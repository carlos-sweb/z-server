# Changelog

## v1.0.0 — 2026-11-15

### First Stable Release

- **Semantic Versioning (SemVer):** Declares API stability for the public exports of all 10 modules.
- **10 Modular Libraries:** `z_server` (HTTP core), `z_server_db` (SQLite connection pool), `z_server_cache` (in-process Pogocache L1), `z_server_tls` (hardened BearSSL TLS 1.2), `z_server_config` (JSON schema v2 configuration), `z_server_auth` (API Keys with HMAC-SHA256), `z_server_jwt` (HS256 JWT with `jti` denylist), `z_server_token` (OAuth 2.0 Client Credentials), `z_server_ratelimit` (Token bucket with IETF headers), and `z_server_metrics` (Prometheus text 0.0.4 exporter).
- **9 Consumer Examples:** Fully standalone examples covering every module individually (`hello-world`, `hello-db`, `hello-cache`, `hello-tls`, `hello-config`, `hello-auth`, `hello-jwt`, `hello-ratelimit`) and in unified combination (`hello-all`).
- **Production Hardening:** Exhaustive deployment checklist in `docs/production.md` covering secrets, Linux kernel tuning (`LimitNOFILE`, `somaxconn`), non-blocking SQLite hot backups, reverse proxies, and Prometheus alert rules.
- **Performance & Benchmarking:**
  - Diagnosed and fixed SQLite `synchronous=FULL` bottleneck in WAL mode, achieving a **690x reduction in p99 latency** (8831 ms → 12.83 ms), **733x reduction in p50** (132 ms → 0.18 ms), and 3.8x reduction in disk write volume under 2000 concurrent VUs. Full engineering breakdown published in `docs/blog-post-690x.md`.
  - Benchmark parity with Bun (1.1) in throughput while utilizing **3.0x less CPU** (11.8% vs 35.4%) and **8.3x less memory** (42.6 MB vs 353 MB) in a **107x smaller deployment image** (2.4 MB static binary vs 237 MB runtime).
- **Quality & Footprint:**
  - 127/127 tests passing across the entire test suite.
  - Fully static binary compiled for `x86_64-linux-musl` at ~2.4 MB with zero runtime shared-library dependencies.
- **Documentation:**
  - Comprehensive documentation covering every subsystem: `docs/auth.md`, `docs/jwt.md`, `docs/oauth.md`, `docs/ratelimit.md`, `docs/metrics.md`, `docs/tls.md`, `docs/config.md`, `docs/embedding.md`, `docs/production.md`, and `docs/blog-post-690x.md`.

## v0.9.0 — 2026-11-15

### Added

- `z_server_metrics` module providing Prometheus Text 0.0.4 exposition format.
- 11 core metrics covering HTTP (requests_total, duration_seconds histogram, in_flight), SQLite (busy_count, query_duration), cache (hits, misses), auth (failures by reason), JWT (validations by result), rate limiting (rejections by policy), and process (start_time, uptime).
- Per-handler `wrap()` with explicit route patterns to prevent cardinality explosion.
- Decoupled `Registry` collecting atomics from active modules (`z_server_db`, `z_server_cache`, `z_server_auth`, `z_server_jwt`, `z_server_ratelimit`).
- `config.json` schema v2 `metrics` section (`enabled`, `path`, `require_auth`, `allowed_cidrs`).
- Route protection with optional Bearer token auth (`metrics:read` scope) and IPv4 CIDR allowlist.
- Full module documentation in `docs/metrics.md`.

## v0.8.0 — 2026-11-15

### Added

- `z_server_ratelimit` module implementing production-grade HTTP rate limiting using the Token Bucket algorithm.
- Standard IETF RateLimit response headers (`RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`) and `Retry-After` on HTTP 429.
- Multiple rate-limiting dimensions: `.ip` (with `X-Forwarded-For` proxy extraction and port stripping), `.api_key` (`AuthContext`), `.jwt_sub` (`AuthContext`), `.header` (multi-tenant), `.global`, and `.custom` function extractors.
- Automatic pre-auth vs post-auth detection (`isPostAuth()`) with explicit boolean overrides.
- Dual-tier storage: Pogocache (`z_server_cache`) with automatic TTL, falling back to an in-memory thread-safe `AutoHashMap` with periodic background sweep when cache is omitted.
- Zero-overhead route wrapping middleware `wrap()` compatible with both freestanding `fn (req, res)` and context-based `fn (ctx, req, res)` handlers.
- Comprehensive test suite in `tests/ratelimit_test.zig` covering 15 test scenarios.
- Standalone consumer example `examples/hello-ratelimit/` demonstrating multi-tier rate limiting policies on HTTP routes.
- Full module documentation in `docs/ratelimit.md` and updated embedding guide.

