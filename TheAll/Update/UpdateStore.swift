import Foundation
import Observation

/// One observable update state for every desktop window.
@Observable
final class UpdateStore {
    static let shared = UpdateStore(currentVersion:
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")

    let currentVersion: String
    private(set) var state: UpdateState = .idle
    private(set) var availableVersion: String?
    var canCancelDownload = false
    var canCancelInstallation = false

    var hasUpdate: Bool {
        switch state {
        case .updateAvailable, .downloading, .readyToInstall, .waitingToInstall, .installing: return true
        default: return false
        }
    }
    var showsSidebarNotice: Bool {
        if case .error = state { return availableVersion != nil }
        return hasUpdate
    }
    /// Prevent a new desktop/phone turn racing with the final relaunch handoff.
    var blocksNewMessages: Bool { state == .installing }

    init(currentVersion: String) { self.currentVersion = currentVersion }

    @discardableResult func beginCheck() -> Bool {
        switch state {
        case .checking, .updateAvailable, .downloading, .readyToInstall, .waitingToInstall, .installing: return false
        default: state = .checking; return true
        }
    }
    func setChecking() { state = .checking }
    func setUpToDate() { availableVersion = nil; state = .upToDate }
    func setUpdateAvailable(version: String, releaseNotes: String?) {
        availableVersion = version
        state = .updateAvailable(version: version, releaseNotes: releaseNotes)
    }
    func setDownloading(progress: Double) {
        state = .downloading(progress: progress.isFinite ? min(1, max(0, progress)) : 0)
    }
    func setReadyToInstall() { canCancelDownload = false; state = .readyToInstall }
    func setWaitingToInstall() { state = .waitingToInstall }
    func setInstalling() { state = .installing }
    func setError(_ message: String) { canCancelDownload = false; state = .error(message) }
    func resetToIdle() { canCancelDownload = false; canCancelInstallation = false; availableVersion = nil; state = .idle }
}

/// Keeps the real Sparkle installation reply pending while AI turns are running.
/// Injected closures make this lifecycle testable without a live feed or quitting.
@MainActor
final class UpdateInstallCoordinator {
    private let store: UpdateStore
    private let isBusy: () -> Bool
    private let flush: () throws -> Void
    private var installReply: (() -> Void)?
    private var cancelReply: (() -> Void)?
    private var watcher: Task<Void, Never>?

    init(store: UpdateStore, isBusy: @escaping () -> Bool, flush: @escaping () throws -> Void) {
        self.store = store; self.isBusy = isBusy; self.flush = flush
    }

    var hasPendingInstallation: Bool { installReply != nil }

    func ready(install: @escaping () -> Void, cancel: @escaping () -> Void) {
        abandon()
        installReply = install; cancelReply = cancel
        store.canCancelInstallation = true
        store.setReadyToInstall()
        continueWhenIdle()
    }

    func continueWhenIdle() {
        guard let reply = installReply else { return }
        guard !isBusy() else {
            store.setWaitingToInstall()
            startWatcherIfNeeded()
            return
        }
        watcher?.cancel(); watcher = nil
        // Gate sends and flush on the same main-actor turn as the last busy check.
        store.setInstalling()
        do { try flush() }
        catch {
            // Retain the valid continuation for an explicit retry or cancellation.
            store.setError(L10n.string("update.saveFailed"))
            return
        }
        installReply = nil; cancelReply = nil; store.canCancelInstallation = false
        reply()
    }

    private func startWatcherIfNeeded() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.installReply != nil else { return }
                self.continueWhenIdle()
            }
        }
    }

    func cancel() {
        let reply = cancelReply
        abandon()
        store.resetToIdle()
        reply?()
    }

    /// On an engine error the original continuation is invalid; never invoke it.
    func abandon() {
        watcher?.cancel(); watcher = nil
        installReply = nil; cancelReply = nil
        store.canCancelInstallation = false
    }
    deinit { watcher?.cancel() }
}

/// An installation is identified by the executable actually selected for new chats.
struct CLIInstallation: Equatable {
    let provider: AIProvider
    let binary: String
    private var package: String { provider == .openai ? "@openai/codex" : "@anthropic-ai/claude-code" }
    private var cask: String { provider == .openai ? "codex" : "claude-code" }
    private var bin: URL { URL(fileURLWithPath: binary).deletingLastPathComponent() }
    private var prefix: URL { bin.deletingLastPathComponent() }
    private var target: String { URL(fileURLWithPath: binary).resolvingSymlinksInPath().path }
    private var brewCask: Bool {
        target.hasPrefix(prefix.resolvingSymlinksInPath().path + "/Caskroom/" + cask + "/")
    }
    private var nativeCodex: Bool {
        provider == .openai && binary == NSHomeDirectory() + "/.local/bin/codex"
            && target.hasPrefix(NSHomeDirectory() + "/.codex/packages/standalone/releases/")
    }
    private var nativeClaude: Bool {
        provider == .claude && target.hasPrefix(NSHomeDirectory() + "/.local/share/claude/versions/")
    }

