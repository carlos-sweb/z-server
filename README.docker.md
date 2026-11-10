# z-server Docker

Alpine 3.24 image of z-server 0.1.1. The host does **not** need Zig or SQLite.

## Prerequisites

- Docker 24+ (or Podman 4+ with `docker` compatibility)
- Linux x86_64 (the image is pinned to the amd64 Alpine digest)

## Build

```bash
docker build -t z-server:0.1.1 .
```

The builder downloads [Zig 0.17.0](https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz) and checks:

```
SHA256 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
```

Alpine apk has no Zig 0.17.0 (3.24 community is 0.16.0-r1). The official linux tarball is statically linked and runs on musl.

## Run

```bash
docker run --rm -p 8080:8080 z-server:0.1.1
```

With a persistent SQLite file on the host:

```bash
mkdir -p data
docker run --rm -p 8080:8080 \
  -v "$(pwd)/data:/app/data" \
  z-server:0.1.1
```

## Docker Compose

```bash
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down
```

Compose publishes `8080:8080`, mounts `./data:/app/data:Z`, sets `Z_SERVER_BIND=0.0.0.0:8080`, and uses `userns_mode: keep-id` for rootless Podman. The healthcheck is inherited from the Dockerfile.

## Hello world

```bash
curl -s http://localhost:8080/health
# {"ok":true,"version":"0.1.1","db":"ok","cache":"ok"}

curl -s http://localhost:8080/
# {"ok":true}
```

`docker stop` sends SIGTERM. The process handles it, prints the websocket-scoped shutdown line (filtered to err in production logs), deinit SQLite and Pogocache, and exits **0** (not 143).

## Image size

```bash
docker images z-server:0.1.1
```

Expected: **20–40 MB** (measured **16.2 MB** for this build). Acceptable range: 15–80 MB.

The runtime image is Alpine 3.24 + `sqlite-libs` + `ca-certificates` + a ~5 MB ReleaseSafe binary. `libsqlite3.so.0` is the only extra shared library (`ldd` on musl: `libsqlite3.so.0`, `libc.musl-x86_64.so.1`).

## Volume `./data`

SQLite creates `data/app.db` (WAL) under `/app/data`. The container user is `zserver` (UID/GID **1000**). If the host bind-mount is not writable:

```bash
sudo chown -R 1000:1000 data
```

## Bind address

The image sets `ENV Z_SERVER_BIND=0.0.0.0:8080` so Docker DNAT to the container's `eth0` reaches the listener.

Without Docker, the binary still defaults to `127.0.0.1:8080`. Override only when you need all interfaces:

```bash
Z_SERVER_BIND=0.0.0.0:8080 ./zig-out/bin/z-server
```

## Troubleshooting

### Zig tarball SHA256 mismatch

The builder runs `sha256sum -c` on the official tarball. A mismatch means a corrupt or unexpected download. Rebuild without cache:

```bash
docker build --no-cache -t z-server:0.1.1 .
```

If ziglang.org is unreachable, the `curl` step fails before the checksum.

### Volume permissions

`Permission denied` opening `data/app.db` usually means the host directory is not owned by UID 1000. See `chown` above. Do not run the container as root.

### Host firewall on 8080

`curl http://localhost:8080/health` from the host needs the published port. Check `docker ps` shows `0.0.0.0:8080->8080/tcp` (or `[::]:8080`). A host firewall rejecting 8080 will fail even if the container is healthy (`docker inspect --format '{{.State.Health.Status}}'`).

If `curl http://localhost:8080/health` resets the connection but `curl http://127.0.0.1:8080/health` works, the client used IPv6 (`::1`) and the publisher did not forward it. z-server listens on IPv4 `0.0.0.0:8080` only. Use `127.0.0.1` or disable IPv6 for that curl.

### `sqlite-libs` missing `libsqlite3.so.0`

The binary `NEEDED` entries are `libsqlite3.so.0` and `libc.musl-x86_64.so.1`. Alpine `sqlite-libs` provides `so:libsqlite3.so.0`. If the process dies with `Error loading shared library libsqlite3.so.0`, the runtime stage dropped `sqlite-libs`.

### HEALTHCHECK uses BusyBox wget

The runtime image does not install GNU wget. Alpine BusyBox includes `wget`. The probe hits `http://127.0.0.1:8080/health` inside the container (loopback always works once the process is listening).

## Notes

- **Alpine 3.24, not 3.20.** 3.20 EOL: 2026-04-01. Image digest is the amd64 manifest `sha256:0f49f331d9212aff11b932863be4eb01cdf962969aa86dab7d1ee21ac6f5f52b` (Alpine 3.24.4).
- **Builder installs `git`.** `build.zig.zon` dependencies are `git+https://…`. `.dockerignore` excludes `zig-pkg/`, so the builder clones http.zig and translate-c. This is a build-time package only; git is not in the runtime image.
- **Path A (native musl).** Both stages are Alpine. Zig compiles for the native musl target and links Alpine's `libsqlite3.so.0`. No glibc-to-musl cross sysroot.
- **`vendor/pogocache/` is not dockerignored.** Pogocache 1.3.2 is compiled into the binary (C11, `-D_GNU_SOURCE`).
- **UID 1000.** Alpine 3.24 minirootfs does not ship a uid 1000 user. `adduser -u 1000` succeeded on 3.24.4. If it ever conflicts, switch to 1001 and update this file.
- **Rootless Podman + `./data`.** `userns_mode: keep-id` maps the host UID into the container so `./data` stays owned by the host user (no subuid 525287). Docker Compose ignores `userns_mode` (unknown field, no error). Verified with Podman 5.8.9 + podman-compose 1.6.0 (`userns_mode` → `podman run --userns keep-id`).
- **SELinux (Fedora):** `:Z` on the volume is required; it is a no-op elsewhere.
- If `userns_mode: keep-id` is not supported by your podman-compose, fallback: `podman unshare chown 1000:1000 ./data` once before `up`.
- **Podman HEALTHCHECK.** Podman’s default OCI image format drops `HEALTHCHECK`. `docker build` keeps it. With Podman: `podman build --format docker -t z-server:0.1.1 .`
- Tag **v0.1.1** in git is the source this image is meant to build. The Docker tag `z-server:0.1.1` is independent of the git tag.
