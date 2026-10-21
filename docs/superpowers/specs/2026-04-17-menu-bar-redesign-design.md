# Menu Bar Redesign

Date: 2026-04-17
Status: Approved — ready for implementation plan

## Goal

Surface every user-triggerable action in the macOS system menu bar so that keyboard shortcuts become discoverable as a side-effect. Remove default menu items that don't apply to theall.

The menu bar itself is the shortcut documentation — users scan the menus and see `⌘T`, `⌘D`, `⌘⌥→` next to the corresponding actions. No separate cheatsheet panel.

## Scope

### In scope
1. New top-level **Terminal** menu (replacing the current "Tab" menu), organized in four sections separated by dividers: Tab ops, Split, Focus navigation, Tab navigation.
2. Expose the currently-hidden `⌘⌥←/→/↑/↓` pane-focus shortcut as menu items (the two arrows; the ↑/↓ duplicates stay wired via `NSEvent` monitor but are not shown in the menu).
3. **Edit** menu: keep Copy / Paste / Select All only. Menu actions route through notifications to the focused `GhosttyTerminalView`, which calls into libghostty.
4. Clean up default **File / View / Window / Help** menus — remove items that don't apply to a terminal workspace app (Open, Save, Print, Toolbar, NSWindow tabs, Help search, etc.).
5. **Appearance** menu stays as-is — already well-formed.

### Out of scope (YAGNI)
- No cheatsheet / shortcut-overview panel — the menu bar IS the cheatsheet.
- No remapping of existing shortcuts. All current keys are kept.
- No Preferences window.
- No rewrite of ghostty's `keyDown` — existing per-key paths for Copy/Paste inside the terminal surface keep working. The menu is an additional entry point, not a replacement.

## Current state (baseline)

Defined in `TheAll/TheAllApp.swift`:

- **File** → `⌘N` New Workspace (replaces `.newItem`)
- **Tab** → New Tab (`⌘T`), Close Pane (`⌘W`), Split V (`⌘D`), Split H (`⌘⇧D`), Next/Prev Tab (`⌘⇧]` / `⌘⇧[`), Select Tab 1–9 (`⌘1`–`⌘9`)
- **Appearance** → Dark (`⌘⇧1`), Light (`⌘⇧2`), Follow System (`⌘⇧0`)

Hidden (only wired via `NSEvent.addLocalMonitorForEvents` in `TabContent/TabContentView.swift:344`):

- `⌘⌥←` / `⌘⌥↑` — focus previous pane
- `⌘⌥→` / `⌘⌥↓` — focus next pane

Notification names are defined at the bottom of `TheAll/ContentView.swift` (`.theAllNewTab`, `.theAllClosePane`, `.theAllSplitVertical`, `.theAllSplitHorizontal`, `.theAllSelectNextTab`, `.theAllSelectPrevTab`, `.theAllSelectTabAtIndex`, `.theAllBeginCreateWorkspace`).

Default SwiftUI menus (File/Edit/View/Window/Help) ship with many items irrelevant to theall (Open/Save/Print/Find/Spelling/Toolbar/NSWindow tabs/Help search).

## Target menu structure

### App menu (theall)
Default — About / Services / Hide / Quit all retained.

### File
- **New Workspace** `⌘N` (unchanged)
- Remove: Open, Open Recent, Close, Save, Save As, Revert, Page Setup, Print.

### Edit
- **Copy** `⌘C`
- **Paste** `⌘V`
- **Select All** `⌘A`
- Remove: Undo, Redo, Cut, Delete, Find, Spelling, Substitutions, Transformations, Speech, Start Dictation, Emoji & Symbols.

### Terminal (new top-level, replaces "Tab")

```
New Tab                          ⌘T
Close Pane                       ⌘W
───────────────────────────────
Split Vertically (Left/Right)    ⌘D
Split Horizontally (Top/Bottom)  ⌘⇧D
───────────────────────────────
Focus Next Pane                  ⌘⌥→
Focus Previous Pane              ⌘⌥←
───────────────────────────────
Select Next Tab                  ⌘⇧]
Select Previous Tab              ⌘⇧[
Select Tab 1…9                   ⌘1…⌘9
```

Notes:
- Only `⌘⌥→` / `⌘⌥←` appear in the menu. The `⌘⌥↓` / `⌘⌥↑` aliases remain active through the `NSEvent` monitor but are not shown (avoids visually duplicating the same action).
- "Pane" vs "Tab" wording is preserved — a tab contains a split tree of panes.

### Appearance
Unchanged: Dark `⌘⇧1` / Light `⌘⇧2` / Follow System `⌘⇧0`.

### View
- Keep system default **Enter Full Screen** (`^⌘F`).
- Remove: Show/Hide Toolbar, Customize Toolbar (we use `.windowStyle(.hiddenTitleBar)`).

### Window
- Keep system defaults: Minimize (`⌘M`), Zoom, Bring All to Front.
- Remove: Show Previous/Next Tab and NSWindow-tab items — theall manages its own tabs; the NSWindow-level versions would mislead users.

### Help
- Remove default Search field.
- Keep the top-level Help menu (macOS requires it); single disabled "theall Help" placeholder inside.

