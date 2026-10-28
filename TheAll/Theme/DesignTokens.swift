import AppKit

/// theall 设计 token——所有 UI 必须走这里，禁止魔法数字。
enum DT {

    // MARK: - Spacing (4pt scale)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius
    enum Radius {
        static let chip:   CGFloat = 4
        static let row:    CGFloat = 6
        static let window: CGFloat = 8
        /// 外层内容卡片圆角。嵌套圆角请用 `card - 内缩距离` 保持同心一致。
        static let card:   CGFloat = 12
    }

    // MARK: - Stroke
    enum Stroke {
        static let hairline: CGFloat = 1
        static let focus:    CGFloat = 1   // 焦点也只用 1px，靠颜色区分
    }

    // MARK: - Font (UI 字号严格控制在 10..13)
    enum Font {
        static let micro:  NSFont = .systemFont(ofSize: 10, weight: .regular)
        static let microB: NSFont = .systemFont(ofSize: 10, weight: .semibold)
        static let small:  NSFont = .systemFont(ofSize: 11, weight: .regular)
        static let smallB: NSFont = .systemFont(ofSize: 11, weight: .medium)
        static let body:   NSFont = .systemFont(ofSize: 12, weight: .regular)
        static let bodyB:  NSFont = .systemFont(ofSize: 12, weight: .semibold)
        static let title:  NSFont = .systemFont(ofSize: 13, weight: .semibold)
        static let mono:   NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    // MARK: - Chat layout (shared visual rhythm across desktop and mobile)
    enum Chat {
        static let contentWidth: CGFloat = 880
        static let controlHeight: CGFloat = 32
        static let editorHeight: CGFloat = 96
        static let messageRadius: CGFloat = 12
    }

    // MARK: - Motion (默认零；这里只声明允许的极少数过渡)
    enum Motion {
        /// 焦点 / 选中态颜色过渡。线性，80ms。
        static let stateChange: CFTimeInterval = 0.08
    }

    // MARK: - Layout
    enum Layout {
        static let sidebarWidth: CGFloat = 200
        static let titleBarHeight: CGFloat = 28
        static let dotGridSpacing: CGFloat = 24
        static let dotGridDotSize: CGFloat = 1
    }
}

// MARK: - NSColor helper
extension NSColor {
    /// 用 sRGB 三元组创建 NSColor，alpha 默认 1。
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
