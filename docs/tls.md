# Native TLS Architecture with BearSSL

`z-server` provides native HTTPS termination via [BearSSL](https://www.bearssl.org/), statically compiled and linked directly into the single binary without external runtime dependencies (no OpenSSL, LibreSSL, or mbedTLS dynamic libraries required).

## Architecture: Transparent TLS Bridge (Option D)

`http.zig` operates as a high-performance HTTP engine bound to loopback/plaintext interfaces. To preserve full compatibility with existing handlers, SQLite pools, and caching, the TLS subsystem runs an integrated, high-concurrency TLS frontend listener.

```
       HTTPS Client (TLS 1.2)
                │
                ▼ :8443
   ┌─────────────────────────────┐
   │    z-server TLS Listener    │
   │  (BearSSL Engine & SSLIO)   │
   │   - Decrypts client request │
   │   - Enforces max_conns=256  │
   │   - ALPN "http/1.1"         │
   └──────────────┬──────────────┘
                  │ Plaintext HTTP/1.1 loopback
                  ▼ :8080
   ┌─────────────────────────────┐
   │      httpz HTTP Server      │
   │   - Router & Handler Pool   │
   │   - SQLite Pool (WAL)       │
   │   - Pogocache (512 shards)  │
   └──────────────┬──────────────┘
                  │ Plaintext response
                  ▼
   ┌─────────────────────────────┐
   │    z-server TLS Listener    │
   │   - Encrypts via BearSSL    │
   │   - Flushes TLS records     │
   └──────────────┬──────────────┘
                │
                ▼
       HTTPS Client Response
```

### Key Technical Characteristics

1. **Protocol & Version:** TLS 1.2 (BearSSL implements TLS 1.0 to 1.2; modern clients negotiate TLS 1.2).
2. **Key Exchange & Ciphers:**
   - Key Exchange: ECDHE-RSA (Forward Secrecy enabled with Curve25519, NIST P-256).
   - Encryption: ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM, AES-CBC.
   - Hashing & PRF: SHA-256, SHA-384.
3. **Application-Layer Protocol Negotiation (ALPN):** Configured to offer and accept `"http/1.1"`.
4. **Certificate & Key Formats:**
   - Certificates: Standard X.509 PEM format (`-----BEGIN CERTIFICATE-----`). Supports single certificates and full certificate chains.
   - Private Keys: RSA 2048/4096-bit keys in PKCS#1 (`-----BEGIN RSA PRIVATE KEY-----`) and PKCS#8 (`-----BEGIN PRIVATE KEY-----`).
   - Unencrypted keys required (PEM passphrases are not supported natively by BearSSL without external crypto).
5. **Memory Management & Buffering:**
   - BearSSL utilizes a bidirectional buffer of `BR_SSL_BUFSIZE_BIDI` (~33 KB) per active connection.
   - Buffers and connection contexts are cleanly allocated and freed per connection with zero global leaks.
6. **Concurrency & Thread Safety:**
   - Active connections are capped by `tls.max_conns` (default 256) tracked via atomic counter. Excess connections are rejected gracefully.
   - Graceful shutdown handles SIGINT and SIGTERM: the listening socket is closed immediately and in-flight TLS connections drain before process exit.

## Certificate Generation

A helper script is provided at `loadtest/tls/gen-cert.sh` to generate self-signed RSA certificates for local development and testing:

```bash
./loadtest/tls/gen-cert.sh
# Generates server.crt and server.key in loadtest/tls/
```

To configure TLS in `config.json`:

```json
{
  "server": {
    "bind": "127.0.0.1:8080"
  },
  "tls": {
    "enabled": true,
    "bind": "0.0.0.0:8443",
    "cert_path": "server.crt",
    "key_path": "server.key",
    "max_conns": 256
  }
}
```

## Static musl Build & Zero Runtime Dependencies

`z-server` compiles as a 100% static binary targeting `x86_64-linux-musl`:
- **SQLite 3.51.2 Amalgamation:** Compiled directly into the binary from `vendor/sqlite/sqlite3.c` with flags `-DSQLITE_THREADSAFE=1 -DSQLITE_OPEN_URI=1 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_DQS=0`.
- **BearSSL:** Compiled directly into the binary with ECDHE-RSA and x25519 support.
- **musl libc:** Statically linked.
- **Verification:**
  - `file zig-out/bin/z-server`: `ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked`
  - `ldd zig-out/bin/z-server`: `not a dynamic executable`
  - `readelf -d zig-out/bin/z-server`: `There is no dynamic section in this file.`
  - Portability: The binary can be copied via `scp` to any Linux x86_64 system (Alpine, Debian, Ubuntu, RHEL, Arch) and run immediately without preinstalling SQLite, libc, or OpenSSL.

## Performance & TLS Load Benchmark (200 VUs)

Load test executed with k6 using realistic concurrency matching server capacity (`MAX_VUS=200`, `USERS=1000`, `DURATION=120s`, `ulimit -n 65536`) with `sqlite_synchronous=NORMAL`:

- **Total Requests:** 9,442 HTTPS requests
- **Request Success Rate:** 100.00% (0 errors out of 9,442 requests, `http_req_failed = 0.00%`)
- **Checks Passed:** 100.00% (11,403 / 11,403 checks passed)
- **RPS:** 69.92 req/s (arrival-rate scenario with realistic user think-times)
- **Latency Distribution (`http_req_duration`):**
  - p50: 0.31 ms (305 µs)
  - p90: 0.99 ms (996 µs)
  - p95: 1.10 ms
  - p99: 1.59 ms
  - max: 51.11 ms
- **TLS Handshaking (`http_req_tls_handshaking`):**
  - Average: 2.21 ms
  - p90 / p95: 0 ms (TLS session reuse across keep-alive connections)
  - p99: 46.78 ms
  - Max: 54.74 ms
- **Health Endpoint (`dur_health`):**
  - Median: 0.47 ms
  - p99: 1.66 ms
- **Database & Concurrency Integrity:**
  - `sqlite_synchronous`: 1 (NORMAL), `sqlite_synchronous_all_normal`: true
  - `sqlite_busy_count`: 0 (zero busy locks)
  - `fd_count`: 49 stable descriptors (zero descriptor or memory leaks)
