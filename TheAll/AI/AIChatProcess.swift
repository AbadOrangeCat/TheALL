import Darwin
import Foundation

protocol AIChatTransport: AnyObject {
    var onMessage: (([String: Any]) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    func start(_ configuration: AILaunchConfiguration, directory: String) throws
    func send(_ message: [String: Any]) throws
    /// Throws only before admission. An admitted send completes once on the main
    /// queue; failure may mean a partial write and must not be blindly retried.
    func send(_ message: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) throws
    func stop()
}

extension AIChatTransport {
    func send(_ message: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) throws {
        try send(message)
        completion(.success(()))
    }
}

/// Newline JSON over private pipes. Never uses a shell, PTY, or user's stdin.
final class AIChatProcess: AIChatTransport {
    static let maximumMessageBytes = 16 * 1_024 * 1_024
    static let maximumPendingBytes = 32 * 1_024 * 1_024
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var process: Process?
    private var writer: InputWriter?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let queue = DispatchQueue(label: "TheAll.ai-json")
    private let writeTimeout: TimeInterval
    private var generation = UUID()
    private final class OutputBuffer { var data = Data() }

    init(writeTimeout: TimeInterval = 30) { self.writeTimeout = writeTimeout }

    func start(_ configuration: AILaunchConfiguration, directory: String) throws {
        stop()
        let generation = generation
        let buffer = OutputBuffer()
        guard let executable = configuration.executable else { throw AIConnectionError.missingCLI("AI") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(data, buffer: buffer, generation: generation) }
        }
        // Drain diagnostics without retaining credentials or unstructured output.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.finish(status: process.terminationStatus, generation: generation)
                }
            }
        }
        self.process = process
        do {
            writer = try InputWriter(handle: stdin.fileHandleForWriting, timeout: writeTimeout) { [weak self] in
                self?.finish(status: -1, generation: generation)
            }
            try process.run()
            // The writer owns a separate close-on-exec fd. No FileHandle write
            // can contend with stop(), including while a child stops reading.
            try? stdin.fileHandleForWriting.close()
        } catch { stop(); throw error }
    }

    private func consume(_ data: Data, buffer: OutputBuffer, generation: UUID) {
        buffer.data.append(data)
        while let end = buffer.data.firstIndex(of: 10) {
            let line = buffer.data[..<end]
            buffer.data.removeSubrange(...end)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onMessage?(message)
            }
        }
        if buffer.data.count > 16_000_000 {
            buffer.data.removeAll()
            DispatchQueue.main.async { [weak self] in self?.finish(status: -1, generation: generation) }
        }
    }

    func send(_ message: [String: Any]) throws { try send(message, completion: { _ in }) }

    func send(_ message: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard let writer, process?.isRunning == true else { throw CocoaError(.fileWriteUnknown) }
        guard JSONSerialization.isValidJSONObject(message) else { throw WriteError.invalidMessage }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed, .sortedKeys])
        data.append(10)
        guard data.count <= Self.maximumMessageBytes else { throw WriteError.messageTooLarge }
        try writer.enqueue(data, completion: completion)
    }

    private func finish(status: Int32, generation: UUID) {
        guard self.generation == generation else { return }
        // The barrier follows every admitted write, so a fast child cannot
        // make onExit invalidate a successful send before its completion runs.
        writer?.cancel { [weak self] in
            guard let self, self.generation == generation else { return }
            self.stop()
            self.onExit?(status)
        }
    }

    func stop() {
        generation = UUID()
        process?.terminationHandler = nil
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        writer?.cancel()
        writer = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? output?.close()
        try? errors?.close()
        output = nil
        errors = nil
    }

    deinit { stop() }

    private enum WriteError: LocalizedError {
        case invalidMessage, messageTooLarge, queueFull, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidMessage: "The AI request could not be encoded as JSON."
            case .messageTooLarge: "The AI request exceeds the 16 MiB transport limit."
            case .queueFull: "The AI process has too much pending input. Try again after it finishes."
            case .timedOut: "The AI process stopped accepting input. The conversation was disconnected."
            }
        }
    }

    /// One writer per process generation. Only this serial queue accesses its
    /// fd. The lock protects admission/cancellation, never I/O or a callback.
    private final class InputWriter: @unchecked Sendable {
        private let queue = DispatchQueue(label: "TheAll.ai-json-input")
        private let lock = NSLock()
        private var reservedBytes = 0
        private var cancellation: Error?
        private var descriptor: Int32
        private let timeout: TimeInterval
        private let onFailure: () -> Void

        init(handle: FileHandle, timeout: TimeInterval, onFailure: @escaping () -> Void) throws {
            descriptor = dup(handle.fileDescriptor)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1,
                  fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
                let code = errno
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            self.timeout = timeout
            self.onFailure = onFailure
        }

        func enqueue(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            if let cancellation { throw cancellation }
            guard data.count <= AIChatProcess.maximumPendingBytes - reservedBytes else { throw WriteError.queueFull }
            reservedBytes += data.count
            // Enqueue while holding the admission lock so cancellation's
            // barrier cannot overtake an admitted request, even across threads.
            queue.async {
                let result: Result<Void, Error>
                do { try self.write(data); result = .success(()) }
                catch {
                    result = .failure(error)
                    if self.markCancelled(error) {
                        // A failed/partial JSON line poisons this stream. Do not
                        // send later lines to it or continue a partially written request.
                        DispatchQueue.main.async(execute: self.onFailure)
                    }
                }
                self.lock.lock()
                self.reservedBytes -= data.count
                self.lock.unlock()
                DispatchQueue.main.async { completion(result) }
            }
        }

        func cancel(completion: (() -> Void)? = nil) {
            lock.lock()
            if cancellation == nil { cancellation = CocoaError(.userCancelled) }
            queue.async {
                if self.descriptor >= 0 {
                    Darwin.close(self.descriptor)
                    self.descriptor = -1
                }
                if let completion { DispatchQueue.main.async(execute: completion) }
            }
            lock.unlock()
        }

        private func markCancelled(_ error: Error) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard cancellation == nil else { return false }
            cancellation = error
            return true
        }

        private func checkCancellation() throws {
            lock.lock()
            let error = cancellation
            lock.unlock()
            if let error { throw error }
        }

        private func write(_ data: Data) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw WriteError.timedOut }
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                    if count > 0 { offset += count; continue }
                    let code = errno
                    if count < 0 && code == EINTR { continue }
                    if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                        var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        let result = poll(&item, 1, 50)
                        if result < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        if result > 0 && item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                            throw POSIXError(.EPIPE)
                        }
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: count == 0 ? EIO : code) ?? .EIO)
                }
            }
        }
    }
}
