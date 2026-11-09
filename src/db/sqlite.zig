//! sqlite3_column_text pointer is valid only until next step/reset/finalize.
//! Caller must copy before that.

const std = @import("std");
const c = @import("c");

pub const Error = error{
    Busy,
    BusyTimeout,
    Constraint,
    IoErr,
    Corrupt,
    CantOpen,
    Misuse,
    NoMem,
    NotFound,
    Other,
};

pub const Step = enum { row, done };

pub const Conn = struct {
    db: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Conn {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(path.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |handle| {
                const err = mapExtended(handle);
                _ = c.sqlite3_close_v2(handle);
                return err;
            }
            return error.CantOpen;
        }
        const handle = db.?;
        _ = c.sqlite3_extended_result_codes(handle, 1);
        return .{ .db = handle };
    }

    pub fn close(self: Conn) void {
        _ = c.sqlite3_close_v2(self.db);
    }

    pub fn exec(self: Conn, sql: [:0]const u8) Error!void {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        while (true) {
            switch (try stmt.step()) {
                .row => continue,
                .done => return,
            }
        }
    }

    pub fn prepare(self: Conn, sql: [:0]const u8) Error!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return mapExtended(self.db);
        return .{ .stmt = stmt.?, .db = self.db };
    }

    pub fn lastInsertRowid(self: Conn) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn changes(self: Conn) i32 {
        return c.sqlite3_changes(self.db);
    }

    pub fn errmsg(self: Conn) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.db));
    }
};

pub const Stmt = struct {
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn bindInt64(self: Stmt, index: i32, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.stmt, index, value);
        if (rc != c.SQLITE_OK) return mapExtended(self.db);
    }

    pub fn bindText(self: Stmt, index: i32, value: []const u8) Error!void {
        const rc = c.sqlite3_bind_text(
            self.stmt,
            index,
            value.ptr,
            @intCast(value.len),
            c.SQLITE_TRANSIENT,
        );
        if (rc != c.SQLITE_OK) return mapExtended(self.db);
    }

    pub fn bindNull(self: Stmt, index: i32) Error!void {
        const rc = c.sqlite3_bind_null(self.stmt, index);
        if (rc != c.SQLITE_OK) return mapExtended(self.db);
    }

    pub fn step(self: Stmt) Error!Step {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) return .row;
        if (rc == c.SQLITE_DONE) return .done;
        return mapExtended(self.db);
    }

    pub fn columnInt64(self: Stmt, index: i32) i64 {
        return c.sqlite3_column_int64(self.stmt, index);
    }

    /// Pointer is valid only until the next step/reset/finalize.
    pub fn columnText(self: Stmt, index: i32) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, index) orelse return &.{};
        const n: usize = @intCast(c.sqlite3_column_bytes(self.stmt, index));
        return ptr[0..n];
    }

    /// Pointer is valid only until the next step/reset/finalize.
    pub fn columnBlob(self: Stmt, index: i32) []const u8 {
        const n: usize = @intCast(c.sqlite3_column_bytes(self.stmt, index));
        if (n == 0) return &.{};
        const ptr = c.sqlite3_column_blob(self.stmt, index) orelse return &.{};
        return @as([*]const u8, @ptrCast(ptr))[0..n];
    }

    pub fn columnBytes(self: Stmt, index: i32) usize {
        return @intCast(c.sqlite3_column_bytes(self.stmt, index));
    }

    pub fn copyText(self: Stmt, index: i32, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.columnText(index));
    }

    pub fn reset(self: Stmt) void {
        _ = c.sqlite3_reset(self.stmt);
    }

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

pub fn mapCode(code: c_int) Error {
    if (code == c.SQLITE_BUSY_TIMEOUT) return error.BusyTimeout;
    return switch (code & 0xff) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_IOERR => error.IoErr,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_NOTFOUND => error.NotFound,
        else => error.Other,
    };
}

fn mapExtended(db: *c.sqlite3) Error {
    return mapCode(c.sqlite3_extended_errcode(db));
}
