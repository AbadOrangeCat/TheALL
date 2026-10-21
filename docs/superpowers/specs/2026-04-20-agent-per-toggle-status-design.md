# Per-Agent Status Indicators — Design

**Date**: 2026-04-20
**Status**: Approved (brainstorming complete)
**Supersedes**: `2026-04-19-status-indicators-beta-toggle-design.md` — the single master toggle is replaced by per-agent toggles.

## 1. Problem & Goals

The current status indicator pipeline has one master toggle (`theall-status-indicators`) and treats all four sources (shell + three code agents) uniformly. Shell preexec/precmd floods the socket with a running/idle event pair on every prompt cycle, and the master toggle gives users no way to opt into only the signal they care about: code agent progress.

**Goals**

1. Remove shell from the status indicator pipeline entirely. Shell scripts, enum case, tooltip branches — all gone.
2. Let the user enable Claude Code / Codex / OpenCode **independently**. No master switch.
3. Host the new controls in a dedicated Settings section called **Agents**, between Shell and Update.
4. Architecture stays open to a 4th+ code agent: new agent = new `HookMessage.Agent` enum case + new i18n key + new wrapper script. Zero plumbing changes in Swift beyond the enum.

**Non-goals**

- Retroactive display when a toggle flips ON mid-turn (events during OFF are dropped and never recovered).
- Migration of the old `theall-status-indicators` key. Users who had it set to `true` will see all three new toggles default to OFF and can re-enable; the dangling line in their config file is harmless.
- Runtime (hot) reconfiguration of which agents exist — still compile-time.

## 2. Architecture Overview

```
agent wrapper (claude/codex/opencode)
      │
      ▼ writes JSON lines
Unix socket  ~/Library/Caches/theall/hooks.sock
      │
      ▼
HookSocketListener.onMessage
      │
      │  ── NEW: reads per-agent toggle from SettingsConfigStore,
      │          drops events whose agent is disabled
      ▼
TerminalStatusStore     (only enabled agents leave a trace)
      │
      ▼
Sidebar / Tab bar views
      ▲
      │  showStatusIndicators (master UI gate) is now
      │  derived: any agent toggle == true
```

### Key design decisions

| Decision | Choice |
|----------|--------|
| Filter location | Listener layer (single choke point; store only sees enabled agents) |
| Master UI gate | Keep `showStatusIndicators` plumbing; change its derivation to "any agent enabled" |
| Old key migration | None; old key ignored, new keys default OFF |
| Shell cleanup depth | Full: delete scripts, remove enum case, clean TerminalStatus / IconView branches |
| Extensibility | Data-driven from `HookMessage.Agent.allCases` |

## 3. Data Model

### `TheAll/Models/HookMessage.swift`

```swift
enum Agent: String, Decodable, CaseIterable {
    case claude
    case opencode
    case codex
    // `.shell` removed.

    /// Config key used by Settings → Agents and the listener filter.
    var settingsKey: String { "theall-agent-status-\(rawValue)" }

    /// Localized label for the Agents settings row.
    var label: LocalizedStringResource {
        switch self {
        case .claude:   return L10n.Settings.Agents.claude
        case .codex:    return L10n.Settings.Agents.codex
        case .opencode: return L10n.Settings.Agents.opencode
        }
    }
}
```

`displayName` (already present, used in icon tooltip) remains.

### `TheAll/Models/TerminalStatus.swift`

Drop the `agent: HookMessage.Agent = .shell` default on both success and failed cases:

```swift
case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
             agent: HookMessage.Agent, summary: String? = nil)
case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
            agent: HookMessage.Agent, summary: String? = nil)
```

### `TheAll/Models/TerminalStatusStore.swift`

Same: drop `agent: HookMessage.Agent = .shell` default on `setFinished`.

### Config keys

New, all default absent (→ treated as `"false"`):

- `theall-agent-status-claude`
- `theall-agent-status-codex`
- `theall-agent-status-opencode`

Removed from code paths (not physically stripped from user config files):

- `theall-status-indicators`

## 4. Listener Filter

### `TheAll/ContentView.swift` — `onMessage` closure

Wrap the existing dispatch in an `agent` gate:

