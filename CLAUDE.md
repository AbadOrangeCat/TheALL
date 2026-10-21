# TheAll

macOS 标签页 + 分割窗格式终端 app，以 libghostty 作为终端引擎，Swift/AppKit + SwiftUI 实现。

## Quick Start

```bash
# 1. 首次构建 libghostty（只需一次）
./scripts/build-vendor.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 构建并运行（命令行）
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build

# 4. 运行测试
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests

# 5. 检查文档/目录是否漂移
./scripts/check-doc-drift.sh
```

## Architecture Overview

本地 Debug 已配置固定签名时，应保留 gitignored `Local.xcconfig` 和对应证书，构建不要强制 `CODE_SIGN_IDENTITY=-`，否则会破坏钥匙串的跨版本身份。初始化流程见 `scripts/setup-local-signing.sh` 和 `docs/build.md`。

SwiftUI 侧边栏 + AppKit 标签页/分割窗格混合架构。每个 Workspace 持有一组 TerminalTab，每个 Tab 存一棵 `SplitNode` 树（二叉 split + terminal 叶子）。WorkspaceStore (@Observable) 是唯一状态来源，通过 environment 注入到所有视图。libghostty C API 封装在 GhosttyBridge 单例中，不直接调用 `ghostty_*` 函数在其他文件。

详见 `docs/architecture.md`。

> **历史说明**：早期版本是"白板/Canvas 无限画布"形态，2026-04 迁移到标签页 + 分割。相关决策见 `docs/decisions/003-tabs-over-canvas.md`，旧的设计笔记保留在 `TheAll/Canvas/DESIGN_NOTES.md` 仅作参考。

## Directory Structure

