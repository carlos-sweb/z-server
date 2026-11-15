const std = @import("std");
const Io = std.Io;
const z_server = @import("z_server");
const z_db = @import("z_server_db");
const z_cache = @import("z_server_cache");
const z_config = @import("z_server_config");
const z_auth = @import("z_server_auth");
const z_jwt = @import("z_server_jwt");

// Exported symbol for verification tooling
pub export fn hello_jwt_HmacSha256() void {
    _ = std.crypto.auth.hmac.sha2.HmacSha256;
}

pub const App = struct {
    auth: *z_auth.Authenticator,
    jwt: *z_jwt.Authenticator,
    pool: *z_db.Pool,
};

fn health(_: *App, _: *z_server.Request, res: *z_server.Response) !void {
    res.content_type = .JSON;
    try res.json(.{ .ok = true }, .{});
}

fn extractJwt(req: *z_server.Request) ?[]const u8 {
    if (req.header("authorization")) |hdr| {
        if (hdr.len >= 7 and std.ascii.startsWithIgnoreCase(hdr, "Bearer ")) {
            const tok = std.mem.trim(u8, hdr[7..], " ");
            if (tok.len > 0) return tok;
        }
    }
    return null;
}

fn whoami(app: *App, req: *z_server.Request, res: *z_server.Response) !void {
    res.content_type = .JSON;
    const token = extractJwt(req) orelse {
        res.status = 401;
        res.header("WWW-Authenticate", "Bearer realm=\"z-server\"");
        try res.json(.{ .@"error" = "missing or invalid authorization header" }, .{});
        return;
    };

    const claims = (try app.jwt.validate(token, res.arena)) orelse {
        res.status = 401;
        res.header("WWW-Authenticate", "Bearer realm=\"z-server\"");
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    };

    if (!claims.hasScope("read:whoami")) {
        res.status = 403;
        try res.json(.{ .@"error" = "insufficient permissions" }, .{});
        return;
    }

    try res.json(.{
        .sub = claims.sub,
        .scopes = claims.scope,
        .jti = claims.jti,
    }, .{});
}

fn tokenEndpoint(app: *App, req: *z_server.Request, res: *z_server.Response) !void {
    res.content_type = .JSON;
    var api_key: ?[]const u8 = null;

    // 1. Check Authorization: Bearer <api_key> header
    if (req.header("authorization")) |hdr| {
        if (hdr.len >= 7 and std.ascii.startsWithIgnoreCase(hdr, "Bearer ")) {
            const key = std.mem.trim(u8, hdr[7..], " ");
            if (key.len > 0) api_key = key;
        }
    }

    // 2. Check X-API-Key header
    if (api_key == null) {
        if (req.header("x-api-key")) |hdr| {
            const key = std.mem.trim(u8, hdr, " ");
            if (key.len > 0) api_key = key;
        }
    }

    // 3. Fallback: check JSON body {"api_key": "..."}
    if (api_key == null) {
        if (req.body()) |body| {
            if (body.len > 0) {
                const Parsed = struct { api_key: ?[]const u8 = null };
                if (std.json.parseFromSlice(Parsed, res.arena, body, .{ .ignore_unknown_fields = true })) |p| {
                    api_key = p.value.api_key;
                } else |_| {}
            }
        }
    }

    const key = api_key orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing api_key in authorization header or json body" }, .{});
        return;
    };

    // Validate API key via z_server_auth
    const ctx = (try app.auth.validate(key, res.arena)) orelse {
        res.status = 401;
        res.header("WWW-Authenticate", "Bearer realm=\"z-server\"");
        try res.json(.{ .@"error" = "invalid api key" }, .{});
        return;
    };

    // Issue 15-minute JWT via z_server_jwt
    const jwt_token = try app.jwt.issue(res.arena, ctx.user_id, ctx.scopes, 900);

    try res.json(.{
        .token = jwt_token,
        .token_type = "Bearer",
        .expires_in = 900,
    }, .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    z_db.initLibrary();

    var create_key_cmd = false;
    var issue_jwt_cmd = false;
    var name_arg: []const u8 = "ci";
    var scopes_arg: []const u8 = "read:whoami";
    var ttl_arg: u32 = 900;
    var config_path: ?[]const u8 = "config.json";

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // executable
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "create-key") or std.mem.eql(u8, arg, "--create-key")) {
            create_key_cmd = true;
        } else if (std.mem.eql(u8, arg, "issue-jwt") or std.mem.eql(u8, arg, "--issue-jwt")) {
            issue_jwt_cmd = true;
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--sub")) {
            if (args_it.next()) |n| name_arg = n;
        } else if (std.mem.eql(u8, arg, "--scopes") or std.mem.eql(u8, arg, "-s")) {
            if (args_it.next()) |s| scopes_arg = s;
        } else if (std.mem.eql(u8, arg, "--ttl")) {
            if (args_it.next()) |t| {
                ttl_arg = std.fmt.parseInt(u32, t, 10) catch 900;
            }
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

    const jwt_sec = blk: {
        if (std.c.getenv("Z_SERVER_JWT_SECRET")) |ptr| {
            const s = std.mem.span(ptr);
            if (s.len >= 32) break :blk s;
        }
        std.log.err("missing or invalid Z_SERVER_JWT_SECRET (must be >= 32 bytes)", .{});
        return error.MissingJwtSecret;
    };

    var jwt = try z_jwt.Authenticator.init(gpa, io, &pool, .{
        .secret = jwt_sec,
        .ttl_seconds = cfg.jwt.ttl_seconds,
        .cache = &cache,
        .require_https = cfg.jwt.require_https,
    });
    defer jwt.deinit();

    if (create_key_cmd) {
        const created = try auth.createKey(.{
            .user_id = name_arg,
            .scopes = scopes_arg,
            .env = .live,
        });

        var out_buf: [256]u8 = undefined;
        var f_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
        const out = &f_writer.interface;
        try out.print("{s}\n", .{created.plaintext()});
        try out.flush();
        return;
    }

    if (issue_jwt_cmd) {
        const token = try jwt.issue(gpa, name_arg, scopes_arg, ttl_arg);
        defer gpa.free(token);

        var out_buf: [4096]u8 = undefined;
        var f_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
        const out = &f_writer.interface;
        try out.print("{s}\n", .{token});
        try out.flush();
        return;
    }

    try cfg.validate();

    var app = App{
        .auth = &auth,
        .jwt = &jwt,
        .pool = &pool,
    };

    var server = try z_server.ServerT(*App).initWithContext(gpa, io, .{
        .bind = cfg.server.bind,
        .workers = 1,
        .handler_threads = 4,
        .routes = &.{
            .{ .method = .GET, .path = "/health", .handler = health },
            .{ .method = .GET, .path = "/whoami", .handler = whoami },
            .{ .method = .POST, .path = "/token", .handler = tokenEndpoint },
        },
    }, &app);
    defer server.deinit();

    try server.serve();
}