```swift
listener.onMessage = { [weak settingsStore = self.settingsStore] msg in
    guard settingsStore?.get(msg.agent.settingsKey) == "true" else { return }
    switch msg.event {
    case .running:
        store.setRunning(terminalId: msg.terminalId,
                         at: msg.timestamp,
                         detail: msg.toolDetail)
    case .idle:
        store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
    case .needsInput:
        store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
    case .finished:
        guard let ec = msg.exitCode else { return }
        store.setFinished(terminalId: msg.terminalId, exitCode: ec,
                          at: msg.timestamp, agent: msg.agent,
                          summary: msg.summary)
    }
}
```

**Thread / observation notes**: the closure runs on the listener's main-hop (already the case), outside any SwiftUI view `body`, so reading `@Observable` storage does not inject the closure into the observation graph. No spurious re-renders.

**Decode robustness**: after removing `.shell` from the enum, any stray old shell wrapper still emitting `"agent":"shell"` produces a JSONDecoder failure. `HookSocketListener.flushBuffer` already silently drops decode failures — no code change needed there.

## 5. UI — Settings → Agents

### `TheAll/Settings/SettingsSection.swift`

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case font
    case terminal
    case shell
    case agents        // NEW
    case update

    var label: LocalizedStringResource {
        switch self {
        case .appearance: return L10n.Settings.sectionAppearance
        case .font:       return L10n.Settings.sectionFont
        case .terminal:   return L10n.Settings.sectionTerminal
        case .shell:      return L10n.Settings.sectionShell
        case .agents:     return L10n.Settings.sectionAgents     // NEW
        case .update:     return L10n.Settings.sectionUpdate
        }
    }
}
```

### `TheAll/Settings/Sections/AgentsSectionView.swift` (new file)

```swift
import SwiftUI

