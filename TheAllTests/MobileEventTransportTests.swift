import XCTest
import Foundation
import Security
@testable import TheAll

final class MobileEventTransportTests: XCTestCase {
    private final class Trust: NSObject, URLSessionDelegate {
        let authority: SecCertificate
        init(_ authority: SecCertificate) { self.authority = authority }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
            let valid = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess &&
                SecTrustSetAnchorCertificates(trust, [authority] as CFArray) == errSecSuccess &&
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess && SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
            if valid && SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllEvents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func session(authority: SecCertificate? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config, delegate: authority.map(Trust.init), delegateQueue: nil)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw URLError(.timedOut)
    }
    private func socket(_ session: URLSession, origin: String, cookie: String) throws -> URLSessionWebSocketTask {
        let url = origin.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        var request = URLRequest(url: try XCTUnwrap(URL(string: url + "/api/events")))
        request.setValue(origin, forHTTPHeaderField: "Origin"); request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request); task.resume()
        addTeardownBlock { task.cancel(with: .goingAway, reason: nil) }
        return task
    }
    private func text(_ task: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                guard case .string(let text) = try await task.receive() else { throw URLError(.badServerResponse) }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                task.cancel(with: .goingAway, reason: nil)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            let first = try await group.next()
            return try XCTUnwrap(first)
        }
    }
    @MainActor func testTLSWebSocketDeliversQueuedHelloEchoAndClosesOnRevocation() async throws {
        let identity = try MobileLANIdentity(file: directory().appendingPathComponent("ca.json")).prepare(address: "127.0.0.1")
        let server = MobileHTTPServer(); defer { server.stop() }
        var connected: MobileEventChannel?, closed = 0
        server.eventHandler = { request, channel in
            guard request.headers["cookie"] == "device=fixture" else { return .error("Unauthorized", status: 401) }
            connected = channel; channel.onClose = { closed += 1 }
            channel.send("hello") // Before handshake: must be delivered after HTTP 101.
            channel.onText = { channel.send("echo:" + $0) }
            return nil
        }
        try server.start(port: 0, identity: identity.identity, localNetworkOnly: true)
        try await waitFor { server.boundPort != nil }
        let origin = "https://127.0.0.1:\(try XCTUnwrap(server.boundPort))", client = session(authority: identity.authorityCertificate)
        let denied = try socket(client, origin: origin, cookie: "device=wrong")
        do { _ = try await text(denied); XCTFail("Unauthenticated socket must not upgrade") } catch { XCTAssertTrue([NSURLErrorDomain, NSPOSIXErrorDomain].contains((error as NSError).domain)); XCTAssertFalse((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut) }
        XCTAssertNil(connected)
        let phone = try socket(client, origin: origin, cookie: "device=fixture")
        let hello = try await text(phone); XCTAssertEqual(hello, "hello")
        try await phone.send(.string("ping"))
        let echo = try await text(phone); XCTAssertEqual(echo, "echo:ping")
        connected?.close()
        do { _ = try await text(phone); XCTFail("Revocation must close the stream") } catch { XCTAssertTrue([NSURLErrorDomain, NSPOSIXErrorDomain].contains((error as NSError).domain)); XCTAssertFalse((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut) }
        XCTAssertEqual(closed, 1)
    }
    @MainActor func testRealSwiftRelayEventHandshakeOutputInputAndDisconnect() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("mobile-relay/node_modules/ws/package.json").path) else {
            throw XCTSkip("Run npm ci --ignore-scripts in mobile-relay")
        }
        let identity = MobileRelayIdentity(file: try directory().appendingPathComponent("relay.key"))
        let process = Process(), output = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("mobile-relay/test/swift-fixture.mjs").path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "THEALL_MAC_PUBLIC_KEY": try identity.key().publicKey.rawRepresentation.base64EncodedString()]
        process.standardOutput = output; process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.availableData) as? [String: Any])
        let origin = try XCTUnwrap(config["origin"] as? String), relay = MobileRelayClient()
        defer { relay.stop() }
        var ready = false, channel: MobileEventChannel?
        relay.onState = { ready = $0; _ = $1 }
        relay.eventHandler = { request, accepted in
            guard request.headers["cookie"] == "device=fixture" else { return .error("Unauthorized", status: 401) }
            channel = accepted; accepted.send("hello relay")
            accepted.onText = { accepted.send("reply:" + $0) }
            return nil
        }
        try relay.start(origin: origin, identity: identity)
        try await waitFor { ready }
        let client = session(), phone = try socket(client, origin: origin, cookie: "device=fixture")
        let hello = try await text(phone); XCTAssertEqual(hello, "hello relay")
        try await phone.send(.string("ping")); let pong = try await text(phone); XCTAssertEqual(pong, "reply:ping")
        channel?.send("changed"); let changed = try await text(phone); XCTAssertEqual(changed, "changed")
        relay.stop()
        do { _ = try await text(phone); XCTFail("Disconnect must close phone stream") } catch { XCTAssertTrue([NSURLErrorDomain, NSPOSIXErrorDomain].contains((error as NSError).domain)); XCTAssertFalse((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut) }
        XCTAssertTrue(try XCTUnwrap(channel).isClosed)
    }
    func testFrameParserRequiresMaskCanonicalLengthsValidControlFramesAndUTF8CloseReason() throws {
        func frame(_ bytes: [UInt8], first: UInt8 = 0x81) -> Data {
            let mask: [UInt8] = [1, 2, 3, 4]
            return Data([first, 0x80 | UInt8(bytes.count)] + mask + bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        let valid = frame(Array("hello".utf8))
        for count in 0..<valid.count { XCTAssertNil(try MobileWebSocketPeer.parseFrame(valid.prefix(count))) }
        let parsed = try XCTUnwrap(MobileWebSocketPeer.parseFrame(valid))
        XCTAssertEqual(String(data: parsed.payload, encoding: .utf8), "hello"); XCTAssertEqual(parsed.consumed, valid.count)
        XCTAssertFalse(try XCTUnwrap(MobileWebSocketPeer.parseFrame(frame([1], first: 0x01))).final)
        for malformed in [Data([0x81, 0]), Data([0xc1, 0x80]), Data([0x82, 0x80]), Data([0x81, 0xff]),
                          Data([0x81, 0xfe, 0, 1]), Data([0x81, 0xfe, 0x20, 1]), frame([], first: 0x09)] {
            XCTAssertThrowsError(try MobileWebSocketPeer.parseFrame(malformed))
        }
        for malformed in [Data([1]), Data([0x03, 0xed]), Data([0x03, 0xe8, 0xff])] { XCTAssertThrowsError(try MobileWebSocketPeer.validateClose(malformed)) }
        XCTAssertNoThrow(try MobileWebSocketPeer.validateClose(Data([0x03, 0xe8])))
    }
    func testChannelQueuesInOrderAndClosesOnUnboundedInitialOutput() {
        let channel = MobileEventChannel(); var received: [String] = [], closes = 0
        channel.send("hello"); channel.send("changed")
        XCTAssertTrue(received.isEmpty)
        channel.activate(send: { received.append($0) }, close: { closes += 1 })
        channel.send("again"); XCTAssertEqual(received, ["hello", "changed", "again"])
        channel.close(); channel.close(); channel.send("late"); XCTAssertEqual(closes, 1)
        let overflow = MobileEventChannel(); var notified = false
        overflow.onClose = { notified = true }
        for _ in 0..<33 { overflow.send("") }
        XCTAssertTrue(overflow.isClosed); XCTAssertTrue(notified)
    }
}
