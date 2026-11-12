const std = @import("std");
const c = @import("c");
const app = @import("app");

const sqlite = app.sqlite;
const pool_mod = app.pool;

test "pool snapshotSynchronous default is FULL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try pool_mod.Pool.init(allocator, io, path, 4);
    defer pool.deinit();
    const snap = pool.snapshotSynchronous();
    try std.testing.expectEqual(@as(u8, 2), snap.first);
    try std.testing.expectEqual(false, snap.all_normal);
}

test "pool insert select delete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try pool_mod.Pool.init(allocator, io, path, 4);
    defer pool.deinit();

    var lease = try pool.acquire();
    defer lease.deinit();
    const conn = lease.conn;

    var insert = try conn.prepare("INSERT INTO items (name, payload) VALUES (?, ?);");
    defer insert.finalize();
    try insert.bindText(1, "alpha");
    try insert.bindText(2, "{\"k\":1}");
    _ = try insert.step();
    const id = conn.lastInsertRowid();
    try std.testing.expect(id >= 1);

    var select = try conn.prepare("SELECT name FROM items WHERE id = ?;");
    defer select.finalize();
    try select.bindInt64(1, id);
    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    const name = try select.copyText(0, allocator);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("alpha", name);

    var del = try conn.prepare("DELETE FROM items WHERE id = ?;");
    defer del.finalize();
    try del.bindInt64(1, id);
    _ = try del.step();
    try std.testing.expectEqual(@as(i32, 1), conn.changes());
}

test "two threads acquire distinct sqlite3 pointers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);

    const path = try uniqueDbPath(allocator);
    defer cleanupDb(allocator, path);

    var pool = try pool_mod.Pool.init(allocator, io, path, 2);
    defer pool.deinit();

    var go = std.atomic.Value(bool).init(false);
    var out1 = std.atomic.Value(usize).init(0);
    var out2 = std.atomic.Value(usize).init(0);

    const Worker = struct {
        pool: *pool_mod.Pool,
        out: *std.atomic.Value(usize),
        go: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var lease = self.pool.acquire() catch return;
            self.out.store(@intFromPtr(lease.conn.db), .seq_cst);
            while (!self.go.load(.seq_cst)) {
                std.Thread.yield() catch {};
            }
            lease.deinit();
        }
    };

    var w1 = Worker{ .pool = &pool, .out = &out1, .go = &go };
    var w2 = Worker{ .pool = &pool, .out = &out2, .go = &go };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});

    while (out1.load(.seq_cst) == 0 or out2.load(.seq_cst) == 0) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(out1.load(.seq_cst) != out2.load(.seq_cst));

    go.store(true, .seq_cst);
    t1.join();
    t2.join();
}

fn uniqueDbPath(allocator: std.mem.Allocator) ![:0]u8 {
    var n: u64 = undefined;
    std.testing.io.random(std.mem.asBytes(&n));
    return std.fmt.allocPrintSentinel(allocator, "/tmp/z-server-test-{d}.db", .{n}, 0);
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
