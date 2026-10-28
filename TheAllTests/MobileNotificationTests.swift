import XCTest
import CryptoKit
@testable import TheAll

final class MobileNotificationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllPushTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("MobileAccess")
    }
    private func subscription(endpoint: String = "https://web.push.apple.com/test", expiration: Any = NSNull(),
                              key: P256.KeyAgreement.PrivateKey = .init()) throws -> MobileWebPush.Subscription {
        try .init(json: ["endpoint": endpoint, "expirationTime": expiration,
            "keys": ["p256dh": MobileWebPush.encode(key.publicKey.x963Representation), "auth": MobileWebPush.encode(Data(repeating: 7, count: 16))]])
    }
    private func json(_ subscription: MobileWebPush.Subscription, language: String = "en") -> [String: Any] {
        ["subscription": ["endpoint": subscription.endpoint, "expirationTime": subscription.expirationTime.map { $0 as Any } ?? NSNull(),
            "keys": ["p256dh": subscription.p256dh, "auth": subscription.auth]], "language": language]
    }

    func testRFC8291EncryptionVector() throws {
        // Published test vector, RFC 8291 appendix A (not production credentials).
        let receiver = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        let subscription = try MobileWebPush.Subscription(json: ["endpoint": "https://fcm.googleapis.com/test",
            "keys": ["p256dh": receiver, "auth": "BTBZMqHH6r4Tts7J_aSIgg"]])
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: MobileWebPush.decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let plaintext = try MobileWebPush.decode("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24")
        let body = try MobileWebPush.encryptedBody(plaintext, subscription: subscription, key: privateKey,
            salt: MobileWebPush.decode("DGv6ra1nlYgDCS1FRnbzlw"))
        let header = try MobileWebPush.decode("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
        let ciphertext = try MobileWebPush.decode("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")
        XCTAssertEqual(body, header + ciphertext)
    }

    func testVAPIDClaimsSignatureAndHeaders() throws {
        let key = P256.Signing.PrivateKey(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = try MobileWebPush.request(payload: Data("{}".utf8), subscription: subscription(), signingKey: key, now: now)
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        let token = authorization.components(separatedBy: ", ")[0].dropFirst("vapid t=".count)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: MobileWebPush.decode(parts[1])) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://web.push.apple.com")
        XCTAssertEqual(claims["exp"] as? Int, 1_800_003_600)
        XCTAssertEqual(claims["sub"] as? String, "https://github.com/AbadOrangeCat/TheALL")
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: MobileWebPush.decode(parts[2])),
            for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertEqual(request.value(forHTTPHeaderField: "TTL"), "300")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Urgency"), "normal")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "aes128gcm")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRejectsUntrustedEndpointsInvalidKeysAndExpiry() throws {
        for endpoint in ["http://web.push.apple.com/test", "https://web.push.apple.com.evil.test/x", "https://127.0.0.1/x",
                         "https://fcm.googleapis.com:444/x", "https://user@fcm.googleapis.com/x", "https://fcm.googleapis.com/x#fragment",
                         "https://push.apple.com/x", "https://evilfcm.googleapis.com/x", "https://web..push.apple.com/x"] {
            XCTAssertThrowsError(try subscription(endpoint: endpoint), endpoint)
        }
        for endpoint in ["https://fcm.googleapis.com/send/test", "https://updates.push.services.mozilla.com/wpush/v2/test",
                         "https://sub.updates.push.services.mozilla.com/wpush/test", "https://web.push.apple.com/test"] {
            XCTAssertNoThrow(try subscription(endpoint: endpoint), endpoint)
        }
        XCTAssertThrowsError(try subscription(expiration: true))
        XCTAssertThrowsError(try subscription(expiration: 1))
        XCTAssertThrowsError(try MobileWebPush.Subscription(json: ["endpoint": "https://fcm.googleapis.com/x", "keys": ["p256dh": "AAA", "auth": "AA"]]))
    }

    func testPrivateFilesPersistIdentityAndPreserveCorruption() throws {
        let directory = try directory(), store = MobilePushStore(directory: directory)
        let key = try store.signingKey().rawRepresentation
        XCTAssertEqual(try MobilePushStore(directory: directory).signingKey().rawRepresentation, key)
        let keyFile = directory.appendingPathComponent("notification-vapid.key")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: keyFile)
        XCTAssertThrowsError(try MobilePushStore(directory: directory).signingKey())
        XCTAssertEqual(try Data(contentsOf: keyFile), corrupt)
        let external = directory.appendingPathComponent("outside")
        try key.write(to: external)
        try FileManager.default.removeItem(at: keyFile)
        try FileManager.default.createSymbolicLink(at: keyFile, withDestinationURL: external)
        XCTAssertThrowsError(try MobilePushStore(directory: directory).signingKey())
        XCTAssertEqual(try Data(contentsOf: external), key)
    }

    func testPrivateHTTPDoesNotCreateKeysAndEndpointIsUniquelyOwned() throws {
        let directory = try directory(), store = MobilePushStore(directory: directory)
        let service = MobileNotificationService(store: store, sender: { _ in XCTFail("No network expected"); return 201 })
        let first = UUID(), second = UUID()
        XCTAssertEqual(try service.state(deviceID: first, origin: "http://192.168.1.2:49833")["reason"] as? String, "https_required")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let value = try subscription()
        try service.subscribe(deviceID: first, origin: "https://example.test", body: json(value))
        try service.subscribe(deviceID: second, origin: "https://example.test", body: json(value, language: "zh-Hans"))
        XCTAssertEqual(try store.records().map(\.deviceID), [second])
        XCTAssertEqual(try MobilePushStore(directory: directory).records().first?.language, "zh-Hans")
        var invalid = json(value); invalid["deviceId"] = first.uuidString
        XCTAssertThrowsError(try service.subscribe(deviceID: second, origin: "https://example.test", body: invalid))
    }

    @MainActor
    func testCompletionDeduplicatesRechecksAccessAndRevocationCancelsQueuedSend() async throws {
        let store = MobilePushStore(directory: try directory()), device = UUID(), chat = UUID()
        var requests = 0, allowed = true
        let service = MobileNotificationService(store: store, sender: { _ in requests += 1; return 201 })
        service.isAuthorized = { _, id in allowed && (id == nil || id == chat) }
        try service.subscribe(deviceID: device, origin: "https://example.test", body: json(subscription()))
        let event = UUID()
        service.completed(chatID: chat, eventID: event)
        service.completed(chatID: chat, eventID: event)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(requests, 1)
        service.completed(chatID: chat, eventID: UUID())
        allowed = false
        await Task.yield(); await Task.yield()
        XCTAssertEqual(requests, 1)
        allowed = true
        service.completed(chatID: chat, eventID: UUID())
        try service.unsubscribe(deviceID: device)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testExpiredPushServiceResponseRemovesOnlyThatSubscription() async throws {
        let store = MobilePushStore(directory: try directory()), device = UUID()
        let service = MobileNotificationService(store: store, sender: { _ in 410 })
        service.isAuthorized = { _, _ in true }
        try service.subscribe(deviceID: device, origin: "https://example.test", body: json(subscription()))
        do { try await service.test(deviceID: device, origin: "https://example.test"); XCTFail("410 must not report success") } catch {}
        XCTAssertTrue(try store.records().isEmpty)
    }

    func testPayloadContainsOnlyGenericTextAndSafeConversationLink() throws {
        let chat = UUID()
        for language in MobilePushStore.languages {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: MobileNotificationService.payload(eventID: UUID(), chatID: chat, language: language)) as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["version", "id", "type", "chatId", "title", "body", "url"])
            XCTAssertEqual(payload["url"] as? String, "/?chat=" + chat.uuidString)
            XCTAssertEqual(payload["title"] as? String, "TheAll")
        }
        let test = try XCTUnwrap(JSONSerialization.jsonObject(with: MobileNotificationService.payload(eventID: UUID(), chatID: nil, language: "en")) as? [String: Any])
        XCTAssertNil(test["chatId"]); XCTAssertEqual(test["url"] as? String, "/")
    }
    func testExpiredSubscriptionsDoNotPermanentlyConsumeDeviceLimit() throws {
        let store = MobilePushStore(directory: try directory())
        let now = Date()
        for index in 0..<20 {
            let value = try subscription(endpoint: "https://web.push.apple.com/expired-\(index)", expiration: now.addingTimeInterval(60).timeIntervalSince1970 * 1000)
            _ = try store.subscribe(deviceID: UUID(), origin: "https://phone.example", language: "en", subscription: value, now: now)
        }
        XCTAssertEqual(try store.records().count, 20)
        _ = try store.subscribe(deviceID: UUID(), origin: "https://phone.example", language: "en", subscription: subscription(endpoint: "https://web.push.apple.com/new"), now: now.addingTimeInterval(120))
        XCTAssertEqual(try store.records().count, 1)
    }

}
