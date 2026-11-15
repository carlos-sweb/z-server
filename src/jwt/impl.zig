const std = @import("std");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const refresh = @import("refresh.zig");

pub const JWT_DEFAULT_TTL_SECONDS: u32 = 900; // 15 minutes
pub const JWT_CLOCK_SKEW_TOLERANCE: i64 = 30; // 30 seconds

pub fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}

pub const Claims = struct {
    iss: []const u8 = "z-server",
    aud: []const u8 = "z-server-api",
    sub: []const u8,
    jti: []const u8,
    iat: i64,
    nbf: i64,
    exp: i64,
    scope: []const u8 = "",

    pub fn hasScope(self: Claims, required: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, self.scope, " ,");
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "*") or std.mem.eql(u8, token, required)) {
                return true;
            }
        }
        return false;
    }
};

pub const Options = struct {
    secret: []const u8,
    secondary_secret: ?[]const u8 = null,
    ttl_seconds: u32 = JWT_DEFAULT_TTL_SECONDS,
    cache: ?*z_server_cache.Cache = null,
    denylist_cache_ttl_seconds: u32 = 5,
    require_https: bool = true,
};

pub const JwtError = error{
    InvalidSecret,
    MissingSecret,
    InvalidTokenFormat,
    InvalidAlgorithm,
    InvalidSignature,
    TokenExpired,
    TokenNotYetValid,
    TokenIssuedInFuture,
    InvalidIssuer,
    InvalidAudience,
    TokenRevoked,
    InsecureTransport,
    OutOfMemory,
    DatabaseError,
};

const HeaderJson = struct {
    alg: []const u8,
    typ: ?[]const u8 = null,
};

const RawClaims = struct {
    iss: ?[]const u8 = null,
    aud: ?[]const u8 = null,
    sub: ?[]const u8 = null,
    jti: ?[]const u8 = null,
    iat: ?i64 = null,
    nbf: ?i64 = null,
    exp: ?i64 = null,
    scope: ?[]const u8 = null,
};

pub fn parseSecret(raw_secret: []const u8) !?[32]u8 {
    const trimmed = std.mem.trim(u8, raw_secret, " \r\n\t");
    if (trimmed.len == 0) return null;

    var secret: [32]u8 = undefined;
    if (trimmed.len == 64) {
        _ = std.fmt.hexToBytes(&secret, trimmed) catch return error.InvalidSecret;
        return secret;
    } else if (trimmed.len == 44) {
        _ = std.base64.standard.Decoder.decode(&secret, trimmed) catch return error.InvalidSecret;
        return secret;
    } else if (trimmed.len == 43) {
        _ = std.base64.url_safe_no_pad.Decoder.decode(&secret, trimmed) catch return error.InvalidSecret;
        return secret;
    } else if (trimmed.len >= 32) {
        @memcpy(&secret, trimmed[0..32]);
        return secret;
    }
    return error.InvalidSecret;
}

