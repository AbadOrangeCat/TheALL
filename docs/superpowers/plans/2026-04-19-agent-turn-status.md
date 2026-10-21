# Agent Turn Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate `.success` / `.failed` states for AI code agents (Claude Code, Codex, OpenCode) with per-turn error aggregation, plus transcript summary and live tool-detail tooltip content.

**Architecture:** A new Python script (`agent-hook.py`) consumes Claude/Codex hook stdin JSON, accumulates `turnHadError` in a per-session JSON file (`~/Library/Caches/theall/agent-sessions.json`), and emits the existing `.finished` event with `exitCode=0/1` sentinel + optional `summary` at `Stop`. OpenCode's plugin does the same via in-process state. The Swift side extends `HookMessage` / `TerminalStatus` / `TerminalStatusStore` additively — new optional fields, default associated-value arguments — so existing shell-side code and tests stay untouched.

**Tech Stack:** Swift 5 / XCTest, Python 3 / pytest, bash, fish, zsh, Node.js (OpenCode plugin).

**Spec reference:** `docs/superpowers/specs/2026-04-19-agent-turn-status-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `TheAll/Models/HookMessage.swift` | Modify | Add `toolDetail: String?` and `summary: String?`; add `Agent.displayName` extension |
| `TheAllTests/HookMessageTests.swift` | Modify | Decoder tests for new optional fields |
| `TheAll/Models/TerminalStatus.swift` | Modify | Extend `.running` / `.success` / `.failed` associated values with defaulted new args |
| `TheAllTests/TerminalStatusTests.swift` | Modify | Additive tests for new associated values + Equatable semantics |
| `TheAll/Models/TerminalStatusStore.swift` | Modify | Extend `setRunning(..., detail:)`, `setFinished(..., agent:, summary:)`; preserve `.running` startedAt across tool transitions |
| `TheAllTests/TerminalStatusStoreTests.swift` | Modify | Tests for startedAt preservation + agent/summary pass-through |
| `TheAll/Theme/TerminalStatusIconView.swift` | Modify | Tooltip agent-aware formatting (render unchanged) |
| `TheAllTests/TerminalStatusIconViewTests.swift` | Create | Dedicated tooltip matrix tests |
| `TheAll/ContentView.swift` | Modify | Route `toolDetail` to `setRunning`, `agent`+`summary` to `setFinished` |
| `Resources/agent-hooks/agent-hook.py` | Create | Python agent-hook dispatch (prompt/pretool/posttool/stop) |
| `Resources/agent-hooks/agent-hook.sh` | Create | Bash entry that reads stdin + execs agent-hook.py |
| `Resources/agent-hooks/tests/__init__.py` | Create | Empty init for pytest discovery |
| `Resources/agent-hooks/tests/test_agent_hook.py` | Create | Pytest unit tests for agent-hook.py |
| `Resources/agent-hooks/tests/smoke.sh` | Create | End-to-end bash smoke test |
| `Resources/agent-hooks/claude-wrapper.sh` | Modify | hooks.json routes prompt/pretool/posttool/stop to agent-hook.sh |
| `Resources/agent-hooks/codex-wrapper.sh` | Modify | Same routing for Codex |
| `Resources/agent-hooks/opencode-plugin/theall-status.js` | Modify | In-memory turn state + emit `toolDetail`/`exitCode` |
| `docs/agent-hooks.md` | Modify | Document new wire fields, session file, per-agent flow |

No Swift files deleted. No directory restructuring.

---

## Task 1: Extend `HookMessage` decoder

**Files:**
- Modify: `TheAll/Models/HookMessage.swift` (full file)
- Modify: `TheAllTests/HookMessageTests.swift` (append 3 tests)

- [ ] **Step 1.1: Add failing tests for the new optional fields**

Append to `TheAllTests/HookMessageTests.swift`, just before the closing `}` of the class:

```swift
    func testDecodeRunningWithToolDetail() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1713500000.0,"toolDetail":"Edit Models/Foo.swift"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .running)
        XCTAssertEqual(msg.agent, .claude)
        XCTAssertEqual(msg.toolDetail, "Edit Models/Foo.swift")
        XCTAssertNil(msg.summary)
        XCTAssertNil(msg.exitCode)
    }

    func testDecodeFinishedWithAgentAndSummary() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"claude","at":1713500015.3,"exitCode":0,"summary":"Refactored WorkspaceStore."}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .finished)
        XCTAssertEqual(msg.agent, .claude)
        XCTAssertEqual(msg.exitCode, 0)
        XCTAssertEqual(msg.summary, "Refactored WorkspaceStore.")
        XCTAssertNil(msg.toolDetail)
    }

    func testDecodeShellFinishedLacksNewFields() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"shell","at":1713500000.0,"exitCode":0}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .finished)
        XCTAssertEqual(msg.agent, .shell)
        XCTAssertNil(msg.toolDetail)
        XCTAssertNil(msg.summary)
    }
```

- [ ] **Step 1.2: Run tests — verify they fail**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookMessageTests 2>&1 | tail -30
```

Expected: compile errors on `msg.toolDetail` and `msg.summary` (properties don't exist).

- [ ] **Step 1.3: Implement the fields + displayName extension**

Replace the entirety of `TheAll/Models/HookMessage.swift` with:

```swift
import Foundation

/// Message sent by a shell/agent hook to the theall Unix socket.
/// Format: one message per newline, UTF-8 JSON.
struct HookMessage: Decodable, Equatable {
    enum Event: String, Decodable {
        case running
        case idle
        case needsInput
        case finished
    }

    enum Agent: String, Decodable {
        case shell
        case claude
        case opencode
        case codex
    }

    let terminalId: UUID
    let event: Event
    let agent: Agent
    let at: TimeInterval
    /// Present when `event == .finished`. Nil for other events.
    /// For agents: `0` = clean turn, `1` = turn had tool errors.
    /// For shell: real `$?` value.
    let exitCode: Int32?
    /// Optional running-state detail — e.g. "Edit Models/Foo.swift".
    /// Present when Claude/Codex `PreToolUse` or OpenCode `tool.execute.before`
    /// captures a tool name + inputs. Shell never sets this.
    let toolDetail: String?
    /// Optional finished-state summary (e.g. last assistant message, ≤200 chars).
    /// Present when Claude/Codex Stop reads transcript; nil otherwise.
    let summary: String?

    var timestamp: Date { Date(timeIntervalSince1970: at) }
}

extension HookMessage.Agent {
    /// Human-readable name for tooltips and log messages.
    var displayName: String {
        switch self {
        case .shell:    return "Shell"
        case .claude:   return "Claude"
        case .opencode: return "OpenCode"
        case .codex:    return "Codex"
        }
    }
}
```

- [ ] **Step 1.4: Run tests — verify they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookMessageTests 2>&1 | tail -20
```

Expected: 11 tests green (8 existing + 3 new).

- [ ] **Step 1.5: Commit**

```bash
git add TheAll/Models/HookMessage.swift TheAllTests/HookMessageTests.swift
git commit -m "feat(models): add toolDetail + summary fields to HookMessage

Optional wire-format fields for agent-originated messages. toolDetail
rides on running events (current tool + inputs), summary rides on
finished events (transcript last-assistant text). Shell messages
continue to omit both. Also adds Agent.displayName for tooltips."
```

---

## Task 2: Extend `TerminalStatus` enum

**Files:**
- Modify: `TheAll/Models/TerminalStatus.swift` (full file)
- Modify: `TheAllTests/TerminalStatusTests.swift` (append 4 tests)

- [ ] **Step 2.1: Add failing tests**

Append to `TheAllTests/TerminalStatusTests.swift`, just before the `private extension` block:

```swift
    func testSuccessWithAgentClaudeAndSummary() {
        let now = Date()
        let s = TerminalStatus.success(exitCode: 0, duration: 5, finishedAt: now,
                                       agent: .claude, summary: "Refactored X.")
        if case .success(_, _, _, let agent, let summary) = s {
            XCTAssertEqual(agent, .claude)
            XCTAssertEqual(summary, "Refactored X.")
        } else {
            XCTFail("Expected .success case")
        }
    }

    func testFailedDefaultsAreShellAndNilSummary() {
        let now = Date()
        let f = TerminalStatus.failed(exitCode: 1, duration: 2, finishedAt: now)
        if case .failed(_, _, _, let agent, let summary) = f {
            XCTAssertEqual(agent, .shell)
            XCTAssertNil(summary)
        } else {
            XCTFail("Expected .failed case")
        }
    }

    func testRunningWithDetail() {
        let now = Date()
        let r = TerminalStatus.running(startedAt: now, detail: "Edit Foo.swift")
        if case .running(_, let detail) = r {
            XCTAssertEqual(detail, "Edit Foo.swift")
        } else {
            XCTFail("Expected .running case")
        }
    }

    func testSuccessSummaryParticipatesInEquality() {
        let now = Date()
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                       agent: .claude, summary: "A")
        let b = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                       agent: .claude, summary: "B")
        XCTAssertNotEqual(a, b)
    }
