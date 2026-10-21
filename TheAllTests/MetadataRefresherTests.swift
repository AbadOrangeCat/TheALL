import XCTest
@testable import TheAll

final class MetadataRefresherTests: XCTestCase {

    func testParseBranchFromGitOutput() {
        let output = "main\n"
        let branch = MetadataRefresher.parseBranch(from: output)
        XCTAssertEqual(branch, "main")
    }

    func testParseBranchTrimsWhitespace() {
        let output = "  feat/sidebar  \n"
        let branch = MetadataRefresher.parseBranch(from: output)
        XCTAssertEqual(branch, "feat/sidebar")
    }

    func testParseBranchReturnsNilOnEmpty() {
        let branch = MetadataRefresher.parseBranch(from: "")
        XCTAssertNil(branch)
    }
}
