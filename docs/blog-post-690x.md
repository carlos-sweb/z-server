# How a 690x p99 Latency Drop Came from a Single SQLite PRAGMA, Not Zig

When developers decide to build a backend service in a systems programming language like Zig or Rust, the mental model is almost always the same: eliminating garbage collection pauses, reducing memory consumption, and maximizing CPU throughput will automatically yield microsecond-level tail latencies.

We recently built **z-server**, a production-grade, modular HTTP/HTTPS JSON API server in Zig 0.17.0. It statically bundles SQLite 3.51.2 for durable storage, an in-process C11 cache (Pogocache), native TLS 1.2 via BearSSL, API key and JWT authentication, token-bucket rate limiting, and Prometheus observability into a single 2.4 MB static Linux binary with zero dynamic library dependencies.

Yet during our first rigorous load test, the service collapsed at high concurrency. Tail latency (p99) skyrocketed to 8831 ms under a load of 2000 virtual users.

The gut reaction among systems programmers when seeing tail latency spikes is to suspect lock contention in the connection pool, thread pool starvation, memory allocators, or HTTP parser overhead. We almost spent an entire week architecting a complex reader/writer database split and rewriting query pathways.

We were completely wrong.

The entire bottleneck came down to a single configuration directive in SQLite. Changing one line of code reduced our p99 tail latency from 8831 ms to 12.83 ms—a **690x improvement**—while cutting disk I/O by nearly 4x.

This is the technical post-mortem of how we measured the failure, identified the actual root cause, and proved that systems-level instrumentation must always precede architectural rewrites.

---

## 1. The Setup: v0.1.1 Under Stress

The service architecture was designed to be lean and high-throughput:
- **Language:** Zig 0.17.0 compiled with `-Doptimize=ReleaseFast`.
- **HTTP Engine:** Non-blocking event-driven HTTP/1.1 server.
- **Storage:** SQLite 3.51.2 amalgamation compiled directly into the binary, operating in WAL (Write-Ahead Logging) mode with a multi-connection pool.
- **Caching:** In-process Pogocache L1 cache with cache-aside invalidation.
- **Workload:** Standard CRUD REST API (`GET /items`, `GET /items/:id`, `POST /items`, `PUT /items/:id`, `DELETE /items/:id`).

We deployed this build (`v0.1.1`) inside an isolated Linux test environment constrained to realistic cloud micro-instance resources:
- 1 vCPU
- 512 MB RAM
- Standard cloud SSD storage

We then subjected the server to a 300-second sustained load test using `k6`, scaling to 2000 concurrent virtual users (VUs) executing a mixed read/write profile.

### The Initial Results

The results were catastrophic:

```
Total requests:      158,295 in ~315 seconds
Throughput:          502.5 RPS
p50 Latency:         132 ms
p95 Latency:         3926 ms
p99 Latency:         8831 ms
CPU Usage:           ~12% of 1 core
Disk Write Volume:   6.481 GB (~41 KB per request)
Binary Format:       21.4 MB (dynamically linked against glibc)
```

Something was fundamentally broken. An HTTP server written in Zig consuming only 12% CPU while taking 8.8 seconds to complete a request at the 99th percentile represents a severe I/O stall. The CPU was almost entirely idle, waiting on synchronous block I/O.

At 502 RPS, writing 6.481 GB of data across 158,295 requests meant that each HTTP request was generating approximately 41 KB of disk writes, despite each JSON payload being smaller than 150 bytes. That represented a write amplification factor exceeding 270x.

---

## 2. The Diagnosis: Measuring Before Redesigning

When tail latencies balloon under concurrent load, engineering teams often propose speculative redesigns:
1. "SQLite cannot handle concurrent writes; we need PostgreSQL or a multi-process architecture."
2. "The connection pool is experiencing mutex lock contention; we need a segregated reader-pool and single-writer-queue."
3. "Transactions are conflicting; we need to introduce `BEGIN IMMEDIATE` across all transactions."

Before making architectural modifications, we added low-overhead instrumentation directly to the `/health` endpoint and internal counters:
- Linux `/proc/self/io` tracking (`write_bytes`, `syscw`).
- SQLite busy handler callbacks (`sqlite_busy_count`).
- Active file descriptor tracking.

### What the Data Showed

When we reproduced the load with instrumentation enabled, two critical facts emerged:

1. **`sqlite_busy_count` remained at 0.**
   There was zero lock contention. Connections were not waiting on other connections to release table or database locks. The pool was operating as intended.

