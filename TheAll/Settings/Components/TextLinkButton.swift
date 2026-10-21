import SwiftUI
import AppKit

/// 文字型链接按钮：hover 变主文字色 + 下划线，按下稍淡；鼠标悬停显示 pointing hand。
struct TextLinkButton: View {
    let theme: AppTheme
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font(DT.Font.small))
                .underline(hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(TextLinkButtonStyle(theme: theme, hovering: hovering))
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct TextLinkButtonStyle: ButtonStyle {
    let theme: AppTheme
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(color(pressed: configuration.isPressed))
    }

    private func color(pressed: Bool) -> Color {
        if pressed {
            return Color(theme.textTertiary)
        } else if hovering {
            return Color(theme.textPrimary)
        }
        return Color(theme.textSecondary)
    }
}
