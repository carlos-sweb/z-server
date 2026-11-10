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

pub const pool = @import("db/pool.zig");
pub const sqlite = @import("db/sqlite.zig");
pub const items = @import("handlers/items.zig");
pub const cache_mod = @import("cache/pogocache.zig");

const pool_mod = pool;

const PORT: u16 = 8080;
const DB_PATH: [:0]const u8 = "data/app.db";
const MAX_BODY_SIZE: usize = 64 * 1024;

/// Parsed `Z_SERVER_BIND` (`host:port`). Absent env → `127.0.0.1:8080`.
pub const Bind = struct {
    address: httpz.Config.Address,
    host: []const u8,
    port: u16,
};

/// Accepts only `127.0.0.1:PORT` and `0.0.0.0:PORT`. `null` is the default.
pub fn parseBind(spec: ?[]const u8) error{InvalidBind}!Bind {
    const value = spec orelse return .{
        .address = .localhost(PORT),
        .host = "127.0.0.1",
        .port = PORT,
    };

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidBind;
    const host = value[0..colon];
    const port_str = value[colon + 1 ..];
    if (host.len == 0 or port_str.len == 0) return error.InvalidBind;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidBind;

    if (std.mem.eql(u8, host, "0.0.0.0")) {
        return .{ .address = .all(port), .host = "0.0.0.0", .port = port };
    }
    if (std.mem.eql(u8, host, "127.0.0.1")) {
        return .{ .address = .localhost(port), .host = "127.0.0.1", .port = port };
    }
    return error.InvalidBind;
}

pub const App = struct {
    db: pool_mod.Pool,
    cache: cache_mod.Cache,
    allocator: std.mem.Allocator,
    io: std.Io,
};

var server_instance: ?*httpz.Server(*App) = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // sqlite3_config must run before any sqlite3_open_v2.
    if (c.sqlite3_threadsafe() == 0) {
        std.process.fatal("sqlite built without threadsafe", .{});
    }
    _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);

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

    const thread_pool_count = handlerThreadCount();

    const bind = parseBind(init.environ_map.get("Z_SERVER_BIND")) catch {
        std.log.err("invalid Z_SERVER_BIND (want 127.0.0.1:PORT or 0.0.0.0:PORT)", .{});
        std.process.exit(2);
    };

    try std.Io.Dir.cwd().createDirPath(io, "data");

    var app = App{
        .db = try pool_mod.Pool.init(gpa, io, DB_PATH, thread_pool_count),
        .cache = try cache_mod.Cache.init(gpa, 512),
        .allocator = gpa,
        .io = io,
    };

    var server = try httpz.Server(*App).init(io, gpa, .{
        .address = bind.address,
        .workers = .{ .count = 1 },
        .thread_pool = .{ .count = thread_pool_count },
        .request = .{ .max_body_size = MAX_BODY_SIZE },
    }, &app);
    defer server.deinit();

    var router = try server.router(.{});
    router.get("/", index, .{});
    router.get("/health", health, .{});
    router.get("/items", items.list, .{});
    router.get("/items/:id", items.getItem, .{});
    router.post("/items", items.create, .{});
    router.put("/items/:id", items.putItem, .{});
    router.delete("/items/:id", items.deleteItem, .{});

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("z-server {s}\n", .{version.version});
    try stdout.print("sqlite3 {s}\n", .{std.mem.span(c.sqlite3_libversion())});
    try stdout.print("listening on {s}:{d}\n", .{ bind.host, bind.port });
    try stdout.flush();

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
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}

fn handlerThreadCount() u16 {
    const nproc = std.Thread.getCpuCount() catch 2;
    const doubled = 2 * nproc;
    if (doubled < 4) return 4;
    if (doubled > 16) return 16;
    return @intCast(doubled);
}

pub fn index(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true }, .{});
}

pub fn health(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const db_ok = checkDb(app);
    const cache_ok = checkCache(app);
    if (!db_ok or !cache_ok) res.status = 503;
    try res.json(.{
        .ok = db_ok and cache_ok,
        .version = version.version,
        .db = if (db_ok) "ok" else "err",
        .cache = if (cache_ok) "ok" else "err",
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
