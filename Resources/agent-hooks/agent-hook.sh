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