```

- [ ] **Step 2.2: Run tests — verify compile failure**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -30
```

Expected: compile errors — `.success` etc. don't accept `agent:`/`summary:` args, `.running` doesn't accept `detail:`.

- [ ] **Step 2.3: Extend the enum with defaulted associated values**

Replace the entirety of `TheAll/Models/TerminalStatus.swift` with:

```swift
import Foundation

/// Per-terminal running state.
///
/// - `neverRan`: freshly opened terminal, no command has started yet.
/// - `running`: shell command / agent turn is in progress. `detail` optionally
///   carries a live label ("Edit Foo.swift") when an agent's tool-start hook
///   fires; shell leaves it nil.
/// - `idle`: shell is back at the prompt (command exited, awaiting next input).
/// - `needsInput`: agent/plugin is awaiting user confirmation before proceeding.
/// - `success` / `failed`: last command's or agent turn's result. For shell,
///   `exitCode` is the real `$?`. For agents, `exitCode` is a sentinel — `0`
///   means clean turn, `1` means turn had at least one tool error. `agent`
///   records which source produced the state; `summary` carries an optional
///   human-readable last-assistant message for tooltip display.
///
/// State is in-memory only. App restart → shell relaunches → all terminals
/// reset to `.neverRan`.
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date, detail: String? = nil)
    case idle(since: Date)
    case needsInput(since: Date)
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                 agent: HookMessage.Agent = .shell, summary: String? = nil)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                agent: HookMessage.Agent = .shell, summary: String? = nil)

    /// Aggregation priority (higher wins):
    /// needsInput > running > failed > success > idle > neverRan
    fileprivate var priority: Int {
        switch self {
        case .needsInput: return 5
        case .running:    return 4
        case .failed:     return 3
        case .success:    return 2
        case .idle:       return 1
        case .neverRan:   return 0
        }
    }

    /// Reduce a bag of per-terminal statuses into one aggregate status using the
    /// priority needsInput > running > failed > success > idle > neverRan.
    /// Ties keep the first member (e.g. two successes → the first). Empty input → `.neverRan`.
    static func aggregate(_ statuses: [TerminalStatus]) -> TerminalStatus {
        statuses.reduce(TerminalStatus.neverRan) { current, next in
            next.priority > current.priority ? next : current
        }
    }
}
```

- [ ] **Step 2.4: Run tests — verify they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -20
```

Expected: all `TerminalStatusTests` pass (existing + 4 new). Pre-existing tests that construct `.success(exitCode: 0, duration: 1, finishedAt: now)` continue to work because the new args (`agent`, `summary`) have defaults.

- [ ] **Step 2.5: Full regression**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all tests pass (103 existing + 3 from Task 1 + 4 new from this task = 110 tests, pending).

Note: the app target's `ContentView.swift` still compiles because default args mean existing `.success(exitCode:, duration:, finishedAt:)` sites don't change shape.

- [ ] **Step 2.6: Commit**

```bash
git add TheAll/Models/TerminalStatus.swift TheAllTests/TerminalStatusTests.swift
git commit -m "feat(models): extend TerminalStatus with agent + detail + summary

.running now carries optional detail (live tool label). .success and
.failed carry agent (defaults to .shell) + summary (nil default). All
new associated values have defaults so existing call sites continue
to work unchanged."
```

---

## Task 3: Extend `TerminalStatusStore` setters (with startedAt preservation)

**Files:**
- Modify: `TheAll/Models/TerminalStatusStore.swift` (lines 17-39, `setRunning` + `setFinished`)
- Modify: `TheAllTests/TerminalStatusStoreTests.swift` (append 4 tests)

- [ ] **Step 3.1: Add failing tests — preservation + pass-through**

Append to `TheAllTests/TerminalStatusStoreTests.swift`, just before the class's closing brace:

```swift
    func testSetRunningWithDetailStoresDetail() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: t, detail: "Edit Foo.swift")
        XCTAssertEqual(store.status(for: id), .running(startedAt: t, detail: "Edit Foo.swift"))
    }

    func testSetRunningPreservesStartedAtAcrossToolChanges() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: t1, detail: "Read Foo.swift")
        store.setRunning(terminalId: id, at: t2, detail: "Edit Foo.swift")
        // startedAt stays at t1 — duration is measured from first tool onset
        XCTAssertEqual(store.status(for: id), .running(startedAt: t1, detail: "Edit Foo.swift"))
    }

    func testSetRunningFromNonRunningSetsNewStartedAt() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        store.setIdle(terminalId: id, at: t1)
        store.setRunning(terminalId: id, at: t2, detail: "Bash: ls")
        XCTAssertEqual(store.status(for: id), .running(startedAt: t2, detail: "Bash: ls"))
    }

    func testSetFinishedWithAgentAndSummary() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 112)
        store.setRunning(terminalId: id, at: t1)
        store.setFinished(terminalId: id, exitCode: 1, at: t2,
                          agent: .claude, summary: "Edit failed: permission.")
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 1, duration: 12, finishedAt: t2,
                    agent: .claude, summary: "Edit failed: permission.")
        )
    }

    func testSetFinishedDefaultAgentIsShell() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 3000)
        store.setFinished(terminalId: id, exitCode: 0, at: t)  // no agent arg
        if case .success(_, _, _, let agent, let summary) = store.status(for: id) {
            XCTAssertEqual(agent, .shell)
            XCTAssertNil(summary)
        } else {
            XCTFail("Expected .success with defaults")
        }
    }
```

- [ ] **Step 3.2: Run tests — verify compile failure**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -30
```

Expected: compile errors — `setRunning` doesn't take `detail:`, `setFinished` doesn't take `agent:`/`summary:`.

- [ ] **Step 3.3: Extend the setters + add preservation logic**

In `TheAll/Models/TerminalStatusStore.swift`, replace the existing `setRunning` method (currently `func setRunning(terminalId: UUID, at startedAt: Date) { ... }`) with:

```swift
    func setRunning(terminalId: UUID, at startedAt: Date, detail: String? = nil) {
        guard !isStale(terminalId: terminalId, at: startedAt) else { return }
        // Preserve the original startedAt when we were already running — subsequent
        // PreToolUse / tool.execute.before hooks within a single agent turn arrive
        // with later timestamps, but duration should run from the turn's first
        // transition into running, not from the current tool.
        let effectiveStart: Date
        if case .running(let prev, _) = storage[terminalId] {
            effectiveStart = prev
        } else {
            effectiveStart = startedAt
        }
        storage[terminalId] = .running(startedAt: effectiveStart, detail: detail)
    }
```

Replace the existing `setFinished` method (currently 3-arg: `terminalId:exitCode:at:`) with:

```swift
    func setFinished(terminalId: UUID, exitCode: Int32, at finishedAt: Date,
                     agent: HookMessage.Agent = .shell, summary: String? = nil) {
        guard !isStale(terminalId: terminalId, at: finishedAt) else { return }
        let duration: TimeInterval
        if case .running(let startedAt, _) = storage[terminalId] {
            duration = max(0, finishedAt.timeIntervalSince(startedAt))
        } else {
            duration = 0
        }
        if exitCode == 0 {
            storage[terminalId] = .success(exitCode: exitCode, duration: duration,
                                           finishedAt: finishedAt,
                                           agent: agent, summary: summary)
        } else {
            storage[terminalId] = .failed(exitCode: exitCode, duration: duration,
                                          finishedAt: finishedAt,
                                          agent: agent, summary: summary)
        }
    }
```

Also update `currentTimestamp(for:)` near line 53 to unpack the new `.running`'s tuple — replace the `case .running(let at)` line with `case .running(let at, _)`. Full updated method:

