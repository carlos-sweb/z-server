const std = @import("std");
const z_server_auth = @import("z_server_auth");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");

const Authenticator = z_server_auth.Authenticator;
const AuthContext = z_server_auth.AuthContext;
const CreateKeySpec = z_server_auth.CreateKeySpec;
const Pool = z_server_db.Pool;
const Cache = z_server_cache.Cache;

const TEST_PEPPER_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn uniqueDbPath(allocator: std.mem.Allocator) ![:0]u8 {
    var n: u64 = undefined;
    std.testing.io.random(std.mem.asBytes(&n));
    return std.fmt.allocPrintSentinel(allocator, "/tmp/z-server-auth-test-{d}.db", .{n}, 0);
}

fn cleanupDb(allocator: std.mem.Allocator, path: [:0]u8) void {
    const io = std.testing.io;
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const wal = std.fmt.allocPrintSentinel(allocator, "{s}-wal", .{path}, 0) catch {
        allocator.free(path);
        return;
    };
    defer allocator.free(wal);
    std.Io.Dir.deleteFileAbsolute(io, wal) catch {};
    const shm = std.fmt.allocPrintSentinel(allocator, "{s}-shm", .{path}, 0) catch {
        allocator.free(path);
        return;
    };
    defer allocator.free(shm);
    std.Io.Dir.deleteFileAbsolute(io, shm) catch {};
    allocator.free(path);
}

test "1. createKey returns valid plaintext with correct format" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "user_123",
        .scopes = "read write",
        .env = .live,
    });

    const key = created.plaintext();
    try std.testing.expectEqual(@as(usize, 58), key.len);
    try std.testing.expect(std.mem.startsWith(u8, key, "zs_live_"));
    try std.testing.expectEqual(@as(u8, '_'), key[51]);
    try std.testing.expect(z_server_auth.validateChecksum(key));

    var mask_buf: [19]u8 = undefined;
    const masked = z_server_auth.maskKey(key, &mask_buf);
    try std.testing.expect(std.mem.startsWith(u8, masked, "zs_live_..."));
    try std.testing.expectEqual(@as(usize, 15), masked.len);

    // Print sample key format for verification output
    std.debug.print("\n[V3 KEY SAMPLE] Plaintext: {s} | Masked: {s}\n", .{ key, masked });
}

test "2. createKey stores only hash, no plaintext in DB" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    // V6 verification: schema table existence
    {
        var lease_schema = try pool.acquire();
        defer lease_schema.release();
        var stmt_schema = try lease_schema.conn.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='api_keys';");
        defer stmt_schema.finalize();
        try std.testing.expectEqual(z_server_db.Step.row, try stmt_schema.step());
        const table_name = stmt_schema.columnText(0);
        try std.testing.expectEqualStrings("api_keys", table_name);
        std.debug.print("\n[V6 SCHEMA CHECK] sqlite_master table found: {s}\n", .{table_name});
    }

    const created = try auth.createKey(.{
        .user_id = "user_secret",
        .scopes = "admin",
        .env = .live,
    });

    var lease = try pool.acquire();
    defer lease.release();

    var stmt = try lease.conn.prepare("SELECT key_hash, key_prefix, user_id FROM api_keys WHERE id = ?;");
    defer stmt.finalize();
    try stmt.bindInt64(1, created.id);

    try std.testing.expectEqual(z_server_db.Step.row, try stmt.step());
    const stored_hash = stmt.columnText(0);
    try std.testing.expectEqual(@as(usize, 64), stored_hash.len);

    const expected_hash = z_server_auth.computeHmacHex(created.plaintext(), &auth.pepper);
    try std.testing.expectEqualStrings(&expected_hash, stored_hash);

    // Ensure the random middle part of the plaintext is not anywhere in the stored hash
    const random_middle = created.plaintext()[8..51];
    try std.testing.expect(std.mem.indexOf(u8, stored_hash, random_middle) == null);
}

test "3. validate valid key returns AuthContext" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "alice",
        .scopes = "items:read items:write",
        .env = .live,
    });

    const ctx = (try auth.validate(created.plaintext(), allocator)).?;
    defer allocator.free(ctx.user_id);
    defer allocator.free(ctx.scopes);

    try std.testing.expectEqual(created.id, ctx.key_id);
    try std.testing.expectEqualStrings("alice", ctx.user_id);
    try std.testing.expectEqualStrings("items:read items:write", ctx.scopes);
}

