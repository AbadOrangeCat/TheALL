import XCTest
@testable import TheAll

final class SettingsConfigStoreTests: XCTestCase {

    private var tmpPath: String!

    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory()
        tmpPath = (dir as NSString).appendingPathComponent(
            "theall-settings-\(UUID().uuidString).conf"
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpPath)
        super.tearDown()
    }

    func testLoadsMissingFileAsEmpty() {
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()
        XCTAssertNil(store.get("font-size"))
    }

    func testParsesKvCommentsBlankAndUnknown() throws {
        let contents = """
        # top comment

        font-size = 13
        theme = Catppuccin Mocha
        # trailing comment
        garbage-no-equals
        """
        try contents.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        XCTAssertEqual(store.get("font-size"), "13")
        XCTAssertEqual(store.get("theme"), "Catppuccin Mocha")

        let (comments, blanks, unknowns, kvs) = store.debugCounts()
        XCTAssertEqual(comments, 2)
        XCTAssertEqual(blanks, 1)
        XCTAssertEqual(unknowns, 1)
        XCTAssertEqual(kvs, 2)
    }

    func testSetExistingKeyUpdatesInPlace() throws {
        try "font-size = 13\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", "15")
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(roundTrip.contains("font-size = 15"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
        XCTAssertFalse(roundTrip.contains("font-size = 13"))
    }

    func testSetNewKeyAppendsAtEnd() throws {
        try "# user comment\n\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", "15")
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(roundTrip.hasPrefix("# user comment"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
        XCTAssertTrue(roundTrip.contains("font-size = 15"))
        let themeIdx = roundTrip.range(of: "theme = A")!.lowerBound
        let fontIdx  = roundTrip.range(of: "font-size = 15")!.lowerBound
        XCTAssertLessThan(themeIdx, fontIdx)
    }

    func testSetNilDeletesLine() throws {
        try "font-size = 13\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", nil)
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertFalse(roundTrip.contains("font-size"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
    }

    func testPreservesDuplicateKeys() throws {
        let contents = """
        palette = 0=#000000
        palette = 1=#ffffff
        """
        try contents.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        XCTAssertEqual(store.get("palette"), "0=#000000")

        store.save()
        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(roundTrip.contains("palette = 0=#000000"))
        XCTAssertTrue(roundTrip.contains("palette = 1=#ffffff"))
    }

    func testQuotedValueStripped() throws {
        try #"theme = "Catppuccin Latte""#.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()
        XCTAssertEqual(store.get("theme"), "Catppuccin Latte")
    }

}
