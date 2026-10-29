# Architecture

## Windows implementation

Windows uses a separate Electron application under `desktop/`; the Swift/AppKit architecture below describes macOS. Both applications expose the same workspace → tab → split-pane hierarchy and structured Claude Code/Codex chat. The Windows desktop embeds the shared mobile chat renderer in retained pane frames, adding the desktop sidebar, tabs, splitters, composer controls and settings. Build-time adapters fail if shared source contracts change unexpectedly.

- `src/main.mjs` / `preload.cjs`: sandboxed windows, trusted main-frame IPC (`desktop-ipc.mjs` compares WebContents ID and process/frame tokens plus the exact live origin/document, never JS wrapper identity), OS folder selection, image normalization and encrypted credential access.
- `src/runtime.mjs`: a loopback desktop server, per-device LAN/relay sessions, scoped APIs, submission receipts, ownership checks and lazy CLI creation. Reading history never launches an agent.
- `src/ai.mjs`: native executable/npm discovery, isolated provider configuration, bounded JSON pipes, model acknowledgements, conversation resume, automatic tool approval and interactive questions.
- `src/store.mjs`: atomic versioned snapshots, stable conversation IDs and encrypted secrets. Invalid or oversized stores fail without replacing the last valid file.
- `src/relay.mjs` / `tls.mjs`: existing relay wire protocol and encrypted local certificate identity. Desktop administrative APIs and credentials are not exposed to phones.
- `renderer/`: desktop hierarchy, draft persistence, five languages and Mac theme palettes. `scripts/prepare-assets.mjs` generates shared web assets, catalogs, icons and dependency notices.

Installed Windows builds share `%APPDATA%\TheAll`; development uses `%APPDATA%\TheAll Development`. Neither path includes the version. The two OS applications have independent history stores; this is not automatic Mac-to-Windows synchronization. See [Windows setup and validation](windows.md).

## Overview

theall 是 SwiftUI 侧边栏 + AppKit 标签页 / 分割窗格混合架构。两层通过 `NSViewRepresentable` 桥接。状态单向流动：**WorkspaceStore → 视图**，用户交互写回 WorkspaceStore。

> **历史说明**：早期版本采用"无限白板 Canvas + 自由浮动终端窗口"，2026-04 改为"Workspace → Tab → SplitNode 树"形态。旧实现已全部删除，只保留 `TheAll/Canvas/DESIGN_NOTES.md` 作历史参考。迁移理由见 `docs/decisions/003-tabs-over-canvas.md`。

```
TheAll.app
├── Sidebar (SwiftUI 壳 + AppKit 列表)  — workspace 列表，元信息展示
│   └── SidebarView (SwiftUI: footer / alert / 通知 / refresher)
│       └── SidebarListBridge (NSViewRepresentable)
│           └── WorkspaceListView (NSView)
│               └── WorkspaceRowItemView[] (private NSView)
├── TabBridge (NSViewRepresentable)
│   └── TabContentView (NSView，按 selectedWorkspace 渲染)
│       ├── TabBarView (NSView，标签条：+ / 关闭 / 重命名 / 拖拽)
│       └── SplitPaneView (NSView，递归 NSSplitView)
│           └── AITerminalPaneView[] (缓存 AI 选择/配置与运行态)
│               └── AIChatView → AIChatSession → AIChatProcess (选择并配置后创建)
├── SettingsView (SwiftUI，叠在 TabBridge 上；showSettings 时压底层且关交互)
├── TheAllRuntime → AIChatSessionRegistry — app 生命周期的共享会话，与 MobileChatAPI 共用
├── MobileAccessController → MobileHTTPServer (loopback HTTP + LAN HTTP/HTTPS) / MobileRelayClient (outbound WSS)
├── WorkspaceStore (@Observable)        — 持久化状态唯一来源
├── TerminalStatusStore (@Observable)   — 终端运行态聚合（running/idle/needsInput）
├── TerminalPwdStore (@Observable)      — terminalId → pwd 映射（持久化到 UserDefaults；sidebar git 分支读取 / 重启恢复目录）
├── SettingsConfigStore (@Observable)   — theall override config 读写
├── ThemeManager (@Observable)          — 主题解析与分发
├── HookSocketListener                  — Unix socket 接收 agent/shell hook
└── GhosttyBridge (singleton)           — libghostty C API 封装
```

## 核心数据模型

```
Workspace
├── id: UUID
├── name: String
├── needsAutomaticName: Bool ← 首次提问命名后或手动命名后关闭
├── tabs: [TerminalTab]
└── selectedTabId: UUID?

TerminalTab
├── id: UUID
├── title: String
├── layout: SplitNode      ← indirect enum，二叉树
└── focusedTerminalId: UUID

SplitNode
├── .terminal(UUID)                                       ← 叶子
└── .split(splitId, direction, firstRatio, first, second) ← 分支
```

