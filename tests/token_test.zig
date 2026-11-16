const std = @import("std");
const httpz = @import("httpz");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_auth = @import("z_server_auth");
const z_server_jwt = @import("z_server_jwt");
const z_server_token = @import("z_server_token");

const TEST_PEPPER_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const TEST_JWT_SECRET = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

const TestEnv = struct {
    pool: z_server_db.Pool,
    cache: z_server_cache.Cache,
    auth: z_server_auth.Authenticator,
    jwt: z_server_jwt.Authenticator,
    endpoint: z_server_token.TokenEndpoint,
    api_key: [z_server_auth.KEY_LEN]u8,

    pub fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        self.endpoint.deinit();
        self.jwt.deinit();
        self.auth.deinit();
        self.cache.deinit();
        self.pool.deinit();
        allocator.destroy(self);
    }
};

fn cleanupDbFiles(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var wal_buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path})) |wal| {
        std.Io.Dir.deleteFileAbsolute(io, wal) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&wal_buf, "{s}-shm", .{path})) |shm| {
        std.Io.Dir.deleteFileAbsolute(io, shm) catch {};
    } else |_| {}
}

fn setupTestEnv(allocator: std.mem.Allocator, io: std.Io, path: []const u8, custom_limits: ?struct { ip: u32, key: u32 }) !*TestEnv {
    const env = try allocator.create(TestEnv);
    errdefer allocator.destroy(env);

    const c_path = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(c_path);

    env.pool = try z_server_db.Pool.init(allocator, io, .{
        .path = c_path,
        .pool_size = 2,
    });
    errdefer env.pool.deinit();

    env.cache = try z_server_cache.Cache.init(allocator, 16);
    errdefer env.cache.deinit();

    env.auth = try z_server_auth.Authenticator.init(allocator, io, &env.pool, .{
        .pepper = TEST_PEPPER_HEX,
        .cache = &env.cache,
        .require_https = false,
    });
    errdefer env.auth.deinit();

    env.jwt = try z_server_jwt.Authenticator.init(allocator, io, &env.pool, .{
        .secret = TEST_JWT_SECRET,
        .ttl_seconds = 900,
        .cache = &env.cache,
        .require_https = false,
    });
    errdefer env.jwt.deinit();

    const created = try env.auth.createKey(.{
        .user_id = "test_user",
        .scopes = "items:read items:write",
    });
    @memcpy(&env.api_key, created.plaintext());

    const opts = z_server_token.Options{
        .endpoint_path = "/auth/token",
        .rate_limit_ip_per_min = if (custom_limits) |cl| cl.ip else 30,
        .rate_limit_key_per_min = if (custom_limits) |cl| cl.key else 60,
        .ttl_seconds = 900,
        .cache = &env.cache,
    };

    env.endpoint = try z_server_token.TokenEndpoint.init(allocator, io, &env.auth, &env.jwt, opts);

    return env;
}

test "1. handle with valid API key and grant_type=client_credentials -> 200 with JWT" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_1.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(200);
    try ht.expectHeader("Cache-Control", "no-store");
    try ht.expectHeader("Pragma", "no-cache");

    const json_val = try ht.getJson();
    const token = json_val.object.get("access_token").?.string;
    const token_type = json_val.object.get("token_type").?.string;
    const expires_in = json_val.object.get("expires_in").?.integer;
    const scope = json_val.object.get("scope").?.string;

    try std.testing.expect(token.len > 0);
    try std.testing.expectEqualStrings("Bearer", token_type);
    try std.testing.expectEqual(@as(i64, 900), expires_in);
    try std.testing.expectEqualStrings("items:read items:write", scope);

    // Validate the issued token with JWT Authenticator
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const claims = (try env.jwt.validate(token, arena.allocator())).?;
    try std.testing.expectEqualStrings("test_user", claims.sub);
    try std.testing.expectEqualStrings("items:read items:write", claims.scope);
}

test "2. handle without grant_type defaults to client_credentials -> 200" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_2.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.body("{}");

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(200);
    const json_val = try ht.getJson();
    try std.testing.expect(json_val.object.get("access_token") != null);
}

test "3. handle with invalid grant_type (e.g. password) -> 400 unsupported_grant_type" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_3.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.json(.{ .grant_type = "password" });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(400);
    try ht.expectJson(.{ .@"error" = "unsupported_grant_type" });
}

test "4. handle with malformed JSON body -> 400 invalid_request" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_4.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.body("{\"grant_type\": broken-json");

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(400);
    try ht.expectJson(.{ .@"error" = "invalid_request" });
}

test "5. handle with valid downscoped scope -> 200 with reduced scope" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_5.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.json(.{
        .grant_type = "client_credentials",
        .scope = "items:read",
    });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(200);
    const json_val = try ht.getJson();
    const scope = json_val.object.get("scope").?.string;
    try std.testing.expectEqualStrings("items:read", scope);
}

test "6. handle with invalid scope (not a subset) -> 400 invalid_scope" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_6.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.json(.{
        .grant_type = "client_credentials",
        .scope = "admin:drop",
    });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(400);
    try ht.expectJson(.{ .@"error" = "invalid_scope" });
}

test "7. handle missing API key -> 401 invalid_client" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_7.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    ht.body("{}");

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(401);
    try ht.expectHeader("WWW-Authenticate", "Bearer realm=\"z-server\", error=\"invalid_client\"");
    try ht.expectJson(.{ .@"error" = "invalid_client" });
}

test "8. handle invalid API key -> 401 invalid_client" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_8.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    ht.header("authorization", "Bearer zs_live_invalidkey1234567890123456789012345678901234567890123456");
    ht.body("{}");

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(401);
    try ht.expectJson(.{ .@"error" = "invalid_client" });
}

