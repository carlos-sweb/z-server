const std = @import("std");
const httpz = @import("httpz");
const z_server_cache = @import("z_server_cache");

pub const LimitBy = union(enum) {
    ip,
    api_key,
    jwt_sub,
    header: []const u8,
    global,
    custom: *const fn (*httpz.Request, *httpz.Response) ?[]const u8,
};

pub const Policy = struct {
    capacity: u32 = 100,
    window_seconds: u32 = 60,
    by: LimitBy = .ip,
    post_auth: ?bool = null, // auto-detect if null

    pub fn isPostAuth(self: Policy) bool {
        if (self.post_auth) |pa| return pa;
        return switch (self.by) {
            .api_key, .jwt_sub => true,
            .ip, .global, .header, .custom => false,
        };
    }

    pub fn refillRate(self: Policy) f64 {
        const cap = @as(f64, @floatFromInt(self.capacity));
        const win = @as(f64, @floatFromInt(@max(1, self.window_seconds)));
        return cap / win;
    }

    pub fn hash(self: Policy) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.capacity));
        hasher.update(std.mem.asBytes(&self.window_seconds));
        const tag = @intFromEnum(@as(std.meta.Tag(LimitBy), self.by));
        hasher.update(std.mem.asBytes(&tag));
        switch (self.by) {
            .header => |hdr| hasher.update(hdr),
            else => {},
        }
        return hasher.final();
    }
};

pub const Decision = struct {
    allowed: bool,
    limit: u32,
    remaining: u32,
    reset_in_s: u32,
    retry_after_s: u32,
};

pub const AuthContext = struct {
    key_id: ?i64 = null,
    sub: ?[]const u8 = null,
};

pub threadlocal var current_auth_context: ?AuthContext = null;

pub fn setAuthContext(ctx: ?AuthContext) void {
    current_auth_context = ctx;
}

