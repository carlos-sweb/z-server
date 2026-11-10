# z-server

HTTP/1.1 JSON API in **Zig 0.17.0**. SQLite3 is linked as a system `.so`. Pogocache 1.3.2 is compiled into the binary (C11, no runtime `.so`).

First release: **v0.1.0**. Bind: `127.0.0.1:8080`. No TLS, no auth.

## Requirements

- Zig 0.17.0
- libsqlite3 (headers + `.so`), e.g. Fedora: `sudo dnf install sqlite-devel`
- Linux x86_64

Optional: [oha](https://github.com/hatoo/oha) for load tests, valgrind for leak checks.

## Build and run

```bash
zig version          # 0.17.0
zig build
zig build test --summary all
zig build run
```

Bind defaults to `127.0.0.1:8080`. Override with `Z_SERVER_BIND` (`127.0.0.1:PORT` or `0.0.0.0:PORT`):

```bash
./zig-out/bin/z-server                         # host dev, loopback
Z_SERVER_BIND=0.0.0.0:8080 ./zig-out/bin/z-server  # Docker / all interfaces
```

The process prints:

```
z-server 0.1.1
sqlite3 3.x.x
listening on 127.0.0.1:8080
```

SIGINT / SIGTERM: `server.stop()`, then SQLite pool `deinit`, then Pogocache `free`. Exit 0.

If the port is taken:

```
error: address 127.0.0.1:8080 already in use
```

Exit code **2**.

Database file: `data/app.db` (created on first start, WAL).

## HTTP API

| Method | Path | Notes |
|---|---|---|
| GET | `/` | `{"ok":true}` |
| GET | `/health` | `ok`, `version`, `db`, `cache` |
| GET | `/items` | last 100 rows, **no cache** |
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

- No TLS, no auth, no HTTP/2, no metrics
- Stale-HIT window: a GET that misses, SELECTs, then `cache.set` can race a concurrent PUT (mitigate later with `updated_at` or a shorter TTL)
- POST at c=50 is WAL-bound (p99 seconds, not milliseconds); retries keep error count at 0
- `MAX_VALUE_BYTES` 32 KiB vs `max_body_size` 64 KiB on purpose
- Address-in-use log can interleave with the first process’s “listening on …” line on a shared tty
- Linux x86_64 only

## License

MIT. See `LICENSE`. Pogocache remains MIT (Polypoint Labs, LLC). SQLite is public domain. Zig and http.zig are MIT.

## Phase notes

Development write-ups: `README.fase00.md` … `README.fase05.md`.
