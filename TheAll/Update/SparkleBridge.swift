import Foundation
import Sparkle

/// Sparkle verifies Ed25519 signatures and performs the normal quit/install/relaunch.
/// Debug can check the stable feed, but can never replace itself with a release app.
@MainActor
final class SparkleBridge: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleBridge()
    let store: UpdateStore
    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?
    private var launchCheck: Task<Void, Never>?

    init(store: UpdateStore = .shared) { self.store = store; super.init() }

    var isActive: Bool {
        guard !Self.isTestHost else { return false }
        return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
            == "https://github.com/AbadOrangeCat/TheALL/releases/latest/download/appcast.xml"
            && Data(base64Encoded: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")?.count == 32
    }

    var canInstall: Bool {
        #if DEBUG
        return false
        #else
        return isActive && Bundle.main.bundleIdentifier == "com.theall.app"
        #endif
    }

    private static var isTestHost: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.theall.tests.")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func start() {
        guard isActive, updater == nil else { return }
        let driver = UpdateUserDriver(store: store, canInstall: { [weak self] in self?.canInstall == true },
            isBusy: {
                TheAllRuntime.shared.chats.hasPendingWorkForUpdate
            }, flush: {
                try TheAllRuntime.shared.chats.flushForUpdate()
                try TheAllRuntime.shared.workspaces.flushForUpdate()
            })
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do { try updater.start() }
        catch { store.setError(L10n.string("update.checkFailed") + "\n" + error.localizedDescription); return }
        self.updater = updater; self.driver = driver
        // Persisted older settings may have disabled these. Installation remains explicit.
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        updater.updateCheckInterval = 6 * 60 * 60
        launchCheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            self?.checkForUpdates(silently: true)
        }
    }

    func checkForUpdates(silently: Bool) {
        guard isActive else { return }
        if updater == nil { start() }
        guard let updater, !updater.sessionInProgress, store.beginCheck() else { return }
        driver?.prepareForCheck()
        if silently { updater.checkForUpdatesInBackground() } else { updater.checkForUpdates() }
    }

    func downloadAndInstall() {
        guard canInstall else { return }
        driver?.userRequestedDownloadAndInstall()
    }
    func continueInstallation() { driver?.installation.continueWhenIdle() }
    func cancel() { driver?.cancel() }
    func skipVersion() { driver?.userRequestedSkipVersion() }
    func dismiss() { driver?.userRequestedDismiss() }
    func retry() {
        if driver?.installation.hasPendingInstallation == true {
            driver?.installation.continueWhenIdle()
            return
        }
        guard !store.hasUpdate else { return }
        checkForUpdates(silently: false)
    }

    /// Background failures are not always delivered to SPUUserDriver.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { driver?.recordCycleError(error) }
        else if case .checking = store.state { store.setUpToDate() }
    }
}
