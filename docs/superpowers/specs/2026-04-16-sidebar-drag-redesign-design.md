# Sidebar 拖拽交互重设计

**Status:** Approved (brainstorm)
**Date:** 2026-04-16
**Owner:** 澄途

## 背景与问题

侧边栏当前用 SwiftUI `.onDrag` / `.onDrop` / `.onHover` 实现 workspace 重排，
踩到 SwiftUI 的多处固有问题：

1. `.onHover(false)` 在 `.onDrag` 进行期间不可靠触发 → 拖拽结束后 hover 色"卡住"，
   与 selected 行同时显示出"两个 active 色"。
2. `.onDrag` + `.onTapGesture` 共存使短距离拖拽频繁被识别为 tap → 拖拽常被取消。
3. SwiftUI `.onDrop(of:isTargeted:perform:)` 不支持声明 `NSDragOperation`，
   光标显示 "+" copy 标识，语义错误。
4. 行间用 6pt `dropZone` 占位制造点击死区。

项目内 `TheAll/TabContent/TabBarView.swift` 已有一套基于 AppKit 的拖拽实现，覆盖
所有上述问题且体验良好（live reorder preview、4pt 阈值、`.move` 操作符、
`NSTrackingArea` 可靠 hover）。本设计将该 pattern 1:1 移植到侧边栏。

## 目标

- 拖拽体验对齐 `TabBarView`：live 重排预览 + 拖影、4pt 触发阈值、零光标残影、零 hover 残影。
- 不破坏现有的：选中、Rename（context menu + inline TextField）、删除确认、
  workspace 创建、metadata 异步刷新（git branch / PR / 通知）、`theAllBeginCreateWorkspace` 通知响应。
- 视觉风格不变：行卡片圆角、padding、配色与现状一致。

## 非目标（YAGNI）

- 多选拖拽
- 拖出 sidebar（拖到 canvas、拖出窗口、跨进程）
- 长按延时进入拖拽
- 拖拽中渲染 2pt accent 横线（行让位本身已是足够清晰的指示）

## 架构总览

```
ContentView (SwiftUI)
└── SidebarView (SwiftUI 壳；header/footer/alert/refresher)
    └── SidebarListBridge: NSViewRepresentable          ← 新
        └── WorkspaceListView: NSView                   ← 新
            ├── NSScrollView
            └── [WorkspaceRowItemView: NSView, ...]    ← 新
```

数据流单向：

- SwiftUI → AppKit：`SidebarListBridge.updateNSView` 调
  `WorkspaceListView.update(workspaces:selectedId:metadata:theme:)`。
- AppKit → SwiftUI：行级回调（`onSelect` / `onRename` / `onReorder` / `onRequestDelete`）
  冒到 bridge → 调 `store` 方法或设 SwiftUI `@State`。

## 文件改动

### 新增

| 路径 | 角色 |
|---|---|
| `TheAll/Sidebar/WorkspacePasteboardType.swift` | `NSPasteboard.PasteboardType.theAllWorkspace = "com.theall.workspace"`，仅本进程 sidebar 重排用 |
| `TheAll/Sidebar/WorkspaceListView.swift` | 同文件装两个类：`final class WorkspaceListView: NSView` + `NSDraggingDestination`（列表容器、`NSScrollView`、live preview 重排）；以及 `private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate, NSDraggingSource`（行内交互全部）。与 `TabBarView.swift` 同结构 |
| `TheAll/Bridge/SidebarListBridge.swift` | `struct : NSViewRepresentable` |

### 修改

| 路径 | 改动 |
|---|---|
| `TheAll/Sidebar/SidebarView.swift` | 删 `workspaceList` / `dropZone` / `displayedWorkspaces` / `handleDrop` / `resetDragState` / 所有 drag/hover/rename state；header / footer / `.alert` / 通知订阅 / `metadataMap+refreshers` 保留；列表位置换成 `SidebarListBridge(...)`；新增 `metadataTick` 触发 refresh 重渲染 |
| `CLAUDE.md` | Key Conventions §4 更新表述；Common Tasks 表 sidebar 行补充新文件 |

### 删除

| 路径 | 原因 |
|---|---|
| `TheAll/Sidebar/WorkspaceRowView.swift` | 被 `WorkspaceRowItemView` 取代 |

## 详细设计

### `WorkspaceListView`

公共 API：

```swift
final class WorkspaceListView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onReorder: ((Int, Int) -> Void)?    // (fromIndex, toIndex) insertion 0…count
    var onRequestDelete: ((UUID) -> Void)?

    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                theme: AppTheme)
    func applyTheme(_ theme: AppTheme)
}
```

行高 `44pt` 固定（name 12 + xxs 间距 + branch 10 + 上下 xs=4 内填充 + 上下 xxs=2 外间距）。
行间间距 `0pt`。

**id-diff 增量刷新**（与 `TabBarView.rebuildTabItems` 完全一致策略）：

- 现有 row id 序列 == 目标 → 仅调每个 row 的 `refresh(...)`，保留实例与 first responder
  （rename 中的 `NSTextField` 不丢、拖拽 `mouseDown/mouseDragged` 链不断）。
