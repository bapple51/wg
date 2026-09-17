#!/bin/sh
# Starts wireproxy (userspace WireGuard), then ttyd (optional Claude Code
# terminal), then Caddy, and supervises the lot.
#
# WireGuard config comes from either:
#   WG_CONFIG  - a whole wg-quick style config, raw multiline or base64 (preferred)
#   or the individual WG_* vars below (fallback)
#
# The [TCPClientTunnel] section is appended automatically from FORGEJO_TARGET,
# so WG_CONFIG can stay a plain WireGuard config.
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

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

trap 'kill -TERM "$WG_PID" "$CADDY_PID" ${TTYD_PID:-} 2>/dev/null; exit 0' TERM INT

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
kill -TERM "$WG_PID" "$CADDY_PID" ${TTYD_PID:-} 2>/dev/null || true
exit 1
