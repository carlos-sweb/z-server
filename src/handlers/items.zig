const std = @import("std");
const httpz = @import("httpz");
const sqlite = @import("z_server_db");
const limits = @import("../cache/limits.zig");

const App = @import("../main.zig").App;

const busy_delays_ms = [_]u64{ 2, 5, 10, 20, 50 };

pub fn list(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    // Uncached on purpose (last 100 rows, no X-Cache). HIT/MISS is only on GET /items/:id.
    const rows = retry(app, listOnce, .{ app, res.arena }) catch |err| {
        return sendBusyOrError(res, err);
    };
    try res.json(rows, .{});
}

pub fn getItem(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = parseId(req, res) catch return;
    const key = try std.fmt.allocPrint(res.arena, "item:{d}", .{id});

    const cached = app.cache.get(key, res.arena) catch |err| switch (err) {
        error.CacheNoMem, error.CacheIo, error.Other => null,
        else => return err,
    };
    if (cached) |body| {
        res.header("X-Cache", "HIT");
        res.content_type = .JSON;
        res.body = body;
        return;
    }

    const item = retry(app, getOnce, .{ app, res.arena, id }) catch |err| {
        return sendBusyOrError(res, err);
    };
    const row = item orelse {
        res.status = 404;
        try res.json(.{ .@"error" = "not found" }, .{});
        return;
    };

    const body_json = try std.json.Stringify.valueAlloc(res.arena, row, .{});
    res.header("X-Cache", "MISS");
    res.content_type = .JSON;
    res.body = body_json;

    if (body_json.len <= limits.MAX_VALUE_BYTES) {
        app.cache.set(key, body_json, limits.CACHE_TTL_SECONDS) catch |err| {
            std.log.warn("cache set failed for {s}: {}", .{ key, err });
        };
    }
}

pub fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const parsed = parseCreateBody(req) catch {
        res.status = 400;
        try res.json(.{ .@"error" = "invalid json" }, .{});
        return;
    };

    const id = retry(app, insertOnce, .{ app, parsed.name, parsed.payload }) catch |err| {
        return sendBusyOrError(res, err);
    };
    res.status = 201;
    try res.json(.{ .id = id }, .{});
}

pub fn putItem(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = parseId(req, res) catch return;
    const parsed = parseCreateBody(req) catch {
        res.status = 400;
        try res.json(.{ .@"error" = "invalid json" }, .{});
        return;
    };

    const changed = retry(app, updateOnce, .{ app, id, parsed.name, parsed.payload }) catch |err| {
        return sendBusyOrError(res, err);
    };
    if (changed == 0) {
        res.status = 404;
        try res.json(.{ .@"error" = "not found" }, .{});
        return;
    }

    const key = try std.fmt.allocPrint(res.arena, "item:{d}", .{id});
    app.cache.delete(key) catch |err| {
        std.log.warn("cache delete failed for {s}: {}", .{ key, err });
    };

    const item = retry(app, getOnce, .{ app, res.arena, id }) catch |err| {
        return sendBusyOrError(res, err);
    };
    const row = item orelse {
        res.status = 404;
        try res.json(.{ .@"error" = "not found" }, .{});
        return;
    };
    const body_json = try std.json.Stringify.valueAlloc(res.arena, row, .{});
    res.content_type = .JSON;
    res.body = body_json;
}

pub fn deleteItem(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = parseId(req, res) catch return;
    const changed = retry(app, deleteOnce, .{ app, id }) catch |err| {
        return sendBusyOrError(res, err);
    };
    if (changed == 0) {
        res.status = 404;
        try res.json(.{ .@"error" = "not found" }, .{});
        return;
    }

    const key = try std.fmt.allocPrint(res.arena, "item:{d}", .{id});
    app.cache.delete(key) catch |err| {
        std.log.warn("cache delete failed for {s}: {}", .{ key, err });
    };
    res.status = 204;
}

fn parseId(req: *httpz.Request, res: *httpz.Response) !u32 {
    const id_str = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing id" }, .{});
        return error.InvalidId;
    };
    return std.fmt.parseInt(u32, id_str, 10) catch {
        res.status = 400;
        try res.json(.{ .@"error" = "invalid id" }, .{});
        return error.InvalidId;
    };
}

