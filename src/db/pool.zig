const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const c = @import("c");

/// Connection pool size is `Z_SERVER_SQLITE_POOL`, or the handler thread count.
/// One sqlite3* is never used by two threads at once.
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

pub const SqliteSynchronous = enum {
    off,
    normal,
    full,
    extra,

    pub fn toPragma(self: SqliteSynchronous) [:0]const u8 {
        return switch (self) {
            .off => "PRAGMA synchronous=OFF;",
            .normal => "PRAGMA synchronous=NORMAL;",
            .full => "PRAGMA synchronous=FULL;",
            .extra => "PRAGMA synchronous=EXTRA;",
        };
    }
};

pub const Options = struct {
    path: []const u8 = "data/app.db",
    pool_size: u16 = 4,
    synchronous: ?SqliteSynchronous = null,
    busy_timeout_ms: u32 = 5000,
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
    synchronous_snapshot: u8,
    synchronous_all_normal: bool,
    synchronous_last_check_unix: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) !Pool {
        if (c.sqlite3_threadsafe() == 0) {
            @panic("sqlite built without threadsafe");
        }
        _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);

        if (std.fs.path.dirname(options.path)) |dir| {
            if (!std.mem.eql(u8, dir, ".")) {
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }
        }

        const path_z = try allocator.dupeSentinel(u8, options.path, 0);
        defer allocator.free(path_z);

        const pool_sz = options.pool_size;
        const all = try allocator.alloc(*c.sqlite3, pool_sz);
        errdefer allocator.free(all);
        const free = try allocator.alloc(*c.sqlite3, pool_sz);
        errdefer allocator.free(free);

        var opened: usize = 0;
        errdefer {
            for (all[0..opened]) |db| (sqlite.Conn{ .db = db }).close();
        }

        for (0..pool_sz) |i| {
            const conn = try sqlite.Conn.open(path_z);
            try conn.exec("PRAGMA journal_mode=WAL;");
            var busy_buf: [64]u8 = undefined;
            const pragma_busy_slice = try std.fmt.bufPrint(&busy_buf, "PRAGMA busy_timeout={d};", .{options.busy_timeout_ms});
            busy_buf[pragma_busy_slice.len] = 0;
            const pragma_busy: [:0]const u8 = busy_buf[0..pragma_busy_slice.len :0];
            try conn.exec(pragma_busy);
            try conn.exec("PRAGMA foreign_keys=ON;");
            if (options.synchronous) |synch| {
                try conn.exec(synch.toPragma());
            } else {
                try schema.applySynchronous(conn);
            }
            try schema.migrate(conn);

            all[i] = conn.db;
            free[i] = conn.db;
            opened += 1;
        }

        var pool: Pool = .{
            .io = io,
            .allocator = allocator,
            .mutex = .init,
            .cond = .init,
            .all = all,
            .free = free,
            .free_len = pool_sz,
            .closing = false,
            .synchronous_snapshot = 2,
            .synchronous_all_normal = false,
            .synchronous_last_check_unix = 0,
        };
        pool.refreshSynchronousSnapshot();
        return pool;
    }

    pub fn initLegacy(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: [:0]const u8,
        pool_size: u16,
    ) !Pool {
        return init(allocator, io, .{
            .path = path,
            .pool_size = pool_size,
        });
    }

    pub fn size(self: *const Pool) u16 {
        return @intCast(self.all.len);
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

    /// Reads `PRAGMA synchronous` from every live handle (FULLMUTEX serializes).
    pub fn snapshotSynchronous(self: *const Pool) struct { first: u8, all_normal: bool } {
        var first: u8 = 2;
        var all_normal = self.all.len > 0;
        for (self.all, 0..) |db, i| {
            const conn = sqlite.Conn{ .db = db };
            const v = conn.readSynchronous() catch {
                all_normal = false;
                continue;
            };
            if (i == 0) first = v;
            if (v != 1) all_normal = false;
        }
        return .{ .first = first, .all_normal = all_normal };
    }

    pub fn refreshSynchronousSnapshot(self: *Pool) void {
        const snap = self.snapshotSynchronous();
        self.synchronous_snapshot = snap.first;
        self.synchronous_all_normal = snap.all_normal;
        var ts: std.posix.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
            self.synchronous_last_check_unix = ts.sec;
        } else {
            self.synchronous_last_check_unix = 0;
        }
    }
};
