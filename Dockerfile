# --- build wireproxy (userspace WireGuard) ---
FROM golang:1-bookworm AS build
ENV GOTOOLCHAIN=auto
RUN CGO_ENABLED=0 go install github.com/whyvl/wireproxy/cmd/wireproxy@v1.1.3

# --- runtime: caddy + wireproxy ---
FROM caddy:2-alpine
COPY --from=build /go/bin/wireproxy /usr/local/bin/wireproxy
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && adduser -D -u 10001 proxy \
    && mkdir -p /tmp/caddy && chown -R proxy /tmp/caddy
USER proxy
ENV XDG_DATA_HOME=/tmp/caddy \
    XDG_CONFIG_HOME=/tmp/caddy
EXPOSE 10000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
