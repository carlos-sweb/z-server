const std = @import("std");
const Io = std.Io;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .websocket, .level = .err },
    },
};

const c = @import("c");
const httpz = @import("httpz");
const version = @import("version");
const z_server = @import("z_server");
pub const z_server_db = @import("z_server_db");

pub const Bind = z_server.Bind;
pub const parseBind = z_server.parseBind;

pub const pool = z_server_db;
pub const sqlite = z_server_db;
pub const items = @import("handlers/items.zig");
pub const z_server_cache = @import("z_server_cache");
pub const cache_mod = z_server_cache;
pub const config = @import("z_server_config");
pub const z_server_config = config;
pub const z_server_tls = @import("z_server_tls");
pub const z_server_auth = @import("z_server_auth");
pub const z_server_jwt = @import("z_server_jwt");
pub const zargs = @import("zargs");
pub const tls_pem = z_server_tls.pem;
pub const tls_context = z_server_tls.context;
pub const tls_server = z_server_tls.server;
const procstat = @import("procstat.zig");

const PORT: u16 = 8080;
const DB_PATH: [:0]const u8 = "data/app.db";
const MAX_BODY_SIZE: usize = 64 * 1024;

pub const App = struct {
    db: z_server_db.Pool,
    cache: cache_mod.Cache,
    auth: ?*z_server_auth.Authenticator = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    handler_threads: u16,
    sqlite_pool: u16,
};

var server_instance: ?*z_server.ServerT(*App) = null;
var tls_server_instance: ?*tls_server.TlsServer = null;
var g_io: std.Io = undefined;
var g_env: *std.process.Environ.Map = undefined;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    g_io = init.io;
    g_env = init.environ_map;

    // sqlite3_config must run before any sqlite3_open_v2.
    z_server_db.initLibrary();

    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var it = init.minimal.args.iterate();
    const args = try zargs.collectProcessArgs(gpa, &it);
    defer gpa.free(args);

    const root_cmd = zargs.Commands.Command{
        .name = "z-server",
        .help = "High-performance Zig HTTP/HTTPS server with API Keys and JWT authentication",
        .children = &.{
            .{
                .name = "issue-jwt",
                .help = "Issue a new JWT token and exit",
                .action = runIssueJwt,
            },
            .{
                .name = "create-key",
                .help = "Create a new API key and exit",
                .action = runCreateKey,
            },
            .{
                .name = "init-config",
                .help = "Generate a starter config.json file and exit",
                .action = runInitConfig,
            },
        },
        .action = runServer,
    };

    try zargs.Commands.dispatch(root_cmd, gpa, args);
}

fn printRootHelp() void {
    const usage =
        \\Usage: z-server [command] [options]
        \\
        \\High-performance Zig HTTP/HTTPS server with API Keys and JWT authentication.
        \\
        \\Commands:
        \\  issue-jwt                Issue a new JWT token and exit
        \\  create-key               Create a new API key and exit
        \\  init-config              Generate a starter config.json file and exit
        \\
        \\Options:
        \\  -c, --config <path>      Path to JSON configuration file
        \\  -h, --help               Display this help message and exit
        \\
        \\Environment variables:
        \\  Z_SERVER_CONFIG          Path to config file
        \\  Z_SERVER_AUTH_PEPPER     Secret pepper for API key HMAC (required if auth enabled)
        \\  Z_SERVER_JWT_SECRET      Secret key for HS256 JWT signing (required if jwt enabled)
        \\  Z_SERVER_BIND            Server listen address (e.g. 0.0.0.0:8080)
        \\
    ;
    _ = std.c.write(1, usage.ptr, usage.len);
}

fn printIssueJwtHelp() void {
    const usage =
        \\Usage: z-server issue-jwt [options]
        \\
        \\Issue a signed JWT token (HS256) and output it to stdout.
        \\
        \\Options:
        \\  --sub <subject>          Subject claim (default: admin)
        \\  -s, --scopes <scopes>    Space or comma-separated scopes (default: *)
        \\  --ttl <seconds>          Token time-to-live in seconds (default: 900)
        \\  -c, --config <path>      Path to JSON configuration file
        \\  -h, --help               Display this help message and exit
        \\
        \\Environment variables:
        \\  Z_SERVER_JWT_SECRET      Secret key for HS256 signing (required)
        \\
    ;
    _ = std.c.write(1, usage.ptr, usage.len);
}

