import XCTest
@testable import TheAll

final class GhosttyBridgeCommandTests: XCTestCase {
    func testStartupInputTrimsCommandAndAppendsNewline() {
        XCTAssertEqual(
            WorkspaceDefaultCommand.startupInput(for: "  claude  "),
            "claude\n")
    }

    func testStartupInputReturnsNilForEmptyCommand() {
        XCTAssertNil(WorkspaceDefaultCommand.startupInput(for: nil))
        XCTAssertNil(WorkspaceDefaultCommand.startupInput(for: "   "))
    }
}
