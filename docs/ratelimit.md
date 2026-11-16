# Rate Limiting with `z_server_ratelimit`

`z_server_ratelimit` provides production-grade HTTP rate limiting for `z-server` applications and downstream consumers. It implements the standard **Token Bucket** algorithm, emits **IETF-compliant RateLimit headers**, supports multiple rate-limiting dimensions, and provides zero-overhead route wrapping.

## Architecture & Algorithm

### Token Bucket Algorithm

Each client bucket starts with an initial capacity of `capacity` tokens. Over time, tokens replenish at a steady rate:

$$\text{refill\_rate} = \frac{\text{capacity}}{\text{window\_seconds}} \quad (\text{tokens per second})$$

On each incoming request:
1. Replenishment: $\text{tokens} = \min(\text{capacity}, \text{tokens} + \Delta t \times \text{refill\_rate})$.
2. If $\text{tokens} \ge 1.0$:
   - Consume 1 token ($\text{tokens} \gets \text{tokens} - 1.0$).
   - Request is **allowed** (HTTP 200).
   - Remaining tokens: $\lfloor \text{tokens} \rfloor$.
3. If $\text{tokens} < 1.0$:
   - Request is **denied** with HTTP 429 Too Many Requests.
   - Retry wait: $\lceil (1.0 - \text{tokens}) / \text{refill\_rate} \rceil$ seconds.

### Dual Storage Strategy

- **Pogocache (`z_server_cache`)**: If an instance of `*z_server_cache.Cache` is passed to `Limiter.init`, the limiter uses Pogocache with automatic expiration ($TTL = 2 \times \text{window\_seconds}$).
- **In-Memory Fallback (`AutoHashMap`)**: If no cache is passed (`cache == null`), the limiter uses an internal thread-safe `std.AutoHashMap(MemKey, BucketEntry)` with periodic background cleanup every 60 seconds.

## IETF Standard Headers

`z_server_ratelimit` sets the following HTTP headers on every request:

| Header | Description | Example |
|---|---|---|
| `RateLimit-Limit` | Maximum burst capacity in the configured window | `100` |
| `RateLimit-Remaining` | Remaining request tokens in the current window | `87` |
| `RateLimit-Reset` | Approximate seconds until the bucket is completely full | `12` |
| `Retry-After` | Seconds to wait before retrying (emitted **only** on HTTP 429) | `5` |

When a request is rate-limited (HTTP 429), the response body is formatted as JSON:

```json
{
  "error": "rate_limited",
  "message": "Too many requests. Retry in 5 seconds.",
  "retry_after": 5
}
```

## Policy Configuration & Dimensions

A rate-limiting policy is defined via `z_server_ratelimit.Policy`:

```zig
pub const Policy = struct {
    capacity: u32 = 100,
    window_seconds: u32 = 60,
    by: LimitBy = .ip,
    post_auth: ?bool = null,
};
```

### Supported Dimensions (`LimitBy`)

- **`.ip`**: Extracts the client IP. Prefers the first IP in `X-Forwarded-For` (stripping port numbers) if present; falls back to the socket's peer address (`req.address`).
- **`.api_key`**: Rates by API Key ID stored in `AuthContext` (`key:<id>`). Auto-detected as post-auth.
- **`.jwt_sub`**: Rates by JWT subject identifier (`sub:<subject>`). Auto-detected as post-auth.
- **`.header: []const u8`**: Rates by the value of a specific HTTP header (e.g. `X-Tenant-ID`). Returns HTTP 500 if the header is missing.
- **`.global`**: A single shared bucket for all requests on that endpoint (e.g., protecting a high-load webhook).
- **`.custom: *const fn (*Request, *Response) ?[]const u8`**: A user-defined callback that extracts any custom bucket key.

### Pre-Auth vs Post-Auth Auto-Detection

- If `by` is `.api_key` or `.jwt_sub`, `policy.isPostAuth()` evaluates to `true`.
- If `by` is `.ip`, `.global`, `.header`, or `.custom`, `policy.isPostAuth()` evaluates to `false`.
- The behavior can be explicitly overridden via `.post_auth = true` or `.post_auth = false`.

## Route Middleware Wrapping

Handlers can be protected cleanly using `z_server_ratelimit.wrap`:

```zig
const z_ratelimit = @import("z_server_ratelimit");

// Protect a freestanding handler
const public_handler = z_ratelimit.wrap(.{
    .capacity = 100,
    .window_seconds = 60,
    .by = .ip,
}, handlePublic);

// Protect a context-based handler (AppCtx)
const api_handler = z_ratelimit.wrap(.{
    .capacity = 10,
    .window_seconds = 60,
    .by = .ip,
}, handleApi);
```

When using `wrap`, if `AppCtx` has a `.limiter` pointer or optional pointer, `wrap` uses that limiter instance. Otherwise, it uses a process-wide thread-safe default limiter.

## Direct Limiter API

For custom integrations or non-HTTP services:

```zig
var limiter = z_ratelimit.Limiter.init(allocator, io, cache_ptr);
defer limiter.deinit();

const policy = z_ratelimit.Policy{
    .capacity = 50,
    .window_seconds = 60,
    .by = .ip,
};

const decision = try limiter.check(policy, "192.168.1.10");
if (decision.allowed) {
    // Process request
} else {
    // Retry after decision.retry_after_s seconds
}
```
