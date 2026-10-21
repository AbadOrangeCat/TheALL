# Menu Bar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface all user-triggerable actions in the macOS system menu bar with discoverable keyboard shortcuts, route Copy/Paste/Select All through focused `GhosttyTerminalView`, and strip default menu items that don't apply to theall.

**Architecture:** Add 5 new `Notification.Name`s as the plumbing between menu items and the focused terminal. The App-level `.commands { ... }` block replaces default `CommandGroup` placements (to drop unused items), adds a new **Terminal** menu (which replaces the old **Tab** menu), and a minimal **Edit** pasteboard group. `GhosttyTerminalView` gains three thin wrappers over `ghostty_surface_binding_action` for copy/paste/select-all. The hidden `NSEvent` monitor in `TabContentView` is narrowed to only the `⌘⌥↑/↓` aliases — horizontal arrows are now represented by menu shortcuts.

**Tech Stack:** Swift 5.9+, SwiftUI `App` / `Scene` / `Commands`, AppKit (`NSView`, `NSEvent`), libghostty C API, `NotificationCenter`, XCTest.

**Source spec:** `docs/superpowers/specs/2026-04-17-menu-bar-redesign-design.md`

---

## Context for the implementer

If you're walking into this plan cold, read these first:

- **`CLAUDE.md`** — project overview, branch convention (`agent/<name>`), commit convention (`type(scope): description`).
- **`docs/architecture.md`** — `WorkspaceStore` is the single source of truth, `NotificationCenter` is used for menu→view messaging.
- **`TheAll/TheAllApp.swift`** — current `.commands` block (baseline for Task 5).
- **`TheAll/ContentView.swift:92-101`** — existing `Notification.Name` extensions (baseline for Task 1).
- **`TheAll/TabContent/TabContentView.swift:246-275, 344-367`** — notification subscription/dispatch and NSEvent key monitor (baseline for Tasks 3 and 4).
- **`TheAll/Ghostty/GhosttyTerminalView.swift`** — NSView that owns `ghostty_surface_t`, pattern for adding new C-API wrappers (baseline for Task 2).
- **`Vendor/ghostty/include/ghostty.h:1151`** — `ghostty_surface_binding_action(surface, const char*, uintptr_t)` — the C API we wrap.

**libghostty binding-action reminder.** Ghostty binding actions are passed as ASCII DSL strings. The three we use:
- `"copy_to_clipboard"`
- `"paste_from_clipboard"`
- `"select_all"`

The third argument (`uintptr_t`) is the byte length of the string (same as `size_t` on our targets).

