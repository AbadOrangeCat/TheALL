# Sidebar & Tab 管理能力：Rename / Delete / Reorder

**日期**：2026-04-16
**Scope**：为 Sidebar workspace 列表和 TabBar 增加重命名、删除确认、拖拽排序三项管理能力。

---

## 1. 背景与目标

### 现状

- `Sidebar`（SwiftUI）展示 workspace 列表，已有右键「Delete」（立即删除）+ inline 创建 TextField，**缺** rename、拖拽排序、删除确认
- `TabBarView`（AppKit NSView）展示 tab 列表，已有 `×` 关闭按钮 + `+` 新建按钮，**缺** rename、拖拽排序、右键菜单、关闭确认
- 数据层 `WorkspaceStore`（`@Observable`）有 `createWorkspace` / `deleteWorkspace` / `addTab` / `removeTab` / `selectTab`，**缺** rename / reorder 方法
- 持久化 key `theall.workspaces.v2`：`Workspace` / `TerminalTab` 均 Codable，顺序完全靠数组索引（**无 `order` 字段**）

### 目标

1. Sidebar workspace 与 TabBar tab 具备一致的「Rename / Delete / Reorder」管理能力
2. 交互符合 macOS 原生观感（右键菜单、拖拽 drop indicator、sheet 弹窗）
3. 所有状态变更经 `WorkspaceStore` 入口，遵守 `docs/conventions.md` 单一状态源约束
4. 不破坏现有持久化（不引入 `order` 字段，保持 v2 schema 兼容）

### 交互决策（已与产品确认）

| 决策项 | 选择 |
|---|---|
| Rename 触发 | **仅右键菜单**（双击保持为选中/切换） |
| 拖拽作用域 | **同容器内重排**（workspace 在 sidebar；tab 在当前 workspace 的 tabbar） |
| 删除确认 | **总是弹窗**（workspace delete 和 tab close 都走 alert） |
| 技术选型 | SwiftUI 原生拖拽 + AppKit NSPasteboard，共享 `WorkspaceStore` reorder 方法 |

---

## 2. 架构概览

```
                   ┌────────────────────────────────┐
                   │      WorkspaceStore            │
                   │  + renameWorkspace             │
                   │  + renameTab                   │
                   │  + moveWorkspace(IndexSet,to)  │
                   │  + moveTab(IndexSet,to,in:)    │
                   └───────────┬────────────────────┘
                               │ @Environment
                 ┌─────────────┴─────────────────┐
                 ▼                               ▼
     ┌──────────────────────┐         ┌────────────────────────┐
     │  SidebarView (SwiftUI)│        │  TabContentView (AppKit)│
     │  + contextMenu        │        │  + confirmCloseTab sheet│
     │  + renamingId state   │        │                        │
     │  + deleteAlert        │        └───────┬────────────────┘
     │  + draggable/drop     │                │
     └──────────────────────┘                 ▼
                                     ┌──────────────────────┐
                                     │   TabBarView (NSView)│
                                     │   + onRenameTab cb   │
                                     │   + onReorderTab cb  │
                                     │   + NSPasteboard drag│
                                     │   + rightMouseDown   │
                                     │   + inline NSTextField│
                                     └──────────────────────┘
```

**分层规则**：
- Sidebar（SwiftUI）用 SwiftUI 原生拖拽 API（`.draggable` + `.dropDestination`，macOS 13+）
- TabBar（AppKit）用 AppKit 原生 `NSPasteboard` + `NSDraggingSource/Destination`
- 数据变更 **只通过** `WorkspaceStore` 方法；UI 层不直接改 `workspaces` 数组或 `Workspace.tabs`

---

## 3. 数据层改动

### 3.1 `Models/WorkspaceStore.swift` 新增方法