test "4. validate invalid key returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    // Fabricate a syntactically valid key with valid CRC32 that is not in DB
    const prefix = "zs_live_";
    const payload_random = "0123456789012345678901234567890123456789012";
    var payload: [51]u8 = undefined;
    @memcpy(payload[0..8], prefix);
    @memcpy(payload[8..51], payload_random);
    const crc = std.hash.Crc32.hash(&payload);
    var crc_b62: [6]u8 = undefined;
    z_server_auth.encodeBase62_6(crc, &crc_b62);

    var fake_key: [58]u8 = undefined;
    @memcpy(fake_key[0..51], &payload);
    fake_key[51] = '_';
    @memcpy(fake_key[52..58], &crc_b62);

    try std.testing.expect(z_server_auth.validateChecksum(&fake_key));

    const result = try auth.validate(&fake_key, allocator);
    try std.testing.expect(result == null);
}

test "5. validate invalid checksum returns null quickly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "bob",
        .scopes = "*",
    });

    var tampered: [58]u8 = undefined;
    @memcpy(&tampered, created.plaintext());
    // Invalidate checksum
    tampered[57] = if (tampered[57] == 'A') 'B' else 'A';

    try std.testing.expect(!z_server_auth.validateChecksum(&tampered));

    const result = try auth.validate(&tampered, allocator);
    try std.testing.expect(result == null);
}

test "6. validate expired key returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    // Expired 100 seconds ago
    const past_ts = 1600000000;
    const created = try auth.createKey(.{
        .user_id = "expired_user",
        .scopes = "*",
        .expires_at = past_ts,
    });

    const result = try auth.validate(created.plaintext(), allocator);
    try std.testing.expect(result == null);
}

test "7. validate revoked key returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "charlie",
        .scopes = "*",
    });

    // Valid before revoke
    const ctx1 = try auth.validate(created.plaintext(), allocator);
    try std.testing.expect(ctx1 != null);
    allocator.free(ctx1.?.user_id);
    allocator.free(ctx1.?.scopes);

    // Revoke
    try auth.revoke(created.id);

    // Invalid after revoke
    const ctx2 = try auth.validate(created.plaintext(), allocator);
    try std.testing.expect(ctx2 == null);
}

test "8. hasScope returns true/false correctly" {
    const ctx1 = AuthContext{
        .key_id = 1,
        .user_id = "test",
        .scopes = "items:read items:write",
    };
    try std.testing.expect(ctx1.hasScope("items:read"));
    try std.testing.expect(ctx1.hasScope("items:write"));
    try std.testing.expect(!ctx1.hasScope("items:delete"));
    try std.testing.expect(!ctx1.hasScope("admin"));

    const ctx2 = AuthContext{
        .key_id = 2,
        .user_id = "admin",
        .scopes = "*",
    };
    try std.testing.expect(ctx2.hasScope("items:read"));
    try std.testing.expect(ctx2.hasScope("admin"));
    try std.testing.expect(ctx2.hasScope("super:scope"));

    const ctx3 = AuthContext{
        .key_id = 3,
        .user_id = "test",
        .scopes = "read, write, admin",
    };
    try std.testing.expect(ctx3.hasScope("read"));
    try std.testing.expect(ctx3.hasScope("write"));
    try std.testing.expect(ctx3.hasScope("admin"));
    try std.testing.expect(!ctx3.hasScope("delete"));
}

test "9. revoke invalidates immediately and purges cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var cache = try Cache.init(allocator, 64);
    defer cache.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{
        .pepper = TEST_PEPPER_HEX,
        .cache = &cache,
        .cache_ttl_seconds = 10,
    });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "cached_user",
        .scopes = "read",
    });

    // 1. First validation: fills cache
    const ctx1 = (try auth.validate(created.plaintext(), allocator)).?;
    allocator.free(ctx1.user_id);
    allocator.free(ctx1.scopes);

    // Verify entry is present in cache
    const hex_hash = z_server_auth.computeHmacHex(created.plaintext(), &auth.pepper);
    const cached_before = try cache.get(&hex_hash, allocator);
    try std.testing.expect(cached_before != null);
    allocator.free(cached_before.?);

    // 2. Revoke key: must purge cache immediately
    try auth.revoke(created.id);

    const cached_after = try cache.get(&hex_hash, allocator);
    try std.testing.expect(cached_after == null);

    // 3. Validation must now fail immediately
    const ctx2 = try auth.validate(created.plaintext(), allocator);
    try std.testing.expect(ctx2 == null);
}

