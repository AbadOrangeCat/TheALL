import SwiftUI

/// 给 TextField 套上主题样式：文字色走 textPrimary，背景走 sidebar，
/// 边框 hairline 用 border。系统 `.roundedBorder` 在非系统-默认的主题背景下
/// 会显得像一块贴错地方的深灰补丁；这个样式与 ThemeDropdown 的按钮一致。
struct ThemedTextFieldStyle: ViewModifier {
    let theme: AppTheme

    @Environment(\.effectiveContentOpacity) private var effectiveContentOpacity

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            // LabeledContent 的值列默认 trailing 对齐，`.plain` 样式会继承，
            // 文字会从右往左贴着边输入。显式锁到 leading 保证正常左对齐。
            .multilineTextAlignment(.leading)
            .foregroundColor(Color(theme.textPrimary))
            .padding(.horizontal, DT.Space.sm)
            .padding(.vertical, DT.Space.xs + 1)
            .background(
                RoundedRectangle(cornerRadius: DT.Radius.row, style: .continuous)
                    .fill(Color(theme.sidebar).opacity(effectiveContentOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.Radius.row, style: .continuous)
                    .strokeBorder(Color(theme.border).opacity(effectiveContentOpacity), lineWidth: DT.Stroke.hairline * 0.5)
            )
    }
}

extension View {
    func themedTextField(_ theme: AppTheme) -> some View {
        modifier(ThemedTextFieldStyle(theme: theme))
    }
}
