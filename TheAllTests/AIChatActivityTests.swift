import XCTest
@testable import TheAll

/// Tab-strip activity reported by native chats: a spinner while a turn runs,
/// an amber dot for a question, a blue dot for a finished turn not yet viewed.
final class AIChatActivityTests: XCTestCase {
    private final class Credentials: AICredentialStore {
        func load(for provider: AIProvider) throws -> AIConnection? { AIConnection(apiKey: "activity-test-not-a-key", model: "fixture") }
        func save(_ connection: AIConnection, for provider: AIProvider) throws {}
        func delete(for provider: AIProvider) throws {}
    }
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func send(_ value: [String: Any]) throws {
            sent.append(value)
            respondToClaudeEffortControl(value, sent: sent) { onMessage?($0) }
        }
        func stop() {}
        func respond(_ value: [String: Any] = [:]) {
            guard let request = sent.last, let id = request["request_id"] else { return }
            onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
        }
    }
    private let configuration = AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true")

    private func claude(_ pipe: Pipe, record: @escaping (AIChatActivity) -> Void) -> AIChatSession {
        let session = AIChatSession(provider: .claude, model: "fixture", directory: "/tmp", transport: pipe)
        session.onActivityChanged = record
        session.start(configuration); pipe.respond()
        return session
    }

    func testClaudeTurnReportsRunningThenFinished() {
        let pipe = Pipe()
        var events: [AIChatActivity] = []
        let session = claude(pipe) { events.append($0) }
        XCTAssertEqual(events, [], "Starting the CLI is not a turn")
        session.input = "Inspect"; session.send()
        XCTAssertEqual(events, [.running])
        pipe.onMessage?(["type": "result", "subtype": "success", "result": "Done"])
        XCTAssertEqual(events, [.running, .finished(success: true)])
        session.stop()
        XCTAssertEqual(events, [.running, .finished(success: true)], "Stopping an idle chat reports nothing")
    }

    func testClaudeErrorResultReportsFailure() {
        let pipe = Pipe()
        var events: [AIChatActivity] = []
        let session = claude(pipe) { events.append($0) }
        session.input = "Inspect"; session.send()
        pipe.onMessage?(["type": "result", "subtype": "error_during_execution", "is_error": true, "errors": ["fixture failure"]])
        XCTAssertEqual(events, [.running, .finished(success: false)])
        session.stop()
    }

    func testQuestionReportsNeedsInputThenRunningAgain() {
        let pipe = Pipe()
        var events: [AIChatActivity] = []
        let session = claude(pipe) { events.append($0) }
        session.input = "Ask me"; session.send()
        pipe.onMessage?(["type": "control_request", "request_id": "question", "request": [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion",
            "input": ["questions": [["question": "Which file?", "options": [["label": "A"], ["label": "B"]]]]]]])
        XCTAssertEqual(events, [.running, .needsInput])
        pipe.onMessage?(["type": "control_cancel_request", "request_id": "question"])
        XCTAssertEqual(events, [.running, .needsInput, .running])
        session.stop()
        XCTAssertEqual(events.last, .interrupted)
    }

    func testStoppingARunningTurnIsAnInterruption() {
        let pipe = Pipe()
        var events: [AIChatActivity] = []
        let session = claude(pipe) { events.append($0) }
        session.input = "Long task"; session.send()
        session.stop()
        XCTAssertEqual(events, [.running, .interrupted])
    }

    func testStatusStoreRecordsActivityAndMarksItRead() {
        let store = TerminalStatusStore()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        store.record(.running, terminalId: id, agent: .codex, at: start)
        XCTAssertTrue(store.status(for: id).wantsAttention)
        store.record(.finished(success: true), terminalId: id, agent: .codex, at: start.addingTimeInterval(5))
        guard case .success(0, 5, _, .codex, nil, nil) = store.status(for: id) else {
            return XCTFail("Expected an unread success, got \(store.status(for: id))")
        }
        store.markRead(terminalIds: [id])
        XCTAssertFalse(store.status(for: id).wantsAttention)
        store.record(.running, terminalId: id, agent: .codex, at: start.addingTimeInterval(10))
        store.record(.interrupted, terminalId: id, agent: .codex, at: start.addingTimeInterval(11))
        XCTAssertEqual(store.status(for: id), .idle(since: start.addingTimeInterval(11)))
        store.record(.finished(success: false), terminalId: id, agent: .claude, at: start.addingTimeInterval(20))
        guard case .failed(1, _, _, .claude, nil, nil) = store.status(for: id) else {
            return XCTFail("Expected an unread failure, got \(store.status(for: id))")
        }
    }

    @MainActor func testRegistryNamesTheTabAndReportsTurnActivity() throws {
        let key = "AIChatActivityTests." + UUID().uuidString
        let history = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: history)
            for suffix in ["", ".pwd", ".titles"] { UserDefaults.standard.removeObject(forKey: key + suffix) }
        }
        let pipe = Pipe()
        let workspaces = WorkspaceStore(persistenceKey: key)
        let titles = TerminalSessionTitleStore(persistenceKey: key + ".titles")
        let statuses = TerminalStatusStore()
        let registry = AIChatSessionRegistry(
            workspaces: workspaces, directories: TerminalPwdStore(persistenceKey: key + ".pwd"),
            history: AIChatHistoryStore(directory: history), titles: titles, statuses: statuses,
            makeSession: {
                AITerminalSession(credentials: Credentials(), makeLaunch: {
                    try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
                }, loadModels: { _, _ in [] })
            }, makeTransport: { pipe })
        let id = workspaces.createWorkspace(name: "Default")
        let session = try XCTUnwrap(registry.session(for: id))
        session.choose(.claude); pipe.respond()
        defer { session.back() }
        let chat = try XCTUnwrap(session.chat)
        chat.input = "请帮我修复登录页面的崩溃问题。另外看看日志"; chat.send()
        XCTAssertEqual(titles.title(for: id), "修复登录页面的崩溃问题")
        guard case .running = statuses.status(for: id) else { return XCTFail("Expected running") }
        pipe.onMessage?(["type": "result", "subtype": "success", "result": "Fixed"])
        guard case .success(_, _, _, .claude, _, nil) = statuses.status(for: id) else {
            return XCTFail("Expected an unread success, got \(statuses.status(for: id))")
        }
        let tab = try XCTUnwrap(workspaces.workspaces.first?.tabs.first)
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: titles), "修复登录页面的崩溃问题")
        XCTAssertTrue(TerminalStatus.aggregate(tab.layout.allTerminalIds().map { statuses.status(for: $0) }).wantsAttention)
    }
}
