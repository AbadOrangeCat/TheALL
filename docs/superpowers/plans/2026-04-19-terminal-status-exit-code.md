# Terminal Status Exit-Code Wiring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the unused `.success` / `.failed` `TerminalStatus` states by adding a `finished` hook event carrying the shell's `$?` and routing it to `TerminalStatusStore.setFinished`.

**Architecture:** New `finished` wire event with an `exitCode: Int32?` field on `HookMessage`. Shell hooks capture `$?` on the first line of precmd/postexec and emit `finished` only when a preexec actually preceded the prompt return (flag-based for zsh/bash, native `fish_postexec` event for fish). The existing stale-event guard in the store continues to reject out-of-order arrivals. Icon rendering and the `TerminalStatus` enum are already complete — no UI code changes required.

**Tech Stack:** Swift 5 / XCTest, zsh / bash / fish shell scripts, python3 (for socket write inside `hook-emit.sh`).

**Prerequisite (out-of-band):** The repo currently has four staged changes adding `$EPOCHREALTIME` capture in shell hooks (`Resources/agent-hooks/hook-emit.sh`, `shell-hooks.bash`, `shell-hooks.zsh`) and an updated comment in `TerminalStatusStore.isStale`. These must be committed before or together with Task 5 — the hook code in this plan assumes that baseline. If uncommitted at execution time, commit them as their own `feat(agent-hooks): capture $EPOCHREALTIME synchronously before forking hook-emit` commit first, then proceed.

**Spec reference:** `docs/superpowers/specs/2026-04-19-terminal-status-exit-code-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `TheAll/Models/HookMessage.swift` | Modify | Add `.finished` case to `Event`, add `exitCode: Int32?` field |
| `TheAllTests/HookMessageTests.swift` | Modify | Add decoder tests for `.finished` + `exitCode` presence/absence |
| `TheAll/Models/TerminalStatusStore.swift` | Modify | Change `setFinished` to 3-arg form; derive duration from prior `.running` |
| `TheAllTests/TerminalStatusStoreTests.swift` | Modify | Update existing `setFinished` callers; add duration-derivation test |
| `Resources/agent-hooks/hook-emit.sh` | Modify | Accept + validate 4th `exit_code` arg; include in payload for `finished` only; degrade to `idle` on malformed |
| `Resources/agent-hooks/shell-hooks.zsh` | Modify | Flag-based `finished` emission with `$?` captured on precmd first line |
| `Resources/agent-hooks/shell-hooks.bash` | Modify | Same flag pattern, preserving existing DEBUG-trap guards |
| `Resources/agent-hooks/shell-hooks.fish` | Modify | Use `fish_postexec` for finished ($status); keep `fish_prompt` as idle fallback |
| `TheAll/ContentView.swift` | Modify | Route `.finished` event to `store.setFinished` |
| `docs/agent-hooks.md` | Modify | Update IPC wire-format line and event list |

No new files are created. No files are deleted.

---

## Task 1: Extend `HookMessage` decoder

**Files:**
- Modify: `TheAll/Models/HookMessage.swift` (full file, 25 lines)
- Modify: `TheAllTests/HookMessageTests.swift` (add 3 tests)

- [ ] **Step 1.1: Add failing tests for `.finished` decoding**

Edit `TheAllTests/HookMessageTests.swift` — append these three tests inside the `final class HookMessageTests` block, just before the closing `}`:

```swift
    func testDecodeFinishedSuccess() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"shell","at":1713500000.5,"exitCode":0}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .finished)
        XCTAssertEqual(msg.exitCode, 0)
    }

    func testDecodeFinishedNonZero() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"shell","at":1713500000.5,"exitCode":127}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .finished)
        XCTAssertEqual(msg.exitCode, 127)
    }

    func testDecodeIdleHasNoExitCode() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"shell","at":1}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .idle)
        XCTAssertNil(msg.exitCode)
    }
```

- [ ] **Step 1.2: Run tests — verify they fail**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookMessageTests 2>&1 | tail -40
```

Expected: compile errors on `.finished` and `msg.exitCode` — `HookMessage.Event` has no `finished` case, `HookMessage` has no `exitCode` property.

