import Foundation
import Network
import Security

struct MobileHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    var components: URLComponents? { URLComponents(string: "http://localhost" + target) }
    var path: String { components?.path ?? "" }
}

struct MobileHTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ value: [String: Any], status: Int = 200) -> Self {
        Self(status: status, headers: ["Content-Type": "application/json; charset=utf-8"],
             body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }
    static func error(_ message: String, status: Int) -> Self { .json(["error": message], status: status) }

    var securityHeaders: [String: String] {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        headers["X-Frame-Options"] = "DENY"
        headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return headers
    }

    var encoded: Data {
        let headers = securityHeaders
        let head = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n" +
            headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        return Data(head.utf8) + body
    }
}

/// One bounded request per connection; no chunked requests or HTTP pipelining.
/// LAN HTTP requires an explicit opt-in and a private, locally bound listener.
final class MobileHTTPServer {
    static let maximumBody = 32 * 1024 * 1024
    private let queue = DispatchQueue.main
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var eventPeers: [UUID: MobileWebSocketPeer] = [:]
    private var generation = UUID()
    private var localNetworkOnly = false
    private(set) var boundPort: UInt16?
    var handler: (@MainActor (MobileHTTPRequest) async -> MobileHTTPResponse)?
    var eventHandler: (@MainActor (MobileHTTPRequest, MobileEventChannel) -> MobileHTTPResponse?)?
    var onState: ((Bool, String?) -> Void)?

    func start(port: UInt16, host: String = "127.0.0.1", identity: sec_identity_t? = nil,
               localNetworkOnly: Bool = false, allowLANHTTP: Bool = false) throws {
        stop()
        guard identity != nil || MobileLANAddress.isLoopback(host) ||
                (allowLANHTTP && localNetworkOnly && MobileLANAddress.isPrivate(host))
        else { throw URLError(.secureConnectionFailed) }
        self.localNetworkOnly = localNetworkOnly
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else { parameters = .tcp }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let current = UUID()
        generation = current
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
                self.boundPort = self.listener?.port?.rawValue
                self.onState?(true, nil)
            case .failed, .waiting:
                self.boundPort = nil
                self.onState?(false, L10n.string("mobile.error.listen"))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, generation: current) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        generation = UUID()
        let peers = Array(eventPeers.values)
        eventPeers.removeAll()
        peers.forEach { $0.stop() }
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
    }

    private func accept(_ connection: NWConnection, generation current: UUID) {
        guard generation == current, clients.count < 24, clients.count - eventPeers.count < 8 else { connection.cancel(); return }
        if localNetworkOnly {
            guard case .hostPort(let host, _) = connection.endpoint,
                  MobileLANAddress.isPrivate(String(describing: host)) || MobileLANAddress.isLoopback(String(describing: host))
            else { connection.cancel(); return }
        }
        let id = UUID()
        clients[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 180) { [weak self, weak connection] in
            guard self?.eventPeers[id] == nil else { return }
            connection?.cancel(); self?.clients[id] = nil
        }
        receive(connection, id: id, buffer: RequestBuffer())
    }

    private final class RequestBuffer { var data = Data() }

    private func receive(_ connection: NWConnection, id: UUID, buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, complete, error in
            guard let self, self.clients[id] != nil else { return }
            if let chunk { buffer.data.append(chunk) }
            do {
                if let request = try Self.parse(buffer.data) {
                    let current = self.generation
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.clients[id] != nil else { return }
                        if request.path == "/api/events" {
                            guard let key = MobileWebSocketPeer.acceptKey(request) else {
                                self.respond(.error("WebSocket upgrade required", status: 400), connection: connection, id: id); return
                            }
                            guard self.eventPeers.count < 16, let eventHandler = self.eventHandler else {
                                self.respond(.error("Events unavailable", status: 503), connection: connection, id: id); return
                            }
                            let channel = MobileEventChannel()
                            if let rejection = eventHandler(request, channel) {
                                channel.close(); self.respond(rejection, connection: connection, id: id); return
                            }
                            guard !channel.isClosed else {
                                self.respond(.error("Events unavailable", status: 503), connection: connection, id: id); return
                            }
                            let peer = MobileWebSocketPeer(connection: connection, channel: channel) { [weak self] in
                                self?.eventPeers[id] = nil; self?.clients[id] = nil
                            }
                            self.eventPeers[id] = peer
                            peer.start(acceptKey: key)
                            return
                        }
                        let response = await self.handler?(request) ?? .error("Unavailable", status: 503)
                        self.queue.async { self.respond(response, connection: connection, id: id) }
                    }
                } else if complete || error != nil {
                    self.respond(.error("Incomplete request", status: 400), connection: connection, id: id)
                } else { self.receive(connection, id: id, buffer: buffer) }
            } catch {
                self.respond(.error("Invalid request", status: 400), connection: connection, id: id)
            }
        }
    }

    private func respond(_ response: MobileHTTPResponse, connection: NWConnection, id: UUID) {
        guard clients[id] != nil else { return }
        connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.clients[id] = nil
        })
    }

    enum ParseError: Error { case invalid }
    static func parse(_ data: Data) throws -> MobileHTTPRequest? {
        guard data.count <= maximumBody + 16384 else { throw ParseError.invalid }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16384 else { throw ParseError.invalid }
            return nil
        }
        guard end.lowerBound <= 16384, let raw = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw ParseError.invalid }
        let lines = raw.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#") else { throw ParseError.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw ParseError.invalid }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[name] == nil, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ParseError.invalid }
            headers[name] = value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil else { throw ParseError.invalid }
        let lengthString = headers["content-length"] ?? "0"
        guard !lengthString.isEmpty, lengthString.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthString), length <= maximumBody,
              first[0] != "POST" || headers["content-length"] != nil else { throw ParseError.invalid }
        let total = end.upperBound + length
        guard data.count <= total else { throw ParseError.invalid }
        guard data.count == total else { return nil }
        return MobileHTTPRequest(method: String(first[0]), target: String(first[1]), headers: headers,
                                 body: Data(data[end.upperBound...]))
    }
}
