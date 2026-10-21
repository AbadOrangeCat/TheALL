import SwiftUI

struct SettingsView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let updateStore: UpdateStore
    let workspaceStore: WorkspaceStore
    let quickActionsStore: QuickActionsStore
    /// 仅加在 tab 栏左侧的额外预留（section body 仍全宽）：侧边栏折叠时让设置页
    /// tab 栏左沿落到与普通 tab 栏相同的窗口 x，避免顶到左上角的品牌/齿轮/toggle。
    let tabStripLeadingReserve: CGFloat
    let onClose: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.effectiveContentOpacity) private var effectiveContentOpacity
    @State private var section: SettingsSection

    init(
        theme: AppTheme,
        settings: SettingsConfigStore,
        updateStore: UpdateStore,
        workspaceStore: WorkspaceStore,
        quickActionsStore: QuickActionsStore,
        initialSection: SettingsSection? = nil,
        tabStripLeadingReserve: CGFloat = 0,
        onClose: @escaping () -> Void
    ) {
        self.theme = theme
        self.settings = settings
        self.updateStore = updateStore
        self.workspaceStore = workspaceStore
        self.quickActionsStore = quickActionsStore
        self.tabStripLeadingReserve = tabStripLeadingReserve
        self.onClose = onClose
        _section = State(initialValue: initialSection ?? .appearance)
    }

    var body: some View {
        VStack(spacing: 0) {
            // tab 条上方留 xs(4pt) 内缩，对齐 TabContentView.layout 的终端 tab 栏，让分类
            // pill 中心落到 20（cardInset 4 + xs 4 + tbH/2 12）、与交通灯 / 顶部控件同排；
            // 四边内缩一致（左右 / 上 / 下均 xs）。
            SettingsTabBarView(
                theme: theme,
                selection: $section,
                onClose: onClose
            )
            .padding(.top, DT.Space.xs)
            .padding(.leading, DT.Space.xs + tabStripLeadingReserve)
            .padding(.trailing, DT.Space.xs)
            .padding(.bottom, DT.Space.xs)

            // sectionBody + footer 共处同一圆角卡片，边界上的 hairline 由 footer
            // 自带的 overlay 负责；外层 clipShape 把两者一起裁成 stripRadius 圆角，
            // 视觉上是一整块（对齐终端模式下 paneContainer 的形状）。
            VStack(spacing: 0) {
                sectionBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .clipShape(RoundedRectangle(cornerRadius: TabBarView.stripRadius, style: .continuous))
            .padding(.horizontal, DT.Space.xs)
            .padding(.bottom, DT.Space.xs)
        }
        .background(Color(theme.canvas).opacity(effectiveContentOpacity))
        // .tint 通过 env 传给所有 Slider/Toggle/Picker 等，把系统蓝强调色换成主题 accent。
        .tint(Color(theme.accent))
        // 允许 sidebar 的版本号点击在 Settings 已经打开时再次跳转到 Update section。
        .onReceive(NotificationCenter.default.publisher(for: .theAllOpenSettings)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let next = SettingsSection(rawValue: raw) {
                section = next
            }
        }
    }

    // MARK: - Section switcher

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .appearance:   AppearanceSectionView(theme: theme, settings: settings)
        case .font:         FontSectionView(theme: theme, settings: settings)
        case .terminal:     TerminalSectionView(theme: theme, settings: settings)
        case .shell:        ShellSectionView(theme: theme, settings: settings)
        case .quickActions: QuickActionsSectionView(theme: theme, settings: settings, quickActionsStore: quickActionsStore)
        case .agents:       AgentsSectionView(theme: theme, settings: settings, workspaceStore: workspaceStore)
        case .mobile:       MobileAccessSectionView(theme: theme)
        case .update:       UpdateSectionView(theme: theme, updateStore: updateStore)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            TextLinkButton(theme: theme, title: String(localized: (L10n.Settings.footerEdit).withLocale(locale))) {
                settings.openInEditor()
            }
            Spacer()
            Text(L10n.Settings.footerLive)
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textTertiary))
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.sm)
        .background(Color(theme.canvas).opacity(effectiveContentOpacity))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(theme.border).opacity(0.5 * effectiveContentOpacity))
                .frame(height: DT.Stroke.hairline)
        }
    }
}