- [ ] **Step 1.3: Implement the changes in `HookMessage.swift`**

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
    /// Present when `event == .finished`. Nil for other events. A `finished`
    /// message without `exitCode` is treated as malformed by the routing layer
    /// and silently dropped.
    let exitCode: Int32?

    var timestamp: Date { Date(timeIntervalSince1970: at) }
}
```

- [ ] **Step 1.4: Run tests — verify they pass**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookMessageTests 2>&1 | tail -20
```

Expected: all 7 `HookMessageTests` pass (4 existing + 3 new). Also verify the pre-existing `testDecodeRunning` / `testDecodeIdleShell` / `testDecodeNeedsInput` / `testDecodeWithOptionalMeta` / `testDecodeUnknownAgentFails` still pass (`Decodable` with new optional field is backward compatible).

- [ ] **Step 1.5: Commit**

```bash
git add TheAll/Models/HookMessage.swift TheAllTests/HookMessageTests.swift
git commit -m "feat(models): add finished event and exitCode to HookMessage

Prepares wire format for shell \$? propagation. No routing yet — emitters
and swift dispatch land in later commits."
```

---

## Task 2: Evolve `setFinished` to derive duration

**Files:**
- Modify: `TheAll/Models/TerminalStatusStore.swift` (lines 22-29)
- Modify: `TheAllTests/TerminalStatusStoreTests.swift` (update 4 call sites + add 2 new tests)

- [ ] **Step 2.1: Update existing test callers + add failing new tests**

Open `TheAllTests/TerminalStatusStoreTests.swift`. Find every call to `store.setFinished(terminalId:exitCode:duration:at:)` and remove the `duration:` argument. Four call sites to change:

- `testSetFinishedExitZeroIsSuccess` (line 26): `store.setFinished(terminalId: id, exitCode: 0, duration: 5, at: t2)` → `store.setFinished(terminalId: id, exitCode: 0, at: t2)`
- `testSetFinishedExitNonZeroIsFailed` (line 37): drop `duration: 3, `
- `testNewRunningAfterFinishOverwrites` (line 48): drop `duration: 1, `
- `testAggregateForIdsUsesPriority` (line 67): drop `duration: 1, `
- `testStatusesSnapshotReturnsAllSetEntries` (line 81): drop `duration: 1, `

Also update the assertion at line 27-30 of `testSetFinishedExitZeroIsSuccess` to expect duration derived from `t1 → t2` (5s):

```swift
    func testSetFinishedExitZeroIsSuccess() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: t1)
        store.setFinished(terminalId: id, exitCode: 0, at: t2)
        XCTAssertEqual(
            store.status(for: id),
            .success(exitCode: 0, duration: 5, finishedAt: t2)
        )
    }
```

And update `testSetFinishedExitNonZeroIsFailed` — no prior running, so duration should be 0:

```swift
    func testSetFinishedExitNonZeroIsFailed() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 2000)
        store.setFinished(terminalId: id, exitCode: 1, at: t)
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 1, duration: 0, finishedAt: t)
        )
    }
```

And `testStatusesSnapshotReturnsAllSetEntries` — terminal `b` has no prior running, so duration is 0:

```swift
    func testStatusesSnapshotReturnsAllSetEntries() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID()
        let t = Date()
        store.setRunning(terminalId: a, at: t)
        store.setFinished(terminalId: b, exitCode: 0, at: t)
        let snap = store.statusesSnapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], .running(startedAt: t))
        XCTAssertEqual(snap[b], .success(exitCode: 0, duration: 0, finishedAt: t))
    }
```

Then append two new tests before the class's closing brace:

```swift
    func testFinishedDurationDerivedFromRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        let started = Date(timeIntervalSince1970: 10_000)
        let finished = Date(timeIntervalSince1970: 10_007.25)
        store.setRunning(terminalId: id, at: started)
        store.setFinished(terminalId: id, exitCode: 0, at: finished)
        XCTAssertEqual(
            store.status(for: id),
            .success(exitCode: 0, duration: 7.25, finishedAt: finished)
        )
    }

    func testFinishedWithoutPriorRunningHasZeroDuration() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finished = Date(timeIntervalSince1970: 20_000)
        store.setFinished(terminalId: id, exitCode: 2, at: finished)
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 2, duration: 0, finishedAt: finished)
        )
    }
```

