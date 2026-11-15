const std = @import("std");

pub const pool = @import("pool.zig");
pub const sqlite = @import("sqlite.zig");
pub const schema = @import("schema.zig");
pub const c = @import("c");

pub const Pool = pool.Pool;
pub const ConnLease = pool.ConnLease;
pub const Conn = sqlite.Conn;
pub const Stmt = sqlite.Stmt;
pub const Statement = sqlite.Stmt;
pub const Step = sqlite.Step;
pub const Error = sqlite.Error;
pub const sqliteBusyCount = sqlite.sqliteBusyCount;

pub const SqliteSynchronous = pool.SqliteSynchronous;
pub const Options = pool.Options;

var initialized = std.atomic.Value(bool).init(false);

fn initLibraryInternal() void {
    if (c.sqlite3_threadsafe() == 0) {
        @panic("sqlite built without threadsafe");
    }
    _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);
}

/// Initializes sqlite3_config(SQLITE_CONFIG_SERIALIZED). Idempotent and thread-safe.
pub fn initLibrary() void {
    if (initialized.swap(true, .seq_cst)) return;
    initLibraryInternal();
}

pub fn libversion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}
