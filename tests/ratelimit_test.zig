const std = @import("std");
const httpz = @import("httpz");
const z_server_cache = @import("z_server_cache");
const z_server_ratelimit = @import("z_server_ratelimit");

const Limiter = z_server_ratelimit.Limiter;
const Policy = z_server_ratelimit.Policy;
const LimitBy = z_server_ratelimit.LimitBy;
const Decision = z_server_ratelimit.Decision;
const AuthContext = z_server_ratelimit.AuthContext;
const setAuthContext = z_server_ratelimit.setAuthContext;
const getAuthContext = z_server_ratelimit.getAuthContext;
const extractClientIp = z_server_ratelimit.extractClientIp;
const extractKey = z_server_ratelimit.extractKey;
const applyRateLimit = z_server_ratelimit.applyRateLimit;
const wrap = z_server_ratelimit.wrap;

test "1. Token bucket: 10 hits OK + 11th 429" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 10,
        .window_seconds = 60,
        .by = .ip,
    };

    // First 10 requests allowed
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const d = try limiter.check(policy, "192.168.1.1");
        try std.testing.expect(d.allowed);
        try std.testing.expectEqual(@as(u32, 10), d.limit);
        try std.testing.expectEqual(@as(u32, @intCast(9 - i)), d.remaining);
    }

    // 11th request denied
    const d11 = try limiter.check(policy, "192.168.1.1");
    try std.testing.expect(!d11.allowed);
    try std.testing.expectEqual(@as(u32, 0), d11.remaining);
    try std.testing.expect(d11.retry_after_s > 0);
}

test "2. Refill replenishment: tokens recover over time" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 2,
        .window_seconds = 1, // 2 tokens per 1s = 2 tokens/sec
        .by = .ip,
    };

    const d1 = try limiter.check(policy, "10.0.0.1");
    try std.testing.expect(d1.allowed);
    const d2 = try limiter.check(policy, "10.0.0.1");
    try std.testing.expect(d2.allowed);
    const d3 = try limiter.check(policy, "10.0.0.1");
    try std.testing.expect(!d3.allowed);

    // Sleep 1.1s to allow token replenishment
    try std.testing.io.sleep(.fromMilliseconds(1100), .awake);

    const d4 = try limiter.check(policy, "10.0.0.1");
    try std.testing.expect(d4.allowed);
}

test "3. IP extraction: X-Forwarded-For vs RemoteAddr" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    // 3a: X-Forwarded-For header present (multi-IP)
    ht.header("x-forwarded-for", "203.0.113.195, 70.41.3.18:80");
    const ip1 = extractClientIp(ht.req, ht.res.arena);
    try std.testing.expectEqualStrings("203.0.113.195", ip1);

    // 3b: X-Forwarded-For with single IP and port
    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    ht2.header("x-forwarded-for", "198.51.100.22:443");
    const ip2 = extractClientIp(ht2.req, ht2.res.arena);
    try std.testing.expectEqualStrings("198.51.100.22", ip2);

    // 3c: No X-Forwarded-For header -> fallback to req.address
    var ht3 = httpz.testing.init(.{});
    defer ht3.deinit();
    const ip3 = extractClientIp(ht3.req, ht3.res.arena);
    // In httpz testing, default req.address is 127.0.0.1 (or similar)
    try std.testing.expect(ip3.len > 0);
}

test "4. Global dimension: same bucket for all requests" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 3,
        .window_seconds = 60,
        .by = .global,
    };

    var ht1 = httpz.testing.init(.{});
    defer ht1.deinit();
    ht1.header("x-forwarded-for", "1.1.1.1");
    const key1 = (try extractKey(policy, ht1.req, ht1.res)).?;
    try std.testing.expectEqualStrings("global", key1);
    const d1 = try limiter.check(policy, key1);
    try std.testing.expect(d1.allowed);

    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    ht2.header("x-forwarded-for", "2.2.2.2");
    const key2 = (try extractKey(policy, ht2.req, ht2.res)).?;
    try std.testing.expectEqualStrings("global", key2);
    const d2 = try limiter.check(policy, key2);
    try std.testing.expect(d2.allowed);

    const d3 = try limiter.check(policy, key2);
    try std.testing.expect(d3.allowed);

    // 4th request exceeds global capacity of 3
    const d4 = try limiter.check(policy, key2);
    try std.testing.expect(!d4.allowed);
}