- [ ] **Step 2.2: Run tests — verify they fail**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -40
```

Expected: compile error — the old `setFinished(terminalId:exitCode:duration:at:)` signature is what `TerminalStatusStore.swift` still exposes; calls without `duration:` don't match.

- [ ] **Step 2.3: Implement the new `setFinished` signature**

In `TheAll/Models/TerminalStatusStore.swift`, replace lines 22-29 (the current `setFinished`) with:

```swift
    func setFinished(terminalId: UUID, exitCode: Int32, at finishedAt: Date) {
        guard !isStale(terminalId: terminalId, at: finishedAt) else { return }
        let duration: TimeInterval
        if case .running(let startedAt) = storage[terminalId] {
            duration = max(0, finishedAt.timeIntervalSince(startedAt))
        } else {
            duration = 0
        }
        if exitCode == 0 {
            storage[terminalId] = .success(exitCode: exitCode, duration: duration, finishedAt: finishedAt)
        } else {
            storage[terminalId] = .failed(exitCode: exitCode, duration: duration, finishedAt: finishedAt)
        }
    }
```

- [ ] **Step 2.4: Run tests — verify they pass**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -20
```

Expected: all `TerminalStatusStoreTests` pass (13 existing updated + 2 new = 15 total).

- [ ] **Step 2.5: Run the full test suite — regression check**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: no other test regresses. In particular `TerminalStatusTests` (which exercises the enum directly) should be unaffected.

- [ ] **Step 2.6: Commit**

```bash
git add TheAll/Models/TerminalStatusStore.swift TheAllTests/TerminalStatusStoreTests.swift
git commit -m "refactor(models): derive setFinished duration from prior running state

Drops the duration parameter from setFinished — the store now computes
it from the terminal's .running(startedAt:) entry when present, falling
back to 0 otherwise. Call sites supply only exitCode + finishedAt.

No production caller today; only tests updated."
```

---

## Task 3: Accept `exit_code` arg in `hook-emit.sh`

**Files:**
- Modify: `Resources/agent-hooks/hook-emit.sh` (lines 3-7 docstring, lines 13-30 arg parsing + payload)

- [ ] **Step 3.1: Rewrite `hook-emit.sh` to accept a 4th `exit_code` arg**

Full replacement for `Resources/agent-hooks/hook-emit.sh`:

```bash
#!/bin/bash
# hook-emit.sh — emit a hook JSON line to $THEALL_HOOK_SOCK
# Usage: hook-emit.sh <event> <agent> [timestamp] [exit_code]
# event:    running | idle | needsInput | finished
# agent:    shell | claude | opencode | codex
# exit_code: integer — required iff event=finished; ignored otherwise.
#            If event=finished and exit_code is missing/non-integer,
#            the event is downgraded to "idle" to keep the wire stream
#            decoder-safe (a finished without exitCode is treated as
#            malformed by theall and silently dropped).

set -e

if [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exit 0   # silently no-op outside theall
fi

event="${1:-running}"
agent="${2:-shell}"
# Optional 3rd arg: float epoch seconds captured by the caller (zsh/bash hook
# reads $EPOCHREALTIME synchronously before forking us). Prefer it over our
# own python-based timer — python cold/warm startup between two `&!` hooks
# varies enough to invert the two timestamps and fool TerminalStatusStore's
# stale-event check.
arg_now="${3:-}"
arg_exit="${4:-}"

if [[ "$arg_now" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    now="$arg_now"
else
    # Fallback for shells that don't pass a timestamp (fish on macOS, bash 3.2).
    # python for portability — `date %s.%N` is Linux-only.
    now=$(python3 -c 'import time; print(time.time())' 2>/dev/null || echo "$(date +%s).0")
fi

# Validate exit code for `finished`; degrade to `idle` if garbage.
if [ "$event" = "finished" ]; then
    if [[ "$arg_exit" =~ ^-?[0-9]+$ ]]; then
        payload="{\"terminalId\":\"$THEALL_TERMINAL_ID\",\"event\":\"finished\",\"agent\":\"$agent\",\"at\":$now,\"exitCode\":$arg_exit}"
    else
        event="idle"
        payload="{\"terminalId\":\"$THEALL_TERMINAL_ID\",\"event\":\"idle\",\"agent\":\"$agent\",\"at\":$now}"
    fi
else
    payload="{\"terminalId\":\"$THEALL_TERMINAL_ID\",\"event\":\"$event\",\"agent\":\"$agent\",\"at\":$now}"
fi

# Debug log — tee every emit to a file so we can verify hooks fire.
# Remove this block once everything works.
log_dir="$HOME/Library/Caches/theall"
mkdir -p "$log_dir" 2>/dev/null
echo "[$now] event=$event agent=$agent tid=${THEALL_TERMINAL_ID:0:8}${arg_exit:+ exit=$arg_exit}" >> "$log_dir/hook-emit.log" 2>/dev/null

# Use python to open and write to the AF_UNIX socket (bash has no native AF_UNIX client)
python3 - "$THEALL_HOOK_SOCK" "$payload" <<'PY' 2>/dev/null || true
import sys, socket
sock_path, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect(sock_path)
    s.sendall((payload + "\n").encode())
finally:
    s.close()
PY
```

