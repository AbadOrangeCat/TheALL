import AppKit

/// 多层调色板。所有颜色都从 ghostty 配置的 background / foreground / palette 派生，
/// 不再有硬编码的 .dark / .light。如果 ghostty 没设置 background/foreground，会用
/// 系统外观的 fallback。
struct AppTheme: Equatable {
    let isDark: Bool

    // Surfaces
    let canvas: NSColor          // 画布主背景 = ghostty.background
    let surface: NSColor         // 终端窗口背景 = ghostty.background (与画布同源)
    let sidebar: NSColor         // 侧边栏背景 = canvas 略微偏深/偏浅

    // Borders
    let border: NSColor          // hairline / hover / 选中态 = mix(bg, fg, 0.12)
    let borderStrong: NSColor    // 区段分隔 / 选中态 = mix(bg, fg, 0.22)

    // Text
    let textPrimary: NSColor     // = ghostty.foreground
    let textSecondary: NSColor   // = mix(fg, bg, 0.40)
    let textTertiary: NSColor    // = mix(fg, bg, 0.65)

    // Accent (取自 ghostty palette[3] / yellow，回退到品牌 amber)
    let accent: NSColor
    let accentMuted: NSColor     // 选中态背景填充

    // Status (terminal status icon)
    let success: NSColor         // 命令成功退出 (exit 0) 的点色
    let danger: NSColor          // 命令失败 (exit != 0) 的点色
}

extension AppTheme {

    /// 基于 ghostty 的 background/foreground/palette 构造 AppTheme。
    /// background/foreground/palette 任一为 nil 时用 fallback。
    static func derive(
        background: NSColor?,
        foreground: NSColor?,
        accent: NSColor?,
        systemIsDark: Bool
    ) -> AppTheme {
        let bg = background ?? (systemIsDark
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.982, blue: 0.978, alpha: 1))

        let fg = foreground ?? (systemIsDark
            ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.105, alpha: 1))

        let bgBrightness = bg.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        let isDark = bgBrightness < 0.5

        // sidebar: canvas 朝对面 mix 6%
        let sidebar = bg.mixed(with: fg, fraction: isDark ? 0.04 : 0.05) ?? bg

        // border 系列
        let border = bg.mixed(with: fg, fraction: 0.12) ?? bg
        let borderStrong = bg.mixed(with: fg, fraction: 0.22) ?? bg

        // text 系列
        let textSecondary = fg.mixed(with: bg, fraction: 0.40) ?? fg
        let textTertiary = fg.mixed(with: bg, fraction: 0.65) ?? fg

        // accent: ghostty palette 提供则用，否则回退到品牌 amber
        let accentColor = accent ?? (isDark
            ? NSColor(srgbRed: 0.953, green: 0.659, blue: 0.196, alpha: 1)
            : NSColor(srgbRed: 0.850, green: 0.450, blue: 0.050, alpha: 1))
        let accentMuted = accentColor.withAlphaComponent(0.10)

        // status colours: tuned for both dark and light canvases
        let success = isDark
            ? NSColor(srgbRed: 0.247, green: 0.729, blue: 0.314, alpha: 1)  // #3FBA50
            : NSColor(srgbRed: 0.180, green: 0.600, blue: 0.235, alpha: 1)
        let danger = isDark
            ? NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1)  // #F85149
            : NSColor(srgbRed: 0.827, green: 0.184, blue: 0.184, alpha: 1)

        return AppTheme(
            isDark: isDark,
            canvas: bg,
            surface: bg,
            sidebar: sidebar,
            border: border,
            borderStrong: borderStrong,
            textPrimary: fg,
            textSecondary: textSecondary,
            textTertiary: textTertiary,
            accent: accentColor,
            accentMuted: accentMuted,
            success: success,
            danger: danger
        )
    }

    /// 系统外观回退（ghostty 配置完全不可用时）。
    static func systemFallback(isDark: Bool) -> AppTheme {
        derive(background: nil, foreground: nil, accent: nil, systemIsDark: isDark)
    }
}

// MARK: - NSColor helpers

extension NSColor {
    /// sRGB 空间下的线性混色。fraction = 0 → self, 1 → other。
    func mixed(with other: NSColor, fraction: CGFloat) -> NSColor? {
        guard let a = self.usingColorSpace(.sRGB),
              let b = other.usingColorSpace(.sRGB) else { return nil }
        let f = max(0, min(1, fraction))
        return NSColor(
            srgbRed: a.redComponent   * (1 - f) + b.redComponent   * f,
            green:   a.greenComponent * (1 - f) + b.greenComponent * f,
            blue:    a.blueComponent  * (1 - f) + b.blueComponent  * f,
            alpha:   a.alphaComponent * (1 - f) + b.alphaComponent * f
        )
    }
}