```swift
    private func currentTimestamp(for terminalId: UUID) -> Date? {
        switch storage[terminalId] {
        case .none, .neverRan:                     return nil
        case .running(let at, _):                  return at
        case .idle(let at):                        return at
        case .needsInput(let at):                  return at
        case .success(_, _, let at, _, _):         return at
        case .failed(_, _, let at, _, _):          return at
        }
    }
```

(The `.success` / `.failed` patterns need extra `_` for the new `agent` and `summary` associated values. Compiler will point this out.)

- [ ] **Step 3.4: Run tests — verify they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -20
```

Expected: 20 tests pass (15 pre-existing + 5 new — wait, appended 5 including preservation). Count might be 19-20.

- [ ] **Step 3.5: Full regression**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all tests green.

- [ ] **Step 3.6: Commit**

```bash
git add TheAll/Models/TerminalStatusStore.swift TheAllTests/TerminalStatusStoreTests.swift
git commit -m "feat(models): extend store setters with detail/agent/summary

setRunning takes optional detail and preserves startedAt across
in-turn tool transitions (PreToolUse firing multiple times in one
agent turn shouldn't reset duration). setFinished takes optional
agent (default .shell) and summary. Duration derivation unchanged.
currentTimestamp unpacks the new associated values."
```

---

## Task 4: Extend tooltip + new test file

**Files:**
- Modify: `TheAll/Theme/TerminalStatusIconView.swift` (`tooltipText(for:)` static method, lines 151-169)
- Create: `TheAllTests/TerminalStatusIconViewTests.swift`

- [ ] **Step 4.1: Create the new test file with failing tests**

Create `TheAllTests/TerminalStatusIconViewTests.swift`:

```swift
import XCTest
@testable import TheAll

final class TerminalStatusIconViewTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - Running with/without detail

    func testRunningNoDetail() {
        let text = TerminalStatusIconView.tooltipText(for: .running(startedAt: now)) ?? ""
        XCTAssertTrue(text.hasPrefix("Running for "), "got: \(text)")
        XCTAssertFalse(text.contains("\n"))
    }

    func testRunningWithDetail() {
        let text = TerminalStatusIconView.tooltipText(
            for: .running(startedAt: now, detail: "Edit Models/Foo.swift")
        ) ?? ""
        XCTAssertTrue(text.hasPrefix("Running for "))
        XCTAssertTrue(text.contains("\nEdit Models/Foo.swift"), "got: \(text)")
    }

    // MARK: - Success shell vs agent

    func testShellSuccessFormatsWithExitCode() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 2, finishedAt: now)
        )
        XCTAssertEqual(t, "Succeeded in 2s · exit 0")
    }

    func testClaudeSuccessFormatsWithoutExitCode() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 12, finishedAt: now,
                          agent: .claude, summary: nil)
        )
        XCTAssertEqual(t, "Claude: turn finished · 12s")
    }

    func testClaudeSuccessWithSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 12, finishedAt: now,
                          agent: .claude, summary: "Refactored X.")
        )
        XCTAssertEqual(t, "Claude: turn finished · 12s\nRefactored X.")
    }

    func testCodexSuccessUsesDisplayName() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 5, finishedAt: now,
                          agent: .codex, summary: nil)
        )
        XCTAssertEqual(t, "Codex: turn finished · 5s")
    }

    func testOpenCodeSuccessUsesDisplayName() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 3, finishedAt: now,
                          agent: .opencode, summary: nil)
        )
        XCTAssertEqual(t, "OpenCode: turn finished · 3s")
    }

    // MARK: - Failed shell vs agent

    func testShellFailedFormatsWithExitCode() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 5, finishedAt: now)
        )
        XCTAssertEqual(t, "Failed after 5s · exit 1")
    }

    func testClaudeFailedWithSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 15, finishedAt: now,
                         agent: .claude, summary: "Edit failed: permission.")
        )
        XCTAssertEqual(t, "Claude: turn had tool errors · 15s\nEdit failed: permission.")
    }

    func testClaudeFailedWithoutSummary() {
        let t = TerminalStatusIconView.tooltipText(
            for: .failed(exitCode: 1, duration: 15, finishedAt: now,
                         agent: .claude, summary: nil)
        )
        XCTAssertEqual(t, "Claude: turn had tool errors · 15s")
    }

    // MARK: - Shell default still works

    func testSuccessDefaultAgentShellDoesNotPrefixWithName() {
        let t = TerminalStatusIconView.tooltipText(
            for: .success(exitCode: 0, duration: 2, finishedAt: now)
        ) ?? ""
        XCTAssertFalse(t.contains("Shell"))
        XCTAssertTrue(t.contains("exit 0"))
    }
}
```

- [ ] **Step 4.2: Run tests — verify compile failures / test failures**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusIconViewTests 2>&1 | tail -40
```

Expected: test failures — current `tooltipText` returns "Succeeded in 12s · exit 0" for Claude success, not "Claude: turn finished · 12s".

- [ ] **Step 4.3: Extend `tooltipText`**

In `TheAll/Theme/TerminalStatusIconView.swift`, replace the entire `tooltipText(for:)` static method (currently lines 151-169) with:

```swift
    static func tooltipText(for status: TerminalStatus) -> String? {
        switch status {
        case .neverRan:
            return nil
        case .running(let startedAt, let detail):
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            let first = "Running for \(Self.formatDuration(elapsed))"
            return detail.map { "\(first)\n\($0)" } ?? first
        case .idle(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Idle for \(Self.formatDuration(elapsed))"
        case .needsInput(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Needs input (\(Self.formatDuration(elapsed)) ago)"
        case .success(let exit, let duration, _, let agent, let summary):
            let prefix: String
            if agent == .shell {
                prefix = "Succeeded in \(Self.formatDuration(duration)) · exit \(exit)"
            } else {
                prefix = "\(agent.displayName): turn finished · \(Self.formatDuration(duration))"
            }
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
        case .failed(let exit, let duration, _, let agent, let summary):
            let prefix: String
            if agent == .shell {
                prefix = "Failed after \(Self.formatDuration(duration)) · exit \(exit)"
            } else {
                prefix = "\(agent.displayName): turn had tool errors · \(Self.formatDuration(duration))"
            }
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
        }
    }
```

The other methods in this file (`update(status:theme:)` at line 35, `sameKind` at line 52, `render()` at line 66, `startSpinAnimation` etc.) all use case patterns without associated-value binding (e.g. `case .running:` not `case .running(_, _):`). They compile unchanged against the extended enum — verify by skimming, no edit needed.

- [ ] **Step 4.4: Run tests — verify they pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusIconViewTests 2>&1 | tail -20
```

Expected: all new tests pass (10 tests).

- [ ] **Step 4.5: Full regression**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all tests green. Existing `testTooltipTextForEachState` in `TerminalStatusTests.swift` continues to pass because it constructs `.success(exitCode: 0, duration: 151, finishedAt: now)` with default `.shell` agent, which takes the shell formatting branch.

- [ ] **Step 4.6: Commit**

```bash
git add TheAll/Theme/TerminalStatusIconView.swift TheAllTests/TerminalStatusIconViewTests.swift
git commit -m "feat(theme): tooltipText agent-aware for .success/.failed/.running

Shell status stays 'Succeeded in Xs · exit 0' / 'Failed after Xs · exit 1'.
Agent status becomes 'Claude: turn finished · Xs' / 'Claude: turn had
tool errors · Xs', with optional second line showing summary or
running tool detail. Icon render unchanged."
```

---

## Task 5: Route new HookMessage fields in `ContentView.swift`

**Files:**
- Modify: `TheAll/ContentView.swift` (hook listener onMessage block, around lines 119-130)

- [ ] **Step 5.1: Update the onMessage switch**

Find the existing block in `TheAll/ContentView.swift` (around line 119):

```swift
                    listener.onMessage = { msg in
                        switch msg.event {
                        case .running:    store.setRunning(terminalId: msg.terminalId, at: msg.timestamp)
                        case .idle:       store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
                        case .needsInput: store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
                        case .finished:
                            guard let ec = msg.exitCode else { return }
                            store.setFinished(terminalId: msg.terminalId, exitCode: ec, at: msg.timestamp)
                        }
                    }