- [ ] **Step 3.2: Smoke-test `hook-emit.sh` payload shape locally (no theall running)**

Run this script block in a bash shell to capture what `hook-emit.sh` emits without actually opening a socket — we mock `THEALL_HOOK_SOCK` to a bogus path so the python send fails silently, but the debug log captures the payload intent:

```bash
cd /Users/zhenghui/Documents/repos/theall
export THEALL_HOOK_SOCK=/tmp/theall-nope.sock
export THEALL_TERMINAL_ID=00000000-0000-0000-0000-000000000001
rm -f ~/Library/Caches/theall/hook-emit.log

./Resources/agent-hooks/hook-emit.sh running shell 1700000000.0
./Resources/agent-hooks/hook-emit.sh idle shell 1700000001.0
./Resources/agent-hooks/hook-emit.sh finished shell 1700000002.0 0
./Resources/agent-hooks/hook-emit.sh finished shell 1700000003.0 42
./Resources/agent-hooks/hook-emit.sh finished shell 1700000004.0      # missing exit_code → expect idle
./Resources/agent-hooks/hook-emit.sh finished shell 1700000005.0 abc  # garbage exit_code → expect idle

tail -20 ~/Library/Caches/theall/hook-emit.log
```

Expected output (last 6 lines):
```
[1700000000.0] event=running agent=shell tid=00000000
[1700000001.0] event=idle agent=shell tid=00000000
[1700000002.0] event=finished agent=shell tid=00000000 exit=0
[1700000003.0] event=finished agent=shell tid=00000000 exit=42
[1700000004.0] event=idle agent=shell tid=00000000
[1700000005.0] event=idle agent=shell tid=00000000 exit=abc
```

(The last line's "exit=abc" in the log is fine — that's the raw arg. The event correctly degraded to `idle` in the payload even though the log shows the raw arg.)

- [ ] **Step 3.3: Commit**

```bash
git add Resources/agent-hooks/hook-emit.sh
git commit -m "feat(agent-hooks): accept exit_code arg and emit finished event

hook-emit.sh now takes an optional 4th arg carrying \$?. For
event=finished the exit code is validated and appended to the JSON
payload as exitCode; malformed/missing downgrades to idle to keep
the wire stream decoder-safe."
```

---

## Task 4: zsh hook emits `finished` with `$?`

**Files:**
- Modify: `Resources/agent-hooks/shell-hooks.zsh` (full file)

- [ ] **Step 4.1: Replace the zsh hook with the flag-based version**

Full replacement for `Resources/agent-hooks/shell-hooks.zsh`:

```zsh
# shell-hooks.zsh — theall shell-level status hooks for zsh.
# Source this from your zshrc via the bootstrap script.

# Guard: only run inside theall
[ -z "$THEALL_HOOK_SOCK" ] && return 0
[ -z "$THEALL_TERMINAL_ID" ] && return 0

# Idempotent guard against double-sourcing
[ -n "$_THEALL_SHELL_HOOKS_INSTALLED" ] && return 0
_THEALL_SHELL_HOOKS_INSTALLED=1

# Resolve path to hook-emit.sh — prefer $THEALL_AGENT_HOOKS_DIR, fall back to this file's dir
if [ -n "$THEALL_AGENT_HOOKS_DIR" ]; then
    _THEALL_HOOK_EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
else
    _THEALL_HOOK_EMIT="$(dirname "${(%):-%x}")/hook-emit.sh"
fi

# $EPOCHREALTIME is float seconds-since-epoch, captured synchronously here —
# before we fork hook-emit.sh — so it reflects hook fire time, not python
# startup time. Without this, two `&!`-backgrounded hook-emits race on python
# cold/warm start and can record `running` with a LATER timestamp than the
# following `idle`, leaving TerminalStatusStore stuck in running.
zmodload zsh/datetime 2>/dev/null

_theall_preexec() {
    local LC_NUMERIC=C   # force `.` decimal regardless of user locale
    _THEALL_DID_PREEXEC=1
    "$_THEALL_HOOK_EMIT" running shell "$EPOCHREALTIME" &!
}

_theall_precmd() {
    local ec=$?          # MUST be first line — any prior command clobbers $?
    local LC_NUMERIC=C
    if [ -n "$_THEALL_DID_PREEXEC" ]; then
        unset _THEALL_DID_PREEXEC
        "$_THEALL_HOOK_EMIT" finished shell "$EPOCHREALTIME" "$ec" &!
    else
        # Startup prompt, empty-enter, or Ctrl-C before a command begins —
        # no real command ran, so no exit code to report.
        "$_THEALL_HOOK_EMIT" idle shell "$EPOCHREALTIME" &!
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _theall_preexec
add-zsh-hook precmd _theall_precmd
```

- [ ] **Step 4.2: Manual verification (zsh)**

Rebuild theall (so the updated `Resources/agent-hooks/` is copied into the app bundle via the postBuildScript) and launch it:

```bash
cd /Users/zhenghui/Documents/repos/theall
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
open build/Debug/TheAll.app   # or however you launch the app
```

In a new zsh terminal inside theall, run these and watch the tab/sidebar status icon:

| Command | Expected icon |
|---------|---------------|
| `true`                  | green dot (success) |
| `false`                 | red dot (failed), tooltip "exit 1" |
| `sleep 2; true`         | spinner 2s, then green dot with "2s" in tooltip |
| `(press Enter on empty prompt)` | hollow circle (idle) — **not** green |
| `exit 42; :` (paste both on one line) | red dot, tooltip "exit 42" |

Also tail the hook log in another terminal:
```bash
tail -f ~/Library/Caches/theall/hook-emit.log
```
Each real command should show `event=running` followed by `event=finished exit=<code>`. Empty enters should show only `event=idle`.

- [ ] **Step 4.3: Commit**

```bash
git add Resources/agent-hooks/shell-hooks.zsh
git commit -m "feat(agent-hooks): zsh precmd emits finished with \$?

preexec sets _THEALL_DID_PREEXEC; precmd captures \$? on its first line
and emits finished when the flag is set, idle otherwise. Startup
prompts and empty-enters continue to report idle as before."
```

---

## Task 5: bash hook emits `finished` with `$?`

**Files:**
- Modify: `Resources/agent-hooks/shell-hooks.bash` (full file)

- [ ] **Step 5.1: Replace the bash hook with the flag-based version**

Full replacement for `Resources/agent-hooks/shell-hooks.bash`:

```bash
# shell-hooks.bash — theall shell-level status hooks for bash.
# Source this from your bashrc via the bootstrap script.

[ -z "$THEALL_HOOK_SOCK" ] && return 0
[ -z "$THEALL_TERMINAL_ID" ] && return 0

[ -n "$_THEALL_SHELL_HOOKS_INSTALLED" ] && return 0
_THEALL_SHELL_HOOKS_INSTALLED=1

if [ -n "$THEALL_AGENT_HOOKS_DIR" ]; then
    _THEALL_HOOK_EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
else
    _THEALL_HOOK_EMIT="$(dirname "${BASH_SOURCE[0]}")/hook-emit.sh"
fi

# $EPOCHREALTIME is a bash 5+ builtin (float seconds-since-epoch). Captured
# synchronously here — before we fork hook-emit.sh — so it reflects hook fire
# time, not python startup time. On bash 3.2 (the macOS system bash) the var
# is unset and the empty arg makes hook-emit.sh fall back to its python timer.
_theall_preexec() {
    # Only fire once per interactive command — not for every subcommand in pipelines
    [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
    [[ "$COMP_LINE" != "" ]] && return
    _THEALL_DID_PREEXEC=1
    LC_NUMERIC=C "$_THEALL_HOOK_EMIT" running shell "${EPOCHREALTIME:-}" >/dev/null 2>&1 &
}

_theall_precmd() {
    local ec=$?          # MUST be first line — any prior command clobbers $?
    if [ -n "$_THEALL_DID_PREEXEC" ]; then
        unset _THEALL_DID_PREEXEC
        LC_NUMERIC=C "$_THEALL_HOOK_EMIT" finished shell "${EPOCHREALTIME:-}" "$ec" >/dev/null 2>&1 &
    else
        LC_NUMERIC=C "$_THEALL_HOOK_EMIT" idle shell "${EPOCHREALTIME:-}" >/dev/null 2>&1 &
    fi
}

trap '_theall_preexec' DEBUG
PROMPT_COMMAND="_theall_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

- [ ] **Step 5.2: Manual verification (bash)**

Requires bash available inside theall (`/opt/homebrew/bin/bash` or `/bin/bash`). Start a bash session in a theall tab:

```bash
exec bash -l
```

Then run the same smoke matrix as Task 4.2 (`true` / `false` / `sleep 2; true` / empty enter). Verify icons + `hook-emit.log`.

**Known quirk:** on macOS system bash (3.2) without `$EPOCHREALTIME`, both hooks fall back to `hook-emit.sh`'s python timer. The cold/warm race is still possible; the store's `isStale` guard handles it by dropping the out-of-order event. Worst-case observed symptom: one missing `finished` transition per terminal lifecycle (spinner stays on until the next command). This is an accepted limitation for bash 3.2 and matches pre-existing behavior for idle.

- [ ] **Step 5.3: Commit**

```bash
git add Resources/agent-hooks/shell-hooks.bash
git commit -m "feat(agent-hooks): bash PROMPT_COMMAND emits finished with \$?

Mirrors the zsh flag pattern. _theall_precmd captures \$? first, then
chooses finished (flag set) vs idle. DEBUG trap guards against
PROMPT_COMMAND self-firing and completion subcommands unchanged."
```

---

## Task 6: fish hook uses `fish_postexec` for finished

**Files:**
- Modify: `Resources/agent-hooks/shell-hooks.fish` (full file)

- [ ] **Step 6.1: Replace the fish hook**

Fish has a dedicated `fish_postexec` event that fires after each command with `$status` already populated — cleaner than the flag trick. Keep `fish_prompt` as the startup/empty-enter idle path, but only when no postexec has just fired.

Full replacement for `Resources/agent-hooks/shell-hooks.fish`:

```fish
# shell-hooks.fish — theall shell-level status hooks for fish.
# Source this from config.fish via the bootstrap script.

test -z "$THEALL_HOOK_SOCK"; and return 0
test -z "$THEALL_TERMINAL_ID"; and return 0

if set -q _THEALL_SHELL_HOOKS_INSTALLED
    return 0
end
set -g _THEALL_SHELL_HOOKS_INSTALLED 1

if set -q THEALL_AGENT_HOOKS_DIR
    set -g _THEALL_HOOK_EMIT "$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
else
    set -g _THEALL_HOOK_EMIT (dirname (status -f))"/hook-emit.sh"
end

# fish does not expose $EPOCHREALTIME; pass empty string and let
# hook-emit.sh fall back to python's time.time() — same behavior
# as before the zsh/bash $EPOCHREALTIME optimization.

# Flag semantics: `_theall_skip_next_idle` is set by preexec or postexec and
# consumed by prompt. This prevents fish_prompt from emitting `idle` after
# a real command (where postexec already reported `finished` or `running`),
# which would otherwise overwrite the `.success/.failed` state with `.idle`.

