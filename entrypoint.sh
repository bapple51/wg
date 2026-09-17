#!/bin/sh
# Starts wireproxy (userspace WireGuard) in the background, then Caddy in the foreground.
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

# Log the config with secrets masked, so bad pastes are easy to spot.
echo "--- wireproxy config (secrets masked) ---"
sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 ***/' "$CONF"
echo "-----------------------------------------"

# wireproxy can validate the config before we commit to starting anything.
wireproxy -n -c "$CONF" || die "wireproxy rejected the config (see above)"

wireproxy -c "$CONF" &
WG_PID=$!

trap 'kill -TERM "$WG_PID" 2>/dev/null; exit 0' TERM INT

# Give the handshake a moment; Caddy retries connections anyway (lb_try_duration).
sleep 3

echo "caddy: listening on 0.0.0.0:${PORT}"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# If either process dies, exit non-zero so Render restarts the container.
while kill -0 "$WG_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
  sleep 5
done

echo "ERROR: wireproxy or caddy exited; shutting down" >&2
kill -TERM "$WG_PID" "$CADDY_PID" 2>/dev/null || true
exit 1
