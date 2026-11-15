const std = @import("std");
const z_server = @import("z_server");
const z_cache = @import("z_server_cache");

const App = struct {
    cache: z_cache.Cache,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    var cache = try z_cache.Cache.init(init.gpa, 512);
    defer cache.deinit();

    var app = App{
        .cache = cache,
        .allocator = init.gpa,
    };

    var server = try z_server.ServerT(*App).init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .handler_ctx = &app,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
            .{ .method = .GET, .path = "/counter", .handler = handleCounter },
        },
    });
    defer server.deinit();

    std.debug.print("hello-cache listening on 127.0.0.1:9000\n", .{});
    try server.serve();
}

fn handleRoot(_: *App, _: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .service = "hello-cache" }, .{});
}

fn handleCounter(app: *App, _: *z_server.Request, res: *z_server.Response) !void {
    var buf: [32]u8 = undefined;
    const v = app.cache.get("counter", app.allocator) catch null;
    defer if (v) |s| app.allocator.free(s);
    const n = if (v) |s| (std.fmt.parseInt(i64, s, 10) catch 0) else 0;
    const n2 = n + 1;
    const s2 = try std.fmt.bufPrint(&buf, "{d}", .{n2});
    try app.cache.set("counter", s2, 60);
    try res.json(.{ .counter = n2 }, .{});
}