function _theall_preexec --on-event fish_preexec
    set -g _theall_skip_next_idle 1
    $_THEALL_HOOK_EMIT running shell "" >/dev/null 2>&1 &
    disown
end

function _theall_postexec --on-event fish_postexec
    # $status is the just-finished command's exit code; capture before anything.
    set -l ec $status
    set -g _theall_skip_next_idle 1   # keep set — prompt will consume
    $_THEALL_HOOK_EMIT finished shell "" $ec >/dev/null 2>&1 &
    disown
end

function _theall_prompt --on-event fish_prompt
    # If preexec or postexec just fired, consume the flag and skip idle —
    # we've already reported running/finished. Otherwise this is a startup
    # prompt, empty-enter, or Ctrl-C-before-command: emit idle.
    if set -q _theall_skip_next_idle
        set -e _theall_skip_next_idle
    else
        $_THEALL_HOOK_EMIT idle shell "" >/dev/null 2>&1 &
        disown
    end
end
```

- [ ] **Step 6.2: Manual verification (fish)**

Requires fish inside theall (`/opt/homebrew/bin/fish`). Start a fish session:

```fish
exec fish
```

Same smoke matrix as Task 4.2. For the empty-enter case in fish, note that `fish_prompt` fires on every prompt — the `set -q _theall_did_preexec` guard prevents emitting `idle` after a real command (since `fish_postexec` already reported finished and cleared the flag). Only the startup prompt and literal empty-enters emit `idle`.

- [ ] **Step 6.3: Commit**

```bash
git add Resources/agent-hooks/shell-hooks.fish
git commit -m "feat(agent-hooks): fish_postexec emits finished with \$status

Uses fish's native post-command event (which receives \$status directly)
instead of the preexec-flag trick the other shells need. fish_prompt
stays wired but only emits idle when no preexec just fired."
```

---

## Task 7: Route `.finished` in `ContentView`

**Files:**
- Modify: `TheAll/ContentView.swift` (around line 119-124)

- [ ] **Step 7.1: Add the `.finished` case to the hook listener switch**

Open `TheAll/ContentView.swift` and find the block around line 119:

```swift
listener.onMessage = { msg in
    switch msg.event {
    case .running:    store.setRunning(terminalId: msg.terminalId, at: msg.timestamp)
    case .idle:       store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
    case .needsInput: store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
    }
}
```

Replace with:

```swift
listener.onMessage = { msg in
    switch msg.event {
    case .running:    store.setRunning(terminalId: msg.terminalId, at: msg.timestamp)
    case .idle:       store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
    case .needsInput: store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
    case .finished:
        // A finished message missing exitCode is malformed — hook-emit.sh
        // degrades to idle before it reaches us, so this guard is defense
        // in depth for third-party writers.
        guard let ec = msg.exitCode else { return }
        store.setFinished(terminalId: msg.terminalId, exitCode: ec, at: msg.timestamp)
    }
}
```

- [ ] **Step 7.2: Build to verify compile**

Run:
```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. No errors about non-exhaustive switch, no errors about `setFinished` signature.

- [ ] **Step 7.3: Run full test suite as regression check**

Run:
```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all tests pass. In particular `HookSocketListenerTests` and any `ContentView`-adjacent tests should be green.

- [ ] **Step 7.4: Commit**

```bash
git add TheAll/ContentView.swift
git commit -m "feat(bridge): route finished hook event to setFinished