struct AgentsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static var managedKeys: [String] {
        HookMessage.Agent.allCases.map(\.settingsKey)
    }

    var body: some View {
        Form {
            ForEach(HookMessage.Agent.allCases, id: \.rawValue) { agent in
                BoundToggle(
                    settings: settings,
                    key: agent.settingsKey,
                    defaultValue: false,
                    label: agent.label
                )
            }
            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

### `TheAll/Settings/SettingsView.swift`

Extend the `sectionBody` switch:

```swift
case .agents: AgentsSectionView(theme: theme, settings: settings)
```

### `TheAll/Settings/Sections/TerminalSectionView.swift`

Remove the `theall-status-indicators` BoundToggle and strip the same string from `managedKeys`.

## 6. UI — Master Gate Derivation & Tooltip Cleanup

### `TheAll/ContentView.swift`

Change the derivation:

```swift
/// Master UI gate for status icons. True iff the user has enabled at least one
/// agent in Settings → Agents. Derived from per-agent keys so the sidebar/tab
/// icon column collapses entirely when the feature is unused.
private var showStatusIndicators: Bool {
    HookMessage.Agent.allCases.contains { agent in
        settingsStore.get(agent.settingsKey) == "true"
    }
}
```

No changes to downstream bridges or AppKit views — `showStatusIndicators: Bool` plumbing stays intact.

### `TheAll/Theme/TerminalStatusIconView.swift` — tooltip

Collapse the shell branches in `tooltipText(for:)`:

```swift
case .success(_, let duration, _, let agent, let summary):
    let prefix = "\(agent.displayName): turn finished · \(Self.formatDuration(duration))"
    return summary.map { "\(prefix)\n\($0)" } ?? prefix

case .failed(_, let duration, _, let agent, let summary):
    let prefix = "\(agent.displayName): turn had tool errors · \(Self.formatDuration(duration))"
    return summary.map { "\(prefix)\n\($0)" } ?? prefix
```

`exitCode` and `finishedAt` are no longer surfaced in the tooltip — agent turns use sentinel 0/1 exit values that aren't informative on their own, and `finishedAt` was only ever used for state reconciliation, not display.

## 7. Shell Pipeline Removal (Option C)

### Files to delete

- `Resources/agent-hooks/shell-hooks.zsh`
- `Resources/agent-hooks/shell-hooks.bash`
- `Resources/agent-hooks/shell-hooks.fish`

### Files to edit

`Resources/agent-hooks/bootstrap.zsh` — remove the line:

```bash
source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.zsh"
```

Same for `bootstrap.bash` and `bootstrap.fish`. The `agent-functions.*` source line stays (it provides the claude/codex/opencode command wrappers).

### `project.yml`

If resources are enumerated file-by-file (not by directory glob), delete the three shell-hooks entries. Most project files use a glob — verify before editing.

### Swift-side grep & cleanup

All references to the following must disappear:

- `HookMessage.Agent.shell` / `\.shell\b` (code sites)
- `agent == .shell` / `agent != .shell` (branch guards)
- JSON literal `"shell"` in tests

### Test fixtures

- `Resources/agent-hooks/tests/smoke.sh` — strip shell-hooks assertions, keep the three agent smokes
- `Resources/agent-hooks/tests/test_agent_hook.py` — same
- `TheAllTests/*` — see §9

### User-side impact

- Old user configs with `theall-status-indicators = ...` keep that line on disk; parser preserves unknown KVs and never reads it.
- User rc files source `$THEALL_AGENT_HOOKS_DIR/bootstrap.*` unchanged. The next app launch installs a bootstrap that no longer enables shell hooks.
- Users who had status icons enabled will see them disappear until they flip an agent toggle in Settings → Agents.

## 8. i18n & Documentation

### `TheAll/Localization/Localizable.xcstrings`

**Add (en + zh-Hans)**:

| Key | en | zh-Hans |
|-----|----|---------|
| `settings.section.agents` | Agents | Agents |
| `settings.agents.claude` | Claude Code | Claude Code |
| `settings.agents.codex` | Codex | Codex |
| `settings.agents.opencode` | OpenCode | OpenCode |

Product names remain English in zh-Hans — matches existing convention (Claude / OpenCode / Codex are brand names).

**Remove**:

- `settings.terminal.statusIndicators`

### `TheAll/Localization/L10n.swift`

Add:

```swift
static let sectionAgents = LocalizedStringResource("settings.section.agents")

enum Agents {
    static let claude   = LocalizedStringResource("settings.agents.claude")
    static let codex    = LocalizedStringResource("settings.agents.codex")
    static let opencode = LocalizedStringResource("settings.agents.opencode")
}
```

Remove `Settings.Terminal.statusIndicators`.

### `CLAUDE.md` / `AGENTS.md`

Add `AgentsSectionView.swift` under the `Settings/Sections/` listing in the Directory Structure. No other changes required (Common Tasks "新增设置项" already covers the flow).

### `docs/agent-hooks.md`

- "各 Agent 的信号来源" table: remove the Shell row
- IPC section JSON schema: `"agent": "shell|claude|opencode|codex"` → `"agent": "claude|opencode|codex"`
- Add a one-line note: "shell 状态在 2026-04 后不再作为独立状态源，见 decisions/004-shell-out-of-status-pipeline.md"

### `docs/settings-reference.md`

- Remove `theall-status-indicators` row
- Add three rows: `theall-agent-status-claude` / `-codex` / `-opencode`, type bool, default false, description "启用该 agent 的状态图标（Settings → Agents 同步）"
- Add a short note: "新增 agent 通过 `HookMessage.Agent` 枚举自动派生新 key。"

### `docs/decisions/004-shell-out-of-status-pipeline.md` (new)

Record the decision:

- **Context**: Shell preexec/precmd emits a running/idle pair on every prompt cycle, producing low-signal noise that drowned the status indicator's purpose (agent progress).
- **Decision**: Shell leaves the status indicator pipeline entirely. Three code agents (Claude / Codex / OpenCode) become the only status sources, each independently toggleable in Settings → Agents.
- **Consequences**: Socket traffic drops by roughly one event-pair per prompt; shell integration code simplified; users who relied on shell icons must adapt. Extensibility path (new agents = enum case + wrapper) preserved.

### `scripts/check-doc-drift.sh`

Only watches `TheAll/` directory structure. Should pass once `AgentsSectionView.swift` is listed in CLAUDE.md/AGENTS.md. Deletions in `Resources/` are not tracked by it.

## 9. Testing

### New / extended tests

Conventionally `TheAllTests/` uses one test file per SUT; extend existing files where there is a natural home, only add a new file when the SUT is itself new.

**Extend `TheAllTests/HookMessageTests.swift`**

- `testAgentAllCasesExcludesShell` — `HookMessage.Agent.allCases` has exactly 3 cases (claude / codex / opencode); none is `.shell`.
- `testAgentSettingsKeyFormat` — each case's `settingsKey` equals `"theall-agent-status-\(rawValue)"`.
- `testShellAgentDecodeFails` — decoding `{"agent":"shell", …}` JSON returns nil (defensive / compatibility guard).

**New `TheAllTests/AgentsSectionViewTests.swift`**

- `testManagedKeysCoversAllAgents` — `AgentsSectionView.managedKeys.count == HookMessage.Agent.allCases.count` and every key starts with `theall-agent-status-`.
- `testDefaultsAllOff` — with a fresh SettingsConfigStore (tmp file), each agent key reads nil.
- `testResetRowStripsAgentKeys` — after setting all three keys to `"true"` and calling the reset action, all three read nil again.

**New `TheAllTests/StatusIndicatorGateTests.swift`**

Subject-under-test is a small static helper extracted from `ContentView.showStatusIndicators` — put the derivation in a pure function `static func anyAgentEnabled(_ settings: SettingsConfigStore) -> Bool` so it's unit-testable without a SwiftUI view.

- `testGateFalseWhenAllAgentsOff`
- `testGateTrueWhenAnyAgentOn` — table-driven over all seven "≥ 1 on" combinations (3 singles + 3 pairs + 1 triple).

**Extend `TheAllTests/HookSocketListenerTests.swift`**

Extract the `ContentView` onMessage closure into a pure function `func dispatchHookMessage(_ msg: HookMessage, settings: SettingsConfigStore, store: TerminalStatusStore)` placed in a testable module location (e.g. a free function in `HookMessage.swift` or a static on `TerminalStatusStore`). Tests then bypass sockets entirely.

- `testDispatchAgentOnForwardsToStore` — agent ON → `store.status(for:)` reflects the event.
- `testDispatchAgentOffDropsEvent` — agent OFF → `store.status(for:)` stays `.neverRan`.
- `testDispatchToggleFlipOffRetainsExistingState` — after an ON event is stored, flipping the toggle OFF and sending more events leaves the stored state in place (regression: accepted edge case).

### Modified tests

- `TheAllTests/L10nSmokeTests.swift` — drop assertions about `settings.terminal.statusIndicators`; add assertions for `settings.section.agents` and `settings.agents.{claude,codex,opencode}`.
- Any test constructing `TerminalStatus.success/.failed` without an explicit agent now must supply one (compile error forces the fix).
- Any tooltip-text assertion using the old shell-style prefix (`Succeeded in …`, `Failed after …`) must switch to the agent-prefixed form (`Claude: turn finished · …`). If the test's intent was shell-specific, delete it.

### Shell-side smoke

- `Resources/agent-hooks/tests/smoke.sh` — remove shell-hooks sections; keep claude/codex/opencode wrapper smoke tests.
- `Resources/agent-hooks/tests/test_agent_hook.py` — same.

### Verification commands

```bash
./scripts/check-doc-drift.sh
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
bash Resources/agent-hooks/tests/smoke.sh
```

All three must pass before the branch merges.

## 10. Implementation Order

Suggested sequence for the writing-plans follow-up. Ordering respects compile dependencies (later steps assume earlier ones are in place).

1. **Enum + TerminalStatus cleanup**: remove `.shell` from `HookMessage.Agent`, drop the `.shell` default on `TerminalStatus.success/.failed` and `TerminalStatusStore.setFinished`. Compile errors will guide the next few steps.
2. **Tooltip branch collapse** in `TerminalStatusIconView` — removes the last reference to `.shell`.
3. **Listener filter**: extract the `ContentView.onMessage` closure into a pure `dispatchHookMessage(...)` function; add the per-agent toggle guard.
4. **Enum helpers**: add `settingsKey` and `label` to `HookMessage.Agent`. (Can fold into step 1 if convenient.)
5. **i18n**: add `settings.section.agents` and `settings.agents.{claude,codex,opencode}` to xcstrings + L10n.swift; remove `settings.terminal.statusIndicators`.
6. **`AgentsSectionView.swift` + `SettingsSection.agents` enum case + `SettingsView` switch arm**.
7. **Remove `TerminalSectionView` statusIndicators row + managedKeys entry**.
8. **ContentView master gate**: change `showStatusIndicators` derivation to "any agent enabled".
9. **Delete `shell-hooks.{zsh,bash,fish}`; edit `bootstrap.{zsh,bash,fish}` to drop their source lines**.
10. **Docs sync**: CLAUDE.md, AGENTS.md, agent-hooks.md, settings-reference.md, new `decisions/004-shell-out-of-status-pipeline.md`.
11. **Tests** — add new, migrate old; run `./scripts/check-doc-drift.sh` + `xcodebuild test …` + `bash Resources/agent-hooks/tests/smoke.sh`.

Each step should compile and pass tests before moving to the next. Landing groups: 1-4 (enum/filter core), 5-8 (settings UI), 9-11 (cleanup + docs + tests).
