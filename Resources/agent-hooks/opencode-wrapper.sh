#!/bin/bash
# opencode-wrapper.sh — launch opencode with the theall status plugin installed.
# Bundled agent hook integration.

set -e

REAL_OPENCODE=""
if [ -n "$THEALL_REAL_OPENCODE" ] && [ -x "$THEALL_REAL_OPENCODE" ]; then
    REAL_OPENCODE="$THEALL_REAL_OPENCODE"
else
    for candidate in $(which -a opencode 2>/dev/null); do
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *theall*agent-hooks*opencode-wrapper*) continue ;;
        esac
        REAL_OPENCODE="$candidate"
        break
    done
fi

if [ -z "$REAL_OPENCODE" ]; then
    echo "theall opencode-wrapper: real 'opencode' binary not found in PATH" >&2
    echo "  hint: install opencode (https://opencode.ai), or set THEALL_REAL_OPENCODE" >&2
    exit 127
fi

if [ -z "$THEALL_AGENT_HOOKS_DIR" ] || [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exec "$REAL_OPENCODE" "$@"
fi

# Install the plugin into the user's global opencode plugins dir if not already present.
# opencode auto-discovers plugins from ~/.config/opencode/plugins/ per its docs.
PLUGIN_SRC="$THEALL_AGENT_HOOKS_DIR/opencode-plugin/theall-status.js"
USER_PLUGINS="$HOME/.config/opencode/plugins"
mkdir -p "$USER_PLUGINS"
LINK="$USER_PLUGINS/theall-status.js"

if [ ! -e "$LINK" ] || [ "$(readlink "$LINK" 2>/dev/null)" != "$PLUGIN_SRC" ]; then
    # Replace any stale copy/symlink with a fresh symlink to the bundled plugin.
    rm -f "$LINK"
    ln -s "$PLUGIN_SRC" "$LINK"
fi

EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"

# Mark the terminal idle on exit — otherwise the precmd hook has to fire
# before the icon updates, which can lag if the window is force-closed.
trap '"$EMIT" idle opencode 2>/dev/null || true' EXIT INT TERM

# Emit idle BEFORE exec: shell preexec already marked us running when the user
# typed `opencode`, but the plugin's session.created event may not fire
# immediately (or at all, if auto-discovery / plugin API shape mismatches).
# Without this, the UI sits on "running" from launch even though opencode is
# actually idle at its prompt. Plugin events still override this when they fire.
"$EMIT" idle opencode 2>/dev/null || true

exec "$REAL_OPENCODE" "$@"
