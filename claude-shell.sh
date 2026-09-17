#!/bin/bash
# The process that actually lives inside the tmux session.
#
# Nothing here is tied to a browser: tmux owns this, ttyd only attaches to it.
# Closing the tab detaches; this keeps running.

cd /workspace 2>/dev/null || cd "${HOME:-/tmp}"

echo "Claude Code -- persistent session 'claude'"
echo "workspace: $(pwd)   (on the /data disk, survives restarts)"
echo "Forgejo through the tunnel: http://127.0.0.1:8080"
echo "Detach with Ctrl-b d. Closing the tab detaches too; this keeps running."
echo

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "No ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is set."
  echo "Claude will ask you to log in; the credentials persist on /data."
  echo
fi

# --continue picks the conversation back up across container restarts, since
# ~/.claude lives on the disk now. It is a no-op on a genuinely fresh session.
if [ -d "$HOME/.claude/projects" ]; then
  claude --continue || claude
else
  claude
fi

echo
echo "claude exited. Type 'claude' to start it again."
echo "Note: 'exit' here ends the persistent session, it does not just detach."
exec /bin/bash -l
