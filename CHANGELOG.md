# Changelog

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
