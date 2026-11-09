const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const c = @import("c");

/// Connection pool sized to the HTTP handler thread pool:
/// N = clamp(2 * nproc, 4, 16). One sqlite3* is never used by two threads at once.
///
/// acquire waits up to 5s (`std.Io.Condition.waitTimeout`; there is no
/// waitUncancelableTimeout in 0.17.0) for a free connection.
pub const acquire_timeout: std.Io.Timeout = .{
    .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
};

pub const Error = error{ PoolTimeout, PoolClosed };

pub const ConnLease = struct {
    pool: *Pool,
    conn: sqlite.Conn,
    released: bool = false,

    pub fn release(self: *ConnLease) void {
        if (self.released) return;
        self.released = true;
        self.pool.release(self.conn);
    }

    pub fn deinit(self: *ConnLease) void {
        self.release();
    }
};

pub const Pool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    all: []*c.sqlite3,
    free: []*c.sqlite3,
    free_len: usize,
    closing: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: [:0]const u8,
        size: u16,
    ) !Pool {
        const all = try allocator.alloc(*c.sqlite3, size);
        errdefer allocator.free(all);
        const free = try allocator.alloc(*c.sqlite3, size);
        errdefer allocator.free(free);

        var opened: usize = 0;
        errdefer {
            for (all[0..opened]) |db| (sqlite.Conn{ .db = db }).close();
        }

        for (0..size) |i| {
            const conn = try sqlite.Conn.open(path);
            try schema.init(conn);
            all[i] = conn.db;
            free[i] = conn.db;
            opened += 1;
        }

        return .{
            .io = io,
            .allocator = allocator,
            .mutex = .init,
            .cond = .init,
            .all = all,
            .free = free,
            .free_len = size,
            .closing = false,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);

        for (self.all) |db| (sqlite.Conn{ .db = db }).close();
        self.allocator.free(self.all);
        self.allocator.free(self.free);
        self.* = undefined;
    }

    pub fn acquire(self: *Pool) Error!ConnLease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.free_len == 0) {
            if (self.closing) return error.PoolClosed;
            self.cond.waitTimeout(self.io, &self.mutex, acquire_timeout) catch |err| switch (err) {
                error.Timeout, error.Canceled => return error.PoolTimeout,
            };
        }
        if (self.closing) return error.PoolClosed;
        self.free_len -= 1;
        return .{
            .pool = self,
            .conn = .{ .db = self.free[self.free_len] },
        };
    }

    pub fn release(self: *Pool, conn: sqlite.Conn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.free[self.free_len] = conn.db;
        self.free_len += 1;
        self.cond.signal(self.io);
    }
};
