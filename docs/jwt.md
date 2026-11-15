# z_server_jwt — JSON Web Token (JWT) Authentication Module

The `z_server_jwt` module provides a high-performance, strictly-verified JSON Web Token (JWT) implementation in pure Zig for the `z-server` ecosystem.

## Key Features

- **Strict Algorithm Enforcement (S1)**: Exclusively supports `HS256`. Explicitly rejects `alg: none`, `RS256`, and any algorithm other than `HS256` in the JOSE header to prevent key-confusion and bypass vulnerabilities.
- **Constant-Time Verification (S2)**: HMAC-SHA256 signatures are verified using `std.crypto.timing_safe.eql` to eliminate timing side channels.
- **Fail-Fast Secret Validation (S3)**: Requires a 256-bit (>= 32 bytes) cryptographically secure secret via `Z_SERVER_JWT_SECRET` (Hex, Base64, Base64URL, or raw bytes). Fails immediately at initialization if secret is missing or under 32 bytes.
- **Dual Secret Rotation**: Supports seamless zero-downtime key rotation via `Z_SERVER_JWT_SECRET_SECONDARY`. New tokens are issued with the primary secret, while valid tokens signed with the secondary secret are accepted during the rotation grace period.
- **Strict Claim Validation (S4)**: Validates `iss == "z-server"`, `aud == "z-server-api"`, `exp`, `nbf`, `iat` with configurable clock-skew tolerance (default 30 seconds), and requires a non-empty `jti` (UUID v4).
- **Immediate Revocation via Denylist (Decisions 5 & 6)**: Individual tokens can be revoked before expiration by storing their `jti` in SQLite (`revoked_jwt`). Lookups are accelerated by Pogocache with a 5-second TTL.
- **Memory Zeroing (S5)**: Intermediate buffers, secret keys, and decoded payloads are scrubbed with `std.crypto.secureZero`.
- **Sanitized Logging (S6)**: Validation failures log only `jti`, `sub`, and failure reason; full token strings are never written to logs.
- **Transport Security (S7)**: Enforces soft HTTPS verification (`X-Forwarded-Proto: https`) when TLS or `require_https` is active.
- **Opaque Refresh Tokens (Decision 4)**: 7-day opaque refresh tokens (32 cryptographically random bytes) stored in SQLite as HMAC-SHA256 hashes using the JWT secret as pepper.

---

## Secret Generation & Configuration

`z_server_jwt` enforces a minimum 256-bit (32-byte) secret.

### 1. Generate Primary Secret

```bash
# Hex format (64 characters) - Recommended
export Z_SERVER_JWT_SECRET=$(openssl rand -hex 32)

# Or Base64 format (44 characters)
export Z_SERVER_JWT_SECRET=$(openssl rand -base64 32)
```

### 2. Configure Secondary Secret (Key Rotation)

When rotating signing secrets, export the previous secret as secondary:

```bash
export Z_SERVER_JWT_SECRET_SECONDARY="<previous-32-byte-secret>"
export Z_SERVER_JWT_SECRET="<newly-generated-32-byte-secret>"
```

---

## Claims Specification

| Claim | Type | Description | Required | Validation Rule |
| :--- | :--- | :--- | :--- | :--- |
| `iss` | string | Token issuer | Yes | Must equal `"z-server"` exactly |
| `aud` | string | Target audience | Yes | Must equal `"z-server-api"` exactly |
| `sub` | string | Subject / user ID | Yes | Non-empty string |
| `jti` | string | Unique token ID | Yes | UUID v4 (36 chars), checked against `revoked_jwt` denylist |
| `iat` | integer | Issued at (Unix timestamp) | Yes | `iat <= now + 30s` (future-dated tokens rejected) |
| `nbf` | integer | Not before (Unix timestamp) | Yes | `nbf <= now + 30s` |
| `exp` | integer | Expiration (Unix timestamp) | Yes | `exp > now - 30s` |
| `scope`| string | Permissions list | No | Space- or comma-separated scopes (e.g. `items:read items:write` or `*`) |

---

## Consumer Usage Example

