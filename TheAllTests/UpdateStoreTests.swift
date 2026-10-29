import XCTest
import Sparkle
@testable import TheAll

final class UpdateStoreTests: XCTestCase {

    func testDefaultStateIsIdle() {
        let s = UpdateStore(currentVersion: "0.1.0")
        XCTAssertEqual(s.state, .idle)
    }

    func testCurrentVersionIsStoredVerbatim() {
        let s = UpdateStore(currentVersion: "1.2.3")
        XCTAssertEqual(s.currentVersion, "1.2.3")
    }

    func testHasUpdateFalseWhenIdle() {
        let s = UpdateStore(currentVersion: "0.1.0")
        XCTAssertFalse(s.hasUpdate)
    }

    func testHasUpdateTrueWhenUpdateAvailable() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setUpdateAvailable(version: "0.2.0", releaseNotes: "fix bug")
        XCTAssertTrue(s.hasUpdate)
        XCTAssertEqual(s.state, .updateAvailable(version: "0.2.0", releaseNotes: "fix bug"))
    }

    func testHasUpdateTrueWhileDownloading() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setUpdateAvailable(version: "0.2.0", releaseNotes: nil)
        s.setDownloading(progress: 0.3)
        XCTAssertTrue(s.hasUpdate)
        XCTAssertEqual(s.state, .downloading(progress: 0.3))
    }

    func testHasUpdateFalseAfterUpToDate() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setChecking()
        s.setUpToDate()
        XCTAssertFalse(s.hasUpdate)
        XCTAssertEqual(s.state, .upToDate)
    }

    func testErrorState() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setError("Network error")
        XCTAssertEqual(s.state, .error("Network error"))
        XCTAssertFalse(s.hasUpdate)
    }

    func testResetToIdle() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setUpdateAvailable(version: "0.2.0", releaseNotes: nil)
        s.resetToIdle()
        XCTAssertEqual(s.state, .idle)
    }

    func testProgressMonotonicAccepted() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setDownloading(progress: 0.1)
        s.setDownloading(progress: 0.5)
        s.setDownloading(progress: 1.0)
        XCTAssertEqual(s.state, .downloading(progress: 1.0))
    }

    func testHasUpdateTrueWhenReadyToInstall() {
        let s = UpdateStore(currentVersion: "0.1.0")
        s.setReadyToInstall()
        XCTAssertTrue(s.hasUpdate)
        XCTAssertEqual(s.state, .readyToInstall)
    }

    @MainActor func testSparkleBridgeIsInactiveInTestHost() {
        // Both configurations compile the real driver; tests never start a live updater.
        XCTAssertFalse(SparkleBridge.shared.isActive)
    }
}

@MainActor
final class UpdateLifecycleTests: XCTestCase {
    private func makeDriver(_ store: UpdateStore, allowsInstall: Bool = true,
                            busy: @escaping () -> Bool = { false }, flush: @escaping () throws -> Void = {}) -> UpdateUserDriver {
        UpdateUserDriver(store: store, canInstall: { allowsInstall }, isBusy: busy, flush: flush)
    }

    func testSharedStoreAndChecksAreSingleFlight() {
        XCTAssertTrue(UpdateStore.shared === UpdateStore.shared)
        let store = UpdateStore(currentVersion: "0.1.6")
        XCTAssertTrue(store.beginCheck())
        XCTAssertFalse(store.beginCheck())
        store.setUpdateAvailable(version: "0.1.7", releaseNotes: nil)
        XCTAssertFalse(store.beginCheck())
        store.setDownloading(progress: .nan)
        XCTAssertEqual(store.state, .downloading(progress: 0))
        XCTAssertFalse(store.beginCheck())
        store.setWaitingToInstall()
        XCTAssertTrue(store.hasUpdate)
        XCTAssertFalse(store.beginCheck())
        store.setError("offline")
        XCTAssertTrue(store.showsSidebarNotice)
        XCTAssertTrue(store.beginCheck())
    }

    func testDownloadedUpdateWaitsForAllTasksAndFlushesBeforeInstallingOnce() {
        let store = UpdateStore(currentVersion: "0.1.6")
        var busy = true
        var events: [String] = []
        let driver = makeDriver(store, busy: { busy }, flush: {
            XCTAssertTrue(store.blocksNewMessages)
            events.append("flush")
        })
        driver.offer(version: "0.1.7", notes: "Changes") { _ in events.append("download") }
        driver.userRequestedDownloadAndInstall()
        driver.userRequestedDownloadAndInstall()
        XCTAssertEqual(events, ["download"])
        driver.showReady { choice in
            XCTAssertEqual(choice, .install)
            events.append("install")
        }
        XCTAssertEqual(store.state, .waitingToInstall)
        XCTAssertFalse(store.blocksNewMessages)
        driver.installation.continueWhenIdle()
        XCTAssertEqual(events, ["download"])
        busy = false
        driver.installation.continueWhenIdle()
        driver.installation.continueWhenIdle()
        XCTAssertEqual(events, ["download", "flush", "install"])
        XCTAssertEqual(store.state, .installing)
    }

