const std = @import("std");
const z_server = @import("z_server");
const z_tls = @import("z_server_tls");

const cert_pem = @embedFile("cert.pem");
const key_pem = @embedFile("key.pem");

pub fn main(init: std.process.Init) !void {
    var server = try z_server.Server.init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = handleRoot },
        },
    });
    defer server.deinit();

    var tls_server = try z_tls.TlsServer.init(init.gpa, .{
        .bind = "127.0.0.1:9443",
        .cert = z_tls.CertSource{
            .pem_bytes = .{
                .cert_pem = cert_pem,
                .key_pem = key_pem,
            },
        },
        .max_conns = 256,
    }, 9000);
    defer tls_server.deinit();

    try tls_server.start();

    std.debug.print("hello-tls HTTP listening on 127.0.0.1:9000\n", .{});
    std.debug.print("hello-tls HTTPS listening on 127.0.0.1:9443\n", .{});

    try server.serve();
}

fn handleRoot(req: *z_server.Request, res: *z_server.Response) !void {
    const is_https = if (req.header("x-forwarded-proto")) |proto|
        std.mem.eql(u8, proto, "https")
    else
        false;

    if (is_https) {
        try res.json(.{
            .service = "hello-tls",
            .secure = true,
            .tls_version = "TLSv1.2",
        }, .{});
    } else {
        try res.json(.{
            .service = "hello-tls",
            .secure = false,
        }, .{});
    }
}