fn printCreateKeyHelp() void {
    const usage =
        \\Usage: z-server create-key [options]
        \\
        \\Create a new API key and output the plaintext key to stdout.
        \\
        \\Options:
        \\  -n, --name <name>        User ID or name for the key (default: admin)
        \\  -s, --scopes <scopes>    Space or comma-separated scopes (default: *)
        \\  -c, --config <path>      Path to JSON configuration file
        \\  -h, --help               Display this help message and exit
        \\
        \\Environment variables:
        \\  Z_SERVER_AUTH_PEPPER     Secret pepper for HMAC-SHA256 (required)
        \\
    ;
    _ = std.c.write(1, usage.ptr, usage.len);
}

fn printInitConfigHelp() void {
    const usage =
        \\Usage: z-server init-config [options]
        \\
        \\Generate a starter config.json file.
        \\
        \\Options:
        \\  -o, --output <path>      Output file path (default: config.json)
        \\  -f, --force              Overwrite existing file without prompting
        \\  -h, --help               Display this help message and exit
        \\
    ;
    _ = std.c.write(1, usage.ptr, usage.len);
}

fn runIssueJwt(allocator: std.mem.Allocator, args: []const [:0]const u8) anyerror!void {
    var sub: []const u8 = "admin";
    var scopes: []const u8 = "*";
    var ttl: u32 = 900;
    var config_path: ?[]const u8 = g_env.get("Z_SERVER_CONFIG");

    const specs = &[_]zargs.Simple.OptionSpec{
        .{ .long = "sub", .kind = .value },
        .{ .short = 's', .long = "scopes", .kind = .value },
        .{ .long = "ttl", .kind = .value },
        .{ .short = 'c', .long = "config", .kind = .value },
        .{ .short = 'h', .long = "help", .kind = .flag },
    };

    var parser = zargs.Simple.Parser.init(args, specs);
    while (true) {
        const tok = parser.next();
        switch (tok) {
            .end => break,
        .flag => |f| {
            if (f.short == 'h' or (f.long != null and std.mem.eql(u8, f.long.?, "help"))) {
                printIssueJwtHelp();
                std.process.exit(0);
            }
        },
        .option => |o| {
            if (o.long != null and std.mem.eql(u8, o.long.?, "sub")) {
                sub = o.value;
            } else if ((o.short != null and o.short.? == 's') or (o.long != null and std.mem.eql(u8, o.long.?, "scopes"))) {
                scopes = o.value;
            } else if (o.long != null and std.mem.eql(u8, o.long.?, "ttl")) {
                ttl = std.fmt.parseInt(u32, o.value, 10) catch {
                    std.log.err("invalid --ttl value: {s}", .{o.value});
                    std.process.exit(1);
                };
            } else if ((o.short != null and o.short.? == 'c') or (o.long != null and std.mem.eql(u8, o.long.?, "config"))) {
                config_path = o.value;
            }
        },
        .unknown_option => |u| {
            if (u.long) |l| std.log.err("unknown option --{s}", .{l}) else if (u.short) |s| std.log.err("unknown option -{c}", .{s});
            std.process.exit(1);
        },
        .missing_value => |m| {
            if (m.long) |l| std.log.err("option --{s} requires a value", .{l}) else if (m.short) |s| std.log.err("option -{c} requires a value", .{s});
            std.process.exit(1);
        },
        .unexpected_value => |u| {
            if (u.long) |l| std.log.err("option --{s} does not take a value", .{l});
            std.process.exit(1);
        },
        .positional => |p| {
            std.log.err("unexpected argument '{s}'", .{p});
            std.process.exit(1);
        },
        }
    }

    var cfg: config.Config = blk: {
        if (config_path) |cp| {
            break :blk config.load(allocator, cp) catch |err| {
                std.log.err("failed to load config file '{s}': {s}", .{ cp, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            break :blk config.Config{};
        }
    };
    defer cfg.deinit();

    cfg.applyEnvOverrides(g_env) catch |err| {
        std.log.err("failed to apply env overrides: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const secret_val = blk: {
        if (std.c.getenv("Z_SERVER_JWT_SECRET")) |ptr| {
            const s = std.mem.span(ptr);
            if (s.len >= 32) break :blk s;
        }
        std.log.err("missing or invalid Z_SERVER_JWT_SECRET (must be at least 32 bytes / 256 bits)", .{});
        std.process.exit(1);
    };

    var pool_db = z_server_db.Pool.init(allocator, g_io, .{
        .path = cfg.sqlite.path,
        .pool_size = 2,
    }) catch |err| {
        std.log.err("failed to open database: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer pool_db.deinit();

    var authenticator = z_server_jwt.Authenticator.init(allocator, g_io, &pool_db, .{
        .secret = secret_val,
        .ttl_seconds = ttl,
    }) catch |err| {
        std.log.err("failed to initialize JWT authenticator: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer authenticator.deinit();

    const token = authenticator.issue(allocator, sub, scopes, ttl) catch |err| {
        std.log.err("failed to issue JWT token: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(token);

    var out_buf: [4096]u8 = undefined;
    var f_writer: Io.File.Writer = .init(.stdout(), g_io, &out_buf);
    const out = &f_writer.interface;
    try out.print("{s}\n", .{token});
    try out.flush();
}

fn runCreateKey(allocator: std.mem.Allocator, args: []const [:0]const u8) anyerror!void {
    var key_name: []const u8 = "admin";
    var key_scopes: []const u8 = "*";
    var config_path: ?[]const u8 = g_env.get("Z_SERVER_CONFIG");

    const specs = &[_]zargs.Simple.OptionSpec{
        .{ .short = 'n', .long = "name", .kind = .value },
        .{ .short = 's', .long = "scopes", .kind = .value },
        .{ .short = 'c', .long = "config", .kind = .value },
        .{ .short = 'h', .long = "help", .kind = .flag },
    };

    var parser = zargs.Simple.Parser.init(args, specs);
    while (true) {
        const tok = parser.next();
        switch (tok) {
            .end => break,
        .flag => |f| {
            if (f.short == 'h' or (f.long != null and std.mem.eql(u8, f.long.?, "help"))) {
                printCreateKeyHelp();
                std.process.exit(0);
            }
        },
        .option => |o| {
            if ((o.short != null and o.short.? == 'n') or (o.long != null and std.mem.eql(u8, o.long.?, "name"))) {
                key_name = o.value;
            } else if ((o.short != null and o.short.? == 's') or (o.long != null and std.mem.eql(u8, o.long.?, "scopes"))) {
                key_scopes = o.value;
            } else if ((o.short != null and o.short.? == 'c') or (o.long != null and std.mem.eql(u8, o.long.?, "config"))) {
                config_path = o.value;
            }
        },
        .unknown_option => |u| {
            if (u.long) |l| std.log.err("unknown option --{s}", .{l}) else if (u.short) |s| std.log.err("unknown option -{c}", .{s});
            std.process.exit(1);
        },
        .missing_value => |m| {
            if (m.long) |l| std.log.err("option --{s} requires a value", .{l}) else if (m.short) |s| std.log.err("option -{c} requires a value", .{s});
            std.process.exit(1);
        },
        .unexpected_value => |u| {
            if (u.long) |l| std.log.err("option --{s} does not take a value", .{l});
            std.process.exit(1);
        },
        .positional => |p| {
            std.log.err("unexpected argument '{s}'", .{p});
            std.process.exit(1);
        },
        }
    }

    var cfg: config.Config = blk: {
        if (config_path) |cp| {
            break :blk config.load(allocator, cp) catch |err| {
                std.log.err("failed to load config file '{s}': {s}", .{ cp, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            break :blk config.Config{};
        }
    };
    defer cfg.deinit();

    cfg.applyEnvOverrides(g_env) catch |err| {
        std.log.err("failed to apply env overrides: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var pool_db = z_server_db.Pool.init(allocator, g_io, .{
        .path = cfg.sqlite.path,
        .pool_size = 2,
    }) catch |err| {
        std.log.err("failed to open database: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer pool_db.deinit();

    const pepper_val = cfg.auth.pepper orelse blk: {
        if (std.c.getenv("Z_SERVER_AUTH_PEPPER")) |ptr| {
            break :blk std.mem.span(ptr);
        }
        std.log.err("missing Z_SERVER_AUTH_PEPPER env var", .{});
        std.process.exit(1);
    };

    var authenticator = z_server_auth.Authenticator.init(allocator, g_io, &pool_db, .{
        .pepper = pepper_val,
    }) catch |err| {
        std.log.err("failed to initialize authenticator: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer authenticator.deinit();

    const new_key = authenticator.createKey(.{
        .user_id = key_name,
        .scopes = key_scopes,
        .env = .live,
    }) catch |err| {
        std.log.err("failed to create key: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var out_buf: [256]u8 = undefined;
    var f_writer: Io.File.Writer = .init(.stdout(), g_io, &out_buf);
    const out = &f_writer.interface;
    try out.print("{s}\n", .{new_key.plaintext()});
    try out.flush();
}

fn runInitConfig(allocator: std.mem.Allocator, args: []const [:0]const u8) anyerror!void {
    _ = allocator;
    var output_path: []const u8 = "config.json";
    var force = false;

    const specs = &[_]zargs.Simple.OptionSpec{
        .{ .short = 'o', .long = "output", .kind = .value },
        .{ .short = 'f', .long = "force", .kind = .flag },
        .{ .short = 'h', .long = "help", .kind = .flag },
    };

    var parser = zargs.Simple.Parser.init(args, specs);
    while (true) {
        const tok = parser.next();
        switch (tok) {
            .end => break,
        .flag => |f| {
            if (f.short == 'h' or (f.long != null and std.mem.eql(u8, f.long.?, "help"))) {
                printInitConfigHelp();
                std.process.exit(0);
            } else if (f.short == 'f' or (f.long != null and std.mem.eql(u8, f.long.?, "force"))) {
                force = true;
            }
        },
        .option => |o| {
            if ((o.short != null and o.short.? == 'o') or (o.long != null and std.mem.eql(u8, o.long.?, "output"))) {
                output_path = o.value;
            }
        },
        .unknown_option => |u| {
            if (u.long) |l| std.log.err("unknown option --{s}", .{l}) else if (u.short) |s| std.log.err("unknown option -{c}", .{s});
            std.process.exit(1);
        },
        .missing_value => |m| {
            if (m.long) |l| std.log.err("option --{s} requires a value", .{l}) else if (m.short) |s| std.log.err("option -{c} requires a value", .{s});
            std.process.exit(1);
        },
        .unexpected_value => |u| {
            if (u.long) |l| std.log.err("option --{s} does not take a value", .{l});
            std.process.exit(1);
        },
        .positional => |p| {
            std.log.err("unexpected argument '{s}'", .{p});
            std.process.exit(1);
        },
        }
    }

    const config_template =
        \\{
        \\  "$schema_version": 2,
        \\  "server": {
        \\    "bind": "127.0.0.1:8080",
        \\    "handler_threads": 4,
        \\    "max_body_size": 65536
        \\  },
        \\  "sqlite": {
        \\    "path": "data/app.db",
        \\    "pool_size": 4,
        \\    "synchronous": "NORMAL",
        \\    "busy_timeout_ms": 5000
        \\  },
        \\  "cache": {
        \\    "nshards": 256,
        \\    "default_ttl_s": 60,
        \\    "max_value_bytes": 32768
        \\  },
        \\  "tls": {
        \\    "enabled": false,
        \\    "bind": "0.0.0.0:8443",
        \\    "cert_path": null,
        \\    "key_path": null
        \\  },
        \\  "auth": {
        \\    "enabled": true,
        \\    "require_https": false
        \\  },
        \\  "jwt": {
        \\    "enabled": true,
        \\    "ttl_seconds": 900,
        \\    "require_https": false,
        \\    "denylist_cache_ttl_seconds": 5
        \\  },
        \\  "logging": {
        \\    "level": "info"
        \\  }
        \\}
        \\
    ;

    var path_buf: [4096:0]u8 = undefined;
    if (output_path.len >= path_buf.len) {
        std.log.err("output path too long", .{});
        std.process.exit(1);
    }
    @memcpy(path_buf[0..output_path.len], output_path);
    path_buf[output_path.len] = 0;

    const flags: std.posix.O = if (force)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };

    const fd = std.posix.openatZ(std.posix.AT.FDCWD, &path_buf, flags, 0o644) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.log.err("file '{s}' already exists (use --force to overwrite)", .{output_path});
        } else {
            std.log.err("failed to create file '{s}': {s}", .{ output_path, @errorName(err) });
        }
        std.process.exit(1);
    };
    defer _ = std.os.linux.close(fd);

    const written = std.c.write(fd, config_template.ptr, config_template.len);
    if (written < 0) {
        std.log.err("failed to write to '{s}'", .{output_path});
        std.process.exit(1);
    }

    var out_buf: [256]u8 = undefined;
    var f_writer: Io.File.Writer = .init(.stdout(), g_io, &out_buf);
    const out = &f_writer.interface;
    try out.print("Initialized configuration file at {s}\n", .{output_path});
    try out.flush();
}

fn runServer(allocator: std.mem.Allocator, args: []const [:0]const u8) anyerror!void {
    var config_path: ?[]const u8 = g_env.get("Z_SERVER_CONFIG");

    const specs = &[_]zargs.Simple.OptionSpec{
        .{ .short = 'c', .long = "config", .kind = .value },
        .{ .short = 'h', .long = "help", .kind = .flag },
    };

    var parser = zargs.Simple.Parser.init(args, specs);
    while (true) {
        const tok = parser.next();
        switch (tok) {
            .end => break,
        .flag => |f| {
            if (f.short == 'h' or (f.long != null and std.mem.eql(u8, f.long.?, "help"))) {
                printRootHelp();
                std.process.exit(0);
            }
        },
        .option => |o| {
            if ((o.short != null and o.short.? == 'c') or (o.long != null and std.mem.eql(u8, o.long.?, "config"))) {
                config_path = o.value;
            }
        },
        .unknown_option => |u| {
            if (u.long) |l| std.log.err("unknown option --{s}", .{l}) else if (u.short) |s| std.log.err("unknown option -{c}", .{s});
            std.process.exit(1);
        },
        .missing_value => |m| {
            if (m.long) |l| std.log.err("option --{s} requires a value", .{l}) else if (m.short) |s| std.log.err("option -{c} requires a value", .{s});
            std.process.exit(1);
        },
        .unexpected_value => |u| {
            if (u.long) |l| std.log.err("option --{s} does not take a value", .{l});
            std.process.exit(1);
        },
        .positional => |p| {
            std.log.err("unknown command or argument '{s}'. Run 'z-server --help' for usage.", .{p});
            std.process.exit(1);
        },
        }
    }

    var cfg: config.Config = blk: {
        if (config_path) |cp| {
            break :blk config.load(allocator, cp) catch |err| {
                std.log.err("failed to load config file '{s}': {s}", .{ cp, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            break :blk config.Config{};
        }
    };
    defer cfg.deinit();

    cfg.applyEnvOverrides(g_env) catch |err| {
        std.log.err("failed to apply env overrides: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    cfg.validate() catch |err| {
        std.log.err("config validation failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const thread_pool_count: u16 = if (cfg.server.handler_threads) |t| t else handlerThreadCount(null);
    const sqlite_pool_count: u16 = if (cfg.sqlite.pool_size) |p| p else sqlitePoolSize(null, thread_pool_count);

    const bind = parseBind(cfg.server.bind) catch {
        std.log.err("invalid bind address (want 127.0.0.1:PORT or 0.0.0.0:PORT): {s}", .{cfg.server.bind});
        std.process.exit(2);
    };

    const synch_c = try allocator.dupeSentinel(u8, cfg.sqlite.synchronous, 0);
    defer allocator.free(synch_c);
    _ = c.setenv("Z_SERVER_SQLITE_SYNCHRONOUS", synch_c, 1);

    var app = App{
        .db = try z_server_db.Pool.init(allocator, g_io, .{
            .path = cfg.sqlite.path,
            .pool_size = sqlite_pool_count,
        }),
        .cache = try cache_mod.Cache.init(allocator, cfg.cache.nshards),
        .allocator = allocator,
        .io = g_io,
        .handler_threads = thread_pool_count,
        .sqlite_pool = sqlite_pool_count,
    };

    var authenticator: ?z_server_auth.Authenticator = null;
    if (cfg.auth.enabled) {
        const pepper_val = cfg.auth.pepper orelse blk: {
            if (std.c.getenv("Z_SERVER_AUTH_PEPPER")) |ptr| {
                break :blk std.mem.span(ptr);
            }
            std.log.err("missing Z_SERVER_AUTH_PEPPER env var", .{});
            std.process.exit(1);
        };
        authenticator = z_server_auth.Authenticator.init(allocator, g_io, &app.db, .{
            .pepper = pepper_val,
            .cache = &app.cache,
            .require_https = cfg.auth.require_https and cfg.tls.enabled,
        }) catch |err| {
            std.log.err("failed to initialize Authenticator: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    defer {
        if (authenticator) |*a| a.deinit();
    }
    app.auth = if (authenticator) |*a| a else null;

    var server = try z_server.ServerT(*App).initWithContext(allocator, g_io, .{
        .bind = cfg.server.bind,
        .workers = 1,
        .handler_threads = thread_pool_count,
        .max_body_size = cfg.server.max_body_size,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/health", .handler = health },
            .{ .method = .GET, .path = "/internal/sync-check", .handler = syncCheck },
            .{ .method = .GET, .path = "/items", .handler = wrapAuth("items:read", items.list) },
            .{ .method = .GET, .path = "/items/:id", .handler = wrapAuth("items:read", items.getItem) },
            .{ .method = .POST, .path = "/items", .handler = wrapAuth("items:write", items.create) },
            .{ .method = .PUT, .path = "/items/:id", .handler = wrapAuth("items:write", items.putItem) },
            .{ .method = .DELETE, .path = "/items/:id", .handler = wrapAuth("items:write", items.deleteItem) },
        },
    }, &app);
    defer server.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), g_io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("z-server {s}\n", .{version.version});
    try stdout.print("sqlite3 {s}\n", .{z_server_db.libversion()});
    try stdout.print("handler_threads {d}\n", .{thread_pool_count});
    try stdout.print("sqlite_pool {d}\n", .{sqlite_pool_count});
    try stdout.print("listening on {s}:{d}\n", .{ bind.host, bind.port });
    if (cfg.tls.enabled) {
        try stdout.print("tls listening on {s}\n", .{cfg.tls.bind});
    }
    if (cfg.auth.enabled) {
        try stdout.print("auth: api keys enabled\n", .{});
    }
    try stdout.flush();

    var tls_srv: ?*tls_server.TlsServer = null;
    if (cfg.tls.enabled) {
        tls_srv = tls_server.TlsServer.init(allocator, cfg.tls, bind.port) catch |err| {
            std.log.err("failed to initialize TLS server: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        tls_server_instance = tls_srv;
        tls_srv.?.start() catch |err| {
            std.log.err("failed to start TLS server: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    defer {
        if (tls_srv) |ts| {
            tls_server_instance = null;
            ts.deinit();
        }
    }

    server_instance = &server;
    server.listen() catch |err| switch (err) {
        error.AddressInUse => {
            std.log.err("address {s}:{d} already in use", .{ bind.host, bind.port });
            std.process.exit(2);
        },
        else => return err,
    };
    app.db.deinit();
    app.cache.deinit();
}

fn shutdown(_: std.posix.SIG) callconv(.c) void {
    if (tls_server_instance) |ts| {
        tls_server_instance = null;
        ts.stop();
    }
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}

pub fn handlerThreadCount(spec: ?[]const u8) u16 {
    if (parsePositiveU16(spec, "Z_SERVER_HANDLER_THREADS")) |n| return n;
    const nproc = std.Thread.getCpuCount() catch 2;
    const doubled = 2 * nproc;
    if (doubled < 4) return 4;
    if (doubled > 16) return 16;
    return @intCast(doubled);
}

pub fn sqlitePoolSize(spec: ?[]const u8, handler_threads: u16) u16 {
    if (parsePositiveU16(spec, "Z_SERVER_SQLITE_POOL")) |n| return n;
    return handler_threads;
}

fn parsePositiveU16(spec: ?[]const u8, name: []const u8) ?u16 {
    const value = spec orelse return null;
    const n = std.fmt.parseInt(u16, value, 10) catch {
        std.log.err("invalid {s} (want 1..65535)", .{name});
        std.process.exit(2);
    };
    if (n == 0) {
        std.log.err("invalid {s} (want >= 1)", .{name});
        std.process.exit(2);
    }
    return n;
}

pub fn index(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true }, .{});
}

pub fn health(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const db_ok = checkDb(app);
    const cache_ok = checkCache(app);
    if (!db_ok or !cache_ok) res.status = 503;
    const io_bytes = procstat.ioBytes();
    try res.json(.{
        .ok = db_ok and cache_ok,
        .version = version.version,
        .db = if (db_ok) "ok" else "err",
        .cache = if (cache_ok) "ok" else "err",
        .sqlite_busy_count = sqlite.sqliteBusyCount(),
        .io_read_bytes = io_bytes.read_bytes,
        .io_write_bytes = io_bytes.write_bytes,
        .fd_count = procstat.fdCount(),
        .handler_threads = app.handler_threads,
        .sqlite_pool = app.sqlite_pool,
        .sqlite_synchronous = app.db.synchronous_snapshot,
        .sqlite_synchronous_all_normal = app.db.synchronous_all_normal,
        .sqlite_synchronous_last_check_unix = app.db.synchronous_last_check_unix,
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
    }, .{});
}

pub fn syncCheck(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    app.db.refreshSynchronousSnapshot();
    try res.json(.{
        .sqlite_synchronous = app.db.synchronous_snapshot,
        .sqlite_synchronous_all_normal = app.db.synchronous_all_normal,
        .sqlite_synchronous_last_check_unix = app.db.synchronous_last_check_unix,
    }, .{});
}

fn checkDb(app: *App) bool {
    var lease = app.db.acquire() catch return false;
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = conn.prepare("SELECT 1;") catch return false;
    defer stmt.finalize();
    _ = stmt.step() catch return false;
    return true;
}

fn checkCache(app: *App) bool {
    app.cache.set("healthcheck", "1", 1) catch return false;
    const got = app.cache.get("healthcheck", app.allocator) catch return false;
    const value = got orelse return false;
    defer app.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn wrapAuth(comptime required_scope: []const u8, comptime target: fn (*App, *httpz.Request, *httpz.Response) anyerror!void) fn (*App, *httpz.Request, *httpz.Response) anyerror!void {
    const Wrapper = struct {
        fn handle(app_ptr: *App, req: *httpz.Request, res: *httpz.Response) anyerror!void {
            if (app_ptr.auth) |auth_ptr| {
                const mw = z_server_auth.AuthMiddleware.init(auth_ptr, .{
                    .require_https = auth_ptr.options.require_https,
                    .allow_x_api_key = auth_ptr.options.allow_x_api_key,
                });
                const auth_ctx = (try mw.authenticate(req, res, res.arena, required_scope)) orelse return;
                _ = auth_ctx;
            }
            return target(app_ptr, req, res);
        }
    };
    return Wrapper.handle;
}
