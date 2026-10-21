---
date: 2026-04-19
topic: Status indicators as opt-in beta toggle
status: draft
---

# Status Indicators — Beta Toggle

## Background

The shell-side exit-code wiring (2026-04-19 spec #1) and agent-turn-status feature (2026-04-19 spec #2) landed per-terminal running/success/failed/needsInput icons in the sidebar workspace rows and the tab bar. A Claude hook-coverage gap surfaced during manual verification: in `--dangerously-skip-permissions` mode, safety-blocked tools leave the state stuck on `running` until the next UserPromptSubmit, because no Stop / PostToolUse / Notification hook fires in that window.

Rather than hacking a client-side staleness heuristic to cover the gap, gate the entire status-indicator display behind an opt-in setting defaulting to off. Users who want the indicators can enable them; everyone else gets the pre-feature UX back. Marks the feature as "Beta" to set expectations about the remaining edge cases.

## Goals

- Add a settings toggle labeled "Status Indicators (Beta)" in the Terminal section of Settings.
- Default OFF — fresh install / existing users without the key see no status icons in sidebar or tab bar.
- Reactive: flipping the toggle shows/hides icons immediately without app restart.
- When OFF: collapse the icon's layout slot (text shifts left where the icon used to sit) — distinguishes "off" from "on but stale".
- Hook pipeline (socket listener, agent-hook.sh, agent-sessions.json, wrappers) keeps running regardless of toggle state. Only UI rendering is gated.

## Non-Goals

- Hiding the toggle itself from Settings UI once enabled (it stays visible so users can turn it off again).
- Disabling the env-var injection (`THEALL_HOOK_SOCK`, `THEALL_TERMINAL_ID`) that feeds the hooks. Those stay on always.
- Killing the Unix socket listener process when off. It keeps receiving events — just nobody renders them.
- Per-terminal overrides (e.g. "show icons for Claude but not shell"). One global toggle covers v1.
- Migration of existing user configs: users with the feature effectively turned on already (by virtue of running the previous builds) will see icons disappear on next launch. This is the intended reset; the beta toggle starts fresh.
- Staleness / watchdog / `.running → .needsInput` auto-degrade to work around Claude's bypass-mode hook gap — deferred to a separate spec if the beta toggle + documentation isn't enough.

## Config Schema

**Key:** `theall-status-indicators`
**Values:** `"true"` | `"false"` | missing → treated as `"false"`
**File:** `~/Library/Application Support/theall/config` (existing theall config file)
**Default behavior when key absent:** OFF (no icons). No migration step, no default value written on first launch.

Key naming follows the existing `theall-content-opacity` / `theall-default-cursor-style-blink` pattern (kebab-case, `theall-` prefix to avoid collision with ghostty-native keys).

## Settings UI

**Location:** `TheAll/Settings/Sections/TerminalSectionView.swift`, inserted as the **first** control in the `Form`, above `scrollback-limit`.

**Control:**

```swift
BoundToggle(
    settings: settings,
    key: "theall-status-indicators",
    defaultValue: false,
    label: "Status Indicators (Beta)"
)
```

The existing `BoundToggle` component already handles string-value persistence (`"true"` / absent). No new component needed.

**Visual beta indicator:** the `(Beta)` suffix in the label is sufficient. No orange pill / colored badge in v1 — keep visual weight low.

**Reset integration:** add `"theall-status-indicators"` to `managedKeys` in `TerminalSectionView.swift` so "Reset Terminal settings" resets it to default (false).

## Propagation Path

The toggle state is a `Bool` derived from `settingsStore.get("theall-status-indicators") == "true"`. It must reach two AppKit views:

1. **`WorkspaceListView`** (sidebar per-workspace row icon — `TerminalStatus.aggregate(...)` rendered on each row)
2. **`TabBarView`** (per-tab icon at the tab's `statusIcon: TerminalStatusIconView` subview — `TabBarView.swift:330`)

Both are accessed via bridges from `ContentView`:

- `SidebarListBridge` (NSViewRepresentable) → `WorkspaceListView`
- `TabBridge` (NSViewRepresentable) → `TabContentView` → `TabBarView`

**ContentView changes:**

```swift
// Computed from settings — reactively recomputes on @Observable changes.
private var showStatusIndicators: Bool {
    settingsStore.get("theall-status-indicators") == "true"
}

// In the body, pass to both bridges:
SidebarListBridge(
    store: store,
    statusStore: statusStore,
    theme: ...,
    metadata: ...,
    metadataTick: ...,
    backgroundOpacity: ...,
    showStatusIndicators: showStatusIndicators,   // NEW
    onRequestDelete: { ... }
)

TabBridge(
    store: store,
    statusStore: statusStore,
    ...,
    showStatusIndicators: showStatusIndicators,   // NEW
    ...
)
```

**Bridge changes:**

Each bridge struct adds a `showStatusIndicators: Bool` property and forwards it to the NSView's update method.

**NSView changes:**

Each of `WorkspaceListView.update(...)` and `TabContentView.loadWorkspace(...)` / `TabBarView`'s per-tab layout receives the Bool and either:
- Adds/removes the icon subview, **or**
- Sets `isHidden` on the icon + collapses the layout slot

The collapse semantics (required — per Q2 "collapse layout" decision) mean the layout code must conditionally include or exclude the icon's width from the row/tab frame math. See Implementation Details below for the specific layout computations.

## Implementation Details per View

### `WorkspaceListView` (sidebar)

Per-workspace row currently shows `[aggregated-status-icon] [workspace-name] [metadata]`. When `showStatusIndicators == false`:
- Don't add the `TerminalStatusIconView` subview (or set `isHidden = true` AND `widthAnchor == 0`)
- Shift the workspace-name leading anchor by `TerminalStatusIconView.size + spacing` to the left (or use a stackview that naturally collapses zero-width hidden subviews)

Recommended: use `isHidden = true` + a conditional constraint so SwiftUI / AppKit auto-layout handles collapse. If the row is hand-laid-out (frame math), pass the flag into the layout function and branch the `x` origin.

### `TabBarView` (per-tab)

Tab cell has `statusIcon: TerminalStatusIconView` at `TabBarView.swift:330`. Current layout (at line ~402) computes `iconSize` and positions the label after the icon. Gate:
- `statusIcon.isHidden = !showStatusIndicators`
- In the layout function, if `!showStatusIndicators`, set `iconSize = 0` so the label's leading origin starts at the tab's leading edge.

### `TerminalStatusIconView` itself

No changes. The icon view stays a dumb NSView. All gating happens one level up.

## Reactive Update Flow

1. User toggles in Settings → `BoundToggle` writes `"true"` / `"false"` to `SettingsConfigStore`
2. `SettingsConfigStore.set(...)` debounces 200ms → write to disk + invokes `onChange` callback
3. `onChange` in `ContentView` already refreshes theme / reload config / etc. Status-indicator update piggybacks on the same trigger **automatically** because `showStatusIndicators` is a computed property on `@Observable` storage.

Wait — `SettingsConfigStore` is `@Observable`. SwiftUI views that read `settingsStore.get(...)` participate in the observation graph and re-render when `lines` changes (since `get` reads `lines`). ContentView's body re-evaluates, passes the new `showStatusIndicators` Bool to bridges, which trigger `updateNSView`, which calls `view.update(showStatusIndicators: ...)`, which updates icon visibility.

**No extra onChange wiring needed** — @Observable + NSViewRepresentable.updateNSView does the dance.

## Hook Infrastructure (Unchanged)

- `HookSocketListener` starts at app launch and runs regardless of setting
- `claude-wrapper.sh` / `codex-wrapper.sh` / `opencode-plugin/theall-status.js` always inject/run
- `agent-hook.sh` / `agent-hook.py` / `agent-sessions.json` all continue to function
- `TerminalStatusStore` still receives and stores updates via `setRunning` / `setFinished` etc.

Only the final render step (WorkspaceListView / TabBarView adding `TerminalStatusIconView` subviews) is gated.

Consequence: when the user flips the toggle from OFF → ON mid-session, icons immediately reflect the current state of `TerminalStatusStore`. No ramp-up period.

## Testing

### New Swift tests

In `TheAllTests/SettingsConfigStoreTests.swift` (extend existing):
- `testStatusIndicatorsDefaultFalse` — fresh store returns nil for the key
- `testStatusIndicatorsRoundtrip` — set `true`, get `true`

In `TheAllTests/SidebarListBridgeTests.swift` (extend existing):
- `testShowStatusIndicatorsFlagPropagates` — if feasible with NSViewRepresentable; otherwise a unit test on `WorkspaceListView.update(showStatusIndicators: false)` asserting the status-icon subview is hidden / has zero width

A new `TheAllTests/TabBarViewTests.swift` may be needed if none exists. Keep scope minimal — verify the Bool threads through to layout, don't reimplement layout tests.

### Manual verification

1. Fresh launch: no icons anywhere. Toggle off by default.
2. Settings → Terminal → flip "Status Indicators (Beta)" to ON. Icons appear immediately on all terminals (current state of store reflects).
3. Run `true` in a shell, watch icon transition: neverRan → running → success (green dot).
4. Flip toggle to OFF: icons disappear instantly, row layout collapses (text shifts left).
5. Flip back to ON: icons reappear with current state preserved.
6. Restart app: toggle state persists, icons render per saved value.
7. Sidebar workspace row aggregated icon also follows the flag (not just per-tab).

## Edge Cases

| Case | Behavior |
|------|----------|
| User sets key to `"1"` / `"yes"` / other truthy strings | Treated as OFF (only exact `"true"` enables). Documented. |
| Config file corrupt / missing | Key absent → OFF. Normal fallback. |
| Toggle flipped while an agent turn is mid-flight | Icons reflect current `TerminalStatus` from store when re-enabled; no replay / backfill needed. |
| Tab created while indicators OFF | Layout excludes icon slot from the start. Flipping ON adds the slot and re-lays-out. |
| User runs old agent wrapper expecting icons | Wrapper still emits to socket; listener still receives; only UI render gated. No regression for hook-generating code. |

## File Map

**Modify:**
- `TheAll/Settings/Sections/TerminalSectionView.swift` — add BoundToggle at top, extend `managedKeys`
- `TheAll/ContentView.swift` — add computed `showStatusIndicators`, pass to both bridges
- `TheAll/Bridge/SidebarListBridge.swift` — add property + forward to `WorkspaceListView.update`
- `TheAll/Bridge/TabBridge.swift` — add property + forward to `TabContentView.loadWorkspace` or a dedicated update method
- `TheAll/Sidebar/WorkspaceListView.swift` — accept the flag, gate icon subview + layout
- `TheAll/TabContent/TabBarView.swift` — accept the flag (via TabContentView or directly), gate icon subview + `iconSize = 0`
- `TheAll/TabContent/TabContentView.swift` — thread the flag through to TabBarView instances

**Modify (tests):**
- `TheAllTests/SettingsConfigStoreTests.swift` — add default + roundtrip tests for the new key
- `TheAllTests/SidebarListBridgeTests.swift` — add flag-propagation test (if feasible)

**New:** none unless a new test file is cheaper than extending an existing one.

**Not touched:**
- `TerminalStatusIconView.swift` — stays as-is
- `HookSocketListener.swift` / `TerminalStatusStore.swift` / `HookMessage.swift` — stays as-is
- `Resources/agent-hooks/*` — stays as-is
- `docs/agent-hooks.md` — existing content accurate; will reference the toggle in the next update if needed

## Implementation Order

1. Add BoundToggle + key in `TerminalSectionView.swift` + extend `managedKeys`; add SettingsConfigStore tests. Verify config persistence via test.
2. Add `showStatusIndicators: Bool` to `SidebarListBridge` + plumb into `WorkspaceListView.update`. Gate icon in WorkspaceListView. Verify via manual inspection: toggle off → sidebar rows lose icons.
3. Add same to `TabBridge` + plumb into `TabContentView.loadWorkspace` + `TabBarView`. Gate icon in TabBarView. Verify: toggle off → tab titles lose icons.
4. ContentView computes `showStatusIndicators` from `settingsStore`, passes to both bridges.
5. Full regression test pass + manual smoke per matrix above.

Each step ships its own commit.

## Completion Criteria

- Toggle visible in Settings → Terminal, default OFF
- Existing theall config files without the key → icons hidden on next launch
- Flipping ON live shows icons immediately; OFF hides them immediately
- Hook infrastructure keeps running regardless
- All existing tests still green; new tests green
- No Swift file outside the File Map modified
