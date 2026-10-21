import SwiftUI
import AppKit

/// 把 SwiftUI 内容延伸到 NSWindow 的 traffic-light 区域下，去掉 hidden-titlebar 留下的顶部空白条。
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let w = v.window { configure(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { configure(w) }
        }
    }
}

extension View {
    /// 让窗口允许内容延伸到标题栏区域，并按 background-opacity 切换窗口本体的不透明度。
    /// - Parameter backgroundOpacity: 当 < 1 时把 window.isOpaque 设为 false 且
    ///   backgroundColor = .clear，让 ghostty surface 的 alpha 透到桌面；= 1 时复原。
    /// - Parameter blurRadius: 仅用于 SwiftUI 依赖跟踪 —— 模糊半径的实际应用由
    ///   ghostty 在 `applyWindowBackgroundBlur` 时从自己的 config 里读。把它作为
    ///   参数传入是为了让 body 观察到值变化时重新渲染，触发 updateNSView 回调，
    ///   否则单独改模糊设置不会立即生效（要等 opacity 一起变才冒泡刷新）。
    /// - Parameter onWindow: 每次 configure 都会回调 —— ContentView 借此拿窗口指针
    ///   递给 GhosttyBridge.applyWindowBackgroundBlur。
    func theAllFullSizeContent(
        backgroundOpacity: CGFloat = 1.0,
        blurRadius: CGFloat = 0,
        onWindow: @escaping (NSWindow) -> Void = { _ in }
    ) -> some View {
        background(
            WindowAccessor { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = false
                if let toolbar = window.toolbar {
                    toolbar.isVisible = false
                }
                let opaque = backgroundOpacity >= 1.0
                window.isOpaque = opaque
                window.backgroundColor = opaque ? nil : .clear
                window.hasShadow = true
                _ = blurRadius
                // 内容靠 SwiftUI 侧 `.ignoresSafeArea()` 顶进标题栏区，但 NSHostingView
                // 仍上报约 28pt 的顶部 safe-area inset（来自标题栏）。这会把 AppKit 代表性
                // 子视图（tab 栏的 TabContentView）整体下推 28pt，而 SwiftUI 仍把它们绘制在
                // 顶部——于是点击可见的 tab 落在真实 AppKit frame 上方 28pt 处，命中不到 pill，
                // 转而被标题栏的拖窗逻辑接管。抵消标题栏的 safe-area 贡献，让绘制与命中共用
                // 同一套坐标系（mouseDownCanMoveWindow=false 链才能真正生效）。
                if let contentView = window.contentView {
                    let titlebarInset = max(0, window.frame.height - window.contentLayoutRect.height)
                    if contentView.additionalSafeAreaInsets.top != -titlebarInset {
                        contentView.additionalSafeAreaInsets = NSEdgeInsets(
                            top: -titlebarInset, left: 0, bottom: 0, right: 0)
                    }
                }
                onWindow(window)
            }
        )
    }
}
