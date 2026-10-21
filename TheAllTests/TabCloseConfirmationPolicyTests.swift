import XCTest
@testable import TheAll

final class TabCloseConfirmationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFalseSettingNeverConfirmsEvenForActiveStatuses() {
        let statuses: [TerminalStatus] = [
            .running(startedAt: now),
            .needsInput(since: now),
        ]

        XCTAssertFalse(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "false",
            statuses: statuses
        ))
    }

    func testAlwaysSettingConfirmsWithoutActiveStatuses() {
        let statuses: [TerminalStatus] = [
            .neverRan,
            .idle(since: now),
        ]

        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "always",
            statuses: statuses
        ))
    }

    func testTrueSettingConfirmsForRunningStatus() {
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "true",
            statuses: [.running(startedAt: now)]
        ))
    }

    func testTrueSettingConfirmsForNeedsInputStatus() {
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "true",
            statuses: [.needsInput(since: now)],
            surfaceNeedsConfirmation: false
        ))
    }

    func testTrueSettingConfirmsWhenGhosttySurfaceNeedsConfirmation() {
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "true",
            statuses: [.neverRan, .idle(since: now)],
            surfaceNeedsConfirmation: true
        ))
    }

    func testTrueSettingDoesNotConfirmForInactiveStatuses() {
        let statuses: [TerminalStatus] = [
            .neverRan,
            .idle(since: now),
            .success(exitCode: 0, duration: 2, finishedAt: now, agent: .claude),
            .failed(exitCode: 1, duration: 3, finishedAt: now, agent: .codex),
        ]

        XCTAssertFalse(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "true",
            statuses: statuses
        ))
    }

    func testMissingSettingBehavesLikeTrue() {
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: nil,
            statuses: [.running(startedAt: now)]
        ))
        XCTAssertFalse(TabCloseConfirmationPolicy.needsConfirmation(
            setting: nil,
            statuses: [.idle(since: now)]
        ))
    }

    func testUnknownSettingBehavesLikeTrue() {
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "maybe",
            statuses: [.needsInput(since: now)]
        ))
        XCTAssertFalse(TabCloseConfirmationPolicy.needsConfirmation(
            setting: "maybe",
            statuses: [.neverRan]
        ))
    }

    func testSettingComparisonTrimsWhitespaceAndIgnoresCase() {
        XCTAssertFalse(TabCloseConfirmationPolicy.needsConfirmation(
            setting: " FALSE \n",
            statuses: [.running(startedAt: now)]
        ))
        XCTAssertTrue(TabCloseConfirmationPolicy.needsConfirmation(
            setting: " Always ",
            statuses: [.neverRan]
        ))
    }
}

final class TabMiddleClickClosePolicyTests: XCTestCase {
    func testOnlyMiddleMouseButtonClosesTab() {
        XCTAssertTrue(TabMiddleClickClosePolicy.shouldClose(
            buttonNumber: 2,
            canClose: true
        ))
        XCTAssertFalse(TabMiddleClickClosePolicy.shouldClose(
            buttonNumber: 3,
            canClose: true
        ))
        XCTAssertFalse(TabMiddleClickClosePolicy.shouldClose(
            buttonNumber: 4,
            canClose: true
        ))
    }

    func testMiddleMouseButtonRespectsCanClose() {
        XCTAssertFalse(TabMiddleClickClosePolicy.shouldClose(
            buttonNumber: 2,
            canClose: false
        ))
    }
}