test "5. Header dimension: separated by header value, 500 when missing" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 2,
        .window_seconds = 60,
        .by = .{ .header = "x-tenant-id" },
    };

    // Tenant A
    var ht_a = httpz.testing.init(.{});
    defer ht_a.deinit();
    ht_a.header("x-tenant-id", "tenant-alpha");
    const key_a = (try extractKey(policy, ht_a.req, ht_a.res)).?;
    try std.testing.expectEqualStrings("tenant-alpha", key_a);
    try std.testing.expect((try limiter.check(policy, key_a)).allowed);
    try std.testing.expect((try limiter.check(policy, key_a)).allowed);
    try std.testing.expect(!(try limiter.check(policy, key_a)).allowed); // Tenant A exhausted

    // Tenant B still has capacity
    var ht_b = httpz.testing.init(.{});
    defer ht_b.deinit();
    ht_b.header("x-tenant-id", "tenant-beta");
    const key_b = (try extractKey(policy, ht_b.req, ht_b.res)).?;
    try std.testing.expectEqualStrings("tenant-beta", key_b);
    try std.testing.expect((try limiter.check(policy, key_b)).allowed);

    // Missing header returns null and sets 500
    var ht_c = httpz.testing.init(.{});
    defer ht_c.deinit();
    const key_c = try extractKey(policy, ht_c.req, ht_c.res);
    try std.testing.expectEqual(@as(?[]const u8, null), key_c);
    try ht_c.expectStatus(500);
}

test "6. Retry-After header present in 429 response" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 1,
        .window_seconds = 30,
        .by = .ip,
    };

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.header("x-forwarded-for", "192.0.2.1");

    // Hit 1: allowed (200)
    const ok1 = try applyRateLimit(&limiter, policy, ht.req, ht.res);
    try std.testing.expect(ok1);
    try std.testing.expectEqualStrings("1", ht.res.headers.get("RateLimit-Limit").?);
    try std.testing.expectEqualStrings("0", ht.res.headers.get("RateLimit-Remaining").?);

    // Hit 2: blocked (429)
    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    ht2.header("x-forwarded-for", "192.0.2.1");

    const ok2 = try applyRateLimit(&limiter, policy, ht2.req, ht2.res);
    try std.testing.expect(!ok2);
    try ht2.expectStatus(429);
    const retry_hdr = ht2.res.headers.get("Retry-After");
    try std.testing.expect(retry_hdr != null);
    const retry_val = try std.fmt.parseInt(u32, retry_hdr.?, 10);
    try std.testing.expect(retry_val > 0);
    try std.testing.expect(retry_val <= 30);
}

test "7. RateLimit-Remaining decrements correctly" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 4,
        .window_seconds = 60,
        .by = .ip,
    };

    const d1 = try limiter.check(policy, "test-key");
    try std.testing.expectEqual(@as(u32, 3), d1.remaining);
    const d2 = try limiter.check(policy, "test-key");
    try std.testing.expectEqual(@as(u32, 2), d2.remaining);
    const d3 = try limiter.check(policy, "test-key");
    try std.testing.expectEqual(@as(u32, 1), d3.remaining);
    const d4 = try limiter.check(policy, "test-key");
    try std.testing.expectEqual(@as(u32, 0), d4.remaining);
}

test "8. RateLimit-Reset reflects time to complete refill" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 10,
        .window_seconds = 50, // refill rate = 0.2 tokens/sec
        .by = .ip,
    };

    // First request: 9 tokens remaining, 1 token missing -> 1 / 0.2 = 5 seconds to reset
    const d1 = try limiter.check(policy, "reset-client");
    try std.testing.expectEqual(@as(u32, 5), d1.reset_in_s);

    // Consume all remaining 9 tokens (total 10 consumed)
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        _ = try limiter.check(policy, "reset-client");
    }

    // 10 tokens missing -> 10 / 0.2 = 50 seconds to reset
    const d11 = try limiter.check(policy, "reset-client");
    try std.testing.expectEqual(@as(u32, 50), d11.reset_in_s);
}

test "9. post_auth auto-detect and explicit override" {
    const p_ip = Policy{ .by = .ip };
    try std.testing.expect(!p_ip.isPostAuth());

    const p_global = Policy{ .by = .global };
    try std.testing.expect(!p_global.isPostAuth());

    const p_hdr = Policy{ .by = .{ .header = "x-key" } };
    try std.testing.expect(!p_hdr.isPostAuth());

    const p_api = Policy{ .by = .api_key };
    try std.testing.expect(p_api.isPostAuth());

    const p_jwt = Policy{ .by = .jwt_sub };
    try std.testing.expect(p_jwt.isPostAuth());

    // Explicit overrides
    const p_ip_override = Policy{ .by = .ip, .post_auth = true };
    try std.testing.expect(p_ip_override.isPostAuth());

    const p_api_override = Policy{ .by = .api_key, .post_auth = false };
    try std.testing.expect(!p_api_override.isPostAuth());
}

