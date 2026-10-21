# Sidebar & Tab Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Sidebar workspace 列表与 TabBar 增加 rename（右键菜单）、delete 确认、同容器内拖拽排序三项管理能力。

**Architecture:** 数据变更全部走 `WorkspaceStore` 新增的 4 个方法（`renameWorkspace` / `renameTab` / `moveWorkspace` / `moveTab`），UI 层按栈对应：Sidebar（SwiftUI）用 `.draggable + .dropDestination`，TabBar（AppKit）用 `NSPasteboard + NSDraggingSource/Destination`。设计文档：`docs/superpowers/specs/2026-04-16-sidebar-tab-management-design.md`。

**Tech Stack:** Swift 5.9+、SwiftUI（macOS 13+）、AppKit、`@Observable`、UserDefaults（JSON Codable）、XCTest。

---

## 约定（所有任务通用）

- **测试命令**：`xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests/<testName>`
- **整套测试**：`xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests`
- **构建验证**：`xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug`
- **提交格式**：`type(scope): description`（scope 对应目录，如 `store` / `sidebar` / `tabs`）
- **颜色硬约束**：所有颜色必须来自 `AppTheme` 或 `DT` token；禁止 `Color(...)` / `NSColor(...)` 直接硬编码（`docs/conventions.md` 第 1 条）
- **状态修改硬约束**：UI 层不直接改 `store.workspaces` 或 `Workspace.tabs`，必须调用 store 方法

---

## Phase 1 — 数据层（Task 1-4）

### Task 1：`renameWorkspace`

**Files:**
- Modify: `TheAll/Models/WorkspaceStore.swift`（在 `deleteWorkspace` 后，约第 40 行后追加）
- Test: `TheAllTests/WorkspaceStoreTests.swift`（在 `testDeleteWorkspace` 后追加）

- [ ] **Step 1：添加三个失败测试**

在 `TheAllTests/WorkspaceStoreTests.swift` 第 34 行（`testDeleteWorkspace` 结尾 `}` 之后）插入：

```swift
// MARK: - Rename workspace

func testRenameWorkspace() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "old")
    let id = store.workspaces[0].id
    store.renameWorkspace(id: id, to: "new")
    XCTAssertEqual(store.workspaces[0].name, "new")
}

func testRenameWorkspace_emptyStringIgnored() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "keep")
    let id = store.workspaces[0].id
    store.renameWorkspace(id: id, to: "")
    XCTAssertEqual(store.workspaces[0].name, "keep")
}

func testRenameWorkspace_whitespaceIgnored() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "keep")
    let id = store.workspaces[0].id
    store.renameWorkspace(id: id, to: "   ")
    XCTAssertEqual(store.workspaces[0].name, "keep")
}

func testRenameWorkspace_trimsWhitespace() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "old")
    let id = store.workspaces[0].id
    store.renameWorkspace(id: id, to: "  trimmed  ")
    XCTAssertEqual(store.workspaces[0].name, "trimmed")
}

func testRenameWorkspace_unknownIdIsNoop() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "keep")
    store.renameWorkspace(id: UUID(), to: "nope")
    XCTAssertEqual(store.workspaces[0].name, "keep")
}
```

- [ ] **Step 2：运行测试，确认全部失败（方法不存在）**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace
```
Expected: 编译失败，错误 `value of type 'WorkspaceStore' has no member 'renameWorkspace'`

- [ ] **Step 3：实现最小代码**

在 `TheAll/Models/WorkspaceStore.swift` 第 40 行 `deleteWorkspace` 的闭合 `}` 之后、`select(id:)` 之前，插入：

```swift
    func renameWorkspace(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = wsIndex(id),
              workspaces[idx].name != trimmed else { return }
        workspaces[idx].name = trimmed
        save()
    }
```

- [ ] **Step 4：运行测试，确认全部通过**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace_emptyStringIgnored \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace_whitespaceIgnored \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace_trimsWhitespace \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameWorkspace_unknownIdIsNoop
```
Expected: 全部 PASS

- [ ] **Step 5：提交**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat(store): add renameWorkspace with trim + empty guard"
```

---

### Task 2：`renameTab`

**Files:**
- Modify: `TheAll/Models/WorkspaceStore.swift`
- Test: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 1：添加失败测试**

在 `TheAllTests/WorkspaceStoreTests.swift` 的 `testSelectTab` 测试之后（约第 68 行 `}` 之后）插入：

```swift
// MARK: - Rename tab

func testRenameTab() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    let tabId = store.workspaces[0].tabs[0].id
    store.renameTab(id: tabId, in: wsId, to: "custom")
    XCTAssertEqual(store.workspaces[0].tabs[0].title, "custom")
}

func testRenameTab_emptyIgnored() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    let tabId = store.workspaces[0].tabs[0].id
    let original = store.workspaces[0].tabs[0].title
    store.renameTab(id: tabId, in: wsId, to: "")
    store.renameTab(id: tabId, in: wsId, to: "   ")
    XCTAssertEqual(store.workspaces[0].tabs[0].title, original)
}

func testRenameTab_unknownIdsAreNoop() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    let original = store.workspaces[0].tabs[0].title
    store.renameTab(id: UUID(), in: wsId, to: "x")              // unknown tab
    store.renameTab(id: store.workspaces[0].tabs[0].id,
                    in: UUID(), to: "y")                         // unknown ws
    XCTAssertEqual(store.workspaces[0].tabs[0].title, original)
}
```

- [ ] **Step 2：运行测试，确认失败**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests/testRenameTab
```
Expected: 编译失败，`no member 'renameTab'`

- [ ] **Step 3：实现**

在 `TheAll/Models/WorkspaceStore.swift` 的 `selectTab(id:in:)` 方法结尾 `}` 之后（约第 82 行后）插入：

```swift
    func renameTab(id: UUID, in workspaceId: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(id, in: wsIdx),
              workspaces[wsIdx].tabs[tIdx].title != trimmed else { return }
        workspaces[wsIdx].tabs[tIdx].title = trimmed
        save()
    }
```

- [ ] **Step 4：运行测试，确认通过**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameTab \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameTab_emptyIgnored \
  -only-testing:TheAllTests/WorkspaceStoreTests/testRenameTab_unknownIdsAreNoop
```
Expected: 全部 PASS

- [ ] **Step 5：提交**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat(store): add renameTab with trim + empty guard"
```

---

### Task 3：`moveWorkspace`

**Files:**
- Modify: `TheAll/Models/WorkspaceStore.swift`
- Test: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 1：添加失败测试**