```
TheAll/
├── TheAllApp.swift          — @main 入口，ghostty init，全局 menu commands
├── ContentView.swift      — 根 ZStack/HStack：SidebarView + TabBridge（+ SettingsView 叠层）
├── WindowAccessor.swift   — NSViewRepresentable，把 NSWindow 交给 ghostty 安装 blur layer
├── Bridge/
│   ├── TabBridge.swift          — TabContentView SwiftUI ↔ AppKit 桥接
│   └── SidebarListBridge.swift  — WorkspaceListView SwiftUI ↔ AppKit 桥接
├── Canvas/
│   └── DESIGN_NOTES.md    — 仅保留旧白板形态的设计笔记（代码已全部删除）
├── TabContent/
│   ├── TabBarView.swift       — NSView，水平标签条（新建/关闭/重命名/拖拽）
│   ├── TabContentView.swift   — NSView，承载当前 workspace 的 tabs，管理 SplitPaneView 缓存
│   ├── SplitPaneView.swift    — 递归 NSSplitView 渲染 SplitNode，drag divider + 键盘焦点导航
│   ├── StartupCommandResolver.swift — 旧 shell 命令解析器，保留用于迁移；AI 入口不调用
│   ├── SurfaceScrollView.swift — NSScrollView 包装 GhosttyTerminalView，提供原生 overlay 滚动条（消费 ghostty SCROLLBAR/CELL_SIZE action，拖拽回写 `scroll_to_row:N`）
│   └── PasteboardTypes.swift  — .theAllTab UTI 常量
├── AI/
│   ├── AIConnection.swift        — 提供商、连接校验与旧 Keychain 迁移读取
│   ├── AICredentialHelperProtocol.swift — 私有管道协议与双向签名身份校验
│   ├── PersistentAICredentialStore.swift — 固定凭据 helper 的安装、调用与迁移
│   ├── AILaunchConfiguration.swift — CLI 参数与独立的子进程凭据环境
│   ├── AITerminalSession.swift   — 选择 / 编辑 / 启动状态机
│   ├── AITerminalPaneView.swift  — 缓存 AI 选择表单和原生聊天界面
│   ├── AIModelCatalog.swift      — 从当前 API 获取模型目录（含认证、分页和重定向保护）
│   ├── AIChatSessionRegistry.swift — app 级会话/WorkspaceStore 所有者，桌面与手机共享同一 CLI
│   ├── AIChatSession.swift       — Claude/Codex 会话协议、模型切换、流式消息、自动执行与提问
│   ├── AIChatHistoryStore.swift  — 按终端 UUID 原子保存聊天、草稿和后端会话编号
│   ├── AIChatLegacyHistory.swift — 只读导入应用旧版 Claude 会话，用户明确选择后恢复
│   ├── AIChatProcess.swift       — 常驻 CLI 的逐行 JSON 进程通信
│   └── AIChatView.swift          — 聊天记录、原生输入框、模型下拉框和用户提问
├── Mobile/
│   ├── MobileAccessController.swift — 手机连接设置、配对入口、请求鉴权和静态资源
│   ├── MobileHTTPServer.swift — loopback HTTP / 独立 LAN HTTPS 的有界服务与安全响应头
│   ├── MobileEventChannel.swift — 同源 WebSocket 帧、事件通道与中继适配
│   ├── MobileEventHub.swift — 按授权范围观察变化、合并推送与在线设备状态
│   ├── MobileLANAddress.swift — 枚举可选的局域网 IPv4 地址
│   ├── MobileLANIdentity.swift — 本机 CA、内存 TLS 身份与手机公开证书导出
│   ├── MobilePairingStore.swift — 一次性配对、设备 token 哈希、撤销与过期
│   ├── MobileChatAPI.swift — workspace/历史分页与幂等的回复/新建/停止/回答
│   ├── MobileRelayClient.swift — 电脑主动 WSS 连接、自有 Ed25519 身份与自动重连
│   └── MobileWeb.bundle/ — iOS/Android PWA、图标、仅缓存页面的 Service Worker
├── Ghostty/
│   ├── ghostty-bridging-header.h  — 桥接头文件
│   ├── GhosttyBridge.swift        — libghostty 单例（app/config 生命周期 + window blur）
│   ├── GhosttyTerminalView.swift  — NSView，持有 ghostty_surface_t，Metal 渲染
│   └── LinkHintTooltip.swift      — 链接 hover 提示气泡（无边框浮层窗口）
├── Localization/
│   ├── LanguageStore.swift  — @Observable，语言偏好 + UserDefaults 持久化 + effectiveBundle + locale + tick
│   ├── L10n.swift           — 常量命名空间（LocalizedStringResource + AppKit helper L10n.string(_:args...)）
│   └── Localizable.xcstrings    — Xcode String Catalog（en source + zh-Hans / fr / ja / ko 翻译）
├── Metadata/
│   ├── WorkspaceMetadata.swift  — git/PR/通知 数据结构
│   └── MetadataRefresher.swift  — 5s 轮询 + OSC 通知处理 + onRefresh 回调
├── Models/
│   ├── AppNamespaceMigration.swift — 显式本地配置驱动的一次性偏好/设置键迁移
│   ├── Workspace.swift            — Workspace / TerminalTab / SplitNode / SplitDirection（Codable）
│   ├── WorkspaceStore.swift       — @Observable，workspace / tab / split CRUD + UserDefaults 持久化
│   ├── QuickAction.swift          — BuiltinQuickAction enum + CustomQuickAction struct + QuickActionIcon
│   ├── QuickActionsStore.swift    — @Observable，enabled / overrides / custom 三段持久化
│   ├── TerminalStatus.swift       — 单终端运行状态枚举（running / idle / needsInput）
│   ├── TerminalStatusStore.swift  — @Observable，终端状态聚合（供 sidebar / tab 图标读取）
│   ├── TerminalPwdStore.swift     — @Observable，terminalId → pwd 映射（ghostty PWD action 喂入，sidebar git 分支读取）
│   ├── TerminalSessionTitleStore.swift  — @Observable，terminalId → agent session title（hook 喂入，tab 标题读取）
│   ├── HookDispatcher.swift       — 按 agent toggle 过滤 hook 事件 + 派生 status icon UI 主开关
│   ├── HookMessage.swift          — agent/shell hook 的 JSON wire format
│   └── HookSocketListener.swift   — Unix domain socket 监听，解析 HookMessage → statusStore
├── Settings/
│   ├── SettingsView.swift         — SwiftUI 根面板，承载八个 Section
│   ├── SettingsConfigStore.swift  — @Observable，读写 theall config（200ms debounce）
│   ├── SettingsTabBarView.swift   — Appearance / Font / Terminal / Shell / Quick Actions / Agents / Mobile / Update 分类切换
│   ├── SettingsSection.swift      — Section 枚举定义
│   ├── ThemeCatalog.swift         — 只读扫描 bundle 内 ghostty/themes/
│   ├── Components/                — 复用 SwiftUI 控件（BoundControls / FontPicker / QuickActionIconView / QuickActionRowView / ThemePicker / ...）
│   └── Sections/                  — 八个 Section 的视图实现（Appearance / Font / Terminal / Shell / QuickActions / Agents / Mobile / Update）
├── Sidebar/
│   ├── SidebarView.swift              — SwiftUI 壳：footer / alert / 通知订阅 / refresher 生命周期
│   ├── WorkspaceListView.swift        — AppKit 列表 + private WorkspaceRowItemView
│   └── WorkspacePasteboardType.swift  — .theAllWorkspace UTI 常量
├── Update/
│   ├── UpdateState.swift         — 自动更新 UI 状态枚举（idle / checking / upToDate / updateAvailable / downloading / readyToInstall / error）
│   ├── UpdateStore.swift         — @Observable，自动更新状态存储（sidebar 红点 + Settings Update section 都读这个）
│   ├── SparkleBridge.swift       — 单例，持有 SPUUpdater，对外暴露 checkForUpdates/downloadAndInstall/skip/dismiss/retry；Debug 下为空 stub
│   └── UpdateUserDriver.swift    — 实现 Sparkle 的 SPUUserDriver，事件 → UpdateStore 变更（MainActor，Release-only）
└── Theme/
    ├── AppTheme.swift               — 设计 token 结构体（sidebar / canvas / border / accent / ...）
    ├── DesignTokens.swift           — token 定义与 spacing / radius / layout 常量
    ├── GhosttyConfigReader.swift    — 从 ghostty config 读颜色
    ├── ThemeManager.swift           — @Observable，主题解析与分发（含 opacity / blur）
    ├── IconButton.swift             — 紧凑图标按钮（hover/pressed 走 theme token）
    ├── DraggedSnapshotShadow.swift  — 拖拽 ghost 的分层阴影合成（Josh Comeau layered-shadow 方案）
    └── TerminalStatusIconView.swift — 终端状态圆点图标
```