## Implementation plan (high level)

### A. `TheAll/TheAllApp.swift`
Add `CommandGroup(replacing: ...)` calls to strip unused groups and add the new Terminal menu:

```swift
.commands {
    CommandGroup(replacing: .newItem)          { /* New Workspace */ }
    CommandGroup(replacing: .saveItem)         { }  // clears Save/Save As/Revert/Page Setup/Print
    CommandGroup(replacing: .undoRedo)         { }  // clears Undo/Redo
    CommandGroup(replacing: .pasteboard)       { /* Copy / Paste / Select All */ }
    CommandGroup(replacing: .textEditing)      { }  // clears Find/Spelling
    CommandGroup(replacing: .textFormatting)   { }  // clears Substitutions/Transformations
    CommandGroup(replacing: .toolbar)          { }  // clears Toolbar items
    CommandGroup(replacing: .windowArrangement){ }  // clears NSWindow-tab items
    CommandGroup(replacing: .help)             { Button("theall Help") {}.disabled(true) }

    CommandMenu("Terminal")   { /* Tab / Split / Focus / Tab-nav sections */ }
    CommandMenu("Appearance") { /* unchanged */ }
}
```

### B. `TheAll/ContentView.swift`
Add 5 new notification names:

```swift
static let theAllFocusNextPane = Notification.Name("theall.focusNextPane")
static let theAllFocusPrevPane = Notification.Name("theall.focusPrevPane")
static let theAllCopy          = Notification.Name("theall.copy")
static let theAllPaste         = Notification.Name("theall.paste")
static let theAllSelectAll     = Notification.Name("theall.selectAll")
```

### C. `TheAll/TabContent/TabContentView.swift`
1. `subscribeNotifications()`: add the 5 new names.
2. `handleNotification(_:)`: dispatch 5 new cases.
3. Narrow `installKeyMonitor()` to only the vertical arrows (keycodes `125` ↓ / `126` ↑). The menu's `⌘⌥→/←` shortcuts handle the horizontal arrows via the SwiftUI path, so keeping them in the monitor would risk double-firing (monitor fires before menu-shortcut matching on some macOS versions).
4. Add handlers that resolve the currently focused `GhosttyTerminalView` and call the three new clipboard/selection methods.

### D. `TheAll/Ghostty/GhosttyBridge.swift` + `GhosttyTerminalView.swift`
Add three methods on `GhosttyTerminalView`, thin wrappers over libghostty:

```swift
func copySelection()
func pasteClipboard()
func selectAll()
```

Prefer `ghostty_surface_binding_action` with the `.copy_to_clipboard` / `.paste_from_clipboard` / `.select_all` action enum if the vendored header exposes it. Exact symbol names are confirmed during plan-writing against `Vendor/ghostty/include/ghostty.h`. Fallback: synthesize an `NSEvent` for the matching key combo and dispatch it into the focused surface — functionally equivalent.

### E. Verification
- `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build` succeeds.
- Manual smoke:
  - Click each item in File / Edit / Terminal / Appearance / View / Window / Help once; verify correct action runs and no surprise items appear.
  - Copy via menu produces same clipboard contents as `⌘C` inside the terminal (no double-copy).
  - Paste via menu pastes once (not twice).
  - `⌘⌥←/→` and `⌘⌥↑/↓` all switch panes correctly; menu shows only the `←/→` pair.
  - Full-screen still works from View menu.

## Risks & open questions

**R1 · ghostty binding-action API shape** — the exact symbol used for Copy/Paste/Select-All binding actions in the current vendored libghostty header is confirmed during plan-writing. Fallback is NSEvent synthesis if the API differs from expectation.

**R2 · CommandGroup replacement coverage** — SwiftUI's `CommandGroupPlacement` cases (`.saveItem`, `.pasteboard`, `.undoRedo`, `.textEditing`, `.textFormatting`, `.toolbar`, `.windowArrangement`, `.help`) cover most default items but not every macOS version is identical. Residual items like "Start Dictation…" or "Emoji & Symbols" may survive; verify during manual testing and, if needed, add an AppDelegate hook that prunes the remaining `NSMenuItem`s by title.

**R3 · Edit menu with no focused terminal** — when a workspace has no tab/pane, Copy/Paste/Select All handlers guard with `selectedWorkspace?.selectedTab` and return silently. Menu items stay enabled (graying them would need `@FocusedValue` plumbing that isn't worth the complexity for a one-shot fallthrough).

**R4 · `.keyboardShortcut` vs ghostty's `keyDown`** — once Copy/Paste/Select-All appear in the menu with shortcuts, SwiftUI intercepts `⌘C/⌘V/⌘A` before ghostty's `keyDown`. This is the desired unified path (menu → Notification → `GhosttyTerminalView`). Manual verification must confirm ghostty's built-in keybinds don't fire a second time (would cause double-copy or double-paste). If they do, disable them in the ghostty config emitted by `GhosttyBridge`.

## Non-goals / won't-do

- No Preferences window.
- No cheatsheet / overlay.
- No remapping of existing shortcuts.
- No gray-state Edit items when no terminal is focused.
- No internationalization of menu titles (English only, matches current state).