**不变量：**
- `layout.allTerminalIds()` 不得出现重复 UUID
- `focusedTerminalId` 必须在 `layout.allTerminalIds()` 内
- 同一 workspace 下所有 tabs 的终端 UUID 集合两两不相交
- 仅靠 `SplitNode` 结构 + UUID 持久化终端布局；`ghostty_surface_t` 不序列化

## Data Flow

### 状态流

```
WorkspaceStore (@Observable)
    ↓ 传参 / @Environment
SidebarView ──────── 读 + 交互写回
TabBridge ────────── 读 + 交互写回（createTab / closeTab / split / moveRatio / focus）

用户交互 → WorkspaceStore.method() → 触发视图更新（SwiftUI 自动；AppKit 走 onChange 通知 / observe）
```

### Workspace 切换

```
点击侧边栏 WorkspaceRow
→ WorkspaceStore.select(id)
→ TabBridge 感知 selectedId 变化 → TabContentView.loadWorkspace(newId)
→ 当前 tab 的 SplitPaneView 从视图树移除（GhosttyTerminalView 保留在内存缓存，surface 不销毁）
→ 目标 workspace.selectedTab 对应的 SplitPaneView 重建 / 复用（见下方缓存规则）
```

### 新建 tab / 分割窗格

```
Cmd+T / TabBarView 上的 "+"
→ WorkspaceStore.addTab(to: workspaceId) → 追加 TerminalTab（layout = .terminal(newUUID)）

Cmd+D (vertical) / Cmd+Shift+D (horizontal) / 菜单
→ WorkspaceStore.splitFocused(in: workspaceId, direction:)
→ 更新 tab.layout：把 .terminal(focusedId) 替换成 .split(_, dir, 0.5, .terminal(focusedId), .terminal(newId))
→ SplitPaneView diff 新 tree → AITerminalPaneView 显示 AI 选择界面
→ 选择 Claude / OpenAI → 读取对应 Keychain 连接，缺失则填写并保存
→ AILaunchConfiguration → GhosttyBridge.newSurface(...)，直接启动 Claude Code / Codex
```

### 拖动 divider

```
NSSplitView.delegate 回调
→ WorkspaceStore.updateRatio(splitId:to:) (debounced save)
→ SplitNode 仅 ratio 变化，SplitPaneView 不重建（见 SplitNode.sameStructure）
```

### 主题更新

```
系统外观变化 / ghostty config 变更 / SettingsConfigStore 触发 reloadConfig
→ ThemeManager 重新解析，更新 currentTheme
→ SwiftUI 侧边栏 / SettingsView 自动重绘（@Observable）
→ TabContentView.updateTheme() 穿透刷新 TabBarView + SplitPaneView 内的 layer 颜色
→ GhosttyBridge.shared.reloadConfig() 通知 ghostty 所有 surface
```

### 终端状态推送

```
shell / agent 写一行 JSON 到 Unix socket（~/.config/theall/hooks.sock 之类）
→ HookSocketListener 读取并解码 HookMessage
→ TerminalStatusStore.setRunning / setIdle / setNeedsInput
→ Theme/TerminalStatusIconView 读 store，sidebar / tab 上的圆点颜色刷新
```

详见 `docs/agent-hooks.md`。

`.success` / `.failed` 这两种 turn 终态支持"已读"修饰：关联值 `readAt: Date?`
为 nil 时实心（未读），非 nil 时空心 stroke-only（已读）。`ContentView` 在
`store.selectedId` 或选中 workspace 的 `selectedTabId` 变化时，把 on-screen
（当前 workspace 的当前 tab 分屏树里的全部）terminal id 喂给
`TerminalStatusStore.markRead(terminalIds:)`。下一次 `setFinished` 会重写
storage entry，`readAt` 自然归 nil（新结果 → 重新未读）。`aggregate` 在同
优先级内偏好未读项，保证 "workspace 还有其它未看过的终态" 能稳住实心显示。

### 终端 PWD 追踪

```
shell 启动 / cd → ghostty shell-integration 发 OSC 7 (kitty-shell-cwd://)
→ ghostty 解析并触发 GHOSTTY_ACTION_PWD（target = surface）
→ GhosttyBridge.actionCallback → DispatchQueue.main
→ GhosttyTerminalView.view(forSurface:) 取回 terminalId
→ GhosttyBridge.onPwdChanged(terminalId, pwd) → TerminalPwdStore.setPwd
→ TerminalPwdStore 300ms debounce → UserDefaults 写盘（key theall.pwds.v1）
→ SidebarView 的 MetadataRefresher 下一 5s tick 从 pwdStore 读 focused
   terminal 的 pwd 作为 cwd 跑 `git rev-parse --abbrev-ref HEAD`
→ WorkspaceMetadata.gitBranch 更新 → 侧边栏行的 ⎇ 分支刷新
```

