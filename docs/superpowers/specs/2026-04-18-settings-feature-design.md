# 设置功能 Design

> Status: draft · 2026-04-18

## 目的

theall 是 ghostty 的 fork 封装，终端样式（主题 / 字体 / 字号 / padding / 光标等）本质上都是 ghostty config 字段。当前用户只能通过手动编辑 `~/Library/Application Support/com.mitchellh.ghostty/config` 修改这些值，门槛高、不可发现。

本设计引入一个应用内 **Settings 视图**，把常用 ghostty 配置项通过 GUI 暴露出来；不常用的高级字段（keybind / font-feature / 复杂规则）继续走"打开原始配置文件"菜单项，保持和原生 ghostty 一致的手改体验。

## 范围

**In scope**
- Sidebar 左下角齿轮入口按钮
- 右侧内容区的 Settings 视图（水平分类 tab + Form）
- 四个分类：Appearance / Font / Terminal / Shell
- theall 独立的 override config 文件读写
- App menu 的 `Settings…` 和 `Edit Config File…` 入口
- Theme 选择器（单主题 + 跟随系统双主题）
- 重启生效模型（在视图内显式提示）

**Out of scope**
- 热重载、新 surface 用新值、或 surface 配置重下发——全部需重启
- Keybindings 的 GUI 编辑
- 导入 / 导出 / 预设
- GUI 里验证字段合法性的复杂规则（交给 ghostty 解析时自检）
- palette（256 色盘）的 GUI 编辑
- 设置搜索框

## 视图状态模型

设置是一个独立视图模式（非 Sheet、非特殊 workspace）。

`ContentView` 增加 `@State showSettings: Bool = false`：
- `showSettings == false`：右侧渲染 `TabBridge`（现有行为）
- `showSettings == true`：右侧渲染 `SettingsView`

**切换触发**
| 动作 | 效果 |
|---|---|
| 点击 sidebar footer 齿轮按钮 | `showSettings.toggle()` |
| 点击 App menu `theall > Settings…`（⌘,） | `showSettings = true` |
| Settings 视图 header 的 `×` | `showSettings = false` |
| 点击 sidebar 任一 workspace row | `showSettings = false` + 选中 workspace |

`showSettings` 不持久化：重启 theall 回到上次选中的 workspace。

Sidebar 折叠态（`sidebarCollapsed == true`）下，齿轮按钮跟随隐藏；进入设置只能通过菜单或先展开 sidebar。

## 布局

```
┌──────────────────────────────────────────────────┐
│ sidebar │ [分类1]  [分类2]  [分类3]  [分类4]        │ ← 水平分类 tab（只读）
│  组1    ├──────────────────────────────────────┤
│  组2    │                                        │
│  组3    │       Form 区（当前分类的字段）           │
│  ...    │                                        │
│         │                                        │
│ [⚙ 设置]│                                        │
└─────────┴────────────────────────────────────────┘
```

**Sidebar**
- 完全不动 workspace 列表
- Footer 新增齿轮 IconButton，位于 sidebar 底部左下角

**右侧内容区**
- 顶部：水平分类 tab 条（视觉复刻 workspace 的 `TabBarView`，相同 pill 形状 + 相同 AppTheme token）
- 只读交互：无右键菜单、无拖拽、无关闭按钮、无 `+` 按钮；四个分类硬编码不可增删
- 底部：选中分类的 Form 表单
- Footer：一行提示 "Restart theall to apply changes."
- Header 右侧：`×` 关闭按钮

**分类（enum `SettingsSection`）**
- `.appearance` — 外观
- `.font` — 字体
- `.terminal` — 终端行为
- `.shell` — Shell 集成

## 字段清单

所有字段改动 **onChange → debounce 200ms → 写文件**（改即存）；不提供 Save / Revert 按钮。

### Appearance

| Label | ghostty key | 控件 | 范围 / 选项 |
|---|---|---|---|
| Theme | `theme` | 见下文 5.1 | vendor themes 目录 486 项 |
| Background Opacity | `background-opacity` | Slider | 0.0–1.0 step 0.05 |
| Background Blur | `background-blur-radius` | Slider | 0–100 step 1 |
| Window Padding X | `window-padding-x` | Stepper | 0–100 |
| Window Padding Y | `window-padding-y` | Stepper | 0–100 |
| Cursor Style | `cursor-style` | Segmented | `block` / `bar` / `underline` |
| Cursor Blink | `cursor-style-blink` | Toggle | true / false |
| Unfocused Split Opacity | `unfocused-split-opacity` | Slider | 0.0–1.0 step 0.05 |

### Font

| Label | ghostty key | 控件 | 说明 |
|---|---|---|---|
| Font Family | `font-family` | 下拉 + 自定义文本框 | 下拉枚举 `NSFontManager.availableFontNames(with: .fixedPitchFontMask)`；选 "Custom…" 切换为文本框自填 |
| Font Size | `font-size` | Stepper | 6–72 |
| Font Thicken | `font-thicken` | Toggle | true / false |

### Terminal

