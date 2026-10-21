# 中英国际化（i18n）设计方案

- **日期**：2026-04-19
- **分支**：`agent/i18n-zh-en`
- **Worktree**：`~/.config/superpowers/worktrees/TheAll/agent-i18n/`
- **作者**：Claude (opus-4-7[1m]) 与用户对话共同产出

## 背景与目标

theall 目前所有 UI 文案是硬编码字符串（部分英文、部分中文，例如删除确认 alert "「…」及其所有 tab 将被删除"），没有任何 i18n 基础设施。目标是：

1. 在 Settings 面板的 **Appearance** 分类中新增一行 **Language**，提供 `System / 中文 / English` 三选一。
2. 选项持久化到 UserDefaults。
3. 切换语言**立即生效**（不需重启 app），所有 UI 文案（Sidebar / Settings 面板 / 菜单栏 / Ghostty 错误页等）同步刷新。
4. 首期覆盖**全部用户可见文案**（约 60–80 条 key）。

## 约束

- **不新增 sidebar footer 按钮**：入口只在 Settings 里。
- **SwiftUI + AppKit 混合切换**：必须既能驱动 SwiftUI 视图重绘，又能让 AppKit 子类（TabBarView/WorkspaceRowItemView 等）刷新 label。
- **不改变既有架构模式**：沿用 `@Observable` store + `*Bridge: NSViewRepresentable` + `tick` 参数的现有模式（参考 `SidebarListBridge.metadataTick`）。
- **不修改 `project.yml` 中的目录结构约束**（修改时需显式征求用户确认，参见 CLAUDE.md "禁止"条款）。

## 架构

### 数据流

```
                  UserDefaults("theall.language")
                           │
                           ▼
           ┌───────────────────────────────┐
           │  LanguageStore (@Observable)  │  ← 全局单例，TheAllApp 启动实例化
           │  • preference: Preference     │    .system / .zh / .en
           │  • effectiveBundle: Bundle    │  ← 派生属性
           │  • tick: Int (AppKit 触发器)   │
           └────────┬──────────────────────┘
                    │ environment 注入
         ┌──────────┴──────────┐
         ▼                     ▼
   SwiftUI 视图           AppKit 视图（经 *Bridge）
   Text(L10n.xxx)         语言切换时由 SwiftUI 父视图
   （@Observable 自动       读 tick 触发 updateNSView，
    驱动 body 重跑）         AppKit 侧重读所有 stringValue
```

### 模块划分

新增目录 `TheAll/Localization/`：

| 文件 | 职责 |
|------|------|
| `LanguageStore.swift` | `@Observable class`，单例。持有 `preference: Preference` 与派生的 `effectiveBundle: Bundle`，持久化到 UserDefaults（key `theall.language`），切换时 `tick &+= 1`。 |
| `Strings.xcstrings` | Xcode String Catalog，English 为 source，中文为翻译列。所有 key 走 dotted namespace。 |
| `L10n.swift` | 常量层。`enum L10n { enum Sidebar { … } enum Settings { … } enum Menu { … } }`。避免魔法字符串散落。SwiftUI 侧暴露 `LocalizedStringResource`，AppKit 侧暴露 `L10n.string(_:args:)` 帮手。 |

`Preference` 枚举：

```swift
enum Preference: String, Codable, CaseIterable {
    case system
    case zh        // zh-Hans（简体）
    case en        // en
}
```

`effectiveBundle` 解析逻辑：

```swift
var effectiveBundle: Bundle {
    let code: String
    switch preference {
    case .system:
        code = Locale.current.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
    case .zh: code = "zh-Hans"
    case .en: code = "en"
    }
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
          let bundle = Bundle(path: path)
    else { return .main }
    return bundle
}
```

### L10n 常量层

```swift
enum L10n {
    // SwiftUI 用（类型是 LocalizedStringResource）
    enum Sidebar {
        static let title           = LocalizedStringResource("sidebar.title")
        static let newWorkspace    = LocalizedStringResource("sidebar.newWorkspace")
        static let settings        = LocalizedStringResource("sidebar.settings")
        static let deleteAlert     = LocalizedStringResource("sidebar.deleteAlert.title")
        // …
    }
    enum Settings { /* … */ }
    enum Menu { /* … */ }

    // AppKit 用（返回 String）
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let bundle = LanguageStore.shared.effectiveBundle
        let raw = bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? raw : String(format: raw, arguments: args)
    }
}
```

