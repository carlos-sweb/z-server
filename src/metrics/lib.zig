const std = @import("std");
const httpz = @import("httpz");
const registry_mod = @import("registry.zig");

const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_auth = @import("z_server_auth");
const z_server_jwt = @import("z_server_jwt");
const z_server_ratelimit = @import("z_server_ratelimit");

pub const HttpMetrics = registry_mod.HttpMetrics;
pub const MAX_PATHS = registry_mod.MAX_PATHS;
pub const METHOD_NAMES = registry_mod.METHOD_NAMES;
pub const STATUS_CLASS_NAMES = registry_mod.STATUS_CLASS_NAMES;
pub const BUCKET_LABELS = registry_mod.BUCKET_LABELS;
pub const BUCKETS_NS = registry_mod.BUCKETS_NS;
pub const methodIndex = registry_mod.methodIndex;
pub const statusClassIndex = registry_mod.statusClassIndex;
pub const getMonotonicNs = registry_mod.getMonotonicNs;
pub const getUnixTimestamp = registry_mod.getUnixTimestamp;

pub const Registry = struct {
    http: *HttpMetrics,
    db: ?*const z_server_db.Metrics = null,
    cache: ?*const z_server_cache.Metrics = null,
    auth: ?*const z_server_auth.Metrics = null,
    jwt: ?*const z_server_jwt.Metrics = null,
    ratelimit: ?*const z_server_ratelimit.Metrics = null,
    process_start_unix: i64,

    pub fn init(http: *HttpMetrics) Registry {
        return .{
            .http = http,
            .process_start_unix = getUnixTimestamp(),
        };
    }
};

var g_default_http_metrics: HttpMetrics = HttpMetrics.init();
var g_default_registry: ?Registry = null;

pub fn getDefaultHttpMetrics() *HttpMetrics {
    if (g_default_registry) |*reg| {
        return reg.http;
    }
    return &g_default_http_metrics;
}

pub fn setDefaultHttpMetrics(metrics: *HttpMetrics) void {
    if (g_default_registry) |*reg| {
        reg.http = metrics;
    } else {
        g_default_registry = Registry.init(metrics);
    }
}

pub fn getDefaultRegistry() *Registry {
    if (g_default_registry == null) {
        g_default_registry = Registry.init(&g_default_http_metrics);
    }
    return &g_default_registry.?;
}

pub fn setDefaultRegistry(reg: Registry) void {
    g_default_registry = reg;
}

