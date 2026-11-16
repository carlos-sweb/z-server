# z-server

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-orange)
![Tests 127/127](https://img.shields.io/badge/tests-127%2F127-green)
![Binary 2.4 MB](https://img.shields.io/badge/binary-2.4MB%20static-blue)
![License MIT](https://img.shields.io/badge/license-MIT-green)

z-server is a production-grade HTTP/HTTPS server for Linux, compiled as a single 100% static binary. It integrates SQLite 3.51.2 (WAL + pooling), Pogocache (in-process C11 cache), BearSSL TLS 1.2 (hardened), dual auth (API Key + JWT), OAuth 2.0 Client Credentials, token-bucket rate limiting, and Prometheus metrics — with zero runtime dependencies and no dynamic allocations in the request hot path.

## Requirements

- Zig 0.17.0
- Linux x86_64 (`x86_64-linux-musl` target supported for fully static binaries)

Optional tools:
- `k6` or `oha` for load testing
- `valgrind` for memory leak checks

## Quick Start

Build the ReleaseFast optimized static binary and run the server with a starter configuration:

```bash
# 1. Compile ReleaseFast binary
zig build -Doptimize=ReleaseFast

# 2. Generate initial JSON configuration
./zig-out/bin/z-server init-config --output config.json

# 3. Export authentication secrets (64-char hex strings)
export Z_SERVER_AUTH_PEPPER="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
export Z_SERVER_JWT_SECRET="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

# 4. Start the server
./zig-out/bin/z-server --config config.json

# 5. Verify health endpoint
curl http://127.0.0.1:8080/health
# → {"ok":true,"version":"1.0.0","uptime_s":1,"db_ok":true,"cache_ok":true}
```

Run test suite:

```bash
zig build test --summary all
```

## Configuration

z-server uses a versioned JSON configuration schema (`$schema_version: 2`) with environment variable overrides:

```json
{
  "$schema_version": 2,
  "server": {
    "bind": "127.0.0.1:8080"
  },
  "db": {
    "path": "data/app.db",
    "pool_size": 16,
    "busy_timeout_ms": 5000
  },
  "cache": {
    "capacity": 10000,
    "ttl_seconds": 300
  },
  "tls": {
    "enabled": false,
    "bind": "127.0.0.1:8443",
    "cert_file": "certs/server.crt",
    "key_file": "certs/server.key"
  },
  "auth": {
    "enabled": true,
    "header": "authorization",
    "allow_x_api_key": true
  },
  "jwt": {
    "enabled": true,
    "clock_skew_seconds": 60
  },
  "metrics": {
    "enabled": true,
    "path": "/metrics",
    "require_auth": false,
    "allowed_cidrs": ["127.0.0.1/32"]
  }
}
```

Environment variables always override configuration file fields:
- `Z_SERVER_CONFIG`: Path to JSON configuration file.
- `Z_SERVER_BIND`: Server bind address (`ip:port`).
- `Z_SERVER_AUTH_PEPPER`: Secret pepper for HMAC-SHA256 API Key verification (64 hex or 44 base64 chars).
- `Z_SERVER_JWT_SECRET`: Secret key for HS256 JWT signatures.

## HTTP API Endpoints

| Method | Path | Auth Required | Description |
| --- | --- | --- | --- |
| `GET` | `/health` | No | Operational status, version, uptime, and component health |
| `POST` | `/token` | API Key | OAuth 2.0 Client Credentials token exchange (returns JWT) |
| `GET` | `/items` | Dual (API Key or JWT) | List items (cache-aside with Pogocache + SQLite) |
| `GET` | `/items/:id` | Dual (API Key or JWT) | Fetch item by ID |
| `POST` | `/items` | Dual (API Key or JWT) | Create new item |
| `PUT` | `/items/:id` | Dual (API Key or JWT) | Update item |
| `DELETE` | `/items/:id` | Dual (API Key or JWT) | Delete item and evict from cache |
| `GET` | `/metrics` | Configurable | Prometheus text format v0.0.4 metrics |

## Benchmarks (The 690x Story)

During load testing with 2000 virtual users (VUs) over 300 seconds on a 1 vCPU, 512 MB test container, we diagnosed and resolved a severe tail-latency bottleneck.

| Metric | v0.1.1 (`synchronous=FULL`) | v0.2.0 (`synchronous=NORMAL`) | Improvement |
| --- | --- | --- | --- |
| **Throughput (RPS)** | 502.5 req/s (158,295 req / ~315s) | 670.6 req/s (211,246 req / 300s) | **+34%** |
| **p50 Latency** | 132 ms | 0.18 ms | **733x faster** |
| **p95 Latency** | 3926 ms | 1.24 ms | **3166x faster** |
| **p99 Latency** | 8831 ms | 12.83 ms | **690x faster** |
| **CPU Usage** | ~12% 1 core (saturated by fsync waits) | 11.8% 1 core (idle headroom) | Stable |
| **Disk Write Volume** | 6.481 GB (41 KB/req) | 1.084 GB (5.1 KB/req) | **3.8x less I/O** |
| **SQLite Busy Errors** | n/d (uninstrumented) | 0 | Zero lock contention |
| **Binary Footprint** | 21.4 MB (dynamic glibc) | 2.2 MB (static musl) | **9.7x smaller** |

The 690x p99 improvement (8831 ms → 12.83 ms) came from a single SQLite PRAGMA: synchronous=FULL → NORMAL in WAL mode. Not from Zig, not from the HTTP layer. This is the lesson: measure before redesigning.

Read the complete engineering deep dive in [docs/blog-post-690x.md](docs/blog-post-690x.md).

## Benchmarks vs Bun

Running the exact same CRUD workload with cache-aside against Bun on identical container hardware (2000 VUs, 300 seconds, 1 vCPU, 512 MB RAM):

| Metric | z-server (v0.2.0) | Bun (1.1) | Advantage |
| --- | --- | --- | --- |
| **Throughput (RPS)** | 670.6 req/s | 669.5 req/s | Tie (Δ 0.16%) |
| **p50 Latency** | 0.18 ms | 0.20 ms | Comparable |
| **p99 Latency** | 12.83 ms | 14.66 ms | z-server slightly lower |
| **Peak CPU** | 11.8% | 35.4% | **z-server 3.0x lower CPU** |
| **Peak RSS Memory** | 42.6 MB | 353.0 MB | **z-server 8.3x less RAM** |
| **HTTP Errors** | 0 | 0 | Both 0 errors |
| **Deployment Size** | 2.2 MB static binary | 237 MB container image + runtime | **107x smaller** |

*Note on throughput ceiling:* In both benchmark runs, the `k6` client instance dropped 4,845 iterations due to local generator socket exhaustion. The throughput limit was bounded by the test harness machine rather than the server instances. Multi-machine load generation is planned for v1.1.0 benchmarks.

## Module Ecosystem

`z-server` is structured as a collection of 10 standalone, independently reusable Zig package manager modules:

| Module | Size | C deps | Purpose |
| --- | --- | --- | --- |
| `z_server` | ~332 KB | none | HTTP core |
| `z_server_db` | +1.2 MB | sqlite3.c | SQLite pool |
| `z_server_cache` | +30 KB | pogocache.c | In-process cache |
| `z_server_tls` | +130 KB | bearssl/*.c | TLS 1.2 hardened |
| `z_server_config` | +85 KB | none | JSON config + env overrides |
| `z_server_auth` | +30 KB | none | API Keys (HMAC-SHA256) |
| `z_server_jwt` | +15 KB | none | JWT HS256 + jti denylist |
| `z_server_token` | +5 KB | none | OAuth 2.0 Client Credentials |
| `z_server_ratelimit` | +20 KB | none | Token bucket rate limiter |
| `z_server_metrics` | +135 KB | none | Prometheus metrics |

To consume individual modules in your own Zig projects, see [docs/embedding.md](docs/embedding.md).

## Consumer Examples

The `examples/` directory contains 9 standalone executable consumer applications demonstrating modular composition:

| Example | Size | Demonstrates |
| --- | --- | --- |
| `hello-world` | 332 KB | HTTP core only |
| `hello-db` | 1.5 MB | HTTP + SQLite |
| `hello-cache` | 360 KB | HTTP + Pogocache |
| `hello-tls` | 463 KB | HTTP + BearSSL TLS 1.2 |
| `hello-config` | 417 KB | HTTP + JSON config |
| `hello-auth` | 1.6 MB | HTTP + API Key auth |
| `hello-jwt` | 1.9 MB | HTTP + JWT + OAuth Client Credentials |
| `hello-ratelimit` | ~500 KB | HTTP + token bucket rate limiter |
| `hello-all` | 2.2 MB | Full stack (all 10 modules) |

Each example can be built independently from its directory:

```bash
cd examples/hello-jwt
zig build run
```

## Architecture

```
TCP Socket
    │
    ▼
┌───────────────────────────────────────┐
│ z_server_tls (BearSSL TLS 1.2)        │
│ ECDHE + AEAD + X25519 + P-256         │
│ TLS 1.2 only, no CBC, no RSA keyx     │
└───────────────┬───────────────────────┘
                │ HTTP/1.1 plain
                ▼
┌───────────────────────────────────────┐
│ z_server (HTTP core, httpz)           │
│ ┌─────────────────────────────────┐   │
│ │ z_server_ratelimit (token bucket)│  │
│ │ 30/min IP · 60/min API Key      │   │
│ └───────────────┬─────────────────┘   │
│                 ▼                     │
│ ┌─────────────────────────────────┐   │
│ │ z_server_auth (API Key)          │  │
│ │ z_server_jwt (JWT HS256)         │  │
│ │ z_server_token (OAuth Client Cred)│ │
│ └───────────────┬─────────────────┘   │
│                 ▼                     │
│ ┌─────────────────────────────────┐   │
│ │ Route handler                    │  │
│ │ + z_server_metrics (Prometheus)  │  │
│ └───────────────┬─────────────────┘   │
│                 ▼                     │
│ ┌─────────────────┐ ┌───────────────┐ │
│ │ z_server_cache  │ │ z_server_db   │ │
│ │ (Pogocache L1)  │ │ (SQLite WAL)  │ │
│ └─────────────────┘ └───────────────┘ │
└───────────────────────────────────────┘
```

## Documentation Index

- [docs/embedding.md](docs/embedding.md) — Using z_server modules as libraries
- [docs/auth.md](docs/auth.md) — API Key authentication and management
- [docs/jwt.md](docs/jwt.md) — JWT authentication and token verification
- [docs/oauth.md](docs/oauth.md) — OAuth 2.0 Client Credentials flow
- [docs/ratelimit.md](docs/ratelimit.md) — Token bucket rate limiting
- [docs/metrics.md](docs/metrics.md) — Prometheus metrics specification
- [docs/tls.md](docs/tls.md) — BearSSL TLS 1.2 hardening guide
- [docs/config.md](docs/config.md) — Configuration schema and environment variables
- [docs/production.md](docs/production.md) — Production deployment checklist
- [docs/blog-post-690x.md](docs/blog-post-690x.md) — The 690x tail latency story

## Production Checklist

Before running `z-server` in internet-facing environments:
- Generate 64-character hex secrets for `Z_SERVER_AUTH_PEPPER` and `Z_SERVER_JWT_SECRET`.
- Set Linux file descriptor limits (`LimitNOFILE=65535`).
- Ensure `/dev/shm` is mounted for SQLite WAL shared-memory index files.
- Protect `/metrics` using `allowed_cidrs` or `require_auth: true`.
- Schedule automated daily online backups with `sqlite3 app.db ".backup /backups/app.db"`.
- Set `logging.level = "info"` and never enable debug logging in production.

See the complete guide in [docs/production.md](docs/production.md).

## License

MIT License. Copyright (c) 2026 Carlos & z-server contributors. See LICENSE for details.
