const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const CURRENT_VERSION: i32 = 1;

pub fn init(conn: sqlite.Conn) !void {
    try conn.exec("PRAGMA journal_mode=WAL;");
    try conn.exec("PRAGMA busy_timeout=5000;");
    try conn.exec("PRAGMA foreign_keys=ON;");
    // Default: do not set synchronous → SQLite FULL (2). Override with
    // Z_SERVER_SQLITE_SYNCHRONOUS=OFF|NORMAL|FULL|EXTRA.
    try applySynchronous(conn);
    try migrate(conn);
}

fn applySynchronous(conn: sqlite.Conn) !void {
    const raw = std.c.getenv("Z_SERVER_SQLITE_SYNCHRONOUS") orelse return;
    const s = std.mem.span(raw);
    const sql: [:0]const u8 =
        if (eqlIgnore(s, "OFF") or std.mem.eql(u8, s, "0")) "PRAGMA synchronous=OFF;"
        else if (eqlIgnore(s, "NORMAL") or std.mem.eql(u8, s, "1")) "PRAGMA synchronous=NORMAL;"
        else if (eqlIgnore(s, "FULL") or std.mem.eql(u8, s, "2")) "PRAGMA synchronous=FULL;"
        else if (eqlIgnore(s, "EXTRA") or std.mem.eql(u8, s, "3")) "PRAGMA synchronous=EXTRA;"
        else return;
    try conn.exec(sql);
}

fn eqlIgnore(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn migrate(conn: sqlite.Conn) !void {
    const version = try userVersion(conn);
    if (version >= CURRENT_VERSION) return;

    // v1
    if (version < 1) {
        try conn.exec(
            \\CREATE TABLE IF NOT EXISTS items(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
            \\  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            \\);
        );
        try conn.exec("PRAGMA user_version = 1;");
    }
}

fn userVersion(conn: sqlite.Conn) !i32 {
    var stmt = try conn.prepare("PRAGMA user_version;");
    defer stmt.finalize();
    switch (try stmt.step()) {
        .row => return @intCast(stmt.columnInt64(0)),
        .done => return 0,
    }
}
