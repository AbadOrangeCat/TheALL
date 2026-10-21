import XCTest
@testable import TheAll

final class HoverHighlightURLTests: XCTestCase {
    func testAcceptsWebAndMailto() {
        XCTAssertTrue(GhosttyTerminalView.isHoverHighlightURL("http://example.com"))
        XCTAssertTrue(GhosttyTerminalView.isHoverHighlightURL("https://example.com/a?b=1"))
        XCTAssertTrue(GhosttyTerminalView.isHoverHighlightURL("mailto:x@y.com"))
    }
    func testRejectsFileAndSchemeless() {
        // file:// 是提示符路径噪音的来源，hover 不高亮（但 Cmd+点击仍可由 resolveOpenURL 打开）。
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL("file:///Users/me/repo"))
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL("/clear"))
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL("~/Documents/repos/clip0"))
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL(""))
    }
    func testRejectsDangerousSchemes() {
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL("javascript:alert(1)"))
        XCTAssertFalse(GhosttyTerminalView.isHoverHighlightURL("ftp://example.com"))
    }
}
