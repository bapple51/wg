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
FROM caddy:2-alpine
COPY --from=caddybuild /usr/bin/caddy /usr/bin/caddy
COPY --from=fetch /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && adduser -D -u 10001 proxy \
    && mkdir -p /tmp/caddy && chown -R proxy /tmp/caddy \
    && caddy list-modules | grep -q replace_response
USER proxy
ENV XDG_DATA_HOME=/tmp/caddy \
    XDG_CONFIG_HOME=/tmp/caddy
EXPOSE 10000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