| Label | ghostty key | 控件 | 选项 |
|---|---|---|---|
| Scrollback Limit | `scrollback-limit` | 数字 TextField | ≥ 0 |
| Copy On Select | `copy-on-select` | 下拉 | `false` / `true` / `clipboard` |
| Mouse Hide While Typing | `mouse-hide-while-typing` | Toggle | true / false |
| Confirm Close Surface | `confirm-close-surface` | 下拉 | `false` / `true` / `always` |

### Shell

| Label | ghostty key | 控件 | 选项 |
|---|---|---|---|
| Shell Integration | `shell-integration` | 下拉 | `detect` / `none` / `fish` / `zsh` / `bash` |
| Integration Features | `shell-integration-features` | 多选 | `cursor` / `sudo` / `title` / `ssh-env` |
| Custom Command | `command` | 文本框 | 绝对路径或命令串，空=默认 shell |

### 字段通用写入规则

1. 值等于 ghostty 默认 → 从 theall config 文件删除该行（不写空 key）
2. 空字符串 → 不写 row；UI 显示 placeholder "(default)"
3. 多选字段（`shell-integration-features`）按 `a,b,c` 写；空列表等价未设置
4. 数字字段走 Stepper 或带输入校验的 TextField；非法输入不触发写文件

## 5.1 Theme 选择器

ghostty 支持两种 `theme =` 写法：

1. 单主题：`theme = Name`
2. 双主题（跟随系统）：`theme = light:LightName,dark:DarkName`

**UI**
```
Theme:
  ○ Single     [Catppuccin Latte          ▼]
  ● Follow system appearance
      Light    [Catppuccin Latte          ▼]
      Dark     [Catppuccin Mocha          ▼]
```

- 顶部 radio 两选
- 下拉框 = 搜索式 `Menu { TextField + ForEach(filtered) }`
- 主题列表 = 扫描 `Vendor/ghostty/share/ghostty/themes/` 下所有文件名（bundle 里 `Bundle.main.resourcePath/ghostty/themes`）
- 扫描一次缓存到 `ThemeCatalog` static

**写入**
- Single 模式：`theme = <name>`
- Follow-system 模式：`theme = light:<light>,dark:<dark>`

**读回**
- 解析 theall config 的 `theme` 字段：
  - 值以 `light:` 开头 → 解析成 follow-system 模式
  - 否则 → Single 模式
- 不存在 → 从用户的 ghostty config 读作展示值（只读展示，不写 override）

## 持久化与合并

### 文件位置
`~/Library/Application Support/theall/config`

- 语法：ghostty `key = value`（和 ghostty config 一致）
- 首次启动不存在则不创建；用户第一次从 GUI 修改任一字段才创建

### 启动时加载顺序（`GhosttyBridge.initialize()`）

```
1. ghostty_config_load_default_files(cfg)      ← 现有
2. ghostty_config_load_recursive_files(cfg)    ← 现有
3. resources-dir 临时 conf                      ← 现有
4. ghostty theme override (resolvedThemePath)  ← 现有
5. theall override config                         ← 新增
6. ghostty_config_finalize(cfg)                 ← 现有
```

步骤 5 使得 theall override 是最后写入的一层，按 ghostty 语义覆盖前面所有来源。

### `SettingsConfigStore`（新模块）

```
Settings/SettingsConfigStore.swift
```

- `@Observable`
- 负责：读取 / 内存缓存 / 写回 `~/Library/Application Support/theall/config`
- 保留文件原始**顺序、注释、未识别 key、重复 key**（例如 palette 行）
- 内部表示 = `[ConfigLine]`，`ConfigLine` 枚举：`.comment(String)`、`.blank`、`.kv(key, value, rawLine)`、`.unknown(String)`

**接口**
```swift
func get(_ key: String) -> String?
func set(_ key: String, _ value: String?)  // value == nil 删除该 key 行
```

**写盘策略**
- `set` 会立即修改内存数组，然后 debounce 200 ms 异步写回文件
- 写使用 `String.write(toFile:atomically: true, encoding: .utf8)`
- 如果 key 已存在：原地替换值、保留前后空白
- 如果 key 不存在：append 到文件尾，前面空一行分隔

**读盘策略**
- 启动时一次性读入；运行期不监听文件变动（简化；用户改完文件必然重启才生效）

### 两来源显示语义

字段在 GUI 里展示的**当前值**来源：

1. theall config 里有该 key → 显示 override 值
2. theall config 里没有 → 显示 ghostty 本体 config 的值（通过 `GhosttyConfigReader` 解析用户 ghostty 主 config，**只读展示**）
3. 两处都没有 → 显示 ghostty 默认值（硬编码在字段定义里，或用 `ghostty_config_get` 取）

**修改行为统一写 theall config**：即使当前值是从 ghostty 主 config 读的，用户改动也只写 theall override，不改 ghostty 主文件。

## 菜单栏

在 App menu（`theall > …`）加两项，位于 `About theall` 下方：

