#!/bin/bash
# claude-wrapper.sh — launch Claude Code with theall lifecycle hooks injected
# via `claude --settings <json>` on the top-level REPL/print modes.
#
# Why CLI flag instead of CLAUDE_CONFIG_DIR overlay?
# Claude derives its macOS keychain service name from
# `sha256(CLAUDE_CONFIG_DIR)[:8]` — overriding the env var would shift the
# hash, so OAuth tokens stored in keychain under the real
# `~/.claude` hash become unreachable and the user has to log in again on
# every session. Keeping CLAUDE_CONFIG_DIR untouched and injecting hooks
# via a CLI flag preserves login state and shares it with non-theall claude.
#
# Why a passthrough blocklist?
# claude's subcommands (`mcp`, `doctor`, `--remote-control`, …) inherit
# commander.js's argument parser, which doesn't always recognize the
# top-level `--settings` flag — `claude remote-control` regressed with
# "Unknown argument: { hooks: …}" (issue #26). Hooks are meaningless for
# those one-shot subcommands anyway, so we passthrough without injection
# whenever any arg matches a known subcommand or help/version flag.
#
# Reads THEALL_AGENT_HOOKS_DIR, THEALL_HOOK_SOCK, THEALL_TERMINAL_ID from env.

set -e

# DEBUG: sentinel to confirm wrapper actually gets invoked.
{
    echo "[$(date +%s)] [claude-wrapper] invoked: args=$*  THEALL_AGENT_HOOKS_DIR=${THEALL_AGENT_HOOKS_DIR:+set}  THEALL_HOOK_SOCK=${THEALL_HOOK_SOCK:+set}  THEALL_TERMINAL_ID=${THEALL_TERMINAL_ID:+set}"
} >> "$HOME/Library/Caches/theall/hook-emit.log" 2>/dev/null || true

# Find the real claude binary: skip any shell function / wrapper and the theall wrapper itself.
# Strategy: try THEALL_REAL_CLAUDE env override first; else walk PATH.
REAL_CLAUDE=""
if [ -n "$THEALL_REAL_CLAUDE" ] && [ -x "$THEALL_REAL_CLAUDE" ]; then
    REAL_CLAUDE="$THEALL_REAL_CLAUDE"
else
    for candidate in $(which -a claude 2>/dev/null); do
        # Resolve symlinks and skip our own wrapper path
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *theall*agent-hooks*claude-wrapper*) continue ;;
        esac
        REAL_CLAUDE="$candidate"
        break
    done
fi

if [ -z "$REAL_CLAUDE" ]; then
    echo "theall claude-wrapper: real 'claude' binary not found in PATH" >&2
    echo "  hint: install Claude Code, or set THEALL_REAL_CLAUDE to its path" >&2
    exit 127
fi

# If theall env is missing (e.g. user ran this wrapper outside theall), passthrough.
if [ -z "$THEALL_AGENT_HOOKS_DIR" ] || [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exec "$REAL_CLAUDE" "$@"
fi

# Subcommand / help / version passthrough. Walk all args (not just $1) so
# things like `claude --debug remote-control` are caught too. Source of
# truth: `claude --help` "Commands" section, plus the historical
# `migrate-installer`/`config`/`remote-control` aliases that may not show
# up in --help but still parse. If Claude Code adds a new subcommand and a
# user reports it breaking, append the name here.
#
# Print mode escape: `claude -p update` is a print turn whose prompt happens
# to equal a subcommand name; commander treats the positional as a prompt
# (not a subcommand), so we MUST still inject hooks. Skip the blocklist scan
# whenever `-p`/`--print` is anywhere in args — print mode never combines
# with a subcommand.
PRINT_MODE=0
for arg in "$@"; do
    case "$arg" in
        -p|--print) PRINT_MODE=1; break ;;
    esac
done

if [ "$PRINT_MODE" = "0" ]; then
    for arg in "$@"; do
        case "$arg" in
            agents|auth|auto-mode|config|doctor|install|mcp|migrate-installer|plugin|plugins|project|remote-control|setup-token|ultrareview|update|upgrade|--help|-h|--version|-v)
                exec "$REAL_CLAUDE" "$@"
                ;;
        esac
    done
fi

EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$THEALL_AGENT_HOOKS_DIR/agent-hook.sh"

# Build Claude Code --settings JSON.
# Schema (Claude Code v2): each event → array of hook-groups; each group has
# an empty matcher and a nested hooks array with {type, command} entries.
# Flat {"command": "..."} silently fails to parse — the nested shape is required.
#
# Four events (UserPromptSubmit / PreToolUse / PostToolUse / Stop) route to
# agent-hook.sh for stateful turn tracking (reads hook payload JSON from
# stdin, maintains per-session error flag, emits finished + summary at Stop).
# SessionStart / SessionEnd / Notification stay on hook-emit.sh — they just
# send a bare state event, no stdin parsing needed.
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

# DEBUG: log the full claude invocation we're about to exec.
{
    echo "[$(date +%s)] [claude-wrapper] execing: $REAL_CLAUDE --settings <json> $*"
    echo "[$(date +%s)] [claude-wrapper] SETTINGS_JSON=$SETTINGS_JSON"
} >> "$HOME/Library/Caches/theall/hook-emit.log" 2>/dev/null || true

# --settings merges with user's own settings.json (don't disable those with
# --setting-sources — would break user's model/tool config). If the user has
# their own hooks for the same events, both fire; that's fine.
exec "$REAL_CLAUDE" --settings "$SETTINGS_JSON" "$@"
