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
