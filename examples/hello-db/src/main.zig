const std = @import("std");
const z_server = @import("z_server");
const z_db = @import("z_server_db");

const App = struct {
    db: z_db.Pool,
};

pub fn main(init: std.process.Init) !void {
    var db = try z_db.Pool.init(init.gpa, init.io, .{
        .path = "data/hello.db",
        .pool_size = 4,
    });
    defer db.deinit();

    var app = App{ .db = db };

    var server = try z_server.ServerT(*App).init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .handler_ctx = &app,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
            .{ .method = .GET, .path = "/db-check", .handler = handleDbCheck },
        },
    });
    defer server.deinit();

    std.debug.print("hello-db listening on 127.0.0.1:9000\n", .{});
    try server.serve();
}

fn handleRoot(_: *App, _: *z_server.Request, res: *z_server.Response) !void {
    try res.json(.{ .service = "hello-db" }, .{});
}

fn handleDbCheck(app: *App, _: *z_server.Request, res: *z_server.Response) !void {
    var lease = try app.db.acquire();
    defer lease.deinit();

    var stmt = try lease.conn.prepare("SELECT 1;");
    defer stmt.finalize();

    if (try stmt.step() == .row) {
        const val = stmt.columnInt64(0);
        try res.json(.{ .db = "connected", .query_result = val }, .{});
    } else {
        res.status = 500;
    }
}
