const std = @import("std");
const z_server_db = @import("z_server_db");

pub const REFRESH_TOKEN_TTL_SECONDS: u32 = 7 * 24 * 3600; // 7 days

pub fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}

pub const RefreshTokenResult = struct {
    token: [43]u8,
    expires_at: i64,

    pub fn plaintext(self: *const RefreshTokenResult) []const u8 {
        return &self.token;
    }
};

pub const RefreshTokenClaims = struct {
    id: i64,
    sub: []const u8,
    scopes: []const u8,
    expires_at: i64,
};

pub fn initSchema(pool: *z_server_db.Pool) !void {
    var lease = try pool.acquire();
    defer lease.release();

    try lease.conn.exec(
        \\CREATE TABLE IF NOT EXISTS refresh_tokens (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    token_hash TEXT UNIQUE NOT NULL,
        \\    sub TEXT NOT NULL,
        \\    scopes TEXT NOT NULL,
        \\    expires_at INTEGER NOT NULL,
        \\    revoked INTEGER NOT NULL DEFAULT 0,
        \\    created_at INTEGER NOT NULL
        \\);
    );
    try lease.conn.exec("CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);");
    try lease.conn.exec("CREATE INDEX IF NOT EXISTS idx_refresh_tokens_exp ON refresh_tokens(expires_at);");
}

pub fn hashRefreshToken(token: []const u8, secret_key: *const [32]u8) [64]u8 {
    var hmac_out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_out, token, secret_key);
    return std.fmt.bytesToHex(hmac_out, .lower);
}

pub fn createRefreshToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *z_server_db.Pool,
    secret_key: *const [32]u8,
    sub: []const u8,
    scopes: []const u8,
) !RefreshTokenResult {
    _ = allocator;
    var raw_bytes: [32]u8 = undefined;
    io.random(&raw_bytes);
    defer std.crypto.secureZero(u8, &raw_bytes);

    var token_b64: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&token_b64, &raw_bytes);

    const token_hash = hashRefreshToken(&token_b64, secret_key);
    const now = getUnixTimestamp();
    const expires_at = now + REFRESH_TOKEN_TTL_SECONDS;

    var lease = try pool.acquire();
    defer lease.release();

    const insert_sql =
        \\INSERT INTO refresh_tokens (token_hash, sub, scopes, expires_at, revoked, created_at)
        \\VALUES (?, ?, ?, ?, 0, ?);
    ;

    var s = try lease.conn.prepare(insert_sql);
    defer s.finalize();

    try s.bindText(1, &token_hash);
    try s.bindText(2, sub);
    try s.bindText(3, scopes);
    try s.bindInt64(4, expires_at);
    try s.bindInt64(5, now);

    _ = try s.step();

    return RefreshTokenResult{
        .token = token_b64,
        .expires_at = expires_at,
    };
}

pub fn validateRefreshToken(
    arena: std.mem.Allocator,
    pool: *z_server_db.Pool,
    secret_key: *const [32]u8,
    token_plaintext: []const u8,
) !?RefreshTokenClaims {
    if (token_plaintext.len != 43) return null;

    const token_hash = hashRefreshToken(token_plaintext, secret_key);
    const now = getUnixTimestamp();

    var lease = try pool.acquire();
    defer lease.release();

    const select_sql =
        \\SELECT id, sub, scopes, expires_at, revoked
        \\FROM refresh_tokens
        \\WHERE token_hash = ? AND revoked = 0 AND expires_at > ?
        \\LIMIT 1;
    ;

    var s = try lease.conn.prepare(select_sql);
    defer s.finalize();

    try s.bindText(1, &token_hash);
    try s.bindInt64(2, now);

    const step_res = try s.step();
    if (step_res != .row) return null;

    const id = s.columnInt64(0);
    const sub_text = s.columnText(1);
    const scopes_text = s.columnText(2);
    const expires_at = s.columnInt64(3);

    return RefreshTokenClaims{
        .id = id,
        .sub = try arena.dupe(u8, sub_text),
        .scopes = try arena.dupe(u8, scopes_text),
        .expires_at = expires_at,
    };
}

pub fn revokeRefreshToken(
    pool: *z_server_db.Pool,
    secret_key: *const [32]u8,
    token_plaintext: []const u8,
) !void {
    if (token_plaintext.len != 43) return;

    const token_hash = hashRefreshToken(token_plaintext, secret_key);

    var lease = try pool.acquire();
    defer lease.release();

    const update_sql = "UPDATE refresh_tokens SET revoked = 1 WHERE token_hash = ?;";
    var s = try lease.conn.prepare(update_sql);
    defer s.finalize();

    try s.bindText(1, &token_hash);
    _ = try s.step();
}

pub fn cleanupExpiredRefreshTokens(pool: *z_server_db.Pool) !void {
    const now = getUnixTimestamp();

    var lease = try pool.acquire();
    defer lease.release();

    const delete_sql = "DELETE FROM refresh_tokens WHERE expires_at < ?;";
    var s = try lease.conn.prepare(delete_sql);
    defer s.finalize();

    try s.bindInt64(1, now);
    _ = try s.step();
}
