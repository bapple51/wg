# forgejo-wg-proxy

Puts a home-LAN Forgejo instance (`192.168.1.156:3000`) behind a public HTTPS URL on
Render, over a WireGuard tunnel — **without needing any access to the Forgejo host**.
Caddy rewrites the LAN origin out of responses, so Forgejo's `ROOT_URL` can stay as it
is and the UI, login, browsing, cloning and pushing all work from a plain browser with
no VPN on the client.

```
browser / git --HTTPS--> Render [ caddy -> wireproxy ] --WireGuard/UDP--> router --> Forgejo
```

Three processes in one container:

- **wireproxy** — userspace WireGuard (no `/dev/net/tun` or `NET_ADMIN`, which is why
  this works on Render). Forwards `127.0.0.1:8080` to `192.168.1.156:3000`.
- **Caddy** — listens on `$PORT`, serves the `/clone` zip routes, strips
  `http://192.168.1.156:3000` from HTML/JSON/redirects, and streams git traffic through
  untouched.
- **ttyd + tmux** — optional; a persistent Claude Code session, viewable at `/claude/`
  and password-gated by Caddy. It keeps running with no tab open, and `cron` drives
  unattended tasks against it. Off unless `CLAUDE_TERMINAL=on`. See
  [Claude Code in the browser](#claude-code-in-the-browser).

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

## Claude Code in the browser

`https://<your-service>.onrender.com/claude/` is a full Claude Code terminal running
*inside* the container, on the LAN side of the tunnel. Claude can clone, edit, commit
and push your Forgejo repos over `http://127.0.0.1:8080` without any of it leaving the
tunnel, and you get to it from any browser with no VPN.

It is **off by default**. Turning it on publishes an interactive shell into your home
network behind one password — read [Exposure](#exposure) before you do.

### Turning it on

1. Pick a long random password:

   ```sh
   openssl rand -base64 24
   ```

2. In Render → your service → **Environment**, set:

   | Variable | Value |
   |---|---|
   | `CLAUDE_TERMINAL` | `on` |
   | `CLAUDE_TERM_PASSWORD` | the password from step 1 |
   | `ANTHROPIC_API_KEY` | your API key |

   On a Pro/Max subscription instead of an API key: run `claude setup-token` on your
   own machine, then set `CLAUDE_CODE_OAUTH_TOKEN` to what it prints and leave
   `ANTHROPIC_API_KEY` unset.

3. To let Claude push, add `FORGEJO_USER` and `FORGEJO_TOKEN` (Forgejo → Settings →
   Applications). The entrypoint writes them to `~/.git-credentials` and maps
   `http://192.168.1.156:3000/` to the tunnel, so URLs copied straight out of the
   Forgejo UI clone without editing.

4. Redeploy. The logs should say `claude terminal: /claude/ (basic auth user: claude)`.

### Using it

Open `/claude/`, enter the username (`claude` unless you changed `CLAUDE_TERM_USER`)
and password, and you land in Claude Code in `/workspace`:

```sh
git clone http://127.0.0.1:8080/brain-blossom/<repo>.git
cd <repo>
# then just talk to Claude
```

### The session outlives the tab

Claude does **not** stop when you close the browser. The real session is a tmux
session named `claude`, started by the entrypoint at boot; ttyd only attaches to it.
Closing the tab detaches, exactly like `Ctrl-b d`. Reopen `/claude/` and you are back
in the same live session, mid-task if it was mid-task.

That means you can kick off a long job, close the laptop, and come back to it. The
things that *do* end it:

| | ends the session? |
|---|---|
| closing the tab / losing the network | no, detaches |
| ttyd crashing | no, it is respawned and reattaches |
| typing `exit` in the shell | **yes** — use `Ctrl-b d` to leave |
| Render deploy or restart | yes, but see below |

A restart kills the process, but not your work: `/workspace` and `~/.claude` both live
on the `/data` disk, so the repos are intact and `claude --continue` picks the
conversation back up. `claude-shell` does that automatically on boot.

### Scheduled tasks

Unattended runs are plain cron. Edit `/data/tasks/crontab` — it persists, and is
reloaded into the spool on every boot:

```cron
# 5-field cron, UTC, runs as `proxy`.
0 3 * * * cd /workspace/myrepo && git pull -q && claude-task nightly "Summarize commits from the last 24h into NOTES.md, then commit and push"
```

`claude-task <name> <prompt>` runs `claude --print` and writes everything to
`/data/logs/<name>-<timestamp>.log`, with `<name>-latest.log` pointing at the newest.
Long prompts can live in a file: `claude-task <name> -f /data/tasks/prompts/foo.md`.

The entrypoint seeds `/data/tasks/crontab` with a commented example on first boot, and
logs how many active jobs it found. Logs older than `CLAUDE_TASK_LOG_DAYS` (14) are
pruned after each run.

> **Permissions.** Nobody is there to approve a tool call at 3am, so `claude-task`
> defaults to `--dangerously-skip-permissions`. Inside this container that means
> Claude can run anything, against a network that reaches your whole LAN. Narrow it
> where you can by setting `CLAUDE_TASK_FLAGS`, e.g.
> `--allowedTools "Read,Grep,Glob,Bash(git log:*)"`.

### Knobs

| Variable | Default | Notes |
|---|---|---|
| `CLAUDE_TERMINAL` | `off` | `on` enables the terminal and its route |
| `CLAUDE_TERM_USER` | `claude` | basic-auth username |
| `CLAUDE_TERM_PASSWORD` | — | secret; required when `CLAUDE_TERMINAL=on` |
| `CLAUDE_TERM_MAX_CLIENTS` | `2` | concurrent browser sessions |
| `ANTHROPIC_API_KEY` | — | secret; or use `CLAUDE_CODE_OAUTH_TOKEN` |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | secret; from `claude setup-token` |
| `FORGEJO_USER` / `FORGEJO_TOKEN` | — | secret; git credentials for pushing |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `Claude` / `claude@localhost` | commit identity |
| `CLAUDE_TASK_FLAGS` | `--dangerously-skip-permissions` | what `claude-task` passes to `claude --print` |
| `CLAUDE_TASK_DIR` | `/workspace` | working directory for scheduled tasks |
| `CLAUDE_TASK_LOG_DAYS` | `14` | days of task logs to keep |
| `DATA_DIR` | `/data` | the persistent disk mount |

### How it's wired

ttyd runs on `127.0.0.1:7681` with `--base-path /claude`, so its own asset and
websocket URLs already carry the prefix and Caddy passes the path through untouched.
Caddy does the authentication; ttyd is told to trust the header Caddy sets
(`--auth-header`) instead of challenging the websocket separately.

ttyd's command is not Claude — it is `tmux new-session -A -s claude`. That indirection
is the whole reason sessions survive a closed tab: ttyd sends the child SIGHUP when the
websocket drops, and all that reaches is the tmux client.

The container starts as **root**, but only long enough to `chown` the Render disk
(which is mounted root-owned) and symlink `/workspace` and `~/.claude` onto it. It then
`exec`s `su-exec proxy`, so the shell keeps PID 1 and Render's signals still land.
Nothing that touches the network, Claude or your repos runs as root.

wireproxy and Caddy are the service — if either dies the container exits and Render
restarts it. ttyd is an add-on, so a crash there is respawned in place (five attempts)
and never takes the proxy down with it. Shutdown calls `tmux kill-server` first, giving
Claude a chance to flush its history to the disk.

Layout on the disk:

```
/data/workspace   <- /workspace      repos and working files
/data/claude      <- ~/.claude       history, config, login
/data/tasks/crontab                  your schedule (edit this)
/data/logs/                          task output, cron.log
/data/spool/proxy                    copied from tasks/crontab at boot
```

Alpine notes, in case you edit the Dockerfile: ripgrep comes from `apk`, not from the
copy bundled with Claude Code, because that one is glibc-linked and will not run on
musl — hence `USE_BUILTIN_RIPGREP=0`. `bash` is installed because Claude shells out
expecting it rather than busybox `ash`.

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
| `CLAUDE_TERMINAL` | `off` | Claude Code terminal at `/claude/`; see [its own table](#knobs) |

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
- **`/claude/` returns 401 forever:** the password is wrong, or `CLAUDE_TERMINAL`
  isn't `on` — when it's off the route is deliberately sealed with a random
  password. The startup log line tells you which.
- **`/claude/` loads but the terminal stays blank:** the websocket didn't
  authenticate. Browsers only replay basic-auth credentials on a websocket after
  the page itself was authenticated, so do a hard reload of `/claude/` rather than
  opening a deep link, and check the logs for `ttyd: exited, restarting`.
- **502 on `/claude/` only:** ttyd died. The proxy stays up by design; the logs say
  how many restarts it has had.
- **Permission denied all over `/workspace`:** the disk chown didn't happen. The boot
  log should say `disk: /data mounted`; if it says `WARNING: /data is not mounted`, the
  mount path in Render isn't `/data`.
- **Claude starts fresh every deploy:** `~/.claude` isn't landing on the disk. Check
  for the `disk:` line above and that `/data/claude` exists.
- **A cron job never runs:** the boot log prints how many active jobs it parsed —
  `cron: no active jobs` means every line in `/data/tasks/crontab` is still commented.
  Otherwise check `/data/logs/cron.log` for the fire, and
  `/data/logs/<name>-latest.log` for what Claude did.
- **A cron job fires but does nothing:** almost always a blocked tool call. Widen
  `CLAUDE_TASK_FLAGS`, or check the log for a permission prompt it couldn't answer.

## Exposure

This is a public login page in front of your home network: registration disabled, 2FA
on, strong admin password. Render's IP allowlist helps if you're working from one place.
Take it down when the trip ends.

With `CLAUDE_TERMINAL=on` it is also a public **shell** on the LAN side of the
tunnel, and a single basic-auth password is the only thing in front of it. Anyone
who guesses or replays it gets a root-less but fully interactive session that can
reach `192.168.1.0/24` — not just Forgejo. If you turn it on: use a long random
password, add Render's IP allowlist, and set `CLAUDE_TERMINAL=off` again the moment
you stop needing it. Your `ANTHROPIC_API_KEY` and `FORGEJO_TOKEN` are readable from
that session too, so rotate them if the password ever leaks.

Scheduled tasks widen this further: they run with `--dangerously-skip-permissions` by
default, unattended, on a machine that can reach your whole LAN. A prompt that pulls in
untrusted text — an issue body, a PR description, a web page — is a prompt someone else
partly wrote. Keep task prompts narrow, point them at repos you control, and set
`CLAUDE_TASK_FLAGS` to an `--allowedTools` list whenever the job doesn't genuinely need
everything.
