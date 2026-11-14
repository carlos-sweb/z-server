# bun-baseline

Native HTTP/1.1 JSON API in **Bun 1.3.14** (`docker.io/oven/bun:latest`) without frameworks (no Hono, no Express, no Fastify). SQLite via `bun:sqlite` with WAL mode and `synchronous = NORMAL`.

This baseline replicates the endpoints, request/response formats, constraints, and sizing of `z-server v0.2.0` for a head-to-head benchmark under identical cgroup conditions (1 vCPU, 512 MB memory, no swap).

## Concurrency Model

**Option C: 1 main process + 16 Worker Threads (`reusePort: true`)**

- **Worker count:** 16 Worker Threads spawned by the main process (`node:worker_threads`).
- **SQLite connections:** 16 independent `bun:sqlite` Database instances (one per worker thread).
- **HTTP binding:** Each worker runs `Bun.serve({ reusePort: true, ... })` listening on the same host and port (`0.0.0.0:8080`), with incoming connections distributed by Linux `SO_REUSEPORT`.
- **Atomic telemetry:** `sqlite_busy_count` is tracked globally across all 16 workers using a shared `SharedArrayBuffer` with atomic additions (`Atomics.add`).
- **Cache replication:** Cache entries (`set` and `invalidate`) are broadcast across workers via parent `postMessage` channels so all workers share cache state.

This architecture is the closest equivalent to z-server's 16 handler threads (`http.zig` worker pool) and 16 SQLite pool connections in a single operating system entity.

## HTTP Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/` | `{"ok":true}` |
| GET | `/health` | $O(1)$ metrics snapshot: `ok`, `version`, `db`, `cache`, `sqlite_busy_count`, `io_read_bytes`, `io_write_bytes`, `fd_count` |
| GET | `/items` | last 100 rows, uncached |
| GET | `/items/:id` | cache-aside, `X-Cache: HIT\|MISS` (TTL 60s) |
| POST | `/items` | body `{ "name", "payload" }`, 201 `{ "id" }` |
| PUT | `/items/:id` | update + invalidate cache, returns updated item JSON |
| DELETE | `/items/:id` | 204, invalidate cache |

Payload limit: 64 KiB. Cached item value limit: 32 KiB.

## Known Limitations and Notes

### Stale Reads Under Concurrency
Cache invalidation across workers uses `postMessage`, which is asynchronous. A GET on worker B immediately after a PUT on worker A may serve stale data until the message is delivered (typically <1ms, but non-zero). z-server uses shared shards with no such window. The benchmark measures throughput, not cache coherence under concurrent writes.
*Empirical measurement:* In an immediate-GET-after-PUT test under 16 workers, `0 / 100` stale reads were observed.

### File Descriptor Count (fd_count)
`fd_count` in the benchmark is 88 (86 base + 2 ephemeral sockets), measured with 16 Worker Threads in a fresh container. The 147 reported in an earlier ad-hoc test came from a long-running container (47h) that had accumulated fds from an unrelated smoke run. Compare medians, not absolute values, against z-server's 46.

### I/O Accounting (io_write_bytes)
`io_read_bytes` and `io_write_bytes` are read from `/proc/self/io`. In Linux, the block I/O layer only tracks `write_bytes` when writing to physical block devices (ext4/xfs). If data were placed on a `tmpfs` (RAM filesystem), `write_bytes` would remain 0. The benchmark runner binds `/app/data` to host disk storage to ensure accurate block I/O accounting.
