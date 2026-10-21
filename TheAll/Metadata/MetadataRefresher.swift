import Foundation

final class MetadataRefresher {
    private let metadata: WorkspaceMetadata
    /// Closure that resolves the workspace's current working directory. Re-evaluated
    /// on every tick because pwd tracks the focused terminal's shell cwd
    /// (ghostty `GHOSTTY_ACTION_PWD` → `TerminalPwdStore`), which moves with `cd`.
    /// Returning nil — e.g. no shell has reported pwd yet — skips the git probe
    /// entirely so we don't run `git` from an unrelated dir.
    private let workingDirectoryProvider: () -> String?
    private var timer: Timer?
    var onRefresh: (() -> Void)?

    init(metadata: WorkspaceMetadata, workingDirectoryProvider: @escaping () -> String?) {
        self.metadata = metadata
        self.workingDirectoryProvider = workingDirectoryProvider
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run one probe cycle now. Safe to call on main thread; work hops to a
    /// background queue and results are published back on main.
    func refresh() {
        let dir = workingDirectoryProvider()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let branch = dir.flatMap { self.fetchGitBranch(cwd: $0) }
            DispatchQueue.main.async {
                self.metadata.workingDirectory = dir
                self.metadata.gitBranch = branch
                self.onRefresh?()
            }
        }
    }

    private func fetchGitBranch(cwd: String) -> String? {
        let output = shell("git rev-parse --abbrev-ref HEAD", cwd: cwd)
        return MetadataRefresher.parseBranch(from: output ?? "")
    }

    private func shell(_ command: String, cwd: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: - Parsers (static for testability)

    static func parseBranch(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
