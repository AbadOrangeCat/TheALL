import XCTest
@testable import TheAll

final class GhosttyTerminalViewPwdTests: XCTestCase {

    func testValidatedDirectory_nil() {
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(nil))
    }

    func testValidatedDirectory_existingDirectory() {
        // /tmp exists on every macOS host and is always a directory
        XCTAssertEqual(GhosttyTerminalView.validatedDirectory("/tmp"), "/tmp")
    }

    func testValidatedDirectory_nonexistentPath() {
        let fake = "/nonexistent/\(UUID().uuidString)"
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(fake))
    }

    func testValidatedDirectory_regularFileRejected() {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("theall-test-\(UUID()).txt")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(path))
    }
}