```swift
// MARK: - Rename

func renameWorkspace(id: UUID, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let idx = workspaces.firstIndex(where: { $0.id == id }),
          workspaces[idx].name != trimmed else { return }
    workspaces[idx].name = trimmed
    save()
}

func renameTab(id: UUID, in workspaceId: UUID, to newTitle: String) {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }),
          let tabIdx = workspaces[wsIdx].tabs.firstIndex(where: { $0.id == id }),
          workspaces[wsIdx].tabs[tabIdx].title != trimmed else { return }
    workspaces[wsIdx].tabs[tabIdx].title = trimmed
    save()
}

// MARK: - Reorder

func moveWorkspace(from source: IndexSet, to destination: Int) {
    let before = workspaces
    workspaces.move(fromOffsets: source, toOffset: destination)
    guard workspaces.map(\.id) != before.map(\.id) else { return }
    save()
}

func moveTab(from source: IndexSet, to destination: Int, in workspaceId: UUID) {
    guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
    let before = workspaces[wsIdx].tabs
    workspaces[wsIdx].tabs.move(fromOffsets: source, toOffset: destination)
    guard workspaces[wsIdx].tabs.map(\.id) != before.map(\.id) else { return }
    save()
}

// AppKit 便利 overload（TabBarView 拖拽使用）
func moveTab(fromIndex: Int, toIndex: Int, in workspaceId: UUID) {
    // Array.move(fromOffsets:toOffset:) 语义：destination 是"插入位置"
    // 若从 2 拖到 5，destination 应传 5（不是 4）——与 SwiftUI onMove 一致
    moveTab(from: IndexSet([fromIndex]), to: toIndex, in: workspaceId)
}
```

**设计要点**：
- `IndexSet` + `Int` 签名匹配 SwiftUI `onMove` 习惯；AppKit 侧用 `moveTab(fromIndex:toIndex:in:)` 便利 overload
- `computeInsertionIndex` 在 TabBarView 中必须返回"插入位置"语义（0…count），而非目标位置语义
- 空白 / 同值 / 越界 / noop 均 early-return，避免无意义 `save()`
- 不引入 `order` 字段（持久化 key 仍是 `theall.workspaces.v2`，schema 不变，旧数据自动兼容）
- `selectedId` / `selectedTabId` 在 reorder 时自然跟随（改的是数组，不是 id）

### 3.2 `Models/Workspace.swift`

无改动。现有 `name` / `title` 字段满足需求。

---

## 4. Sidebar 层（SwiftUI）

### 4.1 文件改动

- `Sidebar/SidebarView.swift`
- `Sidebar/WorkspaceRowView.swift`

### 4.2 右键菜单

扩展 `SidebarView.swift` 第 48-62 的 `ForEach` 内 `.contextMenu`：

```swift
.contextMenu {
    Button("Rename") { beginRename(ws.id) }
    Divider()
    Button("Delete", role: .destructive) {
        workspaceToDelete = ws.id
    }
}
```

### 4.3 Rename UI

**State**：`SidebarView` 新增：
```swift
@State private var renamingId: UUID?
@State private var renameDraft: String = ""
@FocusState private var renameFocused: Bool
```

`beginRename(_:)` 设置 `renamingId` 和 `renameDraft`，并 `renameFocused = true`。

**Row 渲染**：`WorkspaceRowView` 增加参数：
```swift
let isRenaming: Bool
@Binding var draft: String
var focusBinding: FocusState<Bool>.Binding
var onCommit: () -> Void
var onCancel: () -> Void
```

- `isRenaming == false` → 原 `Text(ws.name)` 渲染
- `isRenaming == true` → `TextField("", text: $draft)` + `.textFieldStyle(.plain)` + 相同字号/字体 + `.focused(focusBinding)` + `.onSubmit { onCommit() }` + `.onExitCommand { onCancel() }` + `.onAppear { selectAll }`（借助 `NSTextView` 或 `TextField.onAppear` 配合 responder 全选）

**Commit 语义**：
- `onCommit` → `store.renameWorkspace(id:, to: renameDraft)` → 清空 `renamingId`
- `onCancel` → 直接清空 `renamingId`，不写入
- **失焦自动提交**：显式监听 focus 变化，不依赖隐式行为：
  ```swift
  .onChange(of: renameFocused) { oldValue, newValue in
      if oldValue && !newValue && renamingId != nil {
          onCommit()  // 失焦即 commit
      }
  }
  ```
- Esc / `.onExitCommand` 先置 `renamingId = nil`，再触发失焦，`onChange` 观察到 `renamingId == nil` 跳过 commit

### 4.4 Delete 确认 alert

```swift
@State private var workspaceToDelete: UUID?

.alert("Delete workspace?",
       isPresented: Binding(get: { workspaceToDelete != nil },
                            set: { if !$0 { workspaceToDelete = nil } })) {
    Button("Cancel", role: .cancel) { workspaceToDelete = nil }
    Button("Delete", role: .destructive) {
        if let id = workspaceToDelete { store.deleteWorkspace(id: id) }
        workspaceToDelete = nil
    }
} message: {
    if let id = workspaceToDelete,
       let ws = store.workspaces.first(where: { $0.id == id }) {
        Text("「\(ws.name)」及其所有 tab 将被删除，此操作不可撤销。")
    }
}
```

