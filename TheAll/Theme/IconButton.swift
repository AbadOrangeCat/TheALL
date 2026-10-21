import SwiftUI
import AppKit

/// 紧凑图标按钮：hover 显示 `theme.border` 圆角方块，按下切到 `theme.borderStrong`。
/// 视觉与 sidebar row 的 hover/selected 保持一致，用于标题栏/侧边栏头部的图标入口。
struct IconButton<Label: View>: View {
    let theme: AppTheme
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonHoverStyle(theme: theme, hovering: hovering))
        .help(help)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct IconButtonHoverStyle: ButtonStyle {
    let theme: AppTheme
    let hovering: Bool

    @Environment(\.effectiveContentOpacity) private var effectiveContentOpacity

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DT.Radius.row, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
    }

    private func fill(pressed: Bool) -> Color {
        // 交互反馈继承窗口背景透明度 —— 乘 effectiveContentOpacity 让按钮 hover /
        // press 时的色块和整体半透背景保持同档浓度，不会突兀。
        if pressed {
            return Color(theme.borderStrong).opacity(effectiveContentOpacity)
        } else if hovering {
            return Color(theme.border).opacity(effectiveContentOpacity)
        }
        return .clear
    }
}
