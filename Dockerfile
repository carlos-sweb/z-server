# z-server 0.1.1 — Alpine 3.24 multi-stage (Path A: native musl).
#
# Alpine 3.24 (not 3.20): 3.20 reached EOL on 2026-04-01. 3.24 is the
# current stable branch (support until 2028-06-01). apk zig is 0.16.0-r1,
# so the builder downloads the official Zig 0.17.0 tarball (statically
# linked; runs on musl). Expected image size: 20–40 MB.

# amd64 digest of alpine:3.24.4 (linux/amd64).
FROM alpine:3.24@sha256:0f49f331d9212aff11b932863be4eb01cdf962969aa86dab7d1ee21ac6f5f52b AS builder

# sqlite-dev: headers + libsqlite3.so for linkSystemLibrary("sqlite3").
# build-base / linux-headers: musl-dev, gcc toolchain, kernel headers for
# compiling vendored pogocache.c via Zig's C frontend.
# git: build.zig.zon deps are git+https (httpz, translate-c); zig-pkg/ is
# not copied into the build context.
RUN apk add --no-cache \
        build-base \
        sqlite-dev \
        linux-headers \
        ca-certificates \
        curl \
        xz \
        git

# Official Zig 0.17.0 linux x86_64 tarball (no musl-specific build exists).
# SHA256 from https://ziglang.org/download/index.json (0.17.0 / x86_64-linux).
ENV ZIG_VERSION=0.17.0 \
    ZIG_TARBALL=zig-x86_64-linux-0.17.0.tar.xz \
    ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -C /opt -xJf /tmp/zig.tar.xz \
    && ln -s /opt/zig-x86_64-linux-0.17.0/zig /usr/local/bin/zig \
    && rm -f /tmp/zig.tar.xz \
    && zig version

WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.24@sha256:0f49f331d9212aff11b932863be4eb01cdf962969aa86dab7d1ee21ac6f5f52b

# sqlite-libs: runtime libsqlite3.so.0 (no headers). musl libc is in the base.
# BusyBox wget is present for HEALTHCHECK; no extra wget package.
RUN apk add --no-cache sqlite-libs ca-certificates \
    && addgroup -g 1000 zserver \
    && adduser -u 1000 -G zserver -D -H -s /sbin/nologin zserver \
    && mkdir -p /app/data \
    && chown -R zserver:zserver /app

COPY --from=builder /src/zig-out/bin/z-server /usr/local/bin/z-server

# Docker port publish DNAT hits eth0, not loopback. Default without this
# env is 127.0.0.1:8080 (host-dev). See README.docker.md.
ENV Z_SERVER_BIND=0.0.0.0:8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 --start-period=5s \
    CMD wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1

USER zserver
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/z-server"]
