#!/bin/sh
# Run one unattended Claude task. This is what cron lines call.
#
#   claude-task <name> <prompt...>
#   claude-task <name> -f /data/tasks/prompts/<file>
#
# Output goes to /data/logs/<name>-<timestamp>.log, with <name>-latest.log
# symlinked at the newest run.
set -u

# cron hands you a near-empty PATH; npm's global bin is not on it by default.
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

DATA_DIR="${DATA_DIR:-/data}"
LOG_DIR="$DATA_DIR/logs"

[ $# -ge 2 ] || { echo "usage: claude-task <name> <prompt...|-f file>" >&2; exit 2; }

NAME="$1"
shift

if [ "$1" = "-f" ]; then
  [ -r "$2" ] || { echo "claude-task: cannot read prompt file: $2" >&2; exit 2; }
  PROMPT=$(cat "$2")
else
  PROMPT="$*"
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${NAME}-$(date -u +%Y%m%d-%H%M%S).log"
ln -sfn "$LOG" "$LOG_DIR/${NAME}-latest.log"

# Unattended means nobody is there to approve a tool call, so Claude has to be
# told up front what it may do. The default bypasses every check: that is the
# only way a cron job gets through a run, and it is why CLAUDE_TASK_FLAGS is
# overridable with something narrower like
#   --allowedTools "Read,Grep,Glob,Bash(git log:*)"
CLAUDE_TASK_FLAGS="${CLAUDE_TASK_FLAGS:---dangerously-skip-permissions}"

cd "${CLAUDE_TASK_DIR:-/workspace}" 2>/dev/null || cd /workspace

{
  echo "=== ${NAME} started $(date -u +%Y-%m-%dT%H:%M:%SZ) in $(pwd) ==="
  echo "--- prompt ---"
  printf '%s\n' "$PROMPT"
  echo "--- output ---"
  # shellcheck disable=SC2086
  claude --print "$PROMPT" --output-format text $CLAUDE_TASK_FLAGS
  status=$?
  echo
  echo "=== ${NAME} exit ${status} at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
} >> "$LOG" 2>&1

# 15GB is a lot of disk, but not if a chatty task runs every five minutes.
find "$LOG_DIR" -name '*.log' -type f -mtime "+${CLAUDE_TASK_LOG_DAYS:-14}" \
  -delete 2>/dev/null || true