在 `testRenameWorkspace_unknownIdIsNoop` 后（Task 1 插入的最后一个测试后）追加：

```swift
// MARK: - Move workspace

func testMoveWorkspace_forward() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "a")
    store.createWorkspace(name: "b")
    store.createWorkspace(name: "c")
    // a, b, c → move index 0 (a) to destination 2 → b, a, c
    store.moveWorkspace(from: IndexSet([0]), to: 2)
    XCTAssertEqual(store.workspaces.map(\.name), ["b", "a", "c"])
}

func testMoveWorkspace_backward() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "a")
    store.createWorkspace(name: "b")
    store.createWorkspace(name: "c")
    // a, b, c → move index 2 (c) to destination 0 → c, a, b
    store.moveWorkspace(from: IndexSet([2]), to: 0)
    XCTAssertEqual(store.workspaces.map(\.name), ["c", "a", "b"])
}

func testMoveWorkspace_toSameSpotIsNoop() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "a")
    store.createWorkspace(name: "b")
    let idsBefore = store.workspaces.map(\.id)
    store.moveWorkspace(from: IndexSet([0]), to: 0)
    store.moveWorkspace(from: IndexSet([0]), to: 1)  // same position for single-element move
    XCTAssertEqual(store.workspaces.map(\.id), idsBefore)
}

func testMoveWorkspace_preservesSelectedId() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "a")
    store.createWorkspace(name: "b")
    store.createWorkspace(name: "c")
    let bId = store.workspaces[1].id
    store.select(id: bId)
    store.moveWorkspace(from: IndexSet([0]), to: 3)  // a → end
    XCTAssertEqual(store.selectedId, bId)
    XCTAssertEqual(store.workspaces.map(\.name), ["b", "c", "a"])
}
```

- [ ] **Step 2：运行测试，确认失败**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests/testMoveWorkspace_forward
```
Expected: 编译失败，`no member 'moveWorkspace'`

- [ ] **Step 3：实现**

在 `TheAll/Models/WorkspaceStore.swift` 的 `renameWorkspace` 方法后（Task 1 插入位置）追加：

```swift
    // MARK: - Reorder

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        let beforeIds = workspaces.map(\.id)
        workspaces.move(fromOffsets: source, toOffset: destination)
        guard workspaces.map(\.id) != beforeIds else { return }
        save()
    }
```

- [ ] **Step 4：运行测试，确认通过**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests/testMoveWorkspace_forward \
  -only-testing:TheAllTests/WorkspaceStoreTests/testMoveWorkspace_backward \
  -only-testing:TheAllTests/WorkspaceStoreTests/testMoveWorkspace_toSameSpotIsNoop \
  -only-testing:TheAllTests/WorkspaceStoreTests/testMoveWorkspace_preservesSelectedId
```
Expected: 全部 PASS

- [ ] **Step 5：提交**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat(store): add moveWorkspace for sidebar reorder"
```

---

### Task 4：`moveTab` + AppKit 便利 overload + 持久化 round-trip

**Files:**
- Modify: `TheAll/Models/WorkspaceStore.swift`
- Test: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 1：添加失败测试**

在 `testRenameTab_unknownIdsAreNoop` 后（Task 2 插入位置之后）追加：

```swift
// MARK: - Move tab

func testMoveTab_basic() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    _ = store.addTab(to: wsId)
    _ = store.addTab(to: wsId)
    // titles are "terminal 1", "terminal 2", "terminal 3"
    store.moveTab(from: IndexSet([0]), to: 3, in: wsId)
    XCTAssertEqual(store.workspaces[0].tabs.map(\.title),
                   ["terminal 2", "terminal 3", "terminal 1"])
}

func testMoveTab_preservesSelectedTabId() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    _ = store.addTab(to: wsId)
    _ = store.addTab(to: wsId)
    let firstId = store.workspaces[0].tabs[0].id
    store.selectTab(id: firstId, in: wsId)
    store.moveTab(from: IndexSet([0]), to: 3, in: wsId)  // first → end
    XCTAssertEqual(store.workspaces[0].selectedTabId, firstId)
    XCTAssertEqual(store.workspaces[0].tabs.last?.id, firstId)
}

func testMoveTab_unknownWorkspaceIsNoop() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    _ = store.addTab(to: wsId)
    let titlesBefore = store.workspaces[0].tabs.map(\.title)
    store.moveTab(from: IndexSet([0]), to: 2, in: UUID())
    XCTAssertEqual(store.workspaces[0].tabs.map(\.title), titlesBefore)
}

func testMoveTab_fromIndexToIndexOverload() {
    let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
    store.createWorkspace(name: "ws")
    let wsId = store.workspaces[0].id
    _ = store.addTab(to: wsId)
    _ = store.addTab(to: wsId)
    store.moveTab(fromIndex: 2, toIndex: 0, in: wsId)  // "terminal 3" → front
    XCTAssertEqual(store.workspaces[0].tabs.map(\.title),
                   ["terminal 3", "terminal 1", "terminal 2"])
}

func testMoveTab_persistenceRoundTrip() throws {
    let key = "test-movetab-\(UUID())"
    let store1 = WorkspaceStore(persistenceKey: key)
    store1.createWorkspace(name: "ws")
    let wsId = store1.workspaces[0].id
    _ = store1.addTab(to: wsId)
    _ = store1.addTab(to: wsId)
    store1.moveTab(from: IndexSet([0]), to: 3, in: wsId)
    let expectedTitles = store1.workspaces[0].tabs.map(\.title)

    let store2 = WorkspaceStore(persistenceKey: key)
    XCTAssertEqual(store2.workspaces[0].tabs.map(\.title), expectedTitles)

    UserDefaults.standard.removeObject(forKey: key)
}

func testMoveWorkspace_persistenceRoundTrip() throws {
    let key = "test-movews-\(UUID())"
    let store1 = WorkspaceStore(persistenceKey: key)
    store1.createWorkspace(name: "a")
    store1.createWorkspace(name: "b")
    store1.createWorkspace(name: "c")
    store1.moveWorkspace(from: IndexSet([0]), to: 3)
    let expected = store1.workspaces.map(\.name)

    let store2 = WorkspaceStore(persistenceKey: key)
    XCTAssertEqual(store2.workspaces.map(\.name), expected)

    UserDefaults.standard.removeObject(forKey: key)
}
```

- [ ] **Step 2：运行测试，确认失败**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests/testMoveTab_basic
```
Expected: 编译失败，`no member 'moveTab'`

- [ ] **Step 3：实现 + AppKit overload**

