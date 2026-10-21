import XCTest
import AppKit
@testable import TheAll

final class ThemeManagerTests: XCTestCase {

    func testManagerInitializesWithSomeTheme() {
        let manager = ThemeManager()
        let r = manager.theme.textPrimary.usingColorSpace(.sRGB)?.redComponent ?? 0
        let g = manager.theme.textPrimary.usingColorSpace(.sRGB)?.greenComponent ?? 0
        let b = manager.theme.textPrimary.usingColorSpace(.sRGB)?.blueComponent ?? 0
        XCTAssert(r > 0 || g > 0 || b > 0, "textPrimary should not be black-zero")
    }

    func testDeriveFromDarkBackgroundIsDark() {
        let bg = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        let fg = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
        let theme = AppTheme.derive(background: bg, foreground: fg, accent: nil, systemIsDark: true)
        XCTAssertTrue(theme.isDark)
        XCTAssertLessThan(Double(theme.canvas.brightnessComponent), 0.3)
    }

    func testDeriveFromLightBackgroundIsLight() {
        let bg = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        let fg = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        let theme = AppTheme.derive(background: bg, foreground: fg, accent: nil, systemIsDark: false)
        XCTAssertFalse(theme.isDark)
        XCTAssertGreaterThan(Double(theme.canvas.brightnessComponent), 0.7)
    }

    func testDeriveBuildsBorderBetweenBgAndFg() {
        let bg = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)
        let fg = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        let theme = AppTheme.derive(background: bg, foreground: fg, accent: nil, systemIsDark: true)
        let r = theme.border.usingColorSpace(.sRGB)?.redComponent ?? 0
        XCTAssertGreaterThan(Double(r), 0.10)
        XCTAssertLessThan(Double(r), 0.30)
    }

    func testDeriveAccentFallbackProvidesNonZeroColor() {
        let theme = AppTheme.derive(background: nil, foreground: nil, accent: nil, systemIsDark: true)
        let accent = theme.accent.usingColorSpace(.sRGB)
        XCTAssertNotNil(accent)
        let sum = (accent?.redComponent ?? 0) + (accent?.greenComponent ?? 0) + (accent?.blueComponent ?? 0)
        XCTAssertGreaterThan(Double(sum), 0.5)
    }

    func testParseGhosttyConfigExtractsTheme() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-test-config")
        try! "theme = dark\n".write(to: tmp, atomically: true, encoding: .utf8)
        let manager = ThemeManager()
        let result = manager.parseThemeFromConfig(at: tmp.path)
        XCTAssertEqual(result, "dark")
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParseGhosttyConfigReturnNilWhenMissing() {
        let manager = ThemeManager()
        let result = manager.parseThemeFromConfig(at: "/nonexistent/path")
        XCTAssertNil(result)
    }
}
