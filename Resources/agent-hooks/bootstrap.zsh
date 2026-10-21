# bootstrap.zsh — source this from ~/.zshrc to enable theall status hooks.
# Example: [ -f "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" ] && source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh"
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.zsh" 2>/dev/null