`TerminalPwdStore` 的 pwd 映射还有两处消费：

1. **新建 tab / 拆分 pane / 新建 workspace**：`inherit(from:to:)` 在创建新 terminalId 时把源 pane 的 pwd 预写到新 id 下，让新 shell 落在继承的工作目录而非默认目录。
2. **app 重启恢复**：`GhosttyTerminalView.viewDidMoveToWindow` 从 UserDefaults 读出上次记录的 pwd，经 `GhosttyTerminalView.validatedDirectory(_:)` 用 `FileManager` 校验（路径不存在或非目录则返回 nil），再传给 `GhosttyBridge.newSurface(workingDirectory:)`；校验失败时 ghostty 回退默认目录（通常 `$HOME`）。

## Theme System

ThemeManager 按优先级合并三个来源：

1. theall 用户手动覆盖（最高）
2. `~/.config/ghostty/config` 中的 `theme =` 字段（由 GhosttyConfigReader 解析）
3. macOS 系统深色 / 浅色模式（兜底）

所有视图从 `ThemeManager.currentTheme: AppTheme` 取色，不硬编码任何颜色。ghostty config 解析失败时自动降级，不 crash。

**token 列表（AppTheme）:**

| token | 用途 |
|-------|------|
| `sidebar` | 侧边栏背景 |
| `canvas` | 标签内容区（中央卡片）背景 |
| `foreground` | 主文字色 |
| `border` / `borderStrong` | 分割线、标签未激活边框、hover 背景 |
| `accent` | 激活 tab / 激活 pane 边框、高亮 |
| `selection` | 选中背景色 |
| `textSecondary` | 次要文字（metadata / help） |

ThemeManager 还承载三个窗口级不透明度：`backgroundOpacity`（sidebar 层）、`contentEffectiveOpacity`（卡片层叠加）、`blurRadius`。全部由 SettingsConfigStore 的 `background-opacity` / `background-blur-radius` / `theall-content-opacity` 驱动。

## Tab & SplitPane Layer

Tab + SplitPane 全部用 AppKit，原因：NSSplitView 的 divider 拖拽、z-order、精确 frame 控制比 SwiftUI `HStack/VStack` 及其 `.gesture` 更可靠；且 ghostty surface 对 live resize 有严格的 frame 约定，AppKit 层 layout pass 更可控。

- `TabBarView` — 固定高度水平条，内部自绘 tab cell，支持拖拽重排（`.theAllTab` UTI）
- `TabContentView` — 按 `selectedTabId` 渲染对应的 SplitPaneView；对已切走的 tab 做 view 缓存（key = tab.id），避免 surface 被重新创建
- `SplitPaneView` — 递归构建 `NSSplitView`，叶子是缓存的 `AITerminalPaneView`，完成配置后显示 `AIChatView`，聊天输入由原生 `NSTextView` 管理。结构变化触发 rebuild；仅 ratio 变化只调 `setPosition(_:ofDividerAt:)`（见 `SplitNode.sameStructure` 注释）
- `SurfaceScrollView` — `NSScrollView` + 空白 `documentView`，`GhosttyTerminalView` 作为 documentView 子视图并 pin 在 `visibleRect` 上。消费 ghostty 的 `SCROLLBAR`（total/offset/len 行数）与 `CELL_SIZE`（backing px → pt）action 驱动 scroller；用户拖拽时转成行号并通过 `scroll_to_row:N` binding action 回写 ghostty。永远 overlay 样式以避免非 overlay 滚动条变宽引起的 PTY reflow
- `GhosttyTerminalView` — 持有 `ghostty_surface_t`，Metal CALayer 渲染；失焦时整体降 alpha 到 `unfocused-split-opacity`

### Legacy Quick Actions

`TerminalTab.quickActionId`、`QuickActionsStore` 和设置面板保留旧数据与图标，便于后续迁移。新建入口仅提供 AI 终端，`TabContentView` 不再调用 `StartupCommandResolver`，不会执行旧 Quick Action 命令、workspace defaultCommand 或自动 resume prefill。重启恢复的 tab 同样先进入 AI 选择页。

原始命令与设置结构见 `docs/superpowers/specs/2026-04-30-quick-actions.md`。当前连接流程见 [AI terminals](ai-terminals.md)。

## Settings Layer

