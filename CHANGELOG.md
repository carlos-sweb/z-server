# Changelog

## v0.2.0 — 2026-11-10

### Added

- `Z_SERVER_HANDLER_THREADS` and `Z_SERVER_SQLITE_POOL` (fallback remains clamp(2*nproc,4,16); nproc in rootless cgroups does not match `cpu.max`)
- `Z_SERVER_SQLITE_SYNCHRONOUS` (OFF|NORMAL|FULL|EXTRA; default unset → SQLite FULL)
- `/health` metrics: `sqlite_busy_count`, `io_read_bytes`, `io_write_bytes`, `fd_count`
- `/health` O(1): cached sync snapshot at startup (`sqlite_synchronous`, `sqlite_synchronous_all_normal`, `sqlite_synchronous_last_check_unix`); `/internal/sync-check` re-reads the pool
- Container/compose defaults: 4 handler threads, 4 SQLite pool connections
- Disk hygiene: `run.sh` guard (5 GB min), `build-image.sh` prune
- Docs: smoke `--tmpfs` requires `mode=1777`

### Changed

- `synchronous=NORMAL` fix: 690× p99 improvement (8831 ms → 12.8 ms) on the 16/16 cheap-VPS load
- `analyze.sh`: latency units consistent in ms across the per-minute table
- Sampler reads busy/io/fd from `/health` instead of silent zeros

## v0.1.1 — 2026-11-10

### Added

- `Z_SERVER_BIND` env var to override bind address (default unchanged)

## v0.1.0 — 2026-11-09

First tagged release. Zig 0.17.0, HTTP/1.1 on `127.0.0.1:8080`.

### Added

- http.zig server, SIGINT/SIGTERM shutdown, `AddressInUse` → exit 2
- SQLite3 system `.so`, connection pool (`ConnLease`, 5 s `waitTimeout`, `PoolClosed`)
- Schema `items` with `PRAGMA user_version = 1`, WAL, `busy_timeout=5000`
- CRUD `/items` plus cache-aside on `GET /items/:id` (`X-Cache`)
- Embedded Pogocache 1.3.2 (512 shards, TTL 60 s, skip values &gt; 32 KiB)
- `/health` with `db` and `cache` probes
- Tests: smoke, http, db pool, cache, items HTTP (14 cases including 30/40 KiB and concurrent PUT)
- `bench/run.sh` (oha) and `bench/valgrind.sh`

### Known limitations

Documented in README: stale-HIT race, WAL contention on POST c=50, no TLS/auth/HTTP/2.
