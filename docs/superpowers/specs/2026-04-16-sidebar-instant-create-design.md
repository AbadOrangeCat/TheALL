# Sidebar instant-create design

**Date:** 2026-04-16
**Status:** Approved

## Goal

去掉 sidebar header 旁的 workspace 计数，换成一个 "+" 按钮；统一所有创建入口，移除命名输入框，点击即用默认名创建。

## Motivation

当前 header 右上角的数字是装饰性信息，实用价值低。把这个位置改成一个"+"按钮，既给用户一个更顺手的创建入口，又简化整个创建流程——不再需要先弹出输入框、敲名字、再确认。

## Changes

**`TheAll/Sidebar/SidebarView.swift`**

1. **Header**：删除 `Text("\(store.workspaces.count)")`；在 `Spacer()` 后加一个 `Button` 含 `Text("+")`（沿用 footer 现有的 `DT.Font.body` + `theme.textSecondary`），点击调用 `createWorkspaceWithDefaultName()`。`buttonStyle(.plain)` 保持极简外观。
2. **Footer**：保留 "New workspace" 行（含 ⌘N 提示），但点击行为改为直接调用 `createWorkspaceWithDefaultName()`，不再切换到输入框模式。
3. **删除**：
   - `@State isCreating`
   - `@State newWorkspaceName`
   - `@FocusState newFieldFocused`
   - `creationField` 视图
   - `commitCreate()` / `cancelCreate()`
   - `Group { if isCreating ... else ... }` 包装；`footer` 直接返回新的按钮
4. **重写** `beginCreate()` → 改名为 `createWorkspaceWithDefaultName()`，逻辑：
   ```swift
   let name = "workspace \(store.workspaces.count + 1)"
   store.createWorkspace(name: name)
   ```
5. **保留** `.onReceive(NotificationCenter ... .theAllBeginCreateWorkspace)` —— 但回调改为调用 `createWorkspaceWithDefaultName()`，让 ⌘N 也走同一路径。

## Default name

格式：`workspace N`，其中 `N = workspaces.count + 1`。

- 跟 `WorkspaceStore.makeNewTab` 中的 `"terminal \(index)"` 风格一致。
- 不做唯一性检查；用户删除中间项后下次创建可能重名（与 `terminal N` 行为一致），用户可手动 rename。

## Out of scope

- 不动 `WorkspaceStore.createWorkspace(name:)` API。
- 不动 ⌘N keyboard shortcut 注册（仍在 `TheAllApp.swift` 通过 `.theAllBeginCreateWorkspace` 通知触发）。
- 不动 `WorkspaceListView`（行内 rename 逻辑保持不变；用户可通过双击 row 改名）。

## Testing

手动验证：
1. 点击 header "+" → 立即新建 `workspace N`，无输入框。
2. 点击 footer "New workspace" → 同上。
3. 按 ⌘N → 同上。
4. 计数从 header 消失。
5. 多次创建 → 名字递增。