Activates the .success/.failed TerminalStatus states end-to-end. A
finished message without exitCode is dropped silently — hook-emit.sh
already degrades that case to idle, so the guard is defense in depth."
```

---

## Task 8: End-to-end smoke test across all three shells

**Files:** none modified — this task is verification only, producing no commit.

- [ ] **Step 8.1: Rebuild and launch theall once more**

```bash
cd /Users/zhenghui/Documents/repos/theall
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
# launch the built app
```

- [ ] **Step 8.2: Run the full verification matrix per shell**

In each of: zsh (default), bash (`exec bash -l`), fish (`exec fish`), verify all rows of the following matrix by watching the terminal's status dot in the sidebar / tab bar:

| Step | Command | Expected status transition | Expected tooltip |
|------|---------|----------------------------|------------------|
| 1 | (open new terminal) | hollow → hollow (idle at startup) | none |
| 2 | `true` | idle → spinner (brief) → green | "Succeeded in <1s · exit 0" |
| 3 | `false` | green → spinner (brief) → red | "Failed after <1s · exit 1" |
| 4 | `sleep 2` | red → spinner (2s) → green | "Succeeded in 2s · exit 0" |
| 5 | (press Enter on empty prompt) | green → hollow (idle) | none |
| 6 | `exit 5` (careful — some shells exit; do it in a subshell if needed: `(exit 5)`) | hollow → red | "Failed after <1s · exit 5" |

- [ ] **Step 8.3: Verify the sidebar aggregation**

Create a workspace with two tabs, one running `sleep 10` and the other `false`. Open the sidebar: the workspace row's aggregated status dot should show the **running** state (priority running > failed per `TerminalStatus.aggregate`).

After the `sleep 10` completes to green, the aggregate should flip to **failed** (red) because that terminal's latched `.failed` outranks the other's `.success`.

- [ ] **Step 8.4: Check hook log**

Tail `~/Library/Caches/theall/hook-emit.log` during the smoke test and confirm:
- Every real command shows `event=running` then `event=finished exit=<code>`
- Empty enters show only `event=idle`
- No `event=finished exit=abc` or similar garbage rows (indicates a buggy shell hook)

If any row looks wrong, **don't commit past Task 7** — the bug lives in the most recently changed shell hook; revert that task's commit and iterate.

---

## Task 9: Update `docs/agent-hooks.md`

**Files:**
- Modify: `docs/agent-hooks.md` (lines 3 and 10)

- [ ] **Step 9.1: Update the top-of-file description and the wire-format line**

Replace line 3 of `docs/agent-hooks.md`:

**Before:**
```
theall 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。
```

**After:**
```
theall 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。
```

Replace line 10 (IPC message format bullet):

**Before:**
```
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput", "agent": "shell|claude|opencode|codex", "at": <epoch>}`
```

**After:**
```
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "shell|claude|opencode|codex", "at": <epoch>, "exitCode": <int>?}`。`exitCode` 仅在 `event=finished` 时携带；其他事件省略。
```

- [ ] **Step 9.2: Run doc-drift check**

```bash
./scripts/check-doc-drift.sh
```

Expected: clean output, no drift warnings. (This plan doesn't add or rename any `TheAll/` files, so the Directory Structure should still match.)

- [ ] **Step 9.3: Commit**

```bash
git add docs/agent-hooks.md
git commit -m "docs(agent-hooks): document finished event and exitCode field"
```

---

## Self-review notes (recorded during plan authoring)

- **Spec coverage check:** every section of the spec maps to a task —
  - Wire format → Task 1
  - `hook-emit.sh` → Task 3
  - zsh/bash/fish shell hooks → Tasks 4 / 5 / 6
  - Swift routing → Task 7
  - Duration derivation → Task 2
  - Manual verification rows → Task 8
  - Doc updates → Task 9
  - "Out of scope for later" items (agent wrappers, auto-decay) → deliberately not in this plan
- **Placeholder scan:** no `TBD`/`TODO`; every code block is complete; every test shows actual assertions.
- **Type consistency:** `setFinished(terminalId:exitCode:at:)` used in Task 2 (definition), Task 2 tests, and Task 7 (caller) — all three sites match. `HookMessage.Event.finished` + `exitCode: Int32?` used consistently across Tasks 1 and 7.
- **Cross-file wire format:** zsh/bash pass `"$EPOCHREALTIME"` as 3rd arg; fish passes `""`. `hook-emit.sh` accepts both (empty → python fallback). Fish explicitly tested in Task 6.

---

## Completion criteria

All of the following must be true before declaring the feature done:

1. `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests` passes green, with the new tests from Tasks 1 and 2 included
2. All three shells (zsh, bash on homebrew, fish) pass the Task 8.2 matrix
3. `docs/agent-hooks.md` reflects the new event and field (Task 9)
4. `./scripts/check-doc-drift.sh` is clean
5. No files outside the File Structure table were modified
