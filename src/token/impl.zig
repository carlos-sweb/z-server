const std = @import("std");
const httpz = @import("httpz");
const z_server_auth = @import("z_server_auth");
const z_server_jwt = @import("z_server_jwt");
const z_server_cache = @import("z_server_cache");
const ratelimit = @import("ratelimit.zig");

pub const Options = struct {
    endpoint_path: []const u8 = "/auth/token",
    rate_limit_ip_per_min: u32 = 30,
    rate_limit_key_per_min: u32 = 60,
    ttl_seconds: u32 = 900,
    cache: ?*z_server_cache.Cache = null,
};

pub const TokenRequest = struct {
    grant_type: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_in: u32,
    scope: []const u8,
};

pub const OAuthError = error{
    InvalidRequest,
    InvalidClient,
    InvalidScope,
    UnsupportedGrantType,
    RateLimited,
};

pub const TokenEndpoint = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    auth: *z_server_auth.Authenticator,
    jwt: *z_server_jwt.Authenticator,
    options: Options,
    limiter: ratelimit.RateLimiter,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: *z_server_auth.Authenticator,
        jwt: *z_server_jwt.Authenticator,
        options: Options,
    ) !TokenEndpoint {
        return TokenEndpoint{
            .allocator = allocator,
            .io = io,
            .auth = auth,
            .jwt = jwt,
            .options = options,
            .limiter = ratelimit.RateLimiter.init(allocator, io, options.cache),
        };
    }

    pub fn deinit(self: *TokenEndpoint) void {
        self.limiter.deinit();
    }

    pub fn handle(self: *TokenEndpoint, req: *httpz.Request, res: *httpz.Response) !void {
        // 1. IP rate limiting
        const client_ip = extractClientIp(req, res.arena);
        const ip_ok = self.limiter.checkAndIncrement(
            .ip,
            client_ip,
            self.options.rate_limit_ip_per_min,
            60,
        ) catch true;
        if (!ip_ok) {
            res.status = 429;
            res.header("Retry-After", "60");
            try res.json(.{ .@"error" = "rate_limited" }, .{});
            return;
        }

        // 2. Parse body JSON if present
        var token_req: TokenRequest = .{};
        if (req.body()) |raw_body| {
            const trimmed = std.mem.trim(u8, raw_body, " \t\r\n");
            if (trimmed.len > 0) {
                const parsed = std.json.parseFromSlice(TokenRequest, res.arena, trimmed, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    res.status = 400;
                    try res.json(.{ .@"error" = "invalid_request" }, .{});
                    return;
                };
                token_req = parsed.value;
            }
        }

        // 3. Extract API key (Authorization: Bearer <key>, X-API-Key, or body api_key)
        var api_key: ?[]const u8 = null;
        if (req.header("authorization")) |auth_hdr| {
            if (auth_hdr.len >= 7 and std.ascii.startsWithIgnoreCase(auth_hdr, "Bearer ")) {
                const k = std.mem.trim(u8, auth_hdr[7..], " \t\r\n");
                if (k.len > 0) api_key = k;
            }
        }
        if (api_key == null) {
            if (req.header("x-api-key")) |k_hdr| {
                const k = std.mem.trim(u8, k_hdr, " \t\r\n");
                if (k.len > 0) api_key = k;
            }
        }
        if (api_key == null) {
            if (token_req.api_key) |k| {
                const k_trimmed = std.mem.trim(u8, k, " \t\r\n");
                if (k_trimmed.len > 0) api_key = k_trimmed;
            }
        }

        const key = api_key orelse {
            res.status = 401;
            res.header("WWW-Authenticate", "Bearer realm=\"z-server\", error=\"invalid_client\"");
            try res.json(.{ .@"error" = "invalid_client" }, .{});
            return;
        };

        // 4. Validate API key with z_server_auth
        const auth_ctx = (try self.auth.validate(key, res.arena)) orelse {
            res.status = 401;
            res.header("WWW-Authenticate", "Bearer realm=\"z-server\", error=\"invalid_client\"");
            try res.json(.{ .@"error" = "invalid_client" }, .{});
            return;
        };

        // 5. API Key rate limiting
        var key_id_buf: [32]u8 = undefined;
        const key_id_str = std.fmt.bufPrint(&key_id_buf, "{d}", .{auth_ctx.key_id}) catch "0";
        const key_ok = self.limiter.checkAndIncrement(
            .api_key,
            key_id_str,
            self.options.rate_limit_key_per_min,
            60,
        ) catch true;
        if (!key_ok) {
            res.status = 429;
            res.header("Retry-After", "60");
            try res.json(.{ .@"error" = "rate_limited" }, .{});
            return;
        }

        // 6. Validate grant_type (RFC 6749 §4.4.2)
        if (token_req.grant_type) |gt| {
            if (!std.mem.eql(u8, gt, "client_credentials")) {
                res.status = 400;
                try res.json(.{ .@"error" = "unsupported_grant_type" }, .{});
                return;
            }
        }

        // 7. Validate scopes / downscoping (RFC 6749 §4.4.2)
        var granted_scopes: []const u8 = auth_ctx.scopes;
        if (token_req.scope) |req_scope| {
            const trimmed_scope = std.mem.trim(u8, req_scope, " \t\r\n");
            if (trimmed_scope.len > 0) {
                var it = std.mem.tokenizeAny(u8, trimmed_scope, " ,");
                var count: usize = 0;
                while (it.next()) |token| {
                    count += 1;
                    if (!auth_ctx.hasScope(token)) {
                        res.status = 400;
                        try res.json(.{ .@"error" = "invalid_scope" }, .{});
                        return;
                    }
                }
                if (count > 0) {
                    granted_scopes = trimmed_scope;
                }
            }
        }

        // 8. Issue JWT
        const access_token = try self.jwt.issue(
            res.arena,
            auth_ctx.user_id,
            granted_scopes,
            self.options.ttl_seconds,
        );

        // 9. Respond 200 with RFC 6749 §5.1 headers & body
        res.status = 200;
        res.header("Cache-Control", "no-store");
        res.header("Pragma", "no-cache");
        res.content_type = .JSON;

        const response = TokenResponse{
            .access_token = access_token,
            .token_type = "Bearer",
            .expires_in = self.options.ttl_seconds,
            .scope = granted_scopes,
        };
        try res.json(response, .{});
    }
};

pub fn extractClientIp(req: *httpz.Request, arena: std.mem.Allocator) []const u8 {
    if (req.header("x-forwarded-for")) |xff| {
        var it = std.mem.splitScalar(u8, xff, ',');
        if (it.next()) |first| {
            const trimmed = std.mem.trim(u8, first, " \t\r\n");
            if (trimmed.len > 0) {
                // If it contains a single colon (IPv4:port), strip port
                if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
                    if (std.mem.indexOfScalar(u8, trimmed, ':') == colon) {
                        return trimmed[0..colon];
                    }
                }
                return trimmed;
            }
        }
    }

    switch (req.address) {
        .ip4 => |ip4| {
            return std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{
                ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
            }) catch "127.0.0.1";
        },
        .ip6 => |ip6| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{}", .{ip6}) catch return "::1";
            return arena.dupe(u8, str) catch "::1";
        },
    }
}