**SwiftUI 调用**：`Text(L10n.Sidebar.newWorkspace)`。`LocalizedStringResource` 会自动走当前 `Locale`，但我们要让 `LanguageStore.preference` 覆盖系统 Locale。做法：通过 `.environment(\.locale, languageStore.locale)` 在 `ContentView` 根部注入 locale；AppKit 子视图走 `effectiveBundle` 手动查。

**AppKit 调用**：`myLabel.stringValue = L10n.string("sidebar.newWorkspace")`。

### 即时切换刷新

**SwiftUI 侧**：`LanguageStore` 是 `@Observable`；视图通过 `@Environment(LanguageStore.self)` 读取；`preference` 变化 → `@Observable` 通知 → body 重跑。同时向下传递 `.environment(\.locale, …)` 让 `LocalizedStringResource` 选对 bundle。

**AppKit 侧**：
- 每个受影响的 `*Bridge: NSViewRepresentable`（TabBridge、SidebarListBridge、SettingsTabBarView 如果是 AppKit 部分等）签名新增 `languageTick: Int` 参数。
- 父 SwiftUI 视图在构造 bridge 时读取 `languageStore.tick`（`@Observable` 自动追踪）并透传。
- 语言切换 → `LanguageStore.tick &+= 1` → SwiftUI 检测到 bridge 构造参数变化 → 触发 `updateNSView` → AppKit 子类调用内部方法 `refreshLocalizedStrings()`，重读每个 label/tooltip 的 `stringValue`。

该模式与现有 `SidebarListBridge.metadataTick` 完全一致，不引入新概念。

## UI 呈现

### Appearance 分类新增 Language 行

位置：`Settings/Sections/AppearanceSectionView.swift`，在 Theme / Opacity / Blur 字段之后。

```
┌─ Appearance ──────────────────────────────────────┐
│  Theme         [dropdown picker        ▼]         │
│  Opacity       [slider ────●────]   0.92          │
│  Blur          [toggle ●]                         │
│  …                                                │
│  Language      [System              ▼]  ← 新增    │
│                ├ System                            │
│                ├ 中文（简体）                       │
│                └ English                           │
└───────────────────────────────────────────────────┘
```

**交互细节**：

- 使用现有 `BoundPicker` 组件（见 `Settings/Components/BoundControls.swift`）。
- Picker 绑定到 `languageStore.preference`（通过 `@Bindable` 暴露）。
- 三个选项文本策略：
  - `System`：根据当前语言显示 `System` / `跟随系统`
  - `中文（简体）`：**永远**显示为"中文（简体）"（硬编码）
  - `English`：**永远**显示为"English"（硬编码）
- `SettingsResetRow` 的 reset 操作会把 preference 重置为 `.system`。

### 字符串 Catalog 组织

所有 key 走 dotted namespace，namespace 与 UI 模块对应：

```
Strings.xcstrings（零散代表）
  ├─ sidebar.title                           → "theall"
  ├─ sidebar.newWorkspace                    → "New workspace"
  ├─ sidebar.settings                        → "Settings"
  ├─ sidebar.deleteAlert.title               → "Delete workspace?"
  ├─ sidebar.deleteAlert.message (%@)        → "『%@』will be deleted with all its tabs. This action cannot be undone."
  ├─ sidebar.deleteAlert.cancel              → "Cancel"
  ├─ sidebar.deleteAlert.confirm             → "Delete"
  │
  ├─ tab.newTab                              → "New tab"
  │
  ├─ settings.section.appearance / font / terminal / shell
  ├─ settings.close                          → "Close settings"
  ├─ settings.footer.edit                    → "Edit Config File…"
  ├─ settings.footer.live                    → "Changes apply live."
  ├─ settings.appearance.theme / opacity / blur / language
  ├─ settings.language.system / zh / en
  ├─ settings.font.family / size / default / custom
  ├─ settings.terminal.* (按 TerminalSectionView 字段)
  ├─ settings.shell.* (按 ShellSectionView 字段)
  ├─ settings.reset.title / message
  │
  ├─ app.ghostty.notFound.title              → "Ghostty not found"
  ├─ app.ghostty.notFound.detail
  │
  └─ menu.* (覆盖 TheAllApp 的 Commands 里每一项)
```

