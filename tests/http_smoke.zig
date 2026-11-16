const std = @import("std");
const httpz = @import("httpz");
const app = @import("app");

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
    try ht.expectJson(.{
        .ok = true,
        .version = "1.0.0",
        .db = "ok",
        .cache = "ok",
        .sqlite_busy_count = 0,
        .handler_threads = 4,
        .sqlite_pool = 4,
        .sqlite_synchronous = 2,
        .sqlite_synchronous_all_normal = false,
        .tls_version = "TLSv1.2",
        .tls_cipher_suites = &[_][]const u8{
            "ECDHE-RSA-AES128-GCM-SHA256",
            "ECDHE-RSA-AES256-GCM-SHA384",
            "ECDHE-RSA-CHACHA20-POLY1305-SHA256",
        },
        .tls_curves = &[_][]const u8{
            "x25519",
            "secp256r1",
        },
        .tls_renegotiation = "disabled",
        .tls_rsa_keyx = "disabled",
    });
}

test "handler threads env overrides nproc fallback" {
    try std.testing.expectEqual(@as(u16, 4), app.handlerThreadCount("4"));
    try std.testing.expectEqual(@as(u16, 8), app.sqlitePoolSize("8", 4));
    try std.testing.expectEqual(@as(u16, 4), app.sqlitePoolSize(null, 4));
}

test "parseBind 0.0.0.0 maps to Address.all and listens on all interfaces" {
    const parsed = try app.parseBind("0.0.0.0:0");
    try std.testing.expectEqualStrings("0.0.0.0", parsed.host);
    try std.testing.expectEqual(@as(u16, 0), parsed.port);
    const ip = switch (parsed.address) {
        .ip => |addr| addr,
        .unix => return error.TestUnexpectedResult,
    };
    switch (ip) {
        .ip4 => |ip4| try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, ip4.bytes),
        .ip6 => return error.TestUnexpectedResult,
    }

    const io = std.testing.io;
    var listener = try ip.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    switch (listener.socket.address) {
        .ip4 => |ip4| {
            try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, ip4.bytes);
            try std.testing.expect(ip4.port != 0);
        },
        .ip6 => return error.TestUnexpectedResult,
    }

    const def = try app.parseBind(null);
    try std.testing.expectEqualStrings("127.0.0.1", def.host);
    try std.testing.expectEqual(@as(u16, 8080), def.port);
    switch (def.address) {
        .ip => |addr| switch (addr) {
            .ip4 => |ip4| try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip4.bytes),
            .ip6 => return error.TestUnexpectedResult,
        },
        .unix => return error.TestUnexpectedResult,
    }

    const loopback = try app.parseBind("127.0.0.1:9090");
    try std.testing.expectEqualStrings("127.0.0.1", loopback.host);
    try std.testing.expectEqual(@as(u16, 9090), loopback.port);

    try std.testing.expectError(error.InvalidBind, app.parseBind("garbage"));
    try std.testing.expectError(error.InvalidBind, app.parseBind("localhost:8080"));
    try std.testing.expectError(error.InvalidBind, app.parseBind("0.0.0.0"));
    try std.testing.expectError(error.InvalidBind, app.parseBind("0.0.0.0:99999"));
}

const TestEnv = struct {
    allocator: std.mem.Allocator,
    db_path: [:0]u8,
    app: app.App,

    fn init() !TestEnv {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        app.sqlite.initLibrary();
        var n: u64 = undefined;
        io.random(std.mem.asBytes(&n));
        const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/z-server-test-{d}.db", .{n}, 0);
        const db = try app.pool.Pool.init(allocator, io, .{ .path = path, .pool_size = 4 });
        const cache = try app.cache_mod.Cache.init(allocator, 512);
        return .{
            .allocator = allocator,
            .db_path = path,
            .app = .{ .db = db, .cache = cache, .allocator = allocator, .io = io, .handler_threads = 4, .sqlite_pool = 4 },
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