`SettingsView` 是纯 SwiftUI Form，覆盖在 TabBridge 之上。进入设置时 TabBridge 被压到底层（`.opacity(0)` + `.allowsHitTesting(false)`）**但不 dismantle**，否则 `NSViewRepresentable` 重建会让所有 ghostty surface 被释放重建。

- `SettingsConfigStore` 读写 theall 独立的 override config（不污染用户 ghostty config），改动 200ms debounce 后写盘并触发 `onChange`
- `onChange` 依次调用 `applyWindowEffectsFromSettings → GhosttyBridge.reloadConfig → ThemeManager.refresh → applyUnfocusedOpacityFromSettings`
- 字段清单与默认值见 `docs/settings-reference.md`

## GhosttyBridge

封装 libghostty 全部 C API 调用。其他文件 **不直接** 调用 `ghostty_*`。

- `initialize()` — 在 `TheAllApp.init()` 中调用一次
- `newSurface(nsView:scaleFactor:workingDirectory:)` — 创建 surface，由 `GhosttyTerminalView` 管理生命周期；`workingDirectory` 由 `viewDidMoveToWindow` 从 `TerminalPwdStore` 读出并经 `FileManager` 校验后传入，nil 时 ghostty 在默认目录（通常 `$HOME`）启动 shell
- `reloadConfig()` — SettingsConfigStore 改动后重读 config 并下发到所有活 surface
- `applyWindowBackgroundBlur(to:)` — 根据 config 在 NSWindow 上安装/卸载 blur layer
- `teardown()` — app 退出时释放 app/config

## Persistence

WorkspaceStore 用 UserDefaults + Codable 存 `workspaces` 数组（含 tabs 和 SplitNode tree，key `theall.workspaces.v2`）和 `selectedId`。divider 拖拽走 debounced save 避免每帧写盘。

`ghostty_surface_t` 不序列化 — 重启后 `GhosttyTerminalView` 按 UUID 重建 surface。

`TerminalPwdStore` 用 UserDefaults 存 `terminalId → pwd` 映射（key `theall.pwds.v1`），300ms debounce 写盘。重启时 `GhosttyTerminalView.viewDidMoveToWindow` 读取对应 uuid 的 pwd，校验后传给 `newSurface(workingDirectory:)` 恢复上次工作目录。

SettingsConfigStore 用自己的文件持久化，独立于 UserDefaults。

## Localization (i18n)

The `TheAll/Localization/` module handles all user-facing text:

- `LanguageStore` (`@Observable`, singleton) holds the user's preference
  (`.system | .zh | .en | .fr | .ja | .ko`), persists it to UserDefaults (`theall.language`),
  and publishes a `tick` counter + `locale` + `effectiveBundle`.
- SwiftUI views use `Text(L10n.Namespace.key)`; locale comes from
  `TheAllApp`'s `.environment(\.locale, languageStore.locale)` injection.
  `Text(LocalizedStringResource)` honors the injected locale directly.
- For call sites that resolve to `String` (e.g. `IconButton.help`) use
  `String(localized: L10n.Namespace.key.withLocale(locale))` after reading
  `@Environment(\.locale) private var locale`. The `.withLocale(_:)` helper
  overrides `Locale.current` which `String(localized:)` would otherwise
  ignore the SwiftUI env.
- AppKit subclasses (`TabBarView`, `WorkspaceListView`, etc.) compute
  strings via `L10n.string("raw.key")` against
  `LanguageStore.shared.effectiveBundle`. When language changes, each
  `*Bridge` reads `languageStore.tick`, triggering `updateNSView` which
  calls `refreshLocalizedStrings()` on its subview to rebuild tracked
  labels.
- The Commands menu bar (`TheAllApp.swift`) references `LanguageStore.shared.locale`
  directly and touches `languageStore.tick` in the Scene body to force
  re-evaluation on language switch.

See `docs/i18n.md` for the developer guide. Adding a new string or a new
language is documented there.

## Error Handling

| 场景 | 处理 |
|------|------|
| `ghostty_surface_new()` 失败 | 对应 pane 内显示 inline error banner，不影响兄弟 pane |
| libghostty 未初始化 | 启动时检测，显示 GhosttyMissingView |
| ghostty config 解析失败 | 降级到系统模式，不 crash |
| 持久化失败 | 静默跳过，重启后加载上一次成功写盘的状态 |
| HookSocketListener 启动失败 | 打印 log，其他功能正常（状态图标只是不更新） |

## Auto-Update