在 `TheAll/Models/WorkspaceStore.swift` 的 `moveWorkspace` 方法后追加：

```swift
    func moveTab(from source: IndexSet, to destination: Int, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId) else { return }
        let beforeIds = workspaces[wsIdx].tabs.map(\.id)
        workspaces[wsIdx].tabs.move(fromOffsets: source, toOffset: destination)
        guard workspaces[wsIdx].tabs.map(\.id) != beforeIds else { return }
        save()
    }

    /// AppKit 便利 overload。`toIndex` 使用插入位置语义（0…count）——和 SwiftUI onMove
    /// 的 destination 一致；调用方（`TabBarView.performDragOperation`）需自行计算
    /// "鼠标落点对应的 tab 之间的缝隙索引"。
    func moveTab(fromIndex: Int, toIndex: Int, in workspaceId: UUID) {
        moveTab(from: IndexSet([fromIndex]), to: toIndex, in: workspaceId)
    }
```

- [ ] **Step 4：运行全部 store 测试，确认通过**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/WorkspaceStoreTests
```
Expected: 所有测试（新加 + 旧的）全部 PASS

- [ ] **Step 5：提交**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat(store): add moveTab + AppKit overload, persistence roundtrip tests"
```

---

## Phase 2 — Sidebar UI（Task 5-9）

### Task 5：新建 `Sidebar/DragTypes.swift`

**Files:**
- Create: `TheAll/Sidebar/DragTypes.swift`

- [ ] **Step 1：创建文件**

写入 `TheAll/Sidebar/DragTypes.swift`：

```swift
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar 拖拽载荷。承载被拖拽 workspace 的 UUID；
/// drop destination 据此从 store 中查找源索引并调用 moveWorkspace。
struct WorkspaceDragItem: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .theAllWorkspace)
    }
}

extension UTType {
    /// theall 内部拖拽类型。不跨进程、不写剪贴板；仅用于在 Sidebar 内区分自己的 draggable。
    static let theAllWorkspace = UTType(exportedAs: "com.theall.workspace")
}
```

- [ ] **Step 2：将文件加入 Xcode 工程**

`project.yml` 使用 `xcodegen`，该项目配置通常自动包含 `TheAll/**/*.swift`。验证：

Run:
```bash
xcodegen generate
```
Expected: `theall project regenerated`（若文件未自动纳入，需检查 `project.yml` 的 `sources` 配置，联系人工确认）

- [ ] **Step 3：构建验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4：提交**

```bash
git add TheAll/Sidebar/DragTypes.swift TheAll.xcodeproj
git commit -m "feat(sidebar): add WorkspaceDragItem + UTType.theAllWorkspace"
```

---

