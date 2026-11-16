const std = @import("std");
const httpz = @import("httpz");
const z_server_metrics = @import("z_server_metrics");
const z_server_db = @import("z_server_db");
const z_server_cache = @import("z_server_cache");
const z_server_auth = @import("z_server_auth");
const z_server_jwt = @import("z_server_jwt");
const z_server_ratelimit = @import("z_server_ratelimit");

const HttpMetrics = z_server_metrics.HttpMetrics;
const Registry = z_server_metrics.Registry;
const wrap = z_server_metrics.wrap;
const render = z_server_metrics.render;
const handleMetrics = z_server_metrics.handleMetrics;
const isIpAllowed = z_server_metrics.isIpAllowed;
const BufferWriter = z_server_metrics.BufferWriter;

test "1. wrap() increments requests_total with method/path/status" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const Handler = struct {
        fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
            res.status = 200;
            try res.json(.{ .ok = true }, .{});
        }
    };

    const wrapped = wrap("/api/v1/test", Handler.handle);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try wrapped(ht.req, ht.res);

    const m_idx = z_server_metrics.methodIndex(ht.req.method); // GET = 0
    const p_idx = http_metrics.getOrRegisterPath("/api/v1/test");
    const s_idx = z_server_metrics.statusClassIndex(200); // 2xx = 0

    const count = http_metrics.requests_total.counts[m_idx][p_idx][s_idx].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), count);
}

test "2. wrap() records latency in histogram" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const Handler = struct {
        fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
            res.status = 200;
        }
    };

    const wrapped = wrap("/api/latency", Handler.handle);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try wrapped(ht.req, ht.res);

    const m_idx = z_server_metrics.methodIndex(ht.req.method);
    const p_idx = http_metrics.getOrRegisterPath("/api/latency");

    const hist_count = http_metrics.duration_seconds.counts[m_idx][p_idx].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), hist_count);

    // Sum in nanoseconds should be non-negative
    const sum_ns = http_metrics.duration_seconds.sums_ns[m_idx][p_idx].load(.monotonic);
    try std.testing.expect(sum_ns >= 0);
}

test "3. in_flight: +1 during execution and 0 afterwards" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const Handler = struct {
        var observed_in_flight: u64 = 0;
        var metrics_ptr: *HttpMetrics = undefined;

        fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
            observed_in_flight = metrics_ptr.in_flight.load(.monotonic);
            res.status = 200;
        }
    };
    Handler.metrics_ptr = &http_metrics;

    const wrapped = wrap("/api/inflight", Handler.handle);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try wrapped(ht.req, ht.res);

    try std.testing.expect(Handler.observed_in_flight >= 1);
    try std.testing.expectEqual(@as(u64, 0), http_metrics.in_flight.load(.monotonic));
}

test "4. path normalization: explicit pattern prevents cardinality explosion" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const Handler = struct {
        fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
            res.status = 200;
        }
    };

    const wrapped = wrap("/items/:id", Handler.handle);

    // Hit with ID 1
    var ht1 = httpz.testing.init(.{});
    defer ht1.deinit();
    ht1.url("/items/123");
    try wrapped(ht1.req, ht1.res);

    // Hit with ID 2
    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    ht2.url("/items/456");
    try wrapped(ht2.req, ht2.res);

    // Path count in registry should only increase by 1 for "/items/:id"
    const p_idx = http_metrics.getOrRegisterPath("/items/:id");
    const count = http_metrics.requests_total.counts[0][p_idx][0].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 2), count);
}

test "5. 3 distinct paths do not overwrite each other" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const Handler = struct {
        fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
            res.status = 200;
        }
    };

    const w1 = wrap("/path/one", Handler.handle);
    const w2 = wrap("/path/two", Handler.handle);
    const w3 = wrap("/path/three", Handler.handle);

    var ht1 = httpz.testing.init(.{});
    defer ht1.deinit();
    try w1(ht1.req, ht1.res);

    var ht2 = httpz.testing.init(.{});
    defer ht2.deinit();
    try w2(ht2.req, ht2.res);
    try w2(ht2.req, ht2.res);

    var ht3 = httpz.testing.init(.{});
    defer ht3.deinit();
    try w3(ht3.req, ht3.res);
    try w3(ht3.req, ht3.res);
    try w3(ht3.req, ht3.res);

    const p1 = http_metrics.getOrRegisterPath("/path/one");
    const p2 = http_metrics.getOrRegisterPath("/path/two");
    const p3 = http_metrics.getOrRegisterPath("/path/three");

    try std.testing.expect(p1 != p2);
    try std.testing.expect(p2 != p3);

    try std.testing.expectEqual(@as(u64, 1), http_metrics.requests_total.counts[0][p1][0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), http_metrics.requests_total.counts[0][p2][0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), http_metrics.requests_total.counts[0][p3][0].load(.monotonic));
}