pub fn getAuthContext() ?AuthContext {
    return current_auth_context;
}

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    cache: ?*z_server_cache.Cache,
    mutex: std.Io.Mutex,
    map: std.AutoHashMap(MemKey, BucketEntry),
    last_cleanup: i64,

    pub const MemKey = struct {
        policy_hash: u64,
        key_hash: u64,
    };

    pub const BucketEntry = struct {
        tokens: f64,
        last_ts: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: ?std.Io, cache: ?*z_server_cache.Cache) Limiter {
        return .{
            .allocator = allocator,
            .io = io,
            .cache = cache,
            .mutex = .init,
            .map = std.AutoHashMap(MemKey, BucketEntry).init(allocator),
            .last_cleanup = getUnixTimestamp(),
        };
    }

    pub fn deinit(self: *Limiter) void {
        self.map.deinit();
    }

    pub fn check(self: *Limiter, policy: Policy, key_id: []const u8) !Decision {
        const now = getUnixTimestamp();
        const capacity_f = @as(f64, @floatFromInt(policy.capacity));
        const refill_rate = policy.refillRate();
        const p_hash = policy.hash();

        if (policy.capacity == 0) {
            return Decision{
                .allowed = false,
                .limit = 0,
                .remaining = 0,
                .reset_in_s = policy.window_seconds,
                .retry_after_s = @max(1, policy.window_seconds),
            };
        }

        if (self.cache) |c| {
            return self.checkCache(c, policy, p_hash, key_id, capacity_f, refill_rate, now);
        } else {
            return self.checkMem(policy, p_hash, key_id, capacity_f, refill_rate, now);
        }
    }

    fn checkMem(
        self: *Limiter,
        policy: Policy,
        p_hash: u64,
        key_id: []const u8,
        capacity_f: f64,
        refill_rate: f64,
        now: i64,
    ) !Decision {
        if (self.io) |io| self.mutex.lockUncancelable(io);
        defer if (self.io) |io| self.mutex.unlock(io);

        if (now >= self.last_cleanup + 60) {
            self.cleanupLocked(now, policy.window_seconds);
            self.last_cleanup = now;
        }

        const k_hash = std.hash.Wyhash.hash(0, key_id);
        const mem_key = MemKey{ .policy_hash = p_hash, .key_hash = k_hash };

        var tokens: f64 = capacity_f;
        var last_ts: i64 = now;

        if (self.map.get(mem_key)) |entry| {
            const elapsed = @max(0, now - entry.last_ts);
            tokens = @min(capacity_f, entry.tokens + @as(f64, @floatFromInt(elapsed)) * refill_rate);
            last_ts = entry.last_ts;
        }

        var allowed = false;
        var retry_after_s: u32 = 0;

        if (tokens >= 1.0) {
            tokens -= 1.0;
            allowed = true;
            last_ts = now;
        } else {
            allowed = false;
            const needed = 1.0 - tokens;
            const wait_f = needed / refill_rate;
            retry_after_s = @max(1, @as(u32, @intFromFloat(@ceil(wait_f))));
        }

        try self.map.put(mem_key, .{ .tokens = tokens, .last_ts = last_ts });

        const remaining: u32 = @as(u32, @intFromFloat(@max(0.0, @floor(tokens))));
        const missing = capacity_f - tokens;
        const reset_f = if (missing <= 0.0) 0.0 else missing / refill_rate;
        const reset_in_s: u32 = @as(u32, @intFromFloat(@ceil(reset_f)));

        return Decision{
            .allowed = allowed,
            .limit = policy.capacity,
            .remaining = remaining,
            .reset_in_s = reset_in_s,
            .retry_after_s = retry_after_s,
        };
    }

    fn checkCache(
        self: *Limiter,
        c: *z_server_cache.Cache,
        policy: Policy,
        p_hash: u64,
        key_id: []const u8,
        capacity_f: f64,
        refill_rate: f64,
        now: i64,
    ) !Decision {
        var key_buf: [256]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&key_buf, "rl:{x}:{s}", .{ p_hash, key_id }) catch return error.KeyTooLong;

        var tokens: f64 = capacity_f;
        var last_ts: i64 = now;

        if (try c.get(cache_key, self.allocator)) |raw_val| {
            defer self.allocator.free(raw_val);
            if (std.mem.indexOfScalar(u8, raw_val, ':')) |colon| {
                const tok_str = raw_val[0..colon];
                const ts_str = raw_val[colon + 1 ..];
                const parsed_tok = std.fmt.parseFloat(f64, tok_str) catch capacity_f;
                const parsed_ts = std.fmt.parseInt(i64, ts_str, 10) catch now;
                const elapsed = @max(0, now - parsed_ts);
                tokens = @min(capacity_f, parsed_tok + @as(f64, @floatFromInt(elapsed)) * refill_rate);
                last_ts = parsed_ts;
            }
        }

        var allowed = false;
        var retry_after_s: u32 = 0;

        if (tokens >= 1.0) {
            tokens -= 1.0;
            allowed = true;
            last_ts = now;
        } else {
            allowed = false;
            const needed = 1.0 - tokens;
            const wait_f = needed / refill_rate;
            retry_after_s = @max(1, @as(u32, @intFromFloat(@ceil(wait_f))));
        }

        var val_buf: [64]u8 = undefined;
        const new_val = std.fmt.bufPrint(&val_buf, "{d:.4}:{d}", .{ tokens, last_ts }) catch "0:0";
        try c.set(cache_key, new_val, policy.window_seconds * 2);

        const remaining: u32 = @as(u32, @intFromFloat(@max(0.0, @floor(tokens))));
        const missing = capacity_f - tokens;
        const reset_f = if (missing <= 0.0) 0.0 else missing / refill_rate;
        const reset_in_s: u32 = @as(u32, @intFromFloat(@ceil(reset_f)));

        return Decision{
            .allowed = allowed,
            .limit = policy.capacity,
            .remaining = remaining,
            .reset_in_s = reset_in_s,
            .retry_after_s = retry_after_s,
        };
    }

    pub fn cleanup(self: *Limiter, now: i64, window_s: u32) void {
        if (self.io) |io| self.mutex.lockUncancelable(io);
        defer if (self.io) |io| self.mutex.unlock(io);
        self.cleanupLocked(now, window_s);
    }

    fn cleanupLocked(self: *Limiter, now: i64, window_s: u32) void {
        const threshold = now - @as(i64, @intCast(@max(60, window_s * 2)));
        var to_remove = std.ArrayListUnmanaged(MemKey).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_ts < threshold) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (to_remove.items) |k| {
            _ = self.map.remove(k);
        }
    }
};

pub fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}

