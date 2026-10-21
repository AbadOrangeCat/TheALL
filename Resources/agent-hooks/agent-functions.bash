# agent-functions.bash — override agent CLI names to point at our wrappers.
# Called by bootstrap.bash.
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0

claude()   { command "$THEALL_AGENT_HOOKS_DIR/claude-wrapper.sh"   "$@"; }
opencode() { command "$THEALL_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@"; }
codex()    { command "$THEALL_AGENT_HOOKS_DIR/codex-wrapper.sh"    "$@"; }

export -f claude opencode codex 2>/dev/null || true
