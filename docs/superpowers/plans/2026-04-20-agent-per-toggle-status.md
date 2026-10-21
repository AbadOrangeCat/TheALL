# Per-Agent Status Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `theall-status-indicators` master toggle with per-agent toggles (Claude / Codex / OpenCode) in a new Settings → Agents section, and remove shell from the status indicator pipeline entirely.

**Architecture:** Listener-layer filter in `HookSocketListener.onMessage` (extracted into a testable `HookDispatcher.dispatch` static) reads per-agent keys from `SettingsConfigStore` and drops events whose agent is disabled. The master UI gate `showStatusIndicators` is re-derived as "any agent enabled". Shell is physically removed: scripts deleted, enum case gone, tooltip branches collapsed, stale tests pruned.

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest, xcstrings (Xcode String Catalog), XcodeGen, bash/zsh/fish shell integration scripts.

**Spec:** `docs/superpowers/specs/2026-04-20-agent-per-toggle-status-design.md`

**Working tree:** Do this on a branch, not master. CLAUDE.md forbids pushing to master. Suggested branch name: `agent/per-toggle-status`.

Before starting:

```bash
git switch -c agent/per-toggle-status
```

---

## Task 1: Delete shell-hooks scripts & stop sourcing them from bootstrap

**Files:**
- Delete: `Resources/agent-hooks/shell-hooks.zsh`
- Delete: `Resources/agent-hooks/shell-hooks.bash`
- Delete: `Resources/agent-hooks/shell-hooks.fish`
- Modify: `Resources/agent-hooks/bootstrap.zsh:4`
- Modify: `Resources/agent-hooks/bootstrap.bash:4`
- Modify: `Resources/agent-hooks/bootstrap.fish:7`

Runtime hook behavior isn't in the Swift test target, so this task lands cleanly with no test churn. Build will still compile; the shell integration stops emitting `agent: shell` events on the next app launch.

- [ ] **Step 1: Delete the three shell-hooks scripts**

```bash
rm Resources/agent-hooks/shell-hooks.zsh
rm Resources/agent-hooks/shell-hooks.bash
rm Resources/agent-hooks/shell-hooks.fish
```

- [ ] **Step 2: Remove the source line from `bootstrap.zsh`**

Before (lines 1-6):

```zsh
# bootstrap.zsh — source this from ~/.zshrc to enable theall status hooks.
# Example: [ -f "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" ] && source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh"
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.zsh"
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.zsh" 2>/dev/null
```

After:

```zsh
# bootstrap.zsh — source this from ~/.zshrc to enable theall status hooks.
# Example: [ -f "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" ] && source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh"
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.zsh" 2>/dev/null
```

- [ ] **Step 3: Remove the source line from `bootstrap.bash`**

Drop line 4 (`source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.bash"`). Final file:

```bash
# bootstrap.bash — source this from ~/.bashrc to enable theall status hooks.
# Example: [ -f "$THEALL_AGENT_HOOKS_DIR/bootstrap.bash" ] && source "$THEALL_AGENT_HOOKS_DIR/bootstrap.bash"
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.bash" 2>/dev/null
```

- [ ] **Step 4: Remove the source line from `bootstrap.fish`**

Drop line 7 (`source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.fish"`). Final file:

```fish
# bootstrap.fish — source this from ~/.config/fish/config.fish to enable theall status hooks.
# Example:
#   if set -q THEALL_AGENT_HOOKS_DIR
#       source "$THEALL_AGENT_HOOKS_DIR/bootstrap.fish"
#   end
test -z "$THEALL_AGENT_HOOKS_DIR"; and return 0
test -f "$THEALL_AGENT_HOOKS_DIR/agent-functions.fish"; and source "$THEALL_AGENT_HOOKS_DIR/agent-functions.fish"
```

- [ ] **Step 5: Verify build still compiles**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Resources/agent-hooks/
git commit -m "$(cat <<'EOF'
refactor(agent-hooks): drop shell-hooks from the status indicator pipeline

Deletes shell-hooks.{zsh,bash,fish} and removes their source lines from
bootstrap.*. Shell preexec/precmd no longer emits status events. The
enum case and Swift-side shell branches are removed in follow-up commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Remove `.shell` case from `HookMessage.Agent` + add `CaseIterable` / `settingsKey`

**Files:**
- Modify: `TheAll/Models/HookMessage.swift:13-18` (enum), `:39-49` (displayName)

The `label` computed property is added in Task 8 (after i18n keys exist). This task keeps the enum on 3 cases, adds `CaseIterable`, and introduces `settingsKey`. It also removes `"Shell"` from `displayName`.

Removing `.shell` creates compile errors in tests and (indirectly) in `TerminalStatus.swift` / `TerminalStatusStore.swift` (default parameters `= .shell`). Tasks 3 and 4 fix those; keeping them in separate tasks is only practical if we do the defaults first — so we inline the default-parameter edits here as well to land a clean compile in one go.

- [ ] **Step 1: Update `HookMessage.Agent`**

Edit `TheAll/Models/HookMessage.swift`, replacing lines 13-18:

```swift
    enum Agent: String, Decodable, CaseIterable {
        case claude
        case opencode
        case codex

        /// Config key used by Settings → Agents and by the listener filter.
        var settingsKey: String { "theall-agent-status-\(rawValue)" }
    }
```

- [ ] **Step 2: Update `displayName` to drop the `.shell` branch**

Edit `TheAll/Models/HookMessage.swift`, replacing lines 39-49:

```swift
extension HookMessage.Agent {
    /// Human-readable name for tooltips and log messages.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .opencode: return "OpenCode"
        case .codex:    return "Codex"
        }
    }
}
```

- [ ] **Step 3: Remove the `.shell` default from `TerminalStatus.success` / `.failed`**

Edit `TheAll/Models/TerminalStatus.swift` lines 24-27:

```swift
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                 agent: HookMessage.Agent, summary: String? = nil)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                agent: HookMessage.Agent, summary: String? = nil)
```

- [ ] **Step 4: Remove the `.shell` default from `TerminalStatusStore.setFinished`**

