# Status Indicators Beta Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the sidebar + tab-bar status icons behind an opt-in "Status Indicators (Beta)" setting defaulting OFF, with layout collapse when disabled.

**Architecture:** Single config key `theall-status-indicators` in the existing `SettingsConfigStore`. A `showStatusIndicators: Bool` derived from the key in `ContentView` is threaded down through both view bridges into `WorkspaceListView` and `TabBarView`, which hide their `TerminalStatusIconView` subview and collapse the icon's layout slot when false. Hook pipeline (`HookSocketListener` / wrappers / `agent-hook.*`) continues running unconditionally.

**Tech Stack:** Swift 5 / AppKit / SwiftUI, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-19-status-indicators-beta-toggle-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `TheAll/Settings/Sections/TerminalSectionView.swift` | Modify | Add `BoundToggle` at top of form; extend `managedKeys` |
| `TheAllTests/SettingsConfigStoreTests.swift` | Modify | Add default + roundtrip tests for the new key |
| `TheAll/Bridge/SidebarListBridge.swift` | Modify | Add `showStatusIndicators: Bool` prop, forward to `WorkspaceListView.update` |
| `TheAll/Sidebar/WorkspaceListView.swift` | Modify | Accept flag on `update(...)` + per-row init; gate icon subview + collapse layout |
| `TheAll/Bridge/TabBridge.swift` | Modify | Add `showStatusIndicators: Bool` prop, forward to `TabContentView.loadWorkspace` |
| `TheAll/TabContent/TabContentView.swift` | Modify | Accept flag on `loadWorkspace(...)`, forward to `TabBarView.update` |
| `TheAll/TabContent/TabBarView.swift` | Modify | Accept flag on `update(...)` + per-tab init/refresh; gate icon + collapse layout |
| `TheAll/ContentView.swift` | Modify | Compute `showStatusIndicators` from settings; pass to both bridges |

No Swift files deleted. No new files created.

---

## Task 1: Settings UI + Config plumbing

**Files:**
- Modify: `TheAll/Settings/Sections/TerminalSectionView.swift`
- Modify: `TheAllTests/SettingsConfigStoreTests.swift` (append 2 tests)

- [ ] **Step 1.1: Append two tests for the new key**

Open `TheAllTests/SettingsConfigStoreTests.swift` and append inside the class (before the closing `}`):

```swift
    func testStatusIndicatorsDefaultAbsent() {
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()
        XCTAssertNil(store.get("theall-status-indicators"))
    }

    func testStatusIndicatorsRoundtrip() {
        let store = SettingsConfigStore(filePath: tmpPath)
        store.set("theall-status-indicators", "true")
        XCTAssertEqual(store.get("theall-status-indicators"), "true")
        store.set("theall-status-indicators", "false")
        XCTAssertEqual(store.get("theall-status-indicators"), "false")
        store.set("theall-status-indicators", nil)
        XCTAssertNil(store.get("theall-status-indicators"))
    }
```