## v0.7.0 — 2026-11-15

### Added

- `z_server_token` module implementing OAuth 2.0 Client Credentials Grant ([RFC 6749 §4.4](https://datatracker.ietf.org/doc/html/rfc6749#section-4.4)).
- `POST /auth/token` endpoint exchanging API keys for short-lived (default 900s) HS256 JWT access tokens.
- Scope downscoping support (RFC 6749 §4.4.2) allowing clients to request a subset of granted scopes.
- Dual-tier rate limiting for token endpoint: 30 req/min per IP and 60 req/min per API Key (fixed window, 60s TTL). Backed by Pogocache with in-memory `std.AutoHashMap` fallback and periodic cleanup.
- CLI subcommand `revoke-jwt <jti>` to immediately insert token IDs into the SQLite `revoked_jwt` denylist.
- Config schema v2 `token` section (`enabled`, `endpoint_path`, `rate_limit_ip_per_min`, `rate_limit_key_per_min`).
- Comprehensive documentation in `docs/oauth.md`.

## v0.6.0 — 2026-11-15

### Added

- `z_server_jwt` module providing HS256 JSON Web Token authentication with constant-time verification, strict claim validation (`iss`, `aud`, `exp`, `nbf`, `iat`, `jti`), and secondary secret support for zero-downtime key rotation.
- In-memory and SQLite-backed `jti` denylist for immediate token revocation, cached with Pogocache for sub-millisecond lookups.
- Opaque 7-day refresh tokens stored in SQLite with HMAC-SHA256 hashing.
- Integrated `z-args` CLI argument parsing with dedicated subcommands:
  - `issue-jwt`: Issue signed JWT tokens directly from CLI.
  - `create-key`: Generate API keys with custom scopes and user IDs.
  - `init-config`: Generate a starter `config.json` (schema v2) with `--force` support.
  - `--help` / `-h` support across root and all subcommands.
- Dual authentication on `z-server`: simultaneously accepts either API Keys or JWT tokens on protected `/items/*` routes based on header inspection, while keeping `/health` public.
- Config schema v2 `jwt` section (`enabled`, `ttl_seconds`, `require_https`, `denylist_cache_ttl_seconds`).
- Documentation in `docs/jwt.md` covering secret generation, claims, CLI, and security model.

## v0.5.0 — 2026-11-15

### Added

- `z_server_auth` module providing API key authentication with HMAC-SHA256, timing-safe verification, dummy hashing against enumeration, and structured key format (`zs_live_<random>_<crc32>`).
- CLI subcommand `create-key` on `z-server` (and example `hello-auth`) to generate API keys directly with custom scopes and user IDs.
- Config schema v2 with `auth` configuration block (`enabled`, `pepper`, `require_https`).
- Standalone consumer example `examples/hello-auth` demonstrating auth module usage.
- Backward compatibility: schema v1 configs continue to load seamlessly with authentication disabled and a warning to migrate.
- Authenticated endpoints: protected `/items/*` with API key header (`Authorization: Bearer <key>` or `X-API-Key: <key>`), while keeping `/health` public.

## v0.4.0 — 2026-11-15

### Added

- Modular architecture decomposing `z-server` into 5 standalone Zig modules (`z_server`, `z_server_db`, `z_server_cache`, `z_server_tls`, `z_server_config`).
- Standalone consumer examples for each module (`hello-db`, `hello-cache`, `hello-tls`, `hello-config`, `hello-all`).

## v0.3.0 — 2026-11-14 (Proposed)

### Added

- Native HTTPS via BearSSL statically compiled into single binary (zero external runtime TLS dependencies).
- TLS 1.2 support with ECDHE-RSA key exchange, AES-GCM, and ChaCha20-Poly1305.
- ALPN negotiation supporting `http/1.1`.
- PEM parser supporting X.509 certificate chains and RSA private keys in PKCS#1 and PKCS#8 formats.
- Configuration file system (`--config <path>` or `Z_SERVER_CONFIG`) with JSON schema v1, path resolution, and validation.
- Concurrency limiter for TLS connections (`tls.max_conns`, default 256).
- Test helpers: `loadtest/tls/gen-cert.sh` (self-signed cert generator) and `loadtest/tls/concurrency-test.sh` (50 parallel requests).
- Full test coverage: `tests/config_test.zig` (8 cases) and `tests/tls_test.zig` (9 cases).
- Documentation: `docs/config.md`, `docs/tls.md`, `docs/config.dev.json`, `docs/config.prod.example.json`.

### Security

- Prohibited `Z_SERVER_TLS_CERT_PATH` and `Z_SERVER_TLS_KEY_PATH` in environment variables to prevent credentials leaking via `/proc/$PID/environ`.
- World-readable private key detection and warnings.

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
