import Foundation
import Security

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case claude, openai

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "OpenAI" }
    var tool: String { self == .claude ? "Claude Code" : "Codex" }
    var executable: String { self == .claude ? "claude" : "codex" }
    var defaultBaseURL: String {
        self == .claude ? "https://api.anthropic.com" : "https://api.openai.com/v1"
    }
}

/// The endpoint and credential are one Keychain item, so changing an endpoint
/// cannot accidentally pair it with a credential belonging to another service.
struct AIConnection: Codable, Equatable {
    var apiKey: String
    var baseURL: String = ""
    var model: String = ""
    var useBearerToken: Bool = false

    func validated(for provider: AIProvider) throws -> AIConnection {
        var result = self
        result.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.apiKey.isEmpty,
              !result.apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AIConnectionError.invalidKey }
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = endpoint.isEmpty ? provider.defaultBaseURL : endpoint
        guard let parts = URLComponents(string: result.baseURL),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !result.baseURL.contains(where: { $0.isWhitespace }),
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw AIConnectionError.invalidURL }
        while result.baseURL.hasSuffix("/") { result.baseURL.removeLast() }
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AIConnectionError.invalidModel }
        return result
    }
}

/// Connection fields recognized in a pasted block: Claude Code `settings.json`
/// (`env`), shell `export` / `set` / PowerShell `$env:` lines, `.env` files,
/// Codex TOML or loose "API key: …" notes. Only known names are applied;
/// other environment variables are listed so the user can see what was skipped.
/// Mirrored by `desktop/renderer/connection-paste.mjs`; keep both in sync.
struct AIConnectionPaste: Equatable {
    enum Field: Equatable { case apiKey, baseURL, model }

    var apiKey: String?
    var baseURL: String?
    var model: String?
    /// Claude only: `ANTHROPIC_AUTH_TOKEN` is sent as `Authorization: Bearer`.
    var useBearerToken: Bool?
    /// Set when the variable names belong to one provider.
    var provider: AIProvider?
    var ignored: [String] = []

    var fields: [Field] {
        [apiKey.map { _ in Field.apiKey }, baseURL.map { _ in .baseURL }, model.map { _ in .model }].compactMap { $0 }
    }

    private struct Name {
        let field: Field
        let rank: Int
        var provider: AIProvider? = nil
        var bearer: Bool? = nil
    }

    private static let names: [String: Name] = {
        var names: [String: Name] = [
            "ANTHROPIC_AUTH_TOKEN": Name(field: .apiKey, rank: 2, provider: .claude, bearer: true),
            "ANTHROPIC_API_KEY": Name(field: .apiKey, rank: 2, provider: .claude, bearer: false),
            "OPENAI_API_KEY": Name(field: .apiKey, rank: 2, provider: .openai),
            "CODEX_API_KEY": Name(field: .apiKey, rank: 2, provider: .openai),
            "ANTHROPIC_BASE_URL": Name(field: .baseURL, rank: 2, provider: .claude),
            "OPENAI_BASE_URL": Name(field: .baseURL, rank: 2, provider: .openai),
            "OPENAI_API_BASE": Name(field: .baseURL, rank: 2, provider: .openai),
            "ANTHROPIC_MODEL": Name(field: .model, rank: 2, provider: .claude),
            "OPENAI_MODEL": Name(field: .model, rank: 2, provider: .openai),
            "CODEX_MODEL": Name(field: .model, rank: 2, provider: .openai),
            "MODEL": Name(field: .model, rank: 1),
        ]
        for name in ["API_KEY", "APIKEY", "X_API_KEY", "KEY", "TOKEN", "AUTH_TOKEN", "ACCESS_TOKEN", "BEARER_TOKEN", "SECRET_KEY"] {
            names[name] = Name(field: .apiKey, rank: 1)
        }
        for name in ["BASE_URL", "BASEURL", "API_BASE", "API_BASE_URL", "API_URL", "ENDPOINT", "URL"] {
            names[name] = Name(field: .baseURL, rank: 1)
        }
        return names
    }()

