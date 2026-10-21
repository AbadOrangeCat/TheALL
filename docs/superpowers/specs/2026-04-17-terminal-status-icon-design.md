# 终端状态图标 Design

> Status: draft · 2026-04-17

## 目的

侧边栏 workspace 行与 tab 项各自增加一个"状态图标"，反映其关联终端的运行状态。核心使用场景：用户在一个 workspace 里用多个 tab 并行跑 Claude Code / Codex / opencode 等长跑 CLI，需要在侧边栏扫一眼就知道"哪个 workspace 还在忙、哪个已经完成、哪个挂了"。

## 四态模型

单个终端（一个 `ghostty_surface_t`）有四种状态：

| 状态 | 触发 | 视觉 |
|------|------|------|
| `neverRan` | 新开的 terminal，还没有任何命令跑过 | 空心描边灰圆 |
| `running(startedAt:)` | shell 开始执行一条命令（OSC 133 C / 等价信号） | 转动的 270° 描边弧，主色调 |
| `success(exitCode, duration, finishedAt)` | 命令结束且 `exitCode == 0` | 实心绿圆点 |
| `failed(exitCode, duration, finishedAt)` | 命令结束且 `exitCode != 0` | 实心红圆点 |

## 聚合规则

一个 tab 可能有多个 terminal（split panes）；一个 workspace 有多个 tab。上层聚合按优先级：

```
running > failed > success > neverRan
```

语义：

- 任一终端在 running → 上层显示 `running`
- 无 running、任一 failed → 上层显示 `failed`（红，促使用户介入）
- 无 running/failed、任一 success → 上层显示 `success`
- 全部 neverRan → 上层显示 `neverRan`

聚合函数用 reduce 统一实现，供 `aggregatedStatus(for: tab)` 和 `aggregatedStatus(for: workspace)` 复用。

## 数据层

新建 `Models/TerminalStatus.swift`：

```swift
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date)
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
}
```

新建 `Models/TerminalStatusStore.swift`，`@Observable` 单例，与 `WorkspaceStore` 并列注入 environment：

- `status(for terminalId: UUID) -> TerminalStatus`（默认 `.neverRan`）
- `setRunning(terminalId: UUID, at: Date)`
- `setFinished(terminalId: UUID, exitCode: Int32, duration: TimeInterval, at: Date)`
- `aggregatedStatus(terminalIds: [UUID]) -> TerminalStatus`
- 纯内存，不持久化。app 重启后全部回到 `neverRan`（与 shell 实际重启对齐）。

## 信号接入

信号源：OSC 133 shell integration → ghostty runtime action callback → `GHOSTTY_ACTION_COMMAND_FINISHED`（携带 `exit_code` 和 `duration`）。

两处基础设施改动：

### a) Shell integration 脚本就位

**当前状态**：`Vendor/ghostty/` 只有 `include/` 和 `lib/`，没有 `share/`。shell integration 脚本从未打包。`GhosttyBridge.initialize()` 也没给 libghostty 喂 `resources-dir`，所以即便脚本存在也不会被注入。

需要分三步：

1. **Vendor 侧**：`scripts/build-vendor.sh` 在 ghostty 构建产物里把 `share/ghostty/shell-integration/` 一起复制到 `Vendor/ghostty/share/`。
2. **App bundle 侧**：`project.yml` 新增 copy phase，把 `Vendor/ghostty/share/ghostty/` 复制进 app bundle 的 `Resources/ghostty/`。
3. **Runtime 侧**：`GhosttyBridge.initialize()` 读 `Bundle.main.resourcePath + "/ghostty"`，通过 `ghostty_config_load_file` 或等价机制告诉 libghostty `resources-dir`。具体 config key 需要在 ghostty Zig 源或 CLI 帮助里查（预期是 `resources-dir`）——plan 里会有一个 "验证 config key 并跑通 OSC 133" 的前置 task，发信号成功后再继续后面的 view 层改动。

⚠️ 步骤 1、2 涉及 `scripts/build-vendor.sh` 和 `project.yml`，CLAUDE.md 明确要人工确认；plan 会把它们拆成独立 task，到了就停下来等用户授权或自己跑。

### b) `actionCallback` 变路由器

`GhosttyBridge.actionCallback` 当前恒返回 `false`。改成：

1. 按 `ghostty_target_s.tag` 分支：`GHOSTTY_TARGET_SURFACE` 拿 `surface` 指针。
2. 通过 `surface → GhosttyTerminalView → terminalId` 反查（在 `GhosttyTerminalView` 上加 `terminalId: UUID` 字段，并让现有 `registry` 也能按 surface 指针查找）。
3. 分发 action：
   - `GHOSTTY_ACTION_COMMAND_FINISHED` → `TerminalStatusStore.setFinished(...)`
   - "命令开始"信号的具体 action name 需要实测（可能是 OSC 133 C 的某个未命名 action，或通过监听 prompt-related action 间接得到）。若 ghostty 只暴露 FINISHED 不暴露 STARTED，则用"收到 PTY 输出且当前非 running → 推断进入 running"的 fallback。这是唯一有实现风险的点，plan 里会有一个验证 task。

## 视图层

### `Theme/TerminalStatusIconView.swift`（新建 NSView）

10×10 pt 画布，`draw(_:)` 按 `status` 分支绘制：