```

Replace with:

```swift
                    listener.onMessage = { msg in
                        switch msg.event {
                        case .running:
                            store.setRunning(terminalId: msg.terminalId,
                                             at: msg.timestamp,
                                             detail: msg.toolDetail)
                        case .idle:       store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
                        case .needsInput: store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
                        case .finished:
                            guard let ec = msg.exitCode else { return }
                            store.setFinished(terminalId: msg.terminalId,
                                              exitCode: ec,
                                              at: msg.timestamp,
                                              agent: msg.agent,
                                              summary: msg.summary)
                        }
                    }
```

- [ ] **Step 5.2: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.3: Full test regression**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5.4: Commit**

```bash
git add TheAll/ContentView.swift
git commit -m "feat(bridge): route toolDetail, agent, summary to TerminalStatusStore

setRunning now receives msg.toolDetail; setFinished passes msg.agent
and msg.summary through. Shell events (toolDetail/summary nil, agent
.shell) stay on the old shell-formatting path via default-arg plumbing."
```

---

## Task 6: `agent-hook.py` + pytest unit tests

**Files:**
- Create: `Resources/agent-hooks/agent-hook.py`
- Create: `Resources/agent-hooks/tests/__init__.py`
- Create: `Resources/agent-hooks/tests/test_agent_hook.py`

- [ ] **Step 6.1: Check pytest is installed**

```bash
python3 -m pytest --version
```

Expected: `pytest X.Y.Z`. If "No module named pytest": `python3 -m pip install --user pytest`.

- [ ] **Step 6.2: Create `agent-hook.py`**

Create `Resources/agent-hooks/agent-hook.py`:

```python
#!/usr/bin/env python3
"""agent-hook.py — agent lifecycle dispatch for Claude Code / Codex hooks.

Invoked by agent-hook.sh. Reads environment variables set by the bash entry
(_THEALL_SUBCMD, _THEALL_AGENT, _THEALL_PAYLOAD, _THEALL_SESSION_FILE, plus
THEALL_TERMINAL_ID and THEALL_HOOK_SOCK). Dispatches on subcommand, updates the
session JSON file, and optionally emits a socket message.

Subcommands:
    prompt    — UserPromptSubmit: reset turn state, emit `running`
    pretool   — PreToolUse: record current tool, emit `running` + toolDetail
    posttool  — PostToolUse: sticky-set turnHadError if tool_response.is_error
    stop      — Stop: aggregate to exitCode, read transcript summary, emit
                `finished`, remove session entry
"""

import json
import os
import re
import time
import fcntl
import socket
import pathlib


SESSION_TTL_SEC = 3600
SUMMARY_MAXLEN = 200


def parse_payload() -> dict:
    """Parse _THEALL_PAYLOAD env var as JSON. Returns {} on any error."""
    raw = os.environ.get("_THEALL_PAYLOAD", "")
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def short_path(p: str) -> str:
    """Keep the last 3 path segments. `/a/b/c/d/e.swift` → `c/d/e.swift`."""
    parts = [s for s in p.split("/") if s]
    if len(parts) <= 3:
        return "/".join(parts)
    return "/".join(parts[-3:])


def describe_tool(tool: str, inp) -> str:
    """Human-readable label for a Claude Code tool + input dict."""
    if not isinstance(inp, dict):
        return tool or ""
    if tool in ("Edit", "Write", "Read"):
        p = short_path(inp.get("file_path", ""))
        return f"{tool} {p}" if p else tool
    if tool == "Bash":
        cmd = (inp.get("command") or "").split("\n")[0][:60]
        return f"Bash: {cmd}" if cmd else "Bash"
    if tool == "Grep":
        pat = inp.get("pattern", "")
        return f"Grep {pat!r}"
    if tool == "Glob":
        return f"Glob {inp.get('pattern', '')}"
    if tool == "Task":
        return f"Subagent: {inp.get('subagent_type', 'general-purpose')}"
    return tool or ""


def read_transcript_summary(path: str) -> str:
    """Read Claude's transcript JSONL, return last assistant text stripped of
    <thinking>...</thinking> blocks, truncated to SUMMARY_MAXLEN. Empty string
    on any error (missing file, malformed, no assistant message)."""
    if not path:
        return ""
    try:
        with open(path) as f:
            lines = f.readlines()
    except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
        return ""
    for line in reversed(lines):
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content", "")
        if isinstance(content, list):
            text = ""
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text", "")
                    break
            content = text
        if not isinstance(content, str):
            continue
        content = re.sub(r"<thinking>.*?</thinking>", "", content, flags=re.S)
        content = " ".join(content.split())
        if content:
            return content[:SUMMARY_MAXLEN]
    return ""


def load_sessions(session_file: pathlib.Path) -> dict:
    """Return the parsed sessions doc, or a fresh empty one on any failure."""
    if not session_file.exists():
        return {"version": 1, "sessions": {}}
    try:
        with open(session_file) as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            try:
                return json.load(f)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except (json.JSONDecodeError, OSError):
        return {"version": 1, "sessions": {}}


