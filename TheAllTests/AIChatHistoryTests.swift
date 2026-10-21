import AppKit
import XCTest
@testable import TheAll

final class AIChatHistoryTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var launch: AILaunchConfiguration?
        var stops = 0
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { launch = configuration }
        func send(_ message: [String: Any]) throws { sent.append(message) }
        func stop() { stops += 1 }
        func emit(_ value: [String: Any]) { onMessage?(value) }
        func respond(_ result: [String: Any] = [:]) {
            guard let request = sent.last else { return }
            if let id = request["request_id"] {
                emit(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": result]])
            } else if let id = request["id"] { emit(["id": id, "result": result]) }
        }
    }
    private final class Credentials: AICredentialStore {
        var connection: AIConnection? = AIConnection(apiKey: "history-fixture-secret", model: "shared-default")
        func load(for provider: AIProvider) throws -> AIConnection? { connection }
        func save(_ connection: AIConnection, for provider: AIProvider) throws { self.connection = connection }
        func delete(for provider: AIProvider) throws { connection = nil }
    }
    private func terminal(_ pipe: Transport, credentials: Credentials = Credentials()) -> AITerminalSession {
        let session = AITerminalSession(credentials: credentials, makeLaunch: {
            try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
        }, loadModels: { _, _ in [] })
        session.onLaunch = { [weak session] in session?.startChat($0, directory: "/tmp", transport: pipe) }
        return session
    }
    private func snapshot(provider: AIProvider = .claude) -> AIChatSnapshot {
        AIChatSnapshot(provider: provider, directory: "/tmp", model: "pane-model", input: "unsent draft",
            messages: [AIChatMessage(id: "u1", role: .user, text: "First question"),
                       AIChatMessage(id: "p1", role: .assistant, text: "Progress", isIntermediate: true),
                       AIChatMessage(id: "a1", role: .assistant, text: "Final answer")], conversationID: "original-session")
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllHistoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor func testWorkspaceViewRecreationAutomaticallyOpensSavedChatWithoutChoosingProvider() throws {
        let directory = try root(), key = "AIChatHistoryTests." + UUID().uuidString
        let pwdKey = key + ".pwd"
        defer { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: pwdKey) }
        var originalTerminal: UUID?
        func panes(in view: NSView) -> [AITerminalPaneView] {
            (view as? AITerminalPaneView).map { [$0] } ?? view.subviews.flatMap { panes(in: $0) }
        }
        func view(store: WorkspaceStore, pipe: Transport) -> TabContentView {
            let view = TabContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
            view.store = store
            view.pwdStore = TerminalPwdStore(persistenceKey: pwdKey)
            view.chatHistoryStore = AIChatHistoryStore(directory: directory)
            view.makeAIPane = { AITerminalPaneView(session: self.terminal(pipe), makeTransport: { pipe }) }
            return view
        }
        do {
            let layout = WorkspaceStore(persistenceKey: key), pipe = Transport()
            layout.createWorkspace(name: "Default")
            let workspace = try XCTUnwrap(layout.selectedWorkspace)
            let id = try XCTUnwrap(workspace.selectedTab?.focusedTerminalId)
            originalTerminal = id
            let first = view(store: layout, pipe: pipe)
            first.pwdStore?.setPwd("/tmp", for: id)
            first.pwdStore?.flushSaveForTesting()
            first.loadWorkspace(workspace)
            let pane = try XCTUnwrap(panes(in: first).first)
            XCTAssertNil(pane.session.chat)
            pane.session.choose(.claude)
            pipe.respond()
            let chat = try XCTUnwrap(pane.session.chat)
            chat.input = "List the project files"
            chat.send()
            pipe.emit(["type": "result", "subtype": "success", "session_id": "workspace-session", "result": "The project contains app and tests."])
            chat.input = "My next question"
            chat.model = "selected-model"
            first.detach()
        }
        let reloaded = WorkspaceStore(persistenceKey: key), pipe = Transport()
        let workspace = try XCTUnwrap(reloaded.selectedWorkspace)
        XCTAssertEqual(workspace.selectedTab?.focusedTerminalId, originalTerminal)
        XCTAssertEqual(workspace.name, "List the project files")
        let reopened = view(store: reloaded, pipe: pipe)
        reopened.loadWorkspace(workspace)
        let pane = try XCTUnwrap(panes(in: reopened).first)
        let chat = try XCTUnwrap(pane.session.chat, "The actual workspace/pane entry must skip the AI selector")
        XCTAssertEqual(pane.session.provider, .claude)
        XCTAssertEqual(chat.messages.map(\.text), ["List the project files", "The project contains app and tests."])
        XCTAssertEqual(chat.input, "My next question")
        XCTAssertEqual(chat.model, "selected-model")
        XCTAssertEqual(chat.directory, "/tmp")
        XCTAssertTrue(pipe.launch!.arguments.contains("--resume"))
        XCTAssertTrue(pipe.launch!.arguments.contains("workspace-session"))
        pipe.respond()
        XCTAssertTrue(chat.isReady)
        reopened.detach()
    }

    @MainActor func testLegacyImportFromRunningEmptyChatStopsOldProcessAndPreservesDraftAndModel() throws {
        for selectedModel in ["pane-model", ""] {
            let store = AIChatHistoryStore(directory: try root()), id = UUID()
            let oldPipe = Transport(), session = terminal(Transport())
            session.restoreHistory(for: id, store: store)
            session.onLaunch = { [weak session] in session?.startChat($0, directory: "/tmp", transport: oldPipe) }
            session.choose(.claude); oldPipe.respond()
            let oldChat = try XCTUnwrap(session.chat)
            oldChat.input = "Keep my draft"
            oldChat.model = selectedModel
            let old = snapshot()
            let candidate = AIChatLegacyConversation(id: old.conversationID!, title: "First question",
                directory: old.directory, updatedAt: Date(), messages: old.messages)
            let resumed = Transport()
            XCTAssertTrue(session.restoreLegacyConversation(candidate, transport: resumed))
            XCTAssertGreaterThan(oldPipe.stops, 0)
            XCTAssertFalse(session.chat === oldChat)
            XCTAssertEqual(session.chat?.input, "Keep my draft")
            XCTAssertEqual(session.chat?.model, selectedModel)
            XCTAssertEqual(session.chat?.messages.count, 3)
            XCTAssertTrue(resumed.launch!.arguments.contains("original-session"))
            resumed.respond()
            XCTAssertTrue(session.chat!.isReady)
            let saved = try XCTUnwrap(AIChatHistoryStore(directory: store.directory).load(for: id))
            XCTAssertEqual(saved.conversationID, candidate.id)
            XCTAssertEqual(saved.input, "Keep my draft")
            XCTAssertEqual(saved.model, selectedModel)
        }
    }

    func testLegacyImportCannotReplaceChatThatChangedWhileOpeningHistory() {
        let pipe = Transport(), session = terminal(pipe)
        session.choose(.claude); pipe.respond()
        let original = session.chat!
        original.input = "New question"
        original.send()
        let old = snapshot()
        let candidate = AIChatLegacyConversation(id: old.conversationID!, title: "First question",
            directory: old.directory, updatedAt: Date(), messages: old.messages)
        XCTAssertFalse(session.restoreLegacyConversation(candidate, transport: Transport()))
        XCTAssertTrue(session.chat === original)
        XCTAssertEqual(original.messages.last?.text, "New question")
        XCTAssertEqual(pipe.stops, 0)
    }

    @MainActor func testQuitCheckpointAndNewPaneRestoreConversationDraftModelAndFolder() throws {
        let directory = try root().appendingPathComponent("history")
        let notifications = NotificationCenter()
        let store = AIChatHistoryStore(directory: directory, notifications: notifications)
        let id = UUID(), otherID = UUID()
        let pipe = Transport()
        let first = terminal(pipe)
        first.restoreHistory(for: id, store: store, transport: pipe)
        first.choose(.claude)
        let chat = try XCTUnwrap(first.chat)
        pipe.respond()
        chat.input = "First question"
        chat.send()
        pipe.emit(["type": "system", "session_id": "original-session"])
        pipe.emit(["type": "assistant", "message": ["id": "p1", "content": [["type": "text", "text": "Progress"]]]])
        pipe.emit(["type": "result", "session_id": "original-session", "subtype": "success", "result": "Final answer"])
        XCTAssertTrue(chat.isReady)
        first.chat!.input = "latest draft"
        first.chat!.model = "latest-model"
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        let reopenedStore = AIChatHistoryStore(directory: directory)
        let saved = try XCTUnwrap(reopenedStore.load(for: id))
        XCTAssertEqual(saved.input, "latest draft")
        XCTAssertEqual(saved.model, "latest-model")
        XCTAssertEqual(saved.messages.count, 3)
        XCTAssertTrue(saved.messages[1].isIntermediate)
        XCTAssertNil(try reopenedStore.load(for: otherID))
        let reopenedPipe = Transport(), reopened = terminal(Transport())
        var renamed = false
        reopened.onFirstMessageSubmitted = { _ in renamed = true }
        reopened.restoreHistory(for: id, store: reopenedStore, transport: reopenedPipe)
        XCTAssertEqual(reopened.provider, .claude)
        XCTAssertEqual(reopened.chat?.directory, "/tmp")
        XCTAssertEqual(reopened.chat?.input, "latest draft")
        XCTAssertFalse(reopened.chat!.isBusy)
        XCTAssertTrue(reopened.chat!.approvals.isEmpty)
        XCTAssertTrue(reopenedPipe.launch!.arguments.contains("--resume"))
        XCTAssertTrue(reopenedPipe.launch!.arguments.contains("original-session"))
        XCTAssertTrue(reopenedPipe.launch!.arguments.contains("latest-model"))
        reopenedPipe.respond()
        reopened.chat!.send()
        XCTAssertEqual(reopenedPipe.sent.last?["session_id"] as? String, "original-session")
        XCTAssertFalse(renamed)
        XCTAssertEqual(reopened.chat!.messages.filter { $0.role == .user }.count, 2)
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("history-fixture-secret"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        first.flushHistory(); reopened.flushHistory(); chat.stop()
    }

    @MainActor func testCodexResumesSavedThreadAndNeverStartsEmptyThreadOnFailure() {
        let pipe = Transport(), session = terminal(Transport())
        session.restore(snapshot(provider: .openai), transport: pipe)
        pipe.respond()
        pipe.respond(["data": [["isDefault": true, "model": "default-model"]]])
        XCTAssertEqual(pipe.sent.last?["method"] as? String, "thread/resume")
        let params = pipe.sent.last?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "original-session")
        XCTAssertEqual(params?["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params?["sandbox"] as? String, "danger-full-access")
        XCTAssertEqual(params?["excludeTurns"] as? Bool, true)
        pipe.emit(["id": pipe.sent.last!["id"]!, "error": ["message": "Session no longer exists"]])
        XCTAssertFalse(session.chat!.isReady)
        XCTAssertEqual(session.chat!.input, "unsent draft")
        XCTAssertEqual(session.chat!.messages.count, 3)
        XCTAssertEqual(session.chat!.conversationID, "original-session")
        XCTAssertNotNil(session.chat!.errorMessage)
        XCTAssertFalse(pipe.sent.contains { $0["method"] as? String == "thread/start" })
    }

    @MainActor func testMissingCredentialsAndEditingConnectionKeepHistory() {
        let credentials = Credentials()
        credentials.connection = nil
        let pipe = Transport(), session = terminal(pipe, credentials: credentials)
        session.restore(snapshot(), transport: pipe)
        XCTAssertEqual(session.chat?.messages.count, 3)
        XCTAssertNotNil(session.chat?.errorMessage)
        XCTAssertNil(pipe.launch)
        session.editConnection()
        session.draft = AIConnection(apiKey: "replacement-fixture-key", model: "new-default")
        session.saveAndLaunch()
        XCTAssertEqual(session.chat?.messages.count, 3)
        XCTAssertEqual(session.chat?.model, "pane-model")
        XCTAssertEqual(session.chat?.input, "unsent draft")
        XCTAssertTrue(pipe.launch!.arguments.contains("original-session"))
        pipe.respond()
        XCTAssertTrue(session.chat!.isReady)
    }

    @MainActor func testCorruptHistoryIsReportedAndNeverOverwrittenByEmptyChat() throws {
        let directory = try root(), id = UUID()
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        let corrupt = Data("incomplete previous file".utf8)
        try corrupt.write(to: file)
        let store = AIChatHistoryStore(directory: directory), session = terminal(Transport())
        session.restoreHistory(for: id, store: store)
        XCTAssertNotNil(session.historyError)
        session.choose(.claude)
        session.flushHistory()
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testMissingBackendIDDoesNotSilentlyDiscardVisibleHistory() {
        var saved = snapshot()
        saved.conversationID = nil
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe, restoring: saved)
        chat.start(AILaunchConfiguration(command: "unused", environment: [:]))
        XCTAssertNil(pipe.launch)
        XCTAssertFalse(chat.isReady)
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.messages.count, 3)
    }

    @MainActor func testCheckpointsRedactKnownKeysIncludingAfterStopping() throws {
        let directory = try root(), id = UUID()
        let store = AIChatHistoryStore(directory: directory)
        let pipe = Transport(), session = terminal(Transport())
        session.restoreHistory(for: id, store: store)
        session.restore(snapshot(), transport: pipe)
        pipe.respond()
        session.chat!.input = "draft contains history-fixture-secret"
        pipe.emit(["type": "assistant", "message": ["id": "key-output",
            "content": [["type": "text", "text": "output contains history-fixture-secret"]]]])
        session.flushHistory()
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("history-fixture-secret"))
        session.chat!.stop()
        session.flushHistory()
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("history-fixture-secret"))
        XCTAssertEqual(try store.load(for: id)?.input, "draft contains ••••")
    }

    func testFailedCheckpointReportsFailureWithoutDestroyingPreviousFile() throws {
        let directory = try root(), id = UUID()
        let store = AIChatHistoryStore(directory: directory)
        store.save(snapshot(), for: id) { _ in }
        store.flush()
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        let original = try Data(contentsOf: file)
        // A file in place of a directory gives a deterministic error, including
        // when the test is run as a privileged user with permissive filesystem access.
        let unavailable = AIChatHistoryStore(directory: file)
        let reported = expectation(description: "failed checkpoint reported")
        unavailable.save(snapshot(), for: id) { succeeded in
            XCTAssertFalse(succeeded)
            reported.fulfill()
        }
        unavailable.flush()
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