**Branch convention.** Work on `agent/menu-bar-redesign` (or continue on the current `agent/terminal-status-icon` if that's where brainstorming happened — check `git branch --show-current` first; the spec was committed on `agent/terminal-status-icon`, so stay there unless told otherwise).

---

## File map

Files created or modified, with the single responsibility of each:

| File | Action | Responsibility |
|---|---|---|
| `TheAll/ContentView.swift` | Modify (+5 lines at bottom) | Declare 5 new `Notification.Name` constants |
| `TheAll/Ghostty/GhosttyTerminalView.swift` | Modify (add 1 small MARK section) | Expose `copySelection()` / `pasteClipboard()` / `selectAll()` as thin `ghostty_surface_binding_action` wrappers |
| `TheAll/TabContent/TabContentView.swift` | Modify 3 places | Subscribe to 5 new notifications, dispatch them, narrow key monitor to vertical arrows |
| `TheAll/TheAllApp.swift` | Rewrite `.commands { ... }` body | Replace default command groups to drop unused items, add new **Terminal** menu, add minimal **Edit** pasteboard group |
| `TheAllTests/NotificationNamesTests.swift` | Create (new file, trivial) | Pin the 5 new notification name raw strings — guards against rename drift |

Nothing in `TheAll/Models/`, `TheAll/Sidebar/`, `TheAll/Canvas/`, or `TheAll/Bridge/` changes. No changes to `project.yml`, `Vendor/`, or `scripts/`.

---

## Task 1: Add new Notification.Name constants

**Files:**
- Modify: `TheAll/ContentView.swift:92-101` (extend the existing `extension Notification.Name`)
- Create: `TheAllTests/NotificationNamesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TheAllTests/NotificationNamesTests.swift` with:

```swift
import XCTest
@testable import TheAll

final class NotificationNamesTests: XCTestCase {
    func testNewMenuNotificationRawValues() {
        XCTAssertEqual(Notification.Name.theAllFocusNextPane.rawValue, "theall.focusNextPane")
        XCTAssertEqual(Notification.Name.theAllFocusPrevPane.rawValue, "theall.focusPrevPane")
        XCTAssertEqual(Notification.Name.theAllCopy.rawValue,          "theall.copy")
        XCTAssertEqual(Notification.Name.theAllPaste.rawValue,         "theall.paste")
        XCTAssertEqual(Notification.Name.theAllSelectAll.rawValue,     "theall.selectAll")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/NotificationNamesTests/testNewMenuNotificationRawValues 2>&1 | tail -20
```

Expected: **FAIL** — `Notification.Name` has no member `theAllFocusNextPane` (and friends); compile error from the test target.

- [ ] **Step 3: Add the 5 new Notification.Name constants**

In `TheAll/ContentView.swift`, locate the existing block:

```swift
extension Notification.Name {
    static let theAllBeginCreateWorkspace = Notification.Name("theall.beginCreateWorkspace")
    static let theAllNewTab               = Notification.Name("theall.newTab")
    static let theAllClosePane            = Notification.Name("theall.closePane")
    static let theAllSplitVertical        = Notification.Name("theall.splitVertical")
    static let theAllSplitHorizontal      = Notification.Name("theall.splitHorizontal")
    static let theAllSelectNextTab        = Notification.Name("theall.selectNextTab")
    static let theAllSelectPrevTab        = Notification.Name("theall.selectPrevTab")
    static let theAllSelectTabAtIndex     = Notification.Name("theall.selectTabAtIndex")
}
```

Append 5 new entries so the full block becomes:

```swift
extension Notification.Name {
    static let theAllBeginCreateWorkspace = Notification.Name("theall.beginCreateWorkspace")
    static let theAllNewTab               = Notification.Name("theall.newTab")
    static let theAllClosePane            = Notification.Name("theall.closePane")
    static let theAllSplitVertical        = Notification.Name("theall.splitVertical")
    static let theAllSplitHorizontal      = Notification.Name("theall.splitHorizontal")
    static let theAllSelectNextTab        = Notification.Name("theall.selectNextTab")
    static let theAllSelectPrevTab        = Notification.Name("theall.selectPrevTab")
    static let theAllSelectTabAtIndex     = Notification.Name("theall.selectTabAtIndex")

    // Pane focus navigation (also bound in the "Terminal" menu).
    static let theAllFocusNextPane        = Notification.Name("theall.focusNextPane")
    static let theAllFocusPrevPane        = Notification.Name("theall.focusPrevPane")

    // Edit menu → focused GhosttyTerminalView (routes to ghostty_surface_binding_action).
    static let theAllCopy                 = Notification.Name("theall.copy")
    static let theAllPaste                = Notification.Name("theall.paste")
    static let theAllSelectAll            = Notification.Name("theall.selectAll")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/NotificationNamesTests/testNewMenuNotificationRawValues 2>&1 | tail -20
```

Expected: **PASS** — "Test Suite 'NotificationNamesTests' passed".

- [ ] **Step 5: Commit**

```bash
git add TheAll/ContentView.swift TheAllTests/NotificationNamesTests.swift
git commit -m "feat(notifications): add menu-bar notification names for focus/copy/paste/select"
```

---

## Task 2: Add libghostty binding-action wrappers to GhosttyTerminalView

**Files:**
- Modify: `TheAll/Ghostty/GhosttyTerminalView.swift` (add a new `// MARK: - Binding actions` section)

The spec calls out that only `GhosttyTerminalView` and `GhosttyBridge` may directly call `ghostty_*` symbols (CLAUDE.md convention 2). Since these wrappers operate on a single surface, they belong on `GhosttyTerminalView`.

- [ ] **Step 1: Add the three binding-action methods**

In `TheAll/Ghostty/GhosttyTerminalView.swift`, add a new section just below the existing `// MARK: - Focus` block (after `resignFirstResponder()` ends near line 222). The exact insertion point is right before `// MARK: - Keyboard input`:

```swift
    // MARK: - Binding actions

    /// Invoke a ghostty binding-action DSL string on this surface.
    /// Returns false silently if the surface isn't ready or ghostty refused.
    @discardableResult
    private func runBindingAction(_ action: String) -> Bool {
        guard let s = surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(s, ptr, uintptr_t(action.utf8.count))
        }
    }

    /// Copy the current selection to the system clipboard.
    /// No-op (returns false) if there is no surface or no selection.
    @discardableResult
    func copySelection() -> Bool { runBindingAction("copy_to_clipboard") }

    /// Paste the system clipboard into the focused surface.
    @discardableResult
    func pasteClipboard() -> Bool { runBindingAction("paste_from_clipboard") }

    /// Select the entire scrollback contents.
    @discardableResult
    func selectAll() -> Bool { runBindingAction("select_all") }
```

- [ ] **Step 2: Build to verify compilation**

Run:
```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

If it fails with "cannot find 'ghostty_surface_binding_action' in scope", confirm the bridging header import in `TheAll/Ghostty/ghostty-bridging-header.h` includes `ghostty.h` (it should already, since the rest of the file uses ghostty symbols).

- [ ] **Step 3: Commit**

```bash
git add TheAll/Ghostty/GhosttyTerminalView.swift
git commit -m "feat(ghostty): wrap copy/paste/select-all binding actions on terminal view"
```

---

## Task 3: Wire new notifications in TabContentView

**Files:**
- Modify: `TheAll/TabContent/TabContentView.swift:248-275` (subscribe + handle)

The pattern already exists for the 7 existing menu notifications — we extend it for the 5 new names and add corresponding handlers that resolve the focused `GhosttyTerminalView` and call the wrappers from Task 2.

- [ ] **Step 1: Extend the subscription list**

Locate `subscribeNotifications()` at `TabContentView.swift:248` and replace the `names` array. Current:

```swift
private func subscribeNotifications() {
    let names: [Notification.Name] = [
        .theAllNewTab, .theAllClosePane,
        .theAllSplitVertical, .theAllSplitHorizontal,
        .theAllSelectNextTab, .theAllSelectPrevTab,
        .theAllSelectTabAtIndex,
    ]
    for name in names {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNotification(_:)), name: name, object: nil)
    }
}
```

New:

```swift
private func subscribeNotifications() {
    let names: [Notification.Name] = [
        .theAllNewTab, .theAllClosePane,
        .theAllSplitVertical, .theAllSplitHorizontal,
        .theAllSelectNextTab, .theAllSelectPrevTab,
        .theAllSelectTabAtIndex,
        .theAllFocusNextPane, .theAllFocusPrevPane,
        .theAllCopy, .theAllPaste, .theAllSelectAll,
    ]
    for name in names {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNotification(_:)), name: name, object: nil)
    }
}
```

- [ ] **Step 2: Extend the dispatch switch**

Locate `handleNotification(_:)` at `TabContentView.swift:261`. The current switch ends with:

```swift
case .theAllSelectTabAtIndex:
    if let idx = note.userInfo?["index"] as? Int { selectTab(at: idx) }
