import Foundation
import Observation

/// App lifetime ownership: windows and the phone share one backend per leaf.
@Observable
final class AIChatSessionRegistry {
    let workspaces: WorkspaceStore
    let directories: TerminalPwdStore
    let history: AIChatHistoryStore
    /// Tab names and tab/sidebar activity. Optional so tests can omit them.
    let titles: TerminalSessionTitleStore?
    let statuses: TerminalStatusStore?
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
         titles: TerminalSessionTitleStore? = nil,
         statuses: TerminalStatusStore? = nil,
         makeSession: @escaping () -> AITerminalSession = { AITerminalSession() },
         makeTransport: @escaping () -> any AIChatTransport = { AIChatProcess() }) {
        self.workspaces = workspaces
        self.directories = directories
        self.history = history
        self.titles = titles
        self.statuses = statuses
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
            self?.titles?.nameTerminal(id, fromPrompt: prompt)
        }
        session.onTurnCompleted = { [weak self, weak session] eventID in
            guard let self, let session, self.sessions[id] === session, self.contains(id) else { return }
            self.onTurnCompleted?(id, eventID)
        }
        session.onActivityChanged = { [weak self, weak session] activity in
            guard let self, let session, self.sessions[id] === session, self.contains(id) else { return }
            let agent: HookMessage.Agent = session.chat?.provider == .openai ? .codex : .claude
            self.statuses?.record(activity, terminalId: id, agent: agent)
        }
        sessions[id] = session
        session.restoreHistory(for: id, store: history, transport: makeTransport())
        // Conversations from before automatic tab names get one from their first question.
        if let prompt = session.chat?.messages.first(where: { $0.role == .user && !$0.isSteering })?.text {
            titles?.nameTerminal(id, fromPrompt: prompt)
        }
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
    lazy var chats = AIChatSessionRegistry(workspaces: workspaces, directories: directories,
                                           titles: titles, statuses: statuses)
    lazy var mobile = MobileAccessController(registry: chats)
    private init() {}
}
