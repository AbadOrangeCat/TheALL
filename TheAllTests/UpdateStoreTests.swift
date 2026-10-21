import XCTest
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

    func testSparkleBridgeIsInactiveInDebug() {
        // Tests always run in Debug configuration; isActive must be false
        // to guarantee no live-network update checks during testing.
        XCTAssertFalse(SparkleBridge.shared.isActive)
    }
}