### Task 6：`WorkspaceRowView` 支持 inline rename

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceRowView.swift`

- [ ] **Step 1：改写 `WorkspaceRowView`，增加 rename 参数**

**完整**替换 `TheAll/Sidebar/WorkspaceRowView.swift` 内容：

```swift
import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let metadata: WorkspaceMetadata
    let isSelected: Bool
    let theme: AppTheme

    // Rename 相关——由 SidebarView 通过 binding 注入
    let isRenaming: Bool
    @Binding var draft: String
    var focusBinding: FocusState<Bool>.Binding
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DT.Space.xxs) {
            HStack(spacing: DT.Space.xs) {
                if isRenaming {
                    renameField
                } else {
                    Text(workspace.name)
                        .font(Font(isSelected ? DT.Font.bodyB : DT.Font.body))
                        .foregroundColor(Color(isSelected ? theme.textPrimary : theme.textSecondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let pr = metadata.prStatus {
                    prBadge(pr)
                }
            }

            if metadata.gitBranch != nil || !metadata.listeningPorts.isEmpty {
                HStack(spacing: DT.Space.xs) {
                    if let branch = metadata.gitBranch {
                        branchLabel(branch)
                    }
                    if !metadata.listeningPorts.isEmpty {
                        portList(metadata.listeningPorts)
                    }
                }
            }

            if let note = metadata.latestNotification {
                Text(note)
                    .font(Font(DT.Font.micro))
                    .foregroundColor(Color(theme.accent))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.row, style: .continuous)
                .fill(isSelected ? Color(theme.borderStrong) : Color.clear)
        )
        .padding(.horizontal, DT.Space.sm)
        .contentShape(Rectangle())
    }

    private var renameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Font(isSelected ? DT.Font.bodyB : DT.Font.body))
            .foregroundColor(Color(theme.textPrimary))
            .focused(focusBinding)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
    }

    private func branchLabel(_ branch: String) -> some View {
        HStack(spacing: 2) {
            Text("⎇")
                .font(Font(DT.Font.micro))
            Text(branch)
                .font(Font(DT.Font.mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(Color(theme.textTertiary))
    }

    private func portList(_ ports: [Int]) -> some View {
        HStack(spacing: DT.Space.xs) {
            ForEach(ports.prefix(3), id: \.self) { port in
                Text(":\(port)")
                    .font(Font(DT.Font.mono))
                    .foregroundColor(Color(theme.textTertiary))
            }
        }
    }

    private func prBadge(_ status: String) -> some View {
        Text(status.uppercased())
            .font(Font(DT.Font.micro))
            .foregroundColor(Color(theme.textTertiary))
    }
}
```

- [ ] **Step 2：构建（SidebarView 会因签名变化而编译失败，这是预期的）**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD FAILED，错误定位在 `SidebarView.swift` 对 `WorkspaceRowView` 的调用（缺少新参数）—— 这是下一 Task 要修的。

- [ ] **Step 3：先不提交，进入 Task 7 一起修**

不运行 `git commit`，进入 Task 7（SidebarView 改造）后再一起提交，避免中间状态 broken build。

---

### Task 7：`SidebarView` 接入 rename + delete alert

**Files:**
- Modify: `TheAll/Sidebar/SidebarView.swift`

- [ ] **Step 1：完整替换 `TheAll/Sidebar/SidebarView.swift` 内容**

```swift
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme
    @State private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    @State private var refreshers: [UUID: MetadataRefresher] = [:]
    @State private var isCreating = false
    @State private var newWorkspaceName = ""
    @FocusState private var newFieldFocused: Bool

    // Rename
    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFocused: Bool

    // Delete confirmation
    @State private var workspaceToDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            workspaceList
            footer
        }
        .frame(width: DT.Layout.sidebarWidth)
        .background(Color(theme.sidebar))
        .onAppear { startRefreshers() }
        .onChange(of: store.workspaces) { _, _ in startRefreshers() }
        .onReceive(NotificationCenter.default.publisher(for: .theAllBeginCreateWorkspace)) { _ in
            beginCreate()
        }
        .alert("Delete workspace?",
               isPresented: Binding(
                   get: { workspaceToDelete != nil },
                   set: { if !$0 { workspaceToDelete = nil } })) {
            Button("Cancel", role: .cancel) { workspaceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = workspaceToDelete {
                    store.deleteWorkspace(id: id)
                }
                workspaceToDelete = nil
            }
        } message: {
            if let id = workspaceToDelete,
               let ws = store.workspaces.first(where: { $0.id == id }) {
                Text("「\(ws.name)」及其所有 tab 将被删除，此操作不可撤销。")
            }
        }
        .onChange(of: renameFocused) { oldValue, newValue in
            // 失焦即 commit（除非已手动取消使 renamingId == nil）
            if oldValue && !newValue && renamingId != nil {
                commitRename()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DT.Space.sm) {
            Text("theall")
                .font(Font(DT.Font.title))
                .foregroundColor(Color(theme.textPrimary))
            Spacer()
            Text("\(store.workspaces.count)")
                .font(Font(DT.Font.mono))
                .foregroundColor(Color(theme.textTertiary))
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.md)
    }

    // MARK: - List

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.workspaces) { ws in
                    WorkspaceRowView(
                        workspace: ws,
                        metadata: metadataMap[ws.id] ?? WorkspaceMetadata(),
                        isSelected: store.selectedId == ws.id,
                        theme: theme,
                        isRenaming: renamingId == ws.id,
                        draft: $renameDraft,
                        focusBinding: $renameFocused,
                        onCommit: { commitRename() },
                        onCancel: { cancelRename() }
                    )
                    .onTapGesture {
                        // Rename 状态下点同行 row 不切换；点其他行按正常 select
                        if renamingId != nil { return }
                        store.select(id: ws.id)
                    }
                    .contextMenu {
                        Button("Rename") { beginRename(ws.id) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            workspaceToDelete = ws.id
                        }
                    }
                }
            }
            .padding(.vertical, DT.Space.xs)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Group {
            if isCreating {
                creationField
            } else {
                createButton
            }
        }
    }

    private var createButton: some View {
        Button {
            beginCreate()
        } label: {
            HStack(spacing: DT.Space.sm) {
                Text("+")
                    .font(Font(DT.Font.body))
                Text("New workspace")
                    .font(Font(DT.Font.small))
                Spacer()
                Text("⌘N")
                    .font(Font(DT.Font.mono))
                    .foregroundColor(Color(theme.textTertiary))
            }
            .foregroundColor(Color(theme.textSecondary))
            .padding(.horizontal, DT.Space.md)
            .padding(.vertical, DT.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var creationField: some View {
        HStack(spacing: DT.Space.sm) {
            Text("›")
                .font(Font(DT.Font.body))
                .foregroundColor(Color(theme.accent))
            TextField("workspace name", text: $newWorkspaceName)
                .textFieldStyle(.plain)
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textPrimary))
                .focused($newFieldFocused)
                .onSubmit { commitCreate() }
                .onExitCommand { cancelCreate() }
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.md)
    }

    // MARK: - Actions

    func beginCreate() {
        isCreating = true
        newWorkspaceName = ""
        DispatchQueue.main.async { newFieldFocused = true }
    }

    private func commitCreate() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            store.createWorkspace(name: name)
        }
        cancelCreate()
    }

    private func cancelCreate() {
        isCreating = false
        newWorkspaceName = ""
        newFieldFocused = false
    }

    // MARK: - Rename

    private func beginRename(_ id: UUID) {
        guard let ws = store.workspaces.first(where: { $0.id == id }) else { return }
        renamingId = id
        renameDraft = ws.name
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let id = renamingId {
            store.renameWorkspace(id: id, to: renameDraft)
        }
        renamingId = nil
        renameDraft = ""
    }

    private func cancelRename() {
        renamingId = nil
        renameDraft = ""
        renameFocused = false
    }

    // MARK: - Refreshers

    private func startRefreshers() {
        let activeIds = Set(store.workspaces.map { $0.id })
        for id in refreshers.keys where !activeIds.contains(id) {
            refreshers[id]?.stop()
            refreshers.removeValue(forKey: id)
            metadataMap.removeValue(forKey: id)
        }
        for ws in store.workspaces where refreshers[ws.id] == nil {
            let meta = WorkspaceMetadata()
            metadataMap[ws.id] = meta
            let refresher = MetadataRefresher(metadata: meta, workingDirectory: NSHomeDirectory())
            refreshers[ws.id] = refresher
            refresher.start()
        }
    }
}
```

- [ ] **Step 2：构建验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3：启动 app 做手动验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
open /tmp/theall-build/Build/Products/Debug/TheAll.app
```

手动验证：
1. 右键 workspace row → 菜单显示 "Rename" + 分隔线 + "Delete"
2. 点 Rename → row 标题变为可编辑 TextField，自动获焦
3. 输入新名 → 按 Enter → 名字更新
4. 再点 Rename → 输入内容 → 按 Esc → 名字回退
5. 再点 Rename → 输入内容 → 点别的 row → 名字自动 commit（失焦提交）
6. 点 Delete → 弹 alert "Delete workspace?" → Cancel → 不删 / Delete → 删
7. 重启 app → 改名持久化

- [ ] **Step 4：提交（合并 Task 6 的改动）**

```bash
git add TheAll/Sidebar/SidebarView.swift TheAll/Sidebar/WorkspaceRowView.swift
git commit -m "feat(sidebar): add rename via context menu + delete confirmation"
```

---

### Task 8：Sidebar 拖拽排序

**Files:**
- Modify: `TheAll/Sidebar/SidebarView.swift`

- [ ] **Step 1：在 `SidebarView` 中添加 dropZone helper 与 hover state**

在 `SidebarView` 的 `@State` 声明区（`@State private var workspaceToDelete: UUID?` 后）追加：

```swift
    @State private var hoveredDropIndex: Int?
```

- [ ] **Step 2：重写 `workspaceList`，加入 drop zones + draggable**

将 `workspaceList` 整块替换为：

