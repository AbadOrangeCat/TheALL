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
