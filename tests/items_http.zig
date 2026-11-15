const std = @import("std");
const httpz = @import("httpz");
const app = @import("app");

test "POST /items valid json returns 201 id" {
    var env = try TestEnv.init();
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items");
    ht.json(.{ .name = "foo", .payload = .{ .k = 1 } });

    try app.items.create(&env.app, ht.req, ht.res);

    try ht.expectStatus(201);
    try ht.expectJson(.{ .id = 1 });
}

test "GET /items returns inserted item" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items");

    try app.items.list(&env.app, ht.req, ht.res);

    try ht.expectStatus(200);
    try ht.expectJson(.{.{ .id = 1, .name = "foo" }});
}

test "GET /items/:id returns item" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items/1");
    ht.param("id", "1");

    try app.items.getItem(&env.app, ht.req, ht.res);

    try ht.expectStatus(200);
    try ht.expectJson(.{
        .id = 1,
        .name = "foo",
        .payload = .{ .k = 1 },
    });
}

test "GET /items/9999 returns 404" {
    var env = try TestEnv.init();
    defer env.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items/9999");
    ht.param("id", "9999");

    try app.items.getItem(&env.app, ht.req, ht.res);

    try ht.expectStatus(404);
}

test "POST /items invalid json returns 400" {
    var env = try TestEnv.init();
    defer env.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items");
    ht.body("not json");

    try app.items.create(&env.app, ht.req, ht.res);

    try ht.expectStatus(400);
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

fn insertFoo(env: *TestEnv) !void {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.json(.{ .name = "foo", .payload = .{ .k = 1 } });
    try app.items.create(&env.app, ht.req, ht.res);
    try ht.expectStatus(201);
}

test "GET /items/:id first call is MISS" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items/1");
    ht.param("id", "1");
    try app.items.getItem(&env.app, ht.req, ht.res);
    try ht.expectStatus(200);
    try ht.expectHeader("X-Cache", "MISS");
}

test "GET /items/:id second call is HIT" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var miss = httpz.testing.init(.{});
    defer miss.deinit();
    miss.url("/items/1");
    miss.param("id", "1");
    try app.items.getItem(&env.app, miss.req, miss.res);
    try miss.expectStatus(200);
    try miss.expectHeader("X-Cache", "MISS");
    const miss_body = try miss.getBody();

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    hit.url("/items/1");
    hit.param("id", "1");
    try app.items.getItem(&env.app, hit.req, hit.res);
    try hit.expectStatus(200);
    try hit.expectHeader("X-Cache", "HIT");
    const hit_body = try hit.getBody();
    try std.testing.expectEqualStrings(miss_body, hit_body);
}

test "PUT invalidates" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var miss = httpz.testing.init(.{});
    defer miss.deinit();
    miss.param("id", "1");
    try app.items.getItem(&env.app, miss.req, miss.res);
    try miss.expectHeader("X-Cache", "MISS");

    var put = httpz.testing.init(.{});
    defer put.deinit();
    put.param("id", "1");
    put.json(.{ .name = "new", .payload = .{ .k = 2 } });
    try app.items.putItem(&env.app, put.req, put.res);
    try put.expectStatus(200);

    var after = httpz.testing.init(.{});
    defer after.deinit();
    after.param("id", "1");
    try app.items.getItem(&env.app, after.req, after.res);
    try after.expectStatus(200);
    try after.expectHeader("X-Cache", "MISS");
    try after.expectJson(.{ .id = 1, .name = "new", .payload = .{ .k = 2 } });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    hit.param("id", "1");
    try app.items.getItem(&env.app, hit.req, hit.res);
    try hit.expectStatus(200);
    try hit.expectHeader("X-Cache", "HIT");
}

test "DELETE invalidates" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    var get = httpz.testing.init(.{});
    defer get.deinit();
    get.param("id", "1");
    try app.items.getItem(&env.app, get.req, get.res);
    try get.expectStatus(200);

    var del = httpz.testing.init(.{});
    defer del.deinit();
    del.param("id", "1");
    try app.items.deleteItem(&env.app, del.req, del.res);
    try del.expectStatus(204);

    var missing = httpz.testing.init(.{});
    defer missing.deinit();
    missing.param("id", "1");
    try app.items.getItem(&env.app, missing.req, missing.res);
    try missing.expectStatus(404);
}