### 4.5 拖拽排序

**自定义 Transferable**：

```swift
struct WorkspaceDragItem: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .theAllWorkspace)
    }
}

extension UTType {
    static let theAllWorkspace = UTType(exportedAs: "com.theall.workspace")
}
```

**视图侧**：

```swift
ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, ws in
    dropZone(before: index)             // 1pt 高度的 drop 命中区
    WorkspaceRowView(...)
        .draggable(WorkspaceDragItem(id: ws.id))
}
dropZone(before: store.workspaces.count)  // 末尾 drop zone

@State private var hoveredDropIndex: Int?

@ViewBuilder
private func dropZone(before destination: Int) -> some View {
    Rectangle()
        .fill(hoveredDropIndex == destination ? theme.accent : Color.clear)
        .frame(height: 2)
        .dropDestination(for: WorkspaceDragItem.self) { items, _ in
            guard let item = items.first,
                  let from = store.workspaces.firstIndex(where: { $0.id == item.id })
            else { return false }
            store.moveWorkspace(from: IndexSet([from]), to: destination)
            return true
        } isTargeted: { hovering in
            hoveredDropIndex = hovering ? destination : (hoveredDropIndex == destination ? nil : hoveredDropIndex)
        }
}
```

**视觉**：drop zone 默认透明；hover 时用 `AppTheme.accent` token 渲染 2pt 高亮条。不硬编码颜色（conventions.md 第 1 条）。

---

## 5. TabBar 层（AppKit）

### 5.1 文件改动

- `TabContent/TabBarView.swift`
- `TabContent/TabContentView.swift`

### 5.2 TabBarView 新增回调

```swift
var onRenameTab: ((UUID, String) -> Void)?    // (tabId, newTitle)
var onReorderTab: ((Int, Int) -> Void)?       // (fromIndex, toIndex)
// 原 onCloseTab 保留；TabContentView 内部将其接入确认弹窗
```

### 5.3 右键菜单

`TabItemView` 覆写 `rightMouseDown`：

```swift
override func rightMouseDown(with event: NSEvent) {
    let menu = NSMenu()

    let renameItem = NSMenuItem(title: "Rename",
                                action: #selector(beginRename),
                                keyEquivalent: "")
    renameItem.target = self
    menu.addItem(renameItem)

    menu.addItem(.separator())

    let closeItem = NSMenuItem(title: "Close",
                               action: #selector(requestClose),
                               keyEquivalent: "")
    closeItem.target = self
    menu.addItem(closeItem)

    NSMenu.popUpContextMenu(menu, with: event, for: self)
}
```

### 5.4 Inline Rename（NSTextField）

`TabItemView` 持有隐藏 `NSTextField`，与 titleLabel 同 frame / font / color。

**状态切换**：
```swift
@objc private func beginRename() {
    titleLabel.isHidden = true
    renameField.stringValue = tab.title
    renameField.isHidden = false
    window?.makeFirstResponder(renameField)
    renameField.currentEditor()?.selectAll(nil)
}

// NSTextFieldDelegate
func controlTextDidEndEditing(_ notification: Notification) {
    commitRename()
}

// NSResponder
override func cancelOperation(_ sender: Any?) {
    cancelRename()  // Esc：恢复原 title，不回调
}

private func commitRename() {
    let newTitle = renameField.stringValue
    finishRenameUI()
    onRename?(tab.id, newTitle)  // 传给 TabBarView → TabContentView → store
}
```

回车键通过 `NSTextField.action` / `controlTextDidEndEditing` 统一走 commit 路径。

### 5.5 Close 确认弹窗

`TabContentView.swift` 第 53-67 回调接入处，把 `onCloseTab` 替换为确认流程：

```swift
tabBar.onCloseTab = { [weak self] tabId in
    self?.confirmCloseTab(tabId)
}

private func confirmCloseTab(_ tabId: UUID) {
    guard let window,
          let title = store?.workspaces
              .first(where: { $0.id == wsId })?
              .tabs.first(where: { $0.id == tabId })?.title
    else { return }

    let alert = NSAlert()
    alert.messageText = "Close tab?"
    alert.informativeText = "「\(title)」中的所有终端进程将被终止。"
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning

    alert.beginSheetModal(for: window) { [weak self] response in
        guard response == .alertFirstButtonReturn, let self else { return }
        self.store?.removeTab(id: tabId, from: self.wsId)
        self.reloadFromStore()
    }
}
```