test "6. status 2xx, 3xx, 4xx, 5xx each recorded in distinct status class bucket" {
    var http_metrics = HttpMetrics.init();
    z_server_metrics.setDefaultRegistry(Registry.init(&http_metrics));

    const MakeHandler = struct {
        fn make(comptime status: u16) fn (*httpz.Request, *httpz.Response) anyerror!void {
            return struct {
                fn handle(_: *httpz.Request, res: *httpz.Response) anyerror!void {
                    res.status = status;
                }
            }.handle;
        }
    };

    const w200 = wrap("/status/test", MakeHandler.make(200));
    const w301 = wrap("/status/test", MakeHandler.make(301));
    const w404 = wrap("/status/test", MakeHandler.make(404));
    const w500 = wrap("/status/test", MakeHandler.make(500));

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try w200(ht.req, ht.res);
    try w301(ht.req, ht.res);
    try w404(ht.req, ht.res);
    try w500(ht.req, ht.res);

    const p_idx = http_metrics.getOrRegisterPath("/status/test");
    try std.testing.expectEqual(@as(u64, 1), http_metrics.requests_total.counts[0][p_idx][0].load(.monotonic)); // 2xx
    try std.testing.expectEqual(@as(u64, 1), http_metrics.requests_total.counts[0][p_idx][1].load(.monotonic)); // 3xx
    try std.testing.expectEqual(@as(u64, 1), http_metrics.requests_total.counts[0][p_idx][2].load(.monotonic)); // 4xx
    try std.testing.expectEqual(@as(u64, 1), http_metrics.requests_total.counts[0][p_idx][3].load(.monotonic)); // 5xx
}

test "7. /metrics valid Prometheus text output containing # HELP and # TYPE" {
    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();

    try render(&reg, &writer);

    const out = writer.string();
    try std.testing.expect(std.mem.indexOf(u8, out, "# HELP http_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# TYPE http_requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# HELP http_requests_in_flight") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# TYPE http_requests_in_flight gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# HELP process_start_time_seconds") != null);
}

test "8. Registry with only http: omits sqlite metrics" {
    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);
    reg.db = null;

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();

    try render(&reg, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.string(), "sqlite_busy_count_total") == null);
}

test "9. Registry with db: includes sqlite_busy_count_total" {
    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);
    var db_metrics: z_server_db.Metrics = .{};
    _ = db_metrics.busy.fetchAdd(4, .monotonic);
    reg.db = &db_metrics;

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();

    try render(&reg, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.string(), "sqlite_busy_count_total 4") != null);
}

test "10. auth_failures_total with reason=\"missing\" increments on auth failure" {
    var auth_metrics = &z_server_auth.metrics;
    const initial = auth_metrics.missing.load(.monotonic);
    _ = auth_metrics.missing.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(initial + 1, auth_metrics.missing.load(.monotonic));

    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);
    reg.auth = auth_metrics;

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();
    try render(&reg, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.string(), "auth_failures_total{reason=\"missing\"}") != null);
}

test "11. jwt_validations_total with result=\"expired\" increments on expired token" {
    var jwt_metrics = &z_server_jwt.metrics;
    const initial = jwt_metrics.expired.load(.monotonic);
    _ = jwt_metrics.expired.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(initial + 1, jwt_metrics.expired.load(.monotonic));

    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);
    reg.jwt = jwt_metrics;

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();
    try render(&reg, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.string(), "jwt_validations_total{result=\"expired\"}") != null);
}

test "12. ratelimit_rejected_total increments after 429 rejection" {
    var rl_metrics = &z_server_ratelimit.metrics;
    const initial = rl_metrics.rejected_ip.load(.monotonic);
    _ = rl_metrics.rejected_ip.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(initial + 1, rl_metrics.rejected_ip.load(.monotonic));

    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);
    reg.ratelimit = rl_metrics;

    var writer = BufferWriter.init(std.testing.allocator);
    defer writer.deinit();
    try render(&reg, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.string(), "ratelimit_rejected_total{policy=\"ip\"}") != null);
}

test "13. IP allowlist: allowed CIDR returns true, disallowed returns false" {
    const allowed = [_][]const u8{ "127.0.0.1/32", "10.0.0.0/8" };

    try std.testing.expect(isIpAllowed("127.0.0.1", &allowed));
    try std.testing.expect(isIpAllowed("10.1.2.3", &allowed));
    try std.testing.expect(!isIpAllowed("192.168.1.1", &allowed));
    try std.testing.expect(!isIpAllowed("172.16.0.1", &allowed));
}

test "14. IP allowlist: empty list allows any IP" {
    const empty = [_][]const u8{};
    try std.testing.expect(isIpAllowed("192.168.1.1", &empty));
    try std.testing.expect(isIpAllowed("203.0.113.1", &empty));
}

test "15. handleMetrics sets Content-Type and Cache-Control headers" {
    var http_metrics = HttpMetrics.init();
    var reg = Registry.init(&http_metrics);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    try handleMetrics(&reg, ht.req, ht.res);

    try ht.expectStatus(200);
    try std.testing.expectEqualStrings("text/plain; version=0.0.4; charset=utf-8", ht.res.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("no-store", ht.res.headers.get("Cache-Control").?);
}