`CredentialHelper/main.swift` 是独立签名的凭据 helper target；首次使用后保留在 Application Support，应用更新不得覆盖已安装版本。

## Key Conventions

1. **所有颜色取自 AppTheme token** — 禁止在视图里硬编码 `Color(...)` 或 `NSColor(...)`，从 `@Environment(ThemeManager.self)` 取 `.currentTheme` 或直接传 `theme` 参数
2. **ghostty API 只在 GhosttyBridge 和 GhosttyTerminalView 中调用** — 其他文件不 `import` 也不直接调用 `ghostty_*` 函数
3. **状态写回 WorkspaceStore** — 所有持久化状态（workspace 列表、tab 列表、SplitNode tree、selectedTabId）通过 WorkspaceStore 的方法修改，不直接改 struct 字段
4. **TabBar / SplitPane / SidebarList 用 NSView subclass；SidebarView / SettingsView 壳（footer / alert / 通知订阅 / 元数据 refresher 生命周期 / 设置表单）用 SwiftUI View struct** — AppKit ↔ SwiftUI 边界统一在 `*Bridge: NSViewRepresentable`
5. **提交格式** `type(scope): description` — e.g. `feat(tabcontent): add drag-to-reorder`；scope 与目录对应，合法值：`sidebar | tabcontent | settings | theme | ghostty | models | metadata | bridge | build | docs | update | i18n | assets`
6. **不 push 到 master** — 用 `agent/feature-name` 分支，PR 合并
7. **surface 不序列化** — `Workspace → tabs → SplitNode` 只存 UUID 与 split ratio；重启后 GhosttyTerminalView 按 UUID 重建 surface
8. **文档与目录结构同步** — 增删/重命名/移动 `TheAll/` 下的目录或 Swift 文件时，**同一 PR 必须同步更新** CLAUDE.md、AGENTS.md 的 Directory Structure 与 `docs/architecture.md` 中受影响的章节。提交前跑 `./scripts/check-doc-drift.sh` 自检。新模块还要在 Common Tasks 或 Documentation Map 里补条目

## Documentation Map

| 主题 | 文件 |
|------|------|
| 系统架构与数据流 | `docs/architecture.md` |
| 编码规范与模式 | `docs/conventions.md` |
| libghostty 集成 | `docs/ghostty-integration.md` |
| 测试策略 | `docs/testing.md` |
| 构建与 Vendor | `docs/build.md` |
| Agent 状态钩子（Claude/OpenCode/Codex wrapper + IPC） | `docs/agent-hooks.md` |
| 设置面板字段参考 | `docs/settings-reference.md` |
| 设计决策记录 | `docs/decisions/` |
| 国际化 (i18n) | `docs/i18n.md` |
| macOS 权限继承（TCC / 麦克风 / 摄像头 / 屏幕录制） | `docs/macos-permissions.md` |

## Common Tasks

