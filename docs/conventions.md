# Coding Conventions

## Swift 规范

### 命名

- 类型名：`PascalCase`（`WorkspaceStore`、`TerminalWindowView`）
- 方法/属性名：`camelCase`（`createTerminal(at:)`、`selectedWorkspace`）
- 常量：`camelCase`（`let defaultWidth: CGFloat = 720`）
- 通知名：`Notification.Name` extension，前缀 `theall`（`theAllCreateTerminalAtVisibleCenter`）

### 文件组织

每个文件只定义一个主要类型。相关的小型 extension 可以在同文件底部。
`// MARK: -` 分节，顺序：属性 → init → 公开方法 → 私有方法 → delegates/callbacks。

### @Observable vs ObservableObject

用 `@Observable`（Swift 5.9 Observation framework），不用 `ObservableObject`/`@Published`。
Store 类用 `final class`，不用 `struct`（引用语义方便 canvas 跨层持有）。

## AppKit / SwiftUI 边界

| 区域 | 技术 | 原因 |
|------|------|------|
| 侧边栏外壳（header / footer / alert / 通知） | SwiftUI View struct | 声明式，状态刷新省力 |
| 侧边栏列表行 | AppKit（`WorkspaceListView` NSView + private row item） | 行内图标动画、drag source 需要精确控制 |
| 标签条 + 分割窗格（TabBarView / TabContentView / SplitPaneView） | AppKit NSView subclass | NSSplitView 的 divider 拖拽 / z-order / live resize 比 SwiftUI 可靠；ghostty surface 对 frame 要求严格 |
| 终端叶子（GhosttyTerminalView） | AppKit NSView + Metal CALayer | libghostty 本身基于 NSView |
| 设置面板 | SwiftUI Form | 表单控件用声明式最省心 |
| 桥接层 | NSViewRepresentable（TabBridge / SidebarListBridge） | 标准做法，隔离两层 |

**不要** 在 TabContent / SplitPane 层引入 SwiftUI 布局（`.overlay`、`ZStack`、`GeometryReader` 等）管理终端位置 —— ghostty surface 对 frame 变化敏感，SwiftUI layout pass 的中间态会让 Metal renderer 抽风。
**不要** 在侧边栏外壳或设置面板里使用 NSView subclass（有现成 SwiftUI 控件时）。
**不要** 因为切换面板就 dismantle `TabBridge`：其下 ghostty surface 会被释放。需要"隐藏"时用 `.opacity(0)` + `.allowsHitTesting(false)` 保持视图常驻。

## 颜色规范

**禁止：**
```swift
// ❌ 硬编码颜色
view.layer?.backgroundColor = NSColor.black.cgColor
Text("hello").foregroundColor(.white)
```

**正确：**
```swift
// ✅ 从 ThemeManager 取 token
@Environment(ThemeManager.self) var themeManager
view.layer?.backgroundColor = themeManager.currentTheme.background.cgColor
Text("hello").foregroundColor(Color(themeManager.currentTheme.foreground))
```

## libghostty 调用

所有 `ghostty_*` 调用都在 `GhosttyBridge.swift` 或 `GhosttyTerminalView.swift` 中。
在其他 Swift 文件里 **禁止** 直接调用 C API。

如果需要新的 ghostty 功能，先在 GhosttyBridge 封装方法，再从调用方调用。

## 状态修改

**禁止直接改 Workspace struct 字段：**
```swift
// ❌
store.workspaces[0].name = "new name"
```

**正确：通过 WorkspaceStore 方法：**
```swift
// ✅ （先在 WorkspaceStore 添加方法）
store.renameWorkspace(id: id, to: "new name")
```

### Rename / Reorder 专用规范

所有 rename 和 reorder 操作必须调用 `WorkspaceStore` 的专用方法，UI 层不允许直接修改 `workspaces` 数组或 `Workspace.tabs` 字段：

- `renameWorkspace(id:to:)` / `renameTab(id:in:to:)`：内部做 trim + empty guard + 幂等比较
- `moveWorkspace(from:to:)` / `moveTab(from:to:in:)`：`(IndexSet, Int)` 签名对齐 SwiftUI `onMove`
- `moveTab(fromIndex:toIndex:in:)`：AppKit 拖拽便利 overload，`toIndex` 使用 insertion-index 语义

不引入 `order: Int` 字段——顺序完全靠数组索引 + JSON 持久化。

## Git 规范

```
type(scope): description

type:  feat | fix | refactor | test | docs | chore | perf | style | build | ci | revert
scope: sidebar | tabcontent | settings | theme | ghostty | models | metadata | bridge | build | docs
```

示例：
- `feat(tabcontent): add drag-to-reorder tabs`
- `fix(theme): fallback to system mode when ghostty config missing`
- `test(models): add SplitNode.replacing/removing invariant tests`

**分支命名：** `agent/feature-name` 或 `fix/issue-description`

每完成一个逻辑单元提交一次，不要在 session 结束时批量提交所有改动。

### 结构变化必须同步文档

增删 / 重命名 / 移动 `TheAll/` 下的目录或 Swift 文件时，**同一次提交**必须一起更新：

- `CLAUDE.md`（= `AGENTS.md` 符号链接）的 `Directory Structure` 块
- `docs/architecture.md` 中受影响的章节（Overview 树、Data Flow、Layer 小节）
- 如果是新的独立模块，额外补 `Common Tasks` 或 `Documentation Map` 条目

提交前运行 `./scripts/check-doc-drift.sh`：它对比 `CLAUDE.md` 里 Directory Structure 列出的 Swift 文件集合与真实 `TheAll/` 的文件集合，有差异会退出非零并打印 diff。

## 测试规范

- 单元测试放在 `TheAllTests/`，文件名 `<TestedType>Tests.swift`
- 测试方法名：`test_<scenario>_<expectedOutcome>()` 或 `test<WhatAndWhy>()`
- 不 mock WorkspaceStore（直接用 `init(persistenceKey: "test.\(UUID())")` 隔离）
- libghostty 相关的集成测试标注 `// Integration: requires libghostty`，可在 CI 跳过