Edit `TheAll/Models/TerminalStatusStore.swift` line 33:

```swift
    func setFinished(terminalId: UUID, exitCode: Int32, at finishedAt: Date,
                     agent: HookMessage.Agent, summary: String? = nil) {
```

- [ ] **Step 5: Collapse the shell branch in `TerminalStatusIconView.tooltipText`**

Edit `TheAll/Theme/TerminalStatusIconView.swift`, replacing the body of the `.success` and `.failed` cases in `tooltipText(for:)` (currently lines 165-181):

```swift
        case .success(_, let duration, _, let agent, let summary):
            let prefix = "\(agent.displayName): turn finished · \(Self.formatDuration(duration))"
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
        case .failed(_, let duration, _, let agent, let summary):
            let prefix = "\(agent.displayName): turn had tool errors · \(Self.formatDuration(duration))"
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
```

- [ ] **Step 6: Prune shell-specific tests in `HookMessageTests`**

Edit `TheAllTests/HookMessageTests.swift`. Delete these methods entirely — they test shell-only JSON shapes that no longer exist:

- `testDecodeIdleShell` (lines ~16-21)
- `testDecodeFinishedSuccess` (lines ~40-45) — duplicated by `testDecodeFinishedWithAgentAndSummary`
- `testDecodeFinishedNonZero` (lines ~47-52) — agents only emit 0/1 sentinel; exit 127 was shell-only
- `testDecodeShellFinishedLacksNewFields` (lines ~81-88)

