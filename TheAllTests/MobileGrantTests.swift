import XCTest
import AppKit
@testable import TheAll

final class MobileGrantTests: XCTestCase {
    private final class Credentials: AICredentialStore {
        var loads = 0
        func load(for provider: AIProvider) throws -> AIConnection? {
            loads += 1
            return AIConnection(apiKey: "grant-fixture-secret", model: "fixture")
        }
        func save(_ connection: AIConnection, for provider: AIProvider) throws {}
        func delete(for provider: AIProvider) throws {}
    }
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var starts = 0
        var sent: [[String: Any]] = []
        var ready = true
        var holdModel = false
        var heldModelID: String?
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { starts += 1 }
        func stop() {}
        func send(_ message: [String: Any]) throws {
            sent.append(message)
            guard let request = message["request"] as? [String: Any],
                  let id = message["request_id"] as? String else { return }
            if holdModel, request["subtype"] as? String == "set_model" { heldModelID = id; return }
            if ready { acknowledge(id) }
        }
        func acknowledge(_ id: String) {
            onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": [:]]])
        }
        var userWrites: Int { sent.filter { $0["type"] as? String == "user" }.count }
    }
    private struct Fixture {
        let registry: AIChatSessionRegistry
        let api: MobileChatAPI
        let credentials: Credentials
        let pipe: Pipe
        let first: UUID
        let second: UUID
        var firstWorkspace: UUID { registry.workspaces.workspaces[0].id }
        var secondWorkspace: UUID { registry.workspaces.workspaces[1].id }
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllGrantTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    @MainActor private func fixture() throws -> Fixture {
        let key = "MobileGrantTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key + ".pwd") }
        let credentials = Credentials(), pipe = Pipe(), store = WorkspaceStore(persistenceKey: key)
        let registry = AIChatSessionRegistry(workspaces: store, directories: TerminalPwdStore(persistenceKey: key + ".pwd"),
            history: AIChatHistoryStore(directory: try directory()), makeSession: {
                AITerminalSession(credentials: credentials, makeLaunch: {
                    try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
                }, loadModels: { _, _ in [] })
            }, makeTransport: { pipe })
        let first = store.createWorkspace(name: "Shared workspace"), second = store.createWorkspace(name: "Private workspace")
        for (id, text) in [(first, "Shared conversation"), (second, "Private conversation")] {
            registry.history.save(AIChatSnapshot(provider: .claude, directory: "/tmp", model: "fixture", input: "Desktop draft",
                messages: [AIChatMessage(id: UUID().uuidString, role: .user, text: text)], conversationID: UUID().uuidString), for: id) { _ in }
        }
        registry.history.flush()
        return Fixture(registry: registry, api: MobileChatAPI(registry: registry), credentials: credentials, pipe: pipe,
                       first: first, second: second)
    }
    private func device(_ access: MobilePairingStore.Access = .init()) -> MobilePairingStore.Device {
        .init(id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!, name: "Phone", tokenHash: "fixture",
              createdAt: Date(), expiresAt: .distantFuture, access: access)
    }
    private func request(_ path: String, body: [String: Any]? = nil) throws -> MobileHTTPRequest {
        .init(method: body == nil ? "GET" : "POST", target: path, headers: [:],
              body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }
    private func body(_ api: MobileChatAPI, extra: [String: Any] = [:]) -> [String: Any] {
        ["requestId": UUID().uuidString, "bootID": api.bootID].merging(extra) { _, new in new }
    }
    private func object(_ response: MobileHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
    @MainActor private func moveFirstConversation(_ fixture: Fixture) {
        let workspaces = fixture.registry.workspaces
        // Exercise the same ownership transition as importing/moving a layout,
        // through WorkspaceStore rather than mutating its persisted state.
        let source = workspaces.workspaces[0], destination = workspaces.workspaces[1]
        workspaces.updateTabLayout(.terminal(UUID()), tabId: source.tabs[0].id, in: source.id)
        workspaces.updateTabLayout(.terminal(fixture.first), tabId: destination.tabs[0].id, in: destination.id)
    }

    func testGrantPersistsFromInvitationAndLegacyDevicesRemainWritable() throws {
        let file = try directory().appendingPathComponent("devices.json"), scope = UUID()
        let store = MobilePairingStore(file: file)
        let grant = MobilePairingStore.Access(workspaceID: scope, writable: false)
        let invitation = try store.invite(origin: "https://phone.example", access: grant)
        let (token, paired) = try store.pair(token: invitation, name: "Read-only phone", origin: "https://phone.example")
        XCTAssertEqual(paired.access, grant)
        XCTAssertEqual(MobilePairingStore(file: file).authenticate(token)?.access, grant)
        XCTAssertTrue(grant.allows(workspaceID: scope)); XCTAssertFalse(grant.allows(workspaceID: UUID()))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(device())) as? [String: Any])
        legacy.removeValue(forKey: "access"); legacy.removeValue(forKey: "origin")
        let decoded = try JSONDecoder().decode(MobilePairingStore.Device.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.access, .init()); XCTAssertNil(decoded.origin)
        legacy["access"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(MobilePairingStore.Device.self, from: JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertTrue(MobilePairingStore.Access().json["workspaceId"] is NSNull)
    }

    @MainActor func testReadGrantsFilterHistoryWithoutLaunchingOrLoadingCredentials() async throws {
        let f = try fixture()
        for writable in [false, true] {
            let scoped = device(.init(workspaceID: f.firstWorkspace, writable: writable))
            let list = await f.api.handle(try request("/api/workspaces"), device: scoped, stillAuthorized: { true })
            let items = try XCTUnwrap(object(list)["workspaces"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?["id"] as? String, f.firstWorkspace.uuidString)
            let access = try XCTUnwrap(object(list)["access"] as? [String: Any])
            XCTAssertEqual(access["writable"] as? Bool, writable)
            let allowed = await f.api.handle(try request("/api/chats/\(f.first)"), device: scoped, stillAuthorized: { true })
            XCTAssertEqual(allowed.status, 200)
            XCTAssertEqual((try object(allowed)["access"] as? [String: Any])?["workspaceId"] as? String, f.firstWorkspace.uuidString)
            let denied = await f.api.handle(try request("/api/chats/\(f.second)"), device: scoped, stillAuthorized: { true })
            XCTAssertEqual(denied.status, 403)
            XCTAssertFalse(String(decoding: denied.body, as: UTF8.self).contains("Private conversation"))
        }
        let all = await f.api.handle(try request("/api/workspaces"), device: device(.init(writable: false)), stillAuthorized: { true })
        XCTAssertEqual((try object(all)["workspaces"] as? [Any])?.count, 2)
        XCTAssertEqual(f.credentials.loads, 0); XCTAssertEqual(f.pipe.starts, 0); XCTAssertTrue(f.registry.sessions.isEmpty)
    }

    @MainActor func testEveryReadOnlyMutationIsRejectedBeforeSessionOrCredentialAccess() async throws {
        let f = try fixture()
        for scope in [nil, f.firstWorkspace] {
            let readOnly = device(.init(workspaceID: scope, writable: false))
            for path in ["/api/chats", "/api/chats/\(f.first)/send", "/api/chats/\(f.first)/answer", "/api/chats/\(f.first)/interrupt"] {
                let response = await f.api.handle(try request(path, body: body(f.api, extra: ["provider": "claude", "text": "Forbidden"])),
                    device: readOnly, stillAuthorized: { true })
                XCTAssertEqual(response.status, 403, path)
            }
        }
        XCTAssertEqual(f.registry.workspaces.workspaces.count, 2)
        XCTAssertEqual(f.credentials.loads, 0); XCTAssertEqual(f.pipe.starts, 0); XCTAssertTrue(f.registry.sessions.isEmpty)
    }

    @MainActor func testScopedWritesCannotTargetOtherWorkspaceOrCreateWorkspace() async throws {
        let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace))
        for action in ["send", "answer", "interrupt"] {
            let response = await f.api.handle(try request("/api/chats/\(f.second)/\(action)", body: body(f.api, extra: ["text": "Forbidden"])),
                device: scoped, stillAuthorized: { true })
            XCTAssertEqual(response.status, 403)
        }
        for target in [nil, f.secondWorkspace] {
            var value = body(f.api, extra: ["provider": "claude", "directory": "/tmp"])
            if let target { value["workspaceId"] = target.uuidString }
            let response = await f.api.handle(try request("/api/chats", body: value), device: scoped, stillAuthorized: { true })
            XCTAssertEqual(response.status, 403)
        }
        XCTAssertEqual(f.credentials.loads, 0); XCTAssertEqual(f.pipe.starts, 0)
        let allowed = await f.api.handle(try request("/api/chats", body: body(f.api, extra: ["provider": "claude", "directory": "/tmp",
            "workspaceId": f.firstWorkspace.uuidString])), device: scoped, stillAuthorized: { true })
        XCTAssertEqual(allowed.status, 201)
        XCTAssertEqual(f.registry.workspaces.workspaces.count, 2)
        XCTAssertEqual(f.registry.workspaces.workspaces[0].tabs.count, 2)
        XCTAssertEqual(f.registry.workspaces.workspaces[1].tabs.count, 1)
        for session in f.registry.sessions.values { session.back() }
    }

    @MainActor func testAcceptedReceiptCannotBypassDowngradeMoveOrRevocation() async throws {
        let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace))
        let session = try XCTUnwrap(f.registry.session(for: f.first)); defer { session.back() }
        let action = try request("/api/chats/\(f.first)/send", body: body(f.api, extra: ["text": "Send once"]))
        let first = await f.api.handle(action, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(first.status, 200)
        let retry = await f.api.handle(action, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(retry.body, first.body)
        var readOnly = scoped; readOnly.access = .init(workspaceID: f.firstWorkspace, writable: false)
        let downgraded = await f.api.handle(action, device: readOnly, stillAuthorized: { true })
        XCTAssertEqual(downgraded.status, 403)
        let revoked = await f.api.handle(action, device: scoped, stillAuthorized: { false })
        XCTAssertEqual(revoked.status, 401)
        moveFirstConversation(f)
        let moved = await f.api.handle(action, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(moved.status, 403)
        XCTAssertEqual(f.pipe.userWrites, 1)
    }

    @MainActor func testCreationReceiptDoesNotRevealConversationMovedOutsideGrant() async throws {
        let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace))
        let action = try request("/api/chats", body: body(f.api, extra: ["provider": "claude", "directory": "/tmp",
            "workspaceId": f.firstWorkspace.uuidString]))
        let created = await f.api.handle(action, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(created.status, 201)
        let id = try XCTUnwrap(UUID(uuidString: object(created)["id"] as! String))
        let source = f.registry.workspaces.workspaces[0], destination = f.registry.workspaces.workspaces[1]
        let tab = try XCTUnwrap(source.tabs.first { $0.layout.allTerminalIds().contains(id) })
        f.registry.workspaces.updateTabLayout(.terminal(UUID()), tabId: tab.id, in: source.id)
        f.registry.workspaces.updateTabLayout(.terminal(id), tabId: destination.tabs[0].id, in: destination.id)
        let retry = await f.api.handle(action, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(retry.status, 403)
        XCTAssertFalse(String(decoding: retry.body, as: UTF8.self).contains(id.uuidString))
        XCTAssertEqual(f.registry.workspaces.workspaces[0].tabs.count, 2)
        for session in f.registry.sessions.values { session.back() }
    }

    @MainActor func testDeletedWorkspaceCannotCreateOrReturnStaleHistory() async throws {
        let f = try fixture(), scope = f.firstWorkspace, scoped = device(.init(workspaceID: f.firstWorkspace))
        f.registry.workspaces.deleteWorkspace(id: scope)
        let history = await f.api.handle(try request("/api/chats/\(f.first)"), device: scoped, stillAuthorized: { true })
        XCTAssertEqual(history.status, 404)
        let create = await f.api.handle(try request("/api/chats", body: body(f.api, extra: ["provider": "claude", "workspaceId": scope.uuidString])),
            device: scoped, stillAuthorized: { true })
        XCTAssertEqual(create.status, 404)
        let list = await f.api.handle(try request("/api/workspaces"), device: scoped, stillAuthorized: { true })
        XCTAssertEqual((try object(list)["workspaces"] as? [Any])?.count, 0)
        XCTAssertEqual(f.credentials.loads, 0); XCTAssertEqual(f.pipe.starts, 0)
    }

    @MainActor func testScopeIsRecheckedAfterBackendHandshakeWait() async throws {
        let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace))
        f.pipe.ready = false
        let action = try request("/api/chats/\(f.first)/send", body: body(f.api, extra: ["text": "Must not submit"]))
        let operation = Task { @MainActor in await f.api.handle(action, device: scoped, stillAuthorized: { true }) }
        for _ in 0..<100 where f.pipe.starts == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(f.pipe.starts, 0)
        moveFirstConversation(f)
        let response = await operation.value
        XCTAssertEqual(response.status, 403); XCTAssertEqual(f.pipe.userWrites, 0)
        f.registry.sessions[f.first]?.back()
    }

    @MainActor func testRevocationAndScopeChangeDuringModelAcknowledgementPreventPromptWrite() async throws {
        for revoke in [false, true] {
            let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace))
            let session = try XCTUnwrap(f.registry.session(for: f.first)), chat = try XCTUnwrap(session.chat)
            defer { session.back() }
            let originalMessages = chat.messages.count
            chat.input = "Mac draft"
            f.pipe.holdModel = true
            var authorized = true
            let action = try request("/api/chats/\(f.first)/send", body: body(f.api, extra: ["text": "Must not submit", "model": "changed-model"]))
            let operation = Task { @MainActor in await f.api.handle(action, device: scoped, stillAuthorized: { authorized }) }
            for _ in 0..<100 where f.pipe.heldModelID == nil { try await Task.sleep(nanoseconds: 1_000_000) }
            let modelRequest = try XCTUnwrap(f.pipe.heldModelID)
            if revoke { authorized = false } else { moveFirstConversation(f) }
            f.pipe.acknowledge(modelRequest)
            let response = await operation.value
            XCTAssertEqual(response.status, revoke ? 401 : 403)
            XCTAssertEqual(f.pipe.userWrites, 0); XCTAssertEqual(chat.messages.count, originalMessages)
            XCTAssertEqual(chat.input, "Mac draft"); XCTAssertFalse(chat.isBusy)
        }
    }
    private func photoData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<3 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor func testPhotosRequireBothWorkspaceAccessAndMessageReferenceWithoutLaunchingCLI() async throws {
        let f = try fixture(), scoped = device(.init(workspaceID: f.firstWorkspace, writable: false))
        let image = try f.registry.history.imageStore.importImage(data: photoData(), name: "photo.png")
        let draftOnly = try f.registry.history.imageStore.importImage(data: photoData(), name: "draft.png")
        var snapshot = try XCTUnwrap(f.registry.snapshot(for: f.first))
        var message = AIChatMessage(id: UUID().uuidString, role: .user, text: "")
        message.images = [image]; snapshot.messages.append(message); snapshot.draftImages = [draftOnly]
        f.registry.history.save(snapshot, for: f.first) { _ in }; f.registry.history.flush()
        let photo = try request("/api/chats/\(f.first)/images/\(image.id)")
        let response = await f.api.handle(photo, device: scoped, stillAuthorized: { true })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, try f.registry.history.imageStore.data(for: image))
        XCTAssertEqual(response.headers["Content-Type"], image.mimeType)
        XCTAssertEqual(response.securityHeaders["Cache-Control"], "no-store")
        for (path, status) in [
            ("/api/chats/\(f.first)/images/\(draftOnly.id)", 404),
            ("/api/chats/\(f.first)/images/\(UUID())", 404),
            ("/api/chats/\(f.second)/images/\(image.id)", 403)
        ] {
            let denied = await f.api.handle(try request(path), device: scoped, stillAuthorized: { true })
            XCTAssertEqual(denied.status, status)
        }
        let otherChat = await f.api.handle(try request("/api/chats/\(f.second)/images/\(image.id)"), device: device(), stillAuthorized: { true })
        XCTAssertEqual(otherChat.status, 404, "Knowing a global image UUID does not grant access through another chat")
        let revoked = await f.api.handle(photo, device: scoped, stillAuthorized: { false })
        XCTAssertEqual(revoked.status, 401)
        let history = await f.api.handle(try request("/api/chats/\(f.first)"), device: scoped, stillAuthorized: { true })
        let messages = try XCTUnwrap(try object(history)["messages"] as? [[String: Any]])
        let images = try XCTUnwrap(messages.last?["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["id"] as? String, image.id.uuidString)
        XCTAssertNil(images.first?["data"]); XCTAssertNil(images.first?["path"])
        XCTAssertEqual(f.pipe.starts, 0); XCTAssertEqual(f.credentials.loads, 0); XCTAssertTrue(f.registry.sessions.isEmpty)
    }

    @MainActor func testPhotoOnlySendIsIdempotentAndPreservesDesktopDraftAndImages() async throws {
        let f = try fixture(), phone = device()
        let chat = try XCTUnwrap(f.registry.session(for: f.first)?.chat)
        defer { f.registry.sessions[f.first]?.back() }
        let desktopPhoto = try chat.imageStore.importImage(data: photoData(), name: "desktop.png")
        chat.input = "Mac unsent draft"; chat.draftImages = [desktopPhoto]
        let action = try request("/api/chats/\(f.first)/send", body: body(f.api,
            extra: ["text": "", "images": [["name": "phone.png", "data": try photoData().base64EncodedString()]]]))
        let first = await f.api.handle(action, device: phone, stillAuthorized: { true })
        let second = await f.api.handle(action, device: phone, stillAuthorized: { true })
        XCTAssertEqual(first.status, 200); XCTAssertEqual(second.body, first.body)
        XCTAssertEqual(f.pipe.userWrites, 1)
        XCTAssertEqual(chat.input, "Mac unsent draft"); XCTAssertEqual(chat.draftImages, [desktopPhoto])
        let sent = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(sent.text, ""); XCTAssertEqual(sent.images.count, 1); XCTAssertTrue(sent.isVisibleInTranscript)
        XCTAssertNoThrow(try chat.imageStore.data(for: XCTUnwrap(sent.images.first)))
        let imageResponse = await f.api.handle(try request("/api/chats/\(f.first)/images/\(sent.images[0].id)"), device: phone, stillAuthorized: { true })
        XCTAssertEqual(imageResponse.status, 200)
    }

    @MainActor func testInvalidPhotosAndReadOnlyUploadsNeverStartCLI() async throws {
        let f = try fixture()
        let valid = ["name": "photo.png", "data": try photoData().base64EncodedString()]
        let payloads: [Any] = [
            "not an array", Array(repeating: valid, count: 5),
            [["name": "image.svg", "data": Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8).base64EncodedString()]],
            [["name": "file.png", "data": "not base64"]],
            [["name": "large.jpg", "data": Data(repeating: 0, count: 512 * 1024 + 1).base64EncodedString()]]
        ]
        for payload in payloads {
            let response = await f.api.handle(try request("/api/chats/\(f.first)/send",
                body: body(f.api, extra: ["text": "", "images": payload])), device: device(), stillAuthorized: { true })
            XCTAssertEqual(response.status, 400)
        }
        let readOnly = await f.api.handle(try request("/api/chats/\(f.first)/send",
            body: body(f.api, extra: ["text": "", "images": [valid]])), device: device(.init(writable: false)), stillAuthorized: { true })
        XCTAssertEqual(readOnly.status, 403)
        XCTAssertEqual(f.pipe.starts, 0); XCTAssertEqual(f.credentials.loads, 0)
    }

    @MainActor func testPhotoSendRevocationDuringModelAcknowledgementDoesNotWritePrompt() async throws {
        let f = try fixture(), phone = device()
        let chat = try XCTUnwrap(f.registry.session(for: f.first)?.chat)
        defer { f.registry.sessions[f.first]?.back() }
        f.pipe.holdModel = true
        var authorized = true
        let messageCount = chat.messages.count
        let action = try request("/api/chats/\(f.first)/send", body: body(f.api,
            extra: ["text": "", "model": "changed-model", "images": [["name": "photo.png", "data": try photoData().base64EncodedString()]]]))
        let operation = Task { @MainActor in await f.api.handle(action, device: phone, stillAuthorized: { authorized }) }
        for _ in 0..<200 where f.pipe.heldModelID == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let requestID = try XCTUnwrap(f.pipe.heldModelID)
        authorized = false; f.pipe.acknowledge(requestID)
        let response = await operation.value
        XCTAssertEqual(response.status, 401); XCTAssertEqual(chat.messages.count, messageCount)
        XCTAssertEqual(f.pipe.userWrites, 0)
    }

}