pub fn extractClientIp(req: *httpz.Request, arena: std.mem.Allocator) []const u8 {
    if (req.header("x-forwarded-for")) |xff| {
        var it = std.mem.splitScalar(u8, xff, ',');
        if (it.next()) |first| {
            const trimmed = std.mem.trim(u8, first, " \t\r\n");
            if (trimmed.len > 0) {
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

// Global default limiter for wrap() when no custom limiter is passed
var g_limiter: ?Limiter = null;
var g_limiter_mutex: std.Io.Mutex = .init;

pub fn getDefaultLimiter(allocator: std.mem.Allocator, io: ?std.Io) *Limiter {
    if (g_limiter == null) {
        if (io) |i| g_limiter_mutex.lockUncancelable(i);
        defer if (io) |i| g_limiter_mutex.unlock(i);
        if (g_limiter == null) {
            g_limiter = Limiter.init(allocator, io, null);
        }
    }
    return &g_limiter.?;
}

pub fn setDefaultLimiter(limiter: Limiter) void {
    if (g_limiter) |*l| l.deinit();
    g_limiter = limiter;
}

pub fn extractKey(policy: Policy, req: *httpz.Request, res: *httpz.Response) !?[]const u8 {
    switch (policy.by) {
        .ip => return extractClientIp(req, res.arena),
        .global => return "global",
        .header => |hdr_name| {
            if (req.header(hdr_name)) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (trimmed.len > 0) return trimmed;
            }
            res.status = 500;
            try res.json(.{ .@"error" = "missing_rate_limit_header" }, .{});
            return null;
        },
        .api_key => {
            if (getAuthContext()) |ctx| {
                if (ctx.key_id) |kid| {
                    return try std.fmt.allocPrint(res.arena, "key:{d}", .{kid});
                }
            }
            std.log.err("rate_limit configured for post-auth but auth context not present", .{});
            res.status = 500;
            try res.json(.{ .@"error" = "internal_server_error" }, .{});
            return null;
        },
        .jwt_sub => {
            if (getAuthContext()) |ctx| {
                if (ctx.sub) |sub| {
                    return try std.fmt.allocPrint(res.arena, "sub:{s}", .{sub});
                }
            }
            std.log.err("rate_limit configured for post-auth but auth context not present", .{});
            res.status = 500;
            try res.json(.{ .@"error" = "internal_server_error" }, .{});
            return null;
        },
        .custom => |func| {
            if (func(req, res)) |key| {
                return key;
            }
            res.status = 500;
            try res.json(.{ .@"error" = "custom_rate_limit_key_null" }, .{});
            return null;
        },
    }
}

pub fn applyRateLimit(
    limiter: *Limiter,
    policy: Policy,
    req: *httpz.Request,
    res: *httpz.Response,
) !bool {
    const key = (try extractKey(policy, req, res)) orelse return false;
    const decision = try limiter.check(policy, key);

    const limit_str = try std.fmt.allocPrint(res.arena, "{d}", .{decision.limit});
    const remaining_str = try std.fmt.allocPrint(res.arena, "{d}", .{decision.remaining});
    const reset_str = try std.fmt.allocPrint(res.arena, "{d}", .{decision.reset_in_s});

    res.header("RateLimit-Limit", limit_str);
    res.header("RateLimit-Remaining", remaining_str);
    res.header("RateLimit-Reset", reset_str);

    if (!decision.allowed) {
        const retry_str = try std.fmt.allocPrint(res.arena, "{d}", .{decision.retry_after_s});
        res.header("Retry-After", retry_str);
        res.status = 429;
        res.content_type = .JSON;
        const msg = try std.fmt.allocPrint(res.arena, "Too many requests. Retry in {d} seconds.", .{decision.retry_after_s});
        try res.json(.{
            .@"error" = "rate_limited",
            .message = msg,
            .retry_after = decision.retry_after_s,
        }, .{});
        return false;
    }

    return true;
}

pub fn wrap(
    comptime policy: Policy,
    comptime target: anytype,
) if (@typeInfo(@TypeOf(target)).@"fn".param_types.len == 2)
    *const fn (@typeInfo(@TypeOf(target)).@"fn".param_types[0].?, @typeInfo(@TypeOf(target)).@"fn".param_types[1].?) anyerror!void
else
    *const fn (@typeInfo(@TypeOf(target)).@"fn".param_types[0].?, @typeInfo(@TypeOf(target)).@"fn".param_types[1].?, @typeInfo(@TypeOf(target)).@"fn".param_types[2].?) anyerror!void {
    const TargetFn = @TypeOf(target);
    const fn_info = @typeInfo(TargetFn).@"fn";

    if (fn_info.param_types.len == 2) {
        const ReqType = fn_info.param_types[0].?;
        const ResType = fn_info.param_types[1].?;
        const Wrapper = struct {
            fn handle(req: ReqType, res: ResType) anyerror!void {
                const limiter_ptr = getDefaultLimiter(res.arena, null);
                const allowed = try applyRateLimit(limiter_ptr, policy, req, res);
                if (!allowed) return;
                return target(req, res);
            }
        };
        return Wrapper.handle;
    } else {
        const H = fn_info.param_types[0].?;
        const ReqType = fn_info.param_types[1].?;
        const ResType = fn_info.param_types[2].?;

        const Wrapper = struct {
            fn handle(app_ctx: H, req: ReqType, res: ResType) anyerror!void {
                const limiter_ptr: *Limiter = blk: {
                    if (@typeInfo(H) == .pointer and @hasField(@typeInfo(H).pointer.child, "limiter")) {
                        const l_val = app_ctx.limiter;
                        if (@typeInfo(@TypeOf(l_val)) == .pointer) break :blk l_val;
                        if (@typeInfo(@TypeOf(l_val)) == .optional and l_val != null) break :blk l_val.?;
                    }
                    break :blk getDefaultLimiter(res.arena, null);
                };

                const allowed = try applyRateLimit(limiter_ptr, policy, req, res);
                if (!allowed) return;

                return target(app_ctx, req, res);
            }
        };
        return Wrapper.handle;
    }
}

pub fn wrapWithLimiter(
    comptime policy: Policy,
    limiter_ptr: *Limiter,
    comptime target: anytype,
) if (@typeInfo(@TypeOf(target)).@"fn".param_types.len == 2)
    *const fn (@typeInfo(@TypeOf(target)).@"fn".param_types[0].?, @typeInfo(@TypeOf(target)).@"fn".param_types[1].?) anyerror!void
else
    *const fn (@typeInfo(@TypeOf(target)).@"fn".param_types[0].?, @typeInfo(@TypeOf(target)).@"fn".param_types[1].?, @typeInfo(@TypeOf(target)).@"fn".param_types[2].?) anyerror!void {
    _ = limiter_ptr;
    return wrap(policy, target);
}
