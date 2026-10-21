import XCTest
import Foundation
import Security
import Darwin
import SwiftUI
import AppKit
@testable import TheAll

final class MobileLANTests: XCTestCase {
    private final class Credentials: AICredentialStore {
        func load(for provider: AIProvider) throws -> AIConnection? { AIConnection(apiKey: "lan-fixture", model: "fixture") }
        func save(_ connection: AIConnection, for provider: AIProvider) throws {}
        func delete(for provider: AIProvider) throws {}
    }
    private final class Pipe: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var ready = true
        var starts = 0
        func start(_ configuration: AILaunchConfiguration, directory: String) throws { starts += 1 }
        func stop() {}
        func send(_ message: [String: Any]) throws {
            sent.append(message)
            if ready, let id = message["request_id"] as? String, message["request"] != nil {
                onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": [:]]])
            }
        }
    }
    private final class Addresses {
        var values: [MobileLANAddress] = [.init(interface: "fixture", address: "127.0.0.1")]
    }
    /// Trust only the fixture CA and the actual requested hostname. This does
    /// not install system trust or accept arbitrary self-signed certificates.
    private final class Trust: NSObject, URLSessionDelegate {
        let authority: SecCertificate
        init(_ authority: SecCertificate) { self.authority = authority }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil); return
            }
            let configured = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess &&
                SecTrustSetAnchorCertificates(trust, [authority] as CFArray) == errSecSuccess &&
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess &&
                SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
            if configured && SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
    private struct Fixture {
        let folder: URL
        let registry: AIChatSessionRegistry
        let controller: MobileAccessController
        let pairing: MobilePairingStore
        let identity: MobileLANIdentity
        let relayIdentity: MobileRelayIdentity
        let addresses: Addresses
        let pipe: Pipe
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllLANTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }
    @MainActor private func fixture() throws -> Fixture {
        let folder = try directory(), pipe = Pipe(), addresses = Addresses()
        let key = "MobileLANTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: key)
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".pwd")
        }
        let registry = AIChatSessionRegistry(workspaces: WorkspaceStore(persistenceKey: key),
            directories: TerminalPwdStore(persistenceKey: key + ".pwd"),
            history: AIChatHistoryStore(directory: folder.appendingPathComponent("history")),
            makeSession: { AITerminalSession(credentials: Credentials(), makeLaunch: {
                try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
            }, loadModels: { _, _ in [] }) }, makeTransport: { pipe })
        let pairing = MobilePairingStore(file: folder.appendingPathComponent("devices.json"))
        let identity = MobileLANIdentity(file: folder.appendingPathComponent("lan.json"))
        let relayIdentity = MobileRelayIdentity(file: folder.appendingPathComponent("relay.key"))
        let previewPort = try freePort()
        var lanPort = try freePort()
        while lanPort == previewPort { lanPort = try freePort() }
        let controller = MobileAccessController(registry: registry, pairing: pairing, defaults: defaults,
            port: previewPort, lanPort: lanPort, relayIdentity: relayIdentity, lanIdentity: identity,
            listAddresses: { addresses.values })
        controller.useRelay = false
        controller.setLANEnabled(true)
        return Fixture(folder: folder, registry: registry, controller: controller, pairing: pairing,
                       identity: identity, relayIdentity: relayIdentity, addresses: addresses, pipe: pipe)
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for local fixture")
        throw URLError(.timedOut)
    }
    private func web(authority: SecCertificate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration, delegate: authority.map(Trust.init), delegateQueue: nil)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }
    private func request(origin: String, path: String, body: [String: Any]? = nil, cookie: String = "") throws -> MobileHTTPRequest {
        let url = try XCTUnwrap(URLComponents(string: origin))
        let host = try XCTUnwrap(url.host) + (url.port.map { ":\($0)" } ?? "")
        return MobileHTTPRequest(method: body == nil ? "GET" : "POST", target: path,
            headers: ["host": host, "origin": origin, "x-theall-client": "1", "content-type": "application/json", "cookie": cookie],
            body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }
    private func fetch(_ session: URLSession, origin: String, path: String, body: [String: Any]? = nil,
                       cookie: String = "") async throws -> (Data, HTTPURLResponse) {
        let source = try request(origin: origin, path: path, body: body, cookie: cookie)
        var value = URLRequest(url: try XCTUnwrap(URL(string: origin + path)))
        value.httpMethod = source.method
        value.httpBody = body == nil ? nil : source.body
        for (name, content) in source.headers where name != "host" { value.setValue(content, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: value)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func invitation(_ controller: MobileAccessController) throws -> String {
        let fragment = try XCTUnwrap(URLComponents(string: XCTUnwrap(controller.pairingURL))?.fragment)
        XCTAssertTrue(fragment.hasPrefix("pair="))
        return String(fragment.dropFirst(5))
    }
    private func cookie(_ response: HTTPURLResponse) throws -> String {
        try XCTUnwrap(response.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
    }

    func testOnlyCanonicalPrivateAddressesAreEligible() {
        for value in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
            XCTAssertTrue(MobileLANAddress.isPrivate(value), value)
        }
        for value in ["8.8.8.8", "127.0.0.1", "172.15.0.1", "172.32.0.1", "192.168.1.1.", "10.0.01.1", "10.0.0", "10.0.0.999", "::1"] {
            XCTAssertFalse(MobileLANAddress.isPrivate(value), value)
        }
        XCTAssertTrue(MobileLANAddress.isLoopback("127.0.0.1"))
        XCTAssertFalse(MobileLANAddress.isLoopback("127.0.0.1."))
    }

    @MainActor func testSettingsDisplaysBothConnectionModesAndCertificateSetup() async throws {
        let fixture = try fixture(), controller = fixture.controller
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isLANListening }
        let hosting = NSHostingView(rootView: MobileAccessSectionView(theme: .systemFallback(isDark: false), controller: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        hosting.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(hosting).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.width, hosting.bounds.width + 2)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        for (name, y) in [("lan-settings-top", CGFloat(0)), ("lan-settings-bottom", max(0, document.bounds.height - scroll.contentView.bounds.height))] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("theall-" + name + ".png"))
        }
    }

    @MainActor func testRealTLSRejectsWrongAuthorityAndServesAuthenticatedSavedHistory() async throws {
        let fixture = try fixture(), controller = fixture.controller
        let id = fixture.registry.workspaces.createWorkspace(name: "Saved fixture")
        let snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "fixture", input: "Private desktop draft",
            messages: [AIChatMessage(id: UUID().uuidString, role: .user, text: "Saved question")], conversationID: "fixture-session")
        fixture.registry.history.save(snapshot, for: id) { _ in }
        fixture.registry.history.flush()
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isListening && controller.isLANListening }
        let origin = try XCTUnwrap(controller.lanURL)
        let authority = try fixture.identity.prepare(address: "127.0.0.1").authorityCertificate
        let trusted = web(authority: authority)
        let wrongAuthority = try MobileLANIdentity(file: fixture.folder.appendingPathComponent("wrong-ca.json"))
            .prepare(address: "127.0.0.1").authorityCertificate
        do {
            _ = try await fetch(web(authority: wrongAuthority), origin: origin, path: "/api/session")
            XCTFail("A client trusting another CA must not complete the TLS connection")
        } catch { XCTAssertTrue(error is URLError, "Unexpected TLS rejection: \(error)") }
        let (_, unauthenticated) = try await fetch(trusted, origin: origin, path: "/api/workspaces")
        XCTAssertEqual(unauthenticated.statusCode, 401)
        controller.createInvitation(via: .lan)
        let token = try invitation(controller)
        let (pairedData, paired) = try await fetch(trusted, origin: origin, path: "/api/pair",
            body: ["token": token, "deviceName": "TLS fixture"])
        XCTAssertEqual(paired.statusCode, 200)
        XCTAssertNotNil(try object(pairedData)["bootID"])
        let setCookie = try XCTUnwrap(paired.value(forHTTPHeaderField: "Set-Cookie"))
        for attribute in ["HttpOnly", "SameSite=Strict", "Secure"] { XCTAssertTrue(setCookie.contains(attribute)) }
        XCTAssertFalse(setCookie.contains("Domain="))
        let access = try cookie(paired)
        let (historyData, historyResponse) = try await fetch(trusted, origin: origin, path: "/api/chats/\(id)", cookie: access)
        XCTAssertEqual(historyResponse.statusCode, 200)
        let history = try object(historyData)
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["text"] as? String, "Saved question")
        XCTAssertNil(history["input"])
        XCTAssertFalse(String(decoding: historyData, as: UTF8.self).contains("Private desktop draft"))
        XCTAssertEqual(fixture.pipe.starts, 0, "Reading inactive saved history must not start an AI backend")
        let (_, privateFile) = try await fetch(trusted, origin: origin, path: "/LANIdentity.json")
        XCTAssertEqual(privateFile.statusCode, 404)
        controller.revoke(try XCTUnwrap(controller.devices.first?.id))
        let (_, revoked) = try await fetch(trusted, origin: origin, path: "/api/workspaces", cookie: access)
        XCTAssertEqual(revoked.statusCode, 401)
    }

    @MainActor func testLANAndRelayHaveSeparateOriginsAndRemainAvailableIndependently() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("mobile-relay/node_modules/ws/package.json").path) else {
            throw XCTSkip("Run npm ci --ignore-scripts in mobile-relay before the relay integration test")
        }
        let fixture = try fixture(), controller = fixture.controller
        let process = Process(), output = Foundation.Pipe(), stderr = Foundation.Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("mobile-relay/test/swift-fixture.mjs").path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "THEALL_MAC_PUBLIC_KEY": try fixture.relayIdentity.key().publicKey.rawRepresentation.base64EncodedString()]
        process.standardOutput = output; process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let startup = try object(output.fileHandleForReading.availableData)
        let relayOrigin = try XCTUnwrap(startup["origin"] as? String)
        controller.publicURL = relayOrigin; controller.useRelay = true
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isLANListening && controller.isListening && controller.relayConnected }
        let lanOrigin = try XCTUnwrap(controller.lanURL)
        let browser = web(authority: try fixture.identity.prepare(address: "127.0.0.1").authorityCertificate)
        let id = fixture.registry.workspaces.createWorkspace(name: "Shared fixture")
        controller.createInvitation(via: .lan)
        let lanToken = try invitation(controller)
        let (_, wrongEntry) = try await fetch(browser, origin: relayOrigin, path: "/api/pair",
            body: ["token": lanToken, "deviceName": "Wrong entry"])
        XCTAssertEqual(wrongEntry.statusCode, 401)
        let (lanPairData, lanPair) = try await fetch(browser, origin: lanOrigin, path: "/api/pair",
            body: ["token": lanToken, "deviceName": "LAN entry"])
        XCTAssertEqual(lanPair.statusCode, 200)
        let lanCookie = try cookie(lanPair)
        let (_, tokenMismatch) = try await fetch(browser, origin: relayOrigin, path: "/api/workspaces", cookie: lanCookie)
        XCTAssertEqual(tokenMismatch.statusCode, 401)
        let lanHostOnRelay = await controller.handle(try request(origin: lanOrigin, path: "/api/workspaces", cookie: lanCookie), via: .relay)
        let relayHostOnLAN = await controller.handle(try request(origin: relayOrigin, path: "/api/workspaces", cookie: lanCookie), via: .lan)
        XCTAssertEqual(lanHostOnRelay.status, 403); XCTAssertEqual(relayHostOnLAN.status, 403)
        var badHeaders = try request(origin: lanOrigin, path: "/api/workspaces", cookie: lanCookie).headers
        badHeaders["origin"] = relayOrigin
        let crossOrigin = await controller.handle(.init(method: "GET", target: "/api/workspaces", headers: badHeaders, body: Data()), via: .lan)
        XCTAssertEqual(crossOrigin.status, 403)
        controller.createInvitation(via: .relay)
        let (_, relayPair) = try await fetch(browser, origin: relayOrigin, path: "/api/pair",
            body: ["token": try invitation(controller), "deviceName": "Relay entry"])
        XCTAssertEqual(relayPair.statusCode, 200)
        let relayCookie = try cookie(relayPair)
        let (_, reverseMismatch) = try await fetch(browser, origin: lanOrigin, path: "/api/workspaces", cookie: relayCookie)
        XCTAssertEqual(reverseMismatch.statusCode, 401)
        let (lanData, lanResponse) = try await fetch(browser, origin: lanOrigin, path: "/api/workspaces", cookie: lanCookie)
        let (relayData, relayResponse) = try await fetch(browser, origin: relayOrigin, path: "/api/workspaces", cookie: relayCookie)
        XCTAssertEqual(lanResponse.statusCode, 200); XCTAssertEqual(relayResponse.statusCode, 200)
        XCTAssertEqual(lanData, relayData)
        XCTAssertTrue(String(decoding: lanData, as: UTF8.self).contains(id.uuidString))
        let session = try XCTUnwrap(fixture.registry.session(for: id))
        session.choose(.claude)
        defer { session.back() }
        session.chat?.input = "Preserve desktop draft"
        let submission: [String: Any] = ["requestId": UUID().uuidString,
            "bootID": try XCTUnwrap(object(lanPairData)["bootID"] as? String), "text": "Send over trusted LAN TLS"]
        let (_, sent) = try await fetch(browser, origin: lanOrigin, path: "/api/chats/\(id)/send", body: submission, cookie: lanCookie)
        let (_, repeated) = try await fetch(browser, origin: lanOrigin, path: "/api/chats/\(id)/send", body: submission, cookie: lanCookie)
        XCTAssertEqual(sent.statusCode, 200); XCTAssertEqual(repeated.statusCode, 200)
        XCTAssertEqual(fixture.pipe.sent.filter { $0["type"] as? String == "user" }.count, 1)
        XCTAssertEqual(session.chat?.input, "Preserve desktop draft")
        let (relayHistory, relayHistoryResponse) = try await fetch(browser, origin: relayOrigin, path: "/api/chats/\(id)", cookie: relayCookie)
        XCTAssertEqual(relayHistoryResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: relayHistory, as: UTF8.self).contains("Send over trusted LAN TLS"))
        controller.setLANEnabled(false)
        XCTAssertFalse(controller.isLANListening); XCTAssertNil(controller.lanURL)
        XCTAssertTrue(controller.isEnabled); XCTAssertTrue(controller.isListening); XCTAssertTrue(controller.relayConnected)
        let (_, relayAfterLANStop) = try await fetch(browser, origin: relayOrigin, path: "/api/workspaces", cookie: relayCookie)
        XCTAssertEqual(relayAfterLANStop.statusCode, 200)
        controller.setLANEnabled(true)
        try await waitFor { controller.isLANListening }
        controller.setRelayEnabled(false)
        let (_, lanAfterRelayStop) = try await fetch(browser, origin: lanOrigin, path: "/api/workspaces", cookie: lanCookie)
        XCTAssertEqual(lanAfterRelayStop.statusCode, 200)
        XCTAssertFalse(controller.relayConnected); XCTAssertTrue(controller.isListening)
    }

    @MainActor func testRelayDisconnectInvalidatesSendWaitingForBackend() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try fixture(), controller = fixture.controller
        let process = Process(), output = Foundation.Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("mobile-relay/test/swift-fixture.mjs").path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "THEALL_MAC_PUBLIC_KEY": try fixture.relayIdentity.key().publicKey.rawRepresentation.base64EncodedString()]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let origin = try XCTUnwrap(object(output.fileHandleForReading.availableData)["origin"] as? String)
        controller.publicURL = origin; controller.useRelay = true
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.relayConnected }
        controller.createInvitation(via: .relay)
        let paired = await controller.handle(try request(origin: origin, path: "/api/pair", body: [
            "token": try invitation(controller), "deviceName": "Waiting relay phone"
        ]), via: .relay)
        let cookie = try XCTUnwrap(paired.headers["Set-Cookie"]?.components(separatedBy: ";").first)
        fixture.pipe.ready = false
        let id = fixture.registry.workspaces.createWorkspace(name: "Waiting relay")
        let session = try XCTUnwrap(fixture.registry.session(for: id))
        session.choose(.claude); defer { session.back() }
        let input = try request(origin: origin, path: "/api/chats/\(id)/send", body: [
            "requestId": UUID().uuidString, "bootID": try XCTUnwrap(object(paired.body)["bootID"]),
            "text": "Must not execute after relay loss"
        ], cookie: cookie)
        let pending = Task { await controller.handle(input, via: .relay) }
        try await Task.sleep(nanoseconds: 150_000_000)
        process.terminate()
        try await waitFor { !controller.relayConnected }
        let initialize = try XCTUnwrap(fixture.pipe.sent.first?["request_id"] as? String)
        fixture.pipe.onMessage?(["type": "control_response", "response": [
            "subtype": "success", "request_id": initialize, "response": [:]
        ]])
        let response = await pending.value
        XCTAssertEqual(response.status, 401)
        XCTAssertFalse(fixture.pipe.sent.contains { $0["type"] as? String == "user" })
        XCTAssertTrue(controller.isListening, "Relay loss must leave LAN and preview independent")
    }

    @MainActor func testAddressLossCancelsInvitationAndPendingSendWithoutStoppingPreview() async throws {
        let fixture = try fixture(), controller = fixture.controller
        fixture.pipe.ready = false
        let id = fixture.registry.workspaces.createWorkspace(name: "Waiting fixture")
        let session = try XCTUnwrap(fixture.registry.session(for: id))
        session.choose(.claude)
        defer { session.back() }
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isLANListening && controller.isListening }
        let origin = try XCTUnwrap(controller.lanURL)
        controller.createInvitation(via: .lan)
        let paired = await controller.handle(try request(origin: origin, path: "/api/pair",
            body: ["token": try invitation(controller), "deviceName": "Waiting phone"]), via: .lan)
        XCTAssertEqual(paired.status, 200)
        let cookie = try XCTUnwrap(paired.headers["Set-Cookie"]?.components(separatedBy: ";").first)
        let bootID = try XCTUnwrap(object(paired.body)["bootID"] as? String)
        let submission = try request(origin: origin, path: "/api/chats/\(id)/send",
            body: ["requestId": UUID().uuidString, "bootID": bootID, "text": "Must not be sent"], cookie: cookie)
        var entered = false
        let pending = Task { @MainActor in
            entered = true
            return await controller.handle(submission, via: .lan)
        }
        try await waitFor { entered }
        XCTAssertFalse(try XCTUnwrap(session.chat).isReady)
        controller.createInvitation(via: .lan)
        let expiredInvitation = try invitation(controller)
        fixture.addresses.values = []
        controller.refreshLANAddresses()
        XCTAssertFalse(controller.isLANListening); XCTAssertNil(controller.lanURL); XCTAssertNil(controller.pairingURL)
        XCTAssertTrue(controller.isListening); XCTAssertTrue(controller.isEnabled)
        XCTAssertThrowsError(try fixture.pairing.pair(token: expiredInvitation, name: "Too late", origin: origin))
        // Restoring the identical address must not resurrect the old generation.
        fixture.addresses.values = [.init(interface: "fixture", address: "127.0.0.1")]
        controller.refreshLANAddresses()
        try await waitFor { controller.isLANListening }
        let response = await pending.value
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(fixture.pipe.sent.filter { $0["type"] as? String == "user" }.count, 0)
        XCTAssertTrue(session.chat?.messages.isEmpty == true)
        let (_, preview) = try await fetch(web(), origin: controller.localURL, path: "/api/session")
        XCTAssertEqual(preview.statusCode, 401, "The preview server stays reachable while the LAN listener is replaced")
    }
    @MainActor func testScopedLiveUpdatesPairingConfirmationPresenceAndRevocation() async throws {
        let fixture = try fixture(), controller = fixture.controller
        let first = fixture.registry.workspaces.createWorkspace(name: "Shared")
        _ = fixture.registry.workspaces.createWorkspace(name: "Hidden")
        let shared = fixture.registry.workspaces.workspaces[0].id
        let hidden = fixture.registry.workspaces.workspaces[1].id
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isLANListening }
        let origin = try XCTUnwrap(controller.lanURL)
        controller.createInvitation(via: .lan, access: .init(workspaceID: shared, writable: false))
        let response = await controller.handle(try request(origin: origin, path: "/api/pair", body: [
            "token": try invitation(controller), "deviceName": "Read-only phone"
        ]), via: .lan)
        XCTAssertEqual(response.status, 200)
        let device = try XCTUnwrap(controller.pairedDevice)
        XCTAssertEqual(device.access, .init(workspaceID: shared, writable: false))
        XCTAssertNil(controller.pairingURL)
        let cookie = try XCTUnwrap(response.headers["Set-Cookie"]?.components(separatedBy: ";").first)
        let material = try fixture.identity.prepare(address: "127.0.0.1")
        let session = web(authority: material.authorityCertificate)
        var req = URLRequest(url: try XCTUnwrap(URL(string: origin.replacingOccurrences(of: "https:", with: "wss:") + "/api/events")))
        req.setValue(origin, forHTTPHeaderField: "Origin"); req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let socket = session.webSocketTask(with: req)
        var received: [[String: Any]] = []
        socket.resume()
        let reader = Task { @MainActor in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    if case .string(let text) = message, let data = text.data(using: .utf8) {
                        received.append(try object(data))
                    }
                }
            } catch { }
        }
        defer { reader.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        try await waitFor { received.first?["type"] as? String == "hello" }
        XCTAssertEqual((received[0]["access"] as? [String: Any])?["writable"] as? Bool, false)
        XCTAssertTrue(controller.onlineDeviceIDs.contains(device.id))
        fixture.registry.workspaces.renameWorkspace(id: hidden, to: "Hidden change")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(received.count, 1, "Hidden workspace changes must not be pushed")
        fixture.registry.workspaces.renameWorkspace(id: shared, to: "Shared change")
        try await waitFor { received.contains { $0["type"] as? String == "changed" } }
        let pane = try XCTUnwrap(fixture.registry.session(for: first))
        pane.choose(.claude)
        try await Task.sleep(nanoseconds: 350_000_000)
        let previous = received.count
        pane.chat?.input = "Private desktop draft"
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(received.count, previous, "Draft changes are not a mobile event")
        pane.chat?.model = "different-model"
        try await waitFor { received.count > previous }
        controller.revoke(device.id)
        XCTAssertFalse(controller.onlineDeviceIDs.contains(device.id))
        XCTAssertNil(controller.pairedDevice)
        let denied = await controller.handle(try request(origin: origin, path: "/api/workspaces", cookie: cookie), via: .lan)
        XCTAssertEqual(denied.status, 401)
    }

    @MainActor func testEventUpgradeRejectsMissingCookieAndForeignOrigin() async throws {
        let fixture = try fixture(), controller = fixture.controller
        controller.enable(); defer { controller.disable() }
        try await waitFor { controller.isLANListening }
        let origin = try XCTUnwrap(controller.lanURL)
        let material = try fixture.identity.prepare(address: "127.0.0.1")
        let session = web(authority: material.authorityCertificate)
        for originHeader in [origin, "https://foreign.example"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: origin.replacingOccurrences(of: "https:", with: "wss:") + "/api/events")))
            request.setValue(originHeader, forHTTPHeaderField: "Origin")
            let socket = session.webSocketTask(with: request)
            socket.resume()
            let deadline = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
            do { _ = try await socket.receive(); XCTFail("Unauthenticated event stream accepted") }
            catch { }
            deadline.cancel(); socket.cancel(with: .goingAway, reason: nil)
        }
        XCTAssertTrue(controller.onlineDeviceIDs.isEmpty)
    }

}
