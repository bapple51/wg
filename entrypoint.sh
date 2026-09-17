#!/bin/sh
# Starts wireproxy (userspace WireGuard), a persistent Claude Code session in
# tmux, cron for unattended tasks, ttyd to view the session, and Caddy.
#
# WireGuard config comes from either:
#   WG_CONFIG  - a whole wg-quick style config, raw multiline or base64 (preferred)
#   or the individual WG_* vars below (fallback)
#
# The [TCPClientTunnel] section is appended automatically from FORGEJO_TARGET,
# so WG_CONFIG can stay a plain WireGuard config.
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

DATA_DIR="${DATA_DIR:-/data}"

# --- root phase: prepare the persistent disk, then drop privileges ----------
# Render mounts disks root-owned and everything else here runs as uid 10001, so
# this is the one thing that genuinely needs root. It ends in exec, so the
# unprivileged shell inherits PID 1 and Render's signals still land on it.
if [ "$(id -u)" = "0" ]; then
  # The image's WORKDIR is /workspace, which this block is about to replace with
  # a symlink. Step off it first: removing your own cwd leaves the process on a
  # deleted inode, and the next command that calls getcwd() (git, reliably) dies
  # with "Unable to read current working directory".
  cd /

  if [ -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR/workspace" "$DATA_DIR/home" "$DATA_DIR/logs" \
             "$DATA_DIR/tasks" "$DATA_DIR/spool"

    # Migrate the first layout, which persisted only ~/.claude. Claude keeps
    # ~/.claude.json *next to* that directory, so it stayed on the ephemeral
    # filesystem and vanished on every restart, taking the login with it.
    if [ -d "$DATA_DIR/claude" ] && [ ! -e "$DATA_DIR/home/.claude" ]; then
      echo "disk: migrating $DATA_DIR/claude -> $DATA_DIR/home/.claude"
      mv "$DATA_DIR/claude" "$DATA_DIR/home/.claude"
    fi

    chown proxy:proxy "$DATA_DIR" "$DATA_DIR/workspace" "$DATA_DIR/home" \
                      "$DATA_DIR/logs" "$DATA_DIR/tasks" "$DATA_DIR/spool"

    # A recursive chown of a full 15GB disk on every boot would be minutes of
    # dead air, so do it once and leave a marker.
    if [ ! -e "$DATA_DIR/.initialized" ]; then
      echo "disk: first run, taking ownership of $DATA_DIR"
      chown -R proxy:proxy "$DATA_DIR"
      : > "$DATA_DIR/.initialized"
      chown proxy:proxy "$DATA_DIR/.initialized"
    fi

    # Point the paths baked into the image at the disk. /workspace is an empty
    # directory in a fresh image; on a restart it is already this symlink.
    [ -L /workspace ] || rm -rf /workspace
    ln -sfn "$DATA_DIR/workspace" /workspace
    # The whole home directory, not just ~/.claude: Claude also writes
    # ~/.claude.json, and symlinking that single file would not survive either,
    # because an atomic rewrite (temp file + rename) replaces the symlink with
    # a real file. Persisting the directory sidesteps both problems and picks
    # up ~/.git-credentials and anything else Claude decides to keep.
    [ -L /home/proxy ] || rm -rf /home/proxy
    ln -sfn "$DATA_DIR/home" /home/proxy

    echo "disk: $DATA_DIR mounted; /workspace and /home/proxy persist"
  else
    echo "WARNING: $DATA_DIR is not mounted - /workspace and Claude's history"
    echo "WARNING: are ephemeral and will be lost on the next deploy."
    mkdir -p /workspace
    chown proxy:proxy /workspace
  fi

  exec su-exec proxy "$0" "$@"
fi
# --- everything below runs as proxy (uid 10001) ----------------------------

# The exec above inherits cwd=/ from the root phase. Land in the workspace now
# that it points at the disk, so git and Claude both start somewhere real.
cd /workspace 2>/dev/null || cd /

[ -n "${FORGEJO_TARGET:-}" ] || die "FORGEJO_TARGET is required (e.g. 192.168.1.156:3000)"

PORT="${PORT:-10000}"
export PORT
CONF=/tmp/wireproxy.conf
umask 077

if [ -n "${WG_CONFIG:-}" ]; then
  # Accept base64 (single-line, paste-safe) or raw multiline.
  if printf '%s' "$WG_CONFIG" | grep -q '\[Interface\]'; then
    printf '%s\n' "$WG_CONFIG" > "$CONF"
  elif printf '%s' "$WG_CONFIG" | base64 -d 2>/dev/null | grep -q '\[Interface\]'; then
    printf '%s' "$WG_CONFIG" | base64 -d > "$CONF"
  else
    die "WG_CONFIG has no [Interface] section (and is not valid base64 of one)"
  fi

  # Strip CRs from copy-paste, and lines wireproxy rejects.
  sed -i 's/\r$//' "$CONF"
  sed -i -E '/^[[:space:]]*(ListenPort|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig|FwMark)[[:space:]]*=/d' "$CONF"

  grep -q '^[[:space:]]*PrivateKey' "$CONF" || die "WG_CONFIG has no PrivateKey"
  grep -q '^[[:space:]]*Endpoint'   "$CONF" || die "WG_CONFIG has no Endpoint"
else
  for v in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_ENDPOINT; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "$v is required (or set WG_CONFIG instead)"
  done
  {
    echo "[Interface]"
    echo "PrivateKey = ${WG_PRIVATE_KEY}"
    echo "Address = ${WG_ADDRESS:-10.0.0.5/32}"
    echo "DNS = ${WG_DNS:-192.168.1.105}"
    echo "MTU = ${WG_MTU:-1280}"
    echo
    echo "[Peer]"
    echo "PublicKey = ${WG_PEER_PUBLIC_KEY}"
    [ -n "${WG_PRESHARED_KEY:-}" ] && echo "PresharedKey = ${WG_PRESHARED_KEY}"
    echo "Endpoint = ${WG_ENDPOINT}"
    echo "AllowedIPs = ${WG_ALLOWED_IPS:-192.168.1.0/24, 10.0.0.0/24}"
    echo "PersistentKeepalive = ${WG_KEEPALIVE:-25}"
  } > "$CONF"
fi

# Make sure the file ends with a newline before appending.
printf '\n' >> "$CONF"

# Append the local forward unless the config already defines one.
if ! grep -q '\[TCPClientTunnel\]' "$CONF"; then
  {
    echo
    echo "[TCPClientTunnel]"
    echo "BindAddress = 127.0.0.1:8080"
    echo "Target = ${FORGEJO_TARGET}"
  } >> "$CONF"
fi

# Caddy's rewrite needs the LAN origin in three forms: plain, JSON-escaped
# (Forgejo emits "http:\/\/..." inside JSON), and regex-escaped (the header
# directive treats its search argument as a regular expression).
LAN_ORIGIN="${LAN_ORIGIN:-http://${FORGEJO_TARGET}}"
LAN_ORIGIN_JSON=$(printf '%s' "$LAN_ORIGIN" | sed 's|/|\\/|g')
LAN_ORIGIN_RE=$(printf '%s' "$LAN_ORIGIN" | sed -e 's/[.[\*^$()+?{}|]/\\&/g')
export LAN_ORIGIN LAN_ORIGIN_JSON LAN_ORIGIN_RE
echo "rewriting origin: ${LAN_ORIGIN} -> (relative)"

# --- Claude Code terminal --------------------------------------------------
# Off by default. Turning it on publishes a shell into your home LAN, so the
# password is required rather than defaulted.
CLAUDE_TERMINAL="${CLAUDE_TERMINAL:-off}"
CLAUDE_TERM_USER="${CLAUDE_TERM_USER:-claude}"
export CLAUDE_TERM_USER

if [ "$CLAUDE_TERMINAL" = "on" ]; then
  [ -n "${CLAUDE_TERM_PASSWORD:-}" ] || die "CLAUDE_TERMINAL=on requires CLAUDE_TERM_PASSWORD"
  CLAUDE_TERM_HASH=$(caddy hash-password --plaintext "$CLAUDE_TERM_PASSWORD")
else
  # The /claude route is always compiled into the Caddyfile, so close it with a
  # password that exists only inside this command substitution.
  RANDOM_PW=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
  CLAUDE_TERM_HASH=$(caddy hash-password --plaintext "$RANDOM_PW")
  unset RANDOM_PW
fi
export CLAUDE_TERM_HASH

# Child processes have no business seeing the plaintext.
unset CLAUDE_TERM_PASSWORD

# Let git reach Forgejo through the tunnel without prompting. Percent-encode
# any of : / @ ? # in the token before setting it, or the URL will not parse.
if [ -n "${FORGEJO_TOKEN:-}" ]; then
  printf 'http://%s:%s@127.0.0.1:8080\n' "${FORGEJO_USER:-git}" "$FORGEJO_TOKEN" \
    > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  git config --global credential.helper store
  # Clones copied out of the Forgejo UI still say http://192.168.1.156:3000;
  # send those through the tunnel too instead of failing to resolve.
  git config --global url."http://127.0.0.1:8080/".insteadOf "${LAN_ORIGIN}/"
fi
git config --global user.name  "${GIT_AUTHOR_NAME:-Claude}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-claude@localhost}"
git config --global --add safe.directory '*'

# Claude's first run asks for a login method, whether or not
# CLAUDE_CODE_OAUTH_TOKEN already authenticates it, and follows up with a trust
# prompt for the working directory. A cron job cannot answer either, and in the
# browser terminal they are just noise on a box that is already authenticated.
# Seed the answers only when the file is absent - it is Claude's own config and
# it owns the contents from here on.
CLAUDE_JSON="$HOME/.claude.json"
if [ ! -e "$CLAUDE_JSON" ]; then
  cat > "$CLAUDE_JSON" <<'JSONEOF'
{
  "hasCompletedOnboarding": true,
  "hasTrustDialogAccepted": true,
  "bypassPermissionsModeAccepted": true
}
JSONEOF
  chmod 600 "$CLAUDE_JSON"
  echo "claude: seeded $CLAUDE_JSON (onboarding and trust prompts pre-answered)"
fi

start_ttyd() {
  # --interface lo keeps ttyd off the container's external interface, so only
  # Caddy can reach it. --auth-header makes ttyd trust the identity Caddy
  # already verified instead of challenging the websocket a second time.
  # Deliberately no --check-origin: the browser's Origin is the public Render
  # host, not ttyd's own.
  ttyd \
    --port 7681 \
    --interface lo \
    --base-path /claude \
    --auth-header X-Claude-User \
    --cwd /workspace \
    --max-clients "${CLAUDE_TERM_MAX_CLIENTS:-2}" \
    --writable \
    -t titleFixed="Claude Code" \
    -t fontSize=14 \
    -t disableLeaveAlert=true \
    /usr/local/bin/claude-session &
  TTYD_PID=$!
}

# Log the config with secrets masked, so bad pastes are easy to spot.
echo "--- wireproxy config (secrets masked) ---"
sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 ***/' "$CONF"
echo "-----------------------------------------"

# wireproxy can validate the config before we commit to starting anything.
wireproxy -n -c "$CONF" || die "wireproxy rejected the config (see above)"

wireproxy -c "$CONF" &
WG_PID=$!

# Cover the gap before the full trap below is installed, so a SIGTERM during
# startup doesn't orphan wireproxy.
trap 'kill -TERM "$WG_PID" 2>/dev/null; exit 0' TERM INT

# Give the handshake a moment; Caddy retries connections anyway (lb_try_duration).
sleep 3

# --- the persistent Claude session -----------------------------------------
# tmux owns this, not ttyd. It is created once at boot and survives every tab
# close, every reconnect, and ttyd crashing or being disabled.
if [ "$CLAUDE_TERMINAL" = "on" ]; then
  if tmux has-session -t claude 2>/dev/null; then
    echo "claude session: already running"
  else
    tmux new-session -d -s claude -c /workspace /usr/local/bin/claude-shell
    echo "claude session: started (tmux session 'claude', detached)"
  fi
fi

# --- scheduled tasks --------------------------------------------------------
# Edit $DATA_DIR/tasks/crontab on the disk; it is copied into the spool each
# boot. Jobs run as proxy, in UTC.
CRON_PID=""

# cron hands jobs a stripped environment, so a task would otherwise start with
# no API key and fail to authenticate with nothing obvious in the log. Hand
# claude-task the variables it cannot work without. /tmp, not the disk: these
# are secrets, and they are rebuilt from the environment on every boot.
TASK_ENV=/tmp/claude-task.env
: > "$TASK_ENV"
chmod 600 "$TASK_ENV"
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL \
         HOME SHELL USE_BUILTIN_RIPGREP DISABLE_AUTOUPDATER DATA_DIR \
         CLAUDE_TASK_FLAGS CLAUDE_TASK_DIR CLAUDE_TASK_LOG_DAYS; do
  eval "val=\${$v:-}"
  # Deliberately unquoted KEY=VALUE: claude-task reads it with `IFS== read`,
  # which needs no escaping and cannot be tricked into executing anything.
  [ -n "$val" ] && printf '%s=%s\n' "$v" "$val" >> "$TASK_ENV"
done
echo "tasks: environment prepared for cron jobs"
if [ ! -e "$DATA_DIR/tasks/crontab" ] && [ -d "$DATA_DIR/tasks" ]; then
  cat > "$DATA_DIR/tasks/crontab" <<'CRONEOF'
# Scheduled Claude tasks. Standard 5-field cron, times are UTC.
# Jobs run as `proxy`. Logs land in /data/logs/<name>-<timestamp>.log.
#
#   claude-task <name> <prompt...>
#   claude-task <name> -f /data/tasks/prompts/<file>
#
# Uncomment to try it: writes a line into the log every 15 minutes.
# */15 * * * * claude-task heartbeat "Reply with the single word: alive"
#
# A real one - nightly digest of a repo:
# 0 3 * * * cd /workspace/myrepo && git pull -q && claude-task nightly "Summarize commits from the last 24h into NOTES.md, then commit and push"
CRONEOF
  echo "cron: seeded $DATA_DIR/tasks/crontab (all jobs commented out)"
fi

if [ -s "$DATA_DIR/tasks/crontab" ] && grep -qE '^[^#[:space:]]' "$DATA_DIR/tasks/crontab"; then
  cp "$DATA_DIR/tasks/crontab" "$DATA_DIR/spool/proxy"
  chmod 600 "$DATA_DIR/spool/proxy"
  crond -f -c "$DATA_DIR/spool" -L "$DATA_DIR/logs/cron.log" &
  CRON_PID=$!
  echo "cron: running $(grep -cE '^[^#[:space:]]' "$DATA_DIR/tasks/crontab") job(s)"
else
  echo "cron: no active jobs in $DATA_DIR/tasks/crontab"
fi

TTYD_PID=""
TTYD_FAILS=0
if [ "$CLAUDE_TERMINAL" = "on" ]; then
  echo "claude terminal: /claude/ (basic auth user: ${CLAUDE_TERM_USER})"
  start_ttyd
else
  echo "claude terminal: disabled (set CLAUDE_TERMINAL=on to enable)"
fi

echo "caddy: listening on 0.0.0.0:${PORT}"
# These belong to caddy alone. As image-wide ENV they would also redirect
# Claude Code's own config into caddy's state directory.
XDG_DATA_HOME=/tmp/caddy XDG_CONFIG_HOME=/tmp/caddy \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

shutdown() {
  # Ask tmux to end the session cleanly so Claude can flush its history to the
  # disk, rather than having the server killed out from under it.
  tmux kill-server 2>/dev/null || true
  kill -TERM "$WG_PID" "$CADDY_PID" ${TTYD_PID:-} ${CRON_PID:-} 2>/dev/null || true
}
trap 'shutdown; exit 0' TERM INT

# wireproxy and caddy are the service: if either dies, exit non-zero so Render
# restarts the container. ttyd is an add-on, so a crash there is respawned in
# place rather than taking the proxy down with it.
while kill -0 "$WG_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
  if [ "$CLAUDE_TERMINAL" = "on" ] &&
     ! { [ -n "$TTYD_PID" ] && kill -0 "$TTYD_PID" 2>/dev/null; }; then
    TTYD_FAILS=$((TTYD_FAILS + 1))
    if [ "$TTYD_FAILS" -gt 5 ]; then
      echo "ttyd: died 5 times, giving up on the terminal" >&2
      CLAUDE_TERMINAL=off
    else
      echo "ttyd: exited, restarting (${TTYD_FAILS}/5)" >&2
      start_ttyd
    fi
  fi
  sleep 5
done

echo "ERROR: wireproxy or caddy exited; shutting down" >&2
shutdown
exit 1