```swift
    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                dropZone(before: 0)
                ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, ws in
                    WorkspaceRowView(
                        workspace: ws,
                        metadata: metadataMap[ws.id] ?? WorkspaceMetadata(),
                        isSelected: store.selectedId == ws.id,
                        theme: theme,
                        isRenaming: renamingId == ws.id,
                        draft: $renameDraft,
                        focusBinding: $renameFocused,
                        onCommit: { commitRename() },
                        onCancel: { cancelRename() }
                    )
                    .onTapGesture {
                        if renamingId != nil { return }
                        store.select(id: ws.id)
                    }
                    .contextMenu {
                        Button("Rename") { beginRename(ws.id) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            workspaceToDelete = ws.id
                        }
                    }
                    .draggable(WorkspaceDragItem(id: ws.id))
                    dropZone(before: index + 1)
                }
            }
            .padding(.vertical, DT.Space.xs)
        }
    }

    @ViewBuilder
    private func dropZone(before destination: Int) -> some View {
        Rectangle()
            .fill(hoveredDropIndex == destination ? Color(theme.accent) : Color.clear)
            .frame(height: 2)
            .padding(.horizontal, DT.Space.sm)
            .dropDestination(for: WorkspaceDragItem.self) { items, _ in
                guard let item = items.first,
                      let from = store.workspaces.firstIndex(where: { $0.id == item.id })
                else { return false }
                store.moveWorkspace(from: IndexSet([from]), to: destination)
                return true
            } isTargeted: { hovering in
                if hovering {
                    hoveredDropIndex = destination
                } else if hoveredDropIndex == destination {
                    hoveredDropIndex = nil
                }
            }
    }
```

- [ ] **Step 3：构建验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4：启动 app 做手动验证**

Run: `open /tmp/theall-build/Build/Products/Debug/TheAll.app`（上次 Task 7 的构建路径）

手动验证（需要至少 3 个 workspace，⌘N 新建）：
1. 鼠标按住一个 row → 拖动
2. 移动到其他 row 之间 → 目标缝隙高亮 2pt accent 色线
3. 松手 → workspace 顺序更新
4. 重启 app → 顺序持久化
5. 拖到同一位置（上或下的相邻 zone）→ 顺序不变，无视觉异常
6. 选中项被拖动后仍保持选中

- [ ] **Step 5：提交**

```bash
git add TheAll/Sidebar/SidebarView.swift
git commit -m "feat(sidebar): drag-and-drop workspace reorder"
```

---

### Task 9：Sidebar 整体回归验证

- [ ] **Step 1：跑单元测试，确保未破坏已有行为**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```
Expected: 全部 PASS

- [ ] **Step 2：手动回归清单（可直接对照 spec § 7.2）**

启动 app，逐项检查：
- [ ] 新建 workspace（⌘N / + 按钮）仍工作
- [ ] 选中 workspace 切换正确
- [ ] 右键 → Rename 正常
- [ ] 右键 → Delete 弹 alert，Cancel/Delete 均正确
- [ ] 拖拽重排 + drop indicator 显示
- [ ] 重启 app 名字 + 顺序均保留
- [ ] 切换主题，重排时 drop indicator 颜色随主题变

- [ ] **Step 3：若发现问题，修复后补测，否则进入 Phase 3**

---

## Phase 3 — TabBar UI（Task 10-15）

### Task 10：新建 `TabContent/PasteboardTypes.swift`

**Files:**
- Create: `TheAll/TabContent/PasteboardTypes.swift`

- [ ] **Step 1：创建文件**

写入 `TheAll/TabContent/PasteboardTypes.swift`：

```swift
import AppKit

extension NSPasteboard.PasteboardType {
    /// theall Tab 拖拽类型。仅用于 TabBarView 自身内部重排——不跨进程、不支持外部拖入。
    static let theAllTab = NSPasteboard.PasteboardType("com.theall.tab")
}
```

- [ ] **Step 2：生成 Xcode 工程 + 构建**

Run:
```bash
xcodegen generate && xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3：提交**

```bash
git add TheAll/TabContent/PasteboardTypes.swift TheAll.xcodeproj
git commit -m "feat(tabs): add theAllTab pasteboard type"
```

---

### Task 11：`TabBarView` 新增回调声明 + TabItemView `tabId` 暴露

**Files:**
- Modify: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 1：在 `TabBarView` 的回调声明处（第 7-9 行）追加**

把 `TheAll/TabContent/TabBarView.swift` 第 7-9 行：

```swift
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
```

替换为：

```swift
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    /// (fromIndex, toIndex) 采用 insertion-index 语义（0…count），
    /// 与 `WorkspaceStore.moveTab(fromIndex:toIndex:in:)` 对齐
    var onReorderTab: ((Int, Int) -> Void)?
    /// 若 tab 总数 ≤ 1，TabItemView 禁用 × 按钮与菜单 Close 项
    private var canClose: Bool { tabs.count > 1 }
```

- [ ] **Step 2：`TabItemView` 暴露 tabId 字段（供拖拽 + rename 使用）**

在 `TheAll/TabContent/TabBarView.swift` 约第 121 行 `private final class TabItemView: NSView {` 内，把原有：

```swift
    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?
```

替换为：

```swift
    let tabId: UUID
    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?
    var onRename: ((String) -> Void)?
    var canClose: Bool = true {
        didSet { closeBtn.isEnabled = canClose }
    }
```

在 `TabItemView.init(tab:isSelected:theme:)` 方法体内 `self.isSelected = isSelected` 那行上面加：

```swift
        self.tabId = tab.id
```

- [ ] **Step 3：在 `TabBarView.rebuildTabItems()` 中传入 canClose + 挂 onRename**

把 `rebuildTabItems()` 方法（第 78-87 行）替换为：

```swift
    private func rebuildTabItems() {
        tabsContainer.subviews.forEach { $0.removeFromSuperview() }
        let canCloseNow = canClose
        for tab in tabs {
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId, theme: theme)
            item.canClose = canCloseNow
            item.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            item.onClose  = { [weak self] in self?.onCloseTab?(tab.id) }
            item.onRename = { [weak self] newTitle in self?.onRenameTab?(tab.id, newTitle) }
            tabsContainer.addSubview(item)
        }
        layoutTabItems()
    }
```

- [ ] **Step 4：构建验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug
```
Expected: BUILD SUCCEEDED（功能性改动在下一 task，本 task 只是骨架）

- [ ] **Step 5：暂不提交，进入 Task 12**

（Rename UI 和右键菜单实现后统一提交）

---

### Task 12：`TabItemView` 右键菜单 + inline rename NSTextField

**Files:**
- Modify: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 1：在 `TabItemView` 中声明 renameField + action selectors**

在 `TabItemView` 的 `private let closeBtn = NSButton()` 之后追加：

```swift
    private let renameField = NSTextField()
    private var originalTitle: String = ""
    private var isRenaming: Bool = false
