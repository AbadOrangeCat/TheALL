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
    var draftImages: [AIChatImage] = []
    var draftFiles: [AIChatFile] = []
    var reasoningEffort: String = ""
    var codexAppliedReasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case version, provider, directory, model, input, messages, conversationID, draftImages, draftFiles, reasoningEffort, codexAppliedReasoningEffort
    }

    init(version: Int = 1, provider: AIProvider, directory: String, model: String, input: String,
         messages: [AIChatMessage], conversationID: String?, draftImages: [AIChatImage] = [], draftFiles: [AIChatFile] = [], reasoningEffort: String = "", codexAppliedReasoningEffort: String? = nil) {
        self.version = !draftFiles.isEmpty || messages.contains { !$0.files.isEmpty } ? max(3, version) :
            (version == 1 && (!draftImages.isEmpty || messages.contains { !$0.images.isEmpty }) ? 2 : version)
        self.provider = provider; self.directory = directory; self.model = model
        self.reasoningEffort = reasoningEffort
        self.codexAppliedReasoningEffort = codexAppliedReasoningEffort
        self.input = input; self.messages = messages; self.conversationID = conversationID; self.draftImages = draftImages; self.draftFiles = draftFiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        provider = try values.decode(AIProvider.self, forKey: .provider)
        directory = try values.decode(String.self, forKey: .directory)
        model = try values.decode(String.self, forKey: .model)
        input = try values.decode(String.self, forKey: .input)
        messages = try values.decode([AIChatMessage].self, forKey: .messages)
        conversationID = try values.decodeIfPresent(String.self, forKey: .conversationID)
        draftImages = try values.decodeIfPresent([AIChatImage].self, forKey: .draftImages) ?? []
        draftFiles = try values.decodeIfPresent([AIChatFile].self, forKey: .draftFiles) ?? []
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
        codexAppliedReasoningEffort = try values.decodeIfPresent(String.self, forKey: .codexAppliedReasoningEffort)
    }

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
    let imageStore: AIChatImageStore
    let fileStore: AIChatFileStore
    private let queue = DispatchQueue(label: "com.theall.chat-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var pending: [UUID: (AIChatSnapshot, [String], ((Bool) -> Void)?)] = [:]
    private var scheduled = false
    private var terminationObserver: NSObjectProtocol?
    private let notifications: NotificationCenter

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("ChatHistory"), notifications: NotificationCenter = .default) {
        self.directory = directory
        self.imageStore = AIChatImageStore(directory: directory.appendingPathComponent("Attachments"))
        self.fileStore = AIChatFileStore(directory: directory.appendingPathComponent("FileAttachments"))
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
            guard (1...3).contains(snapshot.version) else { throw HistoryError.unsupportedVersion }
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

    /// An updater must not terminate until all queued snapshots are on disk.
    /// Failed writes stay pending, so fixing disk/permission issues allows retry.
    func flushForUpdate() throws {
        let checkpoint = {
            self.writePending()
            guard self.pending.isEmpty else { throw HistoryError.saveFailed }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { try checkpoint() }
        else { try queue.sync(execute: checkpoint) }
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
                var saved = snapshot.redacting(secrets)
                // Older app builds reject v2 rather than dropping unknown image
                // references and overwriting the conversation as text-only.
                if saved.version == 1, !saved.draftImages.isEmpty || saved.messages.contains(where: { !$0.images.isEmpty }) {
                    saved.version = 2
                }
                if saved.version < 3, !saved.draftFiles.isEmpty || saved.messages.contains(where: { !$0.files.isEmpty }) { saved.version = 3 }
                let data = try JSONEncoder().encode(saved)
                try data.write(to: file(for: id), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: id).path)
                succeeded = true
            } catch {
                // A save completion is a one-shot result. Keep failed bytes for
                // checkpoint retries without notifying the original caller twice.
                pending[id] = (snapshot, secrets, nil)
                succeeded = false
            }
            if let completion { DispatchQueue.main.async { completion(succeeded) } }
        }
    }

    deinit {
        if let terminationObserver { notifications.removeObserver(terminationObserver) }
        flush()
    }

    enum HistoryError: Error { case unsupportedVersion, saveFailed }
}
