import XCTest
@testable import TheAll

// Most transport fixtures acknowledge SDK settings automatically. Focused
// readback tests opt out so they can delay, reject or clamp individual replies.
@discardableResult
func respondToClaudeEffortControl(_ message: [String: Any], sent: [[String: Any]], reply: ([String: Any]) -> Void) -> Bool {
    guard let request = message["request"] as? [String: Any], let id = message["request_id"] else { return false }
    let subtype = request["subtype"] as? String
    guard subtype == "apply_flag_settings" || subtype == "get_settings" else { return false }
    let latest = sent.reversed().compactMap { $0["request"] as? [String: Any] }.first { $0["subtype"] as? String == "apply_flag_settings" }
    let effort = (latest?["settings"] as? [String: Any])?["effortLevel"] as? String ?? "medium"
    let response: [String: Any] = subtype == "get_settings" ? ["applied": ["effort": effort]] : [:]
    reply(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    return true
}

final class AICompletionTests: XCTestCase {
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var automaticSettings = true
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func send(_ value: [String: Any]) throws {
            sent.append(value)
            if automaticSettings { respondToClaudeEffortControl(value, sent: sent) { onMessage?($0) } }
        }
        func stop() {}
        func respond(_ value: [String: Any] = [:]) {
            guard let request = sent.last else { return }
            if let id = request["request_id"] {
                onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
            } else if let id = request["id"] { onMessage?(["id": id, "result": value]) }
        }
    }
    private let configuration = AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true")

    func testClaudeCompletionEmitsOnceAndTimingSurvivesRestoreWithoutReplay() throws {
        let pipe = Pipe()
        let session = AIChatSession(provider: .claude, model: "fixture", directory: "/tmp", transport: pipe)
        var events: [UUID] = []
        session.onTurnCompleted = { events.append($0) }
        session.start(configuration); pipe.respond()
        session.input = "first"; session.send()
        let result: [String: Any] = ["type": "result", "uuid": "result-1", "session_id": "conversation", "subtype": "success", "result": "Done"]
        pipe.onMessage?(["type": "result", "uuid": "child-result", "parent_tool_use_id": "subagent", "subtype": "success", "result": "Child done"])
        XCTAssertTrue(session.isBusy); XCTAssertEqual(events.count, 0)
        pipe.onMessage?(result); pipe.onMessage?(result)
        XCTAssertEqual(events.count, 1)
        let message = try XCTUnwrap(session.messages.last)
        XCTAssertNotNil(message.completedAt); XCTAssertGreaterThanOrEqual(try XCTUnwrap(message.durationMs), 0)
        let encoded = try JSONEncoder().encode(session.snapshot)
        let snapshot = try JSONDecoder().decode(AIChatSnapshot.self, from: encoded)
        XCTAssertEqual(snapshot.messages.last?.completedAt, message.completedAt)
        let restoredPipe = Pipe()
        let restored = AIChatSession(provider: .claude, model: "fixture", directory: "/tmp", transport: restoredPipe, restoring: snapshot)
        restored.onTurnCompleted = { events.append($0) }
        restored.start(configuration); restoredPipe.respond(); restoredPipe.onMessage?(result)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(restored.messages.last?.completedAt, message.completedAt)
        session.input = "second"; session.send()
        pipe.onMessage?(result) // A delayed duplicate from the previous turn.
        XCTAssertTrue(session.isBusy); XCTAssertEqual(events.count, 1)
        pipe.onMessage?(["type": "result", "uuid": "result-2", "subtype": "success", "result": "Second done"])
        XCTAssertEqual(events.count, 2)
        session.stop(); restored.stop()
    }

    func testClaudeErrorsStopAndRejectedModelNeverNotify() {
        let pipe = Pipe()
        let chat = AIChatSession(provider: .claude, model: "fixture", directory: "/tmp", transport: pipe)
        var events = 0
        chat.onTurnCompleted = { _ in events += 1 }
        chat.start(configuration); pipe.respond()
        chat.input = "error"; chat.send()
        pipe.onMessage?(["type": "result", "uuid": "failed", "is_error": true, "subtype": "error_during_execution"])
        XCTAssertEqual(events, 0)
        chat.input = "interrupt"; chat.send()
        XCTAssertTrue(chat.interrupt())
        pipe.onMessage?(["type": "result", "uuid": "interrupted", "subtype": "success", "result": "Partial result"])
        XCTAssertEqual(events, 0)
        chat.model = "unavailable"; chat.input = "keep draft"; chat.send()
        let id = pipe.sent.last?["request_id"] ?? "missing"
        pipe.onMessage?(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "unavailable"]])
        XCTAssertEqual(events, 0); XCTAssertEqual(chat.input, "keep draft")
        chat.stop(); pipe.onExit?(0)
        XCTAssertEqual(events, 0)
    }

    func testCodexCurrentAcceptedTurnOnlyAndInterruptedOrForeignTurnsDoNotNotify() {
        let pipe = Pipe()
        let session = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: pipe)
        var events = 0
        session.onTurnCompleted = { _ in events += 1 }
        session.start(configuration); pipe.respond()
        pipe.respond(["data": [["isDefault": true, "model": "fixture"]]])
        pipe.respond(["thread": ["id": "thread"], "model": "fixture"])
        session.input = "first"; session.send(); pipe.respond(["turn": ["id": "turn-1"]])
        pipe.onMessage?(["method": "turn/completed", "params": ["threadId": "foreign", "turn": ["id": "turn-1", "status": "completed"]]])
        XCTAssertEqual(events, 0)
        let completed: [String: Any] = ["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn-1", "status": "completed", "items": [["type": "agentMessage", "id": "answer", "text": "Done", "phase": "final_answer"]]]]]
        pipe.onMessage?(completed); pipe.onMessage?(completed)
        XCTAssertEqual(events, 1); XCTAssertNotNil(session.messages.last?.completedAt)
        session.input = "second"; session.send(); pipe.respond(["turn": ["id": "turn-2"]])
        pipe.onMessage?(completed)
        XCTAssertTrue(session.isBusy); XCTAssertEqual(events, 1)
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "turn-2", "status": "interrupted"]]])
        XCTAssertEqual(events, 1)
        // A resumed/hook turn with no local submitted request has no token.
        pipe.onMessage?(["method": "turn/started", "params": ["turn": ["id": "restored"]]])
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "restored", "status": "completed"]]])
        XCTAssertEqual(events, 1)
        session.stop()
    }

    func testLegacyMessageHasNoInventedTiming() throws {
        let value = try JSONDecoder().decode(AIChatMessage.self, from: Data("{\"id\":\"old\",\"role\":\"assistant\",\"text\":\"Historical reply\"}".utf8))
        XCTAssertNil(value.completedAt); XCTAssertNil(value.durationMs)
    }

    func testClaudeEffortWaitsForAcknowledgementAndDefaultClearsPriorOverride() throws {
        let pipe = Pipe()
        pipe.automaticSettings = false
        let session = AIChatSession(provider: .claude, model: "claude-opus-fixture", directory: "/tmp", transport: pipe)
        session.start(configuration)
        pipe.respond(["models": [["value": "opus", "resolvedModel": "claude-opus-fixture", "displayName": "Fixture", "supportsEffort": true, "supportedEffortLevels": ["low", "high", "xhigh"]]]])
        session.catalogModels = [.init(id: "claude-opus-fixture", title: "Claude Opus Fixture")]
        XCTAssertEqual(session.supportedReasoningEfforts, ["low", "high", "xhigh"])
        session.reasoningEffort = "xhigh"; session.input = "xhigh effort"; session.send()
        let request = try XCTUnwrap(pipe.sent.last?["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
        XCTAssertEqual((request["settings"] as? [String: Any])?["effortLevel"] as? String, "xhigh")
        XCTAssertEqual(session.input, "xhigh effort")
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        pipe.respond()
        XCTAssertEqual((pipe.sent.last?["request"] as? [String: Any])?["subtype"] as? String, "get_settings")
        XCTAssertEqual(session.input, "xhigh effort")
        pipe.respond(["applied": ["effort": "xhigh"]])
        XCTAssertEqual(session.input, "")
        pipe.onMessage?(["type": "result", "uuid": "effort-one", "subtype": "success", "result": "Done"])
        session.reasoningEffort = ""; session.input = "default effort"; session.send()
        let reset = try XCTUnwrap(pipe.sent.last?["request"] as? [String: Any])
        XCTAssertTrue((reset["settings"] as? [String: Any])?["effortLevel"] is NSNull)
        let id = pipe.sent.last?["request_id"] ?? "missing"
        pipe.onMessage?(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "unsupported flag"]])
        XCTAssertEqual(session.input, "default effort")
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        session.reasoningEffort = "max"; session.send()
        XCTAssertEqual(session.input, "default effort")
        XCTAssertFalse(session.isBusy)
        session.stop()
    }

    func testCapabilitiesComeFromExactModelAndSnapshotPreservesEffort() throws {
        let backend = AIModelOption.cliModels([
            ["value": "default", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high"]],
            ["value": "alias", "supportsEffort": true, "supportedEffortLevels": ["medium", "high"]],
            ["value": "custom", "supportsEffort": true]
        ], provider: .claude)
        let merged = AIModelOption.merge(catalog: [.init(id: "full-id", title: "Model"), .init(id: "alias", title: "Alias")], backend: backend)
        XCTAssertEqual(merged.first { $0.id == "" }?.reasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(merged.first { $0.id == "full-id" }?.reasoningEfforts, [])
        XCTAssertEqual(merged.first { $0.id == "alias" }?.reasoningEfforts, ["medium", "high"])
        XCTAssertEqual(merged.first { $0.id == "custom" }?.reasoningEfforts, [])
        let codex = AIModelOption.cliModels([["model": "codex", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]], "defaultReasoningEffort": "low"]], provider: .openai)
        XCTAssertEqual(codex.first?.defaultReasoningEffort, "low")
        let page = try JSONDecoder().decode(AIModelCatalog.Page.self, from: Data("{\"data\":[{\"id\":\"full-id\",\"capabilities\":{\"effort\":{\"supported\":true,\"low\":{\"supported\":true},\"medium\":{\"supported\":false},\"high\":{\"supported\":true},\"max\":{\"supported\":false}}}}]}".utf8))
        XCTAssertEqual(page.data.first?.capabilities?.effort?.levels, ["low", "high"])
        let snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "alias", input: "draft", messages: [], conversationID: nil, reasoningEffort: "high")
        let restored = try JSONDecoder().decode(AIChatSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.reasoningEffort, "high")
    }

    func testCodexEffortCapturesTurnAndUsesAdvertisedDefaultToReset() {
        let pipe = Pipe()
        let chat = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        pipe.respond(["data": [["model": "fixture", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]], "defaultReasoningEffort": "low"]]])
        pipe.respond(["thread": ["id": "thread"], "model": "fixture"])
        chat.reasoningEffort = "high"; chat.input = "high"; chat.send()
        XCTAssertEqual((pipe.sent.last?["params"] as? [String: Any])?["effort"] as? String, "high")
        chat.reasoningEffort = ""
        pipe.respond(["turn": ["id": "turn-high"]])
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "turn-high", "status": "completed"]]])
        chat.input = "default"; chat.send()
        XCTAssertEqual((pipe.sent.last?["params"] as? [String: Any])?["effort"] as? String, "low")
        pipe.respond(["turn": ["id": "turn-default"]])
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "turn-default", "status": "completed"]]])
        XCTAssertFalse(chat.sendRemote("bad selection", reasoningEffort: "max"))
        XCTAssertEqual(chat.reasoningEffort, "")
        chat.stop()
    }
    func testCodexAppliedEffortSurvivesDefaultDraftAndRestart() throws {
        let pipe = Pipe()
        let chat = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: pipe)
        let models: [String: Any] = ["data": [["model": "fixture", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "high"]]]]]
        chat.start(configuration); pipe.respond(); pipe.respond(models); pipe.respond(["thread": ["id": "thread"], "model": "fixture"])
        chat.reasoningEffort = "high"; chat.input = "first"; chat.send(); pipe.respond(["turn": ["id": "first"]])
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "first", "status": "completed"]]])
        chat.reasoningEffort = ""
        let snapshot = try JSONDecoder().decode(AIChatSnapshot.self, from: JSONEncoder().encode(chat.snapshot))
        XCTAssertEqual(snapshot.codexAppliedReasoningEffort, "high")
        chat.stop()
        let restoredPipe = Pipe()
        let restored = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: restoredPipe, restoring: snapshot)
        restored.start(configuration); restoredPipe.respond(); restoredPipe.respond(models); restoredPipe.respond(["thread": ["id": "thread"], "model": "fixture"])
        restored.input = "keep draft"; restored.send()
        XCTAssertEqual(restored.input, "keep draft"); XCTAssertNotNil(restored.errorMessage)
        XCTAssertFalse(restoredPipe.sent.contains { $0["method"] as? String == "turn/start" })
        restored.stop()
    }

    func testCodexFailureAndExternalInterruptionHaveDistinctCompletionStatus() {
        for status in ["failed", "interrupted"] {
            let pipe = Pipe()
            let chat = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: pipe)
            var notifications = 0; chat.onTurnCompleted = { _ in notifications += 1 }
            chat.start(configuration); pipe.respond(); pipe.respond(["data": [["model": "fixture", "isDefault": true]]]); pipe.respond(["thread": ["id": "thread"], "model": "fixture"])
            chat.input = "start"; chat.send(); pipe.respond(["turn": ["id": "turn"]])
            pipe.onMessage?(["method": "item/completed", "params": ["item": ["id": "answer", "type": "agentMessage", "text": "Partial answer"]]])
            if status == "failed" { pipe.onMessage?(["method": "error", "params": ["error": ["message": "Fixture failure"]]]) }
            pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": status]]])
            XCTAssertEqual(chat.messages.last?.completionStatus, status)
            XCTAssertNotNil(chat.messages.last?.durationMs); XCTAssertEqual(notifications, 0)
            chat.stop()
        }
    }

    func testClaudeReadbackRejectsClampsBeforeSubmissionAndRecordsActualTurnEffort() throws {
        let pipe = Pipe(); pipe.automaticSettings = false
        let chat = AIChatSession(provider: .claude, model: "opus", directory: "/tmp", transport: pipe)
        chat.start(configuration)
        pipe.respond(["models": [["value": "opus", "supportsEffort": true, "supportedEffortLevels": ["high", "xhigh"]]]])
        chat.reasoningEffort = "xhigh"; chat.input = "Keep this draft"; chat.send()
        pipe.respond()
        pipe.respond(["applied": ["effort": "high"]])
        XCTAssertEqual(chat.input, "Keep this draft")
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        XCTAssertTrue(chat.errorMessage?.contains("xhigh") == true)
        XCTAssertFalse(chat.isBusy)
        chat.send(); pipe.respond(); pipe.respond(["applied": ["effort": NSNull()]])
        XCTAssertEqual(chat.input, "Keep this draft")
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        chat.send(); pipe.respond(); pipe.respond(["applied": ["effort": "xhigh"]])
        XCTAssertEqual(chat.input, "")
        chat.reasoningEffort = "high"
        pipe.onMessage?(["type": "result", "subtype": "success", "result": "Done"])
        XCTAssertEqual(chat.messages.last?.reasoningEffort, "xhigh")
        XCTAssertTrue(chat.messages.last?.reasoningEffortVerified == true)
        let restored = try JSONDecoder().decode(AIChatSnapshot.self, from: JSONEncoder().encode(chat.snapshot))
        XCTAssertEqual(restored.messages.last?.reasoningEffort, "xhigh")
        XCTAssertTrue(restored.messages.last?.reasoningEffortVerified == true)
        let label = AIChatCompletionLabel.text(for: try XCTUnwrap(restored.messages.last), locale: Locale(identifier: "en"))
        XCTAssertTrue(label?.contains("xhigh") == true)
        chat.reasoningEffort = "xhigh"; chat.input = "Another turn"; chat.send()
        XCTAssertEqual((pipe.sent.last?["request"] as? [String: Any])?["subtype"] as? String, "apply_flag_settings")
        pipe.respond(); pipe.respond(["applied": ["effort": "high"]])
        XCTAssertEqual(chat.input, "Another turn")
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        chat.stop()
    }

    func testClaudeMissingReadbackPreservesDraftInsteadOfClaimingVerified() {
        let pipe = Pipe(); pipe.automaticSettings = false
        let chat = AIChatSession(provider: .claude, model: "fixture", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        chat.input = "Default must be checked"; chat.send(); pipe.respond(); pipe.respond()
        XCTAssertEqual(chat.input, "Default must be checked")
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        chat.stop()
    }

    func testCodexRejectedEffortDoesNotBlockAnUnknownDefault() {
        let pipe = Pipe()
        let chat = AIChatSession(provider: .openai, model: "fixture", directory: "/tmp", transport: pipe)
        chat.start(configuration); pipe.respond()
        pipe.respond(["data": [["model": "fixture", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "high"]]]]])
        pipe.respond(["thread": ["id": "thread"], "model": "fixture"])
        chat.reasoningEffort = "high"; chat.input = "Rejected turn"; chat.send()
        pipe.onMessage?(["id": pipe.sent.last!["id"]!, "error": ["message": "Rejected"]])
        XCTAssertNil(chat.snapshot.codexAppliedReasoningEffort)
        chat.model = "unknown"; chat.reasoningEffort = ""; chat.input = "Retry with default"; chat.send()
        XCTAssertEqual(pipe.sent.last?["method"] as? String, "turn/start")
        XCTAssertTrue((pipe.sent.last?["params"] as? [String: Any])?["effort"] is NSNull)
        pipe.respond(["turn": ["id": "next"]]); chat.stop()
    }

    func testClaudeResolvedModelCapabilitiesDoNotLeakAcrossVersions() {
        let backend = AIModelOption.cliModels([
            ["value": "default", "resolvedModel": "claude-opus-fixture", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "max"]],
            ["value": "opus", "resolvedModel": "claude-opus-fixture", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high"]]
        ], provider: .claude)
        let merged = AIModelOption.merge(catalog: [.init(id: "claude-opus-fixture", title: "Claude Opus"), .init(id: "claude-opus-older", title: "Older Opus")], backend: backend)
        XCTAssertEqual(merged.first { $0.id == "claude-opus-fixture" }?.reasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(merged.first { $0.id == "claude-opus-fixture" }?.title, "Claude Opus")
        XCTAssertEqual(merged.first { $0.id == "claude-opus-older" }?.reasoningEfforts, [])
        XCTAssertEqual(merged.filter { $0.id == "claude-opus-fixture" }.count, 1)
    }

}