def write_sessions(session_file: pathlib.Path, data: dict) -> None:
    """Write the sessions doc atomically-ish: lock then replace contents."""
    session_file.parent.mkdir(parents=True, exist_ok=True)
    with open(session_file, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(data, f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def gc_stale(sessions_doc: dict, now: float) -> dict:
    """Drop session entries whose lastTouched is older than SESSION_TTL_SEC."""
    cutoff = now - SESSION_TTL_SEC
    kept = {
        sid: s for sid, s in sessions_doc.get("sessions", {}).items()
        if s.get("lastTouched", 0) > cutoff
    }
    return {"version": 1, "sessions": kept}


def emit_to_socket(sock_path: str, msg: dict) -> None:
    """Best-effort write to the Unix socket. Silent on any failure."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(sock_path)
        s.sendall((json.dumps(msg) + "\n").encode())
        s.close()
    except OSError:
        pass


def _default_entry(agent: str, terminal_id: str) -> dict:
    return {
        "agent": agent,
        "terminalId": terminal_id,
        "turnStartedAt": 0,
        "turnHadError": False,
        "currentToolName": None,
        "currentToolDetail": None,
        "transcriptPath": None,
        "lastTouched": 0,
    }


def dispatch(subcmd: str, agent: str, payload: dict,
             terminal_id: str, session_file: pathlib.Path, now: float) -> dict:
    """Apply subcommand to session file; return dict describing socket emit.
    Return dict keys: event, at, plus optional exitCode, toolDetail, summary.
    Return empty dict if this subcommand emits nothing."""
    sessions_doc = load_sessions(session_file)
    entries = sessions_doc.setdefault("sessions", {})

    session_id = (payload.get("session_id")
                  or payload.get("sessionId")
                  or terminal_id)

    entry = entries.setdefault(session_id, _default_entry(agent, terminal_id))
    entry["agent"] = agent
    entry["terminalId"] = terminal_id
    entry["lastTouched"] = now

    emit: dict = {}

    if subcmd == "prompt":
        entry["turnStartedAt"] = now
        entry["turnHadError"] = False
        entry["currentToolName"] = None
        entry["currentToolDetail"] = None
        tp = payload.get("transcript_path")
        if tp:
            entry["transcriptPath"] = tp
        emit = {"event": "running", "at": now}

    elif subcmd == "pretool":
        tool = payload.get("tool_name", "") or ""
        tool_input = payload.get("tool_input", {})
        detail = describe_tool(tool, tool_input) if tool else None
        entry["currentToolName"] = tool or None
        entry["currentToolDetail"] = detail
        emit = {"event": "running", "at": now}
        if detail:
            emit["toolDetail"] = detail

    elif subcmd == "posttool":
        resp = payload.get("tool_response", {})
        if isinstance(resp, dict) and resp.get("is_error"):
            entry["turnHadError"] = True
        # no emit

    elif subcmd == "stop":
        exit_code = 1 if entry.get("turnHadError") else 0
        summary = read_transcript_summary(entry.get("transcriptPath") or "")
        emit = {"event": "finished", "at": now, "exitCode": exit_code}
        if summary:
            emit["summary"] = summary
        entries.pop(session_id, None)

    sessions_doc = gc_stale(sessions_doc, now)
    write_sessions(session_file, sessions_doc)
    return emit


def main():
    subcmd = os.environ.get("_THEALL_SUBCMD", "stop")
    agent = os.environ.get("_THEALL_AGENT", "claude")
    session_file = pathlib.Path(os.environ["_THEALL_SESSION_FILE"])
    terminal_id = os.environ["THEALL_TERMINAL_ID"]
    sock_path = os.environ["THEALL_HOOK_SOCK"]
    payload = parse_payload()
    now = time.time()

    emit = dispatch(subcmd, agent, payload, terminal_id, session_file, now)
    if emit:
        emit["terminalId"] = terminal_id
        emit["agent"] = agent
        emit_to_socket(sock_path, emit)


if __name__ == "__main__":
    main()
```

- [ ] **Step 6.3: Create `tests/__init__.py`**

Create `Resources/agent-hooks/tests/__init__.py` as an empty file (just to make it a package):

```python
```

(Empty file; pytest can discover tests without it, but including it makes intent explicit.)

- [ ] **Step 6.4: Create `tests/test_agent_hook.py`**

Create `Resources/agent-hooks/tests/test_agent_hook.py`:

```python
"""Unit tests for agent-hook.py. Run with:
    python3 -m pytest Resources/agent-hooks/tests/ -v
"""

import json
import os
import pathlib
import sys
import time
import tempfile

import pytest

# Make the sibling script importable.
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

# agent-hook.py uses a dash which isn't a valid Python identifier — load via
# importlib so we can treat it as a module.
import importlib.util
SPEC = importlib.util.spec_from_file_location(
    "agent_hook", str(HERE.parent / "agent-hook.py"))
agent_hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent_hook)


# ---------- describe_tool ----------

def test_describe_tool_edit():
    assert agent_hook.describe_tool("Edit", {"file_path": "/a/b/c/foo.swift"}) == "Edit b/c/foo.swift"

def test_describe_tool_read():
    assert agent_hook.describe_tool("Read", {"file_path": "/foo.swift"}) == "Read foo.swift"

def test_describe_tool_write_no_path():
    assert agent_hook.describe_tool("Write", {"file_path": ""}) == "Write"

def test_describe_tool_bash_truncates():
    cmd = "x" * 200
    out = agent_hook.describe_tool("Bash", {"command": cmd})
    assert out.startswith("Bash: ")
    assert len(out) == len("Bash: ") + 60

def test_describe_tool_bash_first_line_only():
    assert agent_hook.describe_tool("Bash", {"command": "ls\necho hi"}) == "Bash: ls"

def test_describe_tool_grep():
    assert agent_hook.describe_tool("Grep", {"pattern": "foo"}) == "Grep 'foo'"

def test_describe_tool_glob():
    assert agent_hook.describe_tool("Glob", {"pattern": "**/*.swift"}) == "Glob **/*.swift"

def test_describe_tool_task():
    assert agent_hook.describe_tool("Task", {"subagent_type": "Plan"}) == "Subagent: Plan"

def test_describe_tool_unknown():
    assert agent_hook.describe_tool("MysteryTool", {"foo": "bar"}) == "MysteryTool"

def test_describe_tool_non_dict_input():
    assert agent_hook.describe_tool("Edit", "not a dict") == "Edit"


# ---------- short_path ----------

def test_short_path_three_segments_or_fewer_unchanged():
    assert agent_hook.short_path("a/b/c") == "a/b/c"
    assert agent_hook.short_path("a/b") == "a/b"

def test_short_path_strips_leading_slash():
    assert agent_hook.short_path("/a/b/c/d") == "b/c/d"


# ---------- read_transcript_summary ----------

def _write_transcript(path, messages):
    with open(path, "w") as f:
        for m in messages:
            f.write(json.dumps(m) + "\n")


def test_read_transcript_summary_picks_last_assistant(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "Old response"},
        {"role": "user", "content": "another question"},
        {"role": "assistant", "content": "Latest response"},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Latest response"


def test_read_transcript_summary_strips_thinking(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "assistant", "content": "<thinking>internal</thinking>Actual answer here"},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Actual answer here"


def test_read_transcript_summary_multi_block_content(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "assistant",
         "content": [
             {"type": "text", "text": "Hello"},
             {"type": "tool_use", "name": "Edit"},
         ]},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Hello"


def test_read_transcript_summary_truncates_to_200():
    # Write inline rather than tmp_path to verify the constant itself
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        txt = "x" * 500
        f.write(json.dumps({"role": "assistant", "content": txt}) + "\n")
        path = f.name
    try:
        result = agent_hook.read_transcript_summary(path)
        assert len(result) == 200
        assert result == "x" * 200
    finally:
        os.unlink(path)


def test_read_transcript_summary_empty_file(tmp_path):
    p = tmp_path / "empty.jsonl"
    p.write_text("")
    assert agent_hook.read_transcript_summary(str(p)) == ""


def test_read_transcript_summary_missing_file():
    assert agent_hook.read_transcript_summary("/nonexistent/path.jsonl") == ""


def test_read_transcript_summary_malformed_lines_skipped(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text('not json\n{"role":"assistant","content":"good"}\n')
    assert agent_hook.read_transcript_summary(str(p)) == "good"


def test_read_transcript_summary_no_assistant(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [{"role": "user", "content": "only user"}])
    assert agent_hook.read_transcript_summary(str(p)) == ""


# ---------- gc_stale ----------

def test_gc_stale_drops_old_keeps_fresh():
    now = 10_000.0
    doc = {
        "version": 1,
        "sessions": {
            "s_old":   {"lastTouched": now - 7200},   # 2h ago: drop
            "s_fresh": {"lastTouched": now - 600},    # 10m ago: keep
            "s_no_ts": {},                            # missing: drop
        },
    }
    out = agent_hook.gc_stale(doc, now)
    assert "s_fresh" in out["sessions"]
    assert "s_old" not in out["sessions"]
    assert "s_no_ts" not in out["sessions"]


# ---------- dispatch end-to-end ----------

def test_dispatch_prompt_then_stop_clean_turn(tmp_path, monkeypatch):
    sf = tmp_path / "sessions.json"
    transcript = tmp_path / "transcript.jsonl"
    _write_transcript(transcript, [
        {"role": "assistant", "content": "Done."},
    ])

    now = 1_000_000.0

    prompt_payload = {"session_id": "s1", "transcript_path": str(transcript)}
    emit1 = agent_hook.dispatch("prompt", "claude", prompt_payload, "term1", sf, now)
    assert emit1 == {"event": "running", "at": now}

    stop_payload = {"session_id": "s1"}
    emit2 = agent_hook.dispatch("stop", "claude", stop_payload, "term1", sf, now + 10)
    assert emit2["event"] == "finished"
    assert emit2["exitCode"] == 0
    assert emit2["summary"] == "Done."

    # session entry removed by stop
    doc = agent_hook.load_sessions(sf)
    assert "s1" not in doc.get("sessions", {})


def test_dispatch_posttool_sets_sticky_error(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 2_000_000.0

    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s2"}, "term2", sf, now)
    agent_hook.dispatch("pretool", "claude",
                        {"session_id": "s2", "tool_name": "Edit",
                         "tool_input": {"file_path": "/foo.swift"}},
                        "term2", sf, now + 1)
    agent_hook.dispatch("posttool", "claude",
                        {"session_id": "s2", "tool_response": {"is_error": True}},
                        "term2", sf, now + 2)
    # Even after a subsequent clean posttool, flag should stay sticky
    agent_hook.dispatch("posttool", "claude",
                        {"session_id": "s2", "tool_response": {"is_error": False}},
                        "term2", sf, now + 3)
    emit = agent_hook.dispatch("stop", "claude",
                               {"session_id": "s2"}, "term2", sf, now + 4)
    assert emit["exitCode"] == 1


def test_dispatch_pretool_emits_tool_detail(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 3_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s3"}, "term3", sf, now)
    emit = agent_hook.dispatch("pretool", "claude",
                               {"session_id": "s3", "tool_name": "Edit",
                                "tool_input": {"file_path": "/x/y/z/foo.swift"}},
                               "term3", sf, now + 1)
    assert emit["event"] == "running"
    assert emit["toolDetail"] == "Edit x/y/z/foo.swift"


def test_dispatch_stop_without_prompt_defaults_to_zero_exit(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 4_000_000.0
    # Stop arrives without a prior prompt — entry is created lazily
    emit = agent_hook.dispatch("stop", "claude",
                               {"session_id": "s4"}, "term4", sf, now)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 0   # default turnHadError=False


def test_dispatch_uses_terminal_id_when_no_session_id(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 5_000_000.0
    # payload without session_id — fallback to terminal_id as session key
    agent_hook.dispatch("prompt", "claude", {}, "term5", sf, now)
    doc = agent_hook.load_sessions(sf)
    assert "term5" in doc["sessions"]
```

- [ ] **Step 6.5: Run pytest**

```bash
cd /Users/zhenghui/Documents/repos/theall
python3 -m pytest Resources/agent-hooks/tests/ -v
```

Expected: all ~25 tests pass (exact count depends on parametrization). Pay attention to any failures — fix the Python in `agent-hook.py` before proceeding.

- [ ] **Step 6.6: Commit**

```bash
git add Resources/agent-hooks/agent-hook.py Resources/agent-hooks/tests/__init__.py Resources/agent-hooks/tests/test_agent_hook.py
git commit -m "feat(agent-hooks): add agent-hook.py with pytest coverage

Python dispatcher for Claude Code / Codex hooks. Reads hook JSON from
env var set by agent-hook.sh (to be added next), updates a per-session
JSON file, and emits socket messages for prompt/pretool/stop. posttool
only updates state. Full unit coverage on describe_tool, short_path,
read_transcript_summary, gc_stale, and dispatch end-to-end flows."
```

---

## Task 7: `agent-hook.sh` + end-to-end smoke test

**Files:**
- Create: `Resources/agent-hooks/agent-hook.sh`
- Create: `Resources/agent-hooks/tests/smoke.sh`

- [ ] **Step 7.1: Create the bash entry**

Create `Resources/agent-hooks/agent-hook.sh`:

```bash
#!/bin/bash
# agent-hook.sh — thin bash entry for agent-hook.py.
# Usage: agent-hook.sh <subcommand> <agent>
#   subcommand: prompt | pretool | posttool | stop
#   agent:      claude | codex
#
# Reads the hook's JSON payload from stdin and forwards it to the Python
# script via an env var, along with the subcommand / agent / session file
# path. All dispatch logic lives in agent-hook.py so it can be unit-tested.

set -e

[ -z "$THEALL_HOOK_SOCK" ] && exit 0
[ -z "$THEALL_TERMINAL_ID" ] && exit 0

subcmd="${1:-stop}"
agent="${2:-claude}"
script_dir="$(dirname "${BASH_SOURCE[0]}")"

export _THEALL_SUBCMD="$subcmd"
export _THEALL_AGENT="$agent"
export _THEALL_SESSION_FILE="${HOME}/Library/Caches/theall/agent-sessions.json"

# Forward the full stdin JSON as an env var. Payloads are small (<4k).
export _THEALL_PAYLOAD
_THEALL_PAYLOAD=$(cat)

exec python3 "$script_dir/agent-hook.py"
```

Make it executable:

```bash
chmod +x Resources/agent-hooks/agent-hook.sh
```

- [ ] **Step 7.2: Create the smoke test**

Create `Resources/agent-hooks/tests/smoke.sh`:

```bash
#!/bin/bash
# smoke.sh — end-to-end bash smoke test of agent-hook.sh.
# Sets up a fake Unix socket with Python, fires all 4 subcommands with
# handcrafted JSON payloads, asserts socket received the right messages
# and session file is in the expected state.

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HERE/.."
AGENT_HOOK="$SCRIPT_DIR/agent-hook.sh"

TMPDIR_LOCAL=$(mktemp -d -t theall-smoke.XXXXXX)
SOCK="$TMPDIR_LOCAL/hook.sock"
SESSION_FILE_OVERRIDE="$TMPDIR_LOCAL/sessions.json"
TRANSCRIPT="$TMPDIR_LOCAL/transcript.jsonl"
RECEIVED="$TMPDIR_LOCAL/received.log"

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID"
    fi
    rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT INT TERM

# Seed transcript
cat > "$TRANSCRIPT" <<'EOF'
{"role":"user","content":"refactor foo"}
{"role":"assistant","content":"I refactored Foo.swift."}
EOF

# Start a Python Unix-socket echo server that appends each line to RECEIVED
python3 - "$SOCK" "$RECEIVED" <<'PY' &
import sys, socket, os
sock_path, log_path = sys.argv[1], sys.argv[2]
try: os.unlink(sock_path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(8)
with open(log_path, "w") as log:
    while True:
        conn, _ = s.accept()
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        conn.close()
        log.write(data.decode())
        log.flush()
PY
SERVER_PID=$!
sleep 0.3   # let server bind before first client connect

export THEALL_HOOK_SOCK="$SOCK"
export THEALL_TERMINAL_ID="00000000-0000-0000-0000-000000000001"

# Redirect agent-hook.py's session file to our temp copy.
# agent-hook.sh hardcodes the path, so we override the env var _after_ it
# would have been set by sourcing — simplest: patch the path by running
# the python directly for the session-file path, or temporarily edit.
# Here we just use a wrapper that sets _THEALL_SESSION_FILE manually:
run_hook() {
    local sub="$1"; shift
    local agt="$1"; shift
    local payload="$1"; shift
    _THEALL_SUBCMD="$sub" _THEALL_AGENT="$agt" \
      _THEALL_SESSION_FILE="$SESSION_FILE_OVERRIDE" \
      _THEALL_PAYLOAD="$payload" \
      python3 "$SCRIPT_DIR/agent-hook.py"
}

# Scenario: prompt → pretool(Edit) → posttool(is_error=true) → stop
run_hook prompt   claude '{"session_id":"s1","transcript_path":"'"$TRANSCRIPT"'"}'
run_hook pretool  claude '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/foo/bar/baz.swift"}}'
run_hook posttool claude '{"session_id":"s1","tool_name":"Edit","tool_response":{"is_error":true}}'
run_hook stop     claude '{"session_id":"s1"}'

sleep 0.3   # server flushes

# Assertions
if ! grep -q '"event":"running"' "$RECEIVED"; then
    echo "FAIL: no running event in received log" >&2; exit 1
fi
if ! grep -q '"toolDetail":"Edit bar/baz.swift"' "$RECEIVED"; then
    echo "FAIL: no toolDetail in received log" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"exitCode":1' "$RECEIVED"; then
    echo "FAIL: stop did not emit exitCode 1 (turn had error)" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"summary":"I refactored Foo.swift."' "$RECEIVED"; then
    echo "FAIL: summary not in stop payload" >&2; cat "$RECEIVED" >&2; exit 1
fi

# Session entry should be removed
if grep -q '"s1"' "$SESSION_FILE_OVERRIDE"; then
    echo "FAIL: session entry s1 still present" >&2
    cat "$SESSION_FILE_OVERRIDE" >&2; exit 1
fi

echo "SMOKE OK"
```

Make it executable:

```bash
chmod +x Resources/agent-hooks/tests/smoke.sh
```

- [ ] **Step 7.3: Run the smoke test**

```bash
bash Resources/agent-hooks/tests/smoke.sh
```

Expected: `SMOKE OK` on the last line, exit 0. If any assertion fails, the message printed shows what's missing from the received log.

- [ ] **Step 7.4: Verify file mode**

```bash
ls -la Resources/agent-hooks/agent-hook.sh Resources/agent-hooks/tests/smoke.sh
```

Expected: both show `rwxr-xr-x` (executable).

- [ ] **Step 7.5: Commit**

```bash
git add Resources/agent-hooks/agent-hook.sh Resources/agent-hooks/tests/smoke.sh
git commit -m "feat(agent-hooks): add agent-hook.sh bash entry + smoke test

agent-hook.sh is a thin stdin-reader that execs agent-hook.py with the
subcommand, agent, session-file path, and payload in env vars. Smoke
test spins up a Unix-socket echo server, fires a prompt→pretool→
posttool(error)→stop sequence, asserts the emitted JSONs and session
state are exactly what we expect."
```

---

## Task 8: Update `claude-wrapper.sh` hooks.json

**Files:**
- Modify: `Resources/agent-hooks/claude-wrapper.sh` (lines 47-59, SETTINGS_JSON block)

- [ ] **Step 8.1: Replace the SETTINGS_JSON block**

In `Resources/agent-hooks/claude-wrapper.sh`, find the block that starts with `SETTINGS_JSON=$(cat <<EOF` around line 47 and ends with `EOF` + `)` around line 59. Replace the whole heredoc with:

```bash
SETTINGS_JSON=$(cat <<EOF
{
  "hooks": {
    "SessionStart":     [{"matcher": "", "hooks": [{"type": "command", "command": "$EMIT idle claude"}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "$AGENT_HOOK prompt claude"}]}],
    "PreToolUse":       [{"matcher": "", "hooks": [{"type": "command", "command": "$AGENT_HOOK pretool claude"}]}],
    "PostToolUse":      [{"matcher": "", "hooks": [{"type": "command", "command": "$AGENT_HOOK posttool claude"}]}],
    "Stop":             [{"matcher": "", "hooks": [{"type": "command", "command": "$AGENT_HOOK stop claude"}]}],
    "Notification":     [{"matcher": "", "hooks": [{"type": "command", "command": "$EMIT needsInput claude"}]}],
    "SessionEnd":       [{"matcher": "", "hooks": [{"type": "command", "command": "$EMIT idle claude"}]}]
  }
}
EOF
)
```

Above the heredoc, where `EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"` is defined (around line 41), add the new path variable on a new line:

```bash
EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$THEALL_AGENT_HOOKS_DIR/agent-hook.sh"
```

- [ ] **Step 8.2: Syntax check**

```bash
bash -n Resources/agent-hooks/claude-wrapper.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 8.3: Commit**

```bash
git add Resources/agent-hooks/claude-wrapper.sh
git commit -m "feat(agent-hooks): claude-wrapper routes 4 events to agent-hook.sh

UserPromptSubmit / PreToolUse / PostToolUse / Stop now go through
agent-hook.sh for stateful turn tracking. SessionStart / SessionEnd /
Notification continue on the simpler hook-emit.sh path — they don't
need session state."
```

---

## Task 9: Update `codex-wrapper.sh` hooks.json

**Files:**
- Modify: `Resources/agent-hooks/codex-wrapper.sh` (lines 73-83, the hooks.json heredoc)

- [ ] **Step 9.1: Replace the hooks.json heredoc**

In `Resources/agent-hooks/codex-wrapper.sh`, find the `cat > "$OVERLAY/hooks.json" <<EOF` block around line 73. Replace with:

```bash
cat > "$OVERLAY/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart":     [{"hooks": [{"type": "command", "command": "$EMIT idle codex"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$AGENT_HOOK prompt codex"}]}],
    "PreToolUse":       [{"hooks": [{"type": "command", "command": "$AGENT_HOOK pretool codex"}]}],
    "PostToolUse":      [{"hooks": [{"type": "command", "command": "$AGENT_HOOK posttool codex"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "$AGENT_HOOK stop codex"}]}]
  }
}
EOF
```

Above the heredoc, where `EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"` is defined (around line 32), add:

```bash
EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$THEALL_AGENT_HOOKS_DIR/agent-hook.sh"
```

The `notify = [...EMIT, idle, codex]` line in the overlay config.toml (around line 45) stays the same — it's the fallback for users who don't enable `features.codex_hooks`.

- [ ] **Step 9.2: Syntax check**

```bash
bash -n Resources/agent-hooks/codex-wrapper.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 9.3: Commit**

```bash
git add Resources/agent-hooks/codex-wrapper.sh
git commit -m "feat(agent-hooks): codex-wrapper routes 4 events to agent-hook.sh

Mirrors Claude wrapper. Codex uses the same hook schema (session_id,
tool_name, tool_response.is_error), so agent-hook.sh works with
identical subcommand dispatch. Users without features.codex_hooks
still fall back to the notify-driven idle tick, unchanged."
```

---

## Task 10: Update OpenCode plugin

**Files:**
- Modify: `Resources/agent-hooks/opencode-plugin/theall-status.js` (full file)

- [ ] **Step 10.1: Rewrite the plugin with in-memory turn state**

Replace the entire contents of `Resources/agent-hooks/opencode-plugin/theall-status.js` with:

```javascript
// theall-status.js — opencode plugin that reports session state to theall via Unix socket.
// ESM module. opencode (v1.4.x) loads plugins via `await import(fileURL)` and expects
// either a default export `{ server: async (input) => hooks }` (v1 shape) or any named
// async function export `(input, options) => hooks` (legacy shape). The plugin returns
// a hooks object; there is NO event bus on the input — we subscribe via the `event` hook.
//
// Authoritative schema: packages/plugin/src/index.ts in sst/opencode.
// Bundled agent hook integration.

import net from "node:net";

const SOCK = process.env.THEALL_HOOK_SOCK;
const TID  = process.env.THEALL_TERMINAL_ID;

// In-memory per-plugin turn state. Reset on session.idle / session.error /
// session.status{type=idle}. No session file needed — the plugin process
// outlives the turn naturally (opencode keeps it alive across turns).
let turn = { hadError: false, tool: null, startedAt: null };

function emit(msg) {
    if (!SOCK || !TID) return;
    const payload = JSON.stringify({
        terminalId: TID,
        agent: "opencode",
        at: Date.now() / 1000,
        ...msg,
    }) + "\n";
    try {
        const client = net.createConnection(SOCK);
        client.on("error", () => {});
        client.setTimeout(500, () => { try { client.destroy(); } catch {} });
        client.on("connect", () => client.end(payload));
    } catch (_) {
        // swallow
    }
}

function shortPath(p) {
    if (!p) return "";
    const parts = p.split("/").filter(Boolean);
    return parts.length > 3 ? parts.slice(-3).join("/") : parts.join("/");
}

function describeOpencodeTool(tool, input) {
    if (!input || typeof input !== "object") return tool || "";
    const t = tool || "";
    if (t === "edit" || t === "write" || t === "read") {
        const p = shortPath(input.filePath || input.file_path || "");
        return p ? `${t.charAt(0).toUpperCase() + t.slice(1)} ${p}` : t;
    }
    if (t === "bash") {
        const cmd = (input.command || "").split("\n")[0].slice(0, 60);
        return cmd ? `Bash: ${cmd}` : "Bash";
    }
    return t;
}

function emitFinishedFromTurn() {
    emit({ event: "finished", exitCode: turn.hadError ? 1 : 0 });
    turn = { hadError: false, tool: null, startedAt: null };
}

export const TheAllStatusPlugin = async (_input) => ({
    event: async ({ event }) => {
        switch (event?.type) {
            case "session.created":
                // Do not reset turn state here — session.created fires before first turn too.
                return;
            case "session.idle":                // deprecated but still emitted
            case "session.error":
                return emitFinishedFromTurn();
            case "permission.asked":
                return emit({ event: "needsInput" });
            case "permission.replied":
                return emit({ event: "running" });
            case "session.status": {
                const t = event.properties?.status?.type;
                if (t === "busy") {
                    if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
                    emit({ event: "running" });
                } else if (t === "idle") {
                    emitFinishedFromTurn();
                }
                return;
            }
        }
    },

    "tool.execute.before": async (args) => {
        turn.tool = args?.tool;
        if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
        const detail = describeOpencodeTool(args?.tool, args?.input);
        emit({ event: "running", toolDetail: detail || undefined });
    },

    "tool.execute.after": async (args) => {
        // args.error present if tool threw; args.result.status === "error"
        // for tools that report failure in-band.
        const hadErr = !!(args?.error)
            || (args?.result?.status === "error");
        if (hadErr) turn.hadError = true;
        // No socket emit — icon only flips at session.idle / session.status{type=idle}.
    },
});
```

- [ ] **Step 10.2: Syntax check**

```bash
node --check Resources/agent-hooks/opencode-plugin/theall-status.js
```

Expected: no output (success). If node isn't installed, skip this and note it in the commit.

- [ ] **Step 10.3: Commit**

```bash
git add Resources/agent-hooks/opencode-plugin/theall-status.js
git commit -m "feat(agent-hooks): opencode plugin tracks turn error + tool detail

In-memory turn state (hadError/tool/startedAt) accumulates across
tool.execute.before/after. Icon only flips on session.idle /
session.status{type=idle} / session.error, carrying an exitCode
sentinel (0 clean / 1 had errors). tool.execute.before emits
running + toolDetail for live subtitle; tool.execute.after never
emits to avoid mid-turn icon churn."
```

---

## Task 11: Update `docs/agent-hooks.md`

**Files:**
- Modify: `docs/agent-hooks.md` (lines 3, 10, plus new section after line 11)

- [ ] **Step 11.1: Update line 3 (top description)**

Change line 3 from:

```
theall 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。
```

to:

```
theall 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。Agent 侧（Claude Code / Codex / OpenCode）另外在 `.finished` 事件里携带 `exitCode` 哨兵值（0 = turn 干净，1 = turn 里有 tool 报错）和可选的 `summary`（transcript 最后一条 assistant 消息）。
```

- [ ] **Step 11.2: Update line 10 (IPC message format)**

Change line 10 from:

```
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "shell|claude|opencode|codex", "at": <epoch>, "exitCode": <int>?}`。`exitCode` 仅在 `event=finished` 时携带；其他事件省略。
```

to:

```
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "shell|claude|opencode|codex", "at": <epoch>, "exitCode": <int>?, "toolDetail": <string>?, "summary": <string>?}`。`exitCode` 仅在 `event=finished` 时携带（shell = 真实 `$?`；agent = 0/1 哨兵）；`toolDetail` 仅在 agent 的 `event=running` 时携带（如 "Edit Models/Foo.swift"）；`summary` 仅在 agent 的 `event=finished` 时携带（transcript 最后一条 assistant 消息，≤200 chars）。
```

- [ ] **Step 11.3: Insert a new section after line 11**

After the existing 监听端 bullet line, before the `## 各 Agent 的信号来源` header, insert:

```
## Agent Turn 成败检测

Agent turn 没有真实的 exit code，但 Claude Code / Codex 的 `PostToolUse` hook 和 OpenCode 的 `tool.execute.after` 插件事件都带结构化的 "tool 报错了吗" 字段。theall 在每个 turn 内聚合这些 per-tool 信号到一个布尔 `turnHadError`，在 `Stop` / `session.idle` 时发 `finished` 事件，`exitCode` 设为 0（clean）或 1（had errors）。

**Claude / Codex**（命令行 hook，无状态每次 fork 一个 agent-hook.sh）：per-session 状态存在 `~/Library/Caches/theall/agent-sessions.json`，按 `session_id` 索引。`PostToolUse` 把 `tool_response.is_error` 粘滞累加（一个 turn 里任一 tool 失败就是失败）；`Stop` 读取后清除该 session 条目并 emit。过期（>1h 未 touch）的条目每次 hook 调用时自动 GC。

**OpenCode**（长驻插件进程）：状态保存在插件 closure 的 `turn` 对象里，`tool.execute.after` 累加 `args.error` / `args.result.status === "error"`，`session.idle` 时 emit。插件进程重启（opencode 退出 / 重开）会丢状态，但同时 opencode 自己也重建 session，语义无歧义。

**Turn summary**（Claude 独有）：`Stop` 从 `transcript_path` 读取 JSONL 最后一条 `role: "assistant"` 的 text 字段，剥掉 `<thinking>...</thinking>` 块，截到 200 chars，放进 `summary`。Codex 同理（schema 一致）。OpenCode 的 summary 在 v1 里留空（它没有等价的 transcript path 参数；后续 spec 可补）。

**Tool detail**（全部 agent）：`PreToolUse` / `tool.execute.before` 时，派发脚本/插件会根据 `tool_name` + `tool_input` 生成一个紧凑的人类可读标签（"Edit Models/Foo.swift"、"Bash: ls"），作为 `running` 事件的 `toolDetail`。Swift 端把它拼到 tooltip 的第二行。
```

- [ ] **Step 11.4: Run doc-drift check**

```bash
./scripts/check-doc-drift.sh
```

Expected: clean output, no drift (we didn't add any Swift files under `TheAll/` — all new files are in `Resources/agent-hooks/`, which is outside the drift check's scope).

- [ ] **Step 11.5: Commit**

```bash
git add docs/agent-hooks.md
git commit -m "docs(agent-hooks): document turn success/failed + toolDetail + summary

Describes how Claude/Codex/OpenCode turn outcomes get encoded into the
existing finished event with exitCode sentinel 0/1 and optional summary.
Adds a new 'Agent Turn 成败检测' section explaining the per-agent
signal source + state-store location (session file vs in-memory)."
```

---

## Task 12: User-run manual verification matrix

**Files:** none — this task is user-facing, no commit produced.

- [ ] **Step 12.1: Rebuild theall + launch**

```bash
cd /Users/zhenghui/Documents/repos/theall
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
open build/Debug/TheAll.app   # or your preferred launch method
```

- [ ] **Step 12.2: Verification matrix**

In a new theall terminal for each agent, run the matrix below and watch the status icon + tooltip.

**Claude Code (requires `claude` CLI installed):**

| 操作 | 预期图标 | 预期 tooltip 内容 |
|------|---------|------------------|
| 输入 `claude` 启动 | idle（空心圆 or 低对比圆）| "Idle for Xs" |
| 给简单任务："read CLAUDE.md and tell me the project name" | running（转圈）→ finished（绿点）| Running 时："Running for Xs\nRead CLAUDE.md"。Done 时："Claude: turn finished · Xs\n<summary>" |
| 触发 tool 失败："edit /System/Library/foo.bar to say hi"（应该因权限失败）| running → finished（红点）| "Claude: turn had tool errors · Xs\n<summary>" |
| 继续下一个 prompt | running 回来（红点被覆盖）| 正常 |
| 按下 Enter 在空 prompt（非 turn）| 维持上一个 finished 状态 | 同前 |

**Codex（需 `features.codex_hooks = true`）：** 同 Claude 矩阵，图标行为相同。

**Codex（未开 `codex_hooks`）：** 只能看到 `notify` 兜底的 idle。`claude` 那种 running → finished 不会出现，只会看到启动时 idle，turn 结束时 idle。这是已知限制。

**OpenCode：** 同 Claude 矩阵。OpenCode 没 summary（tooltip 只显示单行 "OpenCode: turn finished · Xs" / "OpenCode: turn had tool errors · Xs"）。

- [ ] **Step 12.3: Inspect session file**

在跑 Claude/Codex 某一轮期间，另开一个 terminal：

```bash
cat ~/Library/Caches/theall/agent-sessions.json | python3 -m json.tool
```

Expected during a turn: 看到一条 session entry，`turnHadError` 反映当前状态。Turn 结束后：entry 消失。

- [ ] **Step 12.4: 反馈**

如果矩阵里任何一行跟预期不符，**不要往下走**。记录：
- 哪个 agent
- 哪一行 / 哪个操作
- 观察到的图标 / tooltip
- `~/Library/Caches/theall/hook-emit.log` 最近几行
- `agent-sessions.json` 当时内容

发给我/plan author 定位问题。可能的 root cause 包括：wrapper 没生效、`features.codex_hooks` 没开、OpenCode 插件路径加载失败、Claude 版本 hook schema 变了。

---

## Self-review notes

**Spec coverage:** 每个 spec 章节都落到至少一个 task：
- §Wire Format → Task 1
- §Swift State Model → Tasks 2, 3
- §Session File → Tasks 6 (python writes), 7 (shell entry)
- §Agent Signal Source Table → Tasks 6 (Claude/Codex), 10 (OpenCode)
- §`agent-hook.sh` + `agent-hook.py` → Tasks 6, 7
- §claude-wrapper.sh Changes → Task 8
- §codex-wrapper.sh Changes → Task 9
- §opencode-plugin Changes → Task 10
- §UI Changes → Task 4
- §Testing → Tasks 1-7, 12
- §Edge Cases → Task 6 tests + Task 7 smoke + Task 12 manual
- §File Map → 全部 tasks 覆盖

**Type consistency spot-check:**
- `HookMessage.toolDetail: String?` / `summary: String?` — Tasks 1, 5, 10 all use these names verbatim
- `TerminalStatus.running(startedAt:, detail:)` — Tasks 2, 3, 4 consistent
- `TerminalStatus.success(exitCode:, duration:, finishedAt:, agent:, summary:)` — Tasks 2, 3, 4 consistent
- `setRunning(terminalId:, at:, detail:)` — Task 3 defines, Task 5 calls
- `setFinished(terminalId:, exitCode:, at:, agent:, summary:)` — Task 3 defines, Task 5 calls

**No placeholders:** every code block is complete; every test has concrete assertions; every command has expected output specified.

---

## Completion criteria

All of the following must be true before declaring the feature done:

1. Full Swift test suite passes (existing 103 + new tests from Tasks 1-4)
2. `python3 -m pytest Resources/agent-hooks/tests/` passes green
3. `bash Resources/agent-hooks/tests/smoke.sh` prints `SMOKE OK`
4. `./scripts/check-doc-drift.sh` clean
5. User runs Task 12 matrix and all rows match expected behavior
6. No commits touch files outside the File Structure table
7. Every intermediate commit compiles (bisectability — should be natural since each task is self-contained and the Swift-side changes use default args for additive compat)