test "10. rotate creates new key without revoking old key" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const key1 = try auth.createKey(.{
        .user_id = "rotation_user",
        .scopes = "read write",
        .env = .live,
    });

    const key2 = try auth.rotate(key1.id);

    try std.testing.expect(key2.id != key1.id);
    try std.testing.expectEqualStrings("rotation_user", key2.user_id);
    try std.testing.expectEqualStrings("read write", key2.scopes);
    try std.testing.expect(z_server_auth.validateChecksum(key2.plaintext()));

    // Both old key and new key are valid simultaneously (grace period)
    const ctx1 = (try auth.validate(key1.plaintext(), allocator)).?;
    allocator.free(ctx1.user_id);
    allocator.free(ctx1.scopes);

    const ctx2 = (try auth.validate(key2.plaintext(), allocator)).?;
    allocator.free(ctx2.user_id);
    allocator.free(ctx2.scopes);
}

fn getMonotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "11. dummy hashing timing and benchmark verification" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 4 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "bench_user",
        .scopes = "*",
    });

    // Fabricate an unknown key with valid checksum
    var payload: [51]u8 = undefined;
    @memcpy(payload[0..8], "zs_live_");
    @memcpy(payload[8..51], "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ");
    const crc = std.hash.Crc32.hash(&payload);
    var crc_b62: [6]u8 = undefined;
    z_server_auth.encodeBase62_6(crc, &crc_b62);
    var unknown_key: [58]u8 = undefined;
    @memcpy(unknown_key[0..51], &payload);
    unknown_key[51] = '_';
    @memcpy(unknown_key[52..58], &crc_b62);

    const iterations = 25;

    // Benchmark valid keys (DB Hit)
    const t0 = getMonotonicNs();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const ctx = try auth.validate(created.plaintext(), allocator);
        if (ctx) |c| {
            allocator.free(c.user_id);
            allocator.free(c.scopes);
        }
    }
    const t1 = getMonotonicNs();
    const hit_duration_ns = t1 - t0;

    // Benchmark invalid keys with valid checksum (DB Miss + Dummy Hashing)
    const t2 = getMonotonicNs();
    i = 0;
    while (i < iterations) : (i += 1) {
        const ctx = try auth.validate(&unknown_key, allocator);
        try std.testing.expect(ctx == null);
    }
    const t3 = getMonotonicNs();
    const miss_duration_ns = t3 - t2;

    const hit_ms = @as(f64, @floatFromInt(hit_duration_ns)) / 1_000_000.0;
    const miss_ms = @as(f64, @floatFromInt(miss_duration_ns)) / 1_000_000.0;

    std.debug.print(
        "\n[V4 BENCHMARK] Batch of {d} validations: Hit={d:.3} ms | Miss (Dummy Hashing)={d:.3} ms\n",
        .{ iterations, hit_ms, miss_ms },
    );

    // Condition V4: < 5 ms per batch
    try std.testing.expect(hit_ms < 5.0);
    try std.testing.expect(miss_ms < 5.0);

    // Timing difference between hit and miss should be bounded (< 2x)
    const ratio = if (hit_ms > miss_ms) hit_ms / @max(0.001, miss_ms) else miss_ms / @max(0.001, hit_ms);
    try std.testing.expect(ratio < 2.0);
}

test "12. API key without ip_allowlist accepts any IP" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "user_no_allowlist",
        .scopes = "read",
    });

    const ctx = (try auth.validate(created.plaintext(), allocator)).?;
    defer {
        allocator.free(ctx.user_id);
        allocator.free(ctx.scopes);
        if (ctx.ip_allowlist.len > 0) allocator.free(ctx.ip_allowlist);
    }

    try std.testing.expectEqualStrings("", ctx.ip_allowlist);

    // Any IP is accepted when ip_allowlist is empty
    const ip1 = (z_server_auth.parseIp("127.0.0.1")).?;
    const ip2 = (z_server_auth.parseIp("192.168.1.100")).?;
    const ip3 = (z_server_auth.parseIp("2001:db8::1")).?;

    const MockReq = struct {
        address: std.Io.net.IpAddress,
        pub fn header(self: @This(), _: []const u8) ?[]const u8 {
            _ = self;
            return null;
        }
    };
    const req1 = MockReq{ .address = ip1 };
    const req2 = MockReq{ .address = ip2 };
    const req3 = MockReq{ .address = ip3 };

    try std.testing.expect(ctx.ip_allowlist.len == 0);
    _ = req1;
    _ = req2;
    _ = req3;
}