点击 `×` 按钮与右键菜单 Close 走同一入口 → 统一弹窗。

**最后一个 tab 的处理**：当 `tabs.count == 1` 时，`×` 按钮隐藏、右键菜单 Close 项置为 disabled（`isEnabled = false`），避免用户走完弹窗后才发现删除无效。这样用户体验与 Safari / Terminal.app 一致（不允许关闭最后一个 tab）。

### 5.6 拖拽排序（NSPasteboard）

**自定义 pasteboard type**：
```swift
extension NSPasteboard.PasteboardType {
    static let theAllTab = NSPasteboard.PasteboardType("com.theall.tab")
}
```

**TabItemView 作为 DraggingSource**：
```swift
override func mouseDragged(with event: NSEvent) {
    guard dragStartPoint.distance(to: event.locationInWindow) > 4 else { return }

    let pbItem = NSPasteboardItem()
    pbItem.setString(tab.id.uuidString, forType: .theAllTab)

    let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
    draggingItem.setDraggingFrame(bounds, contents: snapshotImage())

    beginDraggingSession(with: [draggingItem], event: event, source: self)
}

// NSDraggingSource
func draggingSession(_ session: NSDraggingSession,
                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return .move
}
```

**TabBarView 作为 DraggingDestination**：
```swift
override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.theAllTab])
}

override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let insertionIndex = computeInsertionIndex(at: sender.draggingLocation)
    showDropIndicator(before: insertionIndex)
    return .move
}

override func draggingExited(_ sender: NSDraggingInfo?) {
    hideDropIndicator()
}

override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { hideDropIndicator() }
    guard let idString = sender.draggingPasteboard.string(forType: .theAllTab),
          let tabId = UUID(uuidString: idString),
          let fromIndex = tabs.firstIndex(where: { $0.id == tabId })
    else { return false }

    let toIndex = computeInsertionIndex(at: sender.draggingLocation)
    onReorderTab?(fromIndex, toIndex)
    return true
}
```

**Drop indicator**：1pt 宽度竖线，颜色走 `applyTheme` 传入的 `accent` token，绝不硬编码。

**TabContentView 接入**：
```swift
tabBar.onReorderTab = { [weak self] from, to in
    guard let self, let store = self.store else { return }
    store.moveTab(from: IndexSet([from]), to: to, in: self.wsId)
    self.reloadFromStore()
}
tabBar.onRenameTab = { [weak self] tabId, title in
    guard let self else { return }
    self.store?.renameTab(id: tabId, in: self.wsId, to: title)
}
```

**缓存安全性**：`TabContentView.tabPanes: [UUID: SplitPaneView]` 以 tab UUID 为 key，reorder 不改 UUID，缓存全部命中；`reloadFromStore` 只重排 tabbar 顺序，不销毁/重建 pane 树，焦点保留。

---

## 6. 错误处理与边界

| 场景 | 处理 |
|---|---|
| Rename 空串 / 纯空白 | 裁剪后为空 → store 方法 early-return，UI 回退旧值 |
| Rename 与原值相同 | store 方法 early-return，不触发 `save()` |
| Delete 最后一个 workspace | 允许（沿用现有 `deleteWorkspace` 行为，`selectedId` 自动回退） |
| Close 最后一个 tab | UI 层禁用入口（`×` 隐藏、菜单 Close disabled），弹窗不会出现；`removeTab` 至少保留一个的逻辑作为数据层兜底不变 |
| Reorder 非法索引 | store 方法 guard，直接 early-return |
| Reorder 到同一位置 | 比较前后 `id` 数组，noop 跳过 `save()` |
| Rename 过程中点其他 row / 外部 | 失焦 → commit（SwiftUI `.onSubmit` / AppKit `controlTextDidEndEditing`） |
| Rename 过程中点 Delete | 先 cancel rename 再触发 delete alert |
| 拖拽到容器空白区 | `computeInsertionIndex` 返回末尾（destination = count） |
| 拖拽回自身 / 相邻同位置 | store `moveTab/moveWorkspace` 通过前后比较跳过 save |

---

## 7. 测试策略

