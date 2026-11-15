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
        if (req.header("authorization")) |auth_hdr| {
            if (auth_hdr.len >= 7 and std.ascii.startsWithIgnoreCase(auth_hdr, "Bearer ")) {
                const key = std.mem.trim(u8, auth_hdr[7..], " ");
                if (key.len > 0) return key;
            }
        }
        if (self.options.allow_x_api_key) {
            if (req.header("x-api-key")) |key_hdr| {
                const key = std.mem.trim(u8, key_hdr, " ");
                if (key.len > 0) return key;
            }
        }
        return null;
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