    /// `nil` unless the text names at least one connection field, so typing
    /// or pasting a bare key keeps working as before.
    static func parse(_ text: String) -> AIConnectionPaste? {
        guard text.utf8.count <= 64 * 1024 else { return nil }
        let pairs = jsonPairs(text) ?? scannedPairs(text)
        var result = AIConnectionPaste()
        var ranks: [Field: Int] = [:]
        var providers: [Field: AIProvider] = [:]
        var ignored = Set<String>()
        for (rawName, rawValue) in pairs {
            let key = normalized(rawName)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = names[key] else {
                if rawName.range(of: #"^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$"#, options: .regularExpression) != nil { ignored.insert(rawName) }
                continue
            }
            guard (ranks[name.field] ?? 0) < name.rank, let accepted = accept(value, for: name.field) else { continue }
            ranks[name.field] = name.rank
            if let provider = name.provider { providers[name.field] = provider } else { providers.removeValue(forKey: name.field) }
            switch name.field {
            case .apiKey:
                result.apiKey = accepted
                result.useBearerToken = name.bearer
            case .baseURL: result.baseURL = accepted
            case .model: result.model = accepted
            }
        }
        guard !result.fields.isEmpty else { return nil }
        result.provider = providers[.apiKey] ?? providers[.baseURL] ?? providers[.model]
        result.ignored = Array(ignored).sorted().prefix(6).map { $0 }
        return result
    }

    /// The "Paste settings" button also accepts a single bare key or URL.
    static func parseClipboard(_ text: String) -> AIConnectionPaste? {
        if let parsed = parse(text) { return parsed }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = accept(value, for: .baseURL) { return AIConnectionPaste(baseURL: url) }
        if let key = accept(value, for: .apiKey) { return AIConnectionPaste(apiKey: key) }
        return nil
    }

    func apply(to connection: inout AIConnection, provider: AIProvider) {
        if let apiKey { connection.apiKey = apiKey }
        if let baseURL { connection.baseURL = baseURL }
        if let model { connection.model = model }
        if provider == .claude, let useBearerToken { connection.useBearerToken = useBearerToken }
    }

    private static func normalized(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func accept(_ value: String, for field: Field) -> String? {
        guard !value.isEmpty, value.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        switch field {
        case .apiKey:
            // Skip placeholders such as `${OPENAI_API_KEY}` or `<your key>`.
            guard value.count >= 8, !value.hasPrefix("$"), !value.hasPrefix("<"),
                  value.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return value
        case .baseURL:
            guard let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, !host.isEmpty else { return nil }
            return value
        case .model:
            guard value.count <= 256, !value.hasPrefix("$"), !value.hasPrefix("<") else { return nil }
            return value
        }
    }

    /// Every string (or number) leaf in a JSON document, at any depth.
    private static func jsonPairs(_ text: String) -> [(String, String)]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var pairs: [(String, String)] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 8 else { return }
            if let object = value as? [String: Any] {
                for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                    if let text = value as? String { pairs.append((key, text)) }
                    else if let number = value as? NSNumber, !(value is Bool) { pairs.append((key, number.stringValue)) }
                    else { walk(value, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, depth: depth + 1) }
            }
        }
        walk(object, depth: 0)
        return pairs
    }