- 序列不一致（增删/重排）→ 完整重建。这种情况下用户不在 rename 也不在拖拽，安全。

**live preview 顺序**：内部 `previewOrdered(items:)` 依 `previewInsertionIndex` 把
被拖项移除并插入 dest 位置；`layoutRows(animated:)` 用 `0.16s` `NSAnimationContext`
做缓动。

**`NSDraggingDestination`**：

- `registerForDraggedTypes([.theAllWorkspace])`
- `draggingEntered`：从 pasteboard 读 uuid → `draggingId = uuid`，调 `draggingUpdated`
- `draggingUpdated`：`pointInSelf = convert(draggingLocation, from: nil)`；
  `insertion = insertionIndex(at:)`（按原始 workspaces 顺序的 slot 中线）；
  仅当变化时刷新 preview。`enclosingScrollView?.contentView.autoscroll(with:)`
  让 sidebar 边缘自动滚。返回 `.move`。
- `draggingExited`：清 `previewInsertionIndex`，**保留** `draggingId`。重排回原序。
- `performDragOperation`：`onReorder?(fromIndex, toIndex)` → `cleanupAfterDrag()`
- `cleanupAfterDrag`：清 `draggingId` 和 `previewInsertionIndex`，无动画恢复布局。

### `WorkspaceRowItemView`（与 `WorkspaceListView` 同文件，`private`）

API：

```swift
private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let workspaceId: UUID
    var onSelect: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDragEnded: (() -> Void)?      // → list.cleanupAfterDrag (失败路径兜底)
    var isDragGhost: Bool { didSet { alphaValue = isDragGhost ? 0.35 : 1 } }

    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata, theme: AppTheme)
    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata, theme: AppTheme)
    func applyTheme(_ theme: AppTheme)
}
```

子视图：`backgroundLayer`（圆角 `DT.Radius.row=6`）、`titleLabel`、`branchLabel`、
`prBadge`、`renameField`（`isHidden = true` 默认）。

**状态视觉**

| 状态 | 背景 | 字体 | 主文本 |
|---|---|---|---|
| Default | clear | `body 12 regular` | `theme.textSecondary` |
| Hover | `theme.border` | 同上 | 同上 |
| Selected | `theme.borderStrong` | `bodyB 12 semibold` | `theme.textPrimary` |
| isDragGhost | 当前态 × `alpha 0.35` | — | — |

**鼠标交互**

- `updateTrackingAreas` 装 `[.activeAlways, .mouseEnteredAndExited, .inVisibleRect]`。
- `mouseEntered/Exited` 切 `isHovered`，调 `updateStyle()`。AppKit drag session
  期间 tracking 暂停，session 结束系统重发 entered，**不存在卡 hover**。
- `mouseDown`：记 `mouseDownLocation`，调 `onSelect?()`。
- `mouseDragged`：`isRenaming` 直接 return；
  `dx*dx + dy*dy <= 16` 直接 return（4pt 阈值）；
  写 `NSPasteboardItem(type: .theAllWorkspace, string: uuid.uuidString)`，
  `bitmapImageRepForCachingDisplay(in: bounds)` 取拖影，
  `beginDraggingSession(with:event:source: self)`。
- `NSDraggingSource.sourceOperationMaskFor` → `.move`（消除 "+" copy 光标）。
- `draggingSession(_:endedAt:operation:)` → `onDragEnded?()`（兜底）。
- `rightMouseDown`：弹 `NSMenu`（`autoenablesItems = false`）：
  - **Rename** → `beginRenameAction()`
  - 分隔
  - **Delete** → `onRequestDelete?()` → 冒到 SwiftUI 壳触发 `.alert`

**Inline rename**

- `beginRenameAction`：隐 `titleLabel`、显 `renameField`、`makeFirstResponder(renameField)`、`selectAll`。
- `controlTextDidEndEditing` → `commitRename` → `onRename?(newTitle)`。
- `doCommandBy NSResponder.cancelOperation(_:)`（Esc）→ `cancelRename`，恢复 `originalTitle`。
- 点其它行 → 第一响应者切换 → 系统自动触发 `controlTextDidEndEditing` → 自动 commit。

### `SidebarListBridge`

```swift
struct SidebarListBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme
    var metadata: [UUID: WorkspaceMetadata]
    var onRequestDelete: (UUID) -> Void

    func makeNSView(context: Context) -> WorkspaceListView {
        let view = WorkspaceListView()
        wireCallbacks(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata, theme: theme)
        return view
    }

    func updateNSView(_ view: WorkspaceListView, context: Context) {
        wireCallbacks(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata, theme: theme)
    }

    private func wireCallbacks(_ view: WorkspaceListView) {
        view.onSelect        = { store.select(id: $0) }
        view.onRename        = { store.renameWorkspace(id: $0, to: $1) }
        view.onReorder       = { store.moveWorkspace(from: IndexSet([$0]), to: $1) }
        view.onRequestDelete = { onRequestDelete($0) }
    }
}
```

