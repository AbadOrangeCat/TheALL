# Terminal PWD Persistence & Inheritance Design

**Date:** 2026-04-21
**Status:** Approved — ready for implementation plan

## Problem

三个关联场景都围绕"开一个新 terminal 时，它的初始 pwd 应该在哪里"：

1. **新建 tab**：当前行为总是在 `$HOME` 启动。用户期望新 tab 落在"刚才聚焦的那个 pane 所在目录"。
2. **新建 workspace**：同样在 `$HOME` 启动。用户期望落在"刚才所选 workspace 的聚焦 pane 所在目录"。
3. **app 重启**：持久化的 workspace / tab / split 树能恢复，但所有 terminal 重启后都回到 `$HOME`，丢掉了关闭前用户在各个 pane 里 `cd` 过去的路径。

## Current State

- `TerminalPwdStore`（`Models/TerminalPwdStore.swift`）维护 `[UUID: String]`，由 shell 的 OSC 7（`kitty-shell-cwd://…`）→ ghostty `GHOSTTY_ACTION_PWD` → `GhosttyBridge.onPwdChanged` 回调喂入。**纯内存、session-scoped**，其 doc comment 明确说 "app restart → all entries gone"。
- `GhosttyBridge.newSurface(..., workingDirectory: String?, ...)` 已经有参数，但 `GhosttyTerminalView.viewDidMoveToWindow`（`TheAll/Ghostty/GhosttyTerminalView.swift:162`）永远传 `nil`，所以 shell 只会在 ghostty 默认目录（通常 `$HOME`）启动。
- `WorkspaceStore.addTab(to:)` 返回新 tab 的 `UUID?`，`splitTerminal(...)` 返回新 terminal 的 `UUID?`；`createWorkspace(name:)` 返回 `Void`。
- `Workspace` / `TerminalTab` 的 Codable wire format 不含任何 pwd 字段。

## Decisions

**D1. 继承来源 = 最近焦点（用户选择 A）**
- 新建 tab → 当前 workspace 的 `selectedTab?.focusedTerminalId`
- 新建 workspace → 创建**前**的 `store.selectedWorkspace?.selectedTab?.focusedTerminalId`
- 拆分 pane → 被拆 pane 的 terminalId

**D2. split 也走这套继承（用户选择 A）** — 避免"split 到 `$HOME`、新 tab 却继承"的不一致。

**D3. 失效路径 fallback = 静默回退到 `$HOME`（用户选择 A）** — 用 `FileManager` 在 theall 侧 pre-check，不存在就传 `nil` 给 ghostty，不打印 log、不做 UI 提示。

## Architecture

把"pwd 继承 + 重启还原"统一到一个引擎：**持久化的 `TerminalPwdStore`**。

```
shell OSC 7 → ghostty PWD action → GhosttyBridge.onPwdChanged
  → TerminalPwdStore.setPwd(…)           [debounced UserDefaults write]
                                ↓ 读
GhosttyTerminalView.viewDidMoveToWindow
  → validatedDirectory(pwdStore.pwd(for: id))
  → newSurface(workingDirectory: validated, …)
```

**为什么不把 `lastPwd` 塞进 `TerminalTab` 模型：**
- 每个 tab 里可能有多个 split pane，每个 pane 独立 pwd，以 UUID 为 key 天然支持。
- `TerminalTab` 的 Codable 是 wire format，改字段要迁移；`TerminalPwdStore` 另起一个 UserDefaults key 可以 throwaway（丢了等于回退到当前 nil 行为，零破坏）。
- 关注点分离：`WorkspaceStore` 管布局，`TerminalPwdStore` 管运行时状态快照。

## Components

### 1. `TerminalPwdStore` 升级为持久化源

- 新 UserDefaults key：`theall.pwds.v1`
- `setPwd` 时 300 ms debounce 保存（沿用 `WorkspaceStore.updateSplitRatio` 已有的 `DispatchWorkItem` 防抖模式），避免 OSC 7 高频 `cd` 狂写盘。
- 新 API：`func inherit(from source: UUID, to dest: UUID)` — 若 source 有记录，复制到 dest；否则 no-op。
- `forget(terminalId:)` 行为不变；`ContentView.onChange(of: store.workspaces)` 里已有的失效 UUID pruning 逻辑照跑，pruning 后触发一次 debounced save。
- `init` 里同步 `load()`，和 `WorkspaceStore.init` 同套路。

