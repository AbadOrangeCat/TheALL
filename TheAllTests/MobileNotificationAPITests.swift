import XCTest
import CryptoKit
@testable import TheAll

final class MobileNotificationAPITests: XCTestCase {
    @MainActor
    func testNotificationRoutesRequireDeviceCSRFCurrentScopeAndAllowReadOnlyDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllPushAPI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = "TheAllPushAPI." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace); UserDefaults.standard.removeObject(forKey: namespace); UserDefaults.standard.removeObject(forKey: namespace + ".pwd") }
        defaults.set(false, forKey: "theall.mobile.useRelay")
        let workspaces = WorkspaceStore(persistenceKey: namespace)
        _ = workspaces.createWorkspace(name: "Fixture")
        let owner = try XCTUnwrap(workspaces.workspaces.first?.id)
        let registry = AIChatSessionRegistry(workspaces: workspaces, directories: TerminalPwdStore(persistenceKey: namespace + ".pwd"),
                                             history: AIChatHistoryStore(directory: root.appendingPathComponent("History")))
        let pairing = MobilePairingStore(file: root.appendingPathComponent("pairing.json"))
        let pushStore = MobilePushStore(directory: root.appendingPathComponent("Push"))
        var requests = 0
        let notifications = MobileNotificationService(store: pushStore, sender: { _ in requests += 1; return 201 })
        let controller = MobileAccessController(registry: registry, pairing: pairing, defaults: defaults,
            port: 51983, notifications: notifications, listAddresses: { [] })
        controller.enable()
        defer { controller.disable() }
        let origin = controller.localURL
        let invite = try pairing.invite(origin: origin, access: .init(workspaceID: owner, writable: false))
        let (token, device) = try pairing.pair(token: invite, name: "Read only", origin: origin)
        func request(_ path: String, body: [String: Any]? = nil, token: String? = token, csrf: Bool = true) throws -> MobileHTTPRequest {
            var headers = ["host": "127.0.0.1:51983", "origin": origin, "content-type": "application/json"]
            if csrf { headers["x-theall-client"] = "1" }
            if let token { headers["cookie"] = "TheAllMobileSession=" + token }
            return MobileHTTPRequest(method: body == nil ? "GET" : "POST", target: path, headers: headers,
                body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
        }
        let unauthorized = await controller.handle(try request("/api/notifications", token: nil))
        XCTAssertEqual(unauthorized.status, 401)
        let state = await controller.handle(try request("/api/notifications"))
        XCTAssertEqual(state.status, 200)
        let stateJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: state.body) as? [String: Any])
        XCTAssertEqual(stateJSON["enabled"] as? Bool, false)
        XCTAssertNotNil(stateJSON["publicKey"])
        XCTAssertNil(stateJSON["subscription"])
        let key = P256.KeyAgreement.PrivateKey()
        let body: [String: Any] = ["language": "en", "subscription": ["endpoint": "https://web.push.apple.com/test",
            "expirationTime": NSNull(), "keys": ["p256dh": MobileWebPush.encode(key.publicKey.x963Representation),
                                                  "auth": MobileWebPush.encode(Data(repeating: 9, count: 16))]]]
        let csrfDenied = await controller.handle(try request("/api/notifications/subscribe", body: body, csrf: false))
        XCTAssertEqual(csrfDenied.status, 403)
        let subscribed = await controller.handle(try request("/api/notifications/subscribe", body: body))
        XCTAssertEqual(subscribed.status, 200) // Read-only grants may receive alerts.
        XCTAssertEqual(try pushStore.records().first?.deviceID, device.id)
        let tested = await controller.handle(try request("/api/notifications/test", body: [:]))
        XCTAssertEqual(tested.status, 200); XCTAssertEqual(requests, 1)
        workspaces.deleteWorkspace(id: owner)
        let deletedScope = await controller.handle(try request("/api/notifications"))
        XCTAssertEqual(deletedScope.status, 403)
        let deletedScopeSubscribe = await controller.handle(try request("/api/notifications/subscribe", body: body))
        XCTAssertEqual(deletedScopeSubscribe.status, 403)
        controller.revoke(device.id)
        XCTAssertTrue(try pushStore.records().isEmpty)
        let revoked = await controller.handle(try request("/api/notifications"))
        XCTAssertEqual(revoked.status, 401)
    }
}
