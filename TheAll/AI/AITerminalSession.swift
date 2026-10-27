import Foundation
import Observation

/// One per terminal UUID. Switching tabs or resizing a split never calls choose
/// again, so it cannot create a second process or overwrite an in-progress form.
@Observable
final class AITerminalSession {
    private(set) var provider: AIProvider?
    private(set) var isRunning = false
    private(set) var hasSavedConnection = false
    private(set) var exitCode: Int32?
    private(set) var chat: AIChatSession?
    private(set) var models: [AIModelOption] = []
    private(set) var isLoadingModels = false
    var modelError: String?
    var draft = AIConnection(apiKey: "") {
        didSet {
            if draft.apiKey != oldValue.apiKey || draft.baseURL != oldValue.baseURL || draft.useBearerToken != oldValue.useBearerToken {
                cancelModels()
                models = []
                modelError = nil
            }
        }
    }
    var errorMessage: String?
    private(set) var historyError: String?
    var directory = NSHomeDirectory()
    var theme: AppTheme = .systemFallback(isDark: true)
    var locale: Locale = .current

    @ObservationIgnored private let credentials: any AICredentialStore
    @ObservationIgnored private let makeLaunch: (AIProvider, AIConnection) throws -> AILaunchConfiguration
    @ObservationIgnored private let loadModels: (AIProvider, AIConnection) async throws -> [AIModelOption]
    @ObservationIgnored var onLaunch: ((AILaunchConfiguration) -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onFirstMessageSubmitted: ((String) -> Void)?
    @ObservationIgnored private var activeConnection: AIConnection?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var modelRequestID = UUID()
    @ObservationIgnored private var historyStore: AIChatHistoryStore?
    @ObservationIgnored private var terminalID: UUID?
    @ObservationIgnored private var savedChat: AIChatSnapshot?
    @ObservationIgnored private var historyLoadFailed = false

    init(credentials: any AICredentialStore = PersistentAICredentialStore(),
         makeLaunch: @escaping (AIProvider, AIConnection) throws -> AILaunchConfiguration = {
             try AILaunchConfiguration.make(provider: $0, connection: $1)
         }, loadModels: @escaping (AIProvider, AIConnection) async throws -> [AIModelOption] = {
             try await AIModelCatalog.shared.models(provider: $0, connection: $1)
         }) {
        self.credentials = credentials
        self.makeLaunch = makeLaunch
        self.loadModels = loadModels
    }

    func choose(_ provider: AIProvider, edit: Bool = false) {
        guard !isRunning else { return }
        self.provider = provider
        errorMessage = nil
        exitCode = nil
        draft = AIConnection(apiKey: "")
        hasSavedConnection = false
        do {
            if let connection = try credentials.load(for: provider) {
                draft = connection
                hasSavedConnection = true
                if !edit { try launch(connection, save: false) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveAndLaunch() {
        guard !isRunning else { return }
        errorMessage = nil
        do { try launch(draft, save: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func validateSavedConnection(for provider: AIProvider) throws {
        guard let connection = try credentials.load(for: provider) else { throw AIConnectionError.invalidKey }
        _ = try makeLaunch(provider, connection.validated(for: provider))
    }

    private func launch(_ connection: AIConnection, save: Bool) throws {
        guard let provider else { return }
        let validated = try connection.validated(for: provider)
        // Check CLI availability before saving. A failed Keychain write never
        // launches a session that falsely claims its credentials were saved.
        let configuration = try makeLaunch(provider, validated)
        if save { try credentials.save(validated, for: provider) }
        hasSavedConnection = true
        draft = AIConnection(apiKey: "")
        activeConnection = validated
        exitCode = nil
        isRunning = true
        onLaunch?(configuration)
    }

    func startChat(_ configuration: AILaunchConfiguration, directory: String,
                   transport: any AIChatTransport = AIChatProcess()) {
        guard let provider, let activeConnection else { return }
        let snapshot = savedChat?.provider == provider ? savedChat : nil
        let chat = self.chat ?? AIChatSession(provider: provider, model: activeConnection.model,
            directory: directory, transport: transport, restoring: snapshot,
            imageStore: historyStore?.imageStore ?? .shared)
        self.chat = chat
        self.directory = chat.directory
        chat.onFirstMessageSubmitted = { [weak self] in self?.onFirstMessageSubmitted?($0) }
        chat.onStateChanged = { [weak self] in self?.saveHistory() }
        chat.start(configuration)
        saveHistory()
    }

    /// Called after the pane's callbacks and folder bindings are installed.
    /// Display the transcript even if credentials or the CLI are unavailable.
    func restoreHistory(for terminalID: UUID, store: AIChatHistoryStore = .shared,
                        transport: any AIChatTransport = AIChatProcess()) {
        guard self.terminalID == nil else { return }
        self.terminalID = terminalID
        historyStore = store
        do {
            guard let snapshot = try store.load(for: terminalID) else { return }
            restore(snapshot, transport: transport)
        } catch {
            historyLoadFailed = true
            historyError = L10n.string("ai.history.loadFailed")
        }
    }

    func restore(_ snapshot: AIChatSnapshot, transport: any AIChatTransport = AIChatProcess()) {
        savedChat = snapshot
        directory = snapshot.directory
        chat = AIChatSession(provider: snapshot.provider, model: snapshot.model,
                             directory: snapshot.directory, transport: transport, restoring: snapshot,
                             imageStore: historyStore?.imageStore ?? .shared)
        chat?.onStateChanged = { [weak self] in self?.saveHistory() }
        choose(snapshot.provider)
        if !isRunning {
            chat?.errorMessage = errorMessage ?? L10n.string("ai.history.connectionNeeded")
        }
        saveHistory()
    }

    @discardableResult
    func restoreLegacyConversation(_ conversation: AIChatLegacyConversation,
                                   transport: any AIChatTransport = AIChatProcess()) -> Bool {
        guard chat?.isBusy != true, chat?.messages.isEmpty != false else {
            chat?.errorMessage = L10n.string("ai.history.chatChanged")
            return false
        }
        let input = chat?.input ?? savedChat?.input ?? ""
        let images = chat?.draftImages ?? savedChat?.draftImages ?? []
        let selectedModel: String?
        if provider == .claude {
            selectedModel = chat?.model ?? (savedChat?.provider == .claude ? savedChat?.model : nil)
                ?? activeConnection?.model ?? draft.model
        } else { selectedModel = nil }
        let model = selectedModel ?? (try? credentials.load(for: .claude))?.model
            ?? conversation.messages.last(where: { $0.role == .assistant })?.model ?? ""
        // Import is also available from an already-connected empty chat. Stop
        // that process before choose(), whose running guard otherwise skips resume.
        back()
        restore(AIChatSnapshot(provider: .claude, directory: conversation.directory,
            model: model, input: input, messages: conversation.messages, conversationID: conversation.id, draftImages: images),
            transport: transport)
        flushHistory()
        return true
    }

    private func saveHistory() {
        guard !historyLoadFailed, let chat, let terminalID, let historyStore else { return }
        chat.saveHistory(to: historyStore, for: terminalID) { [weak self] succeeded in
            self?.historyError = succeeded ? nil : L10n.string("ai.history.saveFailed")
        }
    }

    func flushHistory() {
        saveHistory()
        historyStore?.flush()
    }

    func selectModel(_ model: String) {
        guard let chat, let provider, let connection = activeConnection else { return }
        chat.model = model
        // Other panes may have edited the saved endpoint. Never overwrite that
        // newer connection with this pane's older credential snapshot.
        do {
            if var saved = try credentials.load(for: provider), saved.apiKey == connection.apiKey,
               saved.baseURL == connection.baseURL, saved.useBearerToken == connection.useBearerToken {
                saved.model = model
                try credentials.save(saved, for: provider)
            }
        } catch { modelError = error.localizedDescription }
    }

    func refreshModels() {
        guard let provider else { return }
        let connection = isRunning ? activeConnection : draft
        guard let connection else { return }
        cancelModels()
        let requestID = modelRequestID
        isLoadingModels = true
        modelError = nil
        let load = loadModels
        modelTask = Task { @MainActor [weak self] in
            do {
                let models = try await load(provider, connection)
                guard let self, self.modelRequestID == requestID else { return }
                self.models = models
                self.isLoadingModels = false
                if models.isEmpty { self.modelError = L10n.string("ai.models.empty") }
            } catch {
                guard let self, self.modelRequestID == requestID, !Task.isCancelled else { return }
                self.isLoadingModels = false
                self.modelError = (error as? AIModelCatalog.CatalogError)?.localizedDescription
                    ?? (error as? AIConnectionError)?.localizedDescription ?? L10n.string("ai.models.unavailable")
            }
        }
    }

    private func cancelModels() {
        modelTask?.cancel()
        modelTask = nil
        modelRequestID = UUID()
        isLoadingModels = false
    }

    func processExited(_ code: Int32) { exitCode = code }

    func launchFailed() {
        back()
        errorMessage = L10n.string("ai.error.launch")
    }

    func back() {
        flushHistory()
        if let chat { savedChat = chat.snapshot }
        chat?.stop()
        chat = nil
        cancelModels()
        activeConnection = nil
        models = []
        modelError = nil
        onStop?()
        isRunning = false
        provider = nil
        draft = AIConnection(apiKey: "")
        hasSavedConnection = false
        errorMessage = nil
        exitCode = nil
    }

    func editConnection() {
        guard let provider else { return }
        back()
        choose(provider, edit: true)
    }

    func forgetConnection() {
        guard let provider, !isRunning else { return }
        do {
            try credentials.delete(for: provider)
            hasSavedConnection = false
            draft = AIConnection(apiKey: "")
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    deinit { historyStore?.flush() }
}
