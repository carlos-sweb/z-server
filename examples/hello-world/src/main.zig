const std = @import("std");
const z_server = @import("z_server");

pub fn main(init: std.process.Init) !void {
    var server = try z_server.Server.init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
        },
    });
    defer server.deinit();

    std.debug.print("hello-world listening on 127.0.0.1:9000\n", .{});
    try server.serve();
}

fn handleRoot(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .message = "hello world" }, .{});
}