### 7.1 单元测试（`TheAllTests/WorkspaceStoreTests.swift`）

新增：
1. `testRenameWorkspace` — 改名后查 name + 再 load 保留
2. `testRenameWorkspace_emptyStringIgnored`
3. `testRenameWorkspace_whitespaceOnlyIgnored`
4. `testRenameWorkspace_sameValueIsNoop` — 断言不触发 persistence 写（观察一次 encode 开销或加 `saveCount` 测试钩子）
5. `testRenameTab` + `testRenameTab_empty`
6. `testMoveWorkspace_basic` — `IndexSet([2])` → `0`，断言顺序
7. `testMoveWorkspace_outOfBounds` — guard 生效、数组不变
8. `testMoveWorkspace_sameSpotIsNoop`
9. `testMoveTab_basic` + `testMoveTab_preservesSelectedTabId`
10. `testMoveTab_persistenceRoundTrip` — reorder → save → reload → 顺序保留

### 7.2 UI 手测清单

**Sidebar**：
- [ ] 右键 row → Rename → TextField 获焦、全选
- [ ] 输入新名 → Enter 生效 + 持久化（重启后保留）
- [ ] Esc 取消不写入
- [ ] 空输入 Enter → 回退原值
- [ ] 失焦自动提交
- [ ] 右键 row → Delete → alert → Cancel 不删 / Delete 真删
- [ ] 拖拽 row 上下，drop zone 高亮、松手即重排
- [ ] 重启 app 顺序保留
- [ ] 选中项在 rename / reorder 后保留

**TabBar**：
- [ ] 右键 tab → 菜单出现 Rename + Close
- [ ] Rename → 内部 NSTextField 获焦、全选；回车 / 失焦提交；Esc 取消
- [ ] 空输入不覆盖
- [ ] 右键 Close 和 `×` 按钮 → 都弹 sheet 确认
- [ ] Cancel 不关 / Close 真关
- [ ] 拖拽 tab 左右，drop indicator 竖线显示正确位置
- [ ] Reorder 后当前选中 tab 不变、内容（split/terminal）无闪烁、焦点保留
- [ ] 重启 app tab 顺序保留

**主题校验**：
- [ ] 切换主题后：右键菜单、sheet、TextField、drop indicator 颜色全部随主题变
- [ ] grep 新增文件：无 `Color(...)` / `NSColor(...)` 硬编码

---

## 8. 不在本次 scope

- 键盘快捷键（Cmd+W close tab / F2 / Return rename）
- 跨 workspace 拖拽 tab
- 「Close Other Tabs」/「Close to the Right」等扩展菜单
- Undo / Redo 支持
- Workspace 分组 / folder 结构

---

## 9. 文档更新

- `docs/conventions.md`：新增条目「rename / reorder 统一走 `WorkspaceStore` 方法」
- `CLAUDE.md` Common Tasks 表新增一行：
  | 任务 | 相关文件 |
  |---|---|
  | 修改侧边栏/Tab 的 rename/reorder/delete 交互 | `Sidebar/SidebarView.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |

---

## 10. 文件改动总表

| 文件 | 改动 |
|---|---|
| `TheAll/Models/WorkspaceStore.swift` | +4 方法（rename × 2、move × 2）+ 便利 overload |
| `TheAll/Sidebar/SidebarView.swift` | +context menu item、+rename state、+delete alert、+drag/drop zones |
| `TheAll/Sidebar/WorkspaceRowView.swift` | +isRenaming/draft/focus/commit/cancel 参数 |
| `TheAll/Sidebar/DragTypes.swift`（新） | `WorkspaceDragItem` + `UTType.theAllWorkspace` |
| `TheAll/TabContent/TabBarView.swift` | +onRenameTab/onReorderTab 回调、NSDraggingDestination、drop indicator；TabItemView +rightMouseDown、+inline NSTextField、NSDraggingSource |
| `TheAll/TabContent/TabContentView.swift` | onCloseTab 改走 confirmCloseTab sheet；+onRenameTab/onReorderTab wiring |
| `TheAll/TabContent/PasteboardTypes.swift`（新） | `NSPasteboard.PasteboardType.theAllTab` |
| `TheAllTests/WorkspaceStoreTests.swift` | +10 单元测试 |
| `docs/conventions.md` | +rename/reorder 规范条目 |
| `CLAUDE.md` | Common Tasks 表 +1 行 |