pub fn render(registry: *const Registry, writer: anytype) !void {
    const http = registry.http;
    const now = getUnixTimestamp();
    const uptime = if (now >= registry.process_start_unix) now - registry.process_start_unix else 0;

    // 1. http_requests_total
    try writer.writeAll(
        \\# HELP http_requests_total Total HTTP requests processed
        \\# TYPE http_requests_total counter
        \\
    );
    const path_count = http.path_count.load(.acquire);
    for (0..7) |m_i| {
        for (0..path_count) |p_i| {
            for (0..5) |s_i| {
                const count = http.requests_total.counts[m_i][p_i][s_i].load(.monotonic);
                if (count > 0) {
                    try writer.print("http_requests_total{{method=\"{s}\",path=\"{s}\",status=\"{s}\"}} {d}\n", .{
                        METHOD_NAMES[m_i],
                        http.path_registry[p_i],
                        STATUS_CLASS_NAMES[s_i],
                        count,
                    });
                }
            }
        }
    }

    // 2. http_request_duration_seconds
    try writer.writeAll(
        \\# HELP http_request_duration_seconds HTTP request latency histogram
        \\# TYPE http_request_duration_seconds histogram
        \\
    );
    for (0..7) |m_i| {
        for (0..path_count) |p_i| {
            const count = http.duration_seconds.counts[m_i][p_i].load(.monotonic);
            if (count > 0) {
                const path_str = http.path_registry[p_i];
                for (BUCKET_LABELS, 0..) |label, b_i| {
                    const b_val = http.duration_seconds.buckets[m_i][p_i][b_i].load(.monotonic);
                    try writer.print("http_request_duration_seconds_bucket{{method=\"{s}\",path=\"{s}\",le=\"{s}\"}} {d}\n", .{
                        METHOD_NAMES[m_i], path_str, label, b_val,
                    });
                }
                try writer.print("http_request_duration_seconds_bucket{{method=\"{s}\",path=\"{s}\",le=\"+Inf\"}} {d}\n", .{
                    METHOD_NAMES[m_i], path_str, count,
                });
                const sum_ns = http.duration_seconds.sums_ns[m_i][p_i].load(.monotonic);
                const sum_s = @as(f64, @floatFromInt(sum_ns)) / 1_000_000_000.0;
                try writer.print("http_request_duration_seconds_sum{{method=\"{s}\",path=\"{s}\"}} {d:.6}\n", .{
                    METHOD_NAMES[m_i], path_str, sum_s,
                });
                try writer.print("http_request_duration_seconds_count{{method=\"{s}\",path=\"{s}\"}} {d}\n", .{
                    METHOD_NAMES[m_i], path_str, count,
                });
            }
        }
    }

    // 3. http_requests_in_flight
    const in_flight = http.in_flight.load(.monotonic);
    try writer.writeAll(
        \\# HELP http_requests_in_flight Current number of HTTP requests being processed
        \\# TYPE http_requests_in_flight gauge
        \\
    );
    try writer.print("http_requests_in_flight {d}\n", .{in_flight});

    // 4. sqlite_busy_count_total (if db present)
    if (registry.db) |db| {
        try writer.writeAll(
            \\# HELP sqlite_busy_count_total Total number of times SQLite returned SQLITE_BUSY
            \\# TYPE sqlite_busy_count_total counter
            \\
        );
        try writer.print("sqlite_busy_count_total {d}\n", .{db.busy.load(.monotonic)});

        // 5. sqlite_query_duration_seconds
        try writer.writeAll(
            \\# HELP sqlite_query_duration_seconds SQLite query duration in seconds
            \\# TYPE sqlite_query_duration_seconds histogram
            \\
        );
        const query_types = [_][]const u8{ "select", "insert", "update", "delete" };
        const query_ns = [_]u64{
            db.query_ns.select.load(.monotonic),
            db.query_ns.insert.load(.monotonic),
            db.query_ns.update.load(.monotonic),
            db.query_ns.delete.load(.monotonic),
        };
        for (query_types, 0..) |q_type, q_i| {
            const q_count = db.query_count[q_i].load(.monotonic);
            const q_sum_s = @as(f64, @floatFromInt(query_ns[q_i])) / 1_000_000_000.0;
            try writer.print("sqlite_query_duration_seconds_sum{{query_type=\"{s}\"}} {d:.6}\n", .{ q_type, q_sum_s });
            try writer.print("sqlite_query_duration_seconds_count{{query_type=\"{s}\"}} {d}\n", .{ q_type, q_count });
        }
    }

    // 6. cache_hits_total & cache_misses_total (if cache present)
    if (registry.cache) |c| {
        try writer.writeAll(
            \\# HELP cache_hits_total Total number of cache hits
            \\# TYPE cache_hits_total counter
            \\
        );
        try writer.print("cache_hits_total {d}\n", .{c.hits.load(.monotonic)});

        try writer.writeAll(
            \\# HELP cache_misses_total Total number of cache misses
            \\# TYPE cache_misses_total counter
            \\
        );
        try writer.print("cache_misses_total {d}\n", .{c.misses.load(.monotonic)});
    }

    // 7. auth_failures_total (if auth present)
    if (registry.auth) |a| {
        try writer.writeAll(
            \\# HELP auth_failures_total Total number of authentication failures by reason
            \\# TYPE auth_failures_total counter
            \\
        );
        try writer.print("auth_failures_total{{reason=\"missing\"}} {d}\n", .{a.missing.load(.monotonic)});
        try writer.print("auth_failures_total{{reason=\"invalid_key\"}} {d}\n", .{a.invalid_key.load(.monotonic)});
        try writer.print("auth_failures_total{{reason=\"expired\"}} {d}\n", .{a.expired.load(.monotonic)});
        try writer.print("auth_failures_total{{reason=\"revoked\"}} {d}\n", .{a.revoked.load(.monotonic)});
    }

    // 8. jwt_validations_total (if jwt present)
    if (registry.jwt) |j| {
        try writer.writeAll(
            \\# HELP jwt_validations_total Total number of JWT validations by result
            \\# TYPE jwt_validations_total counter
            \\
        );
        try writer.print("jwt_validations_total{{result=\"valid\"}} {d}\n", .{j.valid.load(.monotonic)});
        try writer.print("jwt_validations_total{{result=\"invalid_sig\"}} {d}\n", .{j.invalid_sig.load(.monotonic)});
        try writer.print("jwt_validations_total{{result=\"expired\"}} {d}\n", .{j.expired.load(.monotonic)});
        try writer.print("jwt_validations_total{{result=\"denylist\"}} {d}\n", .{j.denylist.load(.monotonic)});
    }

    // 9. ratelimit_rejected_total (if ratelimit present)
    if (registry.ratelimit) |r| {
        try writer.writeAll(
            \\# HELP ratelimit_rejected_total Total number of rate limited requests by policy
            \\# TYPE ratelimit_rejected_total counter
            \\
        );
        try writer.print("ratelimit_rejected_total{{policy=\"ip\"}} {d}\n", .{r.rejected_ip.load(.monotonic)});
        try writer.print("ratelimit_rejected_total{{policy=\"key\"}} {d}\n", .{r.rejected_key.load(.monotonic)});
        try writer.print("ratelimit_rejected_total{{policy=\"global\"}} {d}\n", .{r.rejected_global.load(.monotonic)});
    }

    // 10 & 11. process_start_time_seconds & process_uptime_seconds
    try writer.writeAll(
        \\# HELP process_start_time_seconds Start time of the process since Unix epoch in seconds
        \\# TYPE process_start_time_seconds gauge
        \\
    );
    try writer.print("process_start_time_seconds {d}\n", .{registry.process_start_unix});

    try writer.writeAll(
        \\# HELP process_uptime_seconds Number of seconds since process start
        \\# TYPE process_uptime_seconds gauge
        \\
    );
    try writer.print("process_uptime_seconds {d}\n", .{uptime});
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

pub fn isIpAllowed(ip_str: []const u8, allowed_cidrs: []const []const u8) bool {
    if (allowed_cidrs.len == 0) return true;
    for (allowed_cidrs) |entry| {
        if (std.mem.eql(u8, ip_str, entry)) return true;
        if (std.mem.indexOfScalar(u8, entry, '/')) |slash| {
            const prefix_str = entry[0..slash];
            const mask_str = entry[slash + 1 ..];
            if (std.mem.eql(u8, ip_str, prefix_str)) return true;
            const mask_bits = std.fmt.parseInt(u8, mask_str, 10) catch continue;
            if (mask_bits > 32) continue;
            const ip4 = parseIpv4(ip_str) orelse continue;
            const net4 = parseIpv4(prefix_str) orelse continue;
            const mask: u32 = if (mask_bits == 0)
                0
            else if (mask_bits == 32)
                ~@as(u32, 0)
            else
                ~(@as(u32, 0)) << @as(u5, @intCast(32 - mask_bits));
            if ((ip4 & mask) == (net4 & mask)) return true;
        }
    }
    return false;
}

fn parseIpv4(ip_str: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, ip_str, '.');
    var result: u32 = 0;
    var count: usize = 0;
    while (it.next()) |part| : (count += 1) {
        if (count >= 4) return null;
        const b = std.fmt.parseInt(u8, part, 10) catch return null;
        result = (result << 8) | @as(u32, b);
    }
    if (count != 4) return null;
    return result;
}

