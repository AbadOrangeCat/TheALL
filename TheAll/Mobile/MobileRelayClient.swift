import Foundation
import CryptoKit

/// The Mac's generated identity is pinned by the user's own relay deployment.
/// No enrollment secret is transmitted or stored on the relay.
final class MobileRelayIdentity {
    private let file: URL
    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("MobileAccess/relay-identity.key")) { self.file = file }

    func key() throws -> Curve25519.Signing.PrivateKey {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for path in [folder, file] where FileManager.default.fileExists(atPath: path.path) {
            guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.invalid }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count == 32 else { throw IdentityError.invalid }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        // Exclusive create avoids replacing an identity already pinned remotely.
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw IdentityError.invalid }
        defer { close(descriptor) }
        let data = key.rawRepresentation
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(descriptor) == 0 else { throw IdentityError.invalid }
        return key
    }
    enum IdentityError: Error { case invalid }
}

/// Outbound-only WSS bridge: no VPN, additional desktop executable or inbound
/// router port is required. HTTPS/WSS certificates use normal system validation.
final class MobileRelayClient: NSObject, URLSessionTaskDelegate {
    var onState: ((Bool, String?) -> Void)?
    var handler: (@MainActor (MobileHTTPRequest) async -> MobileHTTPResponse)?
    var eventHandler: (@MainActor (MobileHTTPRequest, MobileEventChannel) -> MobileHTTPResponse?)?
    private var events: [String: MobileEventChannel] = [:]
    private var eventWrites: [Data] = []
    private var eventWriteBytes = 0
    private var eventWriter: Task<Void, Never>?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var heartbeat: Timer?
    private var generation = UUID()
    private var endpoint: URL?
    private var signingKey: Curve25519.Signing.PrivateKey?
    private var retryDelay: UInt64 = 2
    private var authenticated = false
    private var answeredChallenge = false
    private var inFlight = Set<String>()

