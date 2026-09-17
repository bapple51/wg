# forgejo-wg-proxy

Puts a home-LAN Forgejo instance (`192.168.1.156:3000`) behind a public HTTPS URL on
Render, over a WireGuard tunnel. The full web UI works, login works, `git clone` over
HTTPS works, and `/clone/<owner>/<repo>` hands you a zip of the repo.

```
browser / git --HTTPS--> Render [ caddy -> wireproxy ] --WireGuard/UDP--> router --> Forgejo
```

Two processes in one container:

- **wireproxy** — userspace WireGuard (no `/dev/net/tun` or `NET_ADMIN` needed, which
  is why this works on Render). Forwards `127.0.0.1:8080` to `192.168.1.156:3000`.
- **Caddy** — listens on `$PORT`, handles the `/clone` routes, and reverse-proxies
  everything else to wireproxy with streaming enabled for git smart-HTTP.

## Step 1 — rotate the WireGuard key

The key you had is compromised. Generate a new pair:

```sh
wg genkey | tee render.key | wg pubkey > render.pub
```

On the WireGuard server, replace the old peer's public key with the contents of
`render.pub`, `AllowedIPs = 10.0.0.5/32`, and delete the old peer entry.

## Step 2 — point Forgejo at the public URL (required)

This is the step that makes browsing and login actually work. Forgejo builds absolute
URLs for its CSS/JS assets, login redirects and CSRF cookies from `ROOT_URL`. If that
still says `http://192.168.1.156:3000/`, a remote browser tries to load assets from your
LAN IP and you get an unstyled, un-loginable page.

In `app.ini`:

```ini
[server]
ROOT_URL = https://<your-service>.onrender.com/

[security]
; Render terminates TLS; trust its X-Forwarded-* headers
REVERSE_PROXY_TRUSTED_PROXIES = *
COOKIE_SECURE = true

[service]
DISABLE_REGISTRATION = true
```

Then restart Forgejo. LAN browsing keeps working (links just point at the public
hostname). SSH clone URLs are unaffected.

`REVERSE_PROXY_TRUSTED_PROXIES = *` is safe only because nothing but this proxy can
reach Forgejo's port. Don't also expose port 3000 to the internet.

## Step 3 — deploy

1. Push this folder to a GitHub/GitLab repo.
2. Render → **New → Blueprint** → pick the repo.
3. When prompted for `WG_CONFIG`, paste the whole WireGuard config (see below).
4. Deploy, then set `ROOT_URL` (step 2) to the hostname Render assigned.

### WG_CONFIG

One env var holds the entire tunnel config. Paste it raw (multiline works in Render's
env var editor) or base64 it into a single line:

```sh
base64 -w0 < render.conf    # macOS: base64 -i render.conf
```

The entrypoint accepts either, strips CRs, drops keys wireproxy rejects
(`ListenPort`, `Table`, `PostUp`, ...), and appends the `[TCPClientTunnel]` section
from `FORGEJO_TARGET`. So `WG_CONFIG` stays a plain WireGuard config you can also feed
to `wg-quick` on a laptop.

On boot the container logs the assembled config with `PrivateKey` and `PresharedKey`
masked, so a bad paste is obvious in the deploy logs.

## Using it

**Browse and log in:** `https://<your-service>.onrender.com/` — normal Forgejo, your
existing accounts and passwords. Turn on 2FA; this login page is now public.

**Download a repo as a zip:**

| URL | Result |
|---|---|
| `/clone/brain-blossom/<repo>` | zip of the default branch |
| `/clone/brain-blossom/<repo>/v1.2` | zip of branch, tag or commit `v1.2` |

These redirect to Forgejo's own `archive/<ref>.zip` endpoint, so private repos still
require you to be logged in or to pass a token. Change the default branch by editing
`FORGEJO_DEFAULT_BRANCH` (currently `main`).

Note: `http://192.168.1.156:3000/brain-blossom` is an owner (user or org) page, not a
repo, so it has no zip of its own. `/clone` needs owner **and** repo.

**Clone with git:**

```sh
git clone https://<user>:<token>@<your-service>.onrender.com/brain-blossom/<repo>.git
```

Tokens come from Forgejo → Settings → Applications. HTTPS only; Render doesn't expose
raw TCP, so no SSH.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `WG_CONFIG` | — | required, secret; whole config, raw or base64 |
| `FORGEJO_TARGET` | `192.168.1.156:3000` | LAN host:port |
| `FORGEJO_DEFAULT_BRANCH` | `main` | used by `/clone` |
| `PORT` | `10000` | set by Render |

Fallback vars, used only when `WG_CONFIG` is unset: `WG_PRIVATE_KEY`,
`WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT`, `WG_ADDRESS`, `WG_DNS`, `WG_MTU`,
`WG_ALLOWED_IPS`, `WG_KEEPALIVE`, `WG_PRESHARED_KEY`.

## Troubleshooting

- **502s / health check failing:** check logs for handshake errors. Verify the DuckDNS
  name resolves to your current IP, UDP 51820 is port-forwarded, and `render.pub` is on
  the server. `wg show` on the server tells you whether a handshake happened.
- **Page loads unstyled, or login bounces you back:** `ROOT_URL` is still the LAN
  address. Redo step 2 and restart Forgejo.
- **Large clones stall:** drop `WG_MTU` to 1200.
- **Bad paste:** compare the masked config in the deploy logs against `render.conf`.
- **Local test:** `docker build -t wgp . && docker run --rm -p 10000:10000 -e FORGEJO_TARGET=192.168.1.156:3000 -e WG_CONFIG="$(base64 -w0 < render.conf)" wgp`

## Exposure

This is a public login page in front of your home network. Keep registration disabled,
use 2FA, keep repos private, and consider Render's IP allowlist if you only clone from
known addresses. Cloudflare Tunnel with Cloudflare Access gives you SSO in front of all
this for free, if you'd rather not have the login page open to the world.
