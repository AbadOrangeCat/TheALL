import Foundation
import Security

/// Keeps the Keychain caller stable across app rebuilds. A certificate-based
/// app ACL alone is insufficient: self-signed apps also get a cdhash partition.
struct PersistentAICredentialStore: AICredentialStore {
    private let legacy: any AICredentialStore
    private let defaults: UserDefaults
    private let installationRoot: URL?
    private let keychainPath: String?
    private static let lock = NSRecursiveLock()

    init(legacy: any AICredentialStore = KeychainAICredentialStore(), defaults: UserDefaults = .standard,
         installationRoot: URL? = nil, keychainPath: String? = nil) {
        self.legacy = legacy
        self.defaults = defaults
        self.installationRoot = installationRoot
        self.keychainPath = keychainPath
    }

    func load(for provider: AIProvider) throws -> AIConnection? {
        try serialized {
            let response = try call(.init(operation: .load, provider: provider.rawValue, keychainPath: keychainPath))
            if response.status == errSecSuccess {
                guard let data = response.data, let connection = try? JSONDecoder().decode(AIConnection.self, from: data)
                else { throw AIConnectionError.corruptCredential }
                return connection
            }
            if response.status != errSecItemNotFound { try check(response.status) }
            guard !defaults.bool(forKey: migrationKey(provider)) else { return nil }
            let connection: AIConnection?
            do { connection = try legacy.load(for: provider) }
            catch AIConnectionError.credentialAuthorizationRequired {
                throw AIConnectionError.legacyCredentialAuthorizationRequired
            }
            guard let connection else { return nil }
            try save(connection, for: provider)
            return connection
        }
    }

    func save(_ connection: AIConnection, for provider: AIProvider) throws {
        try serialized {
            let response = try call(.init(operation: .save, provider: provider.rawValue,
                data: JSONEncoder().encode(connection), keychainPath: keychainPath))
            try check(response.status)
            defaults.set(true, forKey: migrationKey(provider))
        }
    }

    func delete(for provider: AIProvider) throws {
        try serialized {
            let response = try call(.init(operation: .delete, provider: provider.rawValue, keychainPath: keychainPath))
            if response.status != errSecItemNotFound { try check(response.status) }
            defaults.set(true, forKey: migrationKey(provider))
        }
    }

    private func migrationKey(_ provider: AIProvider) -> String {
        (Bundle.main.bundleIdentifier ?? "com.theall.app.dev") + ".ai-connections.v3.migrated." + provider.rawValue
    }

    private func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try operation()
    }

    private func installedHelper() throws -> URL {
        let identity = try AICredentialHelperIdentity.current()
        let manager = FileManager.default
        let root = installationRoot ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identity.identifier).appendingPathComponent("CredentialHelper")
        let folder = root.appendingPathComponent(identity.certificateHash).appendingPathComponent("v1")
        let target = folder.appendingPathComponent("TheAllCredentialHelper")
        if manager.fileExists(atPath: target.path) {
            try identity.validateHelper(at: target)
            return target
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TheAllCredentialHelper")
        try identity.validateHelper(at: bundled)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Publish atomically; concurrent app instances must never overwrite an
        // installed helper, which would change the caller's Keychain partition.
        let temporary = folder.appendingPathComponent(UUID().uuidString)
        try manager.copyItem(at: bundled, to: temporary)
        defer { try? manager.removeItem(at: temporary) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        if link(temporary.path, target.path) != 0, errno != EEXIST {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try identity.validateHelper(at: target)
        return target
    }

    private func call(_ request: AICredentialHelperRequest) throws -> AICredentialHelperResponse {
        do {
            let encoded = try JSONEncoder().encode(request)
            guard encoded.count <= 1_048_576 else { throw AIConnectionError.credentialHelperUnavailable }
            let process = Process()
            process.executableURL = try installedHelper()
            process.environment = [:]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate(); process.waitUntilExit() }
            }
            // The helper never prompts. A timeout also closes blocked pipe reads.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            // Authenticate the running child as well as the installed path,
            // before writing any secret to its input pipe.
            try AICredentialHelperIdentity.current().validateHelper(processID: process.processIdentifier)
            try input.fileHandleForWriting.write(contentsOf: encoded)
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 1_048_576 else { throw AIConnectionError.credentialHelperUnavailable }
            return try JSONDecoder().decode(AICredentialHelperResponse.self, from: data)
        } catch let error as AIConnectionError { throw error }
        catch { throw AIConnectionError.credentialHelperUnavailable }
    }

    private func check(_ status: OSStatus) throws {
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw AIConnectionError.credentialAuthorizationRequired
        }
        guard status == errSecSuccess else { throw AIConnectionError.keychain(status) }
    }
}
