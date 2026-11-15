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
    allocator: std.mem.Allocator,
    io: std.Io,
    handler_threads: u16,
    sqlite_pool: u16,
};

var server_instance: ?*z_server.ServerT(*App) = null;
var tls_server_instance: ?*tls_server.TlsServer = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

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

    // CLI Argument parsing
    var config_path: ?[]const u8 = init.environ_map.get("Z_SERVER_CONFIG");
    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // executable
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            config_path = args_it.next();
        }
    }

    var cfg: config.Config = blk: {
        if (config_path) |cp| {
            break :blk config.load(gpa, cp) catch |err| {
                std.log.err("failed to load config file '{s}': {s}", .{ cp, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            break :blk config.Config{};
        }
    };
    defer cfg.deinit();

    cfg.applyEnvOverrides(init.environ_map) catch |err| {
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

    const synch_c = try gpa.dupeSentinel(u8, cfg.sqlite.synchronous, 0);
    defer gpa.free(synch_c);
    _ = c.setenv("Z_SERVER_SQLITE_SYNCHRONOUS", synch_c, 1);

    var app = App{
        .db = try z_server_db.Pool.init(gpa, io, .{
            .path = cfg.sqlite.path,
            .pool_size = sqlite_pool_count,
        }),
        .cache = try cache_mod.Cache.init(gpa, cfg.cache.nshards),
        .allocator = gpa,
        .io = io,
        .handler_threads = thread_pool_count,
        .sqlite_pool = sqlite_pool_count,
    };

    var server = try z_server.ServerT(*App).initWithContext(gpa, io, .{
        .bind = cfg.server.bind,
        .workers = 1,
        .handler_threads = thread_pool_count,
        .max_body_size = cfg.server.max_body_size,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/health", .handler = health },
            .{ .method = .GET, .path = "/internal/sync-check", .handler = syncCheck },
            .{ .method = .GET, .path = "/items", .handler = items.list },
            .{ .method = .GET, .path = "/items/:id", .handler = items.getItem },
            .{ .method = .POST, .path = "/items", .handler = items.create },
            .{ .method = .PUT, .path = "/items/:id", .handler = items.putItem },
            .{ .method = .DELETE, .path = "/items/:id", .handler = items.deleteItem },
        },
    }, &app);
    defer server.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("z-server {s}\n", .{version.version});
    try stdout.print("sqlite3 {s}\n", .{z_server_db.libversion()});
    try stdout.print("handler_threads {d}\n", .{thread_pool_count});
    try stdout.print("sqlite_pool {d}\n", .{sqlite_pool_count});
    try stdout.print("listening on {s}:{d}\n", .{ bind.host, bind.port });
    if (cfg.tls.enabled) {
        try stdout.print("tls listening on {s}\n", .{cfg.tls.bind});
    }
    try stdout.flush();

    var tls_srv: ?*tls_server.TlsServer = null;
    if (cfg.tls.enabled) {
        tls_srv = tls_server.TlsServer.init(gpa, cfg.tls, bind.port) catch |err| {
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

/// `Z_SERVER_HANDLER_THREADS` overrides the fallback.
/// Fallback is clamp(2*nproc, 4, 16). nproc in a rootless cgroup does **not**
/// reflect cpu.max (e.g. nproc=8 with cpu.max=1). Prefer the env var in
/// containers.
pub fn handlerThreadCount(spec: ?[]const u8) u16 {
    if (parsePositiveU16(spec, "Z_SERVER_HANDLER_THREADS")) |n| return n;
    const nproc = std.Thread.getCpuCount() catch 2;
    const doubled = 2 * nproc;
    if (doubled < 4) return 4;
    if (doubled > 16) return 16;
    return @intCast(doubled);
}

/// `Z_SERVER_SQLITE_POOL` overrides the fallback (same as handler thread count).
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
