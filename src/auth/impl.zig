const std = @import("std");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const lib = @import("lib.zig");

pub const KEY_LEN = 58;
pub const PREFIX_LEN = 8;
pub const RANDOM_RAW_LEN = 32;
pub const RANDOM_B64_LEN = 43;
pub const PAYLOAD_LEN = 51;
pub const CHECKSUM_LEN = 6;
pub const HASH_HEX_LEN = 64;

const B62_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub const Environment = enum {
    live,
    test_env,
};

pub const CreateKeySpec = struct {
    user_id: []const u8,
    scopes: []const u8 = "*",
    env: Environment = .live,
    expires_at: ?i64 = null,
    ip_allowlist: ?[]const u8 = null,
};

pub const CreatedKey = struct {
    id: i64,
    key: [KEY_LEN]u8,
    user_id: []const u8,
    scopes: []const u8,
    prefix: [PREFIX_LEN]u8,
    created_at: i64,
    expires_at: ?i64,
    ip_allowlist: ?[]const u8 = null,

    pub fn plaintext(self: *const CreatedKey) []const u8 {
        return &self.key;
    }
};

pub const AuthContext = struct {
    key_id: i64,
    user_id: []const u8,
    scopes: []const u8,
    ip_allowlist: []const u8 = "",

    pub fn hasScope(self: AuthContext, required: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, self.scopes, " ,");
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "*") or std.mem.eql(u8, token, required)) {
                return true;
            }
        }
        return false;
    }
};

pub const KeyInfo = struct {
    id: i64,
    key_prefix: []const u8,
    user_id: []const u8,
    scopes: []const u8,
    created_at: i64,
    expires_at: ?i64,
    last_used_at: ?i64,
    revoked: bool,
    ip_allowlist: ?[]const u8 = null,
};

pub const Options = struct {
    pepper: ?[]const u8 = null,
    cache: ?*z_server_cache.Cache = null,
    cache_ttl_seconds: u32 = 10,
    throttle_seconds: u32 = 60,
    require_https: bool = false,
    allow_x_api_key: bool = true,
    trusted_proxies: ?[]const u8 = null,
};

pub const AuthError = error{
    MissingPepper,
    InvalidPepper,
    KeyNotFound,
    KeyRevoked,
    DatabaseError,
    PoolClosed,
    PoolTimeout,
    OutOfMemory,
};

const CachedAuth = struct {
    id: i64,
    user_id: []const u8,
    scopes: []const u8,
    expires_at: ?i64 = null,
    ip_allowlist: []const u8 = "",
};

pub fn encodeBase62_6(val: u32, out: *[6]u8) void {
    var v = val;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        out[i] = B62_ALPHABET[v % 62];
        v /= 62;
    }
}

pub fn decodeBase62_6(buf: *const [6]u8) ?u32 {
    var v: u64 = 0;
    for (buf) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'A'...'Z' => c - 'A' + 10,
            'a'...'z' => c - 'a' + 36,
            else => return null,
        };
        v = v * 62 + digit;
        if (v > std.math.maxInt(u32)) return null;
    }
    return @intCast(v);
}

pub fn parsePepper(spec: ?[]const u8) !([32]u8) {
    const raw = blk: {
        if (spec) |s| break :blk s;
        if (std.c.getenv("Z_SERVER_AUTH_PEPPER")) |ptr| {
            break :blk std.mem.span(ptr);
        }
        return error.MissingPepper;
    };

    const trimmed = std.mem.trim(u8, raw, " \r\n\t");

    var pepper: [32]u8 = undefined;
    if (trimmed.len == 64) {
        _ = std.fmt.hexToBytes(&pepper, trimmed) catch return error.InvalidPepper;
        return pepper;
    } else if (trimmed.len == 44) {
        _ = std.base64.standard.Decoder.decode(&pepper, trimmed) catch return error.InvalidPepper;
        return pepper;
    } else if (trimmed.len == 43) {
        _ = std.base64.url_safe_no_pad.Decoder.decode(&pepper, trimmed) catch return error.InvalidPepper;
        return pepper;
    }
    return error.InvalidPepper;
}

