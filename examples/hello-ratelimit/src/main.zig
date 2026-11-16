const std = @import("std");
const z_server = @import("z_server");
const z_ratelimit = @import("z_server_ratelimit");

pub fn main(init: std.process.Init) !void {
    const bind_addr = "127.0.0.1:9000";

    var server = try z_server.Server.init(init.gpa, init.io, .{
        .bind = bind_addr,
        .routes = &.{
            .{ .method = .GET, .path = "/health", .handler = handleHealth },
            .{
                .method = .GET,
                .path = "/public",
                .handler = z_ratelimit.wrap(.{
                    .capacity = 100,
                    .window_seconds = 60,
                    .by = .ip,
                }, handlePublic),
            },
            .{
                .method = .GET,
                .path = "/api",
                .handler = z_ratelimit.wrap(.{
                    .capacity = 10,
                    .window_seconds = 60,
                    .by = .ip,
                }, handleApi),
            },
            .{
                .method = .GET,
                .path = "/strict",
                .handler = z_ratelimit.wrap(.{
                    .capacity = 2,
                    .window_seconds = 60,
                    .by = .ip,
                }, handleStrict),
            },
            .{
                .method = .GET,
                .path = "/tenant",
                .handler = z_ratelimit.wrap(.{
                    .capacity = 5,
                    .window_seconds = 60,
                    .by = .{ .header = "x-tenant-id" },
                }, handleTenant),
            },
        },
    });
    defer server.deinit();

    std.debug.print("hello-ratelimit listening on http://{s}\n", .{bind_addr});
    try server.serve();
}

fn handleHealth(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .status = "ok", .rate_limited = false }, .{});
}

fn handlePublic(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{
        .endpoint = "/public",
        .policy = "100 req / 60s by IP",
        .message = "Hello from public endpoint",
    }, .{});
}

fn handleApi(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{
        .endpoint = "/api",
        .policy = "10 req / 60s by IP",
        .message = "Hello from API endpoint",
    }, .{});
}

fn handleStrict(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{
        .endpoint = "/strict",
        .policy = "2 req / 60s by IP",
        .message = "Hello from strict endpoint",
    }, .{});
}

fn handleTenant(_: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{
        .endpoint = "/tenant",
        .policy = "5 req / 60s by X-Tenant-ID",
        .message = "Hello from multi-tenant endpoint",
    }, .{});
}