```

并让 `TabItemView` 遵循 `NSTextFieldDelegate`。把类声明改为：

```swift
private final class TabItemView: NSView, NSTextFieldDelegate {
```

- [ ] **Step 2：在 `setup()` 中初始化 renameField**

把 `setup()` 方法（约第 142-165 行）结尾改为：

```swift
    private func setup() {
        wantsLayer = true

        pillView.wantsLayer = true
        pillView.layer?.masksToBounds = true
        addSubview(pillView)

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = DT.Font.small
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeBtn.isBordered = false
        closeBtn.title = "×"
        closeBtn.font = DT.Font.small
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.isHidden = true
        addSubview(closeBtn)

        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.font = DT.Font.small
        renameField.focusRingType = .none
        renameField.delegate = self
        renameField.isHidden = true
        addSubview(renameField)
    }
```

- [ ] **Step 3：layout 中给 renameField 同步 frame**

把 `layout()` 方法（约第 176-191 行）替换为：

```swift
    override func layout() {
        super.layout()
        let h = bounds.height
        let vInset = TabBarView.pillInset
        let pillH = h - vInset * 2
        pillView.frame = NSRect(x: 0, y: vInset, width: bounds.width, height: pillH)
        pillView.layer?.cornerRadius = TabBarView.pillRadius

        let closeW: CGFloat = 16
        let margin: CGFloat = 10
        closeBtn.frame = NSRect(x: bounds.width - closeW - margin,
                                y: (h - 14) / 2, width: closeW, height: 14)
        let textH = ceil(titleLabel.intrinsicContentSize.height)
        let textFrame = NSRect(x: margin, y: (h - textH) / 2,
                               width: bounds.width - closeW - margin * 2, height: textH)
        titleLabel.frame = textFrame
        renameField.frame = textFrame
    }
```

- [ ] **Step 4：添加 rightMouseDown（右键菜单）**

在 `TabItemView` 的 `override func mouseDown(with event: NSEvent) { onSelect?() }` 下面追加：

```swift
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename",
                                    action: #selector(beginRenameAction),
                                    keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close",
                                   action: #selector(closeTapped),
                                   keyEquivalent: "")
        closeItem.target = self
        closeItem.isEnabled = canClose
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
```

- [ ] **Step 5：添加 rename 生命周期方法**

在 `override func mouseDown...` 之前（即 `acceptsFirstMouse` 之后）追加：

```swift
    // MARK: - Rename

    @objc private func beginRenameAction() {
        originalTitle = titleLabel.stringValue
        renameField.stringValue = originalTitle
        titleLabel.isHidden = true
        renameField.isHidden = false
        isRenaming = true
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    private func finishRenameUI() {
        renameField.isHidden = true
        titleLabel.isHidden = false
        isRenaming = false
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newTitle = renameField.stringValue
        finishRenameUI()
        onRename?(newTitle)
    }

    private func cancelRename() {
        guard isRenaming else { return }
        // 恢复原始显示，不触发回调
        renameField.stringValue = originalTitle
        finishRenameUI()
    }

    // NSTextFieldDelegate —— 回车 / 失焦均触发 commit
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车 / 失焦都走这里；Esc 的情况已经在 doCommandBy 里被处理并提前 finish 了
        commitRename()
    }
```

- [ ] **Step 6：构建验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 7：启动 app 手动验证 rename**

Run: `open /tmp/theall-build/Build/Products/Debug/TheAll.app`

验证：
1. 右键一个 tab → 菜单 "Rename" + 分隔 + "Close"；只有 1 个 tab 时 Close 置灰
2. 点 Rename → tab 标题变 TextField 获焦 + 全选
3. 改名 + 回车 → 新名字显示（但还未写回 store —— 下一任务）
4. Esc → 恢复原名

_注：此时 onRename 回调尚未 wire 到 store（TabContentView 接入在 Task 15），因此回车提交后改名在 UI 层可见但切换 tab 后会还原——这是预期的中间状态。_

- [ ] **Step 8：暂不提交，继续 Task 13（拖拽源/目标）**

---

### Task 13：TabItemView 作为 NSDraggingSource + TabBarView 作为 Destination

**Files:**
- Modify: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 1：在 `TabBarView.setup()` 中注册拖拽类型**

把 `setup()` 结尾 `addSubview(addButton)` 之后追加一行：

```swift
        registerForDraggedTypes([.theAllTab])
```

- [ ] **Step 2：添加 drop indicator NSView + 状态**

在 `TabBarView` 的 `private let addButton = NSButton()` 之后追加：

```swift
    /// 1pt 宽度的 drop 插入提示线；仅在拖拽时显示。
    private let dropIndicator = NSView()
```

在 `setup()` 的 `addSubview(addButton)` **前**插入：

```swift
        dropIndicator.wantsLayer = true
        dropIndicator.isHidden = true
        stripContainer.addSubview(dropIndicator)
```

- [ ] **Step 3：添加计算插入点 + 显示/隐藏 indicator 的 helper**

在 `TabBarView` 的 `@objc private func addTapped() { onAddTab?() }` 之前追加：

```swift
    // MARK: - Drag & drop

    /// 根据鼠标在 TabBarView 坐标系的横坐标，计算应插入到第几个 tab 之前（0…tabs.count）。
    /// 规则：比较 x 与每个 tab 的中线；小于中线则插到该 tab 前面。
    private func insertionIndex(at pointInSelf: NSPoint) -> Int {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        guard !items.isEmpty else { return 0 }
        // 把 x 转换到 tabsContainer 坐标系
        let pointInContainer = tabsContainer.convert(pointInSelf, from: self)
        for (i, item) in items.enumerated() {
            let midX = item.frame.midX
            if pointInContainer.x < midX { return i }
        }
        return items.count
    }

    private func showDropIndicator(before index: Int) {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let x: CGFloat
        if items.isEmpty {
            x = 0
        } else if index >= items.count {
            x = items.last!.frame.maxX
        } else {
            x = items[index].frame.minX
        }
        // 把 x 从 tabsContainer 坐标转到 stripContainer 坐标
        let xInStrip = tabsContainer.convert(NSPoint(x: x, y: 0), to: stripContainer).x
        let h = stripContainer.bounds.height - TabBarView.pillInset * 2
        dropIndicator.frame = NSRect(
            x: max(0, xInStrip - 0.5), y: TabBarView.pillInset,
            width: 1, height: h)
        dropIndicator.layer?.backgroundColor = theme.accent.cgColor
        dropIndicator.isHidden = false
    }

    private func hideDropIndicator() {
        dropIndicator.isHidden = true
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.theAllTab) == true else {
            return []
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pointInSelf)
        showDropIndicator(before: idx)
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
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let toIndex = insertionIndex(at: pointInSelf)
        onReorderTab?(fromIndex, toIndex)
        return true
    }