const CreateBody = struct {
    name: []const u8,
    payload: []const u8,
};

fn parseCreateBody(req: *httpz.Request) !CreateBody {
    const value = try req.jsonValue() orelse return error.InvalidJson;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };
    const name_val = obj.get("name") orelse return error.InvalidJson;
    const name = switch (name_val) {
        .string => |s| s,
        else => return error.InvalidJson,
    };
    const payload_val = obj.get("payload") orelse return error.InvalidJson;
    if (payload_val != .object) return error.InvalidJson;
    const payload = try std.json.Stringify.valueAlloc(req.arena, payload_val, .{});
    return .{ .name = name, .payload = payload };
}

const ListRow = struct {
    id: i64,
    name: []const u8,
    created_at: i64,
};

const ItemRow = struct {
    id: i64,
    name: []const u8,
    payload: std.json.Value,
    created_at: i64,
    updated_at: i64,
};

fn listOnce(app: *App, allocator: std.mem.Allocator) ![]ListRow {
    var lease = try app.db.acquire();
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = try conn.prepare(
        "SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 100;",
    );
    defer stmt.finalize();

    var rows: std.ArrayList(ListRow) = .empty;
    while (try stmt.step() == .row) {
        try rows.append(allocator, .{
            .id = stmt.columnInt64(0),
            .name = try stmt.copyText(1, allocator),
            .created_at = stmt.columnInt64(2),
        });
    }
    return rows.items;
}

fn getOnce(app: *App, allocator: std.mem.Allocator, id: u32) !?ItemRow {
    var lease = try app.db.acquire();
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = try conn.prepare(
        "SELECT id, name, payload, created_at, updated_at FROM items WHERE id = ?;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    if (try stmt.step() != .row) return null;

    const payload_text = try stmt.copyText(2, allocator);
    const payload = std.json.parseFromSliceLeaky(std.json.Value, allocator, payload_text, .{}) catch
        std.json.Value{ .string = payload_text };

    return .{
        .id = stmt.columnInt64(0),
        .name = try stmt.copyText(1, allocator),
        .payload = payload,
        .created_at = stmt.columnInt64(3),
        .updated_at = stmt.columnInt64(4),
    };
}

fn insertOnce(app: *App, name: []const u8, payload: []const u8) !i64 {
    var lease = try app.db.acquire();
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = try conn.prepare("INSERT INTO items (name, payload) VALUES (?, ?);");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, payload);
    _ = try stmt.step();
    return conn.lastInsertRowid();
}

fn updateOnce(app: *App, id: u32, name: []const u8, payload: []const u8) !i32 {
    var lease = try app.db.acquire();
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = try conn.prepare(
        "UPDATE items SET name = ?, payload = ?, updated_at = unixepoch() WHERE id = ?;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, payload);
    try stmt.bindInt64(3, id);
    _ = try stmt.step();
    return conn.changes();
}

fn deleteOnce(app: *App, id: u32) !i32 {
    var lease = try app.db.acquire();
    defer lease.deinit();
    const conn = lease.conn;
    var stmt = try conn.prepare("DELETE FROM items WHERE id = ?;");
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    _ = try stmt.step();
    return conn.changes();
}

fn retry(app: *App, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    var attempt: usize = 0;
    while (true) {
        return @call(.auto, func, args) catch |err| switch (err) {
            error.Busy, error.BusyTimeout => {
                if (attempt >= busy_delays_ms.len) return err;
                app.io.sleep(.fromMilliseconds(@intCast(busy_delays_ms[attempt])), .awake) catch {};
                attempt += 1;
                continue;
            },
            else => return err,
        };
    }
}

fn sendBusyOrError(res: *httpz.Response, err: anyerror) !void {
    switch (err) {
        error.Busy, error.BusyTimeout, error.PoolTimeout, error.PoolClosed => {
            res.status = 503;
            res.header("Retry-After", "1");
            try res.json(.{ .@"error" = "busy" }, .{});
        },
        else => return err,
    }
}
