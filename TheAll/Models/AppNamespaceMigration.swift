import Foundation

/// Copies settings when a locally configured build changes its settings namespace.
/// Application identity, credentials and conversation storage are not changed here.
enum AppNamespaceMigration {
    enum Outcome: Equatable { case notConfigured, alreadyCompleted, migrated }

    enum MigrationError: Error, LocalizedError {
        case invalidNamespace, invalidConfiguration, invalidDirectory, invalidFile, preferencesNotSaved

        var errorDescription: String? {
            switch self {
            case .invalidNamespace: return "The previous settings namespace is invalid."
            case .invalidConfiguration: return "The previous settings file could not be decoded."
            case .invalidDirectory: return "The settings migration directory is not a regular directory."
            case .invalidFile: return "The settings migration path is not a regular file."
            case .preferencesNotSaved: return "The migrated settings could not be saved."
            }
        }
    }

    private static let lock = NSRecursiveLock()
    private static var defaultSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Call before initializing any settings store. An empty or absent build
    /// setting disables migration. Errors must prevent startup with empty stores.
    @discardableResult
    static func runIfConfigured(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                                applicationSupportRoot: URL? = nil) throws -> Outcome {
        guard let configured = bundle.object(forInfoDictionaryKey: "TheAllPreviousNamespace") else {
            return .notConfigured
        }
        guard let previous = configured as? String else { throw MigrationError.invalidNamespace }
        if previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .notConfigured }
        return try migrate(previousNamespace: previous, defaults: defaults,
                           applicationSupportRoot: applicationSupportRoot ?? defaultSupportRoot)
    }

    /// Only prefixed keys are renamed; values, IDs and the source files remain
    /// byte-for-byte intact. A destination value always takes precedence.
    @discardableResult
    static func migrate(previousNamespace: String, newNamespace: String = "theall",
                        defaults: UserDefaults,
                        applicationSupportRoot: URL) throws -> Outcome {
        try validate(previousNamespace)
        try validate(newNamespace)
        guard previousNamespace != newNamespace else { throw MigrationError.invalidNamespace }
        lock.lock()
        defer { lock.unlock() }
        let marker = "\(newNamespace).namespaceMigration.\(previousNamespace).v1"
        guard !defaults.bool(forKey: marker) else { return .alreadyCompleted }

        // Complete filesystem work first so an unreadable configuration cannot
        // leave a successful marker or partially migrated preferences behind.
        let sourceFolder = applicationSupportRoot.appendingPathComponent(previousNamespace, isDirectory: true)
        let destinationFolder = applicationSupportRoot.appendingPathComponent(newNamespace, isDirectory: true)
        let destination = destinationFolder.appendingPathComponent("config")
        if try directoryExists(destinationFolder), try regularFileExists(destination) {
            // Existing settings take precedence even if the old file is corrupt.
        } else if try directoryExists(sourceFolder) {
            let source = sourceFolder.appendingPathComponent("config")
            if try regularFileExists(source) {
                let data = try Data(contentsOf: source)
                guard let configuration = String(data: data, encoding: .utf8) else {
                    throw MigrationError.invalidConfiguration
                }
                let converted = try renameConfigurationKeys(configuration, from: previousNamespace, to: newNamespace)
                _ = try publishConfigurationIfAbsent(Data(converted.utf8), at: destination)
            }
        }

        let oldPrefix = previousNamespace + "."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(oldPrefix) {
            let target = newNamespace + "." + key.dropFirst(oldPrefix.count)
            if defaults.object(forKey: target) == nil { defaults.set(value, forKey: target) }
        }
        // Written last, and only once per source/destination pair. Otherwise a
        // later user deletion would be resurrected from the retained old data.
        defaults.set(true, forKey: marker)
        guard defaults.synchronize() else {
            defaults.removeObject(forKey: marker)
            throw MigrationError.preferencesNotSaved
        }
        return .migrated
    }

    private static func validate(_ namespace: String) throws {
        let bytes = Array(namespace.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, (97...122).contains(bytes[0]),
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else { throw MigrationError.invalidNamespace }
    }

    private static func renameConfigurationKeys(_ text: String, from previous: String, to current: String) throws -> String {
        // Anchor to actual assignment keys. Values, comments, indentation and
        // original LF/CRLF line endings must survive unchanged.
        let pattern = "(?m)^([\\t ]*)" + NSRegularExpression.escapedPattern(for: previous) + "-(?=[^\\t \\r\\n=]+[\\t ]*=)"
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: "$1" + current + "-")
    }

    /// Atomically publishes a complete file without replacing a concurrently
    /// created destination. Hard-link creation is exclusive, unlike rename.
    @discardableResult
    static func publishConfigurationIfAbsent(_ data: Data, at destination: URL) throws -> Bool {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        if !(try directoryExists(folder)) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        guard try directoryExists(folder) else { throw MigrationError.invalidDirectory }
        if try regularFileExists(destination) { return false }
        let temporary = folder.appendingPathComponent(".namespace-migration-" + UUID().uuidString)
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: temporary) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do {
            try manager.linkItem(at: temporary, to: destination)
            return true
        } catch {
            if try regularFileExists(destination) { return false }
            throw error
        }
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        guard let attributes = try attributesIfPresent(url) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw MigrationError.invalidDirectory }
        return true
    }

    private static func regularFileExists(_ url: URL) throws -> Bool {
        guard let attributes = try attributesIfPresent(url) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MigrationError.invalidFile }
        return true
    }

    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
