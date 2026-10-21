import XCTest
@testable import TheAll

/// 覆盖 `resolveThemeNameForAppearance` 的纯函数行为：follow-system 语法
/// `light:X,dark:Y` 的双向解析、顺序无关，以及各种单值/边界输入。
/// 这是把 day/night 切换 bug 收敛后的回归护栏——错误地挑了另一侧主题正是
/// 当初文字不可读的根因。
final class GhosttyConfigReaderTests: XCTestCase {

    func testSingleValuePassthroughDark() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance("Catppuccin Mocha", isDark: true),
            "Catppuccin Mocha"
        )
    }

    func testSingleValuePassthroughLight() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance("Catppuccin Mocha", isDark: false),
            "Catppuccin Mocha"
        )
    }

    func testFollowSystemPicksDarkSide() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance(
                "light:Catppuccin Latte,dark:Catppuccin Mocha", isDark: true
            ),
            "Catppuccin Mocha"
        )
    }

    func testFollowSystemPicksLightSide() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance(
                "light:Catppuccin Latte,dark:Catppuccin Mocha", isDark: false
            ),
            "Catppuccin Latte"
        )
    }

    /// dark/light 顺序颠倒，结果不应改变。
    func testFollowSystemOrderIndependent() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance(
                "dark:Catppuccin Mocha,light:Catppuccin Latte", isDark: false
            ),
            "Catppuccin Latte"
        )
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance(
                "dark:Catppuccin Mocha,light:Catppuccin Latte", isDark: true
            ),
            "Catppuccin Mocha"
        )
    }

    /// 含空格的 light:/dark: 片段（用户配置里常见）也要正确 trim 后匹配。
    func testFollowSystemTrimsWhitespace() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance(
                "light:Catppuccin Latte, dark:Catppuccin Mocha", isDark: true
            ),
            "Catppuccin Mocha"
        )
    }

    /// 含 `:` 但无 `,` —— 不满足 follow-system 语法，原样返回（不当作前缀拆分）。
    func testColonWithoutCommaReturnsRaw() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance("dark:Catppuccin Mocha", isDark: true),
            "dark:Catppuccin Mocha"
        )
    }

    /// 含 `,` 但无 `:` —— 同样不满足语法，原样返回。
    func testCommaWithoutColonReturnsRaw() {
        XCTAssertEqual(
            GhosttyConfigReader.resolveThemeNameForAppearance("Foo,Bar", isDark: false),
            "Foo,Bar"
        )
    }
}
