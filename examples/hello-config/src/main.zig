const std = @import("std");
const z_server = @import("z_server");
const z_config = @import("z_server_config");

const App = struct {
    config: z_config.Config,
};

pub fn main(init: std.process.Init) !void {
    const config_path = "config.json";

    var cfg = z_config.load(init.gpa, config_path) catch |err| {
        std.debug.print("failed to load config from '{s}': {s}\n", .{ config_path, @errorName(err) });
        return err;
    };
    defer cfg.deinit();

    cfg.applyEnvOverrides(init.environ_map) catch |err| {
        std.debug.print("failed to apply env overrides: {s}\n", .{@errorName(err)});
        return err;
    };

    try cfg.validate();

    var app = App{
        .config = cfg,
    };

    var server = try z_server.ServerT(*App).init(init.gpa, init.io, .{
        .bind = cfg.server.bind,
        .handler_threads = cfg.server.handler_threads,
        .max_body_size = cfg.server.max_body_size,
        .handler_ctx = &app,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
            .{ .method = .GET, .path = "/config", .handler = handleConfig },
        },
    });
    defer server.deinit();

    std.debug.print("hello-config listening on {s}\n", .{cfg.server.bind});
    try server.serve();
}

fn handleRoot(_: *App, _: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .service = "hello-config" }, .{});
}

fn handleConfig(app: *App, _: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{
        .bind = app.config.server.bind,
        .handler_threads = app.config.server.handler_threads,
        .max_body_size = app.config.server.max_body_size,
        .logging_level = app.config.logging.level,
    }, .{});
}