    static func stableVersion(_ line: String) -> String? {
        let words = line.split(whereSeparator: { $0.isWhitespace })
        return words.map(String.init).first {
            $0.range(of: #"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$"#, options: .regularExpression) != nil
        }
    }
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    func command(for version: String) -> (executable: String, arguments: [String])? {
        guard Self.stableVersion(version) == version else { return nil }
        if brewCask {
            let brew = bin.appendingPathComponent("brew").path
            guard FileManager.default.isExecutableFile(atPath: brew) else { return nil }
            return (brew, ["upgrade", "--cask", cask])
        }
        if nativeClaude || nativeCodex { return (binary, ["update"]) }
        let modules = prefix.appendingPathComponent("lib/node_modules/" + package).resolvingSymlinksInPath()
        guard target.hasPrefix(modules.path + "/") else { return nil }
        let npm = AILaunchConfiguration.resolveTool("npm", paths: [bin.path] + AILaunchConfiguration.cliSearchPaths())
        guard let npm else { return nil }
        return (npm, ["install", "--global", "--prefix", prefix.path, "--registry=https://registry.npmjs.org", package + "@" + version])
    }

    func latestVersion() async throws -> String {
        let url: URL
        if brewCask { url = URL(string: "https://formulae.brew.sh/api/cask/" + cask + ".json")! }
        else if nativeCodex { url = URL(string: "https://releases.openai.com/codex/channels/latest")! }
        else if nativeClaude { url = URL(string: "https://downloads.claude.ai/claude-code-releases/stable")! }
        else { url = URL(string: "https://registry.npmjs.org/" + package + "/latest")! }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let version: String?
        if nativeClaude { version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        else {
            let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if nativeCodex, let tag = metadata?["tag_name"] as? String, tag.hasPrefix("rust-v") {
                version = String(tag.dropFirst("rust-v".count))
            } else { version = metadata?["version"] as? String }
        }
        guard let version, Self.stableVersion(version) == version else { throw URLError(.cannotParseResponse) }
        return version
    }

    /// Child processes never receive a shell command, a workspace working directory or session API credentials.
    static func run(_ executable: String, _ arguments: [String], versionOnly: Bool = false) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            let path = ([directory] + AILaunchConfiguration.cliSearchPaths()).joined(separator: ":")
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = ["HOME": NSHomeDirectory(), "PATH": path, "LANG": "en_US.UTF-8",
                                   "HOMEBREW_NO_ANALYTICS": "1", "CI": "1"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = versionOnly ? output.fileHandleForWriting : FileHandle.nullDevice
            try process.run()
            try output.fileHandleForWriting.close()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + (versionOnly ? 10 : 600), execute: deadline)
            defer { deadline.cancel() }
            let data = versionOnly ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

@MainActor @Observable
final class CLIUpdateStore {
    static let shared = CLIUpdateStore()
    struct Offer {
        let installation: CLIInstallation
        let installed: String
        let latest: String
    }
    private let resolve: (AIProvider) -> String?
    private let latestVersion: (CLIInstallation) async throws -> String

    init(resolve: @escaping (AIProvider) -> String? = { AILaunchConfiguration.resolveCLI($0) },
         latestVersion: @escaping (CLIInstallation) async throws -> String = { try await $0.latestVersion() }) {
        self.resolve = resolve
        self.latestVersion = latestVersion
    }

    var offers: [AIProvider: Offer] = [:]
    var installedVersions: [AIProvider: String] = [:]
    var errors = Set<AIProvider>()
    var installing: AIProvider?
    var checking = false
    private(set) var checked = false

    func check() async {
        guard !checking, installing == nil else { return }
        checking = true
        defer { checking = false; checked = true }
        for provider in AIProvider.allCases {
            errors.remove(provider)
            guard let binary = resolve(provider) else {
                installedVersions[provider] = nil; offers[provider] = nil
                continue
            }
            let installation = CLIInstallation(provider: provider, binary: binary)
            do {
                let raw = try await CLIInstallation.run(binary, ["--version"], versionOnly: true)
                guard let version = CLIInstallation.stableVersion(raw) else { throw URLError(.cannotParseResponse) }
                installedVersions[provider] = version
                let latest = try await latestVersion(installation)
                offers[provider] = CLIInstallation.isNewer(latest, than: version)
                    ? Offer(installation: installation, installed: version, latest: latest) : nil
            } catch { offers[provider] = nil; errors.insert(provider) }
        }
    }

    func install(_ provider: AIProvider) async {
        guard !checking, installing == nil, let offer = offers[provider] else { return }
        installing = provider
        defer { installing = nil }
        do {
            guard let binary = resolve(provider), binary == offer.installation.binary,
                  let command = offer.installation.command(for: offer.latest) else { throw URLError(.fileDoesNotExist) }
            let raw = try await CLIInstallation.run(binary, ["--version"], versionOnly: true)
            guard let current = CLIInstallation.stableVersion(raw) else { throw URLError(.cannotParseResponse) }
            if CLIInstallation.isNewer(offer.latest, than: current) {
                _ = try await CLIInstallation.run(command.executable, command.arguments)
            }
            guard let actual = resolve(provider), actual == binary,
                  let version = CLIInstallation.stableVersion(try await CLIInstallation.run(actual, ["--version"], versionOnly: true)),
                  !CLIInstallation.isNewer(offer.latest, than: version)
            else { throw URLError(.cannotParseResponse) }
            installedVersions[provider] = version
            offers[provider] = nil
            errors.remove(provider)
        } catch { errors.insert(provider) }
    }
}