test "9. handle API key in X-API-Key header -> 200" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_9.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    ht.header("x-api-key", &env.api_key);
    ht.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(200);
}

test "10. handle API key in JSON body -> 200" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_10.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    ht.json(.{
        .grant_type = "client_credentials",
        .api_key = &env.api_key,
    });

    try env.endpoint.handle(ht.req, ht.res);

    try ht.expectStatus(200);
}

test "11. IP rate limiting: 30 req OK, 31st -> 429 with Retry-After" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_11.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, .{
        .ip = 30,
        .key = 100, // keep key limit higher to test IP limit
    });
    defer env.deinit(a);

    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);

    // 30 requests should succeed
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/auth/token");
        ht.header("authorization", auth_hdr);
        ht.header("x-forwarded-for", "192.168.1.100");
        ht.json(.{ .grant_type = "client_credentials" });

        try env.endpoint.handle(ht.req, ht.res);
        try ht.expectStatus(200);
    }

    // 31st request from same IP should get 429
    var ht31 = httpz.testing.init(.{});
    defer ht31.deinit();
    ht31.url("/auth/token");
    ht31.header("authorization", auth_hdr);
    ht31.header("x-forwarded-for", "192.168.1.100");
    ht31.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht31.req, ht31.res);
    try ht31.expectStatus(429);
    try ht31.expectHeader("Retry-After", "60");
    try ht31.expectJson(.{ .@"error" = "rate_limited" });

    // Different IP should still succeed
    var ht_diff = httpz.testing.init(.{});
    defer ht_diff.deinit();
    ht_diff.url("/auth/token");
    ht_diff.header("authorization", auth_hdr);
    ht_diff.header("x-forwarded-for", "192.168.1.101");
    ht_diff.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht_diff.req, ht_diff.res);
    try ht_diff.expectStatus(200);
}

test "12. API key rate limiting: 60 req OK, 61st -> 429" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_12.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, .{
        .ip = 200, // keep IP limit higher
        .key = 60,
    });
    defer env.deinit(a);

    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/auth/token");
        ht.header("authorization", auth_hdr);
        // Vary IP so IP limit is never hit
        var ip_buf: [32]u8 = undefined;
        const fake_ip = try std.fmt.bufPrint(&ip_buf, "10.0.{d}.{d}", .{ i / 250, (i % 250) + 1 });
        ht.header("x-forwarded-for", fake_ip);
        ht.json(.{ .grant_type = "client_credentials" });

        try env.endpoint.handle(ht.req, ht.res);
        try ht.expectStatus(200);
    }

    // 61st request with same key should get 429
    var ht61 = httpz.testing.init(.{});
    defer ht61.deinit();
    ht61.url("/auth/token");
    ht61.header("authorization", auth_hdr);
    ht61.header("x-forwarded-for", "10.0.99.99");
    ht61.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht61.req, ht61.res);
    try ht61.expectStatus(429);
    try ht61.expectHeader("Retry-After", "60");
}

test "13. RateLimiter unit test with cache and with in-memory HashMap fallback" {
    const a = std.testing.allocator;

    // A. With Cache (Pogocache)
    var cache = try z_server_cache.Cache.init(a, 16);
    defer cache.deinit();

    var cache_limiter = z_server_token.RateLimiter.init(a, null, &cache);
    defer cache_limiter.deinit();

    try std.testing.expect(try cache_limiter.checkAndIncrement(.ip, "1.2.3.4", 3, 60));
    try std.testing.expect(try cache_limiter.checkAndIncrement(.ip, "1.2.3.4", 3, 60));
    try std.testing.expect(try cache_limiter.checkAndIncrement(.ip, "1.2.3.4", 3, 60));
    // 4th should exceed limit 3
    try std.testing.expect(!try cache_limiter.checkAndIncrement(.ip, "1.2.3.4", 3, 60));
    // Different IP should succeed
    try std.testing.expect(try cache_limiter.checkAndIncrement(.ip, "1.2.3.5", 3, 60));

    // B. With in-memory AutoHashMap fallback (cache == null)
    var mem_limiter = z_server_token.RateLimiter.init(a, null, null);
    defer mem_limiter.deinit();

    try std.testing.expect(try mem_limiter.checkAndIncrement(.api_key, "key_42", 2, 60));
    try std.testing.expect(try mem_limiter.checkAndIncrement(.api_key, "key_42", 2, 60));
    // 3rd should exceed limit 2
    try std.testing.expect(!try mem_limiter.checkAndIncrement(.api_key, "key_42", 2, 60));
    // Different key should succeed
    try std.testing.expect(try mem_limiter.checkAndIncrement(.api_key, "key_43", 2, 60));

    // Test cleanup
    const now = z_server_token.RateLimiter.getUnixTimestamp();
    mem_limiter.cleanup(now + 100);
}

test "14. Revoke JWT invalidates token in denylist" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_token_14.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path, null);
    defer env.deinit(a);

    // Issue token via endpoint
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.url("/auth/token");
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{&env.api_key});
    defer a.free(auth_hdr);
    ht.header("authorization", auth_hdr);
    ht.json(.{ .grant_type = "client_credentials" });

    try env.endpoint.handle(ht.req, ht.res);
    try ht.expectStatus(200);

    const json_val = try ht.getJson();
    const token = json_val.object.get("access_token").?.string;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Verify token is initially valid
    const claims = (try env.jwt.validate(token, arena.allocator())).?;

    // Revoke the token using its jti
    try env.jwt.revoke(claims.jti, claims.exp);

    // Validate again -> should return null because token is in denylist
    const res2 = try env.jwt.validate(token, arena.allocator());
    try std.testing.expect(res2 == null);
}