default: break
```

Add 5 new cases just before `default`:

```swift
@objc private func handleNotification(_ note: Notification) {
    // Ignore broadcasts targeting other windows when multiple workspaces are open.
    guard window?.isKeyWindow == true else { return }
    switch note.name {
    case .theAllNewTab:           addNewTab()
    case .theAllClosePane:        closeCurrentPane()
    case .theAllSplitVertical:    splitCurrentPane(direction: .vertical)
    case .theAllSplitHorizontal:  splitCurrentPane(direction: .horizontal)
    case .theAllSelectNextTab:    cycleTab(forward: true)
    case .theAllSelectPrevTab:    cycleTab(forward: false)
    case .theAllSelectTabAtIndex:
        if let idx = note.userInfo?["index"] as? Int { selectTab(at: idx) }
    case .theAllFocusNextPane:    focusAdjacentPane(forward: true)
    case .theAllFocusPrevPane:    focusAdjacentPane(forward: false)
    case .theAllCopy:             focusedTerminalView()?.copySelection()
    case .theAllPaste:            focusedTerminalView()?.pasteClipboard()
    case .theAllSelectAll:        focusedTerminalView()?.selectAll()
    default: break
    }
}
```

- [ ] **Step 3: Add the `focusedTerminalView()` helper**

Add a new helper method near the other private helpers (e.g., right after `selectTab(at:)` which ends around line 340):

```swift
/// Returns the currently focused pane's view, or nil if the workspace has no tab/pane.
/// Used by Edit-menu handlers to target the right surface.
private func focusedTerminalView() -> GhosttyTerminalView? {
    guard let tab = store?.selectedWorkspace?.selectedTab else { return nil }
    return terminalViews[tab.focusedTerminalId]
}
```

- [ ] **Step 4: Build to verify compilation**

Run:
```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add TheAll/TabContent/TabContentView.swift
git commit -m "feat(tabs): route focus/copy/paste notifications to focused terminal"
```

---

## Task 4: Narrow NSEvent monitor to vertical arrows

**Files:**
- Modify: `TheAll/TabContent/TabContentView.swift:344-355` (body of `installKeyMonitor`)

The current monitor captures all four arrow keys under `⌘⌥`. With Task 5 adding menu items for `⌘⌥→/←`, SwiftUI will catch those first — but we remove them from the monitor too so we don't rely on ordering. The monitor stays active for the vertical-arrow aliases (`⌘⌥↑` / `⌘⌥↓`), which are intentionally not shown in the menu (the spec has them as hidden duplicates).

- [ ] **Step 1: Replace the switch body in `installKeyMonitor()`**

Current:

```swift
private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self,
              event.modifierFlags.intersection([.command, .option]) == [.command, .option]
        else { return event }
        switch event.keyCode {
        case 124, 125: self.focusAdjacentPane(forward: true);  return nil  // → ↓
        case 123, 126: self.focusAdjacentPane(forward: false); return nil  // ← ↑
        default: return event
        }
    }
}
```

New:

```swift
private func installKeyMonitor() {
    // ⌘⌥→ and ⌘⌥← are now menu items (Terminal → Focus Next/Previous Pane),
    // so SwiftUI dispatches those via .theAllFocusNextPane / .theAllFocusPrevPane.
    // The monitor remains only for the ↑/↓ aliases — intentional hidden duplicates
    // not shown in the menu, kept because they're a common pane-nav habit.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self,
              event.modifierFlags.intersection([.command, .option]) == [.command, .option]
        else { return event }
        switch event.keyCode {
        case 125: self.focusAdjacentPane(forward: true);  return nil  // ↓
        case 126: self.focusAdjacentPane(forward: false); return nil  // ↑
        default: return event
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run:
```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add TheAll/TabContent/TabContentView.swift
git commit -m "refactor(tabs): narrow key monitor to vertical arrows only"
```

---

## Task 5: Rewrite the `.commands` block in TheAllApp.swift

**Files:**
- Modify: `TheAll/TheAllApp.swift` — replace the `.commands { ... }` body

This is the big cosmetic change: replace the old **Tab** menu with a new **Terminal** menu, add a minimal **Edit** pasteboard group, drop unused default command groups.

- [ ] **Step 1: Replace the `.commands { ... }` block**

Current body is at `TheAllApp.swift:21-76`. Replace the whole `.commands { ... }` closure with:

```swift
        .commands {
            // ── File ──────────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    post(.theAllBeginCreateWorkspace)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Strip default macOS items that don't apply to a terminal workspace app.
            CommandGroup(replacing: .saveItem)          { }  // Save / Save As / Revert / Page Setup / Print
            CommandGroup(replacing: .undoRedo)          { }  // Undo / Redo
            CommandGroup(replacing: .textEditing)       { }  // Find / Spelling
            CommandGroup(replacing: .textFormatting)    { }  // Substitutions / Transformations
            CommandGroup(replacing: .toolbar)           { }  // Show/Hide Toolbar / Customize Toolbar
            CommandGroup(replacing: .windowArrangement) { }  // NSWindow-tab items
            CommandGroup(replacing: .help) {
                Button("theall Help") {}.disabled(true)        // placeholder; removes default Search field
            }

            // ── Edit ──────────────────────────────────────────────────
            // Replace the default pasteboard group so we keep only the three items
            // that make sense for a terminal surface.
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { post(.theAllCopy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { post(.theAllPaste) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { post(.theAllSelectAll) }
                    .keyboardShortcut("a", modifiers: .command)
            }

            // ── Terminal ──────────────────────────────────────────────
            // Replaces the old "Tab" top-level menu. Four sections:
            //   1) Tab / pane creation
            //   2) Split
            //   3) Pane focus navigation
            //   4) Tab navigation
            CommandMenu("Terminal") {
                Button("New Tab") { post(.theAllNewTab) }
                    .keyboardShortcut("t", modifiers: .command)

                Button("Close Pane") { post(.theAllClosePane) }
                    .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Split Vertically (Left/Right)") { post(.theAllSplitVertical) }
                    .keyboardShortcut("d", modifiers: .command)

                Button("Split Horizontally (Top/Bottom)") { post(.theAllSplitHorizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Focus Next Pane") { post(.theAllFocusNextPane) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Focus Previous Pane") { post(.theAllFocusPrevPane) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Divider()

                Button("Select Next Tab") { post(.theAllSelectNextTab) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Select Previous Tab") { post(.theAllSelectPrevTab) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(1...9, id: \.self) { idx in
                    Button("Select Tab \(idx)") {
                        NotificationCenter.default.post(
                            name: .theAllSelectTabAtIndex,
                            object: nil,
                            userInfo: ["index": idx - 1])
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
                }
            }

            // ── Appearance ────────────────────────────────────────────
            CommandMenu("Appearance") {
                Button("Dark")          { themeManager.applyScheme(.dark) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Light")         { themeManager.applyScheme(.light) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Follow System") { themeManager.applyScheme(.system) }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
```

Keep the `private func post(_ name: Notification.Name)` helper below the `body` property exactly as it is.

- [ ] **Step 2: Build to verify compilation**

Run:
```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

Common failure modes:
- **"Cannot find '.saveItem' in scope"** — you're on a macOS deployment target that predates the placement; project.yml targets macOS 14+, so all placements used here are available. If you see this, check `project.yml` wasn't changed.
- **"Type '(Scene) -> some Scene' ambiguous"** — usually means one of the `CommandGroup { }` empty closures trips Swift's closure inference. Add `-> Void` on one of them to disambiguate.

- [ ] **Step 3: Commit**

```bash
git add TheAll/TheAllApp.swift
git commit -m "feat(menu): redesign menu bar — Terminal/Edit groups and strip unused defaults"
```

---

## Task 6: Run full test suite

**Files:** none modified

- [ ] **Step 1: Run the full theall test scheme**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` with `NotificationNamesTests` passing alongside all existing tests (WorkspaceStoreTests, ThemeManagerTests, HookMessageTests, etc.).

If any pre-existing test fails, it is not caused by this change (none of the modified files are covered by existing tests beyond notification-name presence). Stop and investigate before continuing.

- [ ] **Step 2: Commit a verification marker (only if nothing to commit)**

No commit needed. If tests were green and no file changed in this task, move on.

---

## Task 7: Manual smoke test

**Files:** none modified. This task is a human/agent verification pass — the spec's `R2` and `R4` risks can only be confirmed by actually running the app.

- [ ] **Step 1: Launch the Debug build**

```bash
./restart.sh
```

(The script lives at the repo root, not `scripts/`. Added in `ac745ea feat(restart): add script to clean, rebuild, and relaunch theall Debug app`. If it's gone or doesn't do what you expect, the manual form is `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build` followed by `open ~/Library/Developer/Xcode/DerivedData/.../TheAll.app`.)

- [ ] **Step 2: Walk the menu bar top-to-bottom**

Click each menu and verify its contents. Expected items only — if a surprise item appears, that's a residual default slot that needs another `CommandGroup(replacing:)` call or an AppDelegate `NSMenu` prune (see spec R2).

**theall (app menu):** About theall / Settings… (no-op default is fine) / Services / Hide / Hide Others / Show All / Quit theall. Don't modify.

**File:** only "New Workspace ⌘N". No Open, no Save, no Print.

**Edit:** only "Copy ⌘C", "Paste ⌘V", "Select All ⌘A". No Undo, no Find, no Spelling, no Substitutions, no Speech, no Start Dictation, no Emoji & Symbols.

> If "Start Dictation…" or "Emoji & Symbols" survives (macOS injects these late), add an `AppDelegate` that runs after launch and removes those `NSMenuItem`s by title from `NSApp.mainMenu?.item(withTitle: "Edit")?.submenu`. That's out of scope for this plan as an initial attempt, but tag it as a follow-up if needed.

**Terminal:** seven visible sections split by dividers:
```
New Tab                          ⌘T
Close Pane                       ⌘W
─
Split Vertically (Left/Right)    ⌘D
Split Horizontally (Top/Bottom)  ⌘⇧D
─
Focus Next Pane                  ⌘⌥→
Focus Previous Pane              ⌘⌥←
─
Select Next Tab                  ⌘⇧]
Select Previous Tab              ⌘⇧[
─
Select Tab 1  ⌘1
Select Tab 2  ⌘2
…
Select Tab 9  ⌘9
```

**Appearance:** Dark ⌘⇧1 / Light ⌘⇧2 / Follow System ⌘⇧0. Unchanged.

**View:** default entries including "Enter Full Screen" (`^⌘F`). No "Show Toolbar" / "Customize Toolbar".

**Window:** Minimize ⌘M / Zoom / Bring All to Front. No "Show Previous Tab" / "Show Next Tab" / "Move Tab to New Window".

**Help:** single disabled "theall Help" placeholder. No Search field.

- [ ] **Step 3: Functional checks — click each item once**

For each check, create a workspace with 2+ tabs and a split pane where needed.

1. **File → New Workspace** — sidebar adds a new workspace.
2. **Edit → Copy** after selecting terminal text with the mouse — clipboard contains that text (verify with `pbpaste` in another terminal).
3. **Edit → Paste** into a running `cat > /tmp/paste-test` — typed text appears once (not twice!). This is spec R4.
4. **Edit → Select All** — whole scrollback highlights; Copy afterward grabs everything.
5. **Terminal → New Tab** — new tab appears and is selected.
6. **Terminal → Close Pane** — current pane closes (or the tab closes if it's the last pane).
7. **Terminal → Split Vertically / Horizontally** — split happens, new pane gets focus.
8. **Terminal → Focus Next Pane / Focus Previous Pane** — focus cycles between panes.
9. **Terminal → Select Next Tab / Select Previous Tab / Select Tab N** — tab selection cycles or jumps.
10. **Appearance → Dark / Light / Follow System** — theme changes.

- [ ] **Step 4: Confirm no double-firing on Copy/Paste (spec R4)**

With terminal text selected, press `⌘C` once. Verify the clipboard was written exactly once — easiest way: open Console.app and filter by "theall" process while also watching for repeated pasteboard-write log lines, or just paste-and-inspect.

If you see evidence of double-copy (e.g., the clipboard history tool shows two consecutive identical entries), it means ghostty's internal keybind fired alongside the SwiftUI menu shortcut. Fix by overriding ghostty's default copy/paste keybinds — add to the `confContent` string in `GhosttyBridge.initialize()` (around `TheAll/Ghostty/GhosttyBridge.swift:48`):

```swift
let confContent = """
resources-dir = \(ghosttyDir)
shell-integration = detect
keybind = super+c=unbind
keybind = super+v=unbind
keybind = super+a=unbind
"""
```

Commit separately as `fix(ghostty): unbind super+c/v/a so menu shortcuts win cleanly`.

- [ ] **Step 5: Confirm `⌘⌥↑/↓` still moves focus**

With 2+ panes in a tab, press `⌘⌥↑` and `⌘⌥↓` — focus moves between panes. This verifies Task 4 didn't over-narrow the monitor.

- [ ] **Step 6: No commit for this task**

Manual verification only. If issues surface, fix and commit per normal practice.

---

## Self-review checklist (already completed)

- **Spec coverage:** Every item in the target menu structure (File, Edit, Terminal, Appearance, View, Window, Help) has a corresponding task or is explicitly "system default, don't modify". Focus-pane shortcuts moved out of the NSEvent monitor → Task 4 + Task 5. Copy/Paste/Select-All API wrappers → Task 2; routing → Task 3; menu items → Task 5. R1 (API shape) resolved at plan time: `ghostty_surface_binding_action(surface, const char*, uintptr_t)` confirmed against `Vendor/ghostty/include/ghostty.h:1151`. R2 (residual default items) surfaced in Task 7 Step 2 with remediation note. R3 (no focused terminal) handled by `focusedTerminalView()?.…` optional chaining in Task 3. R4 (double-fire) surfaced in Task 7 Step 4 with remediation recipe.

- **Placeholder scan:** No "TODO", "TBD", "similar to", or unspecified code blocks. Every code-touching step shows the code.

- **Type consistency:** `copySelection()` / `pasteClipboard()` / `selectAll()` method names identical in Task 2 declaration, Task 3 dispatch switch, and the design spec. Notification names identical across Task 1 test, Task 1 declaration, Task 3 subscriptions and dispatch, and Task 5 menu posts.

- **Out-of-scope creep:** The plan does not touch `project.yml`, Vendor, scripts, ghostty config (unless R4 remediation is needed), Model layer, or Canvas/Sidebar code. Matches the spec's "In scope" list.