pub const Token = struct {
    raw: []const u8,
    claims: Claims,
};

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *z_server_db.Pool,
    options: Options,
    primary_key: [32]u8,
    secondary_key: ?[32]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        pool: *z_server_db.Pool,
        options: Options,
    ) !Authenticator {
        const prim_opt = try parseSecret(options.secret);
        const prim = prim_opt orelse return error.MissingSecret;

        var sec: ?[32]u8 = null;
        if (options.secondary_secret) |sec_raw| {
            sec = try parseSecret(sec_raw);
        }

        // Initialize SQLite tables for jti denylist
        var lease = try pool.acquire();
        defer lease.release();

        try lease.conn.exec(
            \\CREATE TABLE IF NOT EXISTS revoked_jwt (
            \\    jti TEXT PRIMARY KEY,
            \\    expires_at INTEGER NOT NULL
            \\);
        );
        try lease.conn.exec("CREATE INDEX IF NOT EXISTS idx_revoked_jwt_exp ON revoked_jwt(expires_at);");
        try refresh.initSchema(pool);

        return Authenticator{
            .allocator = allocator,
            .io = io,
            .pool = pool,
            .options = options,
            .primary_key = prim,
            .secondary_key = sec,
        };
    }

    pub fn deinit(self: *Authenticator) void {
        std.crypto.secureZero(u8, &self.primary_key);
        if (self.secondary_key) |*sec| {
            std.crypto.secureZero(u8, sec);
        }
    }

    fn generateUuidV4(self: *const Authenticator, out: *[36]u8) void {
        var b: [16]u8 = undefined;
        self.io.random(&b);
        b[6] = (b[6] & 0x0f) | 0x40; // Version 4
        b[8] = (b[8] & 0x3f) | 0x80; // Variant RFC 4122
        const hex = "0123456789abcdef";
        var idx: usize = 0;
        inline for (0..16) |i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[idx] = '-';
                idx += 1;
            }
            out[idx] = hex[b[i] >> 4];
            out[idx + 1] = hex[b[i] & 0x0f];
            idx += 2;
        }
    }

    pub fn issue(
        self: *const Authenticator,
        allocator: std.mem.Allocator,
        sub: []const u8,
        scope: []const u8,
        custom_ttl: ?u32,
    ) ![]u8 {
        const ttl = custom_ttl orelse self.options.ttl_seconds;
        const now = getUnixTimestamp();
        const exp = now + @as(i64, @intCast(ttl));

        var jti_buf: [36]u8 = undefined;
        self.generateUuidV4(&jti_buf);

        // Pre-computed Base64URL for {"alg":"HS256","typ":"JWT"}
        const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

        // Construct Payload JSON
        const payload_json = try std.fmt.allocPrint(allocator,
            \\{{"iss":"z-server","aud":"z-server-api","sub":"{s}","jti":"{s}","iat":{d},"nbf":{d},"exp":{d},"scope":"{s}"}}
        , .{ sub, &jti_buf, now, now, exp, scope });
        defer allocator.free(payload_json);

        const enc = std.base64.url_safe_no_pad.Encoder;
        const payload_b64_len = enc.calcSize(payload_json.len);
        const payload_b64 = try allocator.alloc(u8, payload_b64_len);
        defer allocator.free(payload_b64);
        _ = enc.encode(payload_b64, payload_json);

        // Signing input = header_b64 . "." . payload_b64
        const signing_input_len = header_b64.len + 1 + payload_b64.len;
        const signing_input = try allocator.alloc(u8, signing_input_len);
        defer allocator.free(signing_input);

        @memcpy(signing_input[0..header_b64.len], header_b64);
        signing_input[header_b64.len] = '.';
        @memcpy(signing_input[header_b64.len + 1 ..], payload_b64);

        // HMAC-SHA256 signature
        var sig_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&sig_bytes, signing_input, &self.primary_key);

        var sig_b64: [43]u8 = undefined;
        _ = enc.encode(&sig_b64, &sig_bytes);

        // Result: signing_input . "." . sig_b64
        const total_len = signing_input_len + 1 + sig_b64.len;
        const result = try allocator.alloc(u8, total_len);
        @memcpy(result[0..signing_input_len], signing_input);
        result[signing_input_len] = '.';
        @memcpy(result[signing_input_len + 1 ..], &sig_b64);

        return result;
    }

    pub fn validate(
        self: *const Authenticator,
        token: []const u8,
        arena: std.mem.Allocator,
    ) !?Claims {
        // Fast bounds check
        if (token.len < 10 or token.len > 8192) return null;

        // Split by '.'
        const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return null;
        const rest = token[dot1 + 1 ..];
        const dot2_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const dot2 = dot1 + 1 + dot2_rel;
        if (std.mem.indexOfScalar(u8, token[dot2 + 1 ..], '.') != null) return null; // No extra parts

        const header_b64 = token[0..dot1];
        const payload_b64 = token[dot1 + 1 .. dot2];
        const sig_b64 = token[dot2 + 1 ..];
        const signing_input = token[0..dot2];

        // S1: Parse header and verify "alg" == "HS256" strictly
        const dec = std.base64.url_safe_no_pad.Decoder;
        const header_json_len = dec.calcSizeForSlice(header_b64) catch return null;
        const header_json = try arena.alloc(u8, header_json_len);
        defer std.crypto.secureZero(u8, header_json);
        dec.decode(header_json, header_b64) catch return null;

        const parsed_header = std.json.parseFromSlice(HeaderJson, arena, header_json, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        // S1: Strict algorithm whitelist check
        if (!std.mem.eql(u8, parsed_header.value.alg, "HS256")) {
            return null; // Reject alg: none, RS256, etc.
        }

        // S2: Decode and verify signature with constant-time equality
        if (sig_b64.len != 43) return null;
        var sig_bytes: [32]u8 = undefined;
        dec.decode(&sig_bytes, sig_b64) catch return null;

        var expected_prim: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_prim, signing_input, &self.primary_key);

        var sig_valid = std.crypto.timing_safe.eql([32]u8, expected_prim, sig_bytes);
        if (!sig_valid and self.secondary_key != null) {
            var expected_sec: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_sec, signing_input, &self.secondary_key.?);
            sig_valid = std.crypto.timing_safe.eql([32]u8, expected_sec, sig_bytes);
        }

        if (!sig_valid) return null;

        // S4: Parse and validate claims
        const payload_json_len = dec.calcSizeForSlice(payload_b64) catch return null;
        const payload_json = try arena.alloc(u8, payload_json_len);
        defer std.crypto.secureZero(u8, payload_json);
        dec.decode(payload_json, payload_b64) catch return null;

        const parsed_payload = std.json.parseFromSlice(RawClaims, arena, payload_json, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        const raw = parsed_payload.value;
        const iss = raw.iss orelse return null;
        const aud = raw.aud orelse return null;
        const sub = raw.sub orelse return null;
        const jti = raw.jti orelse return null;
        const exp = raw.exp orelse return null;
        const nbf = raw.nbf orelse exp;
        const iat = raw.iat orelse exp;
        const scope = raw.scope orelse "";

        // Claim validations
        if (!std.mem.eql(u8, iss, "z-server")) return null;
        if (!std.mem.eql(u8, aud, "z-server-api")) return null;
        if (sub.len == 0 or jti.len == 0) return null;

        const now = getUnixTimestamp();
        if (exp <= now - JWT_CLOCK_SKEW_TOLERANCE) return null; // Expired
        if (nbf > now + JWT_CLOCK_SKEW_TOLERANCE) return null; // Not yet valid
        if (iat > now + JWT_CLOCK_SKEW_TOLERANCE) return null; // Issued in future

        // Decision 5 & 6: Check jti in denylist
        if (try self.isJtiRevoked(jti, arena)) {
            return null; // Revoked token
        }

        return Claims{
            .iss = try arena.dupe(u8, iss),
            .aud = try arena.dupe(u8, aud),
            .sub = try arena.dupe(u8, sub),
            .jti = try arena.dupe(u8, jti),
            .iat = iat,
            .nbf = nbf,
            .exp = exp,
            .scope = try arena.dupe(u8, scope),
        };
    }

    fn isJtiRevoked(self: *const Authenticator, jti: []const u8, arena: std.mem.Allocator) !bool {
        var key_buf: [64]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&key_buf, "jwt_revoked:{s}", .{jti}) catch return true;

        if (self.options.cache) |cache| {
            if (cache.get(cache_key, arena)) |val_opt| {
                if (val_opt) |val| {
                    if (std.mem.eql(u8, val, "1")) return true;
                    if (std.mem.eql(u8, val, "0")) return false;
                }
            } else |_| {}
        }

        // Query SQLite
        var lease = try self.pool.acquire();
        defer lease.release();

        const select_sql = "SELECT 1 FROM revoked_jwt WHERE jti = ? AND expires_at > ? LIMIT 1;";
        var s = try lease.conn.prepare(select_sql);
        defer s.finalize();

        const now = getUnixTimestamp();
        try s.bindText(1, jti);
        try s.bindInt64(2, now);

        const step_res = try s.step();
        if (step_res == .row) {
            if (self.options.cache) |cache| {
                cache.set(cache_key, "1", self.options.denylist_cache_ttl_seconds) catch {};
            }
            return true;
        }

        if (self.options.cache) |cache| {
            cache.set(cache_key, "0", self.options.denylist_cache_ttl_seconds) catch {};
        }
        return false;
    }

    pub fn revoke(self: *const Authenticator, jti: []const u8, exp: i64) !void {
        var lease = try self.pool.acquire();
        defer lease.release();

        const insert_sql = "INSERT OR REPLACE INTO revoked_jwt (jti, expires_at) VALUES (?, ?);";
        var s = try lease.conn.prepare(insert_sql);
        defer s.finalize();

        try s.bindText(1, jti);
        try s.bindInt64(2, exp);
        _ = try s.step();

        var key_buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&key_buf, "jwt_revoked:{s}", .{jti})) |cache_key| {
            if (self.options.cache) |cache| {
                cache.set(cache_key, "1", self.options.denylist_cache_ttl_seconds) catch {};
            }
        } else |_| {}
    }

    pub fn cleanup(self: *const Authenticator) !void {
        const now = getUnixTimestamp();
        var lease = try self.pool.acquire();
        defer lease.release();

        const delete_sql = "DELETE FROM revoked_jwt WHERE expires_at < ?;";
        var s = try lease.conn.prepare(delete_sql);
        defer s.finalize();

        try s.bindInt64(1, now);
        _ = try s.step();
    }
};
