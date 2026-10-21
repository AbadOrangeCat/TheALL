# theall Tab-Based Terminal Redesign

**Date:** 2026-04-14  
**Status:** Approved  
**Scope:** Replace free-canvas multi-window layout with tab + split-pane terminal management

---

## Overview

Replace the current infinite-canvas drag-and-drop terminal layout with a tab-based interface. Each workspace has multiple tabs; each tab supports recursive horizontal/vertical split panes (like Ghostty / tmux). The content area always fills the full window — no floating windows, no scroll canvas.

---

## §1 Data Model

### New Types (replaces `TerminalState`)

```swift
indirect enum SplitNode: Codable, Equatable {
    case terminal(UUID)
    case split(SplitDirection, CGFloat, SplitNode, SplitNode)
    // CGFloat: ratio of first child, 0.0–1.0
}

enum SplitDirection: Codable {
    case horizontal   // top / bottom
    case vertical     // left / right
}

struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String           // initially "terminal N"
    var layout: SplitNode       // root of split tree; initial = .terminal(uuid)
    var focusedTerminalId: UUID // currently focused leaf
}

struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab]
    var selectedTabId: UUID?
}
```

### WorkspaceStore Operations

New methods replacing canvas-era CRUD:
- `addTab(to workspaceId:) -> UUID?` — appends a new tab with one terminal
- `removeTab(id:from:)` — removes tab; if last, creates a new empty tab
- `selectTab(id:in:)` — sets `selectedTabId`
- `splitTerminal(id:in:tabId:direction:) -> UUID?` — replaces `.terminal(id)` leaf with `.split(dir, 0.5, .terminal(id), .terminal(newId))`
- `closeTerminal(id:in:tabId:)` — removes leaf, promotes sibling; if last leaf closes the tab
- `updateSplitRatio(terminalId:in:tabId:ratio:)` — updates ratio in the split node containing `terminalId`
- `updateFocusedTerminal(id:in:tabId:)` — updates `focusedTerminalId`

Removed: `addTerminal(to:frame:)`, `removeTerminal(id:from:)`, `updateTerminalFrame(id:in:frame:)`

### Persistence

Uses a new key `"theall.workspaces.v2"` — old `"theall.workspaces"` data is silently abandoned (it only stored frame coordinates; no meaningful state is lost).

---

## §2 View Layer Architecture

### Files Deleted

- `Canvas/CanvasScrollView.swift`
- `Canvas/CanvasContentView.swift`
- `Canvas/TerminalWindowView.swift`
- `Canvas/TitleBarView.swift`
- `Bridge/CanvasBridge.swift`

### Files Added

```
TabContent/
  TabBarView.swift        — horizontal tab bar (NSView)
  SplitPaneView.swift     — recursive NSSplitView tree (NSView)
  TabContentView.swift    — combines TabBarView + SplitPaneView (NSView)
Bridge/
  TabBridge.swift         — NSViewRepresentable, replaces CanvasBridge
```

### Files Modified

- `Models/Workspace.swift` — new data model
- `Models/WorkspaceStore.swift` — new CRUD, new persistence key
- `ContentView.swift` — swap `CanvasBridge` for `TabBridge`; remove `theAllCreateTerminalAtVisibleCenter` notification
- `TheAllApp.swift` — register new keyboard shortcut menu items

### Files Unchanged

- `Ghostty/GhosttyTerminalView.swift`
- `Ghostty/GhosttyBridge.swift`
- `Theme/` (all files)
- `Sidebar/` (all files)
- `Metadata/` (all files)

### View Hierarchy

```
ContentView (SwiftUI)
  ├─ SidebarView
  └─ TabBridge (NSViewRepresentable)
       └─ TabContentView (NSView)
            ├─ TabBarView (NSView)
            └─ SplitPaneView (NSView)          ← active tab's root node
                 ├─ GhosttyTerminalView         ← .terminal leaf
                 └─ NSSplitView
                      ├─ SplitPaneView          ← recursive
                      └─ SplitPaneView
```