- [ ] **Step 1.2: Run tests (expect failure)**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/SettingsConfigStoreTests 2>&1 | tail -30
```

Expected: tests either PASS (if the store is fully key-agnostic) or FAIL for a specific reason. Both `set/get` already work for any key in the existing store — the tests should PASS immediately. This is fine; proceed. (If they fail, something broke in the existing store; fix before continuing.)

*Note:* This task has no red/green TDD cycle for the tests themselves because the store is already polymorphic over keys. The value of the tests is regression coverage for the specific key name going forward. Proceed to Step 1.3.

- [ ] **Step 1.3: Add BoundToggle + extend managedKeys in TerminalSectionView**

Replace the entirety of `TheAll/Settings/Sections/TerminalSectionView.swift` with:

```swift
import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "theall-status-indicators",
        "scrollback-limit",
        "copy-on-select",
        "mouse-hide-while-typing",
        "confirm-close-surface",
    ]

    var body: some View {
        Form {
            BoundToggle(
                settings: settings,
                key: "theall-status-indicators",
                defaultValue: false,
                label: "Status Indicators (Beta)"
            )

            BoundStepper(
                settings: settings,
                key: "scrollback-limit",
                defaultValue: 10_000_000,
                range: 0...100_000_000,
                label: "Scrollback Limit"
            )

            BoundSegmented(
                settings: settings,
                key: "copy-on-select",
                options: ["false", "true", "clipboard"],
                label: "Copy On Select"
            )

            BoundToggle(
                settings: settings,
                key: "mouse-hide-while-typing",
                defaultValue: false,
                label: "Hide Mouse While Typing"
            )

            BoundSegmented(
                settings: settings,
                key: "confirm-close-surface",
                options: ["true", "false", "always"],
                label: "Confirm Close"
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

Key changes:
- `"theall-status-indicators"` prepended to `managedKeys` (so reset clears it too)
- New `BoundToggle` added at top of `Form`, above `scrollback-limit`
- Label: `"Status Indicators (Beta)"`

- [ ] **Step 1.4: Build + run SettingsConfigStoreTests**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/SettingsConfigStoreTests 2>&1 | tail -15
```

Expected: all tests pass (pre-existing + the 2 new). Also full build of the `theall` target should succeed since the form additions are independent of runtime state.

Also verify the full test suite stays green:

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -10
```

- [ ] **Step 1.5: Commit**

```bash
git add TheAll/Settings/Sections/TerminalSectionView.swift TheAllTests/SettingsConfigStoreTests.swift
git commit -m "feat(settings): add theall-status-indicators beta toggle to Terminal section

New BoundToggle at top of the Terminal settings form bound to the
theall-status-indicators config key, defaulting false. The key is added
to managedKeys so the section's Reset row clears it. No runtime effect
yet — bridges + views will read the key in subsequent commits."
```

---

## Task 2: Sidebar (WorkspaceListView) icon gating

**Files:**
- Modify: `TheAll/Bridge/SidebarListBridge.swift`
- Modify: `TheAll/Sidebar/WorkspaceListView.swift`

- [ ] **Step 2.1: Add `showStatusIndicators` prop to SidebarListBridge**

In `TheAll/Bridge/SidebarListBridge.swift`, add a new property below `backgroundOpacity` (around line 13) and thread it into both `update` calls:

```swift
import SwiftUI
import AppKit

struct SidebarListBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme
    var metadata: [UUID: WorkspaceMetadata]
    /// 由 SidebarView 用 @State Int 触发；本身不读，只用于让 SwiftUI 重跑 body→updateNSView，
    /// 把最新 metadata 推进 WorkspaceListView。
    var metadataTick: Int
    /// ghostty `background-opacity`，透传给 row 的 selected/hovered 填充色。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, rows omit the TerminalStatusIconView subview and
    /// collapse its layout slot so the title uses the full row width.
    var showStatusIndicators: Bool = false
    var onRequestDelete: (UUID) -> Void

    func makeNSView(context: Context) -> WorkspaceListView {
        let view = WorkspaceListView()
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
                    theme: theme,
                    backgroundOpacity: backgroundOpacity,
                    showStatusIndicators: showStatusIndicators)
        return view
    }

    func updateNSView(_ view: WorkspaceListView, context: Context) {
        _ = metadataTick
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
                    theme: theme,
                    backgroundOpacity: backgroundOpacity,
                    showStatusIndicators: showStatusIndicators)
    }

    private func wire(_ view: WorkspaceListView) {
        view.onSelect        = { id in store.select(id: id) }
        view.onRename        = { id, name in store.renameWorkspace(id: id, to: name) }
        view.onReorder       = { from, to in store.moveWorkspace(from: IndexSet([from]), to: to) }
        view.onRequestDelete = { id in onRequestDelete(id) }
    }
}
```

- [ ] **Step 2.2: Extend `WorkspaceListView.update` signature**

In `TheAll/Sidebar/WorkspaceListView.swift` around line 101, find:

```swift
    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                statuses: [UUID: TerminalStatus] = [:],
                theme: AppTheme,
                backgroundOpacity: CGFloat = 1.0) {
        self.workspaces = workspaces
        self.selectedId = selectedId
        self.metadataMap = metadata
        self.statusMap = statuses
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        rebuildRows()
        applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }
```

Replace with:

```swift
    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                statuses: [UUID: TerminalStatus] = [:],
                theme: AppTheme,
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
        self.workspaces = workspaces
        self.selectedId = selectedId
        self.metadataMap = metadata
        self.statusMap = statuses
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        rebuildRows()
        applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }
```

Also add a stored property on the same class near the existing `statusMap` declaration. Find the property block (search for `private var statusMap: [UUID: TerminalStatus]`). Add just after it:

```swift
    /// Gated UI state — see SidebarListBridge.showStatusIndicators docstring.
    /// When false, row layout + subview creation omits the status icon.
    private var showStatusIndicators: Bool = false
```

- [ ] **Step 2.3: Pass the flag into `WorkspaceRowItemView` on creation**

Still in `TheAll/Sidebar/WorkspaceListView.swift`. Find `rebuildRows()` (or wherever `WorkspaceRowItemView(workspace:…)` is constructed). Add `showStatusIndicators: showStatusIndicators` to every init call (there are typically 1–2 such sites; grep for `WorkspaceRowItemView(` inside the file).

Example edit: if the existing call reads

```swift
let row = WorkspaceRowItemView(
    workspace: ws, isSelected: isSel,
    metadata: md, status: wsStatus,
    theme: theme, backgroundOpacity: backgroundOpacity)
```

change to

```swift
let row = WorkspaceRowItemView(
    workspace: ws, isSelected: isSel,
    metadata: md, status: wsStatus,
    theme: theme, backgroundOpacity: backgroundOpacity,
    showStatusIndicators: showStatusIndicators)
```

Do the same for any `refresh(...)` or similar call sites on `WorkspaceRowItemView` further down in the file.

- [ ] **Step 2.4: Update `WorkspaceRowItemView` init + refresh signatures**

In the same file, find `WorkspaceRowItemView`'s class definition (around line 311) and its `init` (around line 338). Add `showStatusIndicators: Bool = false` parameter to both `init` and `refresh`:

Old init signature (around line 338-342):

```swift
    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata,
         status: TerminalStatus = .neverRan,
         theme: AppTheme,
         backgroundOpacity: CGFloat = 1.0) {
```

New init signature:

```swift
    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata,
         status: TerminalStatus = .neverRan,
         theme: AppTheme,
         backgroundOpacity: CGFloat = 1.0,
         showStatusIndicators: Bool = false) {
```

Add at the top of the init body (before `super.init` line ~350):

```swift
        self.showStatusIndicators = showStatusIndicators
```

Add a matching stored property near the other `fileprivate var` declarations around line 326:

```swift
    fileprivate var showStatusIndicators: Bool
```

Now update `refresh(workspace:isSelected:…)` method around line 444. Its current signature includes theme + backgroundOpacity; add the new flag. Find the signature and the line where the body re-assigns these properties, and extend both:

Example — the method typically looks like:

```swift
    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata, status: TerminalStatus,
                 theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        updateContent()
        updateStyle()
        statusIcon.update(status: status, theme: theme)
    }
```

Change to:

```swift
    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata, status: TerminalStatus,
                 theme: AppTheme, backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        updateContent()
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
        needsLayout = true
    }
```

Also update the `init` body (after `super.init(frame:)` but before `setup()`/`updateContent()`/`updateStyle()` calls) to set `statusIcon.isHidden = !showStatusIndicators` immediately. Final init body should end with:

```swift
        self.showStatusIndicators = showStatusIndicators
        super.init(frame: .zero)
        setup()
        updateContent()
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
```

(The `statusIcon.isHidden` line replaces nothing; it's inserted before the existing `statusIcon.update(...)` call at the end of init body around line 354.)

- [ ] **Step 2.5: Gate the icon's layout math**

Still in `TheAll/Sidebar/WorkspaceListView.swift`, around lines 411-437, find the layout block:

```swift
        // Status icon at top-right of the row, aligned to title baseline
        let iconSize = TerminalStatusIconView.size
        statusIcon.frame = NSRect(
            x: bounds.width - hPad - iconSize,
            y: bounds.height - topPad - titleH + (titleH - iconSize) / 2,
            width: iconSize, height: iconSize)

        // PR badge, if present, sits to the LEFT of the icon
        let prW: CGFloat = prBadge.isHidden
            ? 0
            : ceil(prBadge.intrinsicContentSize.width) + DT.Space.xs
        let iconReservedW = iconSize + DT.Space.xs   // space the title must avoid
```

Replace with:

```swift
        // Status icon at top-right of the row, aligned to title baseline.
        // When showStatusIndicators is false, the icon is hidden AND its layout
        // slot collapses so the title uses the full row width.
        let iconSize: CGFloat = showStatusIndicators ? TerminalStatusIconView.size : 0
        if showStatusIndicators {
            statusIcon.frame = NSRect(
                x: bounds.width - hPad - iconSize,
                y: bounds.height - topPad - titleH + (titleH - iconSize) / 2,
                width: iconSize, height: iconSize)
        }

        // PR badge, if present, sits to the LEFT of the icon
        let prW: CGFloat = prBadge.isHidden
            ? 0
            : ceil(prBadge.intrinsicContentSize.width) + DT.Space.xs
        let iconReservedW = showStatusIndicators ? (iconSize + DT.Space.xs) : 0   // space the title must avoid
```

Also, further down in the same layout block, find the `prBadge.frame` assignment that uses `iconSize`:

```swift
        if !prBadge.isHidden {
            prBadge.frame = NSRect(
                x: bounds.width - hPad - iconSize - DT.Space.xs - prW + DT.Space.xs,
                y: bounds.height - topPad - titleH,
                width: prW, height: titleH)
        }
```

This expression evaluates correctly when `iconSize == 0` (the badge sits at the right edge), so no edit needed. But verify the final x makes sense: `bounds.width - hPad - 0 - DT.Space.xs - prW + DT.Space.xs == bounds.width - hPad - prW` — the PR badge pushes against the right padding, which is the intended behavior when the icon is gone. Good.

- [ ] **Step 2.6: Build + run full test suite**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug 2>&1 | tail -15
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` and all tests pass. No existing sidebar tests will exercise the layout collapse directly; smoke verification is deferred to Task 4/5 where ContentView actually passes `true`/`false` from settings.

- [ ] **Step 2.7: Commit**

```bash
git add TheAll/Bridge/SidebarListBridge.swift TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): gate workspace row status icon behind showStatusIndicators

Plumbs a Bool through SidebarListBridge → WorkspaceListView.update →
WorkspaceRowItemView init/refresh. When false, the row's
TerminalStatusIconView subview is hidden AND its layout slot collapses
(iconSize/iconReservedW → 0) so the workspace title uses the full row
width. Default false to match the upcoming toggle default."
```

---

## Task 3: Tab bar (TabBarView) icon gating

**Files:**
- Modify: `TheAll/Bridge/TabBridge.swift`
- Modify: `TheAll/TabContent/TabContentView.swift`
- Modify: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 3.1: Add `showStatusIndicators` prop to TabBridge**

Replace the entirety of `TheAll/Bridge/TabBridge.swift` with:

```swift
import SwiftUI
import AppKit

struct TabBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme
    /// ghostty `background-opacity`，用来给 AppKit layer 背景（canvas / sidebar strip）
    /// 加 alpha —— 不动 theme token 本身，避免派生出的 border/text 色也被乘透。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, per-tab TerminalStatusIconView is hidden and its
    /// layout slot collapses so the tab label uses the full pill width.
    var showStatusIndicators: Bool = false

    func makeNSView(context: Context) -> TabContentView {
        let view = TabContentView(frame: .zero)
        view.store = store
        view.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        if let ws = store.selectedWorkspace {
            view.loadWorkspace(ws,
                               statuses: statusStore.statusesSnapshot(),
                               showStatusIndicators: showStatusIndicators)
        }
        return view
    }

    func updateNSView(_ nsView: TabContentView, context: Context) {
        nsView.store = store
        nsView.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        if let ws = store.selectedWorkspace {
            nsView.loadWorkspace(ws,
                                 statuses: statusStore.statusesSnapshot(),
                                 showStatusIndicators: showStatusIndicators)
        }
    }

    static func dismantleNSView(_ nsView: TabContentView, coordinator: ()) {
        nsView.detach()
    }
}
```

- [ ] **Step 3.2: Extend `TabContentView.loadWorkspace` signature**

In `TheAll/TabContent/TabContentView.swift` around line 112, find:

```swift
    func loadWorkspace(_ workspace: Workspace, statuses: [UUID: TerminalStatus] = [:]) {
        self.lastStatuses = statuses
```

Replace with:

```swift
    func loadWorkspace(_ workspace: Workspace,
                       statuses: [UUID: TerminalStatus] = [:],
                       showStatusIndicators: Bool = false) {
        self.lastStatuses = statuses
        self.lastShowStatusIndicators = showStatusIndicators
```

Add a stored property near the other `private var lastStatuses: [UUID: TerminalStatus] = [:]` declaration (search for it in the file):

```swift
    private var lastShowStatusIndicators: Bool = false
```

Further down in the same function (around line 135), find the `tabBar.update(...)` call:

```swift
        tabBar.update(tabs: workspace.tabs,
                      selectedTabId: workspace.selectedTabId,
                      theme: theme,
                      statuses: self.lastStatuses,
                      backgroundOpacity: backgroundOpacity)
```

Extend with the new flag:

```swift
        tabBar.update(tabs: workspace.tabs,
                      selectedTabId: workspace.selectedTabId,
                      theme: theme,
                      statuses: self.lastStatuses,
                      backgroundOpacity: backgroundOpacity,
                      showStatusIndicators: self.lastShowStatusIndicators)
```

Also check for any other `loadWorkspace` call site INSIDE `TabContentView.swift` itself (search for `loadWorkspace(`). Around line 150 there's a `reloadFromStore` that calls `loadWorkspace(ws, statuses: lastStatuses)` — extend it to pass `showStatusIndicators: lastShowStatusIndicators`:

```swift
        loadWorkspace(ws,
                      statuses: lastStatuses,
                      showStatusIndicators: lastShowStatusIndicators)
```

- [ ] **Step 3.3: Extend `TabBarView.update` signature**

In `TheAll/TabContent/TabBarView.swift` around line 92, find:

```swift
    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus] = [:],
                backgroundOpacity: CGFloat = 1.0) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        self.statuses = statuses
        self.backgroundOpacity = backgroundOpacity
        rebuildTabItems()
        applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }
```

Replace with:

```swift
    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus] = [:],
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        self.statuses = statuses
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        rebuildTabItems()
        applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }
```

Add a stored property on the `TabBarView` class near the other `private var statuses: [UUID: TerminalStatus]` declaration:

```swift
    private var showStatusIndicators: Bool = false
```

- [ ] **Step 3.4: Propagate flag through `rebuildTabItems` → `TabItemView.refresh`**

Still in `TheAll/TabContent/TabBarView.swift`, around line 126 inside `rebuildTabItems()`, find:

```swift
                    item.refresh(tab: tab, isSelected: isSel, theme: theme, canClose: canCloseNow, status: tabStatus, backgroundOpacity: backgroundOpacity)
```

Extend:

```swift
                    item.refresh(tab: tab, isSelected: isSel, theme: theme, canClose: canCloseNow, status: tabStatus, backgroundOpacity: backgroundOpacity, showStatusIndicators: showStatusIndicators)
```

Do the same for any other `refresh(...)` call site inside `rebuildTabItems` (grep for `.refresh(tab:` in the file — there may be one more place that constructs a fresh `TabItemView`).

For the `TabItemView` construction site (search for `TabItemView(` inside `rebuildTabItems`):

Old:

```swift
let item = TabItemView(tab: tab, isSelected: isSel, theme: theme,
                       canClose: canCloseNow, status: tabStatus,
                       backgroundOpacity: backgroundOpacity)
```

New (append the new arg):

```swift
let item = TabItemView(tab: tab, isSelected: isSel, theme: theme,
                       canClose: canCloseNow, status: tabStatus,
                       backgroundOpacity: backgroundOpacity,
                       showStatusIndicators: showStatusIndicators)
```

- [ ] **Step 3.5: Extend `TabItemView` init + refresh + layout**

Still in `TheAll/TabContent/TabBarView.swift`. Find the `TabItemView` class definition (search for `class TabItemView` or similar — around line 290+). Update its init signature, stored properties, and refresh method.

**Init signature:** locate the existing `init(tab:…backgroundOpacity:)` and add `showStatusIndicators: Bool = false` as the last param. Store it:

```swift
    fileprivate var showStatusIndicators: Bool = false
```

In the init body, after `super.init(frame:)` and before the final `statusIcon.update(status:, theme:)` call (around line 362 area), add:

```swift
        self.showStatusIndicators = showStatusIndicators
        statusIcon.isHidden = !showStatusIndicators
```

Also update `addSubview(statusIcon)` at line 362 — keep the addSubview unconditional (always in tree, just hidden when off), so the isHidden toggle is all that's needed to gate visibility.

**Refresh method:** around line 483, existing signature:

```swift
    func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                 canClose: Bool, status: TerminalStatus,
                 backgroundOpacity: CGFloat = 1.0) {
```

New signature (append the param):

```swift
    func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                 canClose: Bool, status: TerminalStatus,
                 backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false) {
```

In the refresh body (around line 493-495), find `statusIcon.update(status: status, theme: theme)` and add the isHidden toggle right before or after:

```swift
        self.showStatusIndicators = showStatusIndicators
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
        needsLayout = true
```

(`needsLayout = true` forces the layout pass to recompute icon slot when the flag flips live.)

- [ ] **Step 3.6: Gate the tab cell's layout math**

Still in `TheAll/TabContent/TabBarView.swift`, around lines 400-414, find:

```swift
        let margin: CGFloat = 10
        let iconSize: CGFloat = TerminalStatusIconView.size
        let iconGap: CGFloat = 6
        statusIcon.frame = NSRect(
            x: bounds.width - margin - iconSize, y: (h - iconSize) / 2,
            width: iconSize, height: iconSize)

        let textH = ceil(titleLabel.intrinsicContentSize.height)
        let textX = margin
        let textFrame = NSRect(x: textX, y: (h - textH) / 2,
                               width: bounds.width - margin - iconSize - iconGap - textX,
                               height: textH)
        titleLabel.frame = textFrame
        renameField.frame = textFrame
    }
```

Replace with:

```swift
        let margin: CGFloat = 10
        let iconSize: CGFloat = showStatusIndicators ? TerminalStatusIconView.size : 0
        let iconGap: CGFloat = showStatusIndicators ? 6 : 0
        if showStatusIndicators {
            statusIcon.frame = NSRect(
                x: bounds.width - margin - iconSize, y: (h - iconSize) / 2,
                width: iconSize, height: iconSize)
        }

        let textH = ceil(titleLabel.intrinsicContentSize.height)
        let textX = margin
        let textFrame = NSRect(x: textX, y: (h - textH) / 2,
                               width: bounds.width - margin - iconSize - iconGap - textX,
                               height: textH)
        titleLabel.frame = textFrame
        renameField.frame = textFrame
    }