    func testWaitingWatcherInstallsAfterTheTaskFinishes() async throws {
        let store = UpdateStore(currentVersion: "0.1.6")
        var busy = true
        var installed = false
        let coordinator = UpdateInstallCoordinator(store: store, isBusy: { busy }, flush: {})
        coordinator.ready(install: { installed = true }, cancel: { XCTFail("Unexpected cancellation") })
        busy = false
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(installed)
        XCTAssertEqual(store.state, .installing)
    }

    func testCancelWaitingResolvesSparkleWithSkipAndNeverRestarts() {
        let store = UpdateStore(currentVersion: "0.1.6")
        var busy = true
        let driver = makeDriver(store, busy: { busy }, flush: { XCTFail("Cancelled update must not flush for installation") })
        driver.offer(version: "0.1.7", notes: nil) { _ in }
        driver.userRequestedDownloadAndInstall()
        var replies: [SPUUserUpdateChoice] = []
        driver.showReady { replies.append($0) }
        driver.cancel()
        busy = false
        driver.installation.continueWhenIdle()
        XCTAssertEqual(replies, [.skip])
        XCTAssertEqual(store.state, .idle)
    }

    func testCancelledDownloadCannotInstallFromLateCallback() {
        let store = UpdateStore(currentVersion: "0.1.6")
        let driver = makeDriver(store)
        driver.offer(version: "0.1.7", notes: nil) { _ in }
        driver.userRequestedDownloadAndInstall()
        var cancellationCount = 0
        driver.showDownloadInitiated { cancellationCount += 1 }
        XCTAssertTrue(store.canCancelDownload)
        driver.cancel(); driver.cancel()
        XCTAssertEqual(cancellationCount, 1)
        driver.showReady { XCTAssertEqual($0, .skip) }
        XCTAssertEqual(store.state, .idle)
        driver.prepareForCheck()
        driver.recordCycleError(URLError(.notConnectedToInternet))
        guard case .error = store.state else { return XCTFail("Retry failures must remain visible") }
    }

    func testDevelopmentBuildAndUnsolicitedReadyNeverInstall() {
        let store = UpdateStore(currentVersion: "0.1.6")
        let driver = makeDriver(store, allowsInstall: false)
        var replyCount = 0
        driver.offer(version: "0.1.7", notes: nil) { _ in replyCount += 1 }
        driver.userRequestedDownloadAndInstall()
        XCTAssertEqual(replyCount, 0)
        driver.showReady { XCTAssertEqual($0, .skip) }
        XCTAssertFalse(store.blocksNewMessages)
        let allowedDriver = makeDriver(store)
        allowedDriver.showReady { XCTAssertEqual($0, .skip) }
    }

    func testResumedStagedUpdateStillWaitsForBusyTasks() {
        let store = UpdateStore(currentVersion: "0.1.6")
        let driver = makeDriver(store, busy: { true })
        var replies: [SPUUserUpdateChoice] = []
        driver.offer(version: "0.1.7", notes: nil, alreadyInstalling: true) { replies.append($0) }
        driver.userRequestedDownloadAndInstall()
        XCTAssertEqual(store.state, .waitingToInstall)
        XCTAssertTrue(replies.isEmpty)
        driver.cancel()
        XCTAssertEqual(replies, [.skip])
    }

