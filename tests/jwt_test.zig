const std = @import("std");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_jwt = @import("z_server_jwt");

const TEST_SECRET_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const TEST_SEC_SECRET_HEX = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

const TestEnv = struct {
    pool: z_server_db.Pool,
    cache: z_server_cache.Cache,
    auth: z_server_jwt.Authenticator,

    pub fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        self.auth.deinit();
        self.pool.deinit();
        self.cache.deinit();
        allocator.destroy(self);
    }
};

fn setupTestEnv(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*TestEnv {
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

    env.auth = try z_server_jwt.Authenticator.init(allocator, io, &env.pool, .{
        .secret = TEST_SECRET_HEX,
        .secondary_secret = TEST_SEC_SECRET_HEX,
        .ttl_seconds = 900,
        .cache = &env.cache,
    });

    return env;
}

fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}

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

test "1. issue + validate roundtrip OK" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_roundtrip.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    const token = try env.auth.issue(a, "alice", "items:read items:write", null);
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const claims = (try env.auth.validate(token, arena.allocator())) orelse return error.ValidationFailed;
    try std.testing.expectEqualStrings("z-server", claims.iss);
    try std.testing.expectEqualStrings("z-server-api", claims.aud);
    try std.testing.expectEqualStrings("alice", claims.sub);
    try std.testing.expectEqualStrings("items:read items:write", claims.scope);
    try std.testing.expect(claims.jti.len == 36);
    try std.testing.expect(claims.exp - claims.iat == 900);
}

test "2. validate con token expirado returns null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_expired.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    // Token with negative TTL (already expired)
    const now = getUnixTimestamp();
    const exp = now - 100;
    const payload = try std.fmt.allocPrint(a,
        \\{{"iss":"z-server","aud":"z-server-api","sub":"bob","jti":"12345678-1234-4234-8234-123456789abc","iat":{d},"nbf":{d},"exp":{d},"scope":"read"}}
    , .{ exp - 10, exp - 10, exp });
    defer a.free(payload);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

    const payload_b64_len = enc.calcSize(payload.len);
    const payload_b64 = try a.alloc(u8, payload_b64_len);
    defer a.free(payload_b64);
    _ = enc.encode(payload_b64, payload);

    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, payload_b64 });
    defer a.free(signing_input);

    var sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, signing_input, &env.auth.primary_key);
    var sig_b64: [43]u8 = undefined;
    _ = enc.encode(&sig_b64, &sig);

    const token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, &sig_b64 });
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try env.auth.validate(token, arena.allocator());
    try std.testing.expect(res == null);
}

test "3. validate con token alg:none returns null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_none.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    // Header with alg: none
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_json = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    var header_b64_buf: [64]u8 = undefined;
    const header_b64 = enc.encode(&header_b64_buf, header_json);

    const payload_json = "{\"iss\":\"z-server\",\"aud\":\"z-server-api\",\"sub\":\"attacker\",\"jti\":\"test-none-jti\",\"iat\":1000,\"exp\":9999999999,\"scope\":\"admin\"}";
    var payload_b64_buf: [256]u8 = undefined;
    const payload_b64 = enc.encode(&payload_b64_buf, payload_json);

    const dummy_sig = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const token = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ header_b64, payload_b64, dummy_sig });
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try env.auth.validate(token, arena.allocator());
    try std.testing.expect(res == null);
}

test "4. validate con token alg:RS256 returns null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_rs256.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    // Header with alg: RS256
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    var header_b64_buf: [64]u8 = undefined;
    const header_b64 = enc.encode(&header_b64_buf, header_json);

    const payload_json = "{\"iss\":\"z-server\",\"aud\":\"z-server-api\",\"sub\":\"attacker\",\"jti\":\"test-rs-jti\",\"iat\":1000,\"exp\":9999999999,\"scope\":\"admin\"}";
    var payload_b64_buf: [256]u8 = undefined;
    const payload_b64 = enc.encode(&payload_b64_buf, payload_json);

    const dummy_sig = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const token = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ header_b64, payload_b64, dummy_sig });
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try env.auth.validate(token, arena.allocator());
    try std.testing.expect(res == null);
}

test "5. validate con firma incorrecta returns null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_badsig.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    const token = try env.auth.issue(a, "alice", "items:read", null);
    defer a.free(token);

    // Tamper with last signature char
    const tampered = try a.dupe(u8, token);
    defer a.free(tampered);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 'a') 'b' else 'a';

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try env.auth.validate(tampered, arena.allocator());
    try std.testing.expect(res == null);
}