pub fn validateChecksum(key: []const u8) bool {
    if (key.len != KEY_LEN) return false;
    if (!std.mem.startsWith(u8, key, "zs_live_") and !std.mem.startsWith(u8, key, "zs_test_")) return false;
    if (key[PAYLOAD_LEN] != '_') return false;

    const payload = key[0..PAYLOAD_LEN];
    const ck_str: *const [6]u8 = key[PAYLOAD_LEN + 1 .. KEY_LEN];
    const expected_crc = decodeBase62_6(ck_str) orelse return false;
    const computed_crc = std.hash.Crc32.hash(payload);
    return computed_crc == expected_crc;
}

pub fn computeHmacHex(key: []const u8, pepper: *const [32]u8) [64]u8 {
    var hmac_out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_out, key, pepper);
    return std.fmt.bytesToHex(hmac_out, .lower);
}

pub fn maskKey(key: []const u8, out: *[19]u8) []const u8 {
    if (key.len < 12) {
        const n = @min(key.len, out.len);
        @memcpy(out[0..n], key[0..n]);
        return out[0..n];
    }
    const prefix_len: usize = if (std.mem.startsWith(u8, key, "zs_live_") or std.mem.startsWith(u8, key, "zs_test_"))
        8
    else
        @min(@as(usize, 8), key.len - 4);

    @memcpy(out[0..prefix_len], key[0..prefix_len]);
    @memcpy(out[prefix_len .. prefix_len + 3], "...");
    const suffix = key[key.len - 4 .. key.len];
    @memcpy(out[prefix_len + 3 .. prefix_len + 7], suffix);
    return out[0 .. prefix_len + 7];
}

pub fn secureZero(buf: []u8) void {
    std.crypto.secureZero(u8, buf);
}

fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *z_server_db.Pool,
    cache: ?*z_server_cache.Cache,
    pepper: [32]u8,
    options: Options,
    throttle_map: std.AutoHashMap(i64, i64),
    throttle_mutex: std.Io.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        db: *z_server_db.Pool,
        options: Options,
    ) !Authenticator {
        const pepper = try parsePepper(options.pepper);

        // Migrate DB
        try migrateDb(db);

        return Authenticator{
            .allocator = allocator,
            .io = io,
            .db = db,
            .cache = options.cache,
            .pepper = pepper,
            .options = options,
            .throttle_map = std.AutoHashMap(i64, i64).init(allocator),
            .throttle_mutex = .init,
        };
    }

    pub fn deinit(self: *Authenticator) void {
        self.throttle_map.deinit();
        self.* = undefined;
    }

    fn migrateDb(db: *z_server_db.Pool) !void {
        var lease = try db.acquire();
        defer lease.release();

        try lease.conn.exec(
            \\CREATE TABLE IF NOT EXISTS api_keys (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    key_hash TEXT NOT NULL UNIQUE,
            \\    key_prefix TEXT NOT NULL,
            \\    user_id TEXT NOT NULL,
            \\    scopes TEXT NOT NULL,
            \\    created_at INTEGER NOT NULL,
            \\    expires_at INTEGER,
            \\    last_used_at INTEGER,
            \\    revoked INTEGER NOT NULL DEFAULT 0,
            \\    ip_allowlist TEXT
            \\);
        );
        try lease.conn.exec("CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);");
        try lease.conn.exec("CREATE INDEX IF NOT EXISTS idx_api_keys_user ON api_keys(user_id);");

        // Check if ip_allowlist column exists (migration for existing tables)
        var has_ip_allowlist = false;
        var stmt = try lease.conn.prepare("PRAGMA table_info(api_keys);");
        defer stmt.finalize();
        while ((try stmt.step()) == .row) {
            const col_name = stmt.columnText(1);
            if (std.mem.eql(u8, col_name, "ip_allowlist")) {
                has_ip_allowlist = true;
                break;
            }
        }
        if (!has_ip_allowlist) {
            try lease.conn.exec("ALTER TABLE api_keys ADD COLUMN ip_allowlist TEXT;");
        }
    }

    fn updateLastUsed(self: *Authenticator, key_id: i64, now: i64) void {
        var should_update = false;
        {
            self.throttle_mutex.lockUncancelable(self.io);
            defer self.throttle_mutex.unlock(self.io);
            const last = self.throttle_map.get(key_id) orelse 0;
            if (now - last >= self.options.throttle_seconds) {
                self.throttle_map.put(key_id, now) catch return;
                should_update = true;
            }
        }
        if (should_update) {
            var lease = self.db.acquire() catch return;
            defer lease.release();
            var stmt = lease.conn.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?;") catch return;
            defer stmt.finalize();
            stmt.bindInt64(1, now) catch return;
            stmt.bindInt64(2, key_id) catch return;
            _ = stmt.step() catch return;
        }
    }

    pub fn createKey(self: *Authenticator, spec: CreateKeySpec) !CreatedKey {
        const prefix: *const [PREFIX_LEN]u8 = switch (spec.env) {
            .live => "zs_live_",
            .test_env => "zs_test_",
        };

        var rand_raw: [RANDOM_RAW_LEN]u8 = undefined;
        self.io.random(&rand_raw);
        defer std.crypto.secureZero(u8, &rand_raw);

        var rand_b64: [RANDOM_B64_LEN]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&rand_b64, &rand_raw);

        var payload: [PAYLOAD_LEN]u8 = undefined;
        @memcpy(payload[0..PREFIX_LEN], prefix);
        @memcpy(payload[PREFIX_LEN..PAYLOAD_LEN], &rand_b64);

        const crc = std.hash.Crc32.hash(&payload);
        var crc_b62: [CHECKSUM_LEN]u8 = undefined;
        encodeBase62_6(crc, &crc_b62);

        var full_key: [KEY_LEN]u8 = undefined;
        @memcpy(full_key[0..PAYLOAD_LEN], &payload);
        full_key[PAYLOAD_LEN] = '_';
        @memcpy(full_key[PAYLOAD_LEN + 1 .. KEY_LEN], &crc_b62);

        const hex_hash = computeHmacHex(&full_key, &self.pepper);
        const now = getUnixTimestamp();

        var lease = try self.db.acquire();
        defer lease.release();

        var stmt = try lease.conn.prepare(
            "INSERT INTO api_keys (key_hash, key_prefix, user_id, scopes, created_at, expires_at, revoked, ip_allowlist) VALUES (?, ?, ?, ?, ?, ?, 0, ?);"
        );
        defer stmt.finalize();

        try stmt.bindText(1, &hex_hash);
        try stmt.bindText(2, prefix);
        try stmt.bindText(3, spec.user_id);
        try stmt.bindText(4, spec.scopes);
        try stmt.bindInt64(5, now);
        if (spec.expires_at) |exp| {
            try stmt.bindInt64(6, exp);
        } else {
            try stmt.bindNull(6);
        }
        if (spec.ip_allowlist) |al| {
            try stmt.bindText(7, al);
        } else {
            try stmt.bindNull(7);
        }

        _ = try stmt.step();
        const id = lease.conn.lastInsertRowid();

        return CreatedKey{
            .id = id,
            .key = full_key,
            .user_id = spec.user_id,
            .scopes = spec.scopes,
            .prefix = prefix.*,
            .created_at = now,
            .expires_at = spec.expires_at,
            .ip_allowlist = spec.ip_allowlist,
        };
    }

    pub fn validate(
        self: *Authenticator,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) !?AuthContext {
        // 1. Fast checksum validation
        if (!validateChecksum(key)) {
            _ = lib.metrics.invalid_key.fetchAdd(1, .monotonic);
            return null;
        }

        // 2. Compute HMAC-SHA256
        var hmac_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_bytes, key, &self.pepper);
        const hex_hash = std.fmt.bytesToHex(hmac_bytes, .lower);

        // 3. Optional Pogocache lookup
        if (self.cache) |cache| {
            if (cache.get(&hex_hash, allocator) catch null) |cached_json| {
                defer allocator.free(cached_json);
                if (std.json.parseFromSlice(CachedAuth, allocator, cached_json, .{})) |parsed| {
                    defer parsed.deinit();
                    const now = getUnixTimestamp();
                    if (parsed.value.expires_at) |exp| {
                        if (now >= exp) {
                            _ = lib.metrics.expired.fetchAdd(1, .monotonic);
                            return null;
                        }
                    }
                    self.updateLastUsed(parsed.value.id, now);
                    return AuthContext{
                        .key_id = parsed.value.id,
                        .user_id = try allocator.dupe(u8, parsed.value.user_id),
                        .scopes = try allocator.dupe(u8, parsed.value.scopes),
                        .ip_allowlist = if (parsed.value.ip_allowlist.len > 0) try allocator.dupe(u8, parsed.value.ip_allowlist) else "",
                    };
                } else |_| {}
            }
        }

        // 4. SQLite lookup
        var lease = try self.db.acquire();
        defer lease.release();

        var stmt = try lease.conn.prepare(
            "SELECT id, user_id, scopes, expires_at, revoked, key_hash, ip_allowlist FROM api_keys WHERE key_hash = ? LIMIT 1;"
        );
        defer stmt.finalize();
        try stmt.bindText(1, &hex_hash);

        if ((try stmt.step()) == .row) {
            const stored_hash = stmt.columnText(5);
            var stored_bytes: [32]u8 = undefined;
            var valid_match = false;
            if (stored_hash.len == 64) {
                if (std.fmt.hexToBytes(&stored_bytes, stored_hash)) |_| {
                    valid_match = std.crypto.timing_safe.eql([32]u8, hmac_bytes, stored_bytes);
                } else |_| {}
            }
            if (!valid_match) {
                _ = lib.metrics.invalid_key.fetchAdd(1, .monotonic);
                return null;
            }

            const revoked = stmt.columnInt64(4) != 0;
            if (revoked) {
                _ = lib.metrics.revoked.fetchAdd(1, .monotonic);
                return null;
            }

            const key_id = stmt.columnInt64(0);
            const expires_at: ?i64 = if (stmt.columnBytes(3) > 0) stmt.columnInt64(3) else null;
            const now = getUnixTimestamp();
            if (expires_at) |exp| {
                if (now >= exp) {
                    _ = lib.metrics.expired.fetchAdd(1, .monotonic);
                    return null;
                }
            }

            const user_id = try stmt.copyText(1, allocator);
            errdefer allocator.free(user_id);
            const scopes = try stmt.copyText(2, allocator);
            errdefer allocator.free(scopes);
            const ip_allowlist = if (stmt.columnBytes(6) > 0) try stmt.copyText(6, allocator) else "";
            errdefer if (stmt.columnBytes(6) > 0) allocator.free(ip_allowlist);

            // Store in cache
            if (self.cache) |cache| {
                const cached_auth = CachedAuth{
                    .id = key_id,
                    .user_id = user_id,
                    .scopes = scopes,
                    .expires_at = expires_at,
                    .ip_allowlist = ip_allowlist,
                };
                if (std.json.Stringify.valueAlloc(allocator, cached_auth, .{})) |c_json| {
                    defer allocator.free(c_json);
                    cache.set(&hex_hash, c_json, self.options.cache_ttl_seconds) catch {};
                } else |_| {}
            }

            self.updateLastUsed(key_id, now);

            return AuthContext{
                .key_id = key_id,
                .user_id = user_id,
                .scopes = scopes,
                .ip_allowlist = ip_allowlist,
            };
        } else {
            // Dummy hashing on lookup failure to prevent timing enumeration (Decision 8 & CVE-2026-23996)
            var dummy_hash: [32]u8 = undefined;
            const dummy_salt = "dummy_timing_mitigation_cve_2026_23996_padding_bytes";
            std.crypto.auth.hmac.sha2.HmacSha256.create(&dummy_hash, dummy_salt, &self.pepper);
            _ = std.crypto.timing_safe.eql([32]u8, hmac_bytes, dummy_hash);
            _ = lib.metrics.invalid_key.fetchAdd(1, .monotonic);
            return null;
        }
    }

    pub fn revoke(self: *Authenticator, key_id: i64) !void {
        var lease = try self.db.acquire();
        defer lease.release();

        if (self.cache) |cache| {
            var stmt_find = try lease.conn.prepare("SELECT key_hash FROM api_keys WHERE id = ? LIMIT 1;");
            defer stmt_find.finalize();
            try stmt_find.bindInt64(1, key_id);
            if ((try stmt_find.step()) == .row) {
                const hash = stmt_find.columnText(0);
                cache.delete(hash) catch {};
            }
        }

        var stmt = try lease.conn.prepare("UPDATE api_keys SET revoked = 1 WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindInt64(1, key_id);
        _ = try stmt.step();
    }

    pub fn rotate(self: *Authenticator, key_id: i64) !CreatedKey {
        var user_id_buf: [256]u8 = undefined;
        var user_id_len: usize = 0;
        var scopes_buf: [512]u8 = undefined;
        var scopes_len: usize = 0;
        var env: Environment = .live;

        {
            var lease = try self.db.acquire();
            defer lease.release();

            var stmt = try lease.conn.prepare(
                "SELECT user_id, scopes, key_prefix FROM api_keys WHERE id = ? AND revoked = 0 LIMIT 1;"
            );
            defer stmt.finalize();
            try stmt.bindInt64(1, key_id);

            if ((try stmt.step()) != .row) {
                return error.KeyNotFound;
            }

            const u_raw = stmt.columnText(0);
            if (u_raw.len > user_id_buf.len) return error.OutOfMemory;
            @memcpy(user_id_buf[0..u_raw.len], u_raw);
            user_id_len = u_raw.len;

            const s_raw = stmt.columnText(1);
            if (s_raw.len > scopes_buf.len) return error.OutOfMemory;
            @memcpy(scopes_buf[0..s_raw.len], s_raw);
            scopes_len = s_raw.len;

            const prefix = stmt.columnText(2);
            env = if (std.mem.startsWith(u8, prefix, "zs_test")) .test_env else .live;
        }

        return try self.createKey(.{
            .user_id = user_id_buf[0..user_id_len],
            .scopes = scopes_buf[0..scopes_len],
            .env = env,
        });
    }

    pub fn listKeys(
        self: *Authenticator,
        user_id: []const u8,
        allocator: std.mem.Allocator,
    ) ![]KeyInfo {
        var lease = try self.db.acquire();
        defer lease.release();

        var stmt = try lease.conn.prepare(
            "SELECT id, key_prefix, user_id, scopes, created_at, expires_at, last_used_at, revoked, ip_allowlist FROM api_keys WHERE user_id = ? ORDER BY id DESC;"
        );
        defer stmt.finalize();
        try stmt.bindText(1, user_id);

        var list = std.ArrayList(KeyInfo).init(allocator);
        errdefer {
            for (list.items) |item| {
                allocator.free(item.user_id);
                allocator.free(item.scopes);
                allocator.free(item.key_prefix);
                if (item.ip_allowlist) |al| allocator.free(al);
            }
            list.deinit();
        }

        while ((try stmt.step()) == .row) {
            const p_raw = try stmt.copyText(1, allocator);
            errdefer allocator.free(p_raw);
            const u_id = try stmt.copyText(2, allocator);
            errdefer allocator.free(u_id);
            const sc = try stmt.copyText(3, allocator);
            errdefer allocator.free(sc);
            const al = if (stmt.columnBytes(8) > 0) try stmt.copyText(8, allocator) else null;
            errdefer if (al) |a| allocator.free(a);

            try list.append(.{
                .id = stmt.columnInt64(0),
                .key_prefix = p_raw,
                .user_id = u_id,
                .scopes = sc,
                .created_at = stmt.columnInt64(4),
                .expires_at = if (stmt.columnBytes(5) > 0) stmt.columnInt64(5) else null,
                .last_used_at = if (stmt.columnBytes(6) > 0) stmt.columnInt64(6) else null,
                .revoked = stmt.columnInt64(7) != 0,
                .ip_allowlist = al,
            });
        }

        return list.toOwnedSlice();
    }
};

