# z-server Step-by-Step Tutorial & Practical Usage Guide

This guide walks you through building, configuring, running, and interacting with `z-server`—a high-performance, 100% statically linked HTTP/HTTPS JSON REST API engine written in **Zig 0.17.0**.

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Building the Static Binary](#2-building-the-static-binary)
3. [Configuration Options](#3-configuration-options)
   - [Default Out-of-the-Box](#default-out-of-the-box)
   - [Environment Variable Overrides](#environment-variable-overrides)
   - [File-Based JSON Configuration](#file-based-json-configuration)
4. [Setting Up Native TLS (HTTPS)](#4-setting-up-native-tls-https)
5. [Complete REST API Walkthrough with Real Examples](#5-complete-rest-api-walkthrough-with-real-examples)
   - [Service Health Check (`GET /health`)](#service-health-check-get-health)
   - [Root Ping (`GET /`)](#root-ping-get-)
   - [Creating Records (`POST /items`)](#creating-records-post-items)
   - [Listing Records (`GET /items`)](#listing-records-get-items)
   - [Cache-Aside Lookup & Header Inspection (`GET /items/:id`)](#cache-aside-lookup--header-inspection-get-itemsid)
   - [Updating Records & Cache Invalidation (`PUT /items/:id`)](#updating-records--cache-invalidation-put-itemsid)
   - [Deleting Records (`DELETE /items/:id`)](#deleting-records-delete-itemsid)
   - [Database Sync Diagnostics (`GET /sync-check`)](#database-sync-diagnostics-get-sync-check)
6. [Hardened TLS Verification](#6-hardened-tls-verification)
7. [Deployment & Production Run](#7-deployment--production-run)
8. [Troubleshooting & Common Codes](#8-troubleshooting--common-codes)

---

## 1. Overview & Architecture

`z-server` combines three high-performance components inside a single static Linux binary (`x86_64-linux-musl`):

- **HTTP Engine (`http.zig`):** Multi-threaded epoll server utilizing non-blocking network I/O and an internal worker thread pool.
- **Database Engine (Bundled SQLite 3.51.2):** Official SQLite amalgamation compiled directly into the binary with WAL (`Write-Ahead Logging`) mode, high-concurrency connection pooling, and `synchronous=NORMAL` for sub-millisecond commits.
- **In-Memory Cache (Embedded Pogocache):** Sharded thread-safe LRU cache providing microsecond response times for hot keys with automatic TTL expiration.
- **Native TLS Bridge (Bundled BearSSL):** Embedded cryptographic engine delivering TLS 1.2 termination with zero external library dependencies (no OpenSSL or dynamic `.so` required).

```
   HTTPS Client (TLS 1.2)                  HTTP Client (Plaintext)
            │                                       │
            ▼ :8443                                 ▼ :8080
┌───────────────────────┐               ┌───────────────────────┐
│ BearSSL TLS Listener  │               │   httpz HTTP Server   │
│ - ECDHE-RSA / x25519  │──Loopback────▶│ - Request Routing     │
│ - AEAD (AES-GCM/Poly) │               │ - 16 Connection Pool  │
└───────────────────────┘               │ - 512 Cache Shards    │
                                        └───────────┬───────────┘
                                                    │
                                                    ▼
                                           ┌─────────────────┐
                                           │ SQLite 3.51 WAL │
                                           │  data/app.db    │
                                           └─────────────────┘
```

---

## 2. Building the Static Binary

### Prerequisites

- **Zig 0.17.0** installed via `mise`, `asdf`, or downloaded from `ziglang.org`.
- **Linux x86_64** (native or container).

### Compiling

To build the optimized static binary:

```bash
# Clone the repository
git clone https://github.com/carlos-sweb/z-server.git
cd z-server

# Verify compiler version
zig version
# 0.17.0

# Run all unit and integration tests
zig build test --summary all

# Build optimized static release
zig build -Doptimize=ReleaseFast
```

The resulting binary is located at `zig-out/bin/z-server`. Verify that it is 100% statically linked:

```bash
file zig-out/bin/z-server
# ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked

ldd zig-out/bin/z-server
# not a dynamic executable
```

---

## 3. Configuration Options

### Default Out-of-the-Box

Running without arguments starts the HTTP engine on `127.0.0.1:8080`:

```bash
./zig-out/bin/z-server
```

Console output:
```text
z-server 0.3.0
sqlite3 3.51.2
handler_threads 16
sqlite_pool 16
listening on 127.0.0.1:8080
```

### Environment Variable Overrides

For containerized environments (Docker, Podman, Kubernetes), you can configure runtime parameters via environment variables:

```bash
# Listen on all interfaces on port 8080 with 4 workers and 4 db connections
Z_SERVER_BIND="0.0.0.0:8080" \
Z_SERVER_HANDLER_THREADS=4 \
Z_SERVER_SQLITE_POOL=4 \
Z_SERVER_SQLITE_SYNCHRONOUS="NORMAL" \
./zig-out/bin/z-server
```

Supported environment variables:
- `Z_SERVER_BIND`: Network interface and port (`127.0.0.1:PORT` or `0.0.0.0:PORT`).
- `Z_SERVER_HANDLER_THREADS`: Number of HTTP handler worker threads (1–128).
- `Z_SERVER_SQLITE_POOL`: Number of shared SQLite read/write handles (1–128).
- `Z_SERVER_SQLITE_SYNCHRONOUS`: SQLite persistence durability (`NORMAL`, `FULL`, `OFF`, `EXTRA`).
- `Z_SERVER_CONFIG`: Path to a JSON configuration file.

### File-Based JSON Configuration

For production deployments, manage all settings—including TLS certificates—in a single version-controlled configuration file:

Create `config.json`:
```json
{
  "$schema_version": 1,
  "server": {
    "bind": "0.0.0.0:8080",
    "handler_threads": 16,
    "max_body_size": 65536
  },
  "sqlite": {
    "path": "data/app.db",
    "pool_size": 16,
    "synchronous": "NORMAL"
  },
  "cache": {
    "nshards": 512,
    "default_ttl_s": 60,
    "max_value_bytes": 32768
  },
  "tls": {
    "enabled": true,
    "bind": "0.0.0.0:8443",
    "cert_path": "loadtest/tls/server.crt",
    "key_path": "loadtest/tls/server.key",
    "max_conns": 256
  }
}
```

Run with `--config`:
```bash
./zig-out/bin/z-server --config config.json
```

---

## 4. Setting Up Native TLS (HTTPS)

`z-server` includes an automated certificate generator script for local development and staging:

```bash
# Generate self-signed RSA 2048-bit certificate and unencrypted private key
./loadtest/tls/gen-cert.sh
```

This generates:
- `loadtest/tls/server.crt`: X.509 Certificate (PEM format).
- `loadtest/tls/server.key`: RSA Private Key (0600 permissions).

Start `z-server` with TLS enabled:
```bash
./zig-out/bin/z-server --config docs/config.dev.json
```

Startup banner:
```text
z-server 0.3.0
sqlite3 3.51.2
handler_threads 16
sqlite_pool 16
listening on 127.0.0.1:8080
tls listening on 127.0.0.1:8443
```

Both plaintext HTTP (`:8080`) and secure HTTPS (`:8443`) are actively serviced in parallel!

---

## 5. Complete REST API Walkthrough with Real Examples

Let's test every endpoint using `curl` against a live instance.

### Service Health Check (`GET /health`)

The `/health` endpoint is an O(1) non-blocking diagnostic query that returns comprehensive system, database, cache, I/O, and TLS telemetry.

```bash
curl -sk https://127.0.0.1:8443/health | jq .
```

Example Response:
```json
{
  "ok": true,
  "version": "0.3.0",
  "db": "ok",
  "cache": "ok",
  "sqlite_busy_count": 0,
  "io_read_bytes": 2396160,
  "io_write_bytes": 49152,
  "fd_count": 49,
  "handler_threads": 16,
  "sqlite_pool": 16,
  "sqlite_synchronous": 1,
  "sqlite_synchronous_all_normal": true,
  "sqlite_synchronous_last_check_unix": 1794670488,
  "tls_version": "TLSv1.2",
  "tls_cipher_suites": [
    "ECDHE-RSA-AES128-GCM-SHA256",
    "ECDHE-RSA-AES256-GCM-SHA384",
    "ECDHE-RSA-CHACHA20-POLY1305-SHA256"
  ],
  "tls_curves": [
    "x25519",
    "secp256r1"
  ],
  "tls_renegotiation": "disabled",
  "tls_rsa_keyx": "disabled"
}
```

Key Metrics to Note:
- `sqlite_synchronous: 1`: Confirms `PRAGMA synchronous=NORMAL` is active for fast disk writes.
- `sqlite_synchronous_all_normal: true`: Confirms every connection in the pool has the optimal setting.
- `sqlite_busy_count: 0`: Zero database lock contentions.
- `tls_rsa_keyx: "disabled"`: Confirms ROBOT mitigation is actively enforced.

---

### Root Ping (`GET /`)

```bash
curl -sk https://127.0.0.1:8443/
```

Response:
```json
{"ok":true}
```

---

### Creating Records (`POST /items`)

Insert a new item. The body must be valid JSON containing `name` (string) and `payload` (JSON object).

```bash
curl -sk -X POST https://127.0.0.1:8443/items \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sensor_alpha",
    "payload": {
      "temperature": 23.4,
      "humidity": 45,
      "status": "active"
    }
  }'
```

Response (`HTTP 201 Created`):
```json
{
  "id": 1
}
```

Create a second item:
```bash
curl -sk -X POST https://127.0.0.1:8443/items \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sensor_beta",
    "payload": {
      "temperature": 19.8,
      "battery": 98
    }
  }'
```

Response:
```json
{
  "id": 2
}
```

---

### Listing Records (`GET /items`)

Retrieve up to the 100 most recent records ordered by ID descending:

```bash
curl -sk https://127.0.0.1:8443/items | jq .
```

Response:
```json
[
  {
    "id": 2,
    "name": "sensor_beta",
    "payload": {
      "temperature": 19.8,
      "battery": 98
    }
  },
  {
    "id": 1,
    "name": "sensor_alpha",
    "payload": {
      "temperature": 23.4,
      "humidity": 45,
      "status": "active"
    }
  }
]
```

---

### Cache-Aside Lookup & Header Inspection (`GET /items/:id`)

When querying a single item by ID, `z-server` checks the in-memory cache first:
- If cached: Returns directly from RAM with header `X-Cache: HIT`.
- If not cached: Queries SQLite, populates the cache, and returns with header `X-Cache: MISS`.

#### First Call (Cache Miss):
```bash
curl -skI https://127.0.0.1:8443/items/1
```

Headers:
```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 95
X-Cache: MISS
```

#### Second Call (Cache Hit):
```bash
curl -skI https://127.0.0.1:8443/items/1
```

Headers:
```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 95
X-Cache: HIT
```

Retrieve data payload:
```bash
curl -sk https://127.0.0.1:8443/items/1 | jq .
```

Response:
```json
{
  "id": 1,
  "name": "sensor_alpha",
  "payload": {
    "temperature": 23.4,
    "humidity": 45,
    "status": "active"
  }
}
```

---

### Updating Records & Cache Invalidation (`PUT /items/:id`)

Update the data of an existing item. This immediately writes through to SQLite and invalidates the cached key so that stale reads are impossible.

```bash
curl -sk -X PUT https://127.0.0.1:8443/items/1 \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sensor_alpha_v2",
    "payload": {
      "temperature": 25.1,
      "humidity": 48,
      "status": "calibrated"
    }
  }'
```

Response (`HTTP 200 OK`):
```json
{
  "id": 1,
  "name": "sensor_alpha_v2",
  "payload": {
    "temperature": 25.1,
    "humidity": 48,
    "status": "calibrated"
  }
}
```

Verify that the next GET request is an `X-Cache: MISS` reflecting the new value:
```bash
curl -skI https://127.0.0.1:8443/items/1 | grep "X-Cache"
# X-Cache: MISS

curl -skI https://127.0.0.1:8443/items/1 | grep "X-Cache"
# X-Cache: HIT
```

---

### Deleting Records (`DELETE /items/:id`)

Delete an item. Deletes the database record and purges it from the cache.

```bash
curl -sk -i -X DELETE https://127.0.0.1:8443/items/2
```

Response (`HTTP 204 No Content`):
```http
HTTP/1.1 204 No Content
```

Querying the deleted record returns 404:
```bash
curl -sk -i https://127.0.0.1:8443/items/2
```

Response:
```http
HTTP/1.1 404 Not Found
```

---

### Database Sync Diagnostics (`GET /sync-check`)

Force an atomic check across all pooled SQLite connections to verify durability settings:

```bash
curl -sk https://127.0.0.1:8443/sync-check | jq .
```

Response:
```json
{
  "sqlite_synchronous": 1,
  "sqlite_synchronous_all_normal": true,
  "sqlite_synchronous_last_check_unix": 1794672217
}
```

---

## 6. Hardened TLS Verification

`z-server` incorporates cryptographic hardening to neutralize BEAST, POODLE, ROBOT, and DROWN attacks. You can verify this strict security posture directly with command-line tools.

### 1. Verification of TLS 1.2 AEAD Negotiation
```bash
curl -skv --tls-max 1.2 https://127.0.0.1:8443/health 2>&1 | grep "SSL connection"
```
Output:
```text
* SSL connection using TLSv1.2 / ECDHE-RSA-AES128-GCM-SHA256 / x25519 / rsaEncryption
```

### 2. Deprecated Protocols Rejection (BEAST & POODLE Mitigation)
```bash
# TLS 1.0 is rejected
curl -skv --tlsv1.0 --tls-max 1.0 https://127.0.0.1:8443/health 2>&1 | grep "protocol version"
# TLS alert, protocol version (582)

# TLS 1.1 is rejected
curl -skv --tlsv1.1 --tls-max 1.1 https://127.0.0.1:8443/health 2>&1 | grep "protocol version"
# TLS alert, protocol version (582)
```

### 3. Legacy CBC Ciphers Rejection (BEAST Mitigation)
```bash
curl -skv --ciphers 'AES128-SHA' https://127.0.0.1:8443/health 2>&1 | grep -E "alert|error"
# TLS alert, handshake failure (552)
```

### 4. Static RSA Key Exchange Rejection (ROBOT Mitigation)
```bash
curl -skv --ciphers 'AES128-GCM-SHA256' https://127.0.0.1:8443/health 2>&1 | grep -E "alert|error"
# TLS alert, handshake failure (552)
```

Only Forward-Secret ECDHE cipher suites with AEAD encryption (`AES-GCM` and `ChaCha20-Poly1305`) over `X25519` and `P-256` curves are accepted.

---

## 7. Deployment & Production Run

### Binary Stripping for Minimal Footprint

Compile and strip the binary to produce a tiny ~2.2 MB distribution:

```bash
zig build -Doptimize=ReleaseFast
strip -s -o z-server-stripped zig-out/bin/z-server

ls -lh z-server-stripped
# -rwxr-xr-x 1 user user 2.2M z-server-stripped
```

### Portability (`scp`)

Because the binary is 100% statically linked against musl libc, you can copy it to **any** Linux x86_64 server (Ubuntu, Debian, Alpine, Rocky, Arch, Amazon Linux):

```bash
scp z-server-stripped deploy@your-server:/opt/z-server/z-server
```

No package installations (`apt-get install libsqlite3-dev` or `openssl`) are needed on the target host!

### Example Systemd Service Unit

Create `/etc/systemd/system/z-server.service`:

```ini
[Unit]
Description=z-server Static HTTP/HTTPS Engine
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/z-server
ExecStart=/opt/z-server/z-server --config /var/www/z-server/config.json
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Reload and enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now z-server
```

---

## 8. Troubleshooting & Common Codes

| HTTP Status | Cause | Resolution |
|---|---|---|
| `400 Bad Request` | Malformed JSON in request body or payload is not a JSON object | Verify `Content-Type: application/json` and valid JSON formatting. |
| `404 Not Found` | The requested item ID does not exist | Check record IDs using `GET /items`. |
| `413 Payload Too Large` | Request body exceeds 64 KiB (`max_body_size`) | Reduce payload size or adjust `server.max_body_size` in `config.json`. |
| `503 Service Unavailable` | Database pool exhausted under extreme load | Increase `sqlite.pool_size` and raise system descriptor limits (`ulimit -n 65536`). |
| `TLS Handshake Failure` | Client attempted TLS 1.0/1.1, CBC cipher, or static RSA | Update client to support TLS 1.2 with ECDHE and AES-GCM or ChaCha20-Poly1305. |
