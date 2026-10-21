import Foundation

struct AIModelOption: Identifiable, Equatable {
    let id: String
    let title: String
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
            let id: String
            let display_name: String?
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
                models[model.id] = AIModelOption(id: model.id, title: model.display_name ?? model.id)
            }
            if provider == .openai || page.has_more != true {
                return models.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            guard let next = page.last_id, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw CatalogError.invalidResponse
            }
            cursor = next
        }
        throw CatalogError.invalidResponse
    }
}
