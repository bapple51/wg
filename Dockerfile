# --- build caddy with the replace-response plugin ---
# The plugin strips the LAN origin out of response bodies, so Forgejo's
# ROOT_URL can stay http://192.168.1.156:3000/ with no change on that host.
FROM caddy:2-builder-alpine AS caddybuild
RUN xcaddy build --with github.com/caddyserver/replace-response

# --- fetch wireproxy (userspace WireGuard), prebuilt and checksum-verified ---
# Note: the project moved from whyvl/wireproxy to windtf/wireproxy, and the Go
# module path moved with it, so `go install github.com/whyvl/...` fails now.
FROM alpine:3.20 AS fetch
ARG WIREPROXY_VERSION=v1.1.3
ARG TARGETARCH=amd64
RUN apk add --no-cache curl
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) sha="e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c" ;; \
      arm64) sha="370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/wp.tar.gz \
      "https://github.com/windtf/wireproxy/releases/download/${WIREPROXY_VERSION}/wireproxy_linux_${TARGETARCH}.tar.gz"; \
    echo "${sha}  /tmp/wp.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/wp.tar.gz -C /usr/local/bin wireproxy; \
    /usr/local/bin/wireproxy --version

# --- runtime ---
FROM alpine:3.20

# ttyd serves the browser terminal; node runs Claude Code. ripgrep is installed
# from apk on purpose: Claude Code ships a glibc-linked ripgrep that will not
# run on musl, so we point it at the system one with USE_BUILTIN_RIPGREP=0.
# bash is here because Claude Code shells out expecting bash, not busybox ash.
# tmux keeps the Claude session alive independently of any browser tab, and
# su-exec drops root after the entrypoint has chown'd the Render disk.
RUN apk add --no-cache \
      ca-certificates libcap su-exec \
      ttyd tmux bash git curl jq less ripgrep \
      nodejs npm

# Claude Code itself. Pinned by the tag you deploy; bump deliberately.
ARG CLAUDE_CODE_VERSION=latest
RUN set -eux; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    claude --version

# Custom caddy goes to its own path. Do NOT overwrite /usr/bin/caddy in the
# official caddy image: that file carries cap_net_bind_service, and exec'ing a
# file with file capabilities as a non-root user fails with EPERM.
COPY --from=caddybuild /usr/bin/caddy /usr/local/bin/caddy
COPY --from=fetch /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-session.sh /usr/local/bin/claude-session
COPY claude-shell.sh /usr/local/bin/claude-shell
COPY claude-task.sh /usr/local/bin/claude-task

RUN set -eux; \
    chmod 0755 /usr/local/bin/caddy /usr/local/bin/wireproxy \
               /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session \
               /usr/local/bin/claude-shell /usr/local/bin/claude-task; \
    chown root:root /usr/local/bin/caddy /usr/local/bin/wireproxy; \
    setcap -r /usr/local/bin/caddy 2>/dev/null || true; \
    adduser -D -u 10001 proxy; \
    mkdir -p /tmp/caddy && chown -R proxy /tmp/caddy; \
    mkdir -p /workspace && chown -R proxy /workspace; \
    /usr/local/bin/caddy version; \
    /usr/local/bin/caddy list-modules | grep -q replace_response; \
    PORT=10000 LAN_ORIGIN=x LAN_ORIGIN_JSON=x LAN_ORIGIN_RE=x \
    CLAUDE_TERM_USER=claude \
    CLAUDE_TERM_HASH='$2a$14$Zkx19XLiW6VYouLHR5NmfOFU0z2GTNmpkT/5qqR7hx4IjWJPDhjvG' \
      /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# Deliberately no `USER proxy`: Render mounts the /data disk root-owned, so the
# entrypoint starts as root purely to chown it, then execs su-exec proxy before
# anything else runs. Nothing that touches the network or Claude runs as root.
WORKDIR /workspace

# HOME must be explicit: Docker defaults it to / regardless of the passwd entry,
# and Claude Code needs a writable ~/.claude (symlinked onto the disk at boot).
# The XDG vars that used to live here moved into entrypoint.sh, scoped to the
# caddy process only, so they no longer redirect Claude's config into caddy's
# state directory.
ENV HOME=/home/proxy \
    SHELL=/bin/bash \
    USE_BUILTIN_RIPGREP=0 \
    DISABLE_AUTOUPDATER=1
EXPOSE 10000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