pub fn parseIp(str: []const u8) ?std.Io.net.IpAddress {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '[') {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
        const inner = trimmed[1..close];
        return if (std.Io.net.Ip6Address.parse(inner, 0)) |ip6| .{ .ip6 = ip6 } else |_| null;
    }
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, ':') == colon) {
            const host = trimmed[0..colon];
            return if (std.Io.net.Ip4Address.parse(host, 0)) |ip4| .{ .ip4 = ip4 } else |_| null;
        }
        return if (std.Io.net.Ip6Address.parse(trimmed, 0)) |ip6| .{ .ip6 = ip6 } else |_| null;
    }
    return if (std.Io.net.Ip4Address.parse(trimmed, 0)) |ip4| .{ .ip4 = ip4 } else |_| null;
}

pub fn isValidCidrOrIp(entry: []const u8) bool {
    const trimmed = std.mem.trim(u8, entry, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const prefix = trimmed[0..slash];
        const mask_str = trimmed[slash + 1 ..];
        const mask_bits = std.fmt.parseInt(u8, mask_str, 10) catch return false;
        if (std.Io.net.Ip4Address.parse(prefix, 0)) |_| {
            return mask_bits <= 32;
        } else |_| {}
        if (std.Io.net.Ip6Address.parse(prefix, 0)) |_| {
            return mask_bits <= 128;
        } else |_| {}
        return false;
    } else {
        return parseIp(trimmed) != null;
    }
}