    func start(origin: String, identity: MobileRelayIdentity) throws {
        stop()
        guard var components = URLComponents(string: origin),
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(components.host))
        else { throw URLError(.badURL) }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/host"
        endpoint = components.url
        signingKey = try identity.key()
        generation = UUID()
        connect(generation)
    }

    func stop() {
        generation = UUID()
        closeEvents()
        reader?.cancel(); reader = nil
        reconnect?.cancel(); reconnect = nil
        heartbeat?.invalidate(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        endpoint = nil; signingKey = nil
        authenticated = false; answeredChallenge = false; inFlight.removeAll()
        retryDelay = 2
    }

    private func connect(_ current: UUID) {
        guard generation == current, let endpoint else { return }
        authenticated = false; answeredChallenge = false; inFlight.removeAll()
        onState?(false, nil)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = MobileHTTPServer.maximumBody * 2 + 16384
        socket = task
        task.resume()
        reader = Task { @MainActor [weak self, weak task] in
            guard let self, let task else { return }
            do {
                while !Task.isCancelled, self.generation == current, self.socket === task {
                    let message = try await task.receive()
                    guard self.generation == current, self.socket === task else { return }
                    try await self.receive(message, task: task, generation: current)
                }
            } catch { self.disconnected(task, generation: current) }
        }
        // Enforce an application handshake deadline, even if the TCP connection
        // succeeds but an endpoint never sends a challenge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak task] in
            guard let self, let task, self.generation == current, self.socket === task, !self.authenticated else { return }
            self.disconnected(task, generation: current)
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak task] _ in
            guard let self, let task else { return }
            task.sendPing { [weak self, weak task] error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    guard let self, let task else { return }
                    self.disconnected(task, generation: current)
                }
            }
        }
    }

    @MainActor
    private func receive(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask, generation current: UUID) async throws {
        guard generation == current, socket === task else { return }
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw URLError(.badServerResponse) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { throw URLError(.badServerResponse) }
        if type == "challenge", !answeredChallenge, !authenticated {
            guard object["protocol"] as? Int == 1, let encoded = object["nonce"] as? String,
                  let nonce = Data(base64Encoded: encoded), nonce.count == 32, let signingKey else { throw URLError(.badServerResponse) }
            answeredChallenge = true
            try await send(["type": "authenticate", "publicKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
                            "signature": signingKey.signature(for: nonce).base64EncodedString()], to: task)
        } else if type == "ready", answeredChallenge, !authenticated, object["protocol"] as? Int == 1 {
            authenticated = true; retryDelay = 2; onState?(true, nil)
        } else if type == "event_open", authenticated {
            guard let id = object["id"] as? String, UUID(uuidString: id) != nil, events[id] == nil,
                  object["method"] as? String == "GET", object["target"] as? String == "/api/events",
                  let headers = object["headers"] as? [String: String],
                  headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16384
            else { throw URLError(.badServerResponse) }
            let channel = MobileEventChannel()
            let request = MobileHTTPRequest(method: "GET", target: "/api/events", headers: headers, body: Data())
            let rejection: MobileHTTPResponse?
            if events.count >= 16 || eventHandler == nil { rejection = .error("Events unavailable", status: 503) }
            else { rejection = eventHandler?(request, channel) }
            if let rejection {
                channel.close()
                try await send(["type": "event_opened", "id": id, "status": rejection.status], to: task)
                return
            }
            guard !channel.isClosed else {
                try await send(["type": "event_opened", "id": id, "status": 503], to: task); return
            }
            events[id] = channel
            try await send(["type": "event_opened", "id": id, "status": 101], to: task)
            guard generation == current, socket === task, events[id] === channel else { channel.close(); return }
            channel.activate(send: { [weak self, weak channel] text in
                guard let self, let channel, self.events[id] === channel else { return }
                self.enqueueEvent(["type": "event_data", "id": id, "text": text])
            }, close: { [weak self] in
                guard let self, self.events.removeValue(forKey: id) != nil else { return }
                self.enqueueEvent(["type": "event_close", "id": id])
            })
        } else if type == "event_input", authenticated {
            guard let id = object["id"] as? String, let text = object["text"] as? String,
                  text.utf8.count <= MobileEventChannel.maximumTextBytes else { throw URLError(.badServerResponse) }
            events[id]?.receive(text)
        } else if type == "event_close", authenticated {
            guard let id = object["id"] as? String else { throw URLError(.badServerResponse) }
            events.removeValue(forKey: id)?.close()
        } else if type == "request", authenticated {
            guard let id = object["id"] as? String, UUID(uuidString: id) != nil, !inFlight.contains(id), inFlight.count < 32,
                  let method = object["method"] as? String, ["GET", "POST"].contains(method),
                  let target = object["target"] as? String, target.hasPrefix("/"), !target.hasPrefix("//"), target.utf8.count < 8192,
                  let headers = object["headers"] as? [String: String],
                  headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16384,
                  let encoded = object["body"] as? String, let body = Data(base64Encoded: encoded), body.count <= MobileHTTPServer.maximumBody
            else { throw URLError(.badServerResponse) }
            inFlight.insert(id)
            let request = MobileHTTPRequest(method: method, target: target, headers: headers, body: body)
            Task { @MainActor [weak self, weak task] in
                guard let self, let task, self.generation == current, self.socket === task else { return }
                var response = await self.handler?(request) ?? .error("Unavailable", status: 503)
                guard self.generation == current, self.socket === task else { return }
                if response.body.count > 16 * 1024 * 1024 { response = .error("Response too large; request fewer messages.", status: 413) }
                // Apply exactly the same browser security policy as loopback HTTP.
                let headers = response.securityHeaders
                do { try await self.send(["type": "response", "id": id, "status": response.status,
                    "headers": headers, "body": response.body.base64EncodedString()], to: task) }
                catch { self.disconnected(task, generation: current) }
                self.inFlight.remove(id)
            }
        } else { throw URLError(.badServerResponse) }
    }

    private func closeEvents() {
        let active = Array(events.values); events.removeAll()
        active.forEach { $0.close() }
        eventWriter?.cancel(); eventWriter = nil; eventWrites.removeAll(); eventWriteBytes = 0
    }
    private func enqueueEvent(_ object: [String: Any]) {
        guard let task = socket, authenticated, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let current = generation
        guard eventWrites.count < 256, eventWriteBytes + data.count <= 256 * 1024 else {
            disconnected(task, generation: current); return
        }
        eventWrites.append(data); eventWriteBytes += data.count
        guard eventWriter == nil else { return }
        eventWriter = Task { @MainActor [weak self, weak task] in
            guard let self, let task else { return }
            do {
                while !Task.isCancelled, self.generation == current, self.socket === task, !self.eventWrites.isEmpty {
                    let next = self.eventWrites.removeFirst()
                    try await task.send(.string(String(decoding: next, as: UTF8.self)))
                    guard self.generation == current, self.socket === task else { return }
                    self.eventWriteBytes -= next.count
                }
                self.eventWriter = nil
            } catch { self.disconnected(task, generation: current) }
        }
    }
    private func send(_ object: [String: Any], to task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func disconnected(_ task: URLSessionWebSocketTask, generation current: UUID) {
        guard generation == current, socket === task else { return }
        socket = nil; authenticated = false
        closeEvents()
        reader?.cancel(); heartbeat?.invalidate(); heartbeat = nil
        task.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel(); session = nil
        onState?(false, L10n.string("mobile.error.relay"))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        reconnect = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self, self.generation == current else { return }
            self.connect(current)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
