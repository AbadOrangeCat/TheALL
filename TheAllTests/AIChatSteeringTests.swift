import XCTest
@testable import TheAll

final class AIChatSteeringTests: XCTestCase {
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var starts = 0
        var failWrite = false
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { starts += 1 }
        func stop() {}
        func send(_ message: [String: Any]) throws {
            if failWrite { throw URLError(.cannotConnectToHost) }
            sent.append(message)
            respondToClaudeEffortControl(message, sent: sent) { onMessage?($0) }
        }
        func reply(_ value: [String: Any] = [:], to request: [String: Any]? = nil) {
            guard let request = request ?? sent.last else { return }
            if let id = request["request_id"] {
                onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
            } else if let id = request["id"] { onMessage?(["id": id, "result": value]) }
        }
        func lifecycle(_ id: String, _ state: String) {
            onMessage?(["type": "command_lifecycle", "command_uuid": id, "state": state])
        }
        func claudeResult(_ ids: [String], text: String = "Final reply") {
            onMessage?(["type": "result", "uuid": UUID().uuidString, "is_error": false,
                "subtype": "success", "result": text, "user_message_uuids": ids, "queued_turn_count": 0])
        }
        func codexResult() {
            onMessage?(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed",
                "items": [["id": "answer", "type": "agentMessage", "text": "Final answer", "phase": "final_answer"]]]]])
        }
    }
    @MainActor private func running(_ provider: AIProvider) throws -> (AIChatSession, Pipe, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Steer-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pipe = Pipe(), chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe,
            imageStore: AIChatImageStore(directory: root.appendingPathComponent("Images")))
        chat.start(AILaunchConfiguration(command: "fixture", environment: [:], executable: "/usr/bin/true"))
        pipe.reply()
        if provider == .openai { pipe.reply(["data": []]); pipe.reply(["thread": ["id": "thread"]]) }
        chat.input = "Original task"; chat.send()
        var initialID = "original"
        if provider == .openai {
            pipe.reply(["turn": ["id": "turn"]])
            pipe.onMessage?(["method": "turn/started", "params": ["threadId": "thread", "turn": ["id": "turn"]]])
        } else {
            initialID = try XCTUnwrap(pipe.sent.last(where: { $0["type"] as? String == "user" })?["uuid"] as? String)
            pipe.lifecycle(initialID, "queued")
        }
        XCTAssertTrue(chat.canSteer)
        return (chat, pipe, initialID)
    }
    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected asynchronous steer state")
    }

    @MainActor func testCodexSteersSameTurnWithFilesKeepsSettingsAndWaitsForACK() async throws {
        let (chat, pipe, _) = try running(.openai)
        defer { chat.stop() }
        let token = chat.steerToken
        var completions = 0; chat.onTurnCompleted = { _ in completions += 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        let file = try chat.fileStore.importFile(data: Data("fixture bytes".utf8), name: "notes.txt")
        chat.model = "next-model"; chat.input = "Also read this"; chat.draftFiles = [file]
        XCTAssertTrue(chat.canSend); chat.send()
        try await eventually { pipe.sent.contains { $0["method"] as? String == "turn/steer" } }
        let request = try XCTUnwrap(pipe.sent.last), params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["expectedTurnId"] as? String, "turn")
        XCTAssertEqual(params["threadId"] as? String, "thread")
        XCTAssertNil(params["model"]); XCTAssertNil(params["effort"])
        XCTAssertTrue(String(describing: params["input"]!).contains(file.id.uuidString))
        XCTAssertFalse(chat.canSteer); XCTAssertEqual(chat.input, "Also read this")
        XCTAssertEqual(chat.messages.last?.isSteering, true)
        pipe.codexResult() // Completion can overtake the steer ACK.
        XCTAssertTrue(chat.isBusy); XCTAssertEqual(completions, 0)
        pipe.reply(["turnId": "turn"], to: request)
        XCTAssertFalse(chat.isBusy); XCTAssertEqual(completions, 1)
        XCTAssertEqual(chat.input, ""); XCTAssertTrue(chat.draftFiles.isEmpty)
        XCTAssertTrue(chat.showsModelChangeHint)
        XCTAssertEqual(chat.model, "next-model"); XCTAssertNil(chat.steerToken)
        XCTAssertNotNil(token)
        XCTAssertGreaterThan(chat.messages.last?.durationMs ?? 0, 40)
        XCTAssertEqual(pipe.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertEqual(pipe.starts, 1)
        let restored = try JSONDecoder().decode(AIChatSnapshot.self, from: JSONEncoder().encode(chat.snapshot))
        XCTAssertEqual(restored.messages.filter(\.isSteering).map(\.text), ["Also read this"])
    }

    @MainActor func testCodexRejectionDoesNotStopOriginalTaskOrDiscardDraft() async throws {
        let (chat, pipe, _) = try running(.openai); defer { chat.stop() }
        chat.input = "Correction"; chat.send()
        try await eventually { pipe.sent.contains { $0["method"] as? String == "turn/steer" } }
        let request = try XCTUnwrap(pipe.sent.last)
        pipe.onMessage?(["id": request["id"]!, "error": ["message": "expected active turn mismatch"]])
        XCTAssertTrue(chat.isBusy); XCTAssertTrue(chat.canSteer)
        XCTAssertEqual(chat.input, "Correction")
        XCTAssertFalse(chat.messages.contains { $0.text == "Correction" })
        XCTAssertEqual(chat.errorMessage, "expected active turn mismatch")
        pipe.codexResult(); XCTAssertFalse(chat.isBusy)
    }

    @MainActor func testClaudeToolBoundarySteerAndFinalStreamContinuationNotifyOnlyOnce() async throws {
        for sameResult in [true, false] {
            let (chat, pipe, originalID) = try running(.claude)
            defer { chat.stop() }
            var completions = 0; chat.onTurnCompleted = { _ in completions += 1 }
            let token = chat.steerToken
            chat.input = "Use another approach"; chat.send()
            try await eventually { pipe.sent.filter { $0["type"] as? String == "user" }.count == 2 }
            let steer = try XCTUnwrap(pipe.sent.last?["uuid"] as? String)
            XCTAssertEqual(chat.input, "Use another approach")
            pipe.lifecycle(steer, "queued")
            XCTAssertEqual(chat.input, ""); XCTAssertTrue(chat.canSteer)
            if !sameResult {
                pipe.claudeResult([originalID], text: "Original reply")
                XCTAssertTrue(chat.isBusy); XCTAssertEqual(completions, 0); XCTAssertEqual(chat.steerToken, token)
            }
            pipe.lifecycle(steer, "started")
            pipe.onMessage?(["type": "user", "uuid": steer, "isReplay": true, "message": ["role": "user", "content": "Use another approach"]])
            pipe.lifecycle(steer, "completed")
            pipe.claudeResult(sameResult ? [originalID, steer] : [steer])
            XCTAssertFalse(chat.isBusy); XCTAssertEqual(completions, 1)
            XCTAssertEqual(chat.messages.filter(\.isSteering).count, 1)
            XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["Original task", "Use another approach"])
            XCTAssertEqual(pipe.starts, 1)
        }
    }

    @MainActor func testClaudeStopCancelsQueuedSteerAndDoesNotNotifyComplete() async throws {
        let (chat, pipe, originalID) = try running(.claude); defer { chat.stop() }
        var completions = 0; chat.onTurnCompleted = { _ in completions += 1 }
        chat.input = "Queued change"; chat.send()
        try await eventually { pipe.sent.filter { $0["type"] as? String == "user" }.count == 2 }
        let id = try XCTUnwrap(pipe.sent.last?["uuid"] as? String)
        pipe.lifecycle(id, "queued")
        pipe.claudeResult([originalID]); XCTAssertTrue(chat.isBusy)
        XCTAssertTrue(chat.interrupt()); XCTAssertFalse(chat.canSteer)
        let control = try XCTUnwrap(pipe.sent.last?["request"] as? [String: Any])
        XCTAssertEqual(control["cancel_queued"] as? Bool, true)
        pipe.reply(["cancelled": [id], "still_queued": []])
        pipe.lifecycle(id, "cancelled") // A later duplicate is harmless.
        XCTAssertFalse(chat.isBusy); XCTAssertEqual(completions, 0)
        XCTAssertTrue(chat.messages.first(where: { $0.id == id })?.isError == true)
        XCTAssertNil(chat.errorMessage)
    }

    @MainActor func testStaleTokenValidationAndRemoteSteerPreserveDesktopDraft() async throws {
        let (chat, pipe, _) = try running(.openai); defer { chat.stop() }
        chat.input = "Private desktop draft"
        var results: [AIChatSession.RemoteSubmissionResult] = []
        XCTAssertFalse(chat.steerRemote("Stale", expectedToken: UUID().uuidString) { results.append($0) })
        XCTAssertEqual(results, [.rejected]); results.removeAll()
        let token = try XCTUnwrap(chat.steerToken)
        XCTAssertTrue(chat.steerRemote("Phone steer", expectedToken: token) { results.append($0) })
        XCTAssertFalse(chat.steerRemote("Duplicate in flight", expectedToken: token))
        try await eventually { pipe.sent.contains { $0["method"] as? String == "turn/steer" } }
        pipe.reply(["turnId": "turn"])
        XCTAssertEqual(results, [.accepted]); XCTAssertEqual(chat.input, "Private desktop draft")
        XCTAssertTrue(chat.isBusy); pipe.codexResult()
        XCTAssertFalse(chat.steerRemote("Expired", expectedToken: token))
    }

    @MainActor func testInvalidFileAndAuthorizationLossLeaveOriginalTaskRunning() async throws {
        for revoked in [false, true] {
            let (chat, pipe, _) = try running(.openai); defer { chat.stop() }
            let file = try chat.fileStore.importFile(data: Data("bytes".utf8), name: "notes.txt")
            if !revoked { try FileManager.default.removeItem(at: chat.fileStore.url(for: file)) }
            var authorized = true, results: [AIChatSession.RemoteSubmissionResult] = []
            XCTAssertTrue(chat.steerRemote("change", files: [file], expectedToken: chat.steerToken!, stillAuthorized: { authorized }) { results.append($0) })
            if revoked { authorized = false }
            try await eventually { !results.isEmpty }
            XCTAssertEqual(results, [.rejected]); XCTAssertTrue(chat.isBusy)
            XCTAssertFalse(pipe.sent.contains { $0["method"] as? String == "turn/steer" })
            XCTAssertFalse(chat.messages.contains { $0.text == "change" })
        }
    }

    @MainActor func testTaskFinishingDuringAttachmentValidationRejectsWithoutNewTurn() async throws {
        let (chat, pipe, _) = try running(.openai); defer { chat.stop() }
        var results: [AIChatSession.RemoteSubmissionResult] = []
        chat.input = "Keep this draft"
        XCTAssertTrue(chat.steerRemote("Too late", expectedToken: chat.steerToken!) { results.append($0) })
        pipe.codexResult()
        try await eventually { !results.isEmpty }
        XCTAssertEqual(results, [.rejected]); XCTAssertEqual(chat.input, "Keep this draft")
        XCTAssertFalse(pipe.sent.contains { $0["method"] as? String == "turn/steer" })
        XCTAssertFalse(chat.isBusy)
    }

    @MainActor func testLostACKRetainsSteerAndStopResolvesOnlyOnce() async throws {
        let (chat, pipe, _) = try running(.openai)
        var results: [AIChatSession.RemoteSubmissionResult] = []
        XCTAssertTrue(chat.steerRemote("May have arrived", expectedToken: chat.steerToken!) { results.append($0) })
        try await eventually { pipe.sent.contains { $0["method"] as? String == "turn/steer" } }
        let request = try XCTUnwrap(pipe.sent.last)
        pipe.reply(["turnId": "unexpected-turn"], to: request)
        XCTAssertEqual(results, [.uncertain]); XCTAssertTrue(chat.isBusy); XCTAssertFalse(chat.canSteer)
        XCTAssertTrue(chat.messages.contains { $0.text == "May have arrived" })
        chat.stop(); pipe.reply(["turnId": "turn"], to: request)
        XCTAssertEqual(results, [.uncertain])
        XCTAssertFalse(chat.hasPendingWorkForUpdate)
    }
}