| 任务 | 相关文件 / 命令 |
|------|----------------|
| 手机连接与中继 | `Mobile/`、`AI/AIChatSessionRegistry.swift`、`Settings/Sections/MobileAccessSectionView.swift`、`mobile-relay/`、`docs/mobile-access.md` |
| 修改 AI 连接与启动流程 | `AI/`、`TabContent/TabContentView.swift`、`Ghostty/GhosttyBridge.swift`、`docs/ai-terminals.md` |
| 修改主题颜色逻辑 | `Theme/ThemeManager.swift`, `Theme/AppTheme.swift`, `docs/architecture.md#theme` |
| 增加新的 workspace 元信息字段 | `Metadata/WorkspaceMetadata.swift` → `Metadata/MetadataRefresher.swift` → `Sidebar/WorkspaceListView.swift`（行视觉） |
| 改标签/分割窗格交互（新建 tab、拆分、拖 divider） | `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `TabContent/SplitPaneView.swift`, `Models/WorkspaceStore.swift`（新 CRUD 方法） |
| 增加新的内置快捷操作 | `Models/QuickAction.swift`（加 `BuiltinQuickAction` case + 默认命令 + `iconSource`），`Models/QuickActionsStore.swift`（默认 enabled 列表如需调整），`Localizable.xcstrings` + `Localization/L10n.swift`（displayName key），必要时 `Assets.xcassets` 加 SVG imageset（`template-rendering-intent: template`），`docs/settings-reference.md`（如新增 builtin id 范围） |
| 旧自定义快捷操作 | Settings → Quick Actions 保留历史配置；当前 AI 入口不执行这些命令，详见 `docs/ai-terminals.md` |
| 接入新的 ghostty C API | `Ghostty/GhosttyBridge.swift`，需同步更新 `docs/ghostty-integration.md` |
| 改自动更新 UI / 行为 | `TheAll/Update/UpdateStore.swift`, `TheAll/Update/UpdateUserDriver.swift`, `TheAll/Settings/Sections/UpdateSectionView.swift`, `TheAll/Sidebar/SidebarView.swift`（footer） |
| 改发布流水线 / appcast 格式 | `.github/workflows/release.yml`, `.github/scripts/render-appcast.sh`, `docs/build.md` |
| 发新版本 | 改 `project.yml` 的 `MARKETING_VERSION` → `./scripts/sync-landing-version.sh` 同步 landing → commit；仅在用户授权发版后手动运行 Release workflow（详见 `docs/build.md#release-流程`） |
| 同步 landing 版本号 | `./scripts/sync-landing-version.sh`（`--check` 为只读校验，CI drift check 会调用） |
| 新增设置项 | `Settings/Sections/<对应>.swift`, `Settings/SettingsConfigStore.swift`（默认值/校验）, `docs/settings-reference.md` |
| 新增终端状态来源 | `Models/HookMessage.swift` → `Models/HookSocketListener.swift` → `Models/TerminalStatusStore.swift`，展示在 `Theme/TerminalStatusIconView.swift` |
| 侧边栏 / Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceListView.swift`, `Bridge/SidebarListBridge.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |
| 跑测试 | `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests` |
| 重新生成 Xcode 工程 | `xcodegen generate`（修改 `project.yml` 后执行）|
| 检查文档漂移 | `./scripts/check-doc-drift.sh`（对比 Directory Structure 与真实 `TheAll/` 目录；同时校验 landing 版本号与 `project.yml` 一致） |
| 新增文案 / 支持新语言 | `TheAll/Localization/Localizable.xcstrings`, `TheAll/Localization/L10n.swift`, `TheAllTests/L10nSmokeTests.swift`, `docs/i18n.md` |
| 修改 tab 自动命名行为（auto title 来源 / 锁定语义） | `Models/TerminalSessionTitleStore.swift`, `Models/Workspace.swift`（displayTitle）, `Models/HookDispatcher.swift`（路由）, `Resources/agent-hooks/agent-hook.py`（claude/codex 来源）, `Resources/agent-hooks/opencode-plugin/theall-status.js`（opencode 来源） |

## Agent Permissions

**允许:**
- 修改 `TheAll/` 下任意 Swift 文件
- 运行 `xcodebuild build/test`、`xcodegen generate`
- 创建 `agent/` 前缀的 git 分支
- 修改 `docs/` 文档

**禁止（需人工确认）:**
- 修改 `scripts/build-vendor.sh` 或 Vendor 目录
- 修改 `project.yml`（影响 Xcode 工程结构）
- Push 到 master
- 修改 `.github/` CI 配置
- **主动重启 / `open` / `killall` 运行中的 TheAll.app** — TheAll 是原生 macOS 应用不支持热更新，但用户可能正在使用这个应用。改完代码跑 `xcodebuild build` 验证能编译即可，由用户自己决定何时重启看效果