```

When `showStatusIndicators` is false:
- `iconSize = 0` and `iconGap = 0` → `textFrame.width = bounds.width - margin - 0 - 0 - margin = bounds.width - 2*margin`, giving the label the full pill interior.

- [ ] **Step 3.7: Build + run full test suite**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug 2>&1 | tail -15
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` and all tests pass.

- [ ] **Step 3.8: Commit**

```bash
git add TheAll/Bridge/TabBridge.swift TheAll/TabContent/TabContentView.swift TheAll/TabContent/TabBarView.swift
git commit -m "feat(tabcontent): gate tab bar status icon behind showStatusIndicators

Threads Bool through TabBridge → TabContentView.loadWorkspace →
TabBarView.update → TabItemView init/refresh. When false, per-tab
statusIcon is isHidden AND layout collapses (iconSize/iconGap → 0)
so the tab title uses the full pill interior. Default false."
```

---

## Task 4: ContentView wiring

**Files:**
- Modify: `TheAll/ContentView.swift`

- [ ] **Step 4.1: Compute `showStatusIndicators` in ContentView and pass to both bridges**

Open `TheAll/ContentView.swift`. Locate where `SidebarListBridge(...)` is constructed (around line 55 area — search for `SidebarListBridge(`). Add a new argument `showStatusIndicators:`.

