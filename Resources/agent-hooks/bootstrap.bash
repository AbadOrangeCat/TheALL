# bootstrap.bash — source this from ~/.bashrc to enable theall status hooks.
# Example: [ -f "$THEALL_AGENT_HOOKS_DIR/bootstrap.bash" ] && source "$THEALL_AGENT_HOOKS_DIR/bootstrap.bash"
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.bash" 2>/dev/null
