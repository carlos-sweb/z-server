# hello-ratelimit

Standalone consumer example demonstrating general-purpose HTTP rate limiting using the `z_server_ratelimit` module with Token Bucket algorithms, standard IETF RateLimit headers (`RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `Retry-After`), and route-level middleware wrapping.

## Features

- **Token Bucket Algorithm**: Smooth traffic shaping and burst handling.
- **IETF Standard Headers**:
  - `RateLimit-Limit`: Maximum burst capacity in current window.
  - `RateLimit-Remaining`: Remaining request tokens in current window.
  - `RateLimit-Reset`: Seconds until token bucket is completely full.
  - `Retry-After`: Seconds to wait before retrying (on HTTP 429).
- **Multiple Dimensions**: IP-based (`.ip`), header-based (`.header`), global (`.global`), and custom extractors (`.custom`).
- **In-Memory Fallback**: Zero external dependencies required; falls back to an in-memory thread-safe `AutoHashMap` when no cache is configured.

## Endpoints & Policies

| Endpoint | Policy | Method | Limit | Window |
|---|---|---|---|---|
| `/health` | Unprotected | GET | Unlimited | - |
| `/public` | Permissive | GET | 100 req | 60s (IP) |
| `/api` | Standard | GET | 10 req | 60s (IP) |
| `/strict` | Strict Burst | GET | 2 req | 60s (IP) |
| `/tenant` | Multi-Tenant | GET | 5 req | 60s (`X-Tenant-ID`) |

## Quick Start

### 1. Build and Run

```bash
cd examples/hello-ratelimit
zig build run
```

The server binds to `http://127.0.0.1:9000`.

### 2. Verify Headers & Permissive Endpoint

```bash
curl -i http://127.0.0.1:9000/public
```

Example response headers:
```http
HTTP/1.1 200 OK
RateLimit-Limit: 100
RateLimit-Remaining: 99
RateLimit-Reset: 1
Content-Type: application/json
```

### 3. Test Rate Limiting on `/api` (10 req / 60s)

Send 11 rapid requests:
```bash
for i in $(seq 1 11); do
  echo -n "Request $i: "
  curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/api
done
```

Output:
```text
Request 1: 200
Request 2: 200
...
Request 10: 200
Request 11: 429
```

Inspect the 429 response:
```bash
curl -i http://127.0.0.1:9000/api
```

```http
HTTP/1.1 429 Too Many Requests
RateLimit-Limit: 10
RateLimit-Remaining: 0
RateLimit-Reset: 60
Retry-After: 6
Content-Type: application/json

{"error":"rate_limited","message":"Too many requests. Retry in 6 seconds.","retry_after":6}
```

### 4. Test Multi-Tenant Limiting (`/tenant`)

```bash
# Tenant A
curl -i -H "X-Tenant-ID: tenant-a" http://127.0.0.1:9000/tenant

# Tenant B (independent bucket)
curl -i -H "X-Tenant-ID: tenant-b" http://127.0.0.1:9000/tenant
```
