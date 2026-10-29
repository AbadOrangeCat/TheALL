import Foundation
import Sparkle

/// The same callback implementation is compiled in Debug and Release. Tests inject
/// local continuations; no feed, updater process or real application is launched.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private let store: UpdateStore
    private let canInstall: () -> Bool
    let installation: UpdateInstallCoordinator
    private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var receivedBytes: UInt64 = 0
    private var expectedTotalBytes: UInt64 = 0
    private var userRequestedInstall = false
    private var wasCancelled = false

    init(store: UpdateStore, canInstall: @escaping () -> Bool,
         isBusy: @escaping () -> Bool, flush: @escaping () throws -> Void) {
        self.store = store; self.canInstall = canInstall
        installation = UpdateInstallCoordinator(store: store, isBusy: isBusy, flush: flush)
        super.init()
    }

    func userRequestedDownloadAndInstall() {
        guard canInstall(), let reply = pendingUpdateReply else { return }
        pendingUpdateReply = nil
        wasCancelled = false; userRequestedInstall = true
        store.setDownloading(progress: 0)
        reply(.install)
    }
    func userRequestedSkipVersion() {
        let reply = pendingUpdateReply; pendingUpdateReply = nil
        userRequestedInstall = false
        store.resetToIdle()
        reply?(.skip)
    }
    func userRequestedDismiss() {
        let reply = pendingUpdateReply; pendingUpdateReply = nil
        userRequestedInstall = false
        store.resetToIdle()
        reply?(.dismiss)
    }
    func cancel() {
        wasCancelled = true; userRequestedInstall = false
        if let cancel = downloadCancellation {
            downloadCancellation = nil
            store.resetToIdle()
            cancel()
        } else if installation.hasPendingInstallation {
            installation.cancel()
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func prepareForCheck() { wasCancelled = false }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { prepareForCheck(); store.setChecking() }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate, Self.isReleaseAsset(appcastItem.fileURL) else {
            reply(.dismiss)
            store.setError(L10n.string("update.invalidRelease"))
            return
        }
        offer(version: appcastItem.displayVersionString, notes: appcastItem.itemDescription,
              alreadyInstalling: state.stage == .installing, reply: reply)
    }

    /// Entry point shared by live Sparkle callbacks and deterministic lifecycle tests.
    func offer(version: String, notes: String?, alreadyInstalling: Bool = false,
               reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingUpdateReply?(.dismiss)
        installation.abandon()
        downloadCancellation = nil; store.canCancelDownload = false
        userRequestedInstall = false; wasCancelled = false
        pendingUpdateReply = { [weak self] choice in
            if choice == .install, alreadyInstalling { self?.showReady(toInstallAndRelaunch: reply) }
            else { reply(choice) }
        }
        store.setUpdateAvailable(version: version, releaseNotes: notes)
    }

    static func isReleaseAsset(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path.range(of: #"^/AbadOrangeCat/TheALL/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/TheAll-[0-9]+\.[0-9]+\.[0-9]+-macos-(arm64|x64|universal)\.(dmg|zip)$"#, options: .regularExpression) != nil
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        recordCycleError(error)
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        recordCycleError(error)
        acknowledgement()
    }

    func recordCycleError(_ error: Error) {
        installation.abandon()
        pendingUpdateReply = nil; downloadCancellation = nil
        userRequestedInstall = false; store.canCancelDownload = false
        let ns = error as NSError
        if wasCancelled || (ns.domain == SUSparkleErrorDomain && ns.code == SUError.installationCanceledError.rawValue) {
            store.resetToIdle(); return
        }
        if ns.domain == SUSparkleErrorDomain, ns.code == SUError.noUpdateError.rawValue {
            let reason = (ns.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue ?? -1
            if reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
                store.setUpToDate()
            } else {
                // Unsupported OS/architecture or an empty feed is not "up to date".
                store.setError(L10n.string("update.noCompatibleRelease"))
            }
        } else {
            store.setError(L10n.string("update.checkFailed") + "\n" + ns.localizedDescription)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard userRequestedInstall, canInstall(), !wasCancelled else { cancellation(); return }
        receivedBytes = 0; expectedTotalBytes = 0
        downloadCancellation = cancellation; store.canCancelDownload = true
        store.setDownloading(progress: 0)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedTotalBytes = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard userRequestedInstall, !wasCancelled else { return }
        let sum = receivedBytes.addingReportingOverflow(length)
        receivedBytes = sum.overflow ? UInt64.max : sum.partialValue
        let total = expectedTotalBytes > 0 ? expectedTotalBytes : max(receivedBytes, 1)
        store.setDownloading(progress: Double(receivedBytes) / Double(total))
    }
    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil; store.canCancelDownload = false
        if userRequestedInstall, !wasCancelled { store.setDownloading(progress: 1) }
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        // Keep download at 100% during verification/extraction (do not jump backwards).
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userRequestedInstall, canInstall(), !wasCancelled else {
            reply(.skip) // Cancel staged installation; .dismiss would still install on quit.
            return
        }
        downloadCancellation = nil; store.canCancelDownload = false
        installation.ready(install: { reply(.install) }, cancel: { reply(.skip) })
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        store.setInstalling()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        installation.abandon(); store.resetToIdle(); acknowledgement()
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {
        // Sparkle can dismiss its UI during the successful termination handoff.
        switch store.state {
        case .checking, .downloading, .readyToInstall, .waitingToInstall:
            installation.abandon(); store.resetToIdle()
        default: break // Preserve error/up-to-date feedback and the relaunch gate.
        }
    }
}