### 2. `WorkspaceStore` 扩展返回值

- `addTab(to:)`：现在 `-> UUID?`（新 tab id），改成 `-> (tabId: UUID, terminalId: UUID)?`，把新 tab 首个 terminal 的 UUID 也暴露出来，供调用方做 `pwdStore.inherit(...)`。
- `splitTerminal(...)`：已返回 `UUID?`（新 terminal id），不动。
- `createWorkspace(name:)`：`Void → UUID?`，返回新 workspace 第一个 tab 的 terminal id（即 `workspaces.last?.tabs.first?.layout` 的 leaf UUID）。
- 注意：`WorkspaceStore` **不**持有 `TerminalPwdStore` 引用。inherit 的调用放在 UI 层（`TabContentView` / `SidebarView`），保持关注点分离。

### 3. 依赖注入：`pwdStore` 下沉到 `TabContentView`

- 现在链条：`ContentView → TabBridge → TabContentView`。需要在 `TabBridge` 加 `pwdStore: TerminalPwdStore` 参数，`TabContentView` 加对应 `var pwdStore: TerminalPwdStore?`。
- `TabContentView.terminalViewFor(id:)` 里，构造 `GhosttyTerminalView` 后立即赋 `tv.pwdStoreRef = self.pwdStore`（和现有的 `tv.terminalId = id` 一样的位置）。

### 4. `GhosttyTerminalView` 读 seed + 校验

- 新字段 `var pwdStoreRef: TerminalPwdStore?`（强引用 OK，store 生命周期由 ContentView 管理，不会早于 view）。
- `viewDidMoveToWindow` 里：
  ```swift
  let seed = pwdStoreRef?.pwd(for: terminalId ?? UUID())
  let validated = Self.validatedDirectory(seed)
  surface = GhosttyBridge.shared.newSurface(
      nsView: self,
      scaleFactor: scale,
      workingDirectory: validated,   // 原本是 nil
      terminalId: terminalId ?? UUID()
  )
  ```
- 新 static helper：
  ```swift
  static func validatedDirectory(_ path: String?) -> String? {
      guard let path else { return nil }
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
            isDir.boolValue else { return nil }
      return path
  }
  ```

### 5. 三个"开新 pane"入口的 inherit 接线

**新建 tab：**`TabContentView` 目前有两条入口 —— `addNewTab()`（notification 分发）和 `tabBar.onAddTab`（AppKit 闭包），各自拷贝了同一段 `store?.addTab(...) + reloadFromStore()`。改造时先归一到一个 `private func addNewTab()`，`tabBar.onAddTab` 直接调它，然后在单点加 inherit：
```swift
private func addNewTab() {
    guard let wsId = store?.selectedId,
          let ws = store?.selectedWorkspace else { return }
    let sourceId = ws.selectedTab?.focusedTerminalId
    guard let (_, newTerminalId) = store?.addTab(to: wsId) else { return }
    if let sourceId { pwdStore?.inherit(from: sourceId, to: newTerminalId) }
    reloadFromStore()
}
```

**拆分 pane（`TabContentView.splitCurrentPane(direction:)`）：**
```swift
let sourceId = tab.focusedTerminalId
guard let newId = store?.splitTerminal(
    id: sourceId, in: wsId, tabId: tab.id, direction: direction) else { return }
pwdStore?.inherit(from: sourceId, to: newId)
reloadFromStore()
```

**新建 workspace（`SidebarView.createWorkspaceWithDefaultName()`）：**
```swift
func createWorkspaceWithDefaultName() {
    let sourceId = store.selectedWorkspace?.selectedTab?.focusedTerminalId
    let name = "workspace \(store.workspaces.count + 1)"
    guard let newTerminalId = store.createWorkspace(name: name) else { return }
    if let sourceId { pwdStore.inherit(from: sourceId, to: newTerminalId) }
}
```

### 6. 首次启动 / 无 source 的情况