2. **Every single commit was issuing a synchronous disk flush (`fdatasync`).**
   Under Linux, inspecting write operations via `strace -c` revealed thousands of blocking `fdatasync` system calls.

We examined how SQLite was initialized in `src/db/sqlite.zig`:

```zig
// Initial initialization in v0.1.1
_ = c.sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
_ = c.sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", null, null, null);
```

While `journal_mode = WAL` was enabled, the `synchronous` setting was left untouched.

By default, SQLite initializes all database connections with:

```sql
PRAGMA synchronous = FULL;
```

In `FULL` synchronous mode, the database engine pauses and forces the operating system to flush write buffers to physical media on every single transaction completion. When 2000 concurrent clients submit write transactions, the kernel serializes the physical flush requests to disk. The 12% CPU usage was not efficient execution; it was the entire process stalling on disk heads and storage controllers.

---

## 3. The Fix: One Line of Configuration

In SQLite's WAL mode, the write-ahead log operates fundamentally differently than traditional rollback journals. Transactions are appended sequentially to the `-wal` file rather than modifying the main database file in place.

SQLite's documentation explicitly addresses this design:

> "In WAL mode with synchronous=NORMAL, the write-ahead log is flushed to disk only during WAL checkpoints. Transactions commit without an immediate fsync."

We altered the connection initialization routine in `src/db/sqlite.zig` to explicitly configure `synchronous = NORMAL`:

```zig
_ = c.sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
_ = c.sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", null, null, null);
_ = c.sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", null, null, null);
```

### Is `synchronous = NORMAL` Safe for Production?

A common fear among engineers is whether `synchronous = NORMAL` compromises data durability or risks database corruption.

In WAL mode, `PRAGMA synchronous = NORMAL` provides the following guarantees:
- **Application Crashes:** Complete ACID safety. If the `z-server` process crashes or is terminated abruptly (`SIGKILL`), zero committed transactions are lost. SQLite recovers all committed WAL frames upon restart.
- **Operating System or Power Loss:** The database file cannot be corrupted. At worst, transactions committed in the few milliseconds immediately preceding a hard power outage might be rolled back if the disk cache had not yet flushed them to non-volatile flash memory. The integrity of the database itself remains completely intact.

For virtually all web APIs and microservices, this is the optimal operational trade-off.

---

## 4. The Impact: v0.1.1 vs v0.2.0

We recompiled `z-server` (released as `v0.2.0`) with static linking against `musl` (`x86_64-linux-musl`), producing a 2.2 MB standalone binary, and repeated the identical 2000 VU load test.

The performance delta was staggering:

| Metric | v0.1.1 (`synchronous=FULL`) | v0.2.0 (`synchronous=NORMAL`) | Absolute Improvement |
| :--- | :--- | :--- | :--- |
| **Throughput (RPS)** | 502.5 req/s (158,295 req / ~315s) | 670.6 req/s (211,246 req / 300s) | **+34% throughput** |
| **Median (p50) Latency** | 132 ms | 0.18 ms | **733x faster** |
| **p95 Latency** | 3926 ms | 1.24 ms | **3166x faster** |
| **p99 Latency** | 8831 ms | 12.83 ms | **690x faster** |
| **CPU Utilization** | ~12% (I/O wait saturation) | 11.8% (smooth processing) | Headroom preserved |
| **Disk Write Volume** | 6.481 GB (41 KB/req) | 1.084 GB (5.1 KB/req) | **3.8x less disk I/O** |
| **SQLite Busy Errors** | Uninstrumented | 0 | Zero contention |
| **Binary Footprint** | 21.4 MB (glibc dynamic) | 2.2 MB (musl static) | **9.7x smaller** |

### Analyzing the Shift

1. **p99 collapsed from 8831 ms to 12.83 ms:** That is a **690x reduction in tail latency**. Requests that previously stacked behind kernel fsync queues now returned in single-digit milliseconds.
2. **p50 dropped from 132 ms to 0.18 ms:** A **733x reduction** in median latency. For over half of all requests, responses were returned in less than two hundred microseconds.
3. **Total disk writes fell from 6.481 GB to 1.084 GB:** By avoiding an immediate fsync on every commit, the Linux page cache coalesced multiple sequential WAL appends into efficient bulk block writes.