test "10. Cache == null: uses in-memory HashMap" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{ .capacity = 5, .window_seconds = 60, .by = .ip };

    try std.testing.expectEqual(@as(usize, 0), limiter.map.count());
    _ = try limiter.check(policy, "mem-client");
    try std.testing.expectEqual(@as(usize, 1), limiter.map.count());
}

test "11. Cache != null: uses Pogocache" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var cache = try z_server_cache.Cache.init(a, 16);
    defer cache.deinit();

    var limiter = Limiter.init(a, io, &cache);
    defer limiter.deinit();

    const policy = Policy{ .capacity = 3, .window_seconds = 60, .by = .ip };

    // Limiter in-memory map remains empty because cache is active
    _ = try limiter.check(policy, "cache-client");
    try std.testing.expectEqual(@as(usize, 0), limiter.map.count());

    // Second check succeeds and continues to use cache
    const d2 = try limiter.check(policy, "cache-client");
    try std.testing.expectEqual(@as(u32, 1), d2.remaining);

    // Third check exhausts capacity
    const d3 = try limiter.check(policy, "cache-client");
    try std.testing.expectEqual(@as(u32, 0), d3.remaining);

    // Fourth check denied
    const d4 = try limiter.check(policy, "cache-client");
    try std.testing.expect(!d4.allowed);
}

test "12. Independent policies do not interfere" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy_read = Policy{ .capacity = 2, .window_seconds = 60, .by = .ip };
    const policy_write = Policy{ .capacity = 5, .window_seconds = 60, .by = .ip };

    const client = "192.168.1.100";

    // Exhaust policy_read
    _ = try limiter.check(policy_read, client);
    _ = try limiter.check(policy_read, client);
    const d_read_blocked = try limiter.check(policy_read, client);
    try std.testing.expect(!d_read_blocked.allowed);

    // policy_write for same client is still allowed with its own capacity
    const d_write = try limiter.check(policy_write, client);
    try std.testing.expect(d_write.allowed);
    try std.testing.expectEqual(@as(u32, 4), d_write.remaining);
}

fn customExtractor(req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    _ = res;
    if (req.header("x-organization-id")) |org| {
        return org;
    }
    return null;
}

test "13. Custom extractor works" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var limiter = Limiter.init(a, io, null);
    defer limiter.deinit();

    const policy = Policy{
        .capacity = 2,
        .window_seconds = 60,
        .by = .{ .custom = customExtractor },
    };

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.header("x-organization-id", "org-acme");

    const key = (try extractKey(policy, ht.req, ht.res)).?;
    try std.testing.expectEqualStrings("org-acme", key);

    try std.testing.expect((try limiter.check(policy, key)).allowed);
}

test "14. wrap() handler wrapping with httpz testing" {
    const TestHandler = struct {
        var call_count: u32 = 0;
        fn handle(req: *httpz.Request, res: *httpz.Response) anyerror!void {
            _ = req;
            call_count += 1;
            try res.json(.{ .ok = true }, .{});
        }
    };

    TestHandler.call_count = 0;

    const wrapped = wrap(.{
        .capacity = 2,
        .window_seconds = 60,
        .by = .ip,
    }, TestHandler.handle);

    var ht1 = httpz.testing.init(.{});
    defer ht1.deinit();
    ht1.header("x-forwarded-for", "10.10.10.1");
    try wrapped(ht1.req, ht1.res);
    try std.testing.expectEqual(@as(u32, 1), TestHandler.call_count);
    try ht1.expectStatus(200);

    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    ht2.header("x-forwarded-for", "10.10.10.1");
    try wrapped(ht2.req, ht2.res);
    try std.testing.expectEqual(@as(u32, 2), TestHandler.call_count);
    try ht2.expectStatus(200);

    // 3rd hit exceeds capacity -> 429 and target is not invoked
    var ht3 = httpz.testing.init(.{});
    defer ht3.deinit();
    ht3.header("x-forwarded-for", "10.10.10.1");
    try wrapped(ht3.req, ht3.res);
    try std.testing.expectEqual(@as(u32, 2), TestHandler.call_count);
    try ht3.expectStatus(429);
}

test "15. AuthContext: api_key and jwt_sub extraction" {
    const a = std.testing.allocator;

    setAuthContext(.{ .key_id = 42, .sub = "user_abc" });
    defer setAuthContext(null);

    const p_api = Policy{ .by = .api_key };
    var ht1 = httpz.testing.init(.{});
    defer ht1.deinit();
    const key_api = (try extractKey(p_api, ht1.req, ht1.res)).?;
    try std.testing.expectEqualStrings("key:42", key_api);

    const p_jwt = Policy{ .by = .jwt_sub };
    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    const key_jwt = (try extractKey(p_jwt, ht2.req, ht2.res)).?;
    try std.testing.expectEqualStrings("sub:user_abc", key_jwt);

    _ = a;
}