```zig
const std = @import("std");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_jwt = @import("z_server_jwt");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 1. Initialize SQLite Pool
    var pool = try z_server_db.Pool.init(allocator, io, .{
        .path = "data/app.db",
        .pool_size = 4,
    });
    defer pool.deinit();

    // 2. Initialize In-Memory Cache (Pogocache)
    var cache = try z_server_cache.Cache.init(allocator, 512);
    defer cache.deinit();

    // 3. Initialize JWT Authenticator
    var auth = try z_server_jwt.Authenticator.init(allocator, io, &pool, .{
        .secret = std.posix.getenv("Z_SERVER_JWT_SECRET") orelse return error.MissingSecret,
        .secondary_secret = std.posix.getenv("Z_SERVER_JWT_SECRET_SECONDARY"),
        .ttl_seconds = 900, // 15 minutes
        .cache = &cache,
        .denylist_cache_ttl_seconds = 5,
        .require_https = true,
    });
    defer auth.deinit();

    // 4. Issue a JWT Token
    const token = try auth.issue(allocator, "alice", "items:read items:write", null);
    defer allocator.free(token);
    std.log.info("Issued JWT: {s}", .{token});

    // 5. Validate Token
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    if (try auth.validate(token, arena.allocator())) |claims| {
        std.log.info("Valid token for user: {s}, scope: {s}", .{ claims.sub, claims.scope });
        if (claims.hasScope("items:read")) {
            std.log.info("Permission granted for items:read", .{});
        }
    } else {
        std.log.warn("Invalid or expired token", .{});
    }

    // 6. Revoke Token via jti
    // try auth.revoke(claims.jti, claims.exp);
}
```

---

## Refresh Tokens (Decision 4)

Refresh tokens are opaque 32-byte cryptographically random strings (Base64URL encoded, 43 chars) stored in SQLite:

```zig
// Initialize refresh tokens table
try z_server_jwt.initRefreshSchema(&pool);

// Create a refresh token (7-day validity)
const res = try z_server_jwt.createRefreshToken(
    allocator,
    io,
    &pool,
    &auth.primary_key,
    "alice",
    "items:read items:write",
);
std.log.info("Refresh token: {s}", .{res.plaintext()});

// Validate refresh token
if (try z_server_jwt.validateRefreshToken(allocator, &pool, &auth.primary_key, res.plaintext())) |claims| {
    // Issue a new access token for claims.sub with claims.scopes
}

// Revoke refresh token
try z_server_jwt.revokeRefreshToken(&pool, &auth.primary_key, res.plaintext());
```

---

## CLI Commands

The CLI integrates `z-args` with dedicated subcommands:

### Issue a JWT Token

```bash
export Z_SERVER_JWT_SECRET=$(openssl rand -hex 32)

# Issue a token for user 'carol' with items:read scope and 10-minute TTL
./zig-out/bin/z-server issue-jwt --sub carol --scopes "items:read" --ttl 600
```

### CLI Help

```bash
./zig-out/bin/z-server --help
./zig-out/bin/z-server issue-jwt --help
./zig-out/bin/z-server create-key --help
./zig-out/bin/z-server init-config --help
```

---

## Security & Threat Model

| Threat | Mitigation in `z_server_jwt` |
| :--- | :--- |
| **`alg: none` bypass** | Header parser strictly requires `"alg":"HS256"`. Any missing or alternate algorithm returns verification failure immediately. |
| **Key Confusion (`RS256` / `HS256`)** | Asymmetric algorithms like `RS256` are rejected before any cryptographic operations. |
| **Timing Attacks** | All HMAC comparisons use `std.crypto.timing_safe.eql` constant-time comparison. |
| **Weak Secret Brute-Force** | Fail-fast initialization enforces >= 256 bits of entropy on all configured secrets. |
| **Revoked Token Replay** | Denylist table `revoked_jwt` checks `jti` on each request, cached with Pogocache for sub-millisecond lookups. Periodic `cleanup()` purges expired denylist records. |
| **Token Leakage in Logs** | Logging records only `jti`, `sub`, and failure codes; full JWT strings are never printed to stdout/stderr. |
| **Man-in-the-Middle Eavesdropping** | Enforces `X-Forwarded-Proto: https` check on HTTP requests when `require_https` is enabled. |