- `.neverRan`：1 pt stroke + clear fill，颜色 `theme.textTertiary`
- `.running`：270° 弧线 stroke（1.5 pt），`theme.accent`（缺 token 就新增 `accent` 到 `AppTheme`）；`CABasicAnimation` 做匀速旋转，周期 1s
- `.success`：实心圆，`theme.success`（新增 token，亮色主题 `#3FB950` 暗色 `#3FB950`）
- `.failed`：实心圆，`theme.danger`（新增 token，`#F85149`）

单一 `update(status:theme:)` 入口，内部决定 stop/start 动画和重绘。

### Tab item（`TabContent/TabBarView.swift`）

`TabItemView.layout()` 改为：

```
[ hPad ][ 10pt icon ][ 6pt ][ title ... ][ close × ][ hPad ]
```

`refresh(...)` 签名追加 `status: TerminalStatus`，传给 icon.update。close × 的 hover 逻辑保持不变。

### Sidebar row（`Sidebar/WorkspaceListView.swift`）

`WorkspaceRowItemView` 右上角加一个 10pt icon view，垂直中线对齐 title（与 PR badge 同一水平线）。PR badge 若存在则左移到 icon 之前，间距 `DT.Space.xs`。

`refresh(...)` 签名追加 `status: TerminalStatus`。

### 订阅传导

沿用现有 metadata 刷新链路：

1. `TerminalStatusStore` 变化时 `WorkspaceListBridge` / `TabBridge` 观察到 → 触发宿主 view 的 `update(...)`。
2. 因为 NSView 层不直接 bind Observation，走"store 的 on-change trigger 推送到 Bridge.update" 的模式（和现有 `WorkspaceStore` / metadata 一样）。

## Tooltip

悬停 icon 显示一行文字：

| 状态 | Tooltip |
|------|---------|
| `neverRan` | 无 tooltip（或 `"Ready"`） |
| `running` | `"Running for 1m23s"`（从 `startedAt` 实时算；tooltip 每次 hover 时刷新） |
| `success` | `"Succeeded in 2m31s · exit 0"` |
| `failed` | `"Failed after 45s · exit 1"` |

实现：`TerminalStatusIconView.toolTip` setter，更新时机跟 `update(status:)` 一致。时长格式化用 `Duration.seconds(...).formatted(.time(pattern: .minuteSecond))` 或自写小工具。

**聚合层**（tab / workspace icon）的 tooltip：显示聚合后的状态对应的文字，running 时不精确到秒（`"Running"`，因为多个 terminal 的 startedAt 不同），success/failed 显示数量（`"3 terminals finished · 1 failed"` 类似）。具体文案在实现时 iterate。

## 文件变更清单

**新增：**
- `TheAll/Models/TerminalStatus.swift`
- `TheAll/Models/TerminalStatusStore.swift`
- `TheAll/Theme/TerminalStatusIconView.swift`
- `TheAllTests/TerminalStatusStoreTests.swift`

**修改：**
- `TheAll/Ghostty/GhosttyBridge.swift`（action 路由 + resources-dir 配置）
- `TheAll/Ghostty/GhosttyTerminalView.swift`（加 `terminalId` 字段 + registry 按 surface 查找）
- `TheAll/TabContent/TabBarView.swift`（`TabItemView` 插入 icon + 布局）
- `TheAll/Sidebar/WorkspaceListView.swift`（`WorkspaceRowItemView` 插入 icon + 布局）
- `TheAll/Bridge/TabBridge.swift`、`TheAll/Bridge/SidebarListBridge.swift`（订阅 `TerminalStatusStore`，把 status 推到 view 的 refresh）
- `TheAll/Theme/AppTheme.swift`、`TheAll/Theme/DesignTokens.swift`（新增 `accent` / `success` / `danger` token）
- `TheAll/TheAllApp.swift`（创建 `TerminalStatusStore` 并注入 environment）

**可能需要动（需人工确认）：**
- `scripts/build-vendor.sh`（shell-integration 脚本打包）
- `project.yml`（app bundle 里 Resources copy phase）

## 测试

- `TerminalStatusStoreTests`：
  - 单 terminal 四态转移（setRunning → setFinished）
  - `aggregatedStatus` 优先级（all 组合覆盖：空、全 neverRan、混合 success/failed、running + failed 等）
  - 聚合函数的 `reduce` 属性测试
- 手工验证（实现阶段记录）：
  - 开一个终端 → 跑 `ls` → 看到 success
  - 开一个终端 → 跑 `false` → 看到 failed
  - 跑 `sleep 60` → 看到 running 动画
  - 开 Claude Code / opencode → 看到 running；退出 → 看到 success/failed
  - 同一 tab 两个 split：一个 sleep，一个完成 → tab icon = running
  - workspace 里两个 tab：一个 sleep + 一个 failed → sidebar icon = running（优先级验证）

## 非目标（YAGNI）

- 状态持久化（app 重启后状态重置合理，不做）
- 手动重置某个 terminal 状态的 UI
- 历史命令列表 / 重跑按钮
- 命令完成时的 NSUserNotification（下一期考虑）
- 支持 shell integration 缺失时的 fallback 检测（OSC 133 不通就保持 `neverRan`；如果未来发现兼容性问题，再加 `ghostty_surface_mouse_captured` polling 作为弱 fallback）
