import Foundation
import Observation

struct AIChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant, thinking, tool }
    let id: String
    let role: Role
    var text: String
    var model: String = ""
    var isError = false
    /// Set only after a successful reply identifies this as turn progress.
    /// Keep the original role/text so expanding it restores the full content.
    var isIntermediate = false
    var images: [AIChatImage] = []
    var completedAt: String?
    var durationMs: Double?
    var completionStatus: String?
    var reasoningEffort: String?
    var reasoningEffortVerified = false
    var isVisibleInTranscript: Bool {
        (role != .tool || isError) && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, model, isError, isIntermediate, images, completedAt, durationMs, completionStatus, reasoningEffort, reasoningEffortVerified }

    init(id: String, role: Role, text: String, model: String = "", isError: Bool = false,
         isIntermediate: Bool = false, images: [AIChatImage] = [], completedAt: String? = nil, durationMs: Double? = nil, completionStatus: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.model = model
        self.isError = isError; self.isIntermediate = isIntermediate; self.images = images
        self.completedAt = completedAt; self.durationMs = durationMs; self.completionStatus = completionStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isIntermediate = try values.decodeIfPresent(Bool.self, forKey: .isIntermediate) ?? false
        images = try values.decodeIfPresent([AIChatImage].self, forKey: .images) ?? []
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        completionStatus = try values.decodeIfPresent(String.self, forKey: .completionStatus)
        durationMs = try values.decodeIfPresent(Double.self, forKey: .durationMs)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        reasoningEffortVerified = try values.decodeIfPresent(Bool.self, forKey: .reasoningEffortVerified) ?? false
        if let durationMs, !durationMs.isFinite || durationMs < 0 { self.durationMs = nil }
    }
}

struct AIChatApproval: Identifiable {
    let id: String
    let title: String
    var questions: [AIChatQuestion] = []
}

struct AIChatQuestion: Identifiable {
    let id: String
    let prompt: String
    let options: [String]
    var multiple = false
    var secret = false
}