### Component Responsibilities

**TabBarView**  
Renders all tabs for the active workspace. Clicking a tab calls `store.selectTab`. `+` button calls `store.addTab`. `×` (shown on hover) calls `store.removeTab`. Receives `AppTheme` for styling.

**SplitPaneView**  
Accepts a `SplitNode`. For `.terminal(id)`: hosts one `GhosttyTerminalView`. For `.split(dir, ratio, a, b)`: creates an `NSSplitView` containing two recursive `SplitPaneView` children. Divider drag callbacks update `store.updateSplitRatio`. Click on a leaf calls `GhosttyTerminalView.makeFrontmost` and `store.updateFocusedTerminal`.

**TabContentView**  
Holds a `WorkspaceStore` reference. On workspace/tab change: tears down old `SplitPaneView`, builds new one from the selected tab's `layout`. Calls `GhosttyTerminalView.makeFrontmost` on the `focusedTerminalId` leaf.

**TabBridge**  
`makeNSView`: creates `TabContentView`, wires store.  
`updateNSView`: pushes workspace changes and theme updates.  
`dismantleNSView`: calls cleanup (analogous to `detachWorkspace`).

---

## §3 Keyboard Shortcuts

All shortcuts registered in `TheAllApp.swift` via `Commands`:

| Action | Shortcut | Behavior |
|--------|----------|----------|
| New tab | `⌘T` | `store.addTab`; focus new tab |
| Close pane / tab | `⌘W` | Close focused terminal; promote sibling; close tab if last pane |
| Split left/right | `⌘D` | `store.splitTerminal(direction: .vertical)` |
| Split top/bottom | `⌘⇧D` | `store.splitTerminal(direction: .horizontal)` |
| Next tab | `⌘⇧]` | Cycle forward |
| Previous tab | `⌘⇧[` | Cycle backward |
| Jump to tab N | `⌘1`–`⌘9` | Select tab by index |
| Focus adjacent pane | `⌘⌥→/←/↑/↓` | Walk split tree to nearest leaf in direction |

### Focus Rules

- Only one `GhosttyTerminalView` is frontmost at any time (existing `makeFrontmost` mechanism, unchanged).
- `focusedTerminalId` in `TerminalTab` persists across tab switches.
- Switching tabs restores focus to `focusedTerminalId` of the newly selected tab.
- Closing a pane transfers focus to the sibling node's `focusedTerminalId` (or the sibling leaf itself).

### Pane Close Tree Transform

```
Before:               After (⌘W on A):
    split                 terminal(B)
   /     \
terminal(A) terminal(B)
```

Sibling node is promoted to replace the parent split node.

---

## §4 Visual Design

### Tab Bar

Height: `DT.Layout.titleBarHeight` (reuses existing token).

| Element | Style |
|---------|-------|
| Tab (normal) | bg `theme.sidebar`, text `theme.textSecondary` |
| Tab (selected) | bg `theme.surface`, text `theme.textPrimary`, bottom border `theme.accent` 2px |
| Tab (hover) | bg `theme.surface` @ 50% alpha |
| `×` button | Visible on hover only |
| `+` button | Right-aligned, `theme.textTertiary` |

### Split Divider

`NSSplitView` divider: `dividerThickness = 1`, color `theme.border`. No system-default raised divider style.

### Tab Title

Displayed as `"terminal 1"`, `"terminal 2"`, etc. (index within workspace). Future extension: update from shell process title via ghostty callback — out of scope for this iteration.

---

## §5 Migration Strategy

Old persistence key `"theall.workspaces"` stores `[TerminalState]` with frame coordinates. This data is not meaningful (terminal sessions are in-memory; frames are canvas positions). The new store uses key `"theall.workspaces.v2"`. No explicit migration needed — old key is silently abandoned on first launch under the new version.

`WorkspaceStore.init()` with the new key will find no data, trigger the default "create one workspace with one tab" path, and proceed normally.
