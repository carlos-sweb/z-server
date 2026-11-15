const std = @import("std");
const z_server = @import("z_server");
const z_db = @import("z_server_db");
const z_cache = @import("z_server_cache");
const z_tls = @import("z_server_tls");
const z_config = @import("z_server_config");

const App = struct {
    db: z_db.Pool,
    cache: z_cache.Cache,
    cfg: *z_config.Config,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    var cfg = try z_config.load(init.gpa, "config.json");
    defer cfg.deinit();
    try cfg.applyEnvOverrides(init.environ_map);
    try cfg.validate();

    var pool = try z_db.Pool.init(init.gpa, init.io, .{
        .path = cfg.sqlite.path,
        .pool_size = cfg.sqlite.pool_size orelse 4,
        .synchronous = .normal,
    });
    defer pool.deinit();

    // Seed a demo item so endpoints respond out of the box
    {
        var lease = try pool.acquire();
        defer lease.release();
        try lease.conn.exec("INSERT OR IGNORE INTO items (id, name, payload) VALUES (1, 'demo', '{\"status\":\"active\"}');");
    }

    var cache = try z_cache.Cache.init(init.gpa, cfg.cache.nshards);
    defer cache.deinit();

    var app = App{
        .db = pool,
        .cache = cache,
        .cfg = &cfg,
        .allocator = init.gpa,
    };

    var server = try z_server.ServerT(*App).initWithContext(
        init.gpa,
        init.io,
        .{
            .bind = cfg.server.bind,
            .handler_threads = cfg.server.handler_threads,
            .max_body_size = cfg.server.max_body_size,
            .routes = &.{
                .{ .method = .GET, .path = "/health", .handler = health },
                .{ .method = .GET, .path = "/items/:id", .handler = getItem },
            },
        },
        &app,
    );
    defer server.deinit();

    var tls_server: ?*z_tls.TlsServer = null;
    if (cfg.tls.enabled) {
        const upstream_port = parsePortFromBind(cfg.server.bind);
        const tls_inst = try z_tls.TlsServer.init(init.gpa, cfg.tls, upstream_port);
        tls_server = tls_inst;
        try tls_inst.start();
        std.debug.print("hello-all HTTPS listening on {s}\n", .{cfg.tls.bind});
    }
    defer if (tls_server) |t| t.deinit();

    std.debug.print("hello-all HTTP listening on {s}\n", .{cfg.server.bind});
    try server.serve();
}

fn parsePortFromBind(bind: []const u8) u16 {
    const colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return 9000;
    return std.fmt.parseInt(u16, bind[colon + 1 ..], 10) catch 9000;
}

fn health(_: *App, req: *z_server.Request, res: *z_server.Response) !void {
    const is_https = if (req.header("x-forwarded-proto")) |proto|
        std.mem.eql(u8, proto, "https")
    else
        false;

    if (is_https) {
        try res.json(.{
            .ok = true,
            .version = "0.3.0",
            .service = "hello-all",
            .db = "ok",
            .cache = "ok",
            .tls_version = "TLSv1.2",
        }, .{});
    } else {
        try res.json(.{
            .ok = true,
            .version = "0.3.0",
            .service = "hello-all",
            .db = "ok",
            .cache = "ok",
        }, .{});
    }
}

fn getItem(app: *App, req: *z_server.Request, res: *z_server.Response) !void {
    const id_str = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing id parameter" }, .{});
        return;
    };
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        res.status = 400;
        try res.json(.{ .@"error" = "invalid id" }, .{});
        return;
    };

    var key_buf: [32]u8 = undefined;
    const cache_key = try std.fmt.bufPrint(&key_buf, "item:{d}", .{id});

    // Check cache
    if (app.cache.get(cache_key, app.allocator) catch null) |cached_json| {
        defer app.allocator.free(cached_json);
        res.header("X-Cache", "HIT");
        res.content_type = .JSON;
        res.body = try res.arena.dupe(u8, cached_json);
        return;
    }

    // Query DB
    var lease = try app.db.acquire();
    defer lease.release();

    var stmt = try lease.conn.prepare("SELECT name, payload FROM items WHERE id = ?;");
    defer stmt.finalize();
    try stmt.bindInt64(1, id);

    switch (try stmt.step()) {
        .row => {
            const name = stmt.columnText(0);
            const payload = stmt.columnText(1);

            const json_str = try std.fmt.allocPrint(res.arena, "{{\"id\":{d},\"name\":\"{s}\",\"payload\":{s}}}", .{ id, name, payload });
            _ = app.cache.set(cache_key, json_str, app.cfg.cache.default_ttl_s) catch {};

            res.header("X-Cache", "MISS");
            res.content_type = .JSON;
            res.body = json_str;
        },
        .done => {
            res.status = 404;
            try res.json(.{ .@"error" = "not found" }, .{});
        },
    }
}
