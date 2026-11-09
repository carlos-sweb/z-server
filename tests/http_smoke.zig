const std = @import("std");
const httpz = @import("httpz");
const app = @import("app");
const c = @import("c");

test "GET / returns ok json" {
    var env = try TestEnv.init();
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");

    try app.index(&env.app, ht.req, ht.res);

    try ht.expectStatus(200);
    try ht.expectJson(.{ .ok = true });
}

test "GET /health returns version and db ok" {
    var env = try TestEnv.init();
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/health");

    try app.health(&env.app, ht.req, ht.res);

    try ht.expectStatus(200);
    try ht.expectJson(.{ .ok = true, .version = "0.1.0", .db = "ok", .cache = "ok" });
}

const TestEnv = struct {
    allocator: std.mem.Allocator,
    db_path: [:0]u8,
    app: app.App,

    fn init() !TestEnv {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);
        var n: u64 = undefined;
        io.random(std.mem.asBytes(&n));
        const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/z-server-test-{d}.db", .{n}, 0);
        const db = try app.pool.Pool.init(allocator, io, path, 4);
        const cache = try app.cache_mod.Cache.init(allocator, 512);
        return .{
            .allocator = allocator,
            .db_path = path,
            .app = .{ .db = db, .cache = cache, .allocator = allocator, .io = io },
        };
    }

    fn deinit(self: *TestEnv) void {
        self.app.db.deinit();
        self.app.cache.deinit();
        const io = self.app.io;
        std.Io.Dir.deleteFileAbsolute(io, self.db_path) catch {};
        const wal = std.fmt.allocPrintSentinel(self.allocator, "{s}-wal", .{self.db_path}, 0) catch {
            self.allocator.free(self.db_path);
            return;
        };
        defer self.allocator.free(wal);
        std.Io.Dir.deleteFileAbsolute(io, wal) catch {};
        const shm = std.fmt.allocPrintSentinel(self.allocator, "{s}-shm", .{self.db_path}, 0) catch {
            self.allocator.free(self.db_path);
            return;
        };
        defer self.allocator.free(shm);
        std.Io.Dir.deleteFileAbsolute(io, shm) catch {};
        self.allocator.free(self.db_path);
    }
};
