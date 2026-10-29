import Foundation
import Observation

/// App lifetime ownership: windows and the phone share one backend per leaf.
@Observable
final class AIChatSessionRegistry {
    let workspaces: WorkspaceStore
    let directories: TerminalPwdStore
    let history: AIChatHistoryStore
    private(set) var sessions: [UUID: AITerminalSession] = [:]
    @ObservationIgnored var onTurnCompleted: ((UUID, UUID) -> Void)?
    private var attachmentImports = 0
    var hasPendingWorkForUpdate: Bool {
        attachmentImports > 0 || sessions.values.contains { $0.chat?.hasPendingWorkForUpdate == true }
    }
    func beginAttachmentImport() -> Bool {
        guard !UpdateStore.shared.blocksNewMessages else { return false }
        attachmentImports += 1
        return true
    }
    func endAttachmentImport() { attachmentImports = max(0, attachmentImports - 1) }
    private let makeSession: () -> AITerminalSession
    private let makeTransport: () -> any AIChatTransport

    init(workspaces: WorkspaceStore, directories: TerminalPwdStore,
         history: AIChatHistoryStore = .shared,
         makeSession: @escaping () -> AITerminalSession = { AITerminalSession() },
         makeTransport: @escaping () -> any AIChatTransport = { AIChatProcess() }) {
        self.workspaces = workspaces
        self.directories = directories
        self.history = history
        self.makeSession = makeSession
        self.makeTransport = makeTransport
        observeLayout()
    }

    func contains(_ id: UUID) -> Bool {
        workspaces.workspaces.contains { $0.tabs.contains { $0.layout.allTerminalIds().contains(id) } }
    }

    func session(for id: UUID) -> AITerminalSession? {
        guard contains(id) else { return nil }
        if let session = sessions[id] { return session }
        let session = makeSession()
        session.directory = directories.pwd(for: id) ?? NSHomeDirectory()
        session.onLaunch = { [weak self, weak session] configuration in
            guard let self, let session else { return }
            session.startChat(configuration, directory: session.directory, transport: self.makeTransport())
            self.directories.setPwd(session.directory, for: id)
        }
        session.onFirstMessageSubmitted = { [weak self] prompt in
            self?.workspaces.nameWorkspaceFromFirstPrompt(prompt, terminalId: id)
        }
        session.onTurnCompleted = { [weak self, weak session] eventID in
            guard let self, let session, self.sessions[id] === session, self.contains(id) else { return }
            self.onTurnCompleted?(id, eventID)
        }
        sessions[id] = session
        session.restoreHistory(for: id, store: history, transport: makeTransport())
        return session
    }

    /// Browsing history never starts inactive CLI processes.
    func snapshot(for id: UUID) throws -> AIChatSnapshot? {
        guard contains(id) else { return nil }
        return try sessions[id]?.chat?.snapshot ?? history.load(for: id)
    }

    func prune() {
        for id in Array(sessions.keys) where !contains(id) {
            sessions.removeValue(forKey: id)?.back()
        }
    }

    func flush() { sessions.values.forEach { $0.flushHistory() }; history.flush() }
    func flushForUpdate() throws {
        for session in sessions.values { try session.flushHistoryForUpdate() }
        try history.flushForUpdate()
    }
    func validateConnection(for provider: AIProvider) throws { try makeSession().validateSavedConnection(for: provider) }

    private func observeLayout() {
        withObservationTracking { _ = workspaces.workspaces } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.prune(); self?.observeLayout() }
        }
    }
}

/// Shared across every desktop window as well as the mobile service.
final class TheAllRuntime {
    static let shared = TheAllRuntime()
    let workspaces = WorkspaceStore()
    let directories = TerminalPwdStore()
    let statuses = TerminalStatusStore()
    let titles = TerminalSessionTitleStore()
    lazy var chats = AIChatSessionRegistry(workspaces: workspaces, directories: directories)
    lazy var mobile = MobileAccessController(registry: chats)
    private init() {}
}
