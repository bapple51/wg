#!/bin/sh
# What the browser terminal drops you into.
#
# Starts Claude Code in /workspace. If Claude exits (or fails to start) we fall
# back to an interactive shell instead of closing the websocket, so a stray
# Ctrl-D doesn't leave the user staring at a dead tab.

cd /workspace 2>/dev/null || cd "${HOME:-/tmp}"

echo "Claude Code @ $(hostname) -- workspace: $(pwd)"
echo "Forgejo is reachable through the tunnel at http://127.0.0.1:8080"
echo

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "No ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is set."
  echo "Claude will ask you to log in; open the URL it prints in another tab."
  echo
fi

claude "$@"

echo
echo "claude exited. Type 'claude' to start it again, or 'exit' to close the tab."
exec /bin/bash -l