Similarly locate `TabBridge(...)`.

Add a computed property on the `ContentView` struct (near the top of the struct body, below the existing `@State` / `@Environment` declarations):

```swift
    /// Beta gate for the sidebar + tab bar status icon display.
    /// Key: `theall-status-indicators` in the theall config file. Absent or any
    /// value other than "true" → false.
    private var showStatusIndicators: Bool {
        settingsStore.get("theall-status-indicators") == "true"
    }
```

Then in each bridge construction, append `showStatusIndicators: showStatusIndicators`.

Example for `SidebarListBridge` (actual indentation depends on surrounding code; match existing):

```swift
SidebarListBridge(
    store: store,
    statusStore: statusStore,
    theme: themeManager.currentTheme,
    metadata: metadata,
    metadataTick: metadataTick,
    backgroundOpacity: effectiveBackgroundOpacity,
    showStatusIndicators: showStatusIndicators,
    onRequestDelete: { id in pendingDeleteId = id }
)
```

Example for `TabBridge`:

```swift
TabBridge(
    store: store,
    statusStore: statusStore,
    theme: themeManager.currentTheme,
    backgroundOpacity: effectiveBackgroundOpacity,
    showStatusIndicators: showStatusIndicators
)
```

(Use the actual argument names / order present in the ContentView file. Only difference: add `showStatusIndicators:` before the last trailing arg in each.)