    func testNetworkAndCompatibilityErrorsAreNotReportedAsLatest() {
        let store = UpdateStore(currentVersion: "0.1.6")
        let driver = makeDriver(store)
        driver.recordCycleError(URLError(.badServerResponse))
        guard case .error = store.state else { return XCTFail("HTTP/feed failure must remain an error") }
        driver.dismissUpdateInstallation()
        guard case .error = store.state else { return XCTFail("Dismissing Sparkle UI must retain the error") }
        driver.recordCycleError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue)]))
        guard case .error = store.state else { return XCTFail("Incompatible OS is not up to date") }
        driver.recordCycleError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)]))
        XCTAssertEqual(store.state, .upToDate)
    }

    func testErrorInvalidatesPendingInstallationAndUnblocksMessages() {
        let store = UpdateStore(currentVersion: "0.1.6")
        var busy = true
        let driver = makeDriver(store, busy: { busy })
        driver.offer(version: "0.1.7", notes: nil) { _ in }
        driver.userRequestedDownloadAndInstall()
        driver.showReady { _ in XCTFail("An errored installation must not resume") }
        driver.recordCycleError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue)))
        busy = false
        driver.installation.continueWhenIdle()
        guard case .error = store.state else { return XCTFail("Signature failure must be visible") }
        XCTAssertFalse(store.blocksNewMessages)
    }

    func testFailedCheckpointKeepsAppOpenAndCanRetryWithoutRedownloading() {
        let store = UpdateStore(currentVersion: "0.1.6")
        var diskIsFull = true
        var installs = 0
        let driver = makeDriver(store, flush: {
            if diskIsFull { throw CocoaError(.fileWriteOutOfSpace) }
        })
        driver.offer(version: "0.1.7", notes: nil) { _ in }
        driver.userRequestedDownloadAndInstall()
        driver.showReady { choice in
            XCTAssertEqual(choice, .install)
            installs += 1
        }
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(store.blocksNewMessages)
        XCTAssertTrue(store.canCancelInstallation)
        guard case .error = store.state else { return XCTFail("Save failure must be actionable") }
        diskIsFull = false
        driver.installation.continueWhenIdle()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(store.state, .installing)
    }

    func testFailedCheckpointCanBeCancelledAndNeverResumesFromLateCallbacks() {
        let store = UpdateStore(currentVersion: "0.1.6")
        let driver = makeDriver(store, flush: { throw CocoaError(.fileWriteOutOfSpace) })
        var choices: [SPUUserUpdateChoice] = []
        driver.offer(version: "0.1.7", notes: nil) { _ in }
        driver.userRequestedDownloadAndInstall()
        driver.showReady { choices.append($0) }
        XCTAssertTrue(driver.installation.hasPendingInstallation)
        driver.cancel()
        XCTAssertEqual(choices, [.skip])
        XCTAssertFalse(driver.installation.hasPendingInstallation)
        driver.installation.continueWhenIdle()
        driver.showReady { XCTAssertEqual($0, .skip) }
        XCTAssertEqual(store.state, .idle)
        XCTAssertFalse(store.blocksNewMessages)
    }

    func testBackgroundCheckFailureDoesNotCreateANewVersionBanner() {
        let store = UpdateStore(currentVersion: "0.1.6")
        store.setError("HTTP 404")
        XCTAssertFalse(store.showsSidebarNotice)
        store.setUpdateAvailable(version: "0.1.7", releaseNotes: nil)
        store.setError("Download interrupted")
        XCTAssertTrue(store.showsSidebarNotice)
    }

    func testHistoryCheckpointRetainsFailedWritesAndReportsRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let history = AIChatHistoryStore(directory: blocked.appendingPathComponent("history"), notifications: NotificationCenter())
        let id = UUID()
        var saveResults: [Bool] = []
        history.save(AIChatSnapshot(provider: .claude, directory: "/tmp", model: "", input: "draft api-secret", messages: [], conversationID: "session"),
                     for: id, redacting: ["api-secret"]) { saveResults.append($0) }
        XCTAssertThrowsError(try history.flushForUpdate())
        XCTAssertThrowsError(try history.flushForUpdate())
        try FileManager.default.removeItem(at: blocked)
        try history.flushForUpdate()
        let restored = try XCTUnwrap(history.load(for: id))
        XCTAssertEqual(restored.input, "draft ••••")
        XCTAssertEqual(restored.conversationID, "session")
        // Also let the original throttled save run; retrying must never call an
        // already-resolved completion again, even after successful recovery.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(saveResults, [false])
    }

    func testOnlyExactHTTPSReleaseAssetsAreEligible() {
        let valid = "https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.7/TheAll-0.1.7-macos-arm64.dmg"
        XCTAssertTrue(UpdateUserDriver.isReleaseAsset(URL(string: valid)))
        for invalid in [valid.replacingOccurrences(of: "https:", with: "http:"),
                        valid.replacingOccurrences(of: "AbadOrangeCat", with: "attacker"),
                        valid.replacingOccurrences(of: "github.com", with: "github.com.attacker.example"),
                        valid + "?redirect=elsewhere", "file:///tmp/TheAll.dmg"] {
            XCTAssertFalse(UpdateUserDriver.isReleaseAsset(URL(string: invalid)))
        }
    }
}