预计总量 **60–80 条 key**。英文作 source，中文手工翻译。Catalog 会自动追踪 key 在代码中的引用，便于日后清理。

## 受影响文件清单

| 类型 | 文件 |
|------|------|
| **新增** | `TheAll/Localization/LanguageStore.swift` |
| **新增** | `TheAll/Localization/L10n.swift` |
| **新增** | `TheAll/Localization/Strings.xcstrings`（Xcode 编辑） |
| **新增** | `TheAllTests/LanguageStoreTests.swift` |
| **新增** | `TheAllTests/L10nSmokeTests.swift` |
| **改** | `TheAll/TheAllApp.swift`（实例化 LanguageStore + 注入 environment；替换硬编码文案；Commands 菜单项改 key） |
| **改** | `TheAll/ContentView.swift`（.environment(\.locale) 注入） |
| **改** | `TheAll/Sidebar/SidebarView.swift`（所有 Text/tooltip/alert 走 L10n） |
| **改** | `TheAll/Sidebar/WorkspaceListView.swift`（AppKit 行视图，读 tick 重建） |
| **改** | `TheAll/Bridge/SidebarListBridge.swift`（新增 languageTick 参数） |
| **改** | `TheAll/Bridge/TabBridge.swift`（同上） |
| **改** | `TheAll/TabContent/TabBarView.swift`（AppKit tab 的 tooltip / 空态文案） |
| **改** | `TheAll/TabContent/TabContentView.swift`（refresh 方法） |
| **改** | `TheAll/Settings/SettingsView.swift`（footer 文案） |
| **改** | `TheAll/Settings/SettingsSection.swift`（`label` 返回 LocalizedStringResource 而非 String） |
| **改** | `TheAll/Settings/SettingsTabBarView.swift`（close tooltip） |
| **改** | `TheAll/Settings/Sections/AppearanceSectionView.swift`（新增 Language 行 + 现有字段走 L10n） |
| **改** | `TheAll/Settings/Sections/FontSectionView.swift` |
| **改** | `TheAll/Settings/Sections/TerminalSectionView.swift` |
| **改** | `TheAll/Settings/Sections/ShellSectionView.swift` |
| **改** | `TheAll/Settings/Components/SettingsResetRow.swift` |
| **改** | `TheAll/Settings/Components/FontPickerView.swift`（"(default)" / "Custom…"） |
| **改** | `project.yml`（把 `TheAll/Localization/Strings.xcstrings` 加入 resources）— **修改 project.yml 会显式征求用户确认后再动** |
| **改** | `CLAUDE.md` / `AGENTS.md`（Directory Structure 加 Localization/；Common Tasks 加"新增文案 / 支持新语言"） |
| **改** | `docs/architecture.md`（加 i18n 章节） |
| **新增** | `docs/i18n.md`（开发者指南：如何加新 key、如何支持第三种语言） |

## 测试策略

- **`LanguageStoreTests`**：
  - 默认值为 `.system`
  - UserDefaults 读写往返
  - `effectiveBundle` 在不同 `preference` 下返回的 bundle path 正确
  - `tick` 在 `preference` 变化时自增
  - `.system` 模式下，mock `Locale.current` 的 language code 为 `"zh"` 时返回 zh bundle，其他返回 en bundle
- **`L10nSmokeTests`**：
  - 列出 Catalog 的所有 key，对每个 key 在 zh 和 en bundle 下查 `NSLocalizedString`，断言返回值非 key 本身（防漏翻译）
  - 对带 `%@` 占位符的 key，格式化后不崩且不含 `%@`
- **不测 SwiftUI 快照**：成本高，收益低。