- [ ] **Step 4.2: Build**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll -configuration Debug 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.3: Full test regression**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4.4: Commit**

```bash
git add TheAll/ContentView.swift
git commit -m "feat(bridge): wire theall-status-indicators setting to both bridges

ContentView reads the config key via settingsStore.get(...) and passes
the resulting Bool as showStatusIndicators to SidebarListBridge and
TabBridge. Because SettingsConfigStore is @Observable, flipping the
toggle in Settings immediately re-evaluates ContentView.body which
re-runs updateNSView on both bridges → icons show/hide live without
app restart."
```

---

## Task 5: Manual verification matrix

**Files:** none. User-run verification task; no commit.

- [ ] **Step 5.1: Rebuild + launch**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
open build/Debug/TheAll.app   # or your preferred launch
```

- [ ] **Step 5.2: Default OFF verification**

Fresh launch (or toggle OFF if you had it on previously). Expect:
- Sidebar workspace rows: NO status dot next to the title. Title fills the row width.
- Tab bar pills: NO status dot. Tab title fills the pill interior.
- No visual reservation for the icon slot (layout collapsed).

- [ ] **Step 5.3: Enable and verify live**

Open Settings (Cmd+,) → Terminal → toggle "Status Indicators (Beta)" ON. Expect:
- Icons appear immediately in both sidebar and tab bar (no app restart).
- Current terminal states reflect correctly (green/red/spinner/etc.).
- Tab and row layouts shrink title area to make room for the icon.

- [ ] **Step 5.4: Live disable**

Flip toggle back to OFF. Expect:
- Icons disappear immediately.
- Title area expands back to full width.
- Click a running command in a terminal to confirm the UI doesn't ghost the icon.

- [ ] **Step 5.5: Persistence across restart**

Set toggle to ON, quit theall, re-launch. Expect icons persist as ON.
Set to OFF, quit, re-launch. Expect no icons.

- [ ] **Step 5.6: Reset row behavior**

In Settings → Terminal, click the "Reset" row at the bottom. The `theall-status-indicators` key should be cleared along with the other managed keys, returning the toggle to OFF.

- [ ] **Step 5.7: Hook infrastructure still runs regardless**

With toggle OFF: run `true` in a terminal. Inspect `~/Library/Caches/theall/hook-emit.log` — you should still see `event=running` / `event=finished` lines. Hook listener / agent-hook.py still receive and process events; only the UI render is gated.

If any row of the matrix fails, stop and report:
- Which row
- Current value of `~/Library/Application Support/theall/config` for the `theall-status-indicators` key
- Screenshot or description of the misbehaving visual state

---

## Self-review notes

**Spec coverage:**
- §Config Schema → Task 1
- §Settings UI → Task 1
- §Propagation Path (bridges + views) → Tasks 2 + 3
- §Implementation Details per View → Tasks 2 (sidebar) + 3 (tab bar)
- §Reactive Update Flow → Task 4 (ContentView reads settings and passes to bridges; @Observable drives re-render)
- §Hook Infrastructure (Unchanged) → verified in Task 5.7
- §Testing → Task 1 adds SettingsConfigStoreTests cases; layout-level NSView tests not added (spec says "if feasible", and adding AppKit layout assertions is high cost / low value for a Bool flag)
- §Edge Cases → handled by the plan's defaults (absent key → OFF, `"1"` / `"yes"` → OFF because comparison is strict `== "true"`)

**Placeholder scan:** no TBD/TODO. Every code block is complete and pasteable.

**Type consistency check:**
- `showStatusIndicators: Bool = false` used as parameter name + stored property name across `SidebarListBridge`, `WorkspaceListView.update`, `WorkspaceRowItemView.init/refresh`, `TabBridge`, `TabContentView.loadWorkspace`, `TabBarView.update`, `TabItemView.init/refresh`, and `ContentView.showStatusIndicators` computed property. All sites match.
- `lastShowStatusIndicators` is the `TabContentView`-internal cache name (only referenced there); consistent in Task 3.2.
- Config key `"theall-status-indicators"` spelled identically in Task 1 (BoundToggle + managedKeys + tests) and Task 4 (ContentView computed property).

**No tests for layout collapse?** Correct. Testing NSView frame math after `needsLayout = true` requires a live run loop in XCTest and is brittle. The behavior is verified by Task 5's manual matrix. This matches the spec's "Swift tests … if feasible" caveat.

---

## Completion criteria

- Swift full test suite: passes green (including the 2 new SettingsConfigStoreTests)
- Build of `theall` and `TheAllTests` schemes: clean
- Fresh launch with no key → icons hidden (default OFF)
- Toggle ON live → icons appear immediately on sidebar + tab bar
- Toggle OFF live → icons disappear, layout collapses
- Hook pipeline continues emitting regardless of toggle state
- Every intermediate commit builds (spec's additive-by-default discipline holds — each task has a default-valued new parameter so earlier commits still compile)
- No Swift file outside the File Structure table modified