### `SidebarView`（SwiftUI 壳精简）

保留：`isCreating` / `newWorkspaceName` / `newFieldFocused` / `workspaceToDelete` /
`metadataMap` / `refreshers` / 创建框 / 删除 alert / `theAllBeginCreateWorkspace` 订阅 /
`startRefreshers()`。

新增：`@State private var metadataTick: Int = 0`，由 `MetadataRefresher` 在每次
完成 refresh 后通过新增的 `onRefresh` closure 回调时 `metadataTick &+= 1`。
该 tick 只用于触发 SwiftUI body 重渲染，**不传入 bridge**——`updateNSView` 会被
SwiftUI 自动调用，拿当前 `metadataMap` 推下去即可。

列表位置：

```swift
SidebarListBridge(
    store: store,
    theme: theme,
    metadata: metadataMap,
    onRequestDelete: { workspaceToDelete = $0 }
)
```

删除：`renamingId` / `renameDraft` / `renameFocused` / `draggingId` /
`hoveredDropIndex` / `displayedWorkspaces` / `dropZone` / `handleDrop` /
`resetDragState` / `commitRename` / `cancelRename` / `beginRename` 全部去掉。

### `WorkspaceMetadata` 的 `@Observable` 处理

`metadataMap: [UUID: WorkspaceMetadata]` 中 value 是 `@Observable final class`。
SwiftUI 不会因为 metadata 内字段变更触发 `updateNSView`（dict 引用值未变）。
`MetadataRefresher` 当前异步更新 `WorkspaceMetadata` 字段。

**解法**：`MetadataRefresher` 新增可选 `onRefresh: (() -> Void)?` closure，
SidebarView 在 `startRefreshers()` 中给每个 refresher 装一个 `{ metadataTick &+= 1 }`。
SwiftUI 重跑 body → `updateNSView` → `WorkspaceListView.update(...)` →
对每行调 `refresh(...)` 拿到最新 `WorkspaceMetadata`。

### CLAUDE.md 更新

**Key Conventions §4** 表述更新：

> Canvas / TabBar / SidebarList 用 NSView subclass；SidebarView 外壳（header /
> footer / alert / 通知订阅 / 元数据 refresher 生命周期）用 SwiftUI View struct。
> AppKit 与 SwiftUI 的边界在 `*Bridge: NSViewRepresentable`。

**Common Tasks 表 sidebar 行**：

| 任务 | 文件 |
|---|---|
| 侧边栏/Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceListView.swift`, `Sidebar/WorkspaceRowItemView.swift`, `Bridge/SidebarListBridge.swift`, `TabContent/TabBarView.swift`, `Models/WorkspaceStore.swift` |

## 测试策略

- **数据层**：现有 `WorkspaceStore` 测试覆盖 `moveWorkspace` / `renameWorkspace` /
  `deleteWorkspace` / `select`，本次不改动。
- **AppKit drag**：drag session 难以单元测试，沿用 TabBar 现有策略——人工回归
  覆盖：拖拽重排、rename 提交/取消、删除流程、hover 切换、selected 视觉。
- **新增 smoke test**：`TheAllTests/SidebarListBridgeTests.swift` —— `makeNSView`
  返回非 nil；`update(...)` 在含 0 / 1 / 多个 workspace 三种状态下不崩；
  传入选中态后 row count 与 selected 数正确。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `metadataTick` 触发频率过高导致频繁重建 | `update(...)` 走 id-diff，metadata 变化只走原地 `refresh()`，无 view 销毁 |
| Rename 中 `updateNSView` 把 `NSTextField` 重置 | id-diff 命中 → 走 `refresh(...)`，不动 `renameField`；只在 `isRenaming == false` 时同步 `titleLabel.stringValue` |
| 拖拽中 `update(...)` 重排行 | `update(...)` 看见 ids 序列没变只 refresh；ids 真正变化（store 更新）时 cleanupAfterDrag 已经先跑过，无冲突 |
| 删除 alert 的 SwiftUI ↔ AppKit 跳转产生焦点错乱 | `onRequestDelete` 只是设 SwiftUI `@State`，alert 弹出时 NSView 自动失焦，标准行为 |

## 实施顺序提示（移交 implementation plan 用）

1. 新增 `WorkspacePasteboardType.swift`
2. 在新文件 `WorkspaceListView.swift` 中实现 `WorkspaceRowItemView`（`private`，独立可手测）
3. 在同文件实现 `WorkspaceListView`（容器 + drag destination）
4. 实现 `SidebarListBridge`
5. 重构 `SidebarView` 接入 bridge，删旧逻辑
6. 删 `WorkspaceRowView.swift`
7. `MetadataRefresher` 新增 `onRefresh` closure，`SidebarView` 注入 `metadataTick`
8. 新增 `SidebarListBridgeTests`
9. `xcodegen generate`、`xcodebuild build`、`xcodebuild test`
10. 更新 `CLAUDE.md`
11. 人工回归：拖拽重排、rename、删除、hover、metadata 异步刷新可见
