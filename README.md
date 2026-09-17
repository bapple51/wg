# forgejo-wg-proxy

Puts a home-LAN Forgejo instance (`192.168.1.156:3000`) behind a public HTTPS URL on
Render, over a WireGuard tunnel — **without needing any access to the Forgejo host**.
Caddy rewrites the LAN origin out of responses, so Forgejo's `ROOT_URL` can stay as it
is and the UI, login, browsing, cloning and pushing all work from a plain browser with
no VPN on the client.

```
browser / git --HTTPS--> Render [ caddy -> wireproxy ] --WireGuard/UDP--> router --> Forgejo
```

Two processes in one container:

- **wireproxy** — userspace WireGuard (no `/dev/net/tun` or `NET_ADMIN`, which is why
  this works on Render). Forwards `127.0.0.1:8080` to `192.168.1.156:3000`.
- **Caddy** — listens on `$PORT`, serves the `/clone` zip routes, strips
  `http://192.168.1.156:3000` from HTML/JSON/redirects, and streams git traffic through
  untouched.

## Step 1 — rotate the WireGuard key

Generate a fresh pair on a machine you trust:

```sh
wg genkey | tee render.key | wg pubkey > render.pub
```

Add `render.pub` as a peer on the WireGuard server with `AllowedIPs = 10.0.0.5/32`.
If you can't reach the server right now, the existing key will work — but treat it as
public and rotate it when you're back.

## Step 2 — deploy

1. Push this folder to a GitHub/GitLab repo.
2. Render → **New → Blueprint** → pick the repo.
3. Paste `WG_CONFIG` when prompted (see below).
4. Wait for the build. It compiles Caddy with the rewrite plugin, so expect a
   couple of minutes.

### WG_CONFIG

One env var holds the whole tunnel config, raw multiline or base64:

```ini
[Interface]
PrivateKey = <your key>
Address = 10.0.0.5/32
DNS = 192.168.1.105
MTU = 1280

[Peer]
PublicKey = n4sIMm33hzPjtVA4keizBz7VvntY/GduwBWY2G6KEAs=
AllowedIPs = 192.168.1.0/24, 10.0.0.0/24
Endpoint = shitpanini.duckdns.org:51820
PersistentKeepalive = 25
```

Base64 it into a single line if multiline pasting misbehaves:

```sh
base64 -w0 < render.conf    # macOS: base64 -i render.conf
```

The entrypoint accepts either, strips CRs, drops keys wireproxy rejects
(`ListenPort`, `Table`, `PostUp`, ...), appends the `[TCPClientTunnel]` section from
`FORGEJO_TARGET`, validates the result with `wireproxy -n`, and logs it with
`PrivateKey`/`PresharedKey` masked so a bad paste is obvious.

## Using it

**Browse and log in:** `https://<your-service>.onrender.com/` — your existing accounts
and passwords. Enable 2FA; this login page is now public.

**Download a repo as a zip:**

| URL | Result |
|---|---|
| `/clone/brain-blossom/<repo>` | zip of the default branch |
| `/clone/brain-blossom/<repo>/v1.2` | zip of branch, tag or commit `v1.2` |

**Clone, pull and push:**

```sh
git clone https://<user>:<token>@<your-service>.onrender.com/brain-blossom/<repo>.git
```

Tokens: Forgejo → Settings → Applications. Push works; git smart-HTTP streams through
without rewriting or buffering.

## What works, and what doesn't

Works: web UI, login and 2FA, repo browsing, issues, PRs, settings, the API, clone,
fetch, push, LFS, release downloads, repo zips.

Doesn't, until `ROOT_URL` is changed on the host:

- **SSH cloning** — Render exposes HTTP only, no raw TCP.
- **Absolute URLs Forgejo generates outside HTML/JSON** — links in notification emails
  and webhook payloads still say `192.168.1.156:3000`.
- **OAuth/OIDC logins** — providers redirect to the registered callback, which points
  at the LAN address. Username/password and tokens are unaffected.

When you're home, set `[server] ROOT_URL = https://<your-service>.onrender.com/` plus
`[security] REVERSE_PROXY_TRUSTED_PROXIES = *` in `app.ini` and restart. Everything
above then works properly and the rewrite becomes a harmless no-op.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `WG_CONFIG` | — | required, secret; whole config, raw or base64 |
| `FORGEJO_TARGET` | `192.168.1.156:3000` | LAN host:port |
| `FORGEJO_DEFAULT_BRANCH` | `main` | used by `/clone` |
| `LAN_ORIGIN` | `http://$FORGEJO_TARGET` | origin to strip; override only if Forgejo's ROOT_URL uses a different host or scheme |
| `PORT` | `10000` | set by Render |

Fallback vars, used only when `WG_CONFIG` is unset: `WG_PRIVATE_KEY`,
`WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT`, `WG_ADDRESS`, `WG_DNS`, `WG_MTU`,
`WG_ALLOWED_IPS`, `WG_KEEPALIVE`, `WG_PRESHARED_KEY`.

## Troubleshooting

- **502s / health check failing:** the logs show the masked config, then WireGuard
  lines. `Handshake did not complete after 5 seconds` means packets aren't reaching
  home — check that the DuckDNS name still resolves to your current IP and that UDP
  51820 is forwarded.
- **Unstyled page:** the body rewrite didn't fire. Check `LAN_ORIGIN` in the logs
  matches the origin in Forgejo's HTML exactly, scheme and port included.
- **Large clones stall:** drop `WG_MTU` to 1200.
- **Bad paste:** compare the masked config in the deploy logs against your file.

## Exposure

This is a public login page in front of your home network: registration disabled, 2FA
on, strong admin password. Render's IP allowlist helps if you're working from one place.
Take it down when the trip ends.
