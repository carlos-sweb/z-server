const std = @import("std");
const impl = @import("impl.zig");

pub const Authenticator = impl.Authenticator;
pub const AuthContext = impl.AuthContext;
pub const maskKey = impl.maskKey;

pub const MiddlewareOptions = struct {
    require_https: bool = false,
    allow_x_api_key: bool = true,
    realm: []const u8 = "z-server",
};

pub const AuthMiddleware = struct {
    auth: *Authenticator,
    options: MiddlewareOptions = .{},

    pub fn init(auth: *Authenticator, options: MiddlewareOptions) AuthMiddleware {
        return .{
            .auth = auth,
            .options = options,
        };
    }

    pub fn extractKey(self: AuthMiddleware, req: anytype) ?[]const u8 {
        return extractKeyFromReq(req, self.options.allow_x_api_key);
    }

    pub fn authenticate(
        self: AuthMiddleware,
        req: anytype,
        res: anytype,
        allocator: std.mem.Allocator,
        required_scope: ?[]const u8,
    ) !?AuthContext {
        // S4: soft HTTPS check
        if (self.options.require_https) {
            const proto = req.header("x-forwarded-proto") orelse "";
            if (!std.ascii.eqlIgnoreCase(proto, "https")) {
                res.status = 403;
                try res.json(.{ .@"error" = "https required" }, .{});
                return null;
            }
        }

        const key = self.extractKey(req) orelse {
            res.status = 401;
            res.header("WWW-Authenticate", "Bearer realm=\"z-server\"");
            try res.json(.{ .@"error" = "missing or invalid authorization header" }, .{});
            return null;
        };

        const ctx = (try self.auth.validate(key, allocator)) orelse {
            res.status = 401;
            res.header("WWW-Authenticate", "Bearer realm=\"z-server\"");
            try res.json(.{ .@"error" = "unauthorized" }, .{});
            return null;
        };

        if (required_scope) |scope| {
            if (!ctx.hasScope(scope)) {
                res.status = 403;
                try res.json(.{ .@"error" = "insufficient permissions" }, .{});
                return null;
            }
        }

        return ctx;
    }
};

pub fn extractKey(req: anytype, allow_x_api_key: bool) ?[]const u8 {
    return extractKeyFromReq(req, allow_x_api_key);
}

fn extractKeyFromReq(req: anytype, allow_x_api_key: bool) ?[]const u8 {
    if (req.header("authorization")) |auth_hdr| {
        if (auth_hdr.len >= 7 and std.ascii.startsWithIgnoreCase(auth_hdr, "Bearer ")) {
            const key = std.mem.trim(u8, auth_hdr[7..], " ");
            if (key.len > 0) return key;
        }
    }
    if (allow_x_api_key) {
        if (req.header("x-api-key")) |key_hdr| {
            const key = std.mem.trim(u8, key_hdr, " ");
            if (key.len > 0) return key;
        }
    }
    return null;
}

pub fn wrap(
    comptime required_scope: []const u8,
    comptime target: anytype,
) *const fn (@typeInfo(@TypeOf(target)).@"fn".param_types[0].?, @typeInfo(@TypeOf(target)).@"fn".param_types[1].?, @typeInfo(@TypeOf(target)).@"fn".param_types[2].?) anyerror!void {
    const TargetFn = @TypeOf(target);
    const fn_info = @typeInfo(TargetFn).@"fn";
    const H = fn_info.param_types[0].?;
    const ReqType = fn_info.param_types[1].?;
    const ResType = fn_info.param_types[2].?;

    const Wrapper = struct {
        fn handle(app_ctx: H, req: ReqType, res: ResType) anyerror!void {
            if (@hasField(@typeInfo(H).pointer.child, "auth")) {
                const auth_val = app_ctx.auth;
                const auth_ptr: ?*Authenticator = switch (@typeInfo(@TypeOf(auth_val))) {
                    .pointer => auth_val,
                    .optional => auth_val,
                    else => null,
                };
                if (auth_ptr) |a| {
                    const mw = AuthMiddleware.init(a, .{
                        .require_https = a.options.require_https,
                        .allow_x_api_key = a.options.allow_x_api_key,
                    });
                    const ctx = (try mw.authenticate(req, res, res.arena, required_scope)) orelse return;
                    _ = ctx;
                }
            }
            return target(app_ctx, req, res);
        }
    };
    return &Wrapper.handle;
}
