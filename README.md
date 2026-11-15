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
# Run with config file (enabling native HTTPS)
./zig-out/bin/z-server --config docs/config.dev.json

# Run via environment variable
Z_SERVER_CONFIG=docs/config.dev.json ./zig-out/bin/z-server

# Standard plaintext run (100% backward-compatible with v0.2.0)
./zig-out/bin/z-server
```

See [docs/config.md](file:///home/sweb/z-server/docs/config.md) for full configuration reference and schema documentation.
See [docs/tls.md](file:///home/sweb/z-server/docs/tls.md) for details on the native BearSSL TLS 1.2 implementation.

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

See [examples/hello-world/](file:///home/sweb/z-server/examples/hello-world/) (HTTP core only), [examples/hello-db/](file:///home/sweb/z-server/examples/hello-db/) (HTTP + SQLite), and [examples/hello-cache/](file:///home/sweb/z-server/examples/hello-cache/) (HTTP + in-memory cache) for complete standalone example projects.

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
