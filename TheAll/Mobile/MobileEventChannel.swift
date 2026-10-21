import Foundation
import Network
import CryptoKit

/// Main-queue event channel. Text is deliberately small: history and mutations
/// continue to use authenticated HTTP. Initial events wait for the WS handshake.
final class MobileEventChannel {
    static let maximumTextBytes = 8192
    static let maximumQueuedBytes = 65536
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var transmit: ((String) -> Void)?
    private var disconnect: (() -> Void)?
    private var pending: [String] = []
    private var pendingBytes = 0
    private(set) var isClosed = false

    func send(_ text: String) {
        guard !isClosed else { return }
        guard text.utf8.count <= Self.maximumTextBytes else { close(); return }
        if let transmit { transmit(text); return }
        guard pending.count < 32, pendingBytes + text.utf8.count <= Self.maximumQueuedBytes else { close(); return }
        pending.append(text); pendingBytes += text.utf8.count
    }
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let disconnect = disconnect, notify = onClose
        transmit = nil; self.disconnect = nil; onText = nil; onClose = nil
        pending.removeAll(); pendingBytes = 0
        disconnect?(); notify?()
    }
    func activate(send: @escaping (String) -> Void, close: @escaping () -> Void) {
        guard !isClosed else { close(); return }
        transmit = send; disconnect = close
        let buffered = pending
        pending.removeAll(); pendingBytes = 0
        for text in buffered where !isClosed { send(text) }
    }
    func receive(_ text: String) {
        guard !isClosed, text.utf8.count <= Self.maximumTextBytes else { close(); return }
        onText?(text)
    }
}

/// Bounded RFC6455 text transport on the same main queue as the HTTP listener.
final class MobileWebSocketPeer {
    private let connection: NWConnection
    let channel: MobileEventChannel
    private let finished: () -> Void
    private var buffer = Data()
    private var fragmented: Data?
    private var queuedBytes = 0
    private var stopped = false
    private var lastReceived = Date()
    private var rateStarted = Date()
    private var receivedFrames = 0
    private var heartbeat: DispatchSourceTimer?

    init(connection: NWConnection, channel: MobileEventChannel, finished: @escaping () -> Void) {
        self.connection = connection; self.channel = channel; self.finished = finished
    }
    static func acceptKey(_ request: MobileHTTPRequest) -> String? {
        guard request.method == "GET", request.target == "/api/events", request.body.isEmpty,
              request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              request.headers["sec-websocket-version"] == "13",
              let key = request.headers["sec-websocket-key"], let raw = Data(base64Encoded: key), raw.count == 16,
              raw.base64EncodedString() == key else { return nil }
        return Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
    func start(acceptKey: String) {
        let handshake = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\nCache-Control: no-store\r\n\r\n".utf8)
        connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.stop(); return }
            self.channel.activate(send: { [weak self] in self?.send(opcode: 1, payload: Data($0.utf8)) }, close: { [weak self] in self?.stop() })
            guard !self.stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 25, repeating: 25)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastReceived) > 75 { self.stop(); return }
                self.send(opcode: 9, payload: Data())
            }
            self.heartbeat = timer; timer.resume()
            self.receive()
        })
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; heartbeat?.cancel(); heartbeat = nil
        connection.cancel(); channel.close(); finished()
    }
    private func send(opcode: UInt8, payload: Data) {
        guard !stopped else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255)) }
        frame.append(payload)
        guard queuedBytes + frame.count <= MobileEventChannel.maximumQueuedBytes else { stop(); return }
        queuedBytes += frame.count
        let count = frame.count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queuedBytes -= count
            if error != nil { self.stop() }
        })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            self.buffer.append(data ?? Data())
            do {
                guard self.buffer.count <= 32768 else { throw FrameError.invalid }
                while let frame = try Self.parseFrame(self.buffer) {
                    self.buffer.removeFirst(frame.consumed)
                    let now = Date()
                    if now.timeIntervalSince(self.rateStarted) >= 1 { self.rateStarted = now; self.receivedFrames = 0 }
                    self.receivedFrames += 1
                    guard self.receivedFrames <= 30 else { throw FrameError.invalid }
                    self.lastReceived = now
                    switch frame.opcode {
                    case 0:
                        guard var fragment = self.fragmented else { throw FrameError.invalid }
                        fragment.append(frame.payload)
                        guard fragment.count <= MobileEventChannel.maximumTextBytes else { throw FrameError.invalid }
                        if frame.final { self.fragmented = nil; try self.deliver(fragment) }
                        else { self.fragmented = fragment }
                    case 1:
                        guard self.fragmented == nil else { throw FrameError.invalid }
                        if frame.final { try self.deliver(frame.payload) }
                        else { self.fragmented = frame.payload }
                    case 8:
                        try Self.validateClose(frame.payload)
                        // Respond to the close handshake, then release the socket.
                        self.stopped = true; self.heartbeat?.cancel(); self.heartbeat = nil
                        let closeFrame = Data([0x88, UInt8(frame.payload.count)]) + frame.payload
                        let connection = self.connection
                        connection.send(content: closeFrame, completion: .contentProcessed { _ in connection.cancel() })
                        self.channel.close(); self.finished()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak connection = self.connection] in connection?.cancel() }
                        return
                    case 9: self.send(opcode: 10, payload: frame.payload)
                    case 10: break
                    default: throw FrameError.invalid
                    }
                    if self.stopped { return }
                }
                if complete || error != nil { self.stop() } else { self.receive() }
            } catch { self.stop() }
        }
    }
    private func deliver(_ payload: Data) throws {
        guard let text = String(data: payload, encoding: .utf8) else { throw FrameError.invalid }
        channel.receive(text)
    }
    struct Frame { let final: Bool; let opcode: UInt8; let payload: Data; let consumed: Int }
    enum FrameError: Error { case invalid }
    static func parseFrame(_ data: Data) throws -> Frame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let final = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0f
        guard bytes[0] & 0x70 == 0, [0, 1, 8, 9, 10].contains(opcode), bytes[1] & 0x80 != 0 else { throw FrameError.invalid }
        var length = Int(bytes[1] & 0x7f), offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
            guard length >= 126 else { throw FrameError.invalid }
        } else if length == 127 { throw FrameError.invalid } // Messages are capped below 65536.
        guard length <= MobileEventChannel.maximumTextBytes, opcode < 8 || (final && length <= 125) else { throw FrameError.invalid }
        guard bytes.count >= offset + 4 + length else { return nil }
        let mask = Array(bytes[offset..<(offset + 4)]); offset += 4
        let payload = Data((0..<length).map { bytes[offset + $0] ^ mask[$0 % 4] })
        return Frame(final: final, opcode: opcode, payload: payload, consumed: offset + length)
    }
    static func validateClose(_ payload: Data) throws {
        guard payload.count != 1 else { throw FrameError.invalid }
        if payload.count >= 2 {
            let bytes = [UInt8](payload), code = Int(bytes[0]) << 8 | Int(bytes[1])
            guard [1000,1001,1002,1003,1007,1008,1009,1010,1011,1012,1013,1014].contains(code) || (3000...4999).contains(code),
                  String(data: payload.dropFirst(2), encoding: .utf8) != nil else { throw FrameError.invalid }
        }
    }
}
