import XCTest
@testable import TheAll

final class TerminalStatusIconViewTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - Running with/without detail

    func testRunningNoDetail() {
        let text = TerminalStatusIconView.tooltipText(for: .running(startedAt: now)) ?? ""
        XCTAssertTrue(text.hasPrefix("Running for "), "got: \(text)")
        XCTAssertFalse(text.contains("\n"))
    }

    func testRunningWithDetail() {
        let text = TerminalStatusIconView.tooltipText(
            for: .running(startedAt: now, detail: "Edit Models/Foo.swift")
        ) ?? ""
        XCTAssertTrue(text.hasPrefix("Running for "))
        XCTAssertTrue(text.contains("\nEdit Models/Foo.swift"), "got: \(text)")
    }

    // MARK: - Success agent tests

    func testClaudeSuccessFormatsWithoutExitCode() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 12, finishedAt: now,
                          agent: .claude, summary: nil)
        )
        XCTAssertEqual(t, "Claude: turn finished · 12s")
    }

    func testClaudeSuccessWithSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 12, finishedAt: now,
                          agent: .claude, summary: "Refactored X.")
        )
        XCTAssertEqual(t, "Claude: turn finished · 12s\nRefactored X.")
    }

    func testCodexSuccessUsesDisplayName() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 5, finishedAt: now,
                          agent: .codex, summary: nil)
        )
        XCTAssertEqual(t, "Codex: turn finished · 5s")
    }

    func testOpenCodeSuccessUsesDisplayName() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 3, finishedAt: now,
                          agent: .opencode, summary: nil)
        )
        XCTAssertEqual(t, "OpenCode: turn finished · 3s")
    }

    // MARK: - Failed agent tests

    func testClaudeFailedWithSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 15, finishedAt: now,
                         agent: .claude, summary: "Edit failed: permission.")
        )
        XCTAssertEqual(t, "Claude: turn had tool errors · 15s\nEdit failed: permission.")
    }

    func testClaudeFailedWithoutSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 15, finishedAt: now,
                         agent: .claude, summary: nil)
        )
        XCTAssertEqual(t, "Claude: turn had tool errors · 15s")
    }

    func testReadSuccessTooltipAppendsReadMarker() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 12, finishedAt: now,
                          agent: .claude, summary: nil,
                          readAt: Date(timeIntervalSince1970: 99))
        )
        XCTAssertEqual(t, "Claude: turn finished · 12s · read")
    }

    func testReadFailedTooltipAppendsReadMarkerBeforeSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 15, finishedAt: now,
                         agent: .claude, summary: "Edit failed: permission.",
                         readAt: Date(timeIntervalSince1970: 99))
        )
        XCTAssertEqual(t, "Claude: turn had tool errors · 15s · read\nEdit failed: permission.")
    }

    // MARK: - renderStyle (read-state visuals)

    private static let darkTheme = AppTheme.systemFallback(isDark: true)

    func testUnreadSuccessIsSolidFill() {
        guard let style = TerminalStatusIconView.renderStyle(
            for: .success(exitCode: 0, duration: 1, finishedAt: Date(), agent: .claude),
            theme: Self.darkTheme)
        else { XCTFail("renderStyle must return non-nil for .success"); return }
        XCTAssertEqual(style.fill, Self.darkTheme.success)
        XCTAssertEqual(style.stroke, NSColor.clear)
        XCTAssertEqual(style.lineWidth, 0)
    }

    func testReadSuccessIsHollowStroke() {
        guard let style = TerminalStatusIconView.renderStyle(
            for: .success(exitCode: 0, duration: 1, finishedAt: Date(),
                          agent: .claude, summary: nil,
                          readAt: Date(timeIntervalSince1970: 99)),
            theme: Self.darkTheme)
        else { XCTFail("renderStyle must return non-nil for .success"); return }
        XCTAssertEqual(style.fill, NSColor.clear)
        XCTAssertEqual(style.stroke, Self.darkTheme.textTertiary)
        XCTAssertEqual(style.lineWidth, 1)
    }

    func testUnreadFailedIsSolidFill() {
        guard let style = TerminalStatusIconView.renderStyle(
            for: .failed(exitCode: 1, duration: 1, finishedAt: Date(), agent: .claude),
            theme: Self.darkTheme)
        else { XCTFail("renderStyle must return non-nil for .failed"); return }
        XCTAssertEqual(style.fill, Self.darkTheme.danger)
        XCTAssertEqual(style.stroke, NSColor.clear)
        XCTAssertEqual(style.lineWidth, 0)
    }

    func testReadFailedIsHollowStroke() {
        guard let style = TerminalStatusIconView.renderStyle(
            for: .failed(exitCode: 1, duration: 1, finishedAt: Date(),
                         agent: .claude, summary: nil,
                         readAt: Date(timeIntervalSince1970: 99)),
            theme: Self.darkTheme)
        else { XCTFail("renderStyle must return non-nil for .failed"); return }
        XCTAssertEqual(style.fill, NSColor.clear)
        XCTAssertEqual(style.stroke, Self.darkTheme.textTertiary)
        XCTAssertEqual(style.lineWidth, 1)
    }
}
