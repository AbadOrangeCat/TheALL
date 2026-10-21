import XCTest
@testable import TheAll

final class ThemeCatalogTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theall-themes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testReturnsEmptyForMissingDirectory() {
        let result = ThemeCatalog.scan(atPath: "/no/such/dir/theall-nonexistent")
        XCTAssertEqual(result, [])
    }

    func testReturnsSortedFileNamesAndSkipsDotFiles() throws {
        for name in ["Catppuccin Mocha", "Dracula", "Apple Classic", ".DS_Store"] {
            let url = tmpDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let result = ThemeCatalog.scan(atPath: tmpDir.path)
        XCTAssertEqual(result, ["Apple Classic", "Catppuccin Mocha", "Dracula"])
    }

    func testBundledThemesIfPresentIncludeKnownName() {
        let all = ThemeCatalog.all
        if !all.isEmpty {
            XCTAssertTrue(all.contains("Catppuccin Mocha") || all.contains("Dracula"),
                          "bundle themes present but missing well-known names")
        }
    }
}
