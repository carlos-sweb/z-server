const std = @import("std");
const Io = std.Io;
const z_server = @import("z_server");
const z_db = @import("z_server_db");
const z_cache = @import("z_server_cache");
const z_config = @import("z_server_config");
const z_auth = @import("z_server_auth");

pub const App = struct {
    auth: *z_auth.Authenticator,
    pool: *z_db.Pool,
};

fn health(_: *App, _: *z_server.Request, res: *z_server.Response) !void {
    res.content_type = .JSON;
    try res.json(.{ .ok = true }, .{});
}

fn whoami(app: *App, req: *z_server.Request, res: *z_server.Response) !void {
    res.content_type = .JSON;
    const key = z_auth.extractKey(req, true) orelse {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    };
    const ctx = (try app.auth.validate(key, res.arena)) orelse {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    };
    try res.json(.{
        .key_id = ctx.key_id,
        .user_id = ctx.user_id,
        .scopes = ctx.scopes,
    }, .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    z_db.initLibrary();

    // Parse CLI arguments
    var create_key_cmd = false;
    var key_name: []const u8 = "admin";
    var key_scopes: []const u8 = "read:whoami";
    var config_path: ?[]const u8 = "config.json";

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // executable
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "create-key") or std.mem.eql(u8, arg, "--create-key")) {
            create_key_cmd = true;
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--user")) {
            if (args_it.next()) |n| key_name = n;
        } else if (std.mem.eql(u8, arg, "--scopes") or std.mem.eql(u8, arg, "-s")) {
            if (args_it.next()) |s| key_scopes = s;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            config_path = args_it.next();
        }
    }

    var cfg = if (config_path) |cp|
        z_config.load(gpa, cp) catch |err| {
            std.log.err("failed to load config file: {s}", .{@errorName(err)});
            return err;
        }
    else
        z_config.Config{};
    defer cfg.deinit();

    cfg.applyEnvOverrides(init.environ_map) catch {};

    var pool = try z_db.Pool.init(gpa, io, .{
        .path = cfg.sqlite.path,
        .pool_size = 4,
    });
    defer pool.deinit();

    var cache = try z_cache.Cache.init(gpa, cfg.cache.nshards);
    defer cache.deinit();

    const pepper_val = cfg.auth.pepper orelse blk: {
        if (std.c.getenv("Z_SERVER_AUTH_PEPPER")) |ptr| {
            break :blk std.mem.span(ptr);
        }
        std.log.err("missing Z_SERVER_AUTH_PEPPER environment variable", .{});
        return error.MissingPepper;
    };

    var auth = try z_auth.Authenticator.init(gpa, io, &pool, .{
        .pepper = pepper_val,
        .cache = &cache,
        .require_https = cfg.auth.require_https,
        .allow_x_api_key = true,
    });
    defer auth.deinit();

    if (create_key_cmd) {
        const created = try auth.createKey(.{
            .user_id = key_name,
            .scopes = key_scopes,
            .env = .live,
        });

        var out_buf: [256]u8 = undefined;
        var f_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
        const out = &f_writer.interface;
        try out.print("{s}\n", .{created.plaintext()});
        try out.flush();
        return;
    }

    try cfg.validate();

    var app = App{
        .auth = &auth,
        .pool = &pool,
    };

    var server = try z_server.ServerT(*App).initWithContext(gpa, io, .{
        .bind = cfg.server.bind,
        .workers = 1,
        .handler_threads = 4,
        .routes = &.{
            .{ .method = .GET, .path = "/health", .handler = health },
            .{ .method = .GET, .path = "/whoami", .handler = z_auth.wrap("read:whoami", whoami) },
        },
    }, &app);
    defer server.deinit();

    try server.serve();
}
