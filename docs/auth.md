# z_server_auth — API Key Authentication Module

The `z_server_auth` module provides robust, high-performance API Key authentication for the `z-server` ecosystem.

## Key Features

- **Storage Security**: HMAC-SHA256 with pepper (`Z_SERVER_AUTH_PEPPER`). Only 64-character hex hashes are stored in SQLite; plaintext keys are never stored.
- **Timing Attack Mitigation**: All hash comparisons use constant-time operations (`std.crypto.timing_safe.eql`). On lookup failures, dummy hashing is computed to eliminate timing side channels (mitigating CVE-2026-23996).
- **Structured Key Format**: `zs_<env>_<random_43_chars>_<crc32_6chars>` (~58 chars total). Enables fast client-side/edge checksum verification and secret scanner detection (e.g., GitHub Secret Scanning).
- **Hybrid Validation**: SQLite persistence with optional Pogocache in-memory cache (5–10s TTL) for high throughput.
- **Rotation with Grace Period**: `rotate(key_id)` provisions a new key without revoking the previous one, allowing seamless zero-downtime client migrations.
- **Throttled Usage Tracking**: In-memory throttling writes `last_used_at` to SQLite at most once every 60 seconds per key.
- **Granular Scopes**: Flexible space- or comma-separated permissions per key with wildcard (`*`) support.
- **Header Flexibility**: Standard `Authorization: Bearer <key>` with configurable `X-API-Key` fallback.

---

## Pepper Generation & Configuration

`z_server_auth` enforces a fail-fast policy: a 32-byte pepper must be provided via the environment or options.

### 1. Generate Pepper

Generate a 32-byte cryptographically secure random pepper:

```bash
# Base64 (44 characters)
openssl rand -base64 32

# Or Hex (64 characters)
openssl rand -hex 32
```

### 2. Configure Environment

Export `Z_SERVER_AUTH_PEPPER` before starting the application:

```bash
export Z_SERVER_AUTH_PEPPER="dGhpcy1pcy1hbi1leGFtcGxlLXBlcHBlci0zMmJ5dGVzCg=="
```

---

## Consumer Usage Example

```zig
const std = @import("std");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_auth = @import("z_server_auth");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 1. Initialize SQLite Pool
    var pool = try z_server_db.Pool.init(allocator, io, .{
        .path = "data/app.db",
        .pool_size = 4,
    });
    defer pool.deinit();

    // 2. Optional: Initialize Pogocache
    var cache = try z_server_cache.Cache.init(allocator, 512);
    defer cache.deinit();

    // 3. Initialize Authenticator
    var auth = try z_server_auth.Authenticator.init(allocator, io, &pool, .{
        .cache = &cache,
        .cache_ttl_seconds = 10,
        .throttle_seconds = 60,
    });
    defer auth.deinit();

    // 4. Create an API Key
    const new_key = try auth.createKey(.{
        .user_id = "tenant_42",
        .scopes = "items:read items:write",
        .env = .live,
    });
    std.log.info("API Key created: {s}", .{new_key.plaintext()});
    // Remember to zero out or discard the plaintext after displaying to the user!
}
```

---

## Protecting Endpoints with Middleware

Use `z_server_auth.wrap` to wrap route handlers declaratively in `z_server.ServerT`:

```zig
var server = try z_server.ServerT(*App).initWithContext(gpa, io, .{
    .bind = "127.0.0.1:9000",
    .routes = &.{
        // Public endpoint
        .{ .method = .GET, .path = "/health", .handler = health },
        // Protected endpoint requiring specific scope
        .{ .method = .GET, .path = "/items", .handler = z_server_auth.wrap("items:read", items.list) },
        .{ .method = .POST, .path = "/items", .handler = z_server_auth.wrap("items:write", items.create) },
    },
}, &app);
```

Or use `AuthMiddleware` directly inside your handler for custom flow:

```zig
const auth_mw = z_server_auth.AuthMiddleware.init(&auth, .{
    .require_https = true, // Soft check via X-Forwarded-Proto: https
    .allow_x_api_key = true,
});

pub fn handleProtected(req: *httpz.Request, res: *httpz.Response) !void {
    // Authenticate request and enforce required scope
    const auth_ctx = (try auth_mw.authenticate(req, res, res.arena, "items:write")) orelse return;

    // Access validated caller information
    std.log.info("Request authorized for user: {s}", .{auth_ctx.user_id});
    try res.json(.{ .status = "ok", .user = auth_ctx.user_id }, .{});
}
```

---

## Generating API Keys from CLI

`z-server` and `hello-auth` support CLI key generation via the `create-key` subcommand:

```bash
# Generate key with default permissions (*)
./zig-out/bin/z-server create-key

# Generate key for specific user and scopes
./zig-out/bin/z-server create-key --name "tenant_alice" --scopes "items:read items:write"

# Output format:
# zs_live_L9TsGEkgBYv3HNBT6GK7uBfhadsFa8Ilv_xB-XidpP8_0yz9bf
```

---

## Configuration Schema v2

In `config.json`, the `"auth"` section configures module behavior:

```json
{
  "$schema_version": 2,
  "server": {
    "bind": "127.0.0.1:8080"
  },
  "sqlite": {
    "path": "data/app.db"
  },
  "cache": {
    "nshards": 512
  },
  "auth": {
    "enabled": true,
    "require_https": true
  }
}
```

> **Security Note**: Never put the secret pepper in `config.json`. The pepper must always be supplied via the `Z_SERVER_AUTH_PEPPER` environment variable.

---

## Threat Model & Security Controls

| Threat | Security Control |
|---|---|
| **Database Compromise** | Only HMAC-SHA256 hashes stored in SQLite. Pepper stored exclusively in environment variable. |
| **Timing Side-Channels** | `std.crypto.timing_safe.eql` constant-time verification; dummy hashing computed on nonexistent keys. |
| **Credential Leakage in Logs** | `maskKey` utility logs only prefix and last 4 characters (`zs_live_...9f2b`). |
| **Accidental Exposure (Git/Chat)** | Standard prefix `zs_live_` and checksum enable immediate detection by secret scanning engines. |
| **Insecure Transport** | Soft HTTPS check (`X-Forwarded-Proto: https` from TLS terminator) rejects cleartext requests. |
| **Database Write Bottleneck** | In-memory atomic throttling writes `last_used_at` at most once every 60s per key. |
| **Downtime During Rotation** | `rotate(key_id)` supports concurrent active keys during client credential transitions. |
