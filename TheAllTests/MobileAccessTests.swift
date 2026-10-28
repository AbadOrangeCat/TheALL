import XCTest
import AppKit
@testable import TheAll

final class MobileAccessTests: XCTestCase {
    private final class Credentials: AICredentialStore {
        func load(for provider: AIProvider) throws -> AIConnection? { AIConnection(apiKey: "mobile-test-secret", model: "fixture") }
        func save(_ connection: AIConnection, for provider: AIProvider) throws {}
        func delete(for provider: AIProvider) throws {}
    }
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var starts = 0
        var stops = 0
        var ready = true
        var failUser = false
        var failModel = false
        var failAnswer = false
        var codexTurnResult: [String: Any]?
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { starts += 1 }
        func stop() { stops += 1 }
        func send(_ message: [String: Any]) throws {
            if message["type"] as? String == "user", failUser { throw URLError(.networkConnectionLost) }
            if message["type"] as? String == "control_response", failAnswer { throw URLError(.networkConnectionLost) }
            sent.append(message)
            if ready, respondToClaudeEffortControl(message, sent: sent, reply: { onMessage?($0) }) { return }
            if let method = message["method"] as? String, let id = message["id"] as? String {
                switch method {
                case "initialize": onMessage?(["id": id, "result": [:]])
                case "model/list": onMessage?(["id": id, "result": ["data": [["model": "fixture", "isDefault": true]]]])
                case "thread/start": onMessage?(["id": id, "result": ["thread": ["id": "test-thread"]]])
                case "turn/start":
                    if let codexTurnResult { onMessage?(codexTurnResult.merging(["id": id]) { _, new in new }) }
                default: break
                }
            }
            if let request = message["request"] as? [String: Any], let id = message["request_id"] as? String, ready {
                let failed = request["subtype"] as? String == "set_model" && failModel
                onMessage?(["type": "control_response", "response": ["subtype": failed ? "error" : "success", "request_id": id, "response": [:], "error": "fixture failure"]])
            }
        }
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllMobileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    @MainActor private func registry(pipe: Pipe = Pipe()) throws -> AIChatSessionRegistry {
        let key = "MobileAccessTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key + ".pwd") }
        let store = WorkspaceStore(persistenceKey: key)
        return AIChatSessionRegistry(workspaces: store, directories: TerminalPwdStore(persistenceKey: key + ".pwd"),
            history: AIChatHistoryStore(directory: try directory()), makeSession: {
                AITerminalSession(credentials: Credentials(), makeLaunch: {
                    try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
                }, loadModels: { _, _ in [] })
            }, makeTransport: { pipe })
    }
    private var device: MobilePairingStore.Device {
        .init(id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!, name: "Test phone", tokenHash: "fake", createdAt: Date(), expiresAt: .distantFuture)
    }
    private func request(_ path: String, body: [String: Any]? = nil, origin: String = "http://127.0.0.1:49889") throws -> MobileHTTPRequest {
        .init(method: body == nil ? "GET" : "POST", target: path,
              headers: ["host": URLComponents(string: origin)!.host! + ":" + String(URLComponents(string: origin)!.port!),
                        "origin": origin, "x-theall-client": "1", "content-type": "application/json"],
              body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }
    private func object(_ response: MobileHTTPResponse) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]) }

    func testPairingIsSingleUseExpiresAndPersistsOnlyHashes() throws {
        let file = try directory().appendingPathComponent("devices.json")
        var now = Date()
        let store = MobilePairingStore(file: file, now: { now })
        let invitation = try store.invite()
        let (token, device) = try store.pair(token: invitation, name: "Phone")
        XCTAssertNotNil(store.authenticate(token))
        XCTAssertThrowsError(try store.pair(token: invitation, name: "Replay"))
        let disk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(disk.contains(token)); XCTAssertFalse(disk.contains(invitation))
        let restored = MobilePairingStore(file: file, now: { now })
        XCTAssertEqual(restored.authenticate(token)?.id, device.id)
        try restored.revoke(device.id)
        XCTAssertNil(restored.authenticate(token))
        let expired = try store.invite()
        now = now.addingTimeInterval(301)
        XCTAssertThrowsError(try store.pair(token: expired, name: "Too late"))
        now = now.addingTimeInterval(31 * 86400)
        XCTAssertNil(store.authenticate(token))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptDeviceStoreFailsClosedWithoutOverwriting() throws {
        let file = try directory().appendingPathComponent("devices.json")
        let data = Data("invalid".utf8); try data.write(to: file)
        let store = MobilePairingStore(file: file)
        XCTAssertThrowsError(try store.invite())
        XCTAssertNil(store.authenticate("anything"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testHTTPParserBoundsAndAmbiguousFraming() throws {
        let header = "POST /api/pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try MobileHTTPServer.parse(Data((header + "{").utf8)))
        XCTAssertEqual(try MobileHTTPServer.parse(Data((header + "{}").utf8))?.body, Data("{}".utf8))
        for raw in [header + "{}GET / HTTP/1.1", "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
                    "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
                    "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 999999999\r\n\r\n",
                    "GET //evil.com HTTP/1.1\r\nHost: a\r\n\r\n"] {
            XCTAssertThrowsError(try MobileHTTPServer.parse(Data(raw.utf8)))
        }
        XCTAssertThrowsError(try MobileHTTPServer.parse(Data(repeating: 65, count: 17000)))
    }

    func testHTTPSOriginValidationAndDefaultPortNormalization() throws {
        XCTAssertEqual(try MobileAccessController.origin("https://Phone.Example.com:443/"), "https://phone.example.com")
        XCTAssertEqual(try MobileAccessController.origin("https://phone.example.com:8443"), "https://phone.example.com:8443")
        for url in ["http://192.168.1.5:49831", "https://name:secret@example.com", "https://example.com/path", "https://example.com?token=123"] {
            XCTAssertThrowsError(try MobileAccessController.origin(url))
        }
    }

    @MainActor func testRegistrySharesBackendAndRemotePreservesDesktopDraft() throws {
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let id = registry.workspaces.createWorkspace(name: "Default")
        let first = try XCTUnwrap(registry.session(for: id))
        first.choose(.claude)
        let second = try XCTUnwrap(registry.session(for: id))
        let pane1 = AITerminalPaneView(session: first, managesLifecycle: false)
        let pane2 = AITerminalPaneView(session: second, managesLifecycle: false)
        XCTAssertTrue(first === second); XCTAssertTrue(pane1.session === pane2.session)
        let chat = try XCTUnwrap(first.chat)
        chat.input = "Same text"
        var result: AIChatSession.RemoteSubmissionResult?
        XCTAssertTrue(chat.sendRemote("Same text") { result = $0 })
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(chat.input, "Same text")
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(pipe.starts, 1)
        first.flushHistory()
        XCTAssertEqual(try registry.history.load(for: id)?.input, "Same text")
        registry.workspaces.deleteWorkspace(id: registry.workspaces.workspaces[0].id)
        registry.prune()
        XCTAssertNil(registry.sessions[id]); XCTAssertGreaterThan(pipe.stops, 0)
    }

    @MainActor func testRemoteSendAcknowledgesWriteAndModelFailures() throws {
        for modelFailure in [false, true] {
            let pipe = Pipe(), registry = try registry(pipe: pipe)
            let id = registry.workspaces.createWorkspace(name: "Default")
            let session = try XCTUnwrap(registry.session(for: id)); session.choose(.claude)
            let chat = try XCTUnwrap(session.chat)
            chat.input = "Mac draft"
            pipe.failUser = !modelFailure; pipe.failModel = modelFailure
            var success: AIChatSession.RemoteSubmissionResult?
            _ = chat.sendRemote("Phone draft", model: modelFailure ? "changed-model" : nil) { success = $0 }
            XCTAssertEqual(success, .rejected)
            XCTAssertEqual(chat.input, "Mac draft")
            XCTAssertTrue(chat.messages.isEmpty)
            session.back()
        }
    }

    @MainActor func testCodexLostAcknowledgementIsUncertainAndExplicitRejectionIsDefinite() async throws {
        for explicitRejection in [false, true] {
            let pipe = Pipe(), registry = try registry(pipe: pipe)
            if explicitRejection { pipe.codexTurnResult = ["error": ["message": "Model unavailable"]] }
            let id = registry.workspaces.createWorkspace(name: "Default")
            let session = try XCTUnwrap(registry.session(for: id)); session.choose(.openai)
            let chat = try XCTUnwrap(session.chat)
            XCTAssertTrue(chat.isReady)
            chat.input = "Mac draft"
            let api = MobileChatAPI(registry: registry)
            let action = try request("/api/chats/\(id)/send", body: ["bootID": api.bootID, "requestId": UUID().uuidString, "text": "Phone request"])
            let pending = Task { await api.handle(action, device: device, stillAuthorized: { true }) }
            if !explicitRejection {
                for _ in 0..<100 {
                    if pipe.sent.contains(where: { $0["method"] as? String == "turn/start" }) { break }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                XCTAssertTrue(pipe.sent.contains { $0["method"] as? String == "turn/start" })
                pipe.onExit?(1) // The request was written, but no acknowledgement arrived.
            }
            let response = await pending.value
            XCTAssertEqual(response.status, 503)
            XCTAssertEqual(try object(response)["code"] as? String, explicitRejection ? "operation_failed" : "outcome_unknown")
            let retry = await api.handle(action, device: device, stillAuthorized: { true })
            XCTAssertEqual(retry.body, response.body)
            XCTAssertEqual(pipe.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
            XCTAssertEqual(chat.input, "Mac draft")
            session.back()
        }
    }

    @MainActor func testRemoteAcknowledgementRemainsOwnedWhenTurnFinishesBeforeReply() throws {
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let id = registry.workspaces.createWorkspace(name: "Default")
        let session = try XCTUnwrap(registry.session(for: id)); session.choose(.openai)
        let chat = try XCTUnwrap(session.chat)
        var first: [AIChatSession.RemoteSubmissionResult] = [], second: [AIChatSession.RemoteSubmissionResult] = []
        XCTAssertTrue(chat.sendRemote("First") { first.append($0) })
        let requestID = try XCTUnwrap(pipe.sent.last(where: { $0["method"] as? String == "turn/start" })?["id"] as? String)
        pipe.onMessage?(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": "completed"]]])
        XCTAssertFalse(chat.isBusy)
        XCTAssertFalse(chat.sendRemote("Second") { second.append($0) })
        chat.input = "Mac draft"; chat.send()
        XCTAssertEqual(pipe.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
        pipe.onMessage?(["id": requestID, "result": ["turn": ["id": "turn"]]])
        XCTAssertEqual(first, [.accepted]); XCTAssertEqual(second, [.rejected])
        XCTAssertEqual(chat.input, "Mac draft")
        session.back()
    }

    @MainActor func testAPIHistoryDoesNotLaunchAndOneCorruptHistoryDoesNotHideOthers() async throws {
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let id = registry.workspaces.createWorkspace(name: "Saved")
        let bad = registry.workspaces.createWorkspace(name: "Damaged")
        registry.history.save(AIChatSnapshot(provider: .claude, directory: "/tmp", model: "fixture", input: "private Mac draft",
            messages: (0..<230).map { AIChatMessage(id: String($0), role: .assistant, text: "Message \($0)") }, conversationID: "saved-id"), for: id) { _ in }
        registry.history.flush()
        try Data("invalid".utf8).write(to: registry.history.directory.appendingPathComponent(bad.uuidString + ".json"))
        let api = MobileChatAPI(registry: registry)
        let list = await api.handle(try request("/api/workspaces"), device: device, stillAuthorized: { true })
        XCTAssertEqual(list.status, 200)
        let response = await api.handle(try request("/api/chats/\(id)?before=130&limit=100"), device: device, stillAuthorized: { true })
        let value = try object(response)
        XCTAssertEqual(value["start"] as? Int, 30)
        XCTAssertEqual(value["total"] as? Int, 230)
        XCTAssertEqual((value["messages"] as? [Any])?.count, 100)
        XCTAssertEqual(value["canResume"] as? Bool, true)
        XCTAssertNil(value["input"]); XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("mobile-test-secret"))
        XCTAssertEqual(pipe.starts, 0); XCTAssertTrue(registry.sessions.isEmpty)
    }

    @MainActor func testAPISendDeduplicatesAndRejectsBusyReusedAndOldBootRequests() async throws {
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let id = registry.workspaces.createWorkspace(name: "Default")
        let session = try XCTUnwrap(registry.session(for: id)); session.choose(.claude)
        let api = MobileChatAPI(registry: registry)
        var body: [String: Any] = ["requestId": UUID().uuidString, "bootID": api.bootID, "text": "Phone question"]
        let req = try request("/api/chats/\(id)/send", body: body)
        let first = await api.handle(req, device: device, stillAuthorized: { true })
        let replay = await api.handle(req, device: device, stillAuthorized: { true })
        XCTAssertEqual(first.status, 200); XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        body["text"] = "Different question"
        let reused = await api.handle(try request(req.path, body: body), device: device, stillAuthorized: { true })
        XCTAssertEqual(reused.status, 409)
        body["requestId"] = UUID().uuidString
        let busy = await api.handle(try request(req.path, body: body), device: device, stillAuthorized: { true })
        XCTAssertEqual(busy.status, 409)
        body["bootID"] = "previous-run"
        let old = await api.handle(try request(req.path, body: body), device: device, stillAuthorized: { true })
        XCTAssertEqual(old.status, 409)
        XCTAssertEqual(registry.workspaces.workspaces[0].name, "Phone question")
        session.back()
    }

    @MainActor func testAPINewConversationUsesMacCredentialsAndPersistsProvider() async throws {
        let registry = try registry(), api = MobileChatAPI(registry: registry)
        let body: [String: Any] = ["requestId": UUID().uuidString, "bootID": api.bootID, "provider": "claude", "directory": "/tmp"]
        let response = await api.handle(try request("/api/chats", body: body), device: device, stillAuthorized: { true })
        XCTAssertEqual(response.status, 201)
        let value = try object(response), id = try XCTUnwrap(UUID(uuidString: value["id"] as! String))
        XCTAssertNotEqual(value["workspaceId"] as? String, id.uuidString)
        XCTAssertEqual(registry.workspaces.workspaces.count, 1)
        XCTAssertEqual(try registry.history.load(for: id)?.provider, .claude)
        registry.sessions[id]?.back()
    }

    @MainActor func testAPIFailedSubmissionCanBeEditedAndQuestionRepliesAreNotDuplicated() async throws {
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let id = registry.workspaces.createWorkspace(name: "Default")
        let session = try XCTUnwrap(registry.session(for: id)); session.choose(.claude)
        let api = MobileChatAPI(registry: registry)
        pipe.failModel = true
        let failed = await api.handle(try request("/api/chats/\(id)/send", body: ["requestId": UUID().uuidString,
            "bootID": api.bootID, "text": "Phone draft", "model": "unavailable"]), device: device, stillAuthorized: { true })
        XCTAssertEqual(failed.status, 503)
        XCTAssertEqual(try object(failed)["code"] as? String, "operation_failed")
        pipe.failModel = false
        let sent = await api.handle(try request("/api/chats/\(id)/send", body: ["requestId": UUID().uuidString,
            "bootID": api.bootID, "text": "Edited draft", "model": "fixture"]), device: device, stillAuthorized: { true })
        XCTAssertEqual(sent.status, 200)
        pipe.onMessage?(["type": "control_request", "request_id": "question", "request": ["subtype": "can_use_tool",
            "tool_name": "AskUserQuestion", "input": ["questions": [["question": "Choose a target", "options": [["label": "Tests"]]]]]]])
        XCTAssertEqual(session.chat?.approvals.count, 1)
        let answer: [String: Any] = ["requestId": UUID().uuidString, "bootID": api.bootID, "questionId": "question",
            "allow": true, "answers": ["Choose a target": ["Tests"]]]
        pipe.failAnswer = true
        let writeFailed = await api.handle(try request("/api/chats/\(id)/answer", body: answer), device: device, stillAuthorized: { true })
        XCTAssertEqual(writeFailed.status, 503); XCTAssertEqual(session.chat?.approvals.count, 1)
        pipe.failAnswer = false
        var retry = answer; retry["requestId"] = UUID().uuidString
        let answered = await api.handle(try request("/api/chats/\(id)/answer", body: retry), device: device, stillAuthorized: { true })
        XCTAssertEqual(answered.status, 200); XCTAssertEqual(session.chat?.approvals.count, 0)
        retry["requestId"] = UUID().uuidString
        let stale = await api.handle(try request("/api/chats/\(id)/answer", body: retry), device: device, stillAuthorized: { true })
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "control_response" }.count, 1)
        session.back()
    }

    @MainActor func testControllerRejectsUnpairedCrossOriginAndRevokedClients() async throws {
        let registry = try registry(), pairing = MobilePairingStore(file: try directory().appendingPathComponent("devices.json"))
        let suite = "MobileAccessTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobileAccessController(registry: registry, pairing: pairing, defaults: defaults, port: 49889)
        controller.enable(); defer { controller.disable() }
        let unpaired = await controller.handle(try request("/api/workspaces"))
        XCTAssertEqual(unpaired.status, 401)
        let invite = try pairing.invite()
        let paired = await controller.handle(try request("/api/pair", body: ["token": invite, "deviceName": "Phone"]))
        XCTAssertEqual(paired.status, 200)
        let cookie = try XCTUnwrap(paired.headers["Set-Cookie"])
        XCTAssertTrue(cookie.contains("HttpOnly")); XCTAssertTrue(cookie.contains("SameSite=Strict"))
        var headers = try request("/api/workspaces").headers
        headers["cookie"] = cookie.components(separatedBy: ";")[0]
        let good = MobileHTTPRequest(method: "GET", target: "/api/workspaces", headers: headers, body: Data())
        let allowed = await controller.handle(good)
        XCTAssertEqual(allowed.status, 200)
        headers["origin"] = "https://attacker.example"
        let rejected = await controller.handle(.init(method: "GET", target: good.target, headers: headers, body: Data()))
        XCTAssertEqual(rejected.status, 403)
        controller.revoke(try XCTUnwrap(pairing.devices.first?.id))
        let revoked = await controller.handle(good)
        XCTAssertEqual(revoked.status, 401)
    }

    func testRelayIdentityPersistsWithoutReplacingCorruptKey() throws {
        let file = try directory().appendingPathComponent("relay.key")
        let first = try MobileRelayIdentity(file: file).key()
        let second = try MobileRelayIdentity(file: file).key()
        XCTAssertEqual(first.publicKey.rawRepresentation, second.publicKey.rawRepresentation)
        let challenge = Data(repeating: 42, count: 32)
        XCTAssertTrue(first.publicKey.isValidSignature(try second.signature(for: challenge), for: challenge))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try MobileRelayIdentity(file: file).key())
        XCTAssertEqual(try Data(contentsOf: file), Data("corrupt".utf8))
    }

    @MainActor func testRealRelayRoundTripPairCreateSendRetryAndRevoke() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("mobile-relay/node_modules/ws/package.json").path) else {
            throw XCTSkip("Run npm ci --ignore-scripts in mobile-relay before the real relay test")
        }
        let folder = try directory(), identity = MobileRelayIdentity(file: folder.appendingPathComponent("relay.key"))
        let process = Process(), output = Foundation.Pipe(), stderr = Foundation.Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("mobile-relay/test/swift-fixture.mjs").path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "THEALL_MAC_PUBLIC_KEY": try identity.key().publicKey.rawRepresentation.base64EncodedString()]
        process.standardOutput = output; process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let startup = output.fileHandleForReading.availableData
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: startup) as? [String: Any])
        let origin = try XCTUnwrap(config["origin"] as? String)
        let pipe = Pipe(), registry = try registry(pipe: pipe)
        let pairing = MobilePairingStore(file: folder.appendingPathComponent("devices.json"))
        let suite = "MobileAccessTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobileAccessController(registry: registry, pairing: pairing, defaults: defaults,
                                                port: 49888, relayIdentity: identity)
        controller.publicURL = origin
        controller.enable()
        defer { controller.disable() }
        for _ in 0..<150 {
            if controller.relayConnected && controller.isListening { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(controller.relayConnected, controller.error ?? "Relay did not connect")
        XCTAssertTrue(controller.isListening)
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.httpCookieStorage = nil
        let web = URLSession(configuration: urlConfig)
        defer { web.invalidateAndCancel() }
        var cookie = ""
        func fetch(_ path: String, body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: URL(string: origin + path)!)
            req.timeoutInterval = 10
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let body {
                req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.setValue(origin, forHTTPHeaderField: "Origin")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("1", forHTTPHeaderField: "X-TheAll-Client")
            }
            let (data, response) = try await web.data(for: req)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let (html, htmlResponse) = try await fetch("/")
        XCTAssertEqual(htmlResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("TheAll"))
        XCTAssertTrue(htmlResponse.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        let (_, unauthenticated) = try await fetch("/api/workspaces")
        XCTAssertEqual(unauthenticated.statusCode, 401)
        let invite = try pairing.invite()
        let (pairedData, pairedResponse) = try await fetch("/api/pair", body: ["token": invite, "deviceName": "Relay test"])
        XCTAssertEqual(pairedResponse.statusCode, 200)
        cookie = try XCTUnwrap(pairedResponse.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        let paired = try XCTUnwrap(JSONSerialization.jsonObject(with: pairedData) as? [String: Any])
        let boot = try XCTUnwrap(paired["bootID"] as? String)
        let (createdData, createdResponse) = try await fetch("/api/chats", body: ["requestId": UUID().uuidString,
            "bootID": boot, "provider": "claude", "directory": "/tmp"])
        XCTAssertEqual(createdResponse.statusCode, 201)
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: createdData) as? [String: Any])
        let id = try XCTUnwrap(created["id"] as? String)
        let session = try XCTUnwrap(registry.sessions[UUID(uuidString: id)!])
        session.chat?.input = "Keep the desktop draft"
        let message: [String: Any] = ["requestId": UUID().uuidString, "bootID": boot, "text": "Sent through the actual relay"]
        let (_, sent) = try await fetch("/api/chats/\(id)/send", body: message)
        let (_, retried) = try await fetch("/api/chats/\(id)/send", body: message)
        XCTAssertEqual(sent.statusCode, 200); XCTAssertEqual(retried.statusCode, 200)
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        XCTAssertEqual(session.chat?.input, "Keep the desktop draft")
        let (history, historyResponse) = try await fetch("/api/chats/\(id)")
        XCTAssertEqual(historyResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: history, as: UTF8.self).contains("Sent through the actual relay"))
        XCTAssertFalse(String(decoding: history, as: UTF8.self).contains("mobile-test-secret"))
        // A local disable/re-enable reconnects the outbound bridge and keeps
        // the same live backend and receipt ledger, without replaying a turn.
        controller.disable(); controller.enable()
        for _ in 0..<150 {
            if controller.relayConnected && controller.isListening { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(controller.relayConnected)
        let (_, reconnected) = try await fetch("/api/chats/\(id)/send", body: message)
        XCTAssertEqual(reconnected.statusCode, 200)
        XCTAssertEqual(pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        controller.revoke(try XCTUnwrap(pairing.devices.first?.id))
        let (_, revoked) = try await fetch("/api/workspaces")
        XCTAssertEqual(revoked.statusCode, 401)
        session.back()
    }
}