| 菜单项 | 快捷键 | 动作 |
|---|---|---|
| Settings… | ⌘, | post `.theAllOpenSettings` |
| Edit Config File… | 无 | 若 `~/Library/Application Support/theall/config` 不存在则 touch 创建空文件，然后 `NSWorkspace.shared.open(url)` |

实现：在 `TheAllApp.swift` commands builder 里 `CommandGroup(replacing: .appSettings) { ... }` 注入。

**新增 Notification.Name**（`ContentView.swift` extension）
- `.theAllOpenSettings`
- `.theAllEditConfigFile`

`ContentView` 分别订阅两者：
- `theAllOpenSettings` → `showSettings = true`
- `theAllEditConfigFile` → 直接调用 `SettingsConfigStore.openConfigFileInEditor()`（工具方法 touch + NSWorkspace.open）

## 模块结构

### 新增 `TheAll/Settings/`

```
TheAll/Settings/
├── SettingsConfigStore.swift
├── SettingsSection.swift
├── SettingsView.swift
├── SettingsTabBarView.swift
├── ThemeCatalog.swift
├── Sections/
│   ├── AppearanceSectionView.swift
│   ├── FontSectionView.swift
│   ├── TerminalSectionView.swift
│   └── ShellSectionView.swift
└── Components/
    ├── ThemePickerView.swift
    ├── FontPickerView.swift
    └── BoundControls.swift
```

### 现有文件改动

| 文件 | 改动 |
|---|---|
| `TheAllApp.swift` | App menu `Settings… ⌘,` + `Edit Config File…`，post 对应 Notification |
| `ContentView.swift` | `@State showSettings`、`@State settingsStore = SettingsConfigStore()`；右侧根据 flag 切换 `TabBridge` / `SettingsView`；订阅两个新 Notification；sidebar workspace 点击时自动 `showSettings = false`；声明 `.theAllOpenSettings`、`.theAllEditConfigFile` |
| `Sidebar/SidebarView.swift` | 在 VStack 末尾加 footer 区 + 齿轮 IconButton；点击 post `.theAllOpenSettings`；sidebar 折叠态由 ContentView 控制显示，footer 本身无感知 |
| `Ghostty/GhosttyBridge.swift` | `initialize()` 在 `finalize` 前加载 `~/Library/Application Support/theall/config`（如存在） |

### 不动的模块

- `Models/WorkspaceStore.swift`
- `Canvas/*`
- `TabContent/*`
- `Metadata/*`
- `Theme/ThemeManager.swift`
- `project.yml`（xcodegen 自动 glob `TheAll/**/*.swift`）

## 设计不变量

1. **Settings UI 不共享 WorkspaceStore** —— settings 状态完全独立于 workspace 数据层
2. **GUI 只写 theall override 文件** —— 永不改用户的 ghostty 主 config
3. **未识别字段保留不动** —— 用户手写在 theall config 里的内容（keybind / 复杂规则 / palette）不会被 GUI 动作覆盖或重排
4. **重启生效** —— 当前 session 不尝试热重载 libghostty
5. **分类 tab 不可增删** —— 硬编码四项
6. **Sidebar 不变** —— Settings 视图只占右侧内容区，不影响 workspace 列表可见性与交互

## 测试

### 单测 `TheAllTests/SettingsTests/`

**`SettingsConfigStoreTests`**
- 读不存在的文件：entries 为空，无异常
- 读含注释 / 空行 / 重复 palette key 的 fixture：get(key) 返回期望值
- `set(key, value)` 后再读文件：值一致
- `set(existingKey, newValue)`：原行原地更新、注释保留
- `set(newKey, value)`：append 到尾
- `set(key, nil)`：该行被删
- 未识别字段完整保留

**`ThemeCatalogTests`**
- 扫描 bundle 目录返回非空列表
- 含若干已知名（如 "Catppuccin Mocha"）

### 手工验证

- 在 GUI 改每个字段 → 查看 `~/Library/Application Support/theall/config` 内容正确
- 重启 theall → 所有 surface 反映新值
- `theall > Edit Config File…` 打开默认 editor，指向正确路径
- Sidebar 收起状态下齿轮按钮隐藏；展开回来可见
- 设置态下点 sidebar workspace → 自动退出设置并跳到该 workspace
- Theme follow-system 模式下系统切换 Dark/Light → ghostty 应用对应主题
- 删除所有 GUI 改动的字段后 theall config 文件只剩用户手写内容

## 实施顺序建议

1. `SettingsConfigStore` + 测试（纯数据层，最独立）
2. `GhosttyBridge` 加载 theall override file（最小改动，无 UI）
3. `ThemeCatalog` + 单测
4. `SettingsView` 空壳 + `SettingsTabBarView` + 视图切换流程（ContentView + Sidebar footer 按钮）
5. App menu `Settings… ⌘,` + `Edit Config File…`
6. 各分类 Form 从 Terminal（最少字段、全原生控件）开始，Appearance → Font → Shell
7. `ThemePickerView`、`FontPickerView` 单独迭代
8. 最终手工验证 checklist

每步都能独立跑通、独立回归，方便在 agent 分支上小步提交。