test "6. validate con iss/aud incorrectos returns null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_badaud.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

    // Wrong audience
    const now = getUnixTimestamp();
    const payload = try std.fmt.allocPrint(a,
        \\{{"iss":"z-server","aud":"wrong-service","sub":"alice","jti":"12345678-1234-4234-8234-123456789abc","iat":{d},"nbf":{d},"exp":{d},"scope":"read"}}
    , .{ now, now, now + 900 });
    defer a.free(payload);

    const payload_b64_len = enc.calcSize(payload.len);
    const payload_b64 = try a.alloc(u8, payload_b64_len);
    defer a.free(payload_b64);
    _ = enc.encode(payload_b64, payload);

    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, payload_b64 });
    defer a.free(signing_input);

    var sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, signing_input, &env.auth.primary_key);
    var sig_b64: [43]u8 = undefined;
    _ = enc.encode(&sig_b64, &sig);

    const token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, &sig_b64 });
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try env.auth.validate(token, arena.allocator());
    try std.testing.expect(res == null);
}

test "7. revoke + validate returns null (jti en denylist)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_revoke.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    const token = try env.auth.issue(a, "carol", "items:read", 600);
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // First validate -> OK
    const claims = (try env.auth.validate(token, arena.allocator())) orelse return error.ValidationFailed;
    try std.testing.expectEqualStrings("carol", claims.sub);

    // Revoke token via jti
    try env.auth.revoke(claims.jti, claims.exp);

    // Second validate -> null (revoked!)
    const after_revoke = try env.auth.validate(token, arena.allocator());
    try std.testing.expect(after_revoke == null);
}

test "8. cleanup elimina jti expirados" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_cleanup.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    const now = getUnixTimestamp();
    // Revoke a token that expired in the past
    try env.auth.revoke("expired-jti-1", now - 100);
    // Revoke a token that expires in the future
    try env.auth.revoke("future-jti-2", now + 1000);

    // Run cleanup
    try env.auth.cleanup();

    var lease = try env.pool.acquire();
    defer lease.release();

    // expired-jti-1 should be deleted
    var s1 = try lease.conn.prepare("SELECT 1 FROM revoked_jwt WHERE jti = 'expired-jti-1';");
    defer s1.finalize();
    const step1 = try s1.step();
    try std.testing.expect(step1 == .done);

    // future-jti-2 should still be present
    var s2 = try lease.conn.prepare("SELECT 1 FROM revoked_jwt WHERE jti = 'future-jti-2';");
    defer s2.finalize();
    const step2 = try s2.step();
    try std.testing.expect(step2 == .row);
}

test "9. secondary secret validates older rotated tokens" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_sec_secret.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    // Issue token with secondary secret
    const sec_key = env.auth.secondary_key.?;
    const now = getUnixTimestamp();
    const payload = try std.fmt.allocPrint(a,
        \\{{"iss":"z-server","aud":"z-server-api","sub":"david","jti":"12345678-1234-4234-8234-123456789abc","iat":{d},"nbf":{d},"exp":{d},"scope":"admin"}}
    , .{ now, now, now + 900 });
    defer a.free(payload);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

    const payload_b64_len = enc.calcSize(payload.len);
    const payload_b64 = try a.alloc(u8, payload_b64_len);
    defer a.free(payload_b64);
    _ = enc.encode(payload_b64, payload);

    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, payload_b64 });
    defer a.free(signing_input);

    var sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, signing_input, &sec_key);
    var sig_b64: [43]u8 = undefined;
    _ = enc.encode(&sig_b64, &sig);

    const token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, &sig_b64 });
    defer a.free(token);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Validates successfully via secondary_key!
    const res = (try env.auth.validate(token, arena.allocator())) orelse return error.ValidationFailed;
    try std.testing.expectEqualStrings("david", res.sub);
}

test "10. refresh token create + validate + revoke" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const db_path = "/tmp/test_jwt_refresh.db";
    defer cleanupDbFiles(io, db_path);

    var env = try setupTestEnv(a, io, db_path);
    defer env.deinit(a);

    try z_server_jwt.initRefreshSchema(&env.pool);

    const refresh_res = try z_server_jwt.createRefreshToken(a, io, &env.pool, &env.auth.primary_key, "user123", "items:read items:write");
    try std.testing.expectEqual(@as(usize, 43), refresh_res.plaintext().len);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Validate refresh token -> OK
    const claims = (try z_server_jwt.validateRefreshToken(arena.allocator(), &env.pool, &env.auth.primary_key, refresh_res.plaintext())) orelse return error.ValidationFailed;
    try std.testing.expectEqualStrings("user123", claims.sub);
    try std.testing.expectEqualStrings("items:read items:write", claims.scopes);

    // Revoke refresh token
    try z_server_jwt.revokeRefreshToken(&env.pool, &env.auth.primary_key, refresh_res.plaintext());

    // Validate again -> null
    const after_revoke = try z_server_jwt.validateRefreshToken(arena.allocator(), &env.pool, &env.auth.primary_key, refresh_res.plaintext());
    try std.testing.expect(after_revoke == null);
}
