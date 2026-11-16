# z-server

High-performance HTTP/1.1 and hardened HTTPS JSON API in **Zig 0.17.0**. Built as a 100% static binary (`x86_64-linux-musl`) with zero runtime shared-library dependencies. SQLite 3.51.2 amalgamation is compiled directly into the binary with WAL pooling. Pogocache 1.3.2 is embedded in-process (C11, no runtime `.so`). Native HTTPS is powered by an embedded, hardened BearSSL engine (statically linked C99, zero runtime OpenSSL/libssl dependencies).

📖 **New to z-server? Check out the comprehensive [TUTORIAL.md](file:///home/sweb/z-server/TUTORIAL.md) for step-by-step setup, TLS certificate generation, and complete REST API curl examples.**

Bind: `127.0.0.1:8080` (override `Z_SERVER_BIND`). Native TLS on `:8443` via config file.

## Requirements

- Zig 0.17.0
- Linux x86_64

Optional: [oha](https://github.com/hatoo/oha) or [k6](https://k6.io) for load tests, valgrind for leak checks.

## Build and run

```bash
zig version          # 0.17.0
zig build
zig build test --summary all
zig build run
```

### Configuration and TLS

`z-server` can be configured via a JSON configuration file, environment variables, or default fallbacks:

```bash
# Run with config file (enabling native HTTPS and Auth)
./zig-out/bin/z-server --config docs/config.dev.json

# Run via environment variable
Z_SERVER_CONFIG=docs/config.dev.json ./zig-out/bin/z-server

# Standard plaintext run (100% backward-compatible with v0.2.0)
./zig-out/bin/z-server

# Generate an API key via CLI
export Z_SERVER_AUTH_PEPPER="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
./zig-out/bin/z-server create-key --name admin --scopes "*"
```

See `z-server --help` for all available CLI options.
See [docs/config.md](file:///home/sweb/z-server/docs/config.md) for full configuration reference and schema documentation.
See [docs/tls.md](file:///home/sweb/z-server/docs/tls.md) for details on the native BearSSL TLS 1.2 implementation.
See [docs/auth.md](file:///home/sweb/z-server/docs/auth.md) for API key authentication and management.

Bind defaults to `127.0.0.1:8080`. Override with `Z_SERVER_BIND` (`127.0.0.1:PORT` or `0.0.0.0:PORT`):

```bash
./zig-out/bin/z-server                         # host dev, loopback
Z_SERVER_BIND=0.0.0.0:8080 ./zig-out/bin/z-server  # Docker / all interfaces
Z_SERVER_HANDLER_THREADS=4 Z_SERVER_SQLITE_POOL=4 ./zig-out/bin/z-server
```

`Z_SERVER_HANDLER_THREADS` / `Z_SERVER_SQLITE_POOL` default to `clamp(2*nproc, 4, 16)`. nproc inside a rootless cgroup does **not** equal `cpu.max` (you can see 8 CPUs with a 1-CPU quota). Set both to 4 on a 1-vCPU box.

The process prints:

```
z-server 0.2.0
sqlite3 3.x.x
handler_threads 4
sqlite_pool 4
listening on 127.0.0.1:8080
```

SIGINT / SIGTERM: `server.stop()`, then SQLite pool `deinit`, then Pogocache `free`. Exit 0.

If the port is taken:

```
error: address 127.0.0.1:8080 already in use
```

Exit code **2**.

Database file: `data/app.db` (created on first start, WAL).

## Authentication

`z-server` supports both API Keys (`z_server_auth`) and JSON Web Tokens (`z_server_jwt`). Both mechanisms can operate simultaneously or independently.

### API Keys (`z_server_auth`)

1. Set secret pepper:
```bash
export Z_SERVER_AUTH_PEPPER=$(openssl rand -hex 32)
```

2. Generate an API key via CLI:
```bash
KEY=$(./zig-out/bin/z-server create-key --name "ci-deploy" \
  --scopes "items:read items:write")
echo "Generated key: $KEY"
# -> zs_live_Zp7rtZCAXUNnNLMr_2s_HSW6qsxsQmCjpPFgNH8F2_o_0vuI2E
```

### JSON Web Tokens (`z_server_jwt`)

1. Set JWT secret (minimum 256 bits / 32 bytes):
```bash
export Z_SERVER_JWT_SECRET=$(openssl rand -hex 32)
```

2. Issue a signed HS256 JWT via CLI:
```bash
JWT=$(./zig-out/bin/z-server issue-jwt --sub "alice" \
  --scopes "items:read items:write" --ttl 900)
echo "Generated token: $JWT"
```

### OAuth 2.0 Client Credentials Grant (`z_server_token`)

Exchange an API key for a short-lived HS256 JWT via RFC 6749 §4.4:

```bash
# Obtain JWT using API Key
curl -s -X POST http://127.0.0.1:8080/auth/token \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials"}' | jq .
# -> { "access_token": "...", "token_type": "Bearer", "expires_in": 900, "scope": "items:read items:write" }

# Revoke a token immediately by its jti
./zig-out/bin/z-server revoke-jwt "<jti-uuid>"
```

See [docs/oauth.md](file:///home/sweb/z-server/docs/oauth.md) for endpoint details and rate limiting.

### Rate Limiting (`z_server_ratelimit`)

Token Bucket rate limiting with standard IETF headers (`RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `Retry-After`):

```zig
const z_ratelimit = @import("z_server_ratelimit");

// Wrap route handlers with custom policies
.{
    .method = .GET,
    .path = "/api",
    .handler = z_ratelimit.wrap(.{
        .capacity = 100,
        .window_seconds = 60,
        .by = .ip,
    }, handleApi),
}
```

See [docs/ratelimit.md](file:///home/sweb/z-server/docs/ratelimit.md) for full policy configurations and multi-tenant dimensions.

### Prometheus Metrics (`z_server_metrics`)

Expose OpenMetrics / Prometheus 0.0.4 metrics via `GET /metrics`:

```zig
const z_metrics = @import("z_server_metrics");

// Wrap route handlers with explicit pattern labels
.{
    .method = .GET,
    .path = "/api/data",
    .handler = z_metrics.wrap("/api/data", handleData),
}
```

See [docs/metrics.md](file:///home/sweb/z-server/docs/metrics.md) for the 11 core metrics, CIDR allowlist, and Prometheus scrape config.

### Run server & test endpoints

```bash
./zig-out/bin/z-server &

# Public endpoint (/health is unauthenticated)
curl -s http://127.0.0.1:8080/health | jq .version
# -> "0.9.0"

# Protected endpoint without token fails with 401
curl -si http://127.0.0.1:8080/items | head -5
# -> HTTP/1.1 401 Unauthorized
# -> WWW-Authenticate: Bearer realm="z-server"

# Protected endpoint with API Key succeeds with 200
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/items | jq .
# -> []

# Protected endpoint with JWT succeeds with 200
curl -s -H "Authorization: Bearer $JWT" http://127.0.0.1:8080/items | jq .
# -> []
```

## Module ecosystem

`z-server` provides a modular architecture where each feature is an independent Zig module. Consumers import only what they need:

| Module            | Size   | Depends on C | Purpose           |
|-------------------|--------|--------------|-------------------|
| z_server          | 332 KB | no           | HTTP core         |
| z_server_db       | +1.2MB | sqlite3.c    | SQLite            |
| z_server_cache    | +30KB  | pogocache.c  | Cache             |
| z_server_tls      | +130KB | bearssl/*.c  | TLS 1.2           |
| z_server_config   | +85KB  | no           | JSON config       |
| z_server_auth     | +30KB  | no           | API Key Auth      |
| z_server_jwt      | +27KB  | no           | JWT & Refresh     |
| z_server_token    | +10KB  | no           | OAuth 2.0 Token   |
| z_server_ratelimit| +15KB  | no           | Rate Limiting     |
| z_server_metrics  | +18KB  | no           | Prometheus metrics|
| hello-all (full)  | 2.23 MB| all          | Complete stack    |

See the standalone examples:
- [examples/hello-world/](file:///home/sweb/z-server/examples/hello-world/) (HTTP core only, ~332 KB)
- [examples/hello-db/](file:///home/sweb/z-server/examples/hello-db/) (HTTP + SQLite connection pool, ~1.5 MB)
- [examples/hello-cache/](file:///home/sweb/z-server/examples/hello-cache/) (HTTP + Pogocache, ~360 KB)
- [examples/hello-tls/](file:///home/sweb/z-server/examples/hello-tls/) (HTTP + BearSSL TLS 1.2, ~463 KB)
- [examples/hello-config/](file:///home/sweb/z-server/examples/hello-config/) (HTTP + JSON config & env overrides, ~417 KB)
- [examples/hello-auth/](file:///home/sweb/z-server/examples/hello-auth/) (HTTP + Auth + SQLite + Pogocache, ~1.6 MB)
- [examples/hello-jwt/](file:///home/sweb/z-server/examples/hello-jwt/) (HTTP + JWT + Auth + SQLite + Pogocache, ~1.6 MB)
- [examples/hello-ratelimit/](file:///home/sweb/z-server/examples/hello-ratelimit/) (HTTP + Rate limiting, ~696 KB)
- [examples/hello-all/](file:///home/sweb/z-server/examples/hello-all/) (Complete stack with all 8 modules, ~2.2 MB)

For an in-depth integration guide, see [docs/embedding.md](file:///home/sweb/z-server/docs/embedding.md).

## Use as a library

`z-server` can be embedded directly as a lightweight HTTP core library in downstream Zig projects without pulling in SQLite, Pogocache, or BearSSL dependencies:

```zig
const std = @import("std");
const z_server = @import("z_server");

pub fn main(init: std.process.Init) !void {
    var server = try z_server.Server.init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
        },
    });
    defer server.deinit();
    try server.serve();
}

fn handleRoot(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .message = "hello world" }, .{});
}
```

## HTTP API

| Method | Path | Notes |
|---|---|---|
| GET | `/` | `{"ok":true}` |
| GET | `/health` | `ok`, `version`, `db`, `cache`, `sqlite_busy_count`, `io_*_bytes`, `fd_count`, `handler_threads`, `sqlite_pool` |
| GET | `/items` | last 100 rows, **no cache** (no `X-Cache`) |
| GET | `/items/:id` | cache-aside, `X-Cache: HIT\|MISS` |
| POST | `/items` | body `{ "name", "payload" }`, 201 `{ "id" }` |
| PUT | `/items/:id` | update + invalidate cache |
| DELETE | `/items/:id` | 204, invalidate cache |

`payload` must be a JSON object. Request body limit: **64 KiB** (413 if larger). Cached GET JSON limit: **32 KiB**; larger items stay in SQLite and always MISS.

```bash
curl -s http://127.0.0.1:8080/health
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"name":"foo","payload":{"k":1}}' \
  http://127.0.0.1:8080/items
curl -sI http://127.0.0.1:8080/items/1   # X-Cache: MISS then HIT
```

## Architecture

```
http.zig workers (epoll) → thread pool (clamp(2*nproc, 4, 16))
    → handlers
        → ConnLease over SQLite pool (FULLMUTEX, WAL, busy_timeout=5000)
        → Pogocache in-process (512 shards, usethreadbatch off)
```

GET `/items/:id` serializes JSON **once** into `res.arena` and uses those bytes for both the response body and `cache.set` (`item:{id}`, TTL 60 s). PUT/DELETE call `cache.delete` after a successful write.

C headers are translated with the official `translate-c` 2.0.2 package (`src/c/bindings.h`). There is no `@cImport`.

Pinned deps (see `build.zig.zon`):

- http.zig `1bb71ff128a044b1645df91046473c38abbf965c`
- translate-c `2.0.2`

Vendored: Pogocache **1.3.2** (`9ca1b8d`), MIT, `vendor/pogocache/`.

## Load tests

```bash
# Fedora
sudo dnf install oha
# or
curl -fsSL -o bench/oha https://github.com/hatoo/oha/releases/download/v1.16.0/oha-linux-amd64
chmod +x bench/oha

./bench/run.sh
./bench/valgrind.sh
```

Numbers from the v0.1.0 run (oha 1.16.0, 2026-11-09) are in `bench/results.md`:

| scenario | n | c | RPS | p99 ms | errors |
|---|---:|---:|---:|---:|---:|
| GET HIT | 1000 | 50 | 132330 | 0.876 | 0 |
| GET MISS (40 KiB) | 1000 | 50 | 4574 | 43.190 | 0 |
| POST | 500 | 50 | 214 | 1333 | 0 |
| GET list | 1000 | 50 | 20478 | 7.071 | 0 |

## Known limitations

- No HTTP/2, no built-in auth, no OpenTelemetry / Prometheus metrics (health endpoint exports key runtime stats)
- Stale-HIT window: a GET that misses, SELECTs, then `cache.set` can race a concurrent PUT (mitigate later with `updated_at` or a shorter TTL)
- POST at high concurrency is WAL-bound; busy_timeout and retries keep error count at 0
- `MAX_VALUE_BYTES` 32 KiB vs `max_body_size` 64 KiB on purpose
- Address-in-use log can interleave with the first process’s “listening on …” line on a shared tty
- Linux x86_64 only

## License

MIT. See `LICENSE`. Pogocache remains MIT (Polypoint Labs, LLC). SQLite is public domain. Zig and http.zig are MIT.

## Phase notes

Development write-ups: `README.fase00.md` … `README.fase05.md`.