    private static let pairPattern = try? NSRegularExpression(
        pattern: #"["']?([A-Za-z_][A-Za-z0-9_.\-]*)["']?[ \t]*[=:][ \t]*("(?:[^"\\]|\\.)*"|'[^']*'|[^\s,;]+)"#)

    /// `NAME=value`, `NAME: value`, `"NAME": "value"`, `export NAME=…`,
    /// `set NAME=…`, `setx NAME value` and `$env:NAME="…"`, in any order and
    /// even when a paste collapsed the line breaks into spaces.
    private static func scannedPairs(_ text: String) -> [(String, String)] {
        var source = text.replacingOccurrences(of: #"\$env:"#, with: "", options: [.regularExpression, .caseInsensitive])
        source = source.replacingOccurrences(of: #"(?im)\bsetx\s+([A-Za-z_][A-Za-z0-9_]*)\s+"#, with: "$1=", options: .regularExpression)
        guard let regex = pairPattern else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { return nil }
            var value = String(source[valueRange])
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
                if first == "\"" { value = value.replacingOccurrences(of: #"\\(["\\/])"#, with: "$1", options: .regularExpression) }
            } else {
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return (String(source[nameRange]), value)
        }
    }
}

enum AIConnectionError: LocalizedError {
    case invalidKey, invalidURL, invalidModel, corruptCredential, credentialHelperUnavailable, credentialAuthorizationRequired, legacyCredentialAuthorizationRequired
    case keychain(OSStatus)
    case missingCLI(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return L10n.string("ai.error.key")
        case .invalidURL: return L10n.string("ai.error.url")
        case .invalidModel: return L10n.string("ai.error.model")
        case .corruptCredential: return L10n.string("ai.error.corrupt")
        case .credentialHelperUnavailable: return L10n.string("ai.error.credentialHelper")
        case .credentialAuthorizationRequired: return L10n.string("ai.error.keychainAuthorization")
        case .legacyCredentialAuthorizationRequired: return L10n.string("ai.error.keychainLegacy")
        case .keychain(let status): return L10n.string("ai.error.keychain", status)
        case .missingCLI(let name): return L10n.string("ai.error.cli", name)
        }
    }
}

protocol AICredentialStore {
    func load(for provider: AIProvider) throws -> AIConnection?
    func save(_ connection: AIConnection, for provider: AIProvider) throws
    func delete(for provider: AIProvider) throws
}

struct KeychainAICredentialStore: AICredentialStore {
    // Debug and Release do not share credentials. No keys go into UserDefaults.
    let service: String
    private let legacyService: String?
    private let defaults: UserDefaults
    private let keychain: SecKeychain?
    private static let interactionLock = NSRecursiveLock()

    init(service: String? = nil, legacyService: String? = nil, defaults: UserDefaults = .standard, keychain: SecKeychain? = nil) {
        let base = (Bundle.main.bundleIdentifier ?? "com.theall.app.dev") + ".ai-connections"
        self.service = service ?? base + ".v2"
        self.legacyService = legacyService ?? (service == nil ? base : nil)
        self.defaults = defaults
        self.keychain = keychain
    }

    private func query(_ provider: AIProvider, service: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: provider.rawValue]
        if let keychain { result[kSecMatchSearchList as String] = [keychain] }
        return result
    }

    func load(for provider: AIProvider) throws -> AIConnection? {
        try withoutInteraction {
            if let saved = try read(provider, service: service) { return saved }
            guard !defaults.bool(forKey: migrationKey(provider)), let legacyService else { return nil }
            // Never ask macOS to authorize the old ad-hoc executable's item.
            // If it is inaccessible, leave it intact and let the user re-enter
            // their API key into a separately protected current item.
            let legacy: AIConnection?
            do { legacy = try read(provider, service: legacyService) }
            catch AIConnectionError.credentialAuthorizationRequired {
                throw AIConnectionError.legacyCredentialAuthorizationRequired
            }
            if let legacy {
                try save(legacy, for: provider)
                return legacy
            }
            return nil
        }
    }

    private func read(_ provider: AIProvider, service: String) throws -> AIConnection? {
        var request = query(provider, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data,
              let connection = try? JSONDecoder().decode(AIConnection.self, from: data)
        else { throw AIConnectionError.corruptCredential }
        return connection
    }

    func save(_ connection: AIConnection, for provider: AIProvider) throws {
        try withoutInteraction {
            let data = try JSONEncoder().encode(connection)
            let attributes = [kSecValueData as String: data]
            var status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var request = query(provider)
                request.removeValue(forKey: kSecMatchSearchList as String)
                if let keychain { request[kSecUseKeychain as String] = keychain }
                request[kSecValueData as String] = data
                request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(request as CFDictionary, nil)
            }
            try check(status)
            if legacyService != nil { defaults.set(true, forKey: migrationKey(provider)) }
        }
    }

    func delete(for provider: AIProvider) throws {
        try withoutInteraction {
            let status = SecItemDelete(query(provider) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            // Forget must not resurrect a retained legacy connection.
            if legacyService != nil { defaults.set(true, forKey: migrationKey(provider)) }
        }
    }

    private func migrationKey(_ provider: AIProvider) -> String { service + ".migrated." + provider.rawValue }

    private func check(_ status: OSStatus) throws {
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw AIConnectionError.credentialAuthorizationRequired
        }
        guard status == errSecSuccess else { throw AIConnectionError.keychain(status) }
    }

    private func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        // These are file-based login Keychain items. LAContext/UIFail alone
        // does not suppress legacy ACL dialogs. Keep the process-wide switch
        // scoped to serialized synchronous calls and restore it even on error.
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        var allowed = DarwinBoolean(false)
        try check(SecKeychainGetUserInteractionAllowed(&allowed))
        try check(SecKeychainSetUserInteractionAllowed(false))
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try operation()
    }
}
