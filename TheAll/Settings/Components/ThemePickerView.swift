import SwiftUI

/// Theme 选择器。渲染为 3 个独立 Form 行：
/// 1. "Theme" 模式选择（Single / Follow system）
/// 2. Single/Light 主题下拉
/// 3. Dark 主题下拉（Single 模式下 opacity 0 占位，避免切换抖动）
///
/// 每行使用 LabeledContent 与其他设置项保持相同的 label-value 对齐。
struct ThemePickerView: View {
    let settings: SettingsConfigStore
    let theme: AppTheme

    enum Mode: String, CaseIterable, Identifiable {
        case single, followSystem
        var id: String { rawValue }
    }

    @State private var mode: Mode = .single
    @State private var singleName: String = ""
    @State private var lightName: String = ""
    @State private var darkName: String = ""
    @State private var hasLoaded: Bool = false
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            LabeledContent(String(localized: (L10n.Settings.theme).withLocale(locale))) {
                HStack {
                    Spacer(minLength: 0)
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m == .single ? L10n.Settings.themeSingle : L10n.Settings.themeFollowSystem).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            LabeledContent(String(localized: (mode == .single ? L10n.Settings.themeName : L10n.Settings.themeLight).withLocale(locale))) {
                HStack {
                    Spacer(minLength: 0)
                    ThemeDropdown(
                        selection: Binding(
                            get: { mode == .single ? singleName : lightName },
                            set: {
                                if mode == .single { singleName = $0 } else { lightName = $0 }
                                writeBack()
                            }
                        ),
                        theme: theme
                    )
                }
            }

            LabeledContent(String(localized: (L10n.Settings.themeDark).withLocale(locale))) {
                HStack {
                    Spacer(minLength: 0)
                    ThemeDropdown(
                        selection: Binding(
                            get: { darkName },
                            set: { darkName = $0; writeBack() }
                        ),
                        theme: theme
                    )
                }
            }
            .opacity(mode == .followSystem ? 1 : 0)
            .allowsHitTesting(mode == .followSystem)
        }
        .onAppear {
            // 只在视图实例第一次出现时从 store 拉值。后续重建（例如 Appearance section
            // 切走又切回）跳过，避免覆盖用户在 200ms debounce 期间的未落盘输入。
            guard !hasLoaded else { return }
            hasLoaded = true
            loadFromStore()
        }
    }

    private func loadFromStore() {
        guard let raw = settings.get("theme"), !raw.isEmpty else {
            mode = .single
            singleName = ""
            lightName = ""
            darkName = ""
            return
        }
        if raw.hasPrefix("light:") || raw.contains(",dark:") {
            mode = .followSystem
            for part in raw.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("light:") {
                    lightName = String(p.dropFirst("light:".count))
                } else if p.hasPrefix("dark:") {
                    darkName = String(p.dropFirst("dark:".count))
                }
            }
        } else {
            mode = .single
            singleName = raw
        }
    }

    private func writeBack() {
        switch mode {
        case .single:
            let s = singleName.trimmingCharacters(in: .whitespaces)
            settings.set("theme", s.isEmpty ? nil : s)
        case .followSystem:
            let l = lightName.trimmingCharacters(in: .whitespaces)
            let d = darkName.trimmingCharacters(in: .whitespaces)
            if l.isEmpty && d.isEmpty {
                settings.set("theme", nil)
            } else if !l.isEmpty && !d.isEmpty {
                settings.set("theme", "light:\(l),dark:\(d)")
            }
            // 只有一侧有值时不写 —— 用户正在填，避免生成半截串
            // `theme = light:X,dark:` 让 ghostty 解析失败
        }
    }
}

/// 带搜索的主题下拉。用 popover 自己渲染，避免 macOS Menu 对
/// TextField / ScrollView 的过滤（Menu 内容走 NSMenu，非菜单项子视图不显示）。
private struct ThemeDropdown: View {
    @Binding var selection: String
    let theme: AppTheme

    @Environment(\.effectiveContentOpacity) private var effectiveContentOpacity
    @Environment(\.locale) private var locale
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty
                     ? String(localized: L10n.Settings.themeInherit.withLocale(locale))
                     : selection)
                    .foregroundColor(Color(theme.textPrimary))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(theme.textSecondary))
            }
            .frame(minWidth: 220, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(theme.sidebar).opacity(effectiveContentOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(theme.border).opacity(effectiveContentOpacity), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ThemeDropdownPanel(
                query: $query,
                selection: Binding(
                    get: { selection },
                    set: {
                        selection = $0
                        open = false
                    }
                ),
                theme: theme
            )
            .frame(width: 280, height: 340)
        }
    }
}

/// popover 面板：搜索框 + 可滚动的主题列表。
private struct ThemeDropdownPanel: View {
    @Binding var query: String
    @Binding var selection: String
    let theme: AppTheme

    @Environment(\.locale) private var locale

    /// "继承 Ghostty" 哨兵 id，代表未选择状态（空字符串）。
    /// 用 ForEach 不能直接用空字符串做 id（和合法主题名冲突风险），所以用独立 id。
    private static let inheritRowID = "__theall_inherit__"

    var body: some View {
        VStack(spacing: 0) {
            TextField(String(localized: (L10n.Settings.themeSearchPlaceholder).withLocale(locale)), text: $query)
                .themedTextField(theme)
                .padding(DT.Space.sm)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 仅在未搜索时显示"继承 Ghostty"行，避免在搜索结果里混入哨兵。
                        if query.isEmpty {
                            ThemeRow(
                                name: String(localized: L10n.Settings.themeInherit.withLocale(locale)),
                                isSelected: selection.isEmpty,
                                theme: theme
                            ) {
                                selection = ""
                            }
                            .id(Self.inheritRowID)
                        }
                        ForEach(filtered, id: \.self) { name in
                            ThemeRow(name: name, isSelected: name == selection, theme: theme) {
                                selection = name
                            }
                            .id(name)
                        }
                    }
                }
                .onAppear {
                    // LazyVStack 要等一帧才渲染出目标行，立即 scrollTo 会失败。
                    DispatchQueue.main.async {
                        let target = selection.isEmpty ? Self.inheritRowID : selection
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .background(Color(theme.canvas))
        // popover 创建独立 NSWindow，不继承父窗口 NSAppearance。显式锁到主题亮度，
        // 否则搜索框的 .roundedBorder 会在系统浅色外观下渲染成刺眼的白底。
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var filtered: [String] {
        guard !query.isEmpty else { return ThemeCatalog.all }
        let lower = query.lowercased()
        return ThemeCatalog.all.filter { $0.lowercased().contains(lower) }
    }
}

private struct ThemeRow: View {
    let name: String
    let isSelected: Bool
    let theme: AppTheme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .foregroundColor(Color(theme.textPrimary))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(theme.accent))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hovering ? theme.border : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
