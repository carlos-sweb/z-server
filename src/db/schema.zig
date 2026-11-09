const sqlite = @import("sqlite.zig");

pub const CURRENT_VERSION: i32 = 1;

pub fn init(conn: sqlite.Conn) !void {
    try conn.exec("PRAGMA journal_mode=WAL;");
    try conn.exec("PRAGMA busy_timeout=5000;");
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrate(conn);
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