**Update** (don't delete) `testDecodeIdleHasNoExitCode` — the invariant is agent-agnostic; just swap the agent:

```swift
    func testDecodeIdleHasNoExitCode() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"claude","at":1}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .idle)
        XCTAssertNil(msg.exitCode)
    }
```

Keep unchanged: `testDecodeRunning`, `testDecodeUnknownAgentFails`, `testDecodeNeedsInput`, `testDecodeWithOptionalMeta`, `testDecodeRunningWithToolDetail`, `testDecodeFinishedWithAgentAndSummary`.

**Add** a new test (alongside the kept `testDecodeUnknownAgentFails`) asserting `"shell"` is now also among the rejected agents — the spec's defensive guard:

```swift
    func testDecodeShellAgentFails() {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"shell","at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: json))
    }
```

The existing `testDecodeUnknownAgentFails` (which tests `"cursor"`) stays unchanged.

- [ ] **Step 7: Add new `HookMessage.Agent` tests**

Append to `TheAllTests/HookMessageTests.swift`:

```swift
    func testAgentAllCasesExcludesShell() {
        XCTAssertEqual(HookMessage.Agent.allCases.count, 3)
        let raws = Set(HookMessage.Agent.allCases.map(\.rawValue))
        XCTAssertEqual(raws, ["claude", "opencode", "codex"])
        XCTAssertFalse(raws.contains("shell"))
    }

    func testAgentSettingsKeyFormat() {
        XCTAssertEqual(HookMessage.Agent.claude.settingsKey,   "theall-agent-status-claude")
        XCTAssertEqual(HookMessage.Agent.codex.settingsKey,    "theall-agent-status-codex")
        XCTAssertEqual(HookMessage.Agent.opencode.settingsKey, "theall-agent-status-opencode")
    }
```

- [ ] **Step 8: Prune shell-specific tests in `TerminalStatusTests`**

Edit `TheAllTests/TerminalStatusTests.swift`.

Delete `testFailedDefaultsAreShellAndNilSummary` (lines ~154-163) entirely — `TerminalStatus.failed` no longer has a default agent.

Fix `testAggregateAnyRunningBeatsEverything` (lines ~28-39), `testAggregateFailedBeatsSuccessAndNeverRan` (lines ~41-51), `testIdleBeatsNeverRanButLosesToSuccess` (lines ~53-59), `testNeedsInputBeatsEverything` (lines ~61-72), `testFullPriorityChain` (lines ~74-91), `testAggregateSuccessBeatsNeverRan` (lines ~93-102), `testAggregateTwoSuccessPicksOneSuccess` (lines ~104-111), `testTooltipTextForEachState` (lines ~121-132) — every `.success(...)` / `.failed(...)` constructor call currently relies on the default `.shell`. Add an explicit `agent: .claude` (or any valid agent) to each.

For example, `testAggregateAnyRunningBeatsEverything` becomes:

```swift
    func testAggregateAnyRunningBeatsEverything() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude),
            .failed(exitCode: 1, duration: 2, finishedAt: now, agent: .claude),
            .running(startedAt: now),
            .neverRan,
        ]
        if case .running = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected running to win aggregation")
        }
    }
```

Apply the same `agent: .claude` insertion everywhere `TerminalStatus.success` / `.failed` is built without it. **Do not** change `testTooltipTextForEachState`'s expected strings yet — that test asserts shell-style tooltips that no longer exist; replace it with an agent-style assertion:

```swift
    func testTooltipTextForEachState() {
        XCTAssertNil(TerminalStatusIconView.tooltipText(for: .neverRan))
        let now = Date()
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .success(exitCode: 0, duration: 151,
                                                              finishedAt: now, agent: .claude)),
            "Claude: turn finished · 2m31s")
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .failed(exitCode: 1, duration: 5,
                                                             finishedAt: now, agent: .claude)),
            "Claude: turn had tool errors · 5s")
        let rt = TerminalStatusIconView.tooltipText(for: .running(startedAt: now)) ?? ""
        XCTAssertTrue(rt.hasPrefix("Running for"))
    }
```

- [ ] **Step 9: Prune shell-specific tests in `TerminalStatusIconViewTests`**

Edit `TheAllTests/TerminalStatusIconViewTests.swift`.

Delete these tests entirely (they assert the removed shell-style tooltip format):

- `testShellSuccessFormatsWithExitCode` (lines ~26-31)
- `testShellFailedFormatsWithExitCode` (lines ~67-72)
- `testSuccessDefaultAgentShellDoesNotPrefixWithName` (lines ~92-98)

Keep all `testClaudeSuccess…`, `testCodexSuccess…`, `testOpenCodeSuccess…`, `testClaudeFailed…` tests unchanged — they already assert the agent-style format that the refactor preserves.

- [ ] **Step 10: Fix `HookSocketListenerTests` agent payload**

Edit `TheAllTests/HookSocketListenerTests.swift`. In `testMultipleMessagesOnSameConnection` (line ~45), both JSON payloads use `"agent":"shell"`. Switch to `"agent":"claude"`:

```swift
        let payload =
            #"{"terminalId":"\#(tid)","event":"running","agent":"claude","at":1}"# + "\n" +
            #"{"terminalId":"\#(tid)","event":"idle","agent":"claude","at":2}"# + "\n"
```

- [ ] **Step 11: Run the full test suite**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```

Expected: all tests pass (compile clean; no references to `.shell`).

If anything fails to compile, grep for stragglers:

```bash
# From repo root
rg '\.shell\b' TheAll/ TheAllTests/
rg '"shell"' TheAllTests/
```

Anything matched in `TheAll/` is a bug — fix before committing. Matches in `TheAllTests/` should only appear inside strings that test the decode-fails case (Step 6).

- [ ] **Step 12: Commit**

```bash
git add TheAll/ TheAllTests/
git commit -m "$(cat <<'EOF'
refactor(models): remove shell from HookMessage.Agent + tooltip

- HookMessage.Agent loses its .shell case; gains CaseIterable and a
  settingsKey helper for Settings → Agents + the listener filter.
- TerminalStatus.success/.failed and TerminalStatusStore.setFinished
  drop their = .shell default parameter; all callers now supply an
  explicit agent.
- TerminalStatusIconView tooltips collapse the shell branch; success /
  failed always read "<Agent>: turn finished · duration" (+ summary).
- Tests pruned or updated to match (shell-specific tooltip tests
  deleted; TerminalStatus constructors gain explicit agent: .claude).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add i18n keys for Agents section (additive only)

**Files:**
- Modify: `TheAll/Localization/Localizable.xcstrings`
- Modify: `TheAll/Localization/L10n.swift:80-146`
- Modify: `TheAllTests/L10nSmokeTests.swift:60-73`

This task only **adds** keys. Removing the obsolete `settings.terminal.statusIndicators` entry is deferred to Task 5, where the `BoundToggle` that uses it is also removed — keeping the commit compilable at every step.

- [ ] **Step 1: Add new xcstrings entries**

Open `TheAll/Localization/Localizable.xcstrings`. It's a JSON file sorted alphabetically by key. Insert the four new entries in sort order.

Locate the block for `"settings.section.appearance"` (around line 319). Insert immediately before it:

```json
    "settings.agents.claude" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Claude Code" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Claude Code" } }
      }
    },
    "settings.agents.codex" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Codex" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Codex" } }
      }
    },
    "settings.agents.opencode" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "OpenCode" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "OpenCode" } }
      }
    },
    "settings.section.agents" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Agents" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Agents" } }
      }
    },
```

Make sure final JSON remains valid (commas between objects, no trailing comma before `}`). Leave `settings.terminal.statusIndicators` in place for now.

- [ ] **Step 2: Update `L10n.swift` — additions only**

Edit `TheAll/Localization/L10n.swift`. In the `Settings` enum:

**Add** (right after `static let sectionUpdate`, around line 86):

```swift
        static let sectionAgents        = LocalizedStringResource("settings.section.agents")
```

**Add** the `Agents` nested enum (place it between `Terminal` and `Update`, around line 145):

```swift
        enum Agents {
            static let claude   = LocalizedStringResource("settings.agents.claude")
            static let codex    = LocalizedStringResource("settings.agents.codex")
            static let opencode = LocalizedStringResource("settings.agents.opencode")
        }
```

Leave `L10n.Settings.Terminal.statusIndicators` in place — its only caller (the TerminalSectionView BoundToggle) is still there. Task 5 removes both together.

- [ ] **Step 3: Update `L10nSmokeTests.allKeys` — additions only**

Edit `TheAllTests/L10nSmokeTests.swift` `allKeys` array (lines 15-134).

**Add** (insert in sort order inside each group):

After the `// Settings — appearance` group (after line 47, which is `"settings.appearance.windowPaddingY"`), add a new group before `// Settings — chrome`:

```swift
        // Settings — agents
        "settings.agents.claude",
        "settings.agents.codex",
        "settings.agents.opencode",
```

Under the `// Settings — section` group (between lines 69-73), insert `"settings.section.agents"` in sort order (alphabetically it comes first):

```swift
        // Settings — section
        "settings.section.agents",
        "settings.section.appearance",
        "settings.section.font",
        "settings.section.shell",
        "settings.section.terminal",
        "settings.section.update",
```

Leave `"settings.terminal.statusIndicators"` in the list — Task 5 removes it.

- [ ] **Step 4: Run L10n smoke tests**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/L10nSmokeTests
```

Expected: all tests pass. Any failure means a key is missing in either bundle or in `allKeys`.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Localization/ TheAllTests/L10nSmokeTests.swift
git commit -m "$(cat <<'EOF'
feat(i18n): add Agents section strings

- Localizable.xcstrings: +settings.section.agents,
  +settings.agents.{claude,codex,opencode}. Each gets identical en +
  zh-Hans values (product names remain English in Chinese).
- L10n.swift: add sectionAgents constant and Agents nested enum.
- L10nSmokeTests.allKeys mirrors the additions.

settings.terminal.statusIndicators removal is deferred to the commit
that also removes its BoundToggle caller in TerminalSectionView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Extract `HookDispatcher.dispatch` with per-agent toggle gate

**Files:**
- Create: `TheAll/Models/HookDispatcher.swift`
- Modify: `TheAll/ContentView.swift:139-157`
- Create: `TheAllTests/HookDispatcherTests.swift`

This is the behavior core of the feature — a pure function that takes a `HookMessage`, a `SettingsConfigStore`, and a `TerminalStatusStore`, and either dispatches to the store or drops the message based on the per-agent toggle.

- [ ] **Step 1: Write failing tests first**

Create `TheAllTests/HookDispatcherTests.swift`:

```swift
import XCTest
@testable import TheAll

final class HookDispatcherTests: XCTestCase {

    private var tmpConfigPath: String!
    private var settings: SettingsConfigStore!
    private var store: TerminalStatusStore!
    private let tid = UUID()

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theall-dispatch-\(UUID().uuidString).conf")
        tmpConfigPath = tmp.path
        settings = SettingsConfigStore(filePath: tmpConfigPath)
        store = TerminalStatusStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpConfigPath)
    }

    private func makeMsg(event: HookMessage.Event,
                         agent: HookMessage.Agent,
                         at: TimeInterval,
                         exitCode: Int32? = nil) -> HookMessage {
        let json = """
        {"terminalId":"\(tid.uuidString)","event":"\(event.rawValue)","agent":"\(agent.rawValue)","at":\(at)\(exitCode.map { ",\"exitCode\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(HookMessage.self, from: json.data(using: .utf8)!)
    }

    func testDispatchAgentOnForwardsRunning() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("Expected .running, got \(store.status(for: tid))")
        }
    }

    func testDispatchAgentOffDropsEvent() {
        // Claude toggle absent → treated as OFF.
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchAgentExplicitFalseDropsEvent() {
        settings.set(HookMessage.Agent.claude.settingsKey, "false")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchFinishedForwardsWithAgent() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude,
                                        at: 110, exitCode: 0),
                                settings: settings, store: store)
        if case .success(_, _, _, let agent, _) = store.status(for: tid) {
            XCTAssertEqual(agent, .claude)
        } else {
            XCTFail("Expected .success, got \(store.status(for: tid))")
        }
    }

    func testDispatchFinishedWithoutExitCodeDropsSilently() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude, at: 100),
                                settings: settings, store: store)
        // No exitCode → setFinished would fail; dispatcher must guard.
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchToggleFlipOffRetainsStoredState() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        // User flips the toggle off mid-turn.
        settings.set(HookMessage.Agent.claude.settingsKey, "false")
        settings.save()
        // New events dropped, but the already-stored .running stays.
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .claude, at: 200),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("Expected .running to persist after toggle-off")
        }
    }

    func testDispatchMixedAgentsRespectsEachToggle() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        // codex toggle absent (OFF)
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 50),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan, "codex OFF should drop")
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("claude ON should forward")
        }
    }
}
```

- [ ] **Step 2: Run the new tests, confirm they fail**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookDispatcherTests
```

Expected: compile error — `HookDispatcher` does not exist.

- [ ] **Step 3: Create `HookDispatcher.swift`**

Create `TheAll/Models/HookDispatcher.swift`:

```swift
import Foundation

/// Stateless filter + fanout from `HookMessage` to `TerminalStatusStore`.
///
/// Extracted out of `ContentView.onMessage` so the per-agent gate can be
/// unit-tested without plumbing an in-process Unix socket. The listener still
/// owns the socket and the main-hop; it calls `dispatch` with each decoded
/// message.
///
/// Filter policy: a message is forwarded iff the user has enabled its agent
/// in Settings → Agents (per-agent key `theall-agent-status-<rawValue>` == "true").
/// Missing or any non-"true" value = disabled. Shell is not representable —
/// the enum no longer has `.shell`, and the socket listener's JSONDecoder
/// drops stray shell-agent payloads before they reach this function.
enum HookDispatcher {
    static func dispatch(_ msg: HookMessage,
                         settings: SettingsConfigStore,
                         store: TerminalStatusStore) {
        guard settings.get(msg.agent.settingsKey) == "true" else { return }
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
            // hook-emit.sh degrades malformed `finished` to `idle` before it
            // reaches us; this guard is defense in depth.
            guard let ec = msg.exitCode else { return }
            store.setFinished(terminalId: msg.terminalId, exitCode: ec,
                              at: msg.timestamp, agent: msg.agent,
                              summary: msg.summary)
        }
    }
}
```

- [ ] **Step 4: Re-run dispatcher tests, confirm they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookDispatcherTests
```

Expected: all 7 tests pass.

- [ ] **Step 5: Wire `ContentView.onMessage` through `HookDispatcher.dispatch`**

Edit `TheAll/ContentView.swift`. Replace the `listener.onMessage = { msg in ... }` block (lines ~139-157) with:

```swift
                    let settingsStoreRef = self.settingsStore
                    listener.onMessage = { msg in
                        HookDispatcher.dispatch(msg,
                                                settings: settingsStoreRef,
                                                store: store)
                    }
```

Context lines (140 & 160) remain: the `do/try` wrapper, `try listener.start()`, `hookListener = listener` stay unchanged.

- [ ] **Step 6: Build and run full test suite**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add TheAll/Models/HookDispatcher.swift TheAll/ContentView.swift TheAllTests/HookDispatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(models): HookDispatcher filters status events by per-agent toggle

Extracts the ContentView.onMessage dispatch logic into a testable
static `HookDispatcher.dispatch(msg:settings:store:)` that:

- Reads settings.get("theall-agent-status-<agent>"), drops the event if
  the value isn't "true".
- For forwarded events, calls the corresponding TerminalStatusStore
  setter. `finished` without an exitCode is silently dropped (existing
  defense-in-depth against malformed shell-side emits).

ContentView.onMessage now just calls HookDispatcher.dispatch.

Unit tests cover: agent ON forwards, agent OFF / absent drops, finished
without exitCode drops, toggle-flip-off retains stored state, mixed
agents respected per-toggle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `Agents` section to Settings + remove `statusIndicators` from Terminal

**Files:**
- Modify: `TheAll/Models/HookMessage.swift` (add `label` property — was deferred from Task 2)
- Modify: `TheAll/Settings/SettingsSection.swift:4-22`
- Create: `TheAll/Settings/Sections/AgentsSectionView.swift`
- Modify: `TheAll/Settings/SettingsView.swift:66-74`
- Modify: `TheAll/Settings/Sections/TerminalSectionView.swift:7-22`
- Modify: `TheAll/Localization/L10n.swift` (remove `Terminal.statusIndicators`)
- Modify: `TheAll/Localization/Localizable.xcstrings` (remove `settings.terminal.statusIndicators`)
- Modify: `TheAllTests/L10nSmokeTests.swift` (remove `settings.terminal.statusIndicators`)

The `BoundToggle` caller, its L10n constant, and its xcstrings entry all disappear together so the codebase stays compilable throughout the commit.

- [ ] **Step 1: Add `label` property to `HookMessage.Agent`**

Edit `TheAll/Models/HookMessage.swift`. Extend the `Agent` extension that currently defines `displayName`:

```swift
extension HookMessage.Agent {
    /// Human-readable name for tooltips and log messages.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .opencode: return "OpenCode"
        case .codex:    return "Codex"
        }
    }

    /// Localized label for the Settings → Agents row.
    var label: LocalizedStringResource {
        switch self {
        case .claude:   return L10n.Settings.Agents.claude
        case .opencode: return L10n.Settings.Agents.opencode
        case .codex:    return L10n.Settings.Agents.codex
        }
    }
}
```

- [ ] **Step 2: Add `.agents` case to `SettingsSection`**

Edit `TheAll/Settings/SettingsSection.swift`. Replace the enum body (lines 4-22):

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case font
    case terminal
    case shell
    case agents
    case update

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .appearance: return L10n.Settings.sectionAppearance
        case .font:       return L10n.Settings.sectionFont
        case .terminal:   return L10n.Settings.sectionTerminal
        case .shell:      return L10n.Settings.sectionShell
        case .agents:     return L10n.Settings.sectionAgents
        case .update:     return L10n.Settings.sectionUpdate
        }
    }
}
```

- [ ] **Step 3: Create `AgentsSectionView.swift`**

Create `TheAll/Settings/Sections/AgentsSectionView.swift`:

```swift
import SwiftUI

struct AgentsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    /// All config keys this section manages. Data-driven from `HookMessage.Agent.allCases`
    /// so adding a new agent (enum case) auto-registers it with the reset button.
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

- [ ] **Step 4: Wire `AgentsSectionView` into `SettingsView.sectionBody`**

Edit `TheAll/Settings/SettingsView.swift`. Extend the `sectionBody` switch (lines 66-74):

```swift
    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .appearance: AppearanceSectionView(theme: theme, settings: settings)
        case .font:       FontSectionView(theme: theme, settings: settings)
        case .terminal:   TerminalSectionView(theme: theme, settings: settings)
        case .shell:      ShellSectionView(theme: theme, settings: settings)
        case .agents:     AgentsSectionView(theme: theme, settings: settings)
        case .update:     UpdateSectionView(theme: theme, updateStore: updateStore)
        }
    }
```

- [ ] **Step 5: Remove `theall-status-indicators` from `TerminalSectionView`**

Edit `TheAll/Settings/Sections/TerminalSectionView.swift`.

**Remove** from `managedKeys` (line ~8):

```swift
        "theall-status-indicators",
```

**Remove** the `BoundToggle` block (lines ~17-22):

```swift
            BoundToggle(
                settings: settings,
                key: "theall-status-indicators",
                defaultValue: false,
                label: L10n.Settings.Terminal.statusIndicators
            )
```

Final file:

```swift
import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "scrollback-limit",
        "copy-on-select",
        "mouse-hide-while-typing",
        "confirm-close-surface",
    ]

    var body: some View {
        Form {
            BoundStepper(
                settings: settings,
                key: "scrollback-limit",
                defaultValue: 10_000_000,
                range: 0...100_000_000,
                label: L10n.Settings.Terminal.scrollbackLimit
            )

            BoundSegmented(
                settings: settings,
                key: "copy-on-select",
                options: ["false", "true", "clipboard"],
                label: L10n.Settings.Terminal.copyOnSelect
            )

            BoundToggle(
                settings: settings,
                key: "mouse-hide-while-typing",
                defaultValue: false,
                label: L10n.Settings.Terminal.hideMouseWhileTyping
            )

            BoundSegmented(
                settings: settings,
                key: "confirm-close-surface",
                options: ["true", "false", "always"],
                label: L10n.Settings.Terminal.confirmClose
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

- [ ] **Step 6: Remove `L10n.Settings.Terminal.statusIndicators`**

Now that the BoundToggle referencing it is gone, the constant is orphaned. Delete it from `TheAll/Localization/L10n.swift` — find the line inside the `Terminal` nested enum:

```swift
            static let statusIndicators       = LocalizedStringResource("settings.terminal.statusIndicators")
```

Delete that single line.

- [ ] **Step 7: Remove the xcstrings entry**

Edit `TheAll/Localization/Localizable.xcstrings`. Delete the `"settings.terminal.statusIndicators"` block (was at lines ~403-409 before additions in Task 3 — shifted; grep to locate):

```bash
rg -n 'settings\.terminal\.statusIndicators' TheAll/Localization/Localizable.xcstrings
```

Delete the full entry (key name + localizations + trailing comma). Verify JSON still valid (no trailing comma before `}`).

- [ ] **Step 8: Remove `"settings.terminal.statusIndicators"` from `L10nSmokeTests.allKeys`**

Edit `TheAllTests/L10nSmokeTests.swift`. In the `allKeys` array, delete:

```swift
        "settings.terminal.statusIndicators",
```

- [ ] **Step 9: Regenerate Xcode project**

The new Swift file (`AgentsSectionView.swift`) needs to be picked up by XcodeGen:

```bash
xcodegen generate
```

Expected: "Loaded project" / "Created project".

- [ ] **Step 10: Build and run tests**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```

Expected: all tests pass. AgentsSectionView builds even if it has no dedicated tests yet (indirectly exercised through the section switch). L10nSmokeTests asserts the xcstrings entries match `allKeys`.

- [ ] **Step 11: Final check — no stragglers referencing `statusIndicators`**

```bash
rg -n 'statusIndicators|status-indicators' TheAll/ TheAllTests/
```

Expected matches:
- `TheAll/ContentView.swift` — the `private var showStatusIndicators` computed property and its downstream bridges/views. These are the UI master gate, unrelated to the removed Terminal toggle. Untouched.
- `TheAll/Bridge/SidebarListBridge.swift`, `TabBridge.swift`, etc. — same, UI plumbing. Untouched.
- `TheAllTests/StatusIndicatorGateTests.swift` — if Task 6 has already landed; otherwise none.

No matches should mention `theall-status-indicators` (the config key) or `L10n.Settings.Terminal.statusIndicators`.

- [ ] **Step 12: Commit**

```bash
git add TheAll/ TheAll.xcodeproj/ TheAllTests/L10nSmokeTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): add Agents section; drop Terminal statusIndicators row

- SettingsSection gains an .agents case between .shell and .update.
- AgentsSectionView iterates HookMessage.Agent.allCases, renders one
  BoundToggle per agent plus a reset row. Managed keys derived from
  the enum so new agents auto-populate.
- HookMessage.Agent.label returns the localized row title.
- TerminalSectionView drops the theall-status-indicators toggle and its
  entry from managedKeys.
- L10n.Settings.Terminal.statusIndicators constant, its xcstrings
  entry, and its smoke-test listing all removed now that the BoundToggle
  caller is gone.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Re-derive `showStatusIndicators` as "any agent enabled"

**Files:**
- Modify: `TheAll/ContentView.swift:27-32`
- Create: `TheAllTests/StatusIndicatorGateTests.swift`

`showStatusIndicators` was a direct read of the old `theall-status-indicators` key. Re-derive it from the per-agent keys so the sidebar/tab icon column collapses iff every agent is off. To keep it testable, factor the derivation into a static on a small namespace.

- [ ] **Step 1: Write failing test**

Create `TheAllTests/StatusIndicatorGateTests.swift`:

```swift
import XCTest
@testable import TheAll

final class StatusIndicatorGateTests: XCTestCase {

    private var tmpPath: String!
    private var settings: SettingsConfigStore!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theall-gate-\(UUID().uuidString).conf")
        tmpPath = tmp.path
        settings = SettingsConfigStore(filePath: tmpPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testGateFalseWhenAllAgentsOff() {
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateFalseWhenAgentsExplicitlyFalse() {
        for agent in HookMessage.Agent.allCases {
            settings.set(agent.settingsKey, "false")
        }
        settings.save()
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenClaudeOn() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenCodexOn() {
        settings.set(HookMessage.Agent.codex.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenOpenCodeOn() {
        settings.set(HookMessage.Agent.opencode.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenAllAgentsOn() {
        for agent in HookMessage.Agent.allCases {
            settings.set(agent.settingsKey, "true")
        }
        settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateIgnoresRemovedMasterKey() {
        // Old `theall-status-indicators=true` in a user's config must not
        // resurrect the feature — only per-agent keys count.
        settings.set("theall-status-indicators", "true"); settings.save()
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }
}
```

- [ ] **Step 2: Run tests, confirm they fail**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/StatusIndicatorGateTests
```

Expected: compile error — `StatusIndicatorGate` does not exist.

- [ ] **Step 3: Create the gate helper**

Append to `TheAll/Models/HookDispatcher.swift` (same file as the dispatcher — they're peers conceptually):

```swift
/// Master UI gate: is the status indicator column visible anywhere?
///
/// True iff the user has enabled at least one agent in Settings → Agents.
/// All other downstream plumbing (`SidebarListBridge.showStatusIndicators`,
/// `TabBridge.showStatusIndicators`, icon rendering) continues to consume a
/// single Bool — this helper is its authoritative source.
enum StatusIndicatorGate {
    static func anyAgentEnabled(_ settings: SettingsConfigStore) -> Bool {
        HookMessage.Agent.allCases.contains { agent in
            settings.get(agent.settingsKey) == "true"
        }
    }
}
```

- [ ] **Step 4: Re-run tests, confirm they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/StatusIndicatorGateTests
```

Expected: all 7 tests pass.

- [ ] **Step 5: Use the gate from `ContentView.showStatusIndicators`**

Edit `TheAll/ContentView.swift`. Replace the computed property (lines 27-32):

```swift
    /// Master UI gate for the sidebar + tab bar status icons. True iff the user
    /// has enabled at least one agent in Settings → Agents; false collapses the
    /// icon column in the sidebar row and tab bar item layout.
    private var showStatusIndicators: Bool {
        StatusIndicatorGate.anyAgentEnabled(settingsStore)
    }
```

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add TheAll/Models/HookDispatcher.swift TheAll/ContentView.swift TheAllTests/StatusIndicatorGateTests.swift
git commit -m "$(cat <<'EOF'
feat(content): derive showStatusIndicators from per-agent toggles

Introduces `StatusIndicatorGate.anyAgentEnabled(_:)` as the authoritative
master-gate derivation. ContentView's computed property now calls through
to it, replacing the removed theall-status-indicators key lookup.

Regression test locks in that a lingering theall-status-indicators=true in
an old user config does NOT re-enable the feature — only per-agent keys
drive the gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update project docs

**Files:**
- Modify: `CLAUDE.md:69`, `:75`
- Modify: `AGENTS.md:75` (and the matching SettingsView line; verify via grep)
- Modify: `docs/agent-hooks.md:10-32`
- Modify: `docs/settings-reference.md`
- Create: `docs/decisions/004-shell-out-of-status-pipeline.md`

- [ ] **Step 1: Update `CLAUDE.md` Settings directory summary**

Edit `TheAll/CLAUDE.md`. Find line 69:

```
│   ├── SettingsView.swift         — SwiftUI 根面板，承载五个 Section
```

Change to:

```
│   ├── SettingsView.swift         — SwiftUI 根面板，承载六个 Section
```

Find line 75:

```
│   └── Sections/                  — 五个 Section 的视图实现（Appearance / Font / Terminal / Shell / Update）
```

Change to:

```
│   └── Sections/                  — 六个 Section 的视图实现（Appearance / Font / Terminal / Shell / Agents / Update）
```

- [ ] **Step 2: Update `AGENTS.md` Settings directory summary**

Edit `AGENTS.md` with the same two changes. If the exact line text differs, grep for "五个 Section" and apply the same rewording. Double-check by:

```bash
rg '五个 Section' AGENTS.md
```

Expected: no matches after the edit.

- [ ] **Step 3: Update `docs/agent-hooks.md`**

Edit `docs/agent-hooks.md`.

**Delete** the Shell row from the agent signal-source table (line ~32):

```
| Shell | zsh preexec/precmd 钩子 | `bootstrap.zsh` |
```

**Update** the IPC JSON schema paragraph (around line 10). The current prose mentions `"agent": "shell|claude|opencode|codex"`. Change to:

```
`"agent": "claude|opencode|codex"`
```

**Append** a one-line note at the end of the file:

```markdown

## Historical: shell 状态来源

shell preexec/precmd 在 2026-04 之前是第 4 种状态源。现已从 pipeline 中移除：
shell-hooks.{zsh,bash,fish} 脚本删除、bootstrap 不再 source、`HookMessage.Agent`
枚举不含 `.shell` case。详见 `decisions/004-shell-out-of-status-pipeline.md`。
```

- [ ] **Step 4: Update `docs/settings-reference.md`**

Edit `docs/settings-reference.md`.

Update the intro paragraph (line 3) to list six sections:

```markdown
theall 的设置面板分成六个 tab：**Appearance（外观）**、**Font（字体）**、**Terminal（终端）**、**Shell**、**Agents**、**Update（更新）**。
```

Insert a new `## 5. Agents` section between the existing `## 4. Shell` (line 51) and the `## 说明：Reset 按钮` section (line 63). Renumber `## Update` → `## 6. Update` for consistency (it currently has no leading number, but the update to "六个 tab" in the intro makes numbering helpful).

New section:

```markdown
---

## 5. Agents

控制哪些 code agent 会在 sidebar / tab 上显示状态图标。三个 agent 独立开关，默认全部关闭。至少打开一个时，图标列才会出现在 UI 上。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Claude Code | `theall-agent-status-claude` | `false` | 开启后，Claude Code wrapper 发来的 running / idle / needsInput / turn-finished 事件会显示在对应终端的状态图标上。关闭则所有 claude 事件被监听层静默丢弃。 |
| Codex | `theall-agent-status-codex` | `false` | 同上，对应 Codex wrapper。Codex 需要用户在 `~/.codex/config.toml` 中显式打开 `[features] codex_hooks = true`，否则只有 turn 完成事件，见 `docs/agent-hooks.md#codex-的特殊规则`。 |
| OpenCode | `theall-agent-status-opencode` | `false` | 同上，对应 OpenCode 插件。 |

**扩展性**：将来新增 code agent 时，`HookMessage.Agent` 枚举加一个 case，Settings → Agents 分组里会自动多出一行 Toggle（managed keys + 行列表均由 `.allCases` 派生）。

**行为细节**：
- 开关全部关闭 → sidebar / tab 的状态图标列整列折叠（等同于该功能被禁用）。
- 某 agent 开关 ON → OFF：已落盘到 `TerminalStatusStore` 的状态会残留（不再收到后续事件也无法自动清理）；新事件被丢弃。这是已知边缘场景。
- 老 key `theall-status-indicators`：2026-04 之前存在的主开关。从代码中移除；如果仍保留在你的 theall config 文件里，theall 不再读取，手动删除即可。

---
```

(If the current `## Update` section is not numbered "## 6. Update", leave its heading unchanged — the intro's "六个 tab" suffices for counting.)

Remove the sentence at line 3 about "四个 tab" and also mention all six.

- [ ] **Step 5: Create `docs/decisions/004-shell-out-of-status-pipeline.md`**

```markdown
# 004 — Shell 从状态指示 pipeline 中移除

**Status**: Accepted
**Date**: 2026-04-20
**Supersedes**: 部分代替 `docs/superpowers/specs/2026-04-17-terminal-status-v2-agent-hooks.md` 中 shell 部分的设定。

## Context

在 2026-04 以前，theall 的终端状态图标有 4 种来源：shell 的 zsh/bash/fish preexec/precmd 钩子，以及 Claude Code / Codex / OpenCode 三个 agent wrapper。shell 钩子在每次命令（甚至空回车）都会发 `running` / `idle` / `finished` 事件对，导致 socket 流量极高而信息量低——大部分用户对着不断跳动的图标看的是"shell 刚执行了什么"，但真正想看的是 "agent turn 还在跑吗 / 有没有需要我确认的提示"。

单一总开关 `theall-status-indicators` 也无法让用户只打开"想关心的 agent"，只能整体 opt-in 或 opt-out。

## Decision

shell 从状态指示 pipeline 中彻底移除：

- 删除 `Resources/agent-hooks/shell-hooks.{zsh,bash,fish}` 三个脚本；`bootstrap.*` 不再 source 它们。
- `HookMessage.Agent` 枚举不含 `.shell` case。`TerminalStatus.success/.failed` 与 `TerminalStatusStore.setFinished` 不再有 `.shell` 默认参数。`TerminalStatusIconView` tooltip 的 shell 分支被合并，统一走 agent 格式。
- 总开关 `theall-status-indicators` 下线。取而代之的是三个独立 per-agent key：`theall-agent-status-claude` / `-codex` / `-opencode`，默认全部关闭。UI 上汇入新的 Settings → Agents 分组。
- 图标的 UI gate（`showStatusIndicators`）从"读总开关"变为"任一 per-agent key 为 true"。

## Consequences

**正面**：
- Socket 流量显著下降（按人均每天打几百次 prompt 估算）。
- 用户可按 agent 精确选择想看到的状态，UI 噪声减少。
- 扩展到第 4 个 code agent 的路径清晰：加 `HookMessage.Agent` 枚举 case + 翻译 key + wrapper 脚本，Swift 侧其它代码自动派生新 toggle。

**负面 / 风险**：
- 老用户升级后状态图标默认消失，直到在 Settings → Agents 里至少打开一个。文档与 release note 需要注明。
- "shell 命令耗时 / 退出码"这个能力彻底没了。假如未来有需求（如"上条命令失败了显示红点"），需要重新引入 shell hooks 或改造为另一条独立 UI。
- 老用户 theall config 里残留的 `theall-status-indicators = ...` 不会被自动清理（行级 ConfigLine 解析保留未知 KV），但不再被读取。无害，自愿手动清理。

## Alternatives Considered

**A. 保留 shell 源，加个只读总开关过滤 UI**：复杂度没降，socket 流量没降。放弃。

**B. 保留 shell，全收全存，视图层按 agent 过滤**：TerminalStatus 所有 case 需要带 agent 字段，下游 sidebar/tab/view 都要改，换来的只是一个罕见边缘场景（toggle 中途关再开）更丝滑。成本收益比不划算。放弃。

**C. 当前方案：监听层按 agent 过滤 + 派生总开关**。选定。
```

- [ ] **Step 6: Run doc drift check**

```bash
./scripts/check-doc-drift.sh
```

Expected: "`CLAUDE.md Directory Structure matches TheAll/ Swift files (depth ≤ 2).`". The script ignores files in `Settings/Sections/` (depth > 2), so it's only checking the top-level `TheAll/` Swift files — which are unchanged.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md AGENTS.md docs/
git commit -m "$(cat <<'EOF'
docs: sync for per-agent status indicators + shell removal

- CLAUDE.md, AGENTS.md: Settings now host six Section views
  (+ Agents).
- docs/agent-hooks.md: drop Shell row from the signal-source table;
  trim the IPC JSON agent enumeration; add a history note.
- docs/settings-reference.md: add § 5 Agents with per-agent keys
  documented; update the intro's tab count.
- docs/decisions/004-shell-out-of-status-pipeline.md: new ADR
  recording the shell-out / per-agent-toggle decision.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run doc drift**

```bash
./scripts/check-doc-drift.sh
```

Expected: exit 0 with success message.

- [ ] **Step 2: Run full test suite**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests
```

Expected: `** TEST SUCCEEDED **`. All targets compile; all tests pass.

- [ ] **Step 3: Run agent-hooks smoke tests**

```bash
bash Resources/agent-hooks/tests/smoke.sh
```

Expected: pass. (These tests exercise Claude/Codex/OpenCode wrappers; there were no shell-specific assertions to begin with, so they should pass unchanged.)

- [ ] **Step 4: Sanity-check manually (local-only, do not commit)**

Launch the built app and confirm:

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

The user then opens Settings and verifies:

1. Six tabs: Appearance / Font / Terminal / Shell / **Agents** / Update.
2. Agents tab has three rows (Claude Code / Codex / OpenCode), all OFF.
3. Terminal tab no longer has the "Status Indicators (Beta)" row.
4. With all three Agents OFF, sidebar rows and tab bar items show no status icon column.
5. Toggling Claude ON and running claude in a terminal makes the icon appear.
6. Toggling Claude OFF makes new events drop (the existing state visibly persists — this is the accepted edge case documented in the ADR).

(No automation for the manual GUI check — CLAUDE.md's rule is agents do not restart the running app.)

- [ ] **Step 5: Final sanity grep — no stragglers**

```bash
rg -n '\.shell\b|"shell"|theall-status-indicators' TheAll/ TheAllTests/ Resources/agent-hooks/
```

Expected matches:
- `TheAllTests/HookMessageTests.swift` — the one test case that asserts `"shell"` agent now fails to decode (intentional).
- `TheAllTests/StatusIndicatorGateTests.swift` — the `testGateIgnoresRemovedMasterKey` test references the old key as a regression guard (intentional).

No other matches.

- [ ] **Step 6: Final commit (if any cleanup touches landed)**

If any lingering edits are pending (they shouldn't be — this task is verification only), commit them:

```bash
git status
# If clean: nothing to commit.
# If not clean, review and commit.
```

---

## Task 9: Open a pull request

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
git push -u origin agent/per-toggle-status
```

- [ ] **Step 2: Open PR targeting master**

```bash
gh pr create --title "feat: per-agent status indicators + shell removal" --body "$(cat <<'EOF'
## Summary

- Replaces single `theall-status-indicators` master toggle with three
  independent per-agent toggles (Claude / Codex / OpenCode) in a new
  Settings → Agents section.
- Removes shell from the status indicator pipeline (scripts deleted,
  `.shell` enum case removed, tooltip branches collapsed).
- Adds `HookDispatcher.dispatch` — a testable static that filters hook
  events by the per-agent toggle before forwarding to the store.

Design doc: `docs/superpowers/specs/2026-04-20-agent-per-toggle-status-design.md`
Decision record: `docs/decisions/004-shell-out-of-status-pipeline.md`

## Test plan

- [ ] `./scripts/check-doc-drift.sh` passes
- [ ] `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests` passes
- [ ] `bash Resources/agent-hooks/tests/smoke.sh` passes
- [ ] Settings UI manually: six sections, Agents section with three
      default-off toggles, Terminal no longer has the Status Indicators row.
- [ ] With all three toggles OFF → no status icon column.
- [ ] Toggle Claude ON → run claude → icons appear.
- [ ] Toggle Claude OFF mid-turn → new events drop; existing state
      persists (known edge case).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Summary

| Task | Outcome |
|------|---------|
| 1 | Shell scripts physically deleted; bootstrap stops sourcing them. |
| 2 | `.shell` gone from the data model; tooltip unified; stale tests pruned. |
| 3 | i18n keys for Agents section added; obsolete `settings.terminal.statusIndicators` dropped. |
| 4 | `HookDispatcher.dispatch` filters by per-agent toggle; `ContentView.onMessage` delegates. |
| 5 | Settings → Agents section live; Terminal section trimmed. |
| 6 | `showStatusIndicators` re-derived from per-agent keys via `StatusIndicatorGate`. |
| 7 | CLAUDE.md, AGENTS.md, agent-hooks.md, settings-reference.md synced; ADR 004 written. |
| 8 | Full verification (doc drift + xcodebuild test + smoke + manual). |
| 9 | PR opened. |