```

- [ ] **Step 4：把 `TabItemView` 变成 NSDraggingSource**

把 `TabItemView` 的类声明改为：

```swift
private final class TabItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
```

- [ ] **Step 5：替换 `TabItemView.mouseDown` 并添加 `mouseDragged` / 拖拽相关方法**

把原 `override func mouseDown(with event: NSEvent) { onSelect?() }` 一行替换为：

```swift
    private var mouseDownLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Rename 中不启动拖拽
        if isRenaming { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        guard (dx * dx + dy * dy) > 16 else { return }  // 4pt 阈值

        let pbItem = NSPasteboardItem()
        pbItem.setString(tabId.uuidString, forType: .theAllTab)

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        let snapshot = snapshotForDragging()
        draggingItem.setDraggingFrame(bounds, contents: snapshot)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotForDragging() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }
```

- [ ] **Step 6：applyTheme 时同步 dropIndicator 颜色**

把 `TabBarView.applyTheme(_:)`（约第 105-114 行）替换为：

```swift
    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.canvas.cgColor
        stripContainer.layer?.backgroundColor = theme.sidebar.cgColor
        addButton.contentTintColor = theme.textTertiary
        dropIndicator.layer?.backgroundColor = theme.accent.cgColor
        tabsContainer.subviews
            .compactMap { $0 as? TabItemView }
            .forEach { $0.applyTheme(theme) }
        needsDisplay = true
    }
```

- [ ] **Step 7：构建**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 8：暂不提交，进入 Task 14（TabContentView 接入回调）**

---

### Task 14：`TabContentView` 接入 rename/reorder/close 确认

**Files:**
- Modify: `TheAll/TabContent/TabContentView.swift`

- [ ] **Step 1：替换 `setup()` 中的 `tabBar.onCloseTab` 部分并添加 rename/reorder wiring**

找到 `TheAll/TabContent/TabContentView.swift` 第 53-67 行的回调注册块，把：

```swift
        tabBar.onSelectTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.selectTab(id: tabId, in: wsId)
            self.reloadFromStore()
        }
        tabBar.onAddTab = { [weak self] in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.addTab(to: wsId)
            self.reloadFromStore()
        }
        tabBar.onCloseTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.removeTab(id: tabId, from: wsId)
            self.reloadFromStore()
        }
```

替换为：

```swift
        tabBar.onSelectTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.selectTab(id: tabId, in: wsId)
            self.reloadFromStore()
        }
        tabBar.onAddTab = { [weak self] in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.addTab(to: wsId)
            self.reloadFromStore()
        }
        tabBar.onCloseTab = { [weak self] tabId in
            self?.confirmCloseTab(tabId)
        }
        tabBar.onRenameTab = { [weak self] tabId, newTitle in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.renameTab(id: tabId, in: wsId, to: newTitle)
            self.reloadFromStore()
        }
        tabBar.onReorderTab = { [weak self] fromIndex, toIndex in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.moveTab(fromIndex: fromIndex, toIndex: toIndex, in: wsId)
            self.reloadFromStore()
        }
```

- [ ] **Step 2：添加 `confirmCloseTab` 方法**

在 `TabContentView.swift` 的 `private func addNewTab()` 之前（约第 262 行附近）插入：

```swift
    // MARK: - Close confirmation

    private func confirmCloseTab(_ tabId: UUID) {
        guard let window,
              let wsId = store?.selectedId,
              let ws = store?.workspaces.first(where: { $0.id == wsId }),
              let tab = ws.tabs.first(where: { $0.id == tabId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Close tab?"
        alert.informativeText = "「\(tab.title)」中的所有终端进程将被终止。"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store?.removeTab(id: tabId, from: wsId)
            self.reloadFromStore()
        }
    }
```

- [ ] **Step 3：构建**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4：启动 app，手动全流程测试**

Run: `open /tmp/theall-build/Build/Products/Debug/TheAll.app`

验证：
1. 新建几个 tab（⌘T）
2. 右键 tab → Rename → 改名 → 回车 → 名字落库
3. 切换 tab 再切回，名字保留（说明已 persist）
4. 重启 app，名字保留
5. 右键 tab → Close → 弹 sheet → Cancel / Close 行为正确
6. 点 × 按钮 → 同样弹 sheet
7. 只剩 1 tab 时：× 按钮 isEnabled = false（视觉需保留原颜色，disabled 即可；若需隐藏见下）、右键菜单 Close 禁用
8. 多个 tab 时，拖动一个 tab 横向 → 出现 1pt accent 竖线 drop indicator → 松手后顺序更新
9. 拖动 tab 后，pane 内容（split 终端、焦点）不闪烁
10. 重启 app，tab 顺序保留

- [ ] **Step 5：提交（汇总 Task 11-14 的全部改动）**

```bash
git add TheAll/TabContent/TabBarView.swift TheAll/TabContent/TabContentView.swift
git commit -m "feat(tabs): add rename context menu, close confirmation, drag reorder"
```

---

### Task 15：Tab 数仅 1 时 × 按钮隐藏（体验优化）

**Files:**
- Modify: `TheAll/TabContent/TabBarView.swift`

可选：当前 Task 12 让 close 按钮变为 `isEnabled = false`；Terminal.app 的做法是直接隐藏。用户体验一致性：隐藏更干净。

- [ ] **Step 1：在 `TabItemView` 的 `canClose` didSet 中同步 closeBtn.isHidden**

把 Task 11 写的：

```swift
    var canClose: Bool = true {
        didSet { closeBtn.isEnabled = canClose }
    }
```

替换为：

```swift
    var canClose: Bool = true {
        didSet {
            closeBtn.isEnabled = canClose
            if !canClose { closeBtn.isHidden = true }
            // hover 时由 mouseEntered 决定是否显示；非 hover 状态不变
        }
    }
```

同时，把 `TabItemView.mouseEntered` 内的：

```swift
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        closeBtn.isHidden = false
        updateStyle()
    }
```

替换为：

```swift
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        closeBtn.isHidden = !canClose   // 唯一的 tab 不显示关闭按钮
        updateStyle()
    }
```

- [ ] **Step 2：构建 + 验证**

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
open /tmp/theall-build/Build/Products/Debug/TheAll.app
```