pub const BufferWriter = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BufferWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BufferWriter) void {
        self.list.deinit(self.allocator);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(str);
        try self.list.appendSlice(self.allocator, str);
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn string(self: *const BufferWriter) []const u8 {
        return self.list.items;
    }
};

pub fn handleMetrics(registry: *const Registry, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    res.header("Cache-Control", "no-store");
    res.status = 200;

    var writer = BufferWriter.init(res.arena);
    try render(registry, &writer);

    res.body = writer.string();
}

pub fn wrap(
    comptime pattern: []const u8,
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
                const metrics = getDefaultHttpMetrics();
                _ = metrics.in_flight.fetchAdd(1, .monotonic);
                defer _ = metrics.in_flight.fetchSub(1, .monotonic);

                const start_ns = getMonotonicNs();
                var err_opt: ?anyerror = null;

                target(req, res) catch |err| {
                    err_opt = err;
                    if (res.status < 400) res.status = 500;
                };

                const end_ns = getMonotonicNs();
                const dur_ns = if (end_ns > start_ns) end_ns - start_ns else 0;
                const m_idx = methodIndex(req.method);
                const s_idx = statusClassIndex(res.status);
                const p_idx = metrics.getOrRegisterPath(pattern);
                metrics.recordRequest(m_idx, p_idx, s_idx, dur_ns);

                if (err_opt) |err| return err;
            }
        };
        return Wrapper.handle;
    } else {
        const H = fn_info.param_types[0].?;
        const ReqType = fn_info.param_types[1].?;
        const ResType = fn_info.param_types[2].?;

        const Wrapper = struct {
            fn handle(app_ctx: H, req: ReqType, res: ResType) anyerror!void {
                const metrics: *HttpMetrics = blk: {
                    if (@typeInfo(H) == .pointer and @hasField(@typeInfo(H).pointer.child, "http_metrics")) {
                        const m_val = app_ctx.http_metrics;
                        if (@typeInfo(@TypeOf(m_val)) == .pointer) break :blk m_val;
                    }
                    if (@typeInfo(H) == .pointer and @hasField(@typeInfo(H).pointer.child, "metrics")) {
                        const m_val = app_ctx.metrics;
                        if (@typeInfo(@TypeOf(m_val)) == .pointer and @hasField(@typeInfo(@TypeOf(m_val.*)), "http")) {
                            break :blk m_val.http;
                        }
                    }
                    if (@typeInfo(H) == .pointer and @hasField(@typeInfo(H).pointer.child, "metrics_registry")) {
                        const m_val = app_ctx.metrics_registry;
                        if (m_val) |reg| break :blk reg.http;
                    }
                    break :blk getDefaultHttpMetrics();
                };

                _ = metrics.in_flight.fetchAdd(1, .monotonic);
                defer _ = metrics.in_flight.fetchSub(1, .monotonic);

                const start_ns = getMonotonicNs();
                var err_opt: ?anyerror = null;

                target(app_ctx, req, res) catch |err| {
                    err_opt = err;
                    if (res.status < 400) res.status = 500;
                };

                const end_ns = getMonotonicNs();
                const dur_ns = if (end_ns > start_ns) end_ns - start_ns else 0;
                const m_idx = methodIndex(req.method);
                const s_idx = statusClassIndex(res.status);
                const p_idx = metrics.getOrRegisterPath(pattern);
                metrics.recordRequest(m_idx, p_idx, s_idx, dur_ns);

                if (err_opt) |err| return err;
            }
        };
        return Wrapper.handle;
    }
}