CI 通过条件：`xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests` 全绿。

## 实施顺序

按以下独立、可验证的增量步骤：

1. **基础设施**：新增 `LanguageStore` + `L10n` 骨架 + 空 `Strings.xcstrings` + 注入到 `TheAllApp` / `ContentView`。单测 `LanguageStoreTests`。**暂不改任何现有视图**。
2. **Sidebar**：迁移 `SidebarView` / `WorkspaceListView` / `SidebarListBridge`。人工验证删除 alert / tooltip 在两种语言下都正确。
3. **Tab 条 & Bridge**：迁移 `TabBarView` / `TabContentView` / `TabBridge`。
4. **Settings 面板**：迁移 `SettingsSection.label` + `SettingsView` + 四个 Section + `SettingsResetRow` + `FontPickerView`。
5. **Appearance 新增 Language 行**：在 `AppearanceSectionView` 加 Picker，绑定 `LanguageStore.preference`。人工验证三个选项切换即时生效。
6. **App 级**：迁移 `TheAllApp` 的 Ghostty not-found 错误页和 Commands 菜单项。
7. **Smoke 测试**：写 `L10nSmokeTests`，补齐遗漏翻译。
8. **文档**：更新 CLAUDE.md / AGENTS.md / `docs/architecture.md`；新增 `docs/i18n.md`；跑 `./scripts/check-doc-drift.sh`。

每一步独立验证、独立提交，commit 格式按 CLAUDE.md 第 5 条：`feat(i18n-zh-en): add LanguageStore` 之类。其中 `i18n` 不是既有 scope，**将在第 1 步同时向 CLAUDE.md 的合法 scope 列表里加入 `i18n`**。

## 已解决的设计决策

1. **Q**：语言入口形态 → **A**：Settings 面板 Appearance 分类里新增一行 Picker，不加 sidebar footer 按钮
2. **Q**：选项集 → **A**：`System / 中文（简体）/ English`
3. **Q**：持久化位置 → **A**：UserDefaults（不进 ghostty config 文件）
4. **Q**："System" 解析 → **A**：`Locale.current.language.languageCode == "zh"` → 中文，其他 → 英文
5. **Q**：Picker 选项文本 → **A**：中文、英文选项文本硬编码（永远显示本语言名字），System 随当前语言变化
6. **Q**：覆盖范围 → **A**：全量（Sidebar + Tab + Settings + 菜单 + 错误页）
7. **Q**：技术方案 → **A**：String Catalog + `@Observable LanguageStore` + `tick` 驱动 AppKit
8. **Q**：AppKit 刷新机制 → **A**：复用 `*Bridge.metadataTick` 模式，新增 `languageTick` 参数

## 风险与注意事项

- **AppleLanguages 不再需要**：原方案预计用 `UserDefaults.set(["zh-Hans"], forKey: "AppleLanguages")` + 重启，但靠 `.environment(\.locale)` + 显式 bundle 查找即可做到无重启切换，且不影响 Cocoa 级别的 menu bar 外观。
- **菜单栏（`TheAllApp.Commands`）即时切换**：SwiftUI `Commands` 由系统管理，`LocalizedStringResource` 走 `\.locale` 环境应自动生效。若实测发现菜单不随 `\.locale` 切换，降级方案是在 `TheAllApp` 里用 `@State var languageTick` 触发整个窗口重建（已经有 `windowTick` 或类似模式可参考）。
- **格式化占位符**：`sidebar.deleteAlert.message` 用 `%@` 而非 Swift string interpolation，确保翻译列能自己决定占位符在句中的位置。
- **混合字体**："中文（简体）" 与 "English" 并置时 DT.Font.body 对中英文都能渲染，无须额外配置。
- **测试稳定性**：`L10nSmokeTests` 把 key 列表作常量硬编码，避免 `.xcstrings` 被解析成私有格式。Xcode build 时 `.xcstrings` 会被拆成 `zh-Hans.lproj/Strings.strings` 等，测试用 `Bundle(for: class).path(forResource: "zh-Hans", ofType: "lproj")` 取 bundle 即可。
