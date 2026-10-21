---
date: 2026-04-19
topic: Terminal status exit-code wiring (`.success` / `.failed` activation)
status: draft
---

# Terminal Status — Exit Code Wiring

## Background

`TerminalStatus` defines six states but the runtime only produces four of them. `.success` and `.failed` are unreachable because the shell hook pipeline (`shell-hooks.{zsh,bash,fish}` → `hook-emit.sh` → `HookSocketListener`) emits `running` / `idle` / `needsInput` and never carries an exit code. `TerminalStatusStore.setFinished(...)` exists but is only invoked from unit tests. `TerminalStatusIconView` already renders the success/failed dots.

This spec wires the last mile: capture `$?` in the shell prompt hook, ship it to theall as a new `finished` event, and route it to `setFinished` so the icons light up.

## Goals

- `.success(exitCode: 0, ...)` after any command that returns 0
- `.failed(exitCode: N, ...)` after any command that returns non-zero
- Preserve current `idle` semantics for: first precmd at shell startup, empty-prompt enter, Ctrl-C before a command begins
- Keep existing stale-event guard (`TerminalStatusStore.isStale`) behavior intact
- zsh, bash, and fish all updated

## Non-Goals

- Auto-fade `.success` / `.failed` back to `.idle` after N seconds — keep current "latched until next command starts" behavior
- Agent wrappers (claude / opencode / codex) emitting `finished` — their state transitions remain running / idle / needsInput
- Changing `TerminalStatus` enum, `TerminalStatusIconView` rendering, or `TerminalStatusStore.setFinished` signature
- Surfacing exit codes elsewhere (tooltips already show them via `TerminalStatusIconView.tooltipText`)

## Wire Format

**New event:** `finished`

**Updated `HookMessage`:**

```swift
struct HookMessage: Decodable, Equatable {
    enum Event: String, Decodable {
        case running
        case idle
        case needsInput
        case finished   // NEW
    }
    let terminalId: UUID
    let event: Event
    let agent: Agent
    let at: TimeInterval
    let exitCode: Int32?   // NEW — required when event == .finished, nil otherwise
}
```

**Wire example:**
```json
{"terminalId":"…","event":"finished","agent":"shell","at":1713500000.123,"exitCode":0}
{"terminalId":"…","event":"finished","agent":"shell","at":1713500001.456,"exitCode":1}
{"terminalId":"…","event":"idle","agent":"shell","at":1713500002.789}
```

Decoder contract: `finished` without `exitCode` is a malformed message → dropped silently (consistent with existing decode-failure behavior in `HookSocketListener.flushBuffer`).

## `hook-emit.sh` Changes

Accept an optional 4th positional arg, only meaningful for `event=finished`:

```
hook-emit.sh <event> <agent> [timestamp] [exit_code]
```

When `event=finished`, emit the `exitCode` field in the JSON payload. For other events, omit it entirely (do not emit `"exitCode":null` — keep payload shape explicit per event).

Validation: `exit_code` must match `^-?[0-9]+$`. On mismatch or missing when `event=finished`, fall back to `idle` event to avoid feeding garbage into the decoder.

## Shell Hook Logic

All three shells share the same idea: use a flag to detect whether a preexec (i.e. a real command) preceded the upcoming precmd. The flag is set in the preexec hook and cleared in the precmd hook — after `$?` is captured.

### zsh (`shell-hooks.zsh`)

```zsh
_theall_preexec() {
    local LC_NUMERIC=C
    _THEALL_DID_PREEXEC=1
    "$_THEALL_HOOK_EMIT" running shell "$EPOCHREALTIME" &!
}

_theall_precmd() {
    local ec=$?                    # MUST be first line
    local LC_NUMERIC=C
    if [ -n "$_THEALL_DID_PREEXEC" ]; then
        unset _THEALL_DID_PREEXEC
        "$_THEALL_HOOK_EMIT" finished shell "$EPOCHREALTIME" "$ec" &!
    else
        "$_THEALL_HOOK_EMIT" idle shell "$EPOCHREALTIME" &!
    fi
}
```

### bash (`shell-hooks.bash`)

Same pattern; still need the `BASH_COMMAND == PROMPT_COMMAND` and `COMP_LINE != ""` guards. `$?` captured on first line of `_theall_precmd`.

```bash
_theall_preexec() {
    [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
    [[ "$COMP_LINE" != "" ]] && return
    _THEALL_DID_PREEXEC=1
    LC_NUMERIC=C "$_THEALL_HOOK_EMIT" running shell "${EPOCHREALTIME:-}" >/dev/null 2>&1 &
}

_theall_precmd() {
    local ec=$?
    if [ -n "$_THEALL_DID_PREEXEC" ]; then
        unset _THEALL_DID_PREEXEC
        LC_NUMERIC=C "$_THEALL_HOOK_EMIT" finished shell "${EPOCHREALTIME:-}" "$ec" >/dev/null 2>&1 &
    else
        LC_NUMERIC=C "$_THEALL_HOOK_EMIT" idle shell "${EPOCHREALTIME:-}" >/dev/null 2>&1 &
    fi
}
```

### fish (`shell-hooks.fish`)

Fish has a dedicated `fish_postexec` event that fires after each command with `$status` already populated — cleaner than the flag trick. Keep `fish_prompt` for the startup/empty-enter idle path.

Flag semantics: `_theall_skip_next_idle` is set by preexec **and** postexec, consumed (erased) by prompt when set. Prompt emits `idle` only when the flag is absent — i.e. startup, empty enter, or Ctrl-C before command start. This inversion is load-bearing: if postexec erased the flag, `fish_prompt` would then emit `idle` after every real command, overwriting the `.success/.failed` state that `finished` just set.

