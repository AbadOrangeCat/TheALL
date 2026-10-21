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
if ! grep -q '"event": "running"' "$RECEIVED"; then
    echo "FAIL: no running event in received log" >&2; exit 1
fi
if ! grep -q '"toolDetail": "Edit foo/bar/baz.swift"' "$RECEIVED"; then
    echo "FAIL: no toolDetail in received log" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"exitCode": 1' "$RECEIVED"; then
    echo "FAIL: stop did not emit exitCode 1 (turn had error)" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"summary": "I refactored Foo.swift."' "$RECEIVED"; then
    echo "FAIL: summary not in stop payload" >&2; cat "$RECEIVED" >&2; exit 1
fi

# Session entry should be removed
if grep -q '"s1"' "$SESSION_FILE_OVERRIDE"; then
    echo "FAIL: session entry s1 still present" >&2
    cat "$SESSION_FILE_OVERRIDE" >&2; exit 1
fi

echo "SMOKE OK"