/// Owns the conversation and draft independently of the selected model. Both
/// backends stay alive for the pane's lifetime; a model applies to the next turn.
@Observable
final class AIChatSession {
    let provider: AIProvider
    private(set) var directory: String { didSet { onStateChanged?() } }
    var input = "" { didSet { onStateChanged?() } }
    var draftImages: [AIChatImage] = [] { didSet { onStateChanged?() } }
    let imageStore: AIChatImageStore
    var model: String {
        didSet { if model != oldValue { showsModelChangeHint = true; if !reasoningEffort.isEmpty && !reasoningEfforts(for: model).contains(reasoningEffort) { reasoningEffort = "" }; onStateChanged?() } }
    }
    var reasoningEffort = "" { didSet { onStateChanged?() } }
    private(set) var backendModels: [AIModelOption] = []
    var catalogModels: [AIModelOption] = [] { didSet { onStateChanged?() } }
    var supportedReasoningEfforts: [String] { reasoningEfforts(for: model) }
    func reasoningEfforts(for model: String) -> [String] {
        let models = AIModelOption.merge(catalog: catalogModels, backend: backendModels)
        if let option = models.first(where: { $0.id == model }) { return option.reasoningEfforts }
        let selected = model.isEmpty ? defaultModel ?? "" : model
        return models.first { $0.id == selected }?.reasoningEfforts ?? []
    }
    @ObservationIgnored private var turnReasoningEffort = ""
    @ObservationIgnored private var turnAppliedReasoningEffort: String?
    @ObservationIgnored private var turnEffortVerified = false
    @ObservationIgnored private var codexAppliedReasoningEffort: String?
    private(set) var showsModelChangeHint = false
    private(set) var messages: [AIChatMessage] = []
    private(set) var approvals: [AIChatApproval] = []
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var canInterrupt = false
    private(set) var revision = 0 { didSet { onStateChanged?() } }
    private(set) var conversationID: String? { didSet { onStateChanged?() } }
    var errorMessage: String?
    @ObservationIgnored var onFirstMessageSubmitted: ((String) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onTurnCompleted: ((UUID) -> Void)?
    @ObservationIgnored private var completionToken: UUID?
    @ObservationIgnored private var turnStartedAt: Date?
    @ObservationIgnored private var turnStartedUptime: TimeInterval?
    @ObservationIgnored private var awaitingSubmittedTurn = false
    @ObservationIgnored private var turnWasInterrupted = false
    @ObservationIgnored private var seenCompletionIDs: [String] = []
    var visibleMessages: [AIChatMessage] { messages.filter(\.isVisibleInTranscript) }
    var activeThinkingID: String? {
        guard isBusy, approvals.isEmpty else { return nil }
        let currentTurn = messages.suffix(from: min(thinkingStartIndex, messages.count))
        return currentTurn.last { $0.role == .thinking }?.id
    }
    var showsThinkingPlaceholder: Bool { isBusy && approvals.isEmpty && activeThinkingID == nil }
    var canChangeDirectory: Bool { !isBusy && approvals.isEmpty && responses.isEmpty }
    @ObservationIgnored private var isStartingForUpdate = false
    var hasPendingWorkForUpdate: Bool {
        isBusy || remoteSubmission != nil || !responses.isEmpty || !approvals.isEmpty
            || pendingClaudeWrite || (isStartingForUpdate && errorMessage == nil)
    }
    var canSend: Bool {
        !UpdateStore.shared.blocksNewMessages && isReady && !isBusy && approvals.isEmpty &&
        (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty)
    }
    var needsConfirmClose: Bool {
        isBusy || !input.isEmpty || !draftImages.isEmpty || !messages.isEmpty || !approvals.isEmpty
    }
    @ObservationIgnored private let transport: any AIChatTransport
    @ObservationIgnored private var responses: [String: (Result<[String: Any], Error>) -> Void] = [:]
    @ObservationIgnored private var approvalReplies: [String: (Bool, [String: [String]]) throws -> Void] = [:]
    @ObservationIgnored private var configuration: AILaunchConfiguration?
    @ObservationIgnored private var reasoningSummaries: [String: [Int: String]] = [:]
    @ObservationIgnored private var reasoningContent: [String: [Int: String]] = [:]
    @ObservationIgnored private var turnID: String?
    @ObservationIgnored private var turnModel = ""
    private var thinkingStartIndex = 0
    private(set) var defaultModel: String?
    @ObservationIgnored private var appliedClaudeModel: String
    @ObservationIgnored private var claudeMessageID = ""
    @ObservationIgnored private var streamedClaudeIDs = Set<String>()
    @ObservationIgnored private var streamedClaudeThinkingIDs = Set<String>()
    @ObservationIgnored private var claudeThinkingCounts: [String: Int] = [:]
    @ObservationIgnored private var claudeStopReasons: [String: String] = [:]
    @ObservationIgnored private var codexMessagePhases: [String: String] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var transportGeneration = UUID()
    @ObservationIgnored private var pendingClaudeWrite = false
    @ObservationIgnored private var deferredClaudeMessages: [[String: Any]] = []
    @ObservationIgnored private var deferredClaudeBytes = 0
    @ObservationIgnored private var hasSubmittedFirstMessage = false
    @ObservationIgnored private var secrets: [String] = []
    enum RemoteSubmissionResult: Equatable { case accepted, rejected, uncertain }
    @ObservationIgnored private var remoteSubmission: ((RemoteSubmissionResult) -> Void)?
    @ObservationIgnored private var remoteRequestWasWritten = false

    init(provider: AIProvider, model: String, directory: String,
         transport: any AIChatTransport = AIChatProcess(), restoring snapshot: AIChatSnapshot? = nil,
         imageStore: AIChatImageStore = .shared) {
        self.provider = provider
        self.model = model
        self.appliedClaudeModel = model
        self.directory = directory
        self.transport = transport
        self.imageStore = imageStore
        if let snapshot, snapshot.provider == provider {
            self.directory = snapshot.directory
            self.model = snapshot.model
            self.appliedClaudeModel = snapshot.model
            self.reasoningEffort = snapshot.reasoningEffort
            self.codexAppliedReasoningEffort = snapshot.codexAppliedReasoningEffort ?? (provider == .openai && !snapshot.reasoningEffort.isEmpty ? snapshot.reasoningEffort : nil)
            self.input = snapshot.input
            self.draftImages = snapshot.draftImages
            self.messages = snapshot.messages
            self.conversationID = snapshot.conversationID
            self.hasSubmittedFirstMessage = snapshot.messages.contains { $0.role == .user }
            self.thinkingStartIndex = snapshot.messages.count
        }
    }

    private var rawSnapshot: AIChatSnapshot {
        AIChatSnapshot(provider: provider, directory: directory, model: model, input: input,
                       messages: messages, conversationID: conversationID, draftImages: draftImages, reasoningEffort: reasoningEffort, codexAppliedReasoningEffort: codexAppliedReasoningEffort)
    }

    var snapshot: AIChatSnapshot { rawSnapshot.redacting(secrets) }

    func saveHistory(to store: AIChatHistoryStore, for terminalID: UUID, completion: @escaping (Bool) -> Void) {
        // Capture value types on the UI thread; redact and encode only the
        // coalesced checkpoint on the writer, not the whole transcript per token.
        store.save(rawSnapshot, for: terminalID, redacting: secrets, completion: completion)
    }

    func start(_ configuration: AILaunchConfiguration, resuming sessionID: String? = nil) {
        completeRemoteSubmission(remoteRequestWasWritten ? .uncertain : .rejected)
        transportGeneration = UUID()
        clearPendingClaudeWrite()
        responses.removeAll()
        clearApprovals()
        finishTurn()
        var configuration = configuration
        // The pane's selection can differ from the shared connection default.
        if let index = configuration.arguments.firstIndex(of: "--model"), index + 1 < configuration.arguments.count {
            configuration.arguments.removeSubrange(index...index + 1)
        }
        if !model.isEmpty { configuration.arguments += ["--model", model] }
        appliedClaudeModel = model
        backendModels = []
        self.configuration = configuration
        isStartingForUpdate = true
        stopped = false
        isReady = false
        errorMessage = nil
        secrets = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "THEALL_OPENAI_API_KEY"]
            .compactMap { configuration.environment[$0] }.filter { !$0.isEmpty }
        let sessionID = sessionID ?? conversationID
        guard sessionID != nil || messages.isEmpty else {
            errorMessage = L10n.string("ai.history.missingSession")
            return
        }
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onExit = { [weak self] status in
            guard let self, !self.stopped else { return }
            self.transportGeneration = UUID()
            self.clearPendingClaudeWrite()
            self.isReady = false
            self.isStartingForUpdate = false
            if self.errorMessage == nil, self.isBusy || status != 0 { self.errorMessage = L10n.string("ai.chat.exit", status) }
            self.completeRemoteSubmission(self.remoteRequestWasWritten ? .uncertain : .rejected)
            self.finishTurn()
            self.clearApprovals()
            let callbacks = Array(self.responses.values)
            self.responses.removeAll()
            callbacks.forEach { $0(.failure(ChatError.disconnected(self.errorMessage ?? L10n.string("ai.chat.exit", status)))) }
        }
        do {
            var launch = configuration.chatConfiguration(for: provider)
            if let sessionID, provider == .claude { launch.arguments += ["--resume", sessionID] }
            try transport.start(launch, directory: directory)
            switch provider {
            case .claude:
                try control("initialize", fields: ["hooks": NSNull()]) { [weak self] result in
                    self?.initialized(result)
                }
            case .openai:
                try rpc("initialize", params: ["clientInfo": ["name": "theall", "version": "0.1.0"]]) { [weak self] result in
                    guard let self else { return }
                    do {
                        _ = try result.get()
                        try self.transport.send(["method": "initialized"])
                        try self.rpc("model/list", params: ["limit": 100]) { [weak self] result in
                            guard let self else { return }
                            if case .success(let value) = result, let models = value["data"] as? [[String: Any]] {
                                self.backendModels = AIModelOption.cliModels(models, provider: .openai)
                                self.defaultModel = models.first { $0["isDefault"] as? Bool == true }?["model"] as? String
                            }
                            self.startCodexThread(resuming: sessionID)
                        }
                    } catch { self.fail(error) }
                }
            }
        } catch { fail(error) }
    }

