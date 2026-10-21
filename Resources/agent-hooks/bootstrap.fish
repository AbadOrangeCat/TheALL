# bootstrap.fish — source this from ~/.config/fish/config.fish to enable theall status hooks.
# Example:
#   if set -q THEALL_AGENT_HOOKS_DIR
#       source "$THEALL_AGENT_HOOKS_DIR/bootstrap.fish"
#   end
test -z "$THEALL_AGENT_HOOKS_DIR"; and return 0
test -f "$THEALL_AGENT_HOOKS_DIR/agent-functions.fish"; and source "$THEALL_AGENT_HOOKS_DIR/agent-functions.fish"
