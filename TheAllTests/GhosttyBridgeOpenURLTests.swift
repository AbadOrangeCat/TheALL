import XCTest
@testable import TheAll

final class GhosttyBridgeOpenURLTests: XCTestCase {
    func testAllowsHTTPAndHTTPS() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("http://example.com")?.absoluteString,
                       "http://example.com")
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
    }

    func testAllowsMailtoAndFile() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("mailto:x@y.com")?.scheme, "mailto")
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("file:///tmp/a.txt")?.scheme, "file")
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("file:///tmp/a.txt")?.absoluteString, "file:///tmp/a.txt")
    }

    func testRejectsEmptyFileURL() {
        XCTAssertNil(GhosttyBridge.resolveOpenURL("file://"))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("  https://example.com  ")?.absoluteString,
                       "https://example.com")
    }

    func testRejectsDisallowedSchemes() {
        XCTAssertNil(GhosttyBridge.resolveOpenURL("javascript:alert(1)"))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("ftp://example.com"))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("custom-scheme://do-something"))
    }

    func testRejectsEmptyAndSchemeless() {
        XCTAssertNil(GhosttyBridge.resolveOpenURL(""))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("   "))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("example.com"))
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("HTTPS://example.com")?.scheme?.lowercased(),
                       "https")
    }
}
