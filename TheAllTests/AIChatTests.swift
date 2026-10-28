import AppKit
import SwiftUI
import XCTest
@testable import TheAll

final class AIChatTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var starts = 0
        var stops = 0
        var launch: AILaunchConfiguration?
        var directory: String?
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { starts += 1; launch = configuration; self.directory = directory }
        func send(_ message: [String: Any]) throws { sent.append(message); respondToClaudeEffortControl(message, sent: sent) { onMessage?($0) } }
        func stop() { stops += 1 }
        func emit(_ message: [String: Any]) { onMessage?(message) }
        func respond(_ value: [String: Any] = [:], to message: [String: Any]? = nil) {
            guard let request = message ?? sent.last else { return }
            if let id = request["request_id"] {
                emit(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
            } else if let id = request["id"] { emit(["id": id, "result": value]) }
        }
    }
    private let configuration = AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true")

    func testClaudeSwitchKeepsProcessConversationAndUnsentDraft() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "startup-model", directory: "/tmp", transport: pipe)
        var firstPrompts: [String] = []
        chat.onFirstMessageSubmitted = { firstPrompts.append($0) }
        chat.start(configuration)
        pipe.respond()
        XCTAssertTrue(chat.isReady)
        XCTAssertFalse(chat.needsConfirmClose)
        chat.model = "model-a"
        chat.input = "first question"
        XCTAssertTrue(chat.needsConfirmClose)
        chat.send()
        XCTAssertEqual((pipe.sent.last?["request"] as? [String: Any])?["model"] as? String, "model-a")
        XCTAssertEqual(chat.input, "first question") // Await model acknowledgement.
        XCTAssertTrue(firstPrompts.isEmpty)
        chat.model = "model-b"
        chat.input = "unsent next draft"
        pipe.respond()
        XCTAssertEqual((pipe.sent.last?["message"] as? [String: Any])?["content"] as? String, "first question")
        XCTAssertEqual(chat.input, "unsent next draft")
        pipe.emit(["type": "system", "session_id": "same-session"])
        pipe.emit(["type": "stream_event", "api_message_id": "reply-1", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello"]]])
        pipe.emit(["type": "assistant", "message": ["id": "reply-1", "content": [["type": "text", "text": "Hello"]]]])
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.map(\.text), ["Hello"])
        pipe.emit(["type": "result", "session_id": "same-session", "is_error": false])
        chat.send()
        XCTAssertEqual((pipe.sent.last?["request"] as? [String: Any])?["model"] as? String, "model-b")
        pipe.respond()
        XCTAssertEqual(pipe.sent.last?["session_id"] as? String, "same-session")
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["first question", "unsent next draft"])
        XCTAssertEqual(firstPrompts, ["first question"])
        XCTAssertEqual(pipe.starts, 1)
        XCTAssertEqual(pipe.stops, 0)
        chat.stop()
    }

    func testFailedModelChangeRetainsDraftAndDoesNotSendPrompt() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "startup-model", directory: "/tmp", transport: pipe)
        var firstPrompts: [String] = []
        chat.onFirstMessageSubmitted = { firstPrompts.append($0) }
        chat.start(configuration); pipe.respond()
        chat.model = "bad"
        chat.input = "keep this"
        chat.send()
        let id = pipe.sent.last!["request_id"]!
        pipe.emit(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "model unavailable"]])
        XCTAssertEqual(chat.input, "keep this")
        XCTAssertFalse(chat.isBusy)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        XCTAssertEqual(chat.errorMessage, "model unavailable")
        XCTAssertTrue(firstPrompts.isEmpty)
    }

    func testCodexSwitchUsesSameThreadAndApprovalZeroIsNotLost() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .openai, model: "model-a", directory: "/tmp", transport: pipe)
        var firstPrompts: [String] = []
        chat.onFirstMessageSubmitted = { firstPrompts.append($0) }
        chat.start(configuration); pipe.respond()
        pipe.respond(["data": [["isDefault": true, "model": "default-model"]]])
        pipe.respond(["thread": ["id": "same-thread"], "model": "model-a"])
        XCTAssertTrue(chat.isReady)
        chat.input = "first"
        chat.send()
        XCTAssertFalse(chat.canInterrupt)
        let first = pipe.sent.last!
        XCTAssertTrue(firstPrompts.isEmpty)
        pipe.respond(["turn": ["id": "turn-1"]])
        XCTAssertEqual(firstPrompts, ["first"])
        pipe.emit(["method": "turn/started", "params": ["turn": ["id": "turn-1"]]])
        XCTAssertTrue(chat.canInterrupt)
        pipe.emit(["id": 0, "method": "item/commandExecution/requestApproval", "params": ["command": "touch example"]])
        XCTAssertTrue(chat.approvals.isEmpty)
        XCTAssertEqual(pipe.sent.last?["id"] as? Int, 0)
        XCTAssertEqual((pipe.sent.last?["result"] as? [String: Any])?["decision"] as? String, "accept")
        chat.input = "keep draft"
        chat.model = "model-b"
        pipe.emit(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "Hi"]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "a", "text": "Hi"]]])
        pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn-1", "status": "completed"]]])
        XCTAssertEqual(chat.input, "keep draft")
        chat.send()
        let second = pipe.sent.last!
        pipe.respond(["turn": ["id": "turn-2"]])
        XCTAssertEqual(firstPrompts, ["first"])
        XCTAssertEqual((first["params"] as? [String: Any])?["threadId"] as? String, "same-thread")
        XCTAssertEqual((second["params"] as? [String: Any])?["threadId"] as? String, "same-thread")
        XCTAssertEqual((second["params"] as? [String: Any])?["model"] as? String, "model-b")
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(pipe.starts, 1)
        pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn-2", "status": "completed"]]])
        chat.model = ""
        chat.input = "use the default"
        chat.send()
        XCTAssertEqual((pipe.sent.last?["params"] as? [String: Any])?["model"] as? String, "default-model")
        pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn-3", "status": "completed"]]])
        pipe.emit(["method": "turn/started", "params": ["threadId": "another-thread", "turn": ["id": "foreign"]]])
        XCTAssertFalse(chat.isBusy)
        pipe.emit(["method": "turn/started", "params": ["threadId": "same-thread", "turn": ["id": "hook-turn"]]])
        XCTAssertTrue(chat.isBusy)
        pipe.emit(["id": 1, "method": "item/fileChange/requestApproval", "params": ["threadId": "child-thread"]])
        XCTAssertTrue(chat.approvals.isEmpty)
        XCTAssertEqual((pipe.sent.last?["result"] as? [String: Any])?["decision"] as? String, "accept")
        pipe.emit(["method": "serverRequest/resolved", "params": ["threadId": "child-thread", "requestId": 1]])
        XCTAssertTrue(chat.approvals.isEmpty)
    }

    func testCodexFailedSubmissionDoesNotNameWorkspace() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .openai, model: "model-a", directory: "/tmp", transport: pipe)
        var firstPrompts: [String] = []
        chat.onFirstMessageSubmitted = { firstPrompts.append($0) }
        chat.start(configuration); pipe.respond(); pipe.respond(["data": []])
        pipe.respond(["thread": ["id": "thread"]])
        chat.input = "Rejected request"
        chat.send()
        let id = pipe.sent.last!["id"]!
        pipe.emit(["id": id, "error": ["code": -32602, "message": "Model unavailable"]])
        XCTAssertTrue(firstPrompts.isEmpty)
        XCTAssertFalse(chat.isBusy)
        chat.input = "Accepted first question"
        chat.send()
        pipe.respond(["turn": ["id": "accepted"]])
        XCTAssertEqual(firstPrompts, ["Accepted first question"])
    }

    func testToolQuestionsStillRequireAnswersWhileWritesRunAutomatically() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        let question = ["question": "Choose a theme", "options": [["label": "Dark"], ["label": "Light"]]] as [String: Any]
        pipe.emit(["type": "control_request", "request_id": "ask", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [question]]]])
        XCTAssertEqual(chat.approvals.first?.questions.first?.options, ["Dark", "Light"])
        chat.answerApproval("ask", allow: true, answers: ["Choose a theme": ["Dark"]])
        let response = pipe.sent.last?["response"] as? [String: Any]
        let decision = response?["response"] as? [String: Any]
        let updated = decision?["updatedInput"] as? [String: Any]
        XCTAssertEqual((updated?["answers"] as? [String: String])?["Choose a theme"], "Dark")
        XCTAssertTrue(chat.approvals.isEmpty)
        pipe.emit(["type": "control_request", "request_id": "write", "request": ["subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "/tmp/example"]]])
        XCTAssertTrue(chat.approvals.isEmpty)
        let allowed = (pipe.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(allowed?["behavior"] as? String, "allow")
        pipe.emit(["type": "control_request", "request_id": "background-question", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [question]]]])
        pipe.emit(["type": "result", "is_error": false])
        XCTAssertEqual(chat.approvals.count, 1) // Background questions survive a parent turn.
        chat.answerApproval("background-question", allow: false)
        let denied = (pipe.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(denied?["behavior"] as? String, "deny")
        pipe.emit(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool-1", "content": "User declined", "is_error": true]]]])
        XCTAssertTrue(chat.messages.last?.text.contains("User declined") == true)
        pipe.emit(["type": "result", "is_error": true, "errors": ["Specific API failure"]])
        pipe.onExit?(1)
        XCTAssertEqual(chat.errorMessage, "Specific API failure")
    }

    func testEveryClaudeToolAutomaticallyRepliesWithUnmodifiedInput() throws {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        XCTAssertTrue(pipe.launch?.arguments.contains("--dangerously-skip-permissions") == true)
        // Protocol-only payloads: none of these commands run on the machine.
        let commands = [
            "for d in */; do if [ -d \"$d/.git\" ]; then echo \"=== $d\"; git -C \"$d\" status --short; fi; done",
            "for d in project-a project-b; do git -C $d diff --stat | tail -3; git -C $d ls-files --others --exclude-standard | xargs -I{} wc -l $d/{}; git -C $d log --oneline -5; done",
            "npm test 2>&1 | tail -25",
            "cd /tmp/project && ls; (ls .venv venv 2>/dev/null | head -2); (.venv/bin/python -m pytest -q -x 2>&1 || python3 -m pytest -q -x 2>&1) | tail -25",
            "npm install && git push", "rm /tmp/fictional-test-file",
        ]
        var requests = commands.map { ("Bash", ["command": $0, "timeout": 600000] as [String: Any]) }
        requests += [("Write", ["file_path": "/tmp/fictional.txt", "content": "fixture"]),
                     ("Edit", ["file_path": "/tmp/fictional.txt", "old_string": "a", "new_string": "b"]),
                     ("mcp__fixture__operation", ["value": "fixture"]), ("ExitPlanMode", ["plan": "fixture"])]
        for (index, request) in requests.enumerated() {
            let id = "tool-\(index)"
            pipe.emit(["type": "control_request", "request_id": id, "request": ["subtype": "can_use_tool", "tool_name": request.0,
                "input": request.1, "decision_reason": "Requires approval"]])
            XCTAssertTrue(chat.approvals.isEmpty)
            let envelope = try XCTUnwrap(pipe.sent.last?["response"] as? [String: Any])
            XCTAssertEqual(envelope["request_id"] as? String, id)
            let response = try XCTUnwrap(envelope["response"] as? [String: Any])
            XCTAssertEqual(response["behavior"] as? String, "allow")
            XCTAssertNil(response["updatedPermissions"])
            XCTAssertEqual(response["updatedInput"] as? NSDictionary, request.1 as NSDictionary)
        }
    }

    func testThinkingIndicatorFollowsOnlyCurrentTurnAndPausesForQuestions() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        XCTAssertFalse(chat.showsThinkingPlaceholder)
        chat.input = "Inspect the project"; chat.send()
        XCTAssertTrue(chat.showsThinkingPlaceholder)
        pipe.emit(["type": "assistant", "message": ["id": "first", "content": [["type": "thinking", "thinking": "Inspecting entry point"]]]])
        XCTAssertEqual(chat.activeThinkingID, chat.messages.last?.id)
        XCTAssertFalse(chat.showsThinkingPlaceholder)
        pipe.emit(["type": "control_request", "request_id": "question", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [["question": "Choose a project"]]]]])
        XCTAssertNil(chat.activeThinkingID)
        XCTAssertFalse(chat.showsThinkingPlaceholder)
        chat.answerApproval("question", allow: false)
        XCTAssertNotNil(chat.activeThinkingID)
        pipe.emit(["type": "result", "is_error": false])
        XCTAssertNil(chat.activeThinkingID)
        chat.input = "Next question"; chat.send()
        XCTAssertNil(chat.activeThinkingID) // Never animate the earlier turn.
        XCTAssertTrue(chat.showsThinkingPlaceholder)
        chat.stop()
        XCTAssertFalse(chat.showsThinkingPlaceholder)
    }

    func testRoutineToolsAreHiddenWhileThinkingProgressAndFailuresRemainVisible() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        pipe.emit(["type": "stream_event", "api_message_id": "thought", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Inspect the entry point."]]])
        pipe.emit(["type": "assistant", "message": ["id": "thought", "content": [
            ["type": "thinking", "thinking": "Inspect the entry point.", "signature": "do-not-render"],
            ["type": "redacted_thinking", "data": "private-payload"],
            ["type": "text", "text": "I am checking the entry point."]]]])
        for index in 0..<12 {
            pipe.emit(["type": "assistant", "message": ["id": "tools-\(index)", "content": [["type": "tool_use", "id": "tool-\(index)", "name": "Bash", "input": ["command": "ls"]]]]])
            pipe.emit(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool-\(index)", "content": "file.swift"]]]])
        }
        XCTAssertEqual(chat.visibleMessages.map(\.text), ["Inspect the entry point.", "I am checking the entry point."])
        XCTAssertEqual(chat.visibleMessages.first?.role, .thinking)
        pipe.emit(["type": "control_request", "request_id": "pending", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "npm test"]]])
        XCTAssertTrue(chat.approvals.isEmpty)
        pipe.emit(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "failed", "content": "Permission denied", "is_error": true]]]])
        XCTAssertTrue(chat.visibleMessages.last?.isError == true)
    }

    func testClaudePerBlockAssistantMessagesDoNotDuplicateStreamedThinking() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        for (index, thought) in ["Inspect entry point.", "Check call sites."].enumerated() {
            pipe.emit(["type": "stream_event", "api_message_id": "reply", "event": ["type": "content_block_delta", "index": index, "delta": ["type": "thinking_delta", "thinking": thought]]])
            pipe.emit(["type": "assistant", "message": ["id": "reply", "content": [["type": "thinking", "thinking": thought]]]])
        }
        XCTAssertEqual(chat.visibleMessages.map(\.text), ["Inspect entry point.", "Check call sites."])
        for thought in ["Fallback one", "Fallback two"] {
            pipe.emit(["type": "assistant", "message": ["id": "fallback", "content": [["type": "thinking", "thinking": thought]]]])
        }
        XCTAssertEqual(chat.visibleMessages.suffix(2).map(\.text), ["Fallback one", "Fallback two"])
    }

    func testCodexAutomaticallyAnswersAllPermissionMethodsAndKeepsQuestions() throws {
        let pipe = Transport()
        let chat = AIChatSession(provider: .openai, model: "model-a", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond(); pipe.respond(["data": []])
        let start = try XCTUnwrap(pipe.sent.last?["params"] as? [String: Any])
        XCTAssertEqual(start["approvalPolicy"] as? String, "never")
        XCTAssertEqual(start["sandbox"] as? String, "danger-full-access")
        pipe.respond(["thread": ["id": "parent"]])
        for (index, method) in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval"].enumerated() {
            pipe.emit(["id": index, "method": method, "params": ["threadId": "child", "command": "test", "availableDecisions": ["accept", "decline"]]])
            XCTAssertTrue(chat.approvals.isEmpty)
            XCTAssertEqual(pipe.sent.last?["id"] as? Int, index)
            XCTAssertEqual((pipe.sent.last?["result"] as? [String: Any])?["decision"] as? String, index < 2 ? "accept" : "approved")
        }
        let permissions: [String: Any] = ["network": ["enabled": true], "fileSystem": NSNull()]
        pipe.emit(["id": "permissions", "method": "item/permissions/requestApproval", "params": ["threadId": "child", "permissions": permissions]])
        XCTAssertEqual((pipe.sent.last?["result"] as? [String: Any])?["permissions"] as? NSDictionary, permissions as NSDictionary)
        XCTAssertTrue(chat.approvals.isEmpty)
        chat.input = "Continue"; chat.send()
        let turn = try XCTUnwrap(pipe.sent.last?["params"] as? [String: Any])
        XCTAssertEqual(turn["approvalPolicy"] as? String, "never")
        XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, "dangerFullAccess")
        pipe.emit(["id": "ask", "method": "item/tool/requestUserInput", "params": ["questions": [["id": "theme", "question": "Choose a theme", "options": [["label": "Dark"]]]]]])
        XCTAssertEqual(chat.approvals.count, 1)
        chat.answerApproval("ask", allow: true, answers: ["theme": ["Dark"]])
        let answers = (pipe.sent.last?["result"] as? [String: Any])?["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(answers?["theme"]?["answers"], ["Dark"])
        pipe.emit(["id": "unknown", "method": "unrecognized/method", "params": [:]])
        XCTAssertNotNil(pipe.sent.last?["error"])
        XCTAssertTrue(chat.approvals.isEmpty)
    }

    func testCodexReasoningPrefersSummaryAndDoesNotDuplicateFinalOrHiddenTools() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .openai, model: "model-a", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond(); pipe.respond(["data": []]); pipe.respond(["thread": ["id": "thread"]])
        pipe.emit(["method": "item/reasoning/textDelta", "params": ["itemId": "r", "contentIndex": 0, "delta": "Provided reasoning"]])
        pipe.emit(["method": "item/reasoning/summaryTextDelta", "params": ["itemId": "r", "summaryIndex": 0, "delta": "Check "]])
        pipe.emit(["method": "item/reasoning/summaryTextDelta", "params": ["itemId": "r", "summaryIndex": 0, "delta": "the tests."]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "reasoning", "id": "r", "summary": ["Check the tests."], "content": ["Provided reasoning"]]]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "commandExecution", "id": "c", "command": "ls", "exitCode": 0, "aggregatedOutput": "file.swift"]]])
        XCTAssertEqual(chat.visibleMessages.map(\.text), ["Check the tests."])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "commandExecution", "id": "bad", "command": "test", "exitCode": 1, "status": "failed"]]])
        XCTAssertTrue(chat.visibleMessages.last?.isError == true)
    }

    func testDirectoryChangePreservesDraftAndConversationAndWaitsForIdle() throws {
        for provider in AIProvider.allCases {
            let pipe = Transport()
            let chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe)
            chat.start(configuration); pipe.respond()
            if provider == .openai { pipe.respond(["data": []]); pipe.respond(["thread": ["id": "original"]]) }
            else { pipe.emit(["type": "system", "session_id": "original"]) }
            chat.input = "hello"; chat.send()
            XCTAssertFalse(chat.changeDirectory("/private/tmp"))
            if provider == .openai { pipe.respond(["turn": ["id": "one"]]); pipe.emit(["method": "turn/completed", "params": [:]]) }
            else { pipe.emit(["type": "result", "is_error": false]) }
            chat.input = "unsent draft"
            XCTAssertTrue(chat.changeDirectory("/private/tmp"))
            XCTAssertEqual(chat.input, "unsent draft")
            XCTAssertEqual(chat.conversationID, "original")
            XCTAssertEqual(chat.messages.first?.text, "hello")
            if provider == .claude {
                XCTAssertEqual(pipe.directory, "/private/tmp")
                XCTAssertTrue(pipe.launch?.arguments.suffix(2) == ["--resume", "original"])
                XCTAssertFalse(chat.isReady)
                pipe.respond()
                XCTAssertEqual(pipe.starts, 2)
            } else { XCTAssertEqual(pipe.starts, 1) }
            chat.send()
            if provider == .openai { XCTAssertEqual((pipe.sent.last?["params"] as? [String: Any])?["cwd"] as? String, "/private/tmp") }
            chat.stop()
        }
    }

    func testModelRequestsUseOnlySelectedEndpointAndAuthentication() throws {
        let openAI = try AIModelCatalog.request(provider: .openai, connection: AIConnection(apiKey: "fake", baseURL: "https://custom.example/api/v1/"))
        XCTAssertEqual(openAI.url?.absoluteString, "https://custom.example/api/v1/models")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer fake")
        XCTAssertNil(openAI.value(forHTTPHeaderField: "x-api-key"))
        let claude = try AIModelCatalog.request(provider: .claude, connection: AIConnection(apiKey: "fake", baseURL: "https://custom.example/v1"), after: "model one")
        XCTAssertEqual(claude.url?.path, "/v1/models")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "x-api-key"), "fake")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(claude.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(claude.url!.absoluteString.contains("after_id=model%20one"))
    }

    @MainActor func testInstalledCLIsKeepHistoryWhenSwitchingModelsThroughNativeBridge() throws {
        for provider in AIProvider.allCases {
            let binary = "/opt/homebrew/bin/" + provider.executable
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw XCTSkip("Install Claude Code and Codex to run local gateway integration coverage")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllChatIntegration-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ai_gateway.py")
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = [fixture.path, root.path]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer { server.terminate(); server.waitUntilExit() }
            func wait(_ seconds: Double, until predicate: () -> Bool) {
                let deadline = Date().addingTimeInterval(seconds)
                while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
            }
            let portFile = root.appendingPathComponent("port")
            wait(5) { FileManager.default.fileExists(atPath: portFile.path) }
            guard let port = try? String(contentsOf: portFile, encoding: .utf8) else { XCTFail("Fixture did not start"); continue }
            let endpoint = "http://127.0.0.1:" + port + (provider == .openai ? "/v1" : "")
            let firstModel = provider == .claude ? "claude-opus-5-5" : "fixture-one"
            let secondModel = provider == .claude ? "claude-sonnet-5-5" : "fixture-two"
            let connection = AIConnection(apiKey: "fake-local-integration-key", baseURL: endpoint, model: firstModel)
            var configuration = try AILaunchConfiguration.make(provider: provider, connection: connection, executable: binary)
            // Real CLIs, exclusively fake credentials, isolated configuration,
            // a temporary working directory, and a local server. Both
            // backends run an offline fixture test through a shell pipeline.
            configuration.environment["HOME"] = root.path
            configuration.environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude").path
            let codexHome = root.appendingPathComponent("codex")
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            configuration.environment["CODEX_HOME"] = codexHome.path
            configuration.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            configuration.environment["DISABLE_AUTOUPDATER"] = "1"
            let chat = AIChatSession(provider: provider, model: firstModel, directory: root.path)
            defer { chat.stop() }
            chat.start(configuration)
            wait(20) { chat.isReady || chat.errorMessage != nil }
            XCTAssertTrue(chat.isReady, "\(provider): \(chat.errorMessage ?? "not ready")")
            guard chat.isReady else { continue }
            chat.input = "First local test question"
            chat.send()
            wait(25) { !chat.isBusy }
            XCTAssertFalse(chat.isBusy)
            XCTAssertNil(chat.errorMessage)
            let conversationID = chat.conversationID
            XCTAssertNotNil(conversationID)
            chat.input = "Continue the same conversation"
            chat.model = secondModel
            XCTAssertEqual(chat.input, "Continue the same conversation")
            chat.send()
            wait(25) { !chat.isBusy }
            XCTAssertFalse(chat.isBusy)
            XCTAssertNil(chat.errorMessage)
            XCTAssertEqual(chat.conversationID, conversationID)
            XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 2)
            let lines = (try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
            let requests = lines.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertEqual(requests.first?["model"] as? String, firstModel)
            XCTAssertEqual(requests.last?["model"] as? String, secondModel)
            // Claude may validate a newly selected model with an extra request.
            let firstCount = requests.filter { $0["model"] as? String == firstModel }.compactMap { $0["count"] as? Int }.max() ?? 0
            let secondCount = requests.filter { $0["model"] as? String == secondModel }.compactMap { $0["count"] as? Int }.max() ?? 0
            XCTAssertGreaterThan(firstCount, 0)
            XCTAssertGreaterThan(secondCount, firstCount)
            let nextFolder = root.appendingPathComponent("next-project")
            try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
            chat.input = "Continue after changing the working folder"
            XCTAssertTrue(chat.changeDirectory(nextFolder.path))
            XCTAssertEqual(chat.input, "Continue after changing the working folder")
            wait(20) { chat.isReady || chat.errorMessage != nil }
            XCTAssertTrue(chat.isReady, chat.errorMessage ?? "Resume did not initialize")
            chat.send()
            wait(25) { !chat.isBusy }
            XCTAssertNil(chat.errorMessage)
            XCTAssertEqual(chat.conversationID, conversationID)
            XCTAssertEqual(chat.directory, nextFolder.path)
            XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 3)
            let resumedLines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            let resumedRequests = resumedLines.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertGreaterThan(resumedRequests.last?["count"] as? Int ?? 0, secondCount)
            let package: [String: Any] = ["name": "theall-offline-fixture", "private": true,
                "scripts": ["test": "node -e \"require('fs').writeFileSync('test-ran.txt','passed');console.log('offline-tests-passed')\""]]
            try JSONSerialization.data(withJSONObject: package).write(to: nextFolder.appendingPathComponent("package.json"))
            let command = "cd " + AILaunchConfiguration.shellQuote(nextFolder.path) + "; (npm test 2>&1 | tail -25)"
            try command.write(to: root.appendingPathComponent("tool-command.txt"), atomically: true, encoding: .utf8)
            chat.input = "Run the local offline test fixture"
            chat.send()
            wait(25) { !chat.isBusy || !chat.approvals.isEmpty }
            XCTAssertTrue(chat.approvals.isEmpty, "Local tests should run without Allow")
            XCTAssertFalse(chat.isBusy)
            XCTAssertNil(chat.errorMessage)
            let result = try String(contentsOf: root.appendingPathComponent("tool-result.json"), encoding: .utf8)
            XCTAssertTrue(result.contains("offline-tests-passed"), result)
            XCTAssertEqual(try String(contentsOf: nextFolder.appendingPathComponent("test-ran.txt"), encoding: .utf8), "passed")
            // A completely new model object and CLI process must recover both
            // the native transcript and the provider's original context.
            chat.input = "Continue after reopening TheAll"
            let historyDirectory = root.appendingPathComponent("chat-history")
            let terminalID = UUID()
            let history = AIChatHistoryStore(directory: historyDirectory)
            history.save(chat.snapshot, for: terminalID) { _ in }
            history.flush()
            let beforeClose = chat.messages.map(\.text)
            let previousRequests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            let previousCount = previousRequests.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["count"] as? Int
            }.max() ?? 0
            chat.stop()
            let loaded = try XCTUnwrap(AIChatHistoryStore(directory: historyDirectory).load(for: terminalID))
            let reopened = AIChatSession(provider: provider, model: "", directory: root.path, restoring: loaded)
            defer { reopened.stop() }
            XCTAssertEqual(reopened.messages.map(\.text), beforeClose)
            XCTAssertEqual(reopened.input, "Continue after reopening TheAll")
            XCTAssertEqual(reopened.directory, nextFolder.path)
            XCTAssertEqual(reopened.model, secondModel)
            reopened.start(configuration)
            wait(20) { reopened.isReady || reopened.errorMessage != nil }
            XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "Reopened chat did not initialize")
            reopened.send()
            wait(25) { !reopened.isBusy }
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.conversationID, conversationID)
            XCTAssertEqual(reopened.messages.filter { $0.role == .user }.count, 5)
            XCTAssertEqual(reopened.messages.filter { $0.role == .assistant }.count, 5)
            let afterReopen = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            let resumedCount = afterReopen.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["count"] as? Int
            }.last ?? 0
            XCTAssertGreaterThan(resumedCount, previousCount, "Backend context must also survive reopening")

            // Inspect actual outbound API payloads, not the model's prose or
            // the SDK's settings ACK, when verifying effort changes.
            let effortModel = try XCTUnwrap(reopened.backendModels.first {
                (provider != .claude || $0.id == firstModel)
                    && $0.reasoningEfforts.contains("xhigh")
            })
            reopened.model = effortModel.id
            for effort in effortModel.reasoningEfforts + [""] {
                reopened.reasoningEffort = effort
                reopened.input = "Verify selected effort " + (effort.isEmpty ? "default" : effort)
                reopened.send()
                wait(25) { !reopened.isBusy }
                XCTAssertFalse(reopened.isBusy)
                XCTAssertNil(reopened.errorMessage)
                let payloads = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                let last = try XCTUnwrap(payloads.split(separator: "\n").last)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
                if !effort.isEmpty {
                    // Ultra belongs to Codex's client; this installed CLI
                    // emits xhigh for its underlying model request.
                    let expected = provider == .openai && effort == "ultra" ? "xhigh" : effort
                    XCTAssertEqual(payload["effort"] as? String, expected, "\(provider): selected \(effort)")
                    XCTAssertEqual(reopened.messages.last?.reasoningEffort, effort)
                    XCTAssertEqual(reopened.messages.last?.reasoningEffortVerified, provider == .claude)
                } else if provider == .openai {
                    XCTAssertEqual(payload["effort"] as? String, effortModel.defaultReasoningEffort)
                } else {
                    XCTAssertEqual(payload["effort"] as? String, "medium", "Opus 5.5 Default must clear the prior explicit max")
                }
            }
            reopened.reasoningEffort = "high"; reopened.input = "High before reopen"; reopened.send()
            wait(25) { !reopened.isBusy }; XCTAssertNil(reopened.errorMessage)
            reopened.reasoningEffort = ""; reopened.input = "Default after reopen"
            let defaultSnapshot = reopened.snapshot
            reopened.stop()
            let defaultChat = AIChatSession(provider: provider, model: "", directory: root.path, restoring: defaultSnapshot)
            defer { defaultChat.stop() }
            defaultChat.start(configuration); wait(20) { defaultChat.isReady || defaultChat.errorMessage != nil }
            XCTAssertTrue(defaultChat.isReady)
            defaultChat.send(); wait(25) { !defaultChat.isBusy }
            XCTAssertNil(defaultChat.errorMessage)
            XCTAssertEqual(defaultChat.messages.last?.reasoningEffort, provider == .claude ? "medium" : effortModel.defaultReasoningEffort)
            XCTAssertEqual(defaultChat.messages.last?.reasoningEffortVerified, provider == .claude)
        }
    }

    func testClaudeCollapsesCompletedProgressAndPreservesCanonicalFinalAnswer() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .claude, model: "model-a", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        chat.input = "Inspect this project"
        chat.send()
        pipe.emit(["type": "assistant", "message": ["id": "progress", "content": [
            ["type": "thinking", "thinking": "Inspect the tests before making changes."],
            ["type": "text", "text": "The tests are running; I am checking the implementation."],
            ["type": "tool_use", "id": "test-tool", "name": "Bash", "input": ["command": "npm test"]]
        ]]])
        pipe.emit(["type": "stream_event", "api_message_id": "final", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Tests passed."]]])
        XCTAssertFalse(chat.messages.contains(where: \.isIntermediate))
        pipe.emit(["type": "result", "subtype": "success", "terminal_reason": "completed", "stop_reason": "end_turn",
            "is_error": false, "result": "Tests passed. The implementation is ready."])
        XCTAssertTrue(chat.messages.first(where: { $0.id == "progress" })?.isIntermediate == true)
        XCTAssertTrue(chat.messages.first(where: { $0.role == .thinking })?.isIntermediate == true)
        XCTAssertEqual(chat.messages.first(where: { $0.id == "final" })?.text, "Tests passed. The implementation is ready.")
        XCTAssertFalse(chat.messages.first(where: { $0.id == "final" })?.isIntermediate ?? true)
        XCTAssertFalse(chat.messages.first(where: { $0.role == .user })?.isIntermediate ?? true)

        chat.input = "Explain the result"
        chat.send()
        pipe.emit(["type": "assistant", "message": ["id": "next", "content": [["type": "text", "text": "A follow-up answer."]]]])
        XCTAssertFalse(chat.messages.first(where: { $0.id == "next" })?.isIntermediate ?? true)
        pipe.emit(["type": "result", "is_error": false, "result": "A follow-up answer."])
        XCTAssertFalse(chat.messages.first(where: { $0.id == "final" })?.isIntermediate ?? true)
        XCTAssertTrue(chat.messages.first(where: { $0.id == "progress" })?.isIntermediate == true)

        chat.input = "One more check"
        chat.send()
        pipe.emit(["type": "assistant", "message": ["id": "only-progress", "content": [
            ["type": "text", "text": "Checking a file."],
            ["type": "tool_use", "id": "last-tool", "name": "Read", "input": ["file_path": "example.swift"]]
        ]]])
        pipe.emit(["type": "result", "is_error": false, "result": "The final answer arrived without streaming."])
        XCTAssertEqual(chat.messages.first(where: { $0.id == "only-progress" })?.text, "Checking a file.")
        XCTAssertTrue(chat.messages.first(where: { $0.id == "only-progress" })?.isIntermediate == true)
        XCTAssertEqual(chat.messages.last?.text, "The final answer arrived without streaming.")
        XCTAssertFalse(chat.messages.last?.isIntermediate ?? true)
    }

    func testCodexPhasesKeepPartialAndFinalAnswersEvenWhenProgressArrivesLast() {
        let pipe = Transport()
        let chat = AIChatSession(provider: .openai, model: "model-a", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond(); pipe.respond(["data": []]); pipe.respond(["thread": ["id": "thread"]])
        chat.input = "Inspect this project"
        chat.send(); pipe.respond(["turn": ["id": "turn"]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "reasoning", "id": "reason", "summary": ["Check the implementation."]]]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "partial", "text": "The first result is correct."]]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "commandExecution", "id": "tool", "command": "npm test", "exitCode": 0]]])
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "final", "text": "All results are correct.", "phase": "final_answer"]]])
        pipe.emit(["method": "item/started", "params": ["item": ["type": "agentMessage", "id": "progress", "text": "", "phase": "commentary"]]])
        pipe.emit(["method": "item/agentMessage/delta", "params": ["itemId": "progress", "delta": "Finishing the checks."]])
        // An older model can omit phase from the completed event; keep the
        // explicit phase from item/started and late phases in turn.items.
        pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "progress", "text": "Finishing the checks."]]])
        XCTAssertFalse(chat.messages.contains(where: \.isIntermediate))
        pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": "completed", "items": [
            ["type": "agentMessage", "id": "partial", "text": "The first result is correct.", "phase": "partial_answer"]
        ]]]])
        XCTAssertEqual(Set(chat.messages.filter(\.isIntermediate).map(\.id)), ["thinking-reason", "progress"])
        XCTAssertFalse(chat.messages.first(where: { $0.id == "partial" })?.isIntermediate ?? true)
        XCTAssertFalse(chat.messages.first(where: { $0.id == "final" })?.isIntermediate ?? true)
    }

    func testLegacyProtocolsPreserveMultipleFinalBlocksAfterLastTool() {
        for provider in [AIProvider.claude, .openai] {
            let pipe = Transport()
            let chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe)
            chat.start(configuration); pipe.respond()
            if provider == .openai { pipe.respond(["data": []]); pipe.respond(["thread": ["id": "thread"]]) }
            chat.input = "Inspect this project"
            chat.send()
            if provider == .openai { pipe.respond(["turn": ["id": "turn"]]) }
            if provider == .claude {
                pipe.emit(["type": "assistant", "message": ["id": "progress", "content": [["type": "text", "text": "Running the tests."],
                    ["type": "tool_use", "id": "tool", "name": "Bash", "input": ["command": "npm test"]]]]])
                for id in ["final-one", "final-two"] {
                    pipe.emit(["type": "assistant", "message": ["id": id, "content": [["type": "text", "text": id]]]])
                }
                pipe.emit(["type": "result", "is_error": false])
            } else {
                pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "progress", "text": "Running the tests."]]])
                pipe.emit(["method": "item/completed", "params": ["item": ["type": "commandExecution", "id": "tool", "command": "npm test", "exitCode": 0]]])
                for id in ["final-one", "final-two"] {
                    pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": id, "text": id]]])
                }
                pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": "completed"]]])
            }
            XCTAssertTrue(chat.messages.first(where: { $0.id == "progress" })?.isIntermediate == true)
            XCTAssertFalse(chat.messages.first(where: { $0.id == "final-one" })?.isIntermediate ?? true)
            XCTAssertFalse(chat.messages.first(where: { $0.id == "final-two" })?.isIntermediate ?? true)
        }
    }

    func testFailedAndInterruptedTurnsKeepTheirProgressExpanded() {
        for provider in [AIProvider.claude, .openai] {
            for interrupted in [false, true] {
                let pipe = Transport()
                let chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe)
                chat.start(configuration); pipe.respond()
                if provider == .openai { pipe.respond(["data": []]); pipe.respond(["thread": ["id": "thread"]]) }
                chat.input = "Inspect this project"
                chat.send()
                if provider == .claude {
                    pipe.emit(["type": "assistant", "message": ["id": "progress", "content": [["type": "thinking", "thinking": "Inspecting the implementation."],
                        ["type": "text", "text": "Still working."]]]])
                    pipe.emit(["type": "result", "subtype": interrupted ? "success" : "error_during_execution",
                        "terminal_reason": interrupted ? "interrupted" : "error", "is_error": !interrupted, "result": "Partial output."])
                } else {
                    pipe.respond(["turn": ["id": "turn"]])
                    pipe.emit(["method": "item/completed", "params": ["item": ["type": "reasoning", "id": "reason", "summary": ["Inspecting the implementation."]]]])
                    pipe.emit(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "progress", "text": "Still working.", "phase": "commentary"]]])
                    pipe.emit(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": interrupted ? "interrupted" : "failed"]]])
                }
                XCTAssertFalse(chat.messages.contains(where: \.isIntermediate))
                XCTAssertFalse(chat.isBusy)
            }
        }
    }

    @MainActor func testNativeChatLayoutWithModelsBelowEditorAndScrollableTranscript() throws {
        final class Store: AICredentialStore {
            func load(for provider: AIProvider) throws -> AIConnection? { AIConnection(apiKey: "fake", model: "model-a") }
            func save(_ connection: AIConnection, for provider: AIProvider) throws {}
            func delete(for provider: AIProvider) throws {}
        }
        let session = AITerminalSession(credentials: Store(), makeLaunch: { _, _ in self.configuration }, loadModels: { _, _ in
            [AIModelOption(id: "model-a", title: "Model A", reasoningEfforts: ["low", "medium", "high"]), AIModelOption(id: "model-b", title: "Model B", reasoningEfforts: ["low", "medium", "high"])]
        })
        session.choose(.claude)
        let pipe = Transport()
        session.startChat(configuration, directory: "/tmp/example-project", transport: pipe)
        pipe.respond(["models": [["value": "model-a", "displayName": "Model A", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high"]]]])
        let chat = try XCTUnwrap(session.chat)
        var submittedPrompts: [String] = []
        session.onFirstMessageSubmitted = { submittedPrompts.append($0) }
        chat.input = "Explain this project's architecture."
        chat.send(); pipe.respond()
        pipe.emit(["type": "assistant", "message": ["id": "progress-preview", "content": [
            ["type": "text", "text": "I am checking the source files and tests.\nThe session manages the backend process.\nI will summarize the result once the checks finish."],
            ["type": "tool_use", "id": "preview-read", "name": "Read", "input": ["file_path": "example.swift"]]
        ]]])
        pipe.emit(["type": "assistant", "message": ["id": "thinking-preview", "content": [["type": "thinking", "thinking": "I will check the entry point and follow how the view connects to the session."]]]])
        pipe.emit(["type": "assistant", "message": ["id": "example", "content": [["type": "text", "text": "TheAll keeps **your conversation and draft** while switching models.\n\n" + String(repeating: "The chat transcript scrolls under the pointer.\n", count: 25)]]]])
        pipe.emit(["type": "result", "session_id": "fixture-session", "is_error": false])
        for index in 0..<8 { pipe.emit(["type": "assistant", "message": ["id": "tool-preview-\(index)", "content": [["type": "tool_use", "id": "t-\(index)", "name": "Bash", "input": ["command": "ls"]]]]]) }
        chat.input = "This draft stays here when the model changes."
        let hosting = NSHostingView(rootView: AIChatView(session: session, chat: chat, onFocus: {}, onEdit: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        defer { session.back(); window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        func capture(_ name: String) {
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }

        chat.input = "How does the next conversation turn work?"
        chat.send()
        pipe.emit(["type": "assistant", "message": ["id": "second-answer", "content": [["type": "text", "text": "Each new question starts a separate round.\n\nThe divider separates this exchange from the previous answer, and the arrow at the lower right returns to the latest message."]]]])
        pipe.emit(["type": "result", "session_id": "fixture-session", "is_error": false])
        chat.input = "This draft stays here when the model changes."
        XCTAssertEqual(submittedPrompts, ["Explain this project's architecture."])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        let editor = try XCTUnwrap(editors(hosting).first(where: \.isEditable))
        XCTAssertEqual(editor.string, chat.input)
        let location = editor.convert(editor.bounds, to: hosting)
        XCTAssertGreaterThan(location.minY, 0)
        XCTAssertLessThan(location.maxY, hosting.bounds.height)
        session.selectModel("model-b")
        XCTAssertEqual(chat.input, "This draft stays here when the model changes.")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let transcript = try XCTUnwrap(scrollViews(hosting).max(by: { $0.bounds.height < $1.bounds.height }))
        let document = try XCTUnwrap(transcript.documentView)
        XCTAssertGreaterThan(document.bounds.height, transcript.contentView.bounds.height)
        let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY - transcript.contentView.bounds.height
        transcript.contentView.scroll(to: NSPoint(x: 0, y: top))
        transcript.reflectScrolledClipView(transcript.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        capture("TheAll jump button visible while reading older messages")
        let viewport = transcript.convert(transcript.bounds, to: nil)
        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
                window.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        // The first completed Progress disclosure sits directly below the question.
        let collapsedHeight = document.bounds.height
        let progressPoint = NSPoint(x: viewport.minX + 32, y: viewport.maxY - 125)
        try click(progressPoint)
        XCTAssertGreaterThan(document.bounds.height, collapsedHeight + 20)
        let expandedHeight = document.bounds.height
        capture("TheAll completed progress opened by an individual click")
        try click(progressPoint)
        // LazyVStack refines offscreen row estimates while revealing content.
        XCTAssertLessThan(document.bounds.height, expandedHeight - 20)
        // Click the lower-right control through the real view hierarchy.
        let buttonPoint = NSPoint(x: viewport.maxX - 30, y: viewport.minY + 30)
        try click(buttonPoint)
        if document.isFlipped {
            XCTAssertGreaterThanOrEqual(transcript.documentVisibleRect.maxY, document.bounds.maxY - 1)
        } else {
            XCTAssertLessThanOrEqual(transcript.documentVisibleRect.minY, document.bounds.minY + 1)
        }
        XCTAssertEqual(chat.input, "This draft stays here when the model changes.")
        capture("TheAll jump button hidden at bottom")
        session.startChat(configuration, directory: "/tmp/example-project", transport: pipe)
        pipe.respond(["models": [["value": "model-a", "displayName": "Model A", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high"]]]])
        let active = try XCTUnwrap(session.chat)
        active.input = "Explain the project."
        active.send(); pipe.respond()
        pipe.emit(["type": "assistant", "message": ["id": "active-thinking", "content": [["type": "thinking", "thinking": "I will check the entry point and trace the session lifecycle."]]]])
        hosting.rootView = AIChatView(session: session, chat: active, onFocus: {}, onEdit: {})
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        capture("TheAll active Thinking indicator")
        window.setContentSize(NSSize(width: 420, height: 640))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        capture("TheAll narrow composer")
        for (width, dark) in [(320.0, true), (420.0, false), (1152.0, true)] {
            session.theme = .systemFallback(isDark: dark)
            window.setContentSize(NSSize(width: width, height: 640))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            let input = try XCTUnwrap(editors(hosting).first(where: \.isEditable))
            let rect = input.convert(input.bounds, to: hosting)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, hosting.bounds.maxX)
            capture("TheAll aligned composer \(Int(width)) \(dark ? "dark" : "light")")
        }
    }
}