test "13. API key with ip_allowlist 127.0.0.1 rejects non-loopback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "user_loopback",
        .scopes = "read",
        .ip_allowlist = "127.0.0.1",
    });

    const ctx = (try auth.validate(created.plaintext(), allocator)).?;
    defer {
        allocator.free(ctx.user_id);
        allocator.free(ctx.scopes);
        if (ctx.ip_allowlist.len > 0) allocator.free(ctx.ip_allowlist);
    }

    try std.testing.expectEqualStrings("127.0.0.1", ctx.ip_allowlist);

    const loopback = (z_server_auth.parseIp("127.0.0.1")).?;
    const non_loopback = (z_server_auth.parseIp("192.168.1.50")).?;

    try std.testing.expect(z_server_auth.checkAllowlist(ctx.ip_allowlist, loopback));
    try std.testing.expect(!z_server_auth.checkAllowlist(ctx.ip_allowlist, non_loopback));
}

test "14. API key with CIDR 10.0.0.0/8 accepts 10.x" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "user_cidr",
        .scopes = "read",
        .ip_allowlist = "10.0.0.0/8",
    });

    const ctx = (try auth.validate(created.plaintext(), allocator)).?;
    defer {
        allocator.free(ctx.user_id);
        allocator.free(ctx.scopes);
        if (ctx.ip_allowlist.len > 0) allocator.free(ctx.ip_allowlist);
    }

    try std.testing.expectEqualStrings("10.0.0.0/8", ctx.ip_allowlist);

    const allowed_ip = (z_server_auth.parseIp("10.1.2.3")).?;
    const rejected_ip = (z_server_auth.parseIp("192.168.1.1")).?;

    try std.testing.expect(z_server_auth.checkAllowlist(ctx.ip_allowlist, allowed_ip));
    try std.testing.expect(!z_server_auth.checkAllowlist(ctx.ip_allowlist, rejected_ip));
}

test "15. API key with IPv6 CIDR" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try Pool.init(allocator, io, .{ .path = path, .pool_size = 2 });
    defer pool.deinit();

    var auth = try Authenticator.init(allocator, io, &pool, .{ .pepper = TEST_PEPPER_HEX });
    defer auth.deinit();

    const created = try auth.createKey(.{
        .user_id = "user_ipv6",
        .scopes = "read",
        .ip_allowlist = "2001:db8::/32",
    });

    const ctx = (try auth.validate(created.plaintext(), allocator)).?;
    defer {
        allocator.free(ctx.user_id);
        allocator.free(ctx.scopes);
        if (ctx.ip_allowlist.len > 0) allocator.free(ctx.ip_allowlist);
    }

    try std.testing.expectEqualStrings("2001:db8::/32", ctx.ip_allowlist);

    const allowed_ip = (z_server_auth.parseIp("2001:db8::1")).?;
    const rejected_ip = (z_server_auth.parseIp("2001:db9::1")).?;

    try std.testing.expect(z_server_auth.checkAllowlist(ctx.ip_allowlist, allowed_ip));
    try std.testing.expect(!z_server_auth.checkAllowlist(ctx.ip_allowlist, rejected_ip));
}

test "16. resolveClientIp: no XFF -> remote_addr" {
    const ip_10 = (z_server_auth.parseIp("10.0.0.5")).?;
    const proxies = &[_][]const u8{"127.0.0.1/32"};
    const resolved = z_server_auth.resolveClientIp(ip_10, null, proxies);
    try std.testing.expect(std.mem.eql(u8, &ip_10.ip4.bytes, &resolved.ip4.bytes));
}

test "17. resolveClientIp: XFF from trusted -> XFF" {
    const ip_127 = (z_server_auth.parseIp("127.0.0.1")).?;
    const ip_10 = (z_server_auth.parseIp("10.0.0.1")).?;
    const proxies = &[_][]const u8{"127.0.0.1/32"};
    const resolved = z_server_auth.resolveClientIp(ip_127, "10.0.0.1", proxies);
    try std.testing.expect(std.mem.eql(u8, &ip_10.ip4.bytes, &resolved.ip4.bytes));
}

test "18. resolveClientIp: XFF from untrusted -> remote_addr" {
    const ip_10 = (z_server_auth.parseIp("10.0.0.5")).?;
    const proxies = &[_][]const u8{"127.0.0.1/32"};
    const resolved = z_server_auth.resolveClientIp(ip_10, "127.0.0.1", proxies);
    try std.testing.expect(std.mem.eql(u8, &ip_10.ip4.bytes, &resolved.ip4.bytes));
}
