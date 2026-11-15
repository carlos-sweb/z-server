const std = @import("std");
const httpz = @import("httpz");

pub const Request = httpz.Request;
pub const Response = httpz.Response;
pub const Method = httpz.Method;

pub const Bind = struct {
    address: httpz.Config.Address,
    host: []const u8,
    port: u16,
};

const DEFAULT_PORT: u16 = 8080;

/// Accepts only `127.0.0.1:PORT` and `0.0.0.0:PORT`. `null` is the default.
pub fn parseBind(spec: ?[]const u8) error{InvalidBind}!Bind {
    const value = spec orelse return .{
        .address = .localhost(DEFAULT_PORT),
        .host = "127.0.0.1",
        .port = DEFAULT_PORT,
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

pub fn ServerT(comptime H: type) type {
    return struct {
        const Self = @This();

        pub const Handler = if (H == void)
            *const fn (*Request, *Response) anyerror!void
        else
            *const fn (H, *Request, *Response) anyerror!void;

        pub const Route = struct {
            method: Method,
            path: []const u8,
            handler: Self.Handler,
        };

        pub const Options = struct {
            bind: []const u8 = "127.0.0.1:8080",
            routes: []const Self.Route = &.{},
            handler_threads: ?u16 = null,
            max_body_size: ?usize = 64 * 1024,
            workers: u16 = 1,
        };

        httpz_server: httpz.Server(H),
        allocator: std.mem.Allocator,
        bind_host: []const u8,
        bind_port: u16,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Self.Options) !Self {
            if (H != void) {
                @compileError("Use initWithContext when H != void");
            }
            return initWithContext(allocator, io, options, {});
        }

        pub fn initWithContext(allocator: std.mem.Allocator, io: std.Io, options: Self.Options, ctx: H) !Self {
            const parsed_bind = try parseBind(options.bind);
            var httpz_cfg: httpz.Config = .{
                .address = parsed_bind.address,
                .workers = .{ .count = options.workers },
            };
            if (options.handler_threads) |t| {
                httpz_cfg.thread_pool = .{ .count = t };
            }
            if (options.max_body_size) |m| {
                httpz_cfg.request = .{ .max_body_size = m };
            }

            var server = try httpz.Server(H).init(io, allocator, httpz_cfg, ctx);
            errdefer server.deinit();

            if (options.routes.len > 0) {
                var router_inst = try server.router(.{});
                for (options.routes) |r| {
                    switch (r.method) {
                        .GET => router_inst.get(r.path, r.handler, .{}),
                        .POST => router_inst.post(r.path, r.handler, .{}),
                        .PUT => router_inst.put(r.path, r.handler, .{}),
                        .DELETE => router_inst.delete(r.path, r.handler, .{}),
                        .HEAD => router_inst.head(r.path, r.handler, .{}),
                        .PATCH => router_inst.patch(r.path, r.handler, .{}),
                        .OPTIONS => router_inst.options(r.path, r.handler, .{}),
                        else => router_inst.all(r.path, r.handler, .{}),
                    }
                }
            }

            return .{
                .httpz_server = server,
                .allocator = allocator,
                .bind_host = parsed_bind.host,
                .bind_port = parsed_bind.port,
            };
        }

        pub fn deinit(self: *Self) void {
            self.httpz_server.deinit();
        }

        pub fn router(self: *Self) !httpz.Router(H) {
            return try self.httpz_server.router(.{});
        }

        pub fn serve(self: *Self) !void {
            try self.httpz_server.listen();
        }

        pub fn listen(self: *Self) !void {
            try self.httpz_server.listen();
        }

        pub fn stop(self: *Self) void {
            self.httpz_server.stop();
        }
    };
}

pub const Server = ServerT(void);
pub const Handler = Server.Handler;
pub const Route = Server.Route;
pub const Options = Server.Options;