    /// Claude's cwd is a process property; resume its saved session after a
    /// restart. Codex accepts cwd with each turn and keeps the existing thread.
    @discardableResult
    func changeDirectory(_ path: String) -> Bool {
        guard canChangeDirectory, var launch = configuration else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = L10n.string("ai.directory.unavailable")
            return false
        }
        if path == directory, isReady { return true }
        if provider == .claude {
            guard conversationID != nil || messages.isEmpty else { return false }
            transport.onMessage = nil
            transport.onExit = nil
            transport.stop()
            // A model chosen since launch also applies to the resumed process.
            if let index = launch.arguments.firstIndex(of: "--model"), index + 1 < launch.arguments.count {
                launch.arguments.removeSubrange(index...index + 1)
            }
            if !model.isEmpty { launch.arguments += ["--model", model] }
            appliedClaudeModel = model
            directory = path
            start(launch, resuming: conversationID)
        } else { directory = path }
        return true
    }

    private func startCodexThread(resuming sessionID: String?) {
        var params: [String: Any] = ["cwd": directory, "modelProvider": "theall",
            "approvalPolicy": "never", "sandbox": "danger-full-access"]
        if !model.isEmpty { params["model"] = model }
        if let sessionID { params["threadId"] = sessionID; params["excludeTurns"] = true }
        do {
            try rpc(sessionID == nil ? "thread/start" : "thread/resume", params: params) { [weak self] result in
                guard let self else { return }
                do {
                    let value = try result.get()
                    guard let thread = value["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        throw ChatError.protocolError
                    }
                    guard sessionID == nil || sessionID == id else { throw ChatError.protocolError }
                    self.conversationID = id
                    if self.defaultModel == nil, self.model.isEmpty { self.defaultModel = value["model"] as? String }
                    self.isStartingForUpdate = false
                    self.isReady = true
                } catch { self.fail(error) }
            }
        } catch { fail(error) }
    }

    private func initialized(_ result: Result<[String: Any], Error>) {
        do {
            let value = try result.get()
            backendModels = AIModelOption.cliModels(value["models"] as? [[String: Any]] ?? [], provider: .claude)
            isStartingForUpdate = false
            isReady = true
        }
        catch { fail(error) }
    }

    func send() {
        guard remoteSubmission == nil else { return }
        _ = submit(input, images: draftImages, clearsComposer: true)
    }

    /// Remote clients own their drafts. Never overwrite or clear the Mac composer.
    @discardableResult
    func sendRemote(_ prompt: String, images: [AIChatImage] = [], model selectedModel: String? = nil, reasoningEffort selectedEffort: String? = nil,
                    stillAuthorized: @escaping () -> Bool = { true },
                    completion: @escaping (RemoteSubmissionResult) -> Void = { _ in }) -> Bool {
        guard !UpdateStore.shared.blocksNewMessages, stillAuthorized(), remoteSubmission == nil, isReady, !isBusy, approvals.isEmpty,
              (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
        else { completion(.rejected); return false }
        let nextModel = selectedModel ?? model
        let nextEffort = selectedEffort ?? (nextModel == model ? reasoningEffort : "")
        guard nextEffort.isEmpty || reasoningEfforts(for: nextModel).contains(nextEffort) else { completion(.rejected); return false }
        remoteRequestWasWritten = false
        remoteSubmission = completion
        if let selectedModel { model = selectedModel }
        reasoningEffort = nextEffort
        return submit(prompt, images: images, clearsComposer: false, stillAuthorized: stillAuthorized)
    }

    @discardableResult
    private func submit(_ prompt: String, images: [AIChatImage], clearsComposer: Bool,
                        stillAuthorized: @escaping () -> Bool = { true }) -> Bool {
        guard !UpdateStore.shared.blocksNewMessages, isReady, !isBusy, approvals.isEmpty,
              (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) else { return false }
        guard reasoningEffort.isEmpty || supportedReasoningEfforts.contains(reasoningEffort) else {
            errorMessage = L10n.string("ai.effort.unsupported")
            completeRemoteSubmission(.rejected)
            return false
        }
        turnModel = model
        turnReasoningEffort = reasoningEffort
        turnAppliedReasoningEffort = nil
        turnEffortVerified = false
        awaitingSubmittedTurn = true
        turnWasInterrupted = false
        thinkingStartIndex = messages.count
        isBusy = true
        errorMessage = nil
        do {
            guard images.count <= AIChatImageStore.maximumCount else { throw AIChatImageStore.ImageError.tooMany }
            guard Set(images.map(\.id)).count == images.count else { throw AIChatImageStore.ImageError.invalid }
            // Validate every attachment before any provider request. A missing
            // restored file must not silently send a text-only question.
            var imageInputs: [[String: Any]] = []
            for image in images {
                let data = try imageStore.data(for: image)
                if provider == .claude {
                    imageInputs.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType,
                        "data": data.base64EncodedString()]])
                } else {
                    imageInputs.append(["type": "localImage", "path": try imageStore.url(for: image).path])
                }
            }
            if provider == .claude {
                // Wait for model acknowledgement before submitting the prompt.
                // A selection made during this turn is left for the next send.
                let selected = turnModel
                let generation = transportGeneration
                let submit: (Result<[String: Any], Error>) -> Void = { [weak self] result in
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    do {
                        _ = try result.get()
                        self.appliedClaudeModel = selected
                        guard stillAuthorized() else {
                            self.finishTurn()
                            self.completeRemoteSubmission(.rejected)
                            return
                        }
                        var content = imageInputs
                        if !prompt.isEmpty { content.insert(["type": "text", "text": prompt], at: 0) }
                        let payload: Any = images.isEmpty ? prompt as Any : content
                        // The pipe writer is asynchronous for large photos. Do
                        // not clear the draft or acknowledge a remote send until
                        // the complete JSON line has actually been written.
                        if self.remoteSubmission != nil { self.remoteRequestWasWritten = true }
                        self.pendingClaudeWrite = true
                        do {
                            try self.transport.send(["type": "user", "message": ["role": "user", "content": payload],
                                "parent_tool_use_id": NSNull(), "session_id": self.conversationID ?? ""]) { [weak self] result in
                                guard let self, !self.stopped, self.transportGeneration == generation else { return }
                                switch result {
                                case .success:
                                    self.didSubmit(prompt, images: images, clearsComposer: clearsComposer)
                                    self.canInterrupt = true
                                    self.completeRemoteSubmission(.accepted)
                                    let queued = self.deferredClaudeMessages
                                    self.clearPendingClaudeWrite()
                                    queued.forEach { self.receive($0) }
                                case .failure(let error):
                                    self.clearPendingClaudeWrite()
                                    self.fail(error)
                                }
                            }
                        } catch {
                            // A synchronous throw means no write was queued.
                            self.remoteRequestWasWritten = false
                            self.clearPendingClaudeWrite()
                            throw error
                        }
                    } catch { self.fail(error) }
                }
                let selectedEffort = turnReasoningEffort
                let applyEffort: (Result<[String: Any], Error>) -> Void = { [weak self] result in
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    do {
                        _ = try result.get()
                        self.appliedClaudeModel = selected
                        guard stillAuthorized() else { self.finishTurn(); self.completeRemoteSubmission(.rejected); return }
                        // A successful settings ACK can still be clamped by
                        // policy. Reapply (including Default) and read back
                        // every turn; cached choices cannot prove live state.
                        try self.control("apply_flag_settings", fields: ["settings": ["effortLevel": selectedEffort.isEmpty ? NSNull() : selectedEffort as Any]]) { [weak self] result in
                            guard let self, !self.stopped, self.transportGeneration == generation else { return }
                            do {
                                _ = try result.get()
                                try self.control("get_settings") { [weak self] result in
                                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                                    do {
                                        let value = try result.get()
                                        guard let applied = value["applied"] as? [String: Any],
                                              applied["effort"] is String || applied["effort"] is NSNull else {
                                            throw ChatError.backend(L10n.string("ai.effort.unverified"))
                                        }
                                        let actual = applied["effort"] as? String
                                        if let actual, actual.isEmpty || actual.count > 32 || !actual.utf8.allSatisfy({ (97...122).contains($0) }) {
                                            throw ChatError.backend(L10n.string("ai.effort.unverified"))
                                        }
                                        if !selectedEffort.isEmpty, actual != selectedEffort {
                                            throw ChatError.backend(L10n.string("ai.effort.mismatch", selectedEffort, actual ?? L10n.string("ai.effort.unknown")))
                                        }
                                        self.turnAppliedReasoningEffort = actual
                                        self.turnEffortVerified = actual != nil
                                        submit(.success([:]))
                                    } catch {
                                        if case ChatError.backend(let message) = error,
                                           message.contains("Unsupported control request"), message.contains("get_settings") {
                                            submit(.failure(ChatError.backend(L10n.string("ai.effort.unverified"))))
                                        } else { submit(.failure(error)) }
                                    }
                                }
                            } catch { submit(.failure(error)) }
                        }
                    } catch { self.fail(error) }
                }
                if appliedClaudeModel == selected { applyEffort(.success([:])) }
                else { try control("set_model", fields: ["model": selected.isEmpty ? NSNull() : selected as Any], completion: applyEffort) }
            } else {
                guard stillAuthorized() else {
                    finishTurn()
                    completeRemoteSubmission(.rejected)
                    return false
                }
                guard let conversationID else { throw ChatError.protocolError }
                var content = imageInputs
                if !prompt.isEmpty { content.insert(["type": "text", "text": prompt], at: 0) }
                var params: [String: Any] = ["threadId": conversationID, "cwd": directory,
                    "approvalPolicy": "never", "sandboxPolicy": ["type": "dangerFullAccess"],
                    "input": content]
                guard let selected = turnModel.isEmpty ? defaultModel : turnModel else { throw ChatError.protocolError }
                params["model"] = selected
                let selectedEffort = turnReasoningEffort
                if selectedEffort.isEmpty {
                    let fallback = AIModelOption.merge(catalog: catalogModels, backend: backendModels).first { $0.id == selected }?.defaultReasoningEffort
                    guard fallback != nil || codexAppliedReasoningEffort == nil else { throw ChatError.backend(L10n.string("ai.effort.unsupported")) }
                    params["effort"] = fallback.map { $0 as Any } ?? NSNull()
                } else { params["effort"] = selectedEffort }
                // A lost acknowledgement can still mean the backend accepted
                // the override. Preserve it independently of the editable draft.
                let previousCodexEffort = codexAppliedReasoningEffort
                turnAppliedReasoningEffort = params["effort"] as? String
                if let applied = params["effort"] as? String {
                    codexAppliedReasoningEffort = applied
                    onStateChanged?()
                }
                var written = false
                var rejectedSynchronously = false
                try rpc("turn/start", params: params) { [weak self] result in
                    guard let self else { return }
                    do {
                        let value = try result.get()
                        self.turnID = (value["turn"] as? [String: Any])?["id"] as? String
                        self.acceptSubmittedTurn()
                        if let applied = params["effort"] as? String { self.codexAppliedReasoningEffort = applied }
                        self.onStateChanged?()
                        self.notifyFirstMessage(prompt, images: images)
                        self.completeRemoteSubmission(.accepted)
                    } catch {
                        if case ChatError.backend = error {
                            self.codexAppliedReasoningEffort = previousCodexEffort
                            self.onStateChanged?()
                        }
                        rejectedSynchronously = !written
                        if clearsComposer, written {
                            if self.input.isEmpty { self.input = prompt }
                            let present = Set(self.draftImages.map(\.id))
                            self.draftImages = images.filter { !present.contains($0.id) } + self.draftImages
                        }
                        self.fail(error)
                    }
                }
                guard !rejectedSynchronously else { return false }
                written = true
                // A written Codex request may execute even if its reply is lost.
                // A synchronous reply may already have completed the submission.
                if remoteSubmission != nil { remoteRequestWasWritten = true }
                didSubmit(prompt, images: images, clearsComposer: clearsComposer)
            }
        } catch { fail(error); return false }
        return true
    }

    private func didSubmit(_ prompt: String, images: [AIChatImage], clearsComposer: Bool) {
        if provider == .claude { acceptSubmittedTurn() }
        messages.append(AIChatMessage(id: UUID().uuidString, role: .user, text: prompt, images: images))
        if clearsComposer, input == prompt { input = "" }
        if clearsComposer {
            let submitted = Set(images.map(\.id))
            draftImages.removeAll { submitted.contains($0.id) }
        }
        // A newer selection made while waiting for the previous model's
        // acknowledgement still applies to the following message.
        if model == turnModel { showsModelChangeHint = false }
        revision += 1
        if provider == .claude { notifyFirstMessage(prompt, images: images) }
    }

    private func notifyFirstMessage(_ prompt: String, images: [AIChatImage] = []) {
        guard !hasSubmittedFirstMessage else { return }
        hasSubmittedFirstMessage = true
        onFirstMessageSubmitted?(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !images.isEmpty
            ? L10n.string("ai.images.defaultName") : prompt)
    }

    @discardableResult
    func interrupt() -> Bool {
        guard isBusy, canInterrupt else { return false }
        turnWasInterrupted = true
        do {
            if provider == .claude {
                try control("interrupt") { [weak self] result in
                    if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
                }
            } else if let conversationID, let turnID {
                try rpc("turn/interrupt", params: ["threadId": conversationID, "turnId": turnID]) { [weak self] result in
                    if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
                }
            }
            return true
        } catch { errorMessage = sanitized(error.localizedDescription); return false }
    }

    @discardableResult
    func answerApproval(_ id: String, allow: Bool, answers: [String: [String]] = [:]) -> Bool {
        guard let reply = approvalReplies[id] else { return false }
        do {
            try reply(allow, answers)
            approvalReplies[id] = nil
            approvals.removeAll { $0.id == id }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func stop() {
        if isBusy { turnWasInterrupted = true }
        transportGeneration = UUID()
        clearPendingClaudeWrite()
        completeRemoteSubmission(remoteRequestWasWritten ? .uncertain : .rejected)
        onStateChanged?()
        stopped = true
        transport.onMessage = nil
        transport.onExit = nil
        transport.stop()
        responses.removeAll()
        isReady = false
        finishTurn()
        clearApprovals()
        let saved = snapshot
        messages = saved.messages
        input = saved.input
        draftImages = saved.draftImages
        secrets.removeAll()
        isStartingForUpdate = false
        configuration = nil
    }

    deinit { remoteSubmission?(remoteRequestWasWritten ? .uncertain : .rejected); transport.stop() }

    private func completeRemoteSubmission(_ result: RemoteSubmissionResult) {
        let completion = remoteSubmission
        remoteSubmission = nil
        remoteRequestWasWritten = false
        completion?(result)
    }

    private func control(_ subtype: String, fields: [String: Any] = [:],
                         completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        let id = UUID().uuidString
        responses[id] = completion
        timeout(id)
        do { try transport.send(["type": "control_request", "request_id": id,
                                 "request": fields.merging(["subtype": subtype]) { _, new in new }]) }
        catch { responses[id] = nil; throw error }
    }

    private func rpc(_ method: String, params: [String: Any],
                     completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        let id = UUID().uuidString
        responses[id] = completion
        timeout(id)
        do { try transport.send(["id": id, "method": method, "params": params]) }
        catch { responses[id] = nil; throw error }
    }

    private func fail(_ error: Error) {
        // Only an explicit backend rejection proves a written turn did not start.
        let rejected: Bool
        if case ChatError.backend = error { rejected = true } else { rejected = false }
        completeRemoteSubmission(remoteRequestWasWritten && !rejected ? .uncertain : .rejected)
        errorMessage = sanitized(error.localizedDescription)
        finishTurn()
    }

    private func timeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let callback = self.responses.removeValue(forKey: id) else { return }
            self.isReady = false
            self.isStartingForUpdate = false
            callback(.failure(ChatError.timeout))
        }
    }

    private func acceptSubmittedTurn() {
        guard awaitingSubmittedTurn, completionToken == nil else { return }
        completionToken = UUID()
        turnStartedAt = Date()
        turnStartedUptime = ProcessInfo.processInfo.systemUptime
    }

    private func recordTurnCompletion(success: Bool) {
        guard let token = completionToken, turnStartedAt != nil else { return }
        completionToken = nil // Consume before callbacks; duplicate results cannot notify.
        if let index = currentTurnRange.last(where: { messages[$0].role == .assistant && !messages[$0].isIntermediate && messages[$0].isVisibleInTranscript }) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            messages[index].completedAt = formatter.string(from: Date())
            messages[index].completionStatus = turnWasInterrupted ? "interrupted" : (success ? "completed" : "failed")
            messages[index].durationMs = max(0, (ProcessInfo.processInfo.systemUptime - (turnStartedUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000)
            messages[index].reasoningEffort = turnAppliedReasoningEffort
            messages[index].reasoningEffortVerified = turnEffortVerified
            revision += 1
        }
        if success, !turnWasInterrupted { onTurnCompleted?(token) }
    }

    private func finishTurn() {
        recordTurnCompletion(success: false)
        completionToken = nil; turnStartedAt = nil; turnStartedUptime = nil; awaitingSubmittedTurn = false
        isBusy = false
        canInterrupt = false
        turnID = nil
    }

    private var currentTurnRange: Range<Int> {
        min(thinkingStartIndex, messages.count)..<messages.count
    }

    /// A provider with no message phases may split its final answer into several
    /// messages. Preserve every answer block after the last tool, not just the last.
    private func trailingAnswerIDs() -> Set<String> {
        let range = currentTurnRange
        let lastTool = range.last { messages[$0].role == .tool }
        let start = lastTool.map { $0 + 1 } ?? range.lowerBound
        return Set(messages[start..<range.upperBound].filter {
            $0.role == .assistant && $0.isVisibleInTranscript && !$0.isError
                && codexMessagePhases[$0.id] != "commentary"
                && claudeStopReasons[$0.id] != "tool_use"
                && claudeStopReasons[$0.id] != "max_tokens"
        }.map(\.id))
    }

    private func collapseCompletedProgress(finalAnswerIDs: Set<String>) {
        // With no actual answer, leave progress visible (for example a stopped
        // or tool-only turn). Errors never disappear into collapsed progress.
        guard !finalAnswerIDs.isEmpty else { return }
        var changed = false
        for index in currentTurnRange {
            let message = messages[index]
            if !message.isError, message.role == .thinking
                || (message.role == .assistant && !finalAnswerIDs.contains(message.id)) {
                if !messages[index].isIntermediate {
                    messages[index].isIntermediate = true
                    changed = true
                }
            }
        }
        if changed { revision += 1 }
    }

    private func completeClaudeReply(_ result: [String: Any]) -> Bool {
        guard result["is_error"] as? Bool != true,
              (result["subtype"] as? String).map({ $0 == "success" }) ?? true,
              (result["terminal_reason"] as? String).map({ $0 == "completed" }) ?? true,
              (result["stop_reason"] as? String).map({ ["end_turn", "stop_sequence"].contains($0) }) ?? true
        else { return false }
        var finalIDs = trailingAnswerIDs()
        if let text = result["result"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let finalText = sanitized(text)
            let answers = messages[currentTurnRange].filter { $0.role == .assistant }
            if let match = answers.last(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == finalText.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                finalIDs = [match.id]
            } else if answers.filter({ finalIDs.contains($0.id) }).map(\.text).joined(separator: "\n\n") != finalText {
                // A result can contain the complete answer after missing or
                // incomplete streaming events. Keep that canonical reply visible.
                let partial = answers.last.flatMap { answer in
                    finalIDs.contains(answer.id) && !answer.text.isEmpty && finalText.hasPrefix(answer.text) ? answer.id : nil
                }
                let id = partial ?? "result-\(UUID().uuidString)"
                updateMessage(id: id, role: .assistant, text: finalText)
                finalIDs = [id]
            }
        }
        collapseCompletedProgress(finalAnswerIDs: finalIDs)
        return true
    }

    private func completeCodexReply(_ turn: [String: Any]) -> Bool {
        guard turn["status"] as? String == "completed", turn["error"] == nil || turn["error"] is NSNull else { return false }
        // The completed turn may supply phases/text omitted from earlier events.
        for item in turn["items"] as? [[String: Any]] ?? [] {
            receiveCodex(["method": "item/completed", "params": ["item": item]])
        }
        let answers = messages[currentTurnRange].filter { $0.role == .assistant && $0.isVisibleInTranscript && !$0.isError }
        let explicitAnswers = Set(answers.filter { ["partial_answer", "final_answer"].contains(codexMessagePhases[$0.id] ?? "") }.map(\.id))
        collapseCompletedProgress(finalAnswerIDs: explicitAnswers.union(trailingAnswerIDs()))
        return true
    }

    private func clearApprovals() {
        approvals.removeAll()
        approvalReplies.removeAll()
    }

    private func sanitized(_ value: String) -> String {
        secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "••••") }
    }

    private func updateMessage(id: String, role: AIChatMessage.Role, text: String, append: Bool = false, isError: Bool = false) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = append ? messages[index].text + text : text
            messages[index].isError = messages[index].isError || isError
        } else {
            messages.append(AIChatMessage(id: id, role: role, text: text, model: role == .assistant ? turnModel : "", isError: isError))
        }
        revision += 1
    }

    private func detail(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return sanitized(text)
    }

    private func updateReasoning(_ id: String) {
        let summaries = reasoningSummaries[id] ?? [:]
        let source = summaries.values.contains(where: { !$0.isEmpty }) ? summaries : reasoningContent[id] ?? [:]
        let text = source.keys.sorted().compactMap { source[$0] }.joined(separator: "\n\n")
        if !text.isEmpty { updateMessage(id: "thinking-" + id, role: .thinking, text: text) }
    }

    private func receive(_ message: [String: Any]) {
        guard !stopped else { return }
        if provider == .claude, pendingClaudeWrite {
            // stdout can race the main-thread write completion. Preserve user
            // -> assistant ordering even when the CLI answers immediately.
            deferredClaudeBytes += (try? JSONSerialization.data(withJSONObject: message).count) ?? 0
            guard deferredClaudeBytes <= 16 * 1024 * 1024, deferredClaudeMessages.count < 1024 else {
                transportGeneration = UUID()
                clearPendingClaudeWrite()
                transport.stop()
                isReady = false
                fail(ChatError.protocolError)
                return
            }
            deferredClaudeMessages.append(message)
            return
        }
        if provider == .claude { receiveClaude(message) } else { receiveCodex(message) }
    }

    private func clearPendingClaudeWrite() {
        pendingClaudeWrite = false
        deferredClaudeMessages.removeAll()
        deferredClaudeBytes = 0
    }

    private func receiveClaude(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "control_response":
            guard let response = message["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let callback = responses.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "error" {
                callback(.failure(ChatError.backend(sanitized(response["error"] as? String ?? "Unknown error"))))
            } else { callback(.success(response["response"] as? [String: Any] ?? [:])) }
        case "control_request":
            guard let id = message["request_id"] as? String, let request = message["request"] as? [String: Any] else { return }
            guard request["subtype"] as? String == "can_use_tool" else {
                try? transport.send(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                    "error": "Unsupported control request"]]); return
            }
            let input = request["input"] as? [String: Any] ?? [:]
            // The user chose automatic execution for every tool. Questions
            // still need an actual answer; tool inputs are forwarded unchanged.
            guard request["tool_name"] as? String == "AskUserQuestion" else {
                do {
                    try transport.send(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                        "response": ["behavior": "allow", "updatedInput": input]]])
                } catch { fail(error) }
                return
            }
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> AIChatQuestion? in
                guard let question = item["question"] as? String else { return nil }
                return AIChatQuestion(id: question, prompt: question,
                    options: (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiple: item["multiSelect"] as? Bool ?? false)
            }
            guard !questions.isEmpty else {
                try? transport.send(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                    "error": "Question request contains no supported questions"]])
                errorMessage = L10n.string("ai.chat.unsupported", "AskUserQuestion")
                return
            }
            approvals.append(AIChatApproval(id: id, title: L10n.string("ai.chat.question"), questions: questions))
            approvalReplies[id] = { [weak self] allow, answers in
                var updated = input
                if !questions.isEmpty { updated["answers"] = answers.mapValues { $0.joined(separator: ", ") } }
                let decision: [String: Any] = allow ? ["behavior": "allow", "updatedInput": updated]
                    : ["behavior": "deny", "message": "The user declined this operation."]
                try self?.transport.send(["type": "control_response", "response": ["subtype": "success",
                    "request_id": id, "response": decision]])
            }
        case "control_cancel_request":
            if let id = message["request_id"] as? String {
                approvals.removeAll { $0.id == id }; approvalReplies[id] = nil
            }
        case "system":
            if let resolved = message["model"] as? String { defaultModel = resolved }
            if let id = message["session_id"] as? String { conversationID = id }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            if let id = message["api_message_id"] as? String { claudeMessageID = id }
            if event["type"] as? String == "message_start", let body = event["message"] as? [String: Any], let id = body["id"] as? String {
                claudeMessageID = id
            }
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                claudeStopReasons[claudeMessageID] = reason
            }
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                streamedClaudeIDs.insert(claudeMessageID)
                updateMessage(id: claudeMessageID, role: .assistant, text: text, append: true)
            }
            let thoughtID = "thinking-\(claudeMessageID)-\(event["index"] as? Int ?? 0)"
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "thinking_delta",
               let thought = delta["thinking"] as? String, !thought.isEmpty {
                streamedClaudeThinkingIDs.insert(claudeMessageID)
                updateMessage(id: thoughtID, role: .thinking, text: thought, append: true)
            } else if event["type"] as? String == "content_block_start",
                      let block = event["content_block"] as? [String: Any], block["type"] as? String == "thinking",
                      let thought = block["thinking"] as? String, !thought.isEmpty {
                streamedClaudeThinkingIDs.insert(claudeMessageID)
                updateMessage(id: thoughtID, role: .thinking, text: thought)
            }
        case "assistant":
            guard let body = message["message"] as? [String: Any], let id = body["id"] as? String,
                  let blocks = body["content"] as? [[String: Any]] else { return }
            if let reason = body["stop_reason"] as? String { claudeStopReasons[id] = reason }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            for block in blocks {
                if block["type"] as? String == "text", !text.isEmpty, !streamedClaudeIDs.contains(id) {
                    updateMessage(id: id, role: .assistant, text: text)
                } else if block["type"] as? String == "thinking", let thought = block["thinking"] as? String,
                          !thought.isEmpty, !streamedClaudeThinkingIDs.contains(id) {
                    // Claude sends each completed block as a separate assistant
                    // message, so its array index is not the stream block index.
                    let index = claudeThinkingCounts[id, default: 0]
                    claudeThinkingCounts[id] = index + 1
                    updateMessage(id: "thinking-\(id)-\(index)", role: .thinking, text: thought)
                } else if block["type"] as? String == "tool_use", let toolID = block["id"] as? String {
                    updateMessage(id: toolID, role: .tool, text: (block["name"] as? String ?? "Tool") + "\n" + detail(block["input"] ?? [:]))
                }
            }
        case "user":
            guard let body = message["message"] as? [String: Any], let blocks = body["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let output = block["content"] as? String ?? detail(block["content"] ?? [])
                let prefix = block["is_error"] as? Bool == true ? L10n.string("ai.chat.toolFailed") : L10n.string("ai.chat.toolResult")
                updateMessage(id: id, role: .tool, text: "\n" + prefix + "\n" + sanitized(String(output.suffix(30_000))), append: true,
                              isError: block["is_error"] as? Bool == true)
            }
        case "result":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull else { return }
            if let resultID = message["uuid"] as? String {
                guard !seenCompletionIDs.contains(resultID) else { return }
                seenCompletionIDs.append(resultID)
                if seenCompletionIDs.count > 256 { seenCompletionIDs.removeFirst() }
            }
            if let id = message["session_id"] as? String { conversationID = id }
            if message["is_error"] as? Bool == true {
                errorMessage = sanitized((message["errors"] as? [String])?.joined(separator: "\n")
                    ?? message["result"] as? String ?? L10n.string("ai.chat.failed"))
            }
            guard isBusy, awaitingSubmittedTurn else { return }
            let success = completeClaudeReply(message)
            recordTurnCompletion(success: success)
            finishTurn()
        default: break
        }
    }

    private func receiveCodex(_ message: [String: Any]) {
        if let id = message["id"] as? String, let callback = responses.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                callback(.failure(ChatError.backend(sanitized(error["message"] as? String ?? "Unknown error"))))
            } else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let requestID = message["id"] {
            let id = String(describing: requestID)
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) {
                do { try transport.send(["id": requestID, "result": ["decision": "accept"]]) }
                catch { fail(error) }
            } else if ["execCommandApproval", "applyPatchApproval"].contains(method) {
                do { try transport.send(["id": requestID, "result": ["decision": "approved"]]) }
                catch { fail(error) }
            } else if method == "item/tool/requestUserInput" {
                let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { item -> AIChatQuestion? in
                    guard let id = item["id"] as? String, let question = item["question"] as? String else { return nil }
                    return AIChatQuestion(id: id, prompt: question,
                        options: (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                        secret: item["isSecret"] as? Bool ?? false)
                }
                guard !questions.isEmpty else {
                    try? transport.send(["id": requestID, "error": ["code": -32602,
                        "message": "Question request contains no supported questions"]])
                    errorMessage = L10n.string("ai.chat.unsupported", method)
                    return
                }
                approvals.append(AIChatApproval(id: id, title: L10n.string("ai.chat.question"), questions: questions))
                approvalReplies[id] = { [weak self] allow, answers in
                    let values = allow ? answers : [:]
                    try self?.transport.send(["id": requestID, "result": ["answers": values.mapValues { ["answers": $0] }]])
                }
            } else if method == "item/permissions/requestApproval" {
                do {
                    try transport.send(["id": requestID, "result": ["permissions": params["permissions"] as? [String: Any] ?? [:], "scope": "turn"]])
                } catch { fail(error) }
            } else {
                // Explicit rejection prevents unsupported server tools hanging
                // forever or being silently approved by the host.
                try? transport.send(["id": requestID, "error": ["code": -32601, "message": "Unsupported request: " + method]])
                errorMessage = L10n.string("ai.chat.unsupported", method)
            }
            return
        }
        // Child agents can ask for approval through this same private server.
        // Only their transcript/turn notifications are excluded from this chat;
        // requests and their resolution must always be answered/cleared.
        if method != "serverRequest/resolved", let thread = params["threadId"] as? String,
           let conversationID, thread != conversationID { return }
        switch method {
        case "turn/started":
            acceptSubmittedTurn()
            if !isBusy { thinkingStartIndex = messages.count }
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
            isBusy = true
            canInterrupt = true
        case "serverRequest/resolved":
            if let requestID = params["requestId"] {
                let id = String(describing: requestID)
                approvals.removeAll { $0.id == id }
                approvalReplies[id] = nil
            }
        case "item/agentMessage/delta":
            if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                updateMessage(id: id, role: .assistant, text: delta, append: true)
            }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                if method == "item/reasoning/summaryTextDelta" {
                    reasoningSummaries[id, default: [:]][params["summaryIndex"] as? Int ?? 0, default: ""] += delta
                } else {
                    reasoningContent[id, default: [:]][params["contentIndex"] as? Int ?? 0, default: ""] += delta
                }
                updateReasoning(id)
            }
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            switch item["type"] as? String {
            case "agentMessage":
                if let phase = item["phase"] as? String, ["commentary", "partial_answer", "final_answer"].contains(phase) {
                    codexMessagePhases[id] = phase
                }
                if let text = item["text"] as? String, !text.isEmpty { updateMessage(id: id, role: .assistant, text: text) }
            case "reasoning":
                if let summary = item["summary"] as? [String], !summary.isEmpty {
                    reasoningSummaries[id] = Dictionary(uniqueKeysWithValues: summary.enumerated().map { ($0.offset, $0.element) })
                }
                if let content = item["content"] as? [String], !content.isEmpty {
                    reasoningContent[id] = Dictionary(uniqueKeysWithValues: content.enumerated().map { ($0.offset, $0.element) })
                }
                updateReasoning(id)
            case "commandExecution":
                let command = item["command"] as? String ?? ""
                let output = String((item["aggregatedOutput"] as? String ?? "").suffix(30_000))
                updateMessage(id: id, role: .tool, text: sanitized(command + (output.isEmpty ? "" : "\n" + output)),
                    isError: item["status"] as? String == "failed" || (item["exitCode"] as? Int).map { $0 != 0 } == true)
            case "fileChange", "mcpToolCall":
                updateMessage(id: id, role: .tool, text: detail(item), isError: item["status"] as? String == "failed")
            default: break
            }
        case "turn/completed":
            if let completedID = (params["turn"] as? [String: Any])?["id"] as? String {
                guard !seenCompletionIDs.contains(completedID), turnID == nil || turnID == completedID else { return }
                seenCompletionIDs.append(completedID)
                if seenCompletionIDs.count > 256 { seenCompletionIDs.removeFirst() }
            }
            if let turn = params["turn"] as? [String: Any], let error = turn["error"] as? [String: Any] {
                errorMessage = sanitized(error["message"] as? String ?? L10n.string("ai.chat.failed"))
            }
            if let turn = params["turn"] as? [String: Any] {
                if turn["status"] as? String == "interrupted" { turnWasInterrupted = true }
                recordTurnCompletion(success: completeCodexReply(turn))
            }
            finishTurn()
        case "error":
            if let error = params["error"] as? [String: Any] {
                errorMessage = sanitized(error["message"] as? String ?? L10n.string("ai.chat.failed"))
            }
        default: break
        }
    }

    enum ChatError: LocalizedError {
        case protocolError, backend(String), timeout, disconnected(String)
        var errorDescription: String? {
            switch self {
            case .protocolError: return L10n.string("ai.chat.failed")
            case .backend(let message), .disconnected(let message): return message
            case .timeout: return L10n.string("ai.chat.timeout")
            }
        }
    }
}
