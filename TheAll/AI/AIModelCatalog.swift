import Foundation

struct AIModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String? = nil
    var resolvedModel: String? = nil
    var line: String? = nil

    static func cliModels(_ values: [[String: Any]], provider: AIProvider) -> [AIModelOption] {
        let aliases: [AIModelOption] = values.compactMap { value in
            guard let rawID = value[provider == .claude ? "value" : "model"] as? String else { return nil }
            let id = provider == .claude && rawID == "default" ? "" : rawID
            let raw: [String]
            if provider == .claude {
                raw = value["supportsEffort"] as? Bool == true ? (value["supportedEffortLevels"] as? [String] ?? []) : []
            } else { raw = (value["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String } }
            let levels = Array(NSOrderedSet(array: raw.filter { !$0.isEmpty && $0.count <= 32 && $0.utf8.allSatisfy { (97...122).contains($0) } })) as? [String] ?? []
            let fallback = value["defaultReasoningEffort"] as? String
            let resolved = provider == .claude ? value["resolvedModel"] as? String : nil
            return AIModelOption(id: id, title: value["displayName"] as? String ?? id, reasoningEfforts: levels,
                defaultReasoningEffort: fallback.flatMap { levels.contains($0) ? $0 : nil },
                resolvedModel: resolved.flatMap { !$0.isEmpty && $0.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil })
        }
        // Claude advertises picker aliases (opus/default) separately from the
        // actual API ID. Only its explicit resolution may bridge those names.
        var result = aliases
        for resolved in Set(aliases.compactMap(\.resolvedModel)).sorted() where !aliases.contains(where: { $0.id == resolved }) {
            let matching = aliases.filter { $0.resolvedModel == resolved }
            let levels = (matching.first?.reasoningEfforts ?? []).filter { level in matching.allSatisfy { $0.reasoningEfforts.contains(level) } }
            result.append(AIModelOption(id: resolved, title: resolved, reasoningEfforts: levels, resolvedModel: resolved))
        }
        return result
    }

    static func merge(catalog: [AIModelOption], backend: [AIModelOption]) -> [AIModelOption] {
        var result = catalog.map { item -> AIModelOption in
            guard let capability = backend.first(where: { $0.id == item.id }) else { return item }
            return AIModelOption(id: item.id, title: item.title, reasoningEfforts: capability.reasoningEfforts,
                                 defaultReasoningEffort: capability.defaultReasoningEffort,
                                 resolvedModel: capability.resolvedModel ?? item.resolvedModel, line: item.line ?? capability.line)
        }
        let ids = Set(result.map(\.id))
        result += backend.filter { !ids.contains($0.id) }
        return ordered(result)
    }

    /// Presentation policy, not a benchmark score. Keep in sync with models.mjs.
    /// Sort after merging so cached catalogs and CLI-only models use the same order.
    static func ordered(_ models: [AIModelOption]) -> [AIModelOption] {
        models.map { ($0, ModelOrder($0)) }.sorted { $0.1.precedes($1.1) }.map(\.0)
    }

}

private struct ModelOrder {
    let family: Int
    let version: [Int]
    let variant: Int
    let title: String
    let id: String
    private static let claude = ["fable", "opus", "sonnet", "haiku"]
    private static let gpt = ["astra", "sol", "terra", "luna"]

    init(_ model: AIModelOption) {
        let canonical = Self.tokens(model.resolvedModel ?? model.id)
        let display = Self.tokens(model.title)
        let explicit = model.line.flatMap { Self.claude.firstIndex(of: $0.lowercased()) }
        let source = explicit != nil || Self.family(canonical) != nil ? canonical : display
        family = model.id.isEmpty ? -1 : explicit ?? Self.family(source) ?? 100
        let parsed = Self.version(source)
        version = parsed.isEmpty && (explicit != nil || Self.family(display) == family) ? Self.version(display) : parsed
        variant = source.contains("nano") ? 3 : source.contains("mini") ? 2 :
            source.contains("pro") || source.contains("max") ? 0 : 1
        title = model.title.lowercased()
        id = model.id
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased().split { !$0.isASCII || !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func family(_ tokens: [String]) -> Int? {
        if tokens.contains("claude") || tokens.count == 1,
           let index = claude.firstIndex(where: tokens.contains) { return index }
        if tokens.contains("gpt") {
            if let index = gpt.firstIndex(where: tokens.contains) { return 10 + index }
            if let index = tokens.firstIndex(of: "gpt"), tokens.indices.contains(index + 1),
               (Int(tokens[index + 1]) != nil || tokens[index + 1] == "4o") { return 20 }
        }
        if tokens.contains(where: { $0.first == "o" && Int($0.dropFirst()) != nil }) { return 21 }
        if tokens.first == "codex" { return 22 }
        return nil
    }

    private static func version(_ tokens: [String]) -> [Int] {
        var result: [Int] = []
        for token in tokens {
            // The older 4o line sits after 4.1 and before the original GPT-4.
            if token == "4o" { result += [4, 0, 1]; continue }
            let raw = token.first == "o" ? String(token.dropFirst()) : token
            if let number = Int(raw) {
                // Snapshot dates / Bedrock revisions are not model generations.
                guard raw.count < 4 else { break }
                result.append(number)
            } else if !result.isEmpty { break }
        }
        return result
    }

    func precedes(_ other: Self) -> Bool {
        if family != other.family { return family < other.family }
        if family < 100 {
            for index in 0..<max(version.count, other.version.count) {
                let lhs = index < version.count ? version[index] : 0
                let rhs = index < other.version.count ? other.version[index] : 0
                if lhs != rhs { return lhs > rhs }
            }
            if variant != other.variant { return variant < other.variant }
        }
        let comparison = title.compare(other.title, options: .numeric, locale: Locale(identifier: "en_US_POSIX"))
        return comparison == .orderedSame ? id < other.id : comparison == .orderedAscending
    }
}

/// Load from the selected gateway, never a second service with the same key.
/// An ephemeral session and redirect refusal keep credentials off disk and
/// prevent an endpoint redirect from forwarding authentication elsewhere.
final class AIModelCatalog: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AIModelCatalog()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func request(provider: AIProvider, connection: AIConnection, after: String? = nil) throws -> URLRequest {
        let connection = try connection.validated(for: provider)
        var base = connection.baseURL
        if provider == .claude, !base.hasSuffix("/v1") { base += "/v1" }
        guard var components = URLComponents(string: base + "/models") else { throw AIConnectionError.invalidURL }
        if provider == .claude {
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let after { components.queryItems?.append(URLQueryItem(name: "after_id", value: after)) }
        }
        guard let url = components.url else { throw AIConnectionError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .openai || connection.useBearerToken {
            request.setValue("Bearer " + connection.apiKey, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(connection.apiKey, forHTTPHeaderField: "x-api-key")
        }
        if provider == .claude { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    struct Page: Decodable {
        struct Model: Decodable {
            struct Capabilities: Decodable {
                struct Effort: Decodable {
                    let supported: Bool?
                    struct Support: Decodable { let supported: Bool? }
                    let low: Support?; let medium: Support?; let high: Support?; let max: Support?; let xhigh: Support?
                    var levels: [String] {
                        guard supported == true else { return [] }
                        return [("low", low), ("medium", medium), ("high", high), ("xhigh", xhigh), ("max", max)].compactMap { $0.1?.supported == true ? $0.0 : nil }
                    }
                }
                let effort: Effort?
            }
            let id: String
            let display_name: String?
            let line: String?
            let capabilities: Capabilities?

            private enum CodingKeys: String, CodingKey { case id, display_name, line, capabilities }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                display_name = try values.decodeIfPresent(String.self, forKey: .display_name)
                capabilities = try values.decodeIfPresent(Capabilities.self, forKey: .capabilities)
                // Optional gateway metadata must not make the entire catalog unavailable.
                line = try? values.decode(String.self, forKey: .line)
            }
        }
        let data: [Model]
        let has_more: Bool?
        let last_id: String?
    }

    enum CatalogError: LocalizedError {
        case http(Int), invalidResponse
        var errorDescription: String? {
            switch self {
            case .http(let status): return L10n.string("ai.models.http", status)
            case .invalidResponse: return L10n.string("ai.models.unavailable")
            }
        }
    }

    func models(provider: AIProvider, connection: AIConnection) async throws -> [AIModelOption] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var models: [String: AIModelOption] = [:]
        var cursor: String?
        var seenCursors = Set<String>()
        // Bound malformed gateway pagination without silently returning a partial list.
        for _ in 0..<100 {
            try Task.checkCancellation()
            let request = try Self.request(provider: provider, connection: connection, after: cursor)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw CatalogError.http(response.statusCode) }
            guard data.count <= 5_000_000, let page = try? JSONDecoder().decode(Page.self, from: data) else {
                throw CatalogError.invalidResponse
            }
            for model in page.data where !model.id.isEmpty && !model.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                models[model.id] = AIModelOption(id: model.id, title: model.display_name ?? model.id, reasoningEfforts: model.capabilities?.effort?.levels ?? [], line: provider == .claude ? model.line : nil)
            }
            if provider == .openai || page.has_more != true {
                return AIModelOption.ordered(Array(models.values))
            }
            guard let next = page.last_id, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw CatalogError.invalidResponse
            }
            cursor = next
        }
        throw CatalogError.invalidResponse
    }
}
