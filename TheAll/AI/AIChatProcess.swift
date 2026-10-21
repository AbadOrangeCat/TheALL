import Foundation

protocol AIChatTransport: AnyObject {
    var onMessage: (([String: Any]) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    func start(_ configuration: AILaunchConfiguration, directory: String) throws
    func send(_ message: [String: Any]) throws
    func stop()
}

/// Newline JSON over private pipes. Never uses a shell, PTY, or user's stdin.
final class AIChatProcess: AIChatTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let queue = DispatchQueue(label: "TheAll.ai-json")
    private var generation = UUID()
    private final class OutputBuffer { var data = Data() }

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
        input = stdin.fileHandleForWriting
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
                    guard let self, self.generation == generation else { return }
                    self.onExit?(process.terminationStatus)
                }
            }
        }
        self.process = process
        do { try process.run() }
        catch { stop(); throw error }
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
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop(); self.onExit?(-1)
            }
        }
    }

    func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed, .sortedKeys])
        data.append(10)
        try input.write(contentsOf: data)
    }

    func stop() {
        generation = UUID()
        process?.terminationHandler = nil
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? output?.close()
        try? errors?.close()
        output = nil
        errors = nil
    }

    deinit { stop() }
}