Had we not measured write amplification and `sqlite_busy_count`, we would have spent days implementing a complex multi-process or segregated reader/writer queue architecture that would have left the 41 KB/request fsync bottleneck completely untouched.

---

## 5. Comparative Evaluation: z-server vs Bun

To put these results in industry perspective, we implemented the identical HTTP REST API with SQLite and in-process caching in Bun (v1.1), one of the fastest modern JavaScript/TypeScript runtimes.

We deployed both servers to the exact same 1 vCPU, 512 MB test container, using the same SQLite schema, WAL mode, cache-aside logic, and 2000 VU load test profile:

| Metric | z-server (Zig 0.17.0) | Bun (v1.1) | Difference |
| :--- | :--- | :--- | :--- |
| **Throughput (RPS)** | 670.6 req/s | 669.5 req/s | Tie (Δ 0.16%) |
| **p50 Latency** | 0.18 ms | 0.20 ms | Comparable |
| **p99 Latency** | 12.83 ms | 14.66 ms | z-server slightly lower |
| **Peak CPU Usage** | 11.8% of 1 core | 35.4% of 1 core | **z-server uses 3.0x less CPU** |
| **Peak RSS Memory** | 42.6 MB | 353.0 MB | **z-server uses 8.3x less RAM** |
| **HTTP Errors** | 0 | 0 | Both 0 errors |
| **Deployment Footprint** | 2.2 MB static binary | 237 MB runtime image | **z-server is 107x smaller** |

### A Note on the Throughput Ceiling

Notice that both z-server and Bun plateaued at approximately 670 RPS. Detailed inspection of client-side metrics revealed that the `k6` generator dropped 4,845 iterations in both runs due to local port and socket exhaustion on the client generator machine.

The throughput limit in this test was enforced by the test runner, not the servers. Measuring the absolute saturation throughput of z-server will require a distributed load test across multiple client machines (scheduled for our v1.1.0 release).

However, resource efficiency tells the real story:
- At equal throughput, Bun required **35.4% CPU** and **353 MB of RAM**.
- z-server achieved the same throughput using **11.8% CPU** and only **42.6 MB of RAM**.

Bun provides an outstanding developer experience. But for dense, resource-constrained deployments, edge appliances, or cost-sensitive infrastructure, Zig delivers 3x lower CPU consumption and 8.3x lower memory overhead in a binary that is 100 times smaller.

---

## 6. The Final Architecture: v1.0.0

Following this benchmark journey, we evolved `z-server` from a monolithic web server into an ecosystem of 10 modular, zero-allocation components:

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

The 10 modules can be used together or imported individually into any Zig project via `build.zig.zon`:
1. `z_server`: Core HTTP/1.1 engine and request dispatcher.
2. `z_server_db`: SQLite connection pool with automatic WAL configuration.
3. `z_server_cache`: In-process Pogocache L1 key-value cache.
4. `z_server_tls`: Embedded BearSSL TLS 1.2 engine.
5. `z_server_config`: JSON schema v2 configuration parser with environment overrides.
6. `z_server_auth`: API key validation with HMAC-SHA256 constant-time verification.
7. `z_server_jwt`: JWT HS256 validation with atomic in-memory `jti` denylist.
8. `z_server_token`: OAuth 2.0 Client Credentials token exchange (`POST /token`).
9. `z_server_ratelimit`: Token-bucket rate limiting with standard IETF headers.
10. `z_server_metrics`: Prometheus text format exporter with zero allocations in request hot paths.

The complete server compiles into a **2.4 MB static binary** (`x86_64-linux-musl`) with zero runtime dependencies.

---

## Conclusion

The biggest optimization in this project wasn't in the language or the architecture. It was in a SQLite PRAGMA that nobody had configured. If you're building an API with SQLite, check your synchronous setting before you rewrite anything.

Systems programming languages give you absolute control over execution, memory layouts, and thread lifecycles. But no amount of manual memory management or lock-free concurrency can compensate for an unconfigured database storage engine issuing blocking disk syncs on every commit.

Measure your system calls. Instrument your database busy handlers. Profile your disk write amplification. And make sure that before you refactor your architecture, you have verified your storage engine's primitives.

The source code, 10 modular packages, 9 consumer examples, and documentation are available on GitHub:
- Repository: [https://github.com/carlos-sweb/z-server](https://github.com/carlos-sweb/z-server)
- Stable Release Tag: [v1.0.0](https://github.com/carlos-sweb/z-server/releases/tag/v1.0.0)