test "value between 32 and 64 KiB is not cached" {
    var env = try TestEnv.init();
    defer env.deinit();

    const filler = try env.allocator.alloc(u8, 40000);
    defer env.allocator.free(filler);
    @memset(filler, 'x');

    var post = httpz.testing.init(.{});
    defer post.deinit();
    post.json(.{ .name = "big", .payload = .{ .data = filler } });
    try app.items.create(&env.app, post.req, post.res);
    try post.expectStatus(201);

    var first = httpz.testing.init(.{});
    defer first.deinit();
    first.param("id", "1");
    try app.items.getItem(&env.app, first.req, first.res);
    try first.expectStatus(200);
    try first.expectHeader("X-Cache", "MISS");

    var second = httpz.testing.init(.{});
    defer second.deinit();
    second.param("id", "1");
    try app.items.getItem(&env.app, second.req, second.res);
    try second.expectStatus(200);
    try second.expectHeader("X-Cache", "MISS");
}

test "value under 32 KiB is cached" {
    var env = try TestEnv.init();
    defer env.deinit();

    const filler = try env.allocator.alloc(u8, 30000);
    defer env.allocator.free(filler);
    @memset(filler, 'x');

    var post = httpz.testing.init(.{});
    defer post.deinit();
    post.json(.{ .name = "ok", .payload = .{ .data = filler } });
    try app.items.create(&env.app, post.req, post.res);
    try post.expectStatus(201);

    var first = httpz.testing.init(.{});
    defer first.deinit();
    first.param("id", "1");
    try app.items.getItem(&env.app, first.req, first.res);
    try first.expectStatus(200);
    try first.expectHeader("X-Cache", "MISS");

    var second = httpz.testing.init(.{});
    defer second.deinit();
    second.param("id", "1");
    try app.items.getItem(&env.app, second.req, second.res);
    try second.expectStatus(200);
    try second.expectHeader("X-Cache", "HIT");
}

test "concurrent PUT to same id keeps cache coherent" {
    var env = try TestEnv.init();
    defer env.deinit();
    try insertFoo(&env);

    const Worker = struct {
        app: *app.App,
        idx: u8,

        fn run(self: *@This()) void {
            var ht = httpz.testing.init(.{});
            defer ht.deinit();
            ht.param("id", "1");
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "t{d}", .{self.idx}) catch return;
            ht.json(.{ .name = name, .payload = .{ .n = self.idx } });
            app.items.putItem(self.app, ht.req, ht.res) catch return;
        }
    };

    var workers: [10]Worker = undefined;
    var threads: [10]std.Thread = undefined;
    for (0..10) |i| {
        workers[i] = .{ .app = &env.app, .idx = @intCast(i) };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    }
    for (threads) |t| t.join();

    var miss = httpz.testing.init(.{});
    defer miss.deinit();
    miss.param("id", "1");
    try app.items.getItem(&env.app, miss.req, miss.res);
    try miss.expectStatus(200);
    try miss.expectHeader("X-Cache", "MISS");
    const miss_body = try miss.getBody();
    const parsed = try miss.getJson();
    const name = parsed.object.get("name").?.string;
    try std.testing.expect(name.len >= 2 and name[0] == 't');

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    hit.param("id", "1");
    try app.items.getItem(&env.app, hit.req, hit.res);
    try hit.expectStatus(200);
    try hit.expectHeader("X-Cache", "HIT");
    const hit_body = try hit.getBody();
    try std.testing.expectEqualStrings(miss_body, hit_body);
}

test "PUT non-existent returns 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "9999");
    ht.json(.{ .name = "x", .payload = .{ .k = 1 } });
    try app.items.putItem(&env.app, ht.req, ht.res);
    try ht.expectStatus(404);
}

test "DELETE non-existent returns 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "9999");
    try app.items.deleteItem(&env.app, ht.req, ht.res);
    try ht.expectStatus(404);
}