- 首次装 theall、或首个 workspace 还没有任何 terminal 上报过 pwd → `inherit(from:to:)` 发现 source 无记录 → no-op → `pwdStore.pwd(for: newId)` 为 nil → surface 传 `nil` workingDirectory → shell 在 `$HOME`。和当前行为一致。

### 7. 重启时序保证

启动序：
1. `ContentView.init`：`@State private var store = WorkspaceStore()`（`init` 里同步 load）、`@State private var pwdStore = TerminalPwdStore()`（`init` 里同步 load）。
2. SwiftUI body 首次跑 → `TabBridge` 构造 → `TabContentView.loadWorkspace(...)` → `terminalViewFor(id:)` 构造 `GhosttyTerminalView`，立即赋 `terminalId` 和 `pwdStoreRef`。
3. View 挂到 window → `viewDidMoveToWindow` → 读 `pwdStoreRef.pwd(for: id)` → 校验存在性 → 传给 `newSurface`。

`pwdStore.load()` 必须在 view 构造**之前**完成 — `@State` 的默认值表达式在 body 第一次跑之前求值，所以 `init` 里同步 `load()` 就够。

非 selected tab 的 terminal 的 `viewDidMoveToWindow` 是 lazy 的（用户切过去才触发），届时 store 仍在内存里，不受时序影响。

## Testing Strategy

新增单元测试：

1. `TerminalPwdStoreTests`
   - `setPwd` + re-init 同 persistenceKey → pwd 保持（round-trip encode/decode）
   - `inherit(from: A, to: B)` where A has pwd → B gets same pwd
   - `inherit` where A has no pwd → B stays nil, no crash
   - `forget(terminalId:)` 后重建 store → 该 id 没有记录

2. `GhosttyTerminalViewTests` / 新文件
   - `validatedDirectory(nil) == nil`
   - `validatedDirectory("/tmp")` → `"/tmp"`（用 `FileManager` 建一个临时目录）
   - `validatedDirectory("/nonexistent/path")` → `nil`
   - `validatedDirectory(<path to a regular file>)` → `nil`

3. `WorkspaceStoreTests` 扩展
   - `addTab(to:)` 返回的 `terminalId` 等于新 tab 的 `layout.allTerminalIds().first`
   - `createWorkspace(name:)` 返回的 `terminalId` 等于新 workspace 首 tab 首 terminal 的 id

**不**覆盖：
- 真正拉起 ghostty surface 的 end-to-end（那是 UI integration，本地跑不稳）
- OSC 7 → pwdStore 的实际回调（ghostty 侧已有测试，theall 只是被动接收）

## Impact Summary

**核心文件：**
- `TheAll/Models/TerminalPwdStore.swift`：加持久化 + `inherit` API
- `TheAll/Models/WorkspaceStore.swift`：`addTab` / `createWorkspace` 返回值扩展
- `TheAll/Ghostty/GhosttyTerminalView.swift`：加 `pwdStoreRef`、读 seed、校验、传 `workingDirectory`
- `TheAll/Ghostty/GhosttyBridge.swift`：无改动（已有 `workingDirectory` 参数）

**注入链：**
- `TheAll/ContentView.swift`：把 `pwdStore` 传给 `TabBridge`
- `TheAll/Bridge/TabBridge.swift`：加 `pwdStore` 参数，转给 `TabContentView`
- `TheAll/TabContent/TabContentView.swift`：加 `var pwdStore`，在 `terminalViewFor` 里赋给 view

**调用点：**
- `TheAll/TabContent/TabContentView.swift`：`addNewTab` / `splitCurrentPane` / `tabBar.onAddTab` 里加 `pwdStore?.inherit(...)`
- `TheAll/Sidebar/SidebarView.swift`：`createWorkspaceWithDefaultName` 加 `pwdStore.inherit(...)`

**文档同步：**
- `docs/architecture.md`：更新 "TerminalPwdStore" 段落（不再是 "session-scoped only"）、`newSurface(...)` 条目 workingDirectory 的含义
- `docs/ghostty-integration.md`：提一句新的 pwd 注入

**不破坏的点：**
- UserDefaults `theall.pwds.v1` 是新 key，老用户第一次跑是空 dict，行为等价于今天
- surface 的 wire protocol 无改动，ghostty 侧零影响
- OSC 7 回调路径无改动
