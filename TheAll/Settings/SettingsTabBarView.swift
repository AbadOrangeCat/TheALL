import SwiftUI
import AppKit

/// 只读水平 tab 条 + 右侧 × 关闭按钮。
/// 视觉复刻 TabContent/TabBarView（左侧 strip 含 pills、右侧 28pt 外置按钮），
/// 但交互上：pills 只读、右侧按钮是关闭而非新建。
struct SettingsTabBarView: View {
    let theme: AppTheme
    @Binding var selection: SettingsSection
    let onClose: () -> Void

    @Environment(\.effectiveContentOpacity) private var effectiveContentOpacity
    @Environment(\.locale) private var locale

    var body: some View {
        let opacity = effectiveContentOpacity
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: TabBarView.stripRadius, style: .continuous)
                    .fill(Color(theme.sidebar).opacity(opacity))
                // 6 个固定 section 均分 strip 宽度：每个 pill 上限 tabItemWidth（140pt），
                // 窗口窄到装不下时整体等比缩小，避免固定 140pt 总宽 (~860pt) 撑破卡片右缘。
                HStack(spacing: TabBarView.pillInset) {
                    ForEach(SettingsSection.allCases) { section in
                        pill(for: section)
                    }
                }
                .padding(.horizontal, TabBarView.pillInset)
            }
            .frame(maxWidth: .infinity)

            IconButton(theme: theme, help: String(localized: (L10n.Settings.close).withLocale(locale)), action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(theme.textSecondary))
            }
            .frame(width: 28)
        }
        .frame(height: TabBarView.height)
    }

    private func pill(for section: SettingsSection) -> some View {
        let isSelected = selection == section
        let pillHeight = TabBarView.height - 2 * TabBarView.pillInset
        return Button {
            selection = section
        } label: {
            // 字号与 TabItemView 对齐：DT.Font.small、文字左对齐 10pt margin。
            // Text 用 maxWidth .infinity 填满 button label；button 自身再用
            // maxWidth tabItemWidth 设上限，HStack 因此能均分 strip 宽度，
            // 窗口窄时 6 个 pill 等比缩小，避免溢出；窗口宽时停在 140pt。
            Text(section.label)
                .font(Font(DT.Font.small))
                .foregroundColor(Color(isSelected ? theme.textPrimary : theme.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity,
                       minHeight: pillHeight,
                       maxHeight: pillHeight,
                       alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TabBarView.pillRadius, style: .continuous)
                        .fill(Color(isSelected ? theme.canvas : .clear)
                            .opacity(isSelected ? effectiveContentOpacity : 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: TabBarView.tabItemWidth)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