```fish
function _theall_preexec --on-event fish_preexec
    set -g _theall_skip_next_idle 1
    $_THEALL_HOOK_EMIT running shell "" >/dev/null 2>&1 &
    disown
end

function _theall_postexec --on-event fish_postexec
    set -l ec $status
    set -g _theall_skip_next_idle 1   # keep set — prompt will consume
    $_THEALL_HOOK_EMIT finished shell "" $ec >/dev/null 2>&1 &
    disown
end

function _theall_prompt --on-event fish_prompt
    if set -q _theall_skip_next_idle
        set -e _theall_skip_next_idle
    else
        $_THEALL_HOOK_EMIT idle shell "" >/dev/null 2>&1 &
        disown
    end
end
```

Note: fish does not pass `$EPOCHREALTIME` (not a fish builtin) — `hook-emit.sh`'s python fallback remains the source of timestamps for fish, unchanged.

### First-line `$?` discipline

The `local ec=$?` / `set -l ec $status` must be the first statement in the precmd / postexec function. Any intervening command clobbers `$?`. This is the single most fragile invariant; it goes in a comment at each capture site.

## Swift Changes

**`Models/HookMessage.swift`:** add `.finished` to `Event`, add `exitCode: Int32?` field.

**`Models/HookSocketListener.swift`:** no code changes. Decoder already does `JSONDecoder().decode(HookMessage.self, ...)`; adding an optional field and a new enum case is backward-compatible at the decoder level.

**`ContentView.swift` hook listener wiring** (around line 119):

```swift
listener.onMessage = { msg in
    switch msg.event {
    case .running:    store.setRunning(terminalId: msg.terminalId, at: msg.timestamp)
    case .idle:       store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
    case .needsInput: store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
    case .finished:
        guard let ec = msg.exitCode else { return }  // malformed → drop
        // Duration is the elapsed time since the last `running` event for this terminal.
        // We don't have that readily available here; pass 0 and let the store compute
        // it from prior state, or accept a zero and rely on the icon's tooltip
        // `formatDuration` to handle "<1s".
        let duration: TimeInterval = 0
        store.setFinished(terminalId: msg.terminalId,
                          exitCode: ec,
                          duration: duration,
                          at: msg.timestamp)
    }
}
```

### Duration handling

`TerminalStatus.success` / `.failed` carry a `duration: TimeInterval`. The shell hook can compute it (preexec timestamp → precmd timestamp) but that adds cross-invocation shell state. Cleaner: let `TerminalStatusStore.setFinished` derive it from the `.running(startedAt:)` state already in the store.

**`TerminalStatusStore.setFinished` evolution:**

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

The old 4-arg signature (`setFinished(terminalId:exitCode:duration:at:)`) is removed. Existing test callers update to the new 3-arg form; no production caller exists to migrate.

## Testing

**`TerminalStatusStoreTests`:**
- Existing tests update to the new `setFinished(terminalId:exitCode:at:)` signature
- Add: running → setFinished computes duration from startedAt delta
- Add: setFinished without prior running → duration == 0

**New `HookMessageTests`:**
- Decode `{event: "finished", exitCode: 0}` → `.finished` with `exitCode == 0`
- Decode `{event: "finished", exitCode: -1}` → `.finished` with `exitCode == -1`
- Decode `{event: "idle"}` (no exitCode) → `.idle` with `exitCode == nil`
- Decode `{event: "finished"}` without exitCode → still decodes, `exitCode == nil` (routing layer drops it)

**Manual verification:**
- zsh: `true` → green dot; `false` → red dot; press Enter on empty prompt → hollow circle stays (idle)
- bash: same, plus `sleep 2; true` → green with 2s tooltip
- fish: same via `fish_postexec` path

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `$?` clobbered before capture | First-line discipline + comment at each capture site; covered by manual smoke test |
| bash 3.2 lacks `$EPOCHREALTIME` → finished/running timestamps from python timer race each other | Existing `isStale` guard on `finishedAt < startedAt` still protects; worst case one missed finished event, same class of failure as today's running/idle |
| Malformed finished message (no exitCode) | Decoder accepts (field is optional); routing switch drops it silently — preferred over forcing a failure mode that affects unrelated messages |
| Duration == 0 when setFinished arrives before the running event on the same terminal | Accept — stale guard in store drops out-of-order events anyway; duration just shows "<1s" in tooltip |
| User sources old `shell-hooks.*` from a prior install and calls new `hook-emit.sh` (or vice versa) | Old hooks call `hook-emit.sh idle` → still works (4th arg is optional). New hooks calling an old `hook-emit.sh`: extra arg ignored by bash, no crash, but `exitCode` never lands in payload → swift drops the malformed finished event. Acceptable — user re-bootstraps to fix |

## Implementation Order

1. **Swift decoder + store** — update `HookMessage`, `setFinished`, tests. Compile green, tests pass. Still no production finished events flowing.
2. **`hook-emit.sh`** — accept + validate 4th arg, emit exitCode in payload.
3. **zsh hook** — switch to flag + finished event; smoke test.
4. **bash hook** — same.
5. **fish hook** — fish_postexec path.
6. **Route in `ContentView.swift`** — wire `.finished` → `store.setFinished`.
7. **Manual verification** across all three shells.
8. **Doc updates** — `docs/agent-hooks.md` (wire format), `docs/architecture.md` (hook pipeline section if it references the event list).

## Out of Scope for Later

- Agent hooks emitting finished with exit code (claude/opencode/codex)
- Auto-decay `.success` / `.failed` → `.idle` after N seconds
- Per-command duration threshold for "significant" runs (currently all latch)
