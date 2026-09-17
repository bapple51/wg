#!/bin/sh
# What ttyd runs for each browser tab.
#
# This is only a viewport. The real session is the tmux session named "claude",
# started by the entrypoint at boot and outliving every tab. Attach if it is
# there, create it if something killed it.
exec tmux new-session -A -s claude -c /workspace /usr/local/bin/claude-shell