macOS 使用 [Sparkle](https://sparkle-project.org) 2.9.6+ 完成下载、Ed25519 校验和重启安装；Windows 使用主进程更新服务检查同一 GitHub 仓库的稳定 Release，选择当前架构与安装方式对应的资产。两端启动后检查，并每 6 小时复查；只有用户点击后才下载，安装前等待所有 AI 回合完成并保存草稿和历史。

```
Sparkle internal ─► UpdateUserDriver (SPUUserDriver)
                       │ (MainActor mutate)
                       ▼
                   UpdateStore (@Observable)
                       │
                       ├─► SidebarView (手机连接按钮上方的更新卡片)
                       └─► UpdateSectionView (主面板)

User click ──► SparkleBridge.{checkForUpdates | downloadAndInstall | skipVersion | dismiss | retry}
                   │
                   ▼
               SPUUpdater APIs
```

**关键约束:**
- Sparkle 符号只在 `TheAll/Update/SparkleBridge.swift` 和 `UpdateUserDriver.swift` 里 `import`，与 ghostty 约定对齐。
- `UpdateStore` 为应用级共享状态，多窗口读同一个更新流程。下载、等待、安装与错误显示使用现有主题 token。
- macOS feed 固定为 `https://github.com/AbadOrangeCat/TheALL/releases/latest/download/appcast.xml`；公钥随应用分发，私钥不进入仓库和安装包。`scripts/prepare-update-feed.mjs` 生成签名 enclosure 与校验文件。新版本的 build 号必须递增。
- Debug 可检查，但不能被正式发布包自动替换；测试宿主默认不联网。Release 通过 Sparkle 正常退出安装，保留原 bundle identifier、签名身份以及 Application Support 数据。
- Windows 更新操作只在受信任桌面主框架的 IPC 中提供，手机 API 和对话窗格不能指定更新 URL、命令或目标路径。下载验证 GitHub 资产 SHA-256 与大小，安装仅使用主进程选择的已验证文件。
- 安装交接时阻止新回合进入；失败必须解除安装门闩并保留当前程序和用户数据。不能为了更新强制终止正在运行的 AI 任务。
- 已发布旧客户端没有这项能力，须先手动安装一次包含更新支持的版本。GitHub 代码提交不会触发更新，只有正式发布的新版本和完整更新资产才会触发。

## AI 终端入口

每个新建或重启恢复的叶子先显示 AI 选择界面；仅切换 tab、workspace 或调整分割比例时复用缓存，不重新启动进程。`AITerminalSession` 管理选择、凭据读取、表单校验和启动，`PersistentAICredentialStore` 按提供商保存完整连接（Key、Base URL、模型、认证方式）。布局及 UserDefaults 不保存凭据。

`PersistentAICredentialStore` 通过私有 stdin/stdout JSON 管道调用独立签名的 `CredentialHelper/main.swift`，密钥不经过 argv、环境变量或日志。`AICredentialHelperProtocol` 定义协议和签名校验：主应用验证 helper 文件及实际启动的子进程，helper 验证实际父进程 PID 的 identifier 与同一证书。helper 启用 hardened runtime，不包含 get-task-allow、disable-library-validation 等调试权限。

首次运行将 helper 原子安装到 `Application Support/<bundleID>/CredentialHelper/<certificateHash>/v1/`，之后复用原二进制，应用重构建不得重签或覆盖它。现代登录钥匙串除了证书 ACL，还以自签名程序的 CDHash 检查 partition；固定证书本身不能解决跨构建读取。固定 helper 保存 `.ai-connections.v3`，Keychain 的调用者指纹不随 UI 更新变化。helper 升级需要通过旧 helper 读取后迁移到新命名空间，不能直接替换现有可执行文件。

所有 Keychain 操作禁止授权弹窗。`KeychainAICredentialStore` 仅用于迁移 v2 和更早的连接：可读则复制到 v3，不可读则保留旧条目，提示在新存储中重新填写一次。Forget 只删当前提供商并记录非敏感迁移标记，防止重新导入旧连接。当前 v3 不可读时仍报解锁/访问错误，不静默覆盖。保留固定签名证书和安装的 helper；相关配置见 `docs/build.md`。

`AILaunchConfiguration` 生成 CLI 可执行文件、参数及独立凭据环境。`AIChatProcess` 使用 `Process` 的 stdin/stdout 管道，以逐行 JSON 和常驻 Claude Code / Codex 通信。`AIChatSession` 管理流式输出、忙闲状态、草稿、工具自动执行以及提问。Claude 用 SDK stdio 控制协议，在下一次发送前确认 `set_model`；Codex 用 app-server，在同一 `threadId` 的 `turn/start` 中明确指定模型。切换模型不重启进程、不清空历史或草稿，也不向终端注入命令。

`AIChatHistoryStore` 将每个 terminal UUID 的提供商、模型、工作目录、草稿、消息（含折叠标记）和后端 conversation ID 原子保存到 Application Support/<bundleID>/ChatHistory/<UUID>.json。串行后台队列每 300ms 合并写入，退出和窗口解绑时同步 flush；目录 0700、文件 0600。快照不保存连接或 API Key。恢复先展示本地记录，再读取 Keychain 并以 Claude `--resume` / Codex `thread/resume` 接续同一后端上下文；凭据缺失和恢复失败都保留记录，不自动创建空白会话。旧版没有 terminal 映射，`AIChatLegacyHistory` 只读扫描本应用 Claude 目录，用户在选择页或空白 Claude 聊天的“恢复旧版 Claude 对话”中明确选择导入；导入前停止空会话并保留草稿/模型，随后按当前终端 UUID 保存，以后重开直接续接。

聊天视觉尺寸集中在 `DT.Chat`：内容列最大宽度 880pt、控件行 32pt、输入区 96pt，使用既有 AppTheme 颜色。输入工具栏宽度不足时把附件/目录与模型/强度/发送拆成两行；桌面 Web 使用对应尺寸，手机保留更大的触摸目标。主题、强调色和自定义配色不受这层布局规则影响。

`AIChatComposer.Editor` 在首个视觉行的 ↑ / 最后视觉行的 ↓ 上浏览当前会话的用户消息；按一次浏览冻结历史，恢复原草稿与光标，临时编辑不改写消息。多行、软换行、选区、修饰键和输入法组合文本保留 AppKit 行为。会话身份或外部草稿变化清理浏览与独立 undo 状态；撤销/重做后的文本作为新草稿，防止历史编辑错位。

`AIChatImage.swift` 提供 `AIChatImage` 元数据和 `AIChatImageStore`。照片独立存储在 ChatHistory/Attachments，快照只保留附件引用和图片草稿，旧版无附件字段的 JSON 仍可读取。ImageIO 检查输入、校正方向、去除 EXIF/GPS 并缩小到最长边 2048；原始文件不修改。每条最多 4 张，桌面原文件最多 20 MB，存储副本最多 2 MB。Claude 使用 base64 image content blocks，Codex 使用 app-server `localImage` 持久本地路径；图片发送失败保留草稿。

`AIChatFile.swift` 提供 `AIChatFile` 与 `AIChatFileStore`，原始文件复制到私有 `ChatHistory/FileAttachments`，存储路径只使用 UUID 与严格过滤的扩展名。每条消息最多 5 个普通文件，单个 10 MiB、总计 20 MiB，允许空文件。SHA-256、长度和普通文件/链接检查在发送前验证；后台读取与验证后，将 JSON 编码的本地路径清单交给 Claude/Codex 工具，历史仍只保存用户原文和元数据。不会自动执行上传文件。`AIChatFileViews.swift` 统一照片与文件选择、拖放、粘贴，混合批次失败时整批回滚；文件卡片显示名称/大小，可移除或在 Finder 显示。更新协调器会等待附件导入完成，再保存草稿并退出。

`AIChatImageViews.swift` 负责选择后的后台导入、图片剪贴板识别、异步缩略图与单图预览。普通文字粘贴仍由 NSTextView 处理。附件可单独移除，支持纯图片消息；上下键历史只调取文字，不隐式重发旧照片。照片预览不因流式文本的每次变化重复解码。

整个聊天区通过 SwiftUI `onDrop` 接收文件 URL 与图片 representation，原生输入框通过 `acceptableDragTypes`、`dragOperation`、`performDragOperation` 接收照片及普通文件，避免 NSTextView 把图片路径插入文字。悬停显示主题色提示，普通文字拖放保留 AppKit 行为。拖入只添加草稿附件、不自动发送；开始加载 provider 前固定会话并占用导入状态，顺序导入，超量或失败整批回滚。文件 URL 优先于同图的其他 representation，临时文件必须在 provider 回调返回前完成导入。

含普通文件的历史或草稿使用快照 v3，只有照片时使用 v2，纯文字继续使用 v1；当前构建兼容三者，旧构建拒绝未知版本，避免丢掉附件后覆盖原记录。`AIChatProcess` 通过每个进程独立的后台串行队列写入非阻塞管道，限制单条 16 MiB、待写总量 32 MiB、写入 30 秒；取消不等待主线程。退出前结算所有已排队写入回调。Claude 仅在完整消息写入后清空提交的草稿，提前到达的 stdout 暂存至用户消息入历史；跨进程代次回调被丢弃。

`AIChatView` 的消息滚动区域与输入框独立，模型下拉框位于输入框下方、紧邻 Send/Stop 左侧，工作目录靠左。聊天区自动加载模型列表，不显示刷新按钮；连接表单保留刷新功能。阅读旧消息时不强制滚动到底部，回答区右下角仅在未到底部时显示跳转按钮。通过原生 NSScrollView 的 clip bounds/document frame 观察计算底部位置，兼容 macOS 14，并随窗口大小和折叠后的内容高度更新。每轮新提问前用加粗分界线分隔上一轮。`AIModelCatalog` 使用用户配置的 API 地址和相同认证方式请求模型列表，支持 Anthropic 分页，拒绝重定向且不缓存凭据；配置改变时丢弃旧请求结果。

首条消息成功提交后，`AIChatSession` → `AITerminalSession` → `TabContentView` 通知 `WorkspaceStore`，按 terminalId 找到实际归属工作区，将首问的简短主题作为名称（本地提取，不额外调用 API）。`needsAutomaticName` 随工作区持久化，一次自动命名或任意手动确认名称后关闭，后续提问、其他分屏及重启不覆盖。旧数据按 Default/workspace N 等默认名称识别是否待命名，自定义名称保留。Claude 在消息写入成功后通知，Codex 等待 `turn/start` 成功，失败提交不命名。

AI 路径不执行旧的 quick action、workspace defaultCommand 或 resume shell prefill。原 `GhosttyTerminalView`/`SurfaceScrollView` 基础设施保留；滚轮转发前恢复真实修饰键，并允许非焦点分屏短暂重绘，避免悬停链接留下 Shift 状态后必须点击才能滚动。兼容性、验证与限制详见 [AI terminals](ai-terminals.md)。

聊天底部显示可点击的工作目录，空闲且无待回答问题时可用系统文件夹选择器更换目录。Claude 以原 session ID 恢复进程，Codex 每轮传入 cwd；历史和草稿保留。`AIChatProcess` 对重启前的迟到消息按进程代次丢弃。常规工具记录隐藏，思考/摘要内容流式显示并与最终块去重；用户提问和工具错误仍可见。成功回合确认最终答复后，`AIChatMessage.isIntermediate` 标记当前轮思考和普通过程说明，UI 默认折叠每条记录，点击单独展开；展开状态保存在父视图，滚动不丢失。Claude 优先使用 result 正文和停止原因，Codex 使用 commentary/partial_answer/final_answer 阶段，保留稳定答复；缺阶段时保守保留最后工具后的多个回答块。失败和中断不自动折叠。用户提问使用 accentMuted 圆角背景、accent 色条，与普通回答和低对比过程文字区分。

按用户明确选择，所有工具操作自动执行，包括改文件、删除、安装依赖和推送。Claude 使用 `--dangerously-skip-permissions`；Codex 启动配置、thread/start 和 turn/start 均明确指定 never 审批与完整访问。兼容性权限回调直接回复允许，Claude 输入原样转发，不再使用只读 shell 解析器。Codex 同时处理现代、旧版及子任务的命令/文件权限请求。真正的用户问题继续等待回答；未知协议请求明确返回错误。

运行指示器显示在当前轮 Thinking 标题前，尚无思考内容时只显示标题占位；等待用户回答或结束后停止，输入区不显示转圈。

## 手机访问与应用级会话

`AIChatSessionRegistry.swift` 中的 `TheAllRuntime` 持有跨窗口共享的 WorkspaceStore、PWD/status/title stores 和 terminal UUID → AITerminalSession registry。`TabBridge` 注入 registry，`AITerminalPaneView` 观察同一个 session 的 chat，而不接管共享 session 的启动回调。关闭窗口不会结束后台会话；删除 workspace/tab 后 registry 会停止对应会话并保存历史。

`MobileAccessController` 默认关闭，点击“手机扫码连接”后选择 quick 模式、开启局域网并在监听就绪时生成一次性二维码；手机从 URL fragment 获取邀请后自动配对。新安装默认 quick，已启用 HTTPS 的旧安装保留 encrypted，直到用户主动选择快捷连接。`MobileLANAddress` 枚举 RFC1918 IPv4，优先 en* 的 Wi-Fi/以太网，保留可用的用户选择；quick 模式地址失效时自动重新选择，取消旧邀请和授权 generation。第二个 `MobileHTTPServer` 仅绑定所选地址；HTTP 必须明确 allowLANHTTP 且 localNetworkOnly，拒绝公网地址及通配地址。HTTPS 模式使用 TLS 1.2+；`MobileLANIdentity` 用 CryptoKit P-256 持久化本机 CA，签发 90 天 IP-SAN 证书，通过 SecIdentityCreate 构造内存身份，不写 Keychain。证书导出、信任与手选网卡保留在高级设置；quick 路径不读取/生成 CA。外网由 `MobileRelayClient` 主动连接用户自建中继的 WSS `/host`，用独立 Ed25519 身份签署一次性挑战。两种入口共用会话和设备表，生命周期与错误分开；停止其中一个不停止另一个或 AI 任务。

`MobilePairingStore` 将 256-bit 手机令牌的 SHA-256 摘要保存到权限 0600 的设备文件，5 分钟邀请仅内存、绑定配对 origin 且只能使用一次，设备 30 天过期或手动撤销。新设备凭据也绑定 origin；不同地址独立配对。Web App 使用 HttpOnly/SameSite=Strict cookie，HTTPS 额外设置 Secure；快捷 LAN 的 `TheAllLANSession` 与原 HTTPS/预览/中继的 `TheAllMobileSession` 分开，避免同 IP 跨端口的 Secure cookie 覆盖冲突。每条请求带服务器内部的入口上下文，分别严格检查 Origin/Host 和 JSON 自定义头，防止 LAN 冒充中继入口。停用任一入口会更新该入口 generation，使等待后端恢复的旧请求失效。中继不持久化聊天、凭据或请求内容，但它是 HTTPS/WSS 的受信任终点，必须由用户控制。

`MobileChatAPI` 遍历所有 workspace/tab/split leaves，读历史不启动闲置 CLI；发送时才按需恢复。手机发送采用独立文本入口，保留 Mac 草稿；实际提交确认后才返回成功。所有变更带每次应用启动的 bootID 和请求 UUID，重复请求读取回执，未知结果不能自动换 ID 重发。前端分页加载全部记录、通过同源 WebSocket 接收变化通知后拉取授权快照，断线回退轮询且离线禁发；Service Worker 只缓存公开页面，不缓存聊天和 API。详见 [连接与部署](mobile-access.md)。

`MobilePairingStore.Access` 把邀请限制为全部或指定 workspace，并选择只读/可操作。服务端在读取历史、启动CLI、查重试回执前验证范围；只读设备不能发送、回答、停止或新建。指定 workspace 的可操作设备只能在该 workspace 新建对话。异步恢复及 Claude 模型 ACK 后真正发送前再次校验，工作空间移动、删除或撤销授权会使旧请求失效。旧设备记录缺少 access 字段时兼容原有全部可操作权限；修改下一张二维码的选项不改变已配对设备。

`MobileEventChannel` 提供有界 RFC6455 text 通道，LAN/回环 `/api/events` 与中继虚拟通道统一交给 Controller 的 Origin/Cookie 鉴权。`MobileEventHub` 通过 Observation 读取授权 workspace 的布局、会话状态与 revision，合并通知，仅推送 hello/changed/pong，不发送聊天内容或桌面草稿。隐藏 workspace 变化不产生通知；断线后客户端重新读取快照，不自动提交写操作。20 秒应用心跳、超时关闭、退避重连与设备在线状态独立于配对凭据的有效期。前端 `live.js` 管连接，`i18n.js` 管五种语言与本机语言偏好；普通 HTTP 和实时通道都保留现有权限检查。前端仅允许安全上下文或严格 RFC1918 HTTP；UUID 在非安全上下文通过 crypto.getRandomValues 生成，Service Worker 仅 HTTPS/可信回环注册。扫码自动配对与 Cookie 恢复探测互斥，错误不自动重复消耗邀请。

## Application namespace migration

The project, source directory, module and targets are `TheAll` / `TheAllTests`. Bundle identifiers default to `com.theall.app.dev` and `com.theall.app`. `THEALL_APP_IDENTIFIER` may be overridden in ignored `Local.xcconfig` when an existing installation needs to retain its signed identity, Keychain helper, conversation storage and mobile identities. `AppNamespaceMigration` runs before any settings stores initialize. An explicitly configured `THEALL_PREVIOUS_NAMESPACE` copies missing preference keys and renames configuration assignment keys into `theall`, without changing values or overwriting existing data. Source data is retained; a completion marker prevents deleted settings from being restored on later launches. Migration failure blocks startup instead of opening an empty workspace.

### Turn metadata and background completion notifications

`AIChatSession` records completion time and monotonic elapsed duration only for a submitted turn. Optional message fields keep old history readable. Model capability metadata drives reasoning effort controls; Claude applies acknowledged flag settings before the user message, and Codex supplies per-turn effort. Selections are persisted without recreating conversations.

`MobileNotificationService` receives explicit successful-turn events through the application-owned chat registry, independently of `MobileEventHub` and open WebSockets. `MobilePushStore` preserves a private VAPID identity and subscriptions bound to the current authenticated device and origin. `MobileWebPush` implements RFC 8291/8292 and only sends to HTTPS Apple/Google/Mozilla push endpoints. Device, workspace and origin authorization is checked again before sending; stop/revoke/unsubscribe cancels pending delivery. Windows implements the same contract in `desktop/src/web-push.mjs`. The mobile worker displays generic encrypted push payloads without fetching private chat data; OS settings govern phone/watch notification mirroring.
