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
