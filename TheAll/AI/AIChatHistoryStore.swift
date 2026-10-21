import AppKit

/// Only conversation state belongs here. Connections and API credentials stay
/// in the credential helper; backend authentication is reloaded on every launch.
struct AIChatSnapshot: Codable {
    var version = 1
    var provider: AIProvider
    var directory: String
    var model: String
    var input: String
    var messages: [AIChatMessage]
    var conversationID: String?

    func redacting(_ secrets: [String]) -> Self {
        guard !secrets.isEmpty else { return self }
        func redact(_ value: String) -> String {
            secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "••••") }
        }
        var saved = self
        saved.input = redact(input)
        saved.messages = messages.map { message in
            var message = message
            message.text = redact(message.text)
            return message
        }
        return saved
    }
}

/// Stable terminal UUIDs survive layout restoration. Stream updates are
/// coalesced on a serial writer, with a synchronous checkpoint at app shutdown.
final class AIChatHistoryStore {
    static let shared = AIChatHistoryStore()
    let directory: URL
    private let queue = DispatchQueue(label: "com.theall.chat-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var pending: [UUID: (AIChatSnapshot, [String], (Bool) -> Void)] = [:]
    private var scheduled = false
    private var terminationObserver: NSObjectProtocol?
    private let notifications: NotificationCenter

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("ChatHistory"), notifications: NotificationCenter = .default) {
        self.directory = directory
        self.notifications = notifications
        queue.setSpecific(key: queueKey, value: true)
        terminationObserver = notifications.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
    }

    func load(for terminalID: UUID) throws -> AIChatSnapshot? {
        try queue.sync {
            writePending()
            let url = file(for: terminalID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let snapshot = try JSONDecoder().decode(AIChatSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1 else { throw HistoryError.unsupportedVersion }
            return snapshot
        }
    }

    func save(_ snapshot: AIChatSnapshot, for terminalID: UUID, redacting secrets: [String] = [],
              completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            pending[terminalID] = (snapshot, secrets, completion)
            guard !scheduled else { return }
            scheduled = true
            // Throttle, rather than debounce: continuous output still reaches disk.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.scheduled = false
                self?.writePending()
            }
        }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) == true { writePending() }
        else { queue.sync { writePending() } }
    }

    private func file(for terminalID: UUID) -> URL {
        directory.appendingPathComponent(terminalID.uuidString + ".json")
    }

    private func writePending() {
        let writes = pending
        pending.removeAll()
        for (id, (snapshot, secrets, completion)) in writes {
            let succeeded: Bool
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let data = try JSONEncoder().encode(snapshot.redacting(secrets))
                try data.write(to: file(for: id), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: id).path)
                succeeded = true
            } catch { succeeded = false }
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    deinit {
        if let terminationObserver { notifications.removeObserver(terminationObserver) }
        flush()
    }

    enum HistoryError: Error { case unsupportedVersion }
}