pub fn checkAllowlist(allowlist: []const u8, client_addr: anytype) bool {
    const trimmed_list = std.mem.trim(u8, allowlist, " \t\r\n");
    if (trimmed_list.len == 0) return true; // empty = allow any IP

    const client_ip: std.Io.net.IpAddress = blk: {
        const T = @TypeOf(client_addr);
        if (T == std.Io.net.IpAddress) {
            break :blk client_addr;
        } else if (T == []const u8 or T == [:0]const u8 or (@typeInfo(T) == .pointer and @typeInfo(T).pointer.child == u8)) {
            break :blk parseIp(client_addr) orelse return false;
        } else {
            break :blk client_addr;
        }
    };

    var it = std.mem.splitScalar(u8, trimmed_list, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;

        if (std.mem.indexOfScalar(u8, entry, '/')) |slash| {
            const prefix_str = entry[0..slash];
            const mask_str = entry[slash + 1 ..];
            const mask_bits = std.fmt.parseInt(u8, mask_str, 10) catch continue;

            switch (client_ip) {
                .ip4 => |client_ip4| {
                    if (mask_bits > 32) continue;
                    const net_ip4 = std.Io.net.Ip4Address.parse(prefix_str, 0) catch continue;
                    const client_u32 = std.mem.readInt(u32, &client_ip4.bytes, .big);
                    const net_u32 = std.mem.readInt(u32, &net_ip4.bytes, .big);
                    const mask: u32 = if (mask_bits == 0)
                        0
                    else if (mask_bits == 32)
                        ~@as(u32, 0)
                    else
                        ~(@as(u32, 0)) << @as(u5, @intCast(32 - mask_bits));
                    if ((client_u32 & mask) == (net_u32 & mask)) return true;
                },
                .ip6 => |client_ip6| {
                    if (mask_bits > 128) continue;
                    const net_ip6 = std.Io.net.Ip6Address.parse(prefix_str, 0) catch continue;
                    const full_bytes = mask_bits / 8;
                    const rem_bits = mask_bits % 8;
                    var match = true;
                    var i: usize = 0;
                    while (i < full_bytes) : (i += 1) {
                        if (client_ip6.bytes[i] != net_ip6.bytes[i]) {
                            match = false;
                            break;
                        }
                    }
                    if (match and rem_bits > 0) {
                        const rem_mask: u8 = @as(u8, 0xFF) << @as(u3, @intCast(8 - rem_bits));
                        if ((client_ip6.bytes[full_bytes] & rem_mask) != (net_ip6.bytes[full_bytes] & rem_mask)) {
                            match = false;
                        }
                    }
                    if (match) return true;
                },
            }
        } else {
            // Exact IP match
            const entry_ip = parseIp(entry) orelse continue;
            switch (client_ip) {
                .ip4 => |client_ip4| {
                    switch (entry_ip) {
                        .ip4 => |entry_ip4| {
                            if (std.mem.eql(u8, &client_ip4.bytes, &entry_ip4.bytes)) return true;
                        },
                        else => {},
                    }
                },
                .ip6 => |client_ip6| {
                    switch (entry_ip) {
                        .ip6 => |entry_ip6| {
                            if (std.mem.eql(u8, &client_ip6.bytes, &entry_ip6.bytes)) return true;
                        },
                        else => {},
                    }
                },
            }
        }
    }
    return false;
}
