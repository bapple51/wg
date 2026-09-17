#!/bin/sh
# Manage the scheduled-task crontab from inside the container.
#
#   claude-cron          show what is scheduled right now
#   claude-cron edit     edit the crontab, then apply it
#   claude-cron apply    apply edits made some other way
#   claude-cron log [n]  tail the cron log
#
# The file you edit ($DATA_DIR/tasks/crontab) lives on the disk and survives
# deploys. The entrypoint copies it into the spool at boot; `apply` does the
# same copy live, so a schedule change does not need a redeploy. crond notices
# the new file within a minute.
set -eu

DATA_DIR="${DATA_DIR:-/data}"
SRC="$DATA_DIR/tasks/crontab"
DST="$DATA_DIR/spool/proxy"

count() { grep -cE '^[^#[:space:]]' "$1" 2>/dev/null || true; }

case "${1:-show}" in
  show)
    echo "editing: $SRC"
    echo "active : $DST"
    echo
    echo "--- scheduled ($(count "$DST") job(s)) ---"
    grep -E '^[^#[:space:]]' "$DST" 2>/dev/null || echo "(none)"
    if [ -f "$SRC" ] && [ -f "$DST" ] && ! cmp -s "$SRC" "$DST"; then
      echo
      echo "NOTE: $SRC has unapplied edits. Run 'claude-cron apply'."
    fi
    ;;
  apply)
    [ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }
    mkdir -p "$DATA_DIR/spool"
    cp "$SRC" "$DST"
    chmod 600 "$DST"
    echo "applied $(count "$SRC") job(s); crond reloads within a minute"
    ;;
  edit)
    "${EDITOR:-vi}" "$SRC"
    exec "$0" apply
    ;;
  log)
    tail -n "${2:-50}" "$DATA_DIR/logs/cron.log" 2>/dev/null \
      || echo "no cron log yet at $DATA_DIR/logs/cron.log"
    ;;
  *)
    echo "usage: claude-cron [show|edit|apply|log [n]]" >&2
    exit 2
    ;;
esac