验证：
1. 只有 1 个 tab 时 hover，× 按钮不显示
2. 添加第二个 tab，hover 两个 tab 时 × 都显示
3. 关掉一个后只剩 1 个，hover 时 × 又隐藏

- [ ] **Step 3：提交**

```bash
git add TheAll/TabContent/TabBarView.swift
git commit -m "feat(tabs): hide close button when only one tab remains"
```

---

## Phase 4 — 文档与最终验收（Task 16-17）

### Task 16：更新 `docs/conventions.md` 与 `CLAUDE.md`

**Files:**
- Modify: `docs/conventions.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1：在 `docs/conventions.md` 中新增规范条目**

打开 `docs/conventions.md`，找到讲解「状态修改必须走 WorkspaceStore」的小节（grep `"通过 WorkspaceStore"`）。在该小节末尾追加一段：

```markdown
## Rename / Reorder 专用规范

所有 rename 和 reorder 操作必须调用 `WorkspaceStore` 的专用方法，UI 层不允许直接修改 `workspaces` 数组或 `Workspace.tabs` 字段：

- `renameWorkspace(id:to:)` / `renameTab(id:in:to:)`：内部做 trim + empty guard + 幂等比较
- `moveWorkspace(from:to:)` / `moveTab(from:to:in:)`：`(IndexSet, Int)` 签名对齐 SwiftUI `onMove`
- `moveTab(fromIndex:toIndex:in:)`：AppKit 拖拽便利 overload，destination 用 insertion-index 语义

不引入 `order: Int` 字段——顺序完全靠数组索引 + JSON 持久化。
```

_若 conventions.md 结构与此处假设不一致，请找到合适位置插入同等内容即可。_

- [ ] **Step 2：在 `CLAUDE.md` 的 Common Tasks 表中追加一行**

打开 `CLAUDE.md`，找到 `## Common Tasks` 下的 Markdown 表格。在表格末尾追加一行：

```markdown
| 侧边栏/Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceRowView.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |
```

- [ ] **Step 3：提交**

```bash
git add docs/conventions.md CLAUDE.md
git commit -m "docs: document rename/reorder conventions + common tasks entry"
```

---

### Task 17：完整回归 + 主题校验

- [ ] **Step 1：跑全部单元测试**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```
Expected: 全部 PASS（新增 14+ 测试 + 原有测试）

- [ ] **Step 2：grep 检查无硬编码颜色**

使用 Grep 工具在所有本次改动/新增文件中扫描：

```
pattern: Color\(red:|Color\(\.sRGB|NSColor\(red:|NSColor\(srgbRed:|NSColor\(white:|#[0-9A-Fa-f]{6}
path: TheAll/Sidebar
```

```
pattern: Color\(red:|Color\(\.sRGB|NSColor\(red:|NSColor\(srgbRed:|NSColor\(white:
path: TheAll/TabContent
```

Expected: 无命中；如有命中，必须替换为 `AppTheme` 或 `DT` token（conventions.md 第 1 条硬约束）

- [ ] **Step 3：全量手测清单（对照 spec § 7.2）**

启动 app：

Run:
```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug -derivedDataPath /tmp/theall-build
open /tmp/theall-build/Build/Products/Debug/TheAll.app
```

**Sidebar 清单：**
- [ ] 右键 row → Rename → TextField 获焦
- [ ] 输入新名 → Enter 生效
- [ ] 输入 → Esc 取消
- [ ] 空输入 Enter → 回退原值
- [ ] 失焦自动提交
- [ ] 右键 Delete → alert Cancel/Delete
- [ ] 拖拽 row 上下 → drop zone 高亮 + 重排
- [ ] 重启 app：名字 + 顺序均保留
- [ ] 选中项跟随移动

**TabBar 清单：**
- [ ] 右键 tab → Rename + Close 出现
- [ ] Rename inline 编辑、回车 / 失焦 commit、Esc 取消
- [ ] 空输入不覆盖
- [ ] × 按钮 + 右键 Close 都弹 sheet
- [ ] sheet Cancel 不关 / Close 真关
- [ ] 只剩 1 tab：× 隐藏、菜单 Close 禁用
- [ ] 拖拽 tab → drop indicator 竖线 → reorder
- [ ] Reorder 后当前 tab 的 split 终端 + 焦点保留，无闪烁
- [ ] 重启 app tab 顺序保留

**主题校验：**
- [ ] 切换到浅色 / 深色主题
- [ ] drop indicator、sheet、TextField、右键菜单配色均随主题变
- [ ] Grep 新加/改动的代码文件无 `Color(red:` / `Color(.` / `NSColor(red:` / `NSColor(srgbRed:` 等硬编码

- [ ] **Step 4：若一切通过，打 final commit（如需）**

若手测过程中有小 fix，每个 fix 单独 commit。若无改动则跳过此步。

---

## Self-Review Checklist

**Spec 覆盖检查**：
- spec § 3 数据层 → Task 1-4 ✅
- spec § 4.2 右键菜单 → Task 7 ✅
- spec § 4.3 Rename UI → Task 6 + Task 7 ✅
- spec § 4.4 Delete alert → Task 7 ✅
- spec § 4.5 拖拽 → Task 5 + Task 8 ✅
- spec § 5.2 TabBar 新回调 → Task 11 ✅
- spec § 5.3 右键菜单 → Task 12 ✅
- spec § 5.4 Inline Rename → Task 12 ✅
- spec § 5.5 Close sheet + 最后一个 tab 处理 → Task 14 + Task 15 ✅
- spec § 5.6 拖拽 → Task 10 + Task 13 + Task 14 ✅
- spec § 7 测试策略 → 每任务 TDD + Task 17 手测 ✅
- spec § 9 文档 → Task 16 ✅
- spec § 10 文件总表 → 全覆盖 ✅

**类型 / 签名一致性**：
- `store.moveTab(fromIndex:toIndex:in:)` 与 `store.moveTab(from:to:in:)`—— 统一在 Task 4 实现、Task 14 使用 ✅
- `WorkspaceRowView` 新增参数 `isRenaming/draft/focusBinding/onCommit/onCancel`—— Task 6 定义、Task 7/8 使用 ✅
- `TabItemView.canClose`—— Task 11 定义、Task 12 菜单使用、Task 15 × 按钮使用 ✅
- `TabBarView.onRenameTab` / `onReorderTab`—— Task 11 声明、Task 14 wire ✅
- `com.theall.workspace` vs `com.theall.tab` pasteboard 类型——Task 5 / Task 10 区分 ✅

无占位符、无 TODO、所有代码块可直接粘贴。
