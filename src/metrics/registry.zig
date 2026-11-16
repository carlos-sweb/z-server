const std = @import("std");
const httpz = @import("httpz");

pub const MAX_PATHS: usize = 64;

pub const METHOD_NAMES = [7][]const u8{
    "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS",
};

pub const STATUS_CLASS_NAMES = [5][]const u8{
    "2xx", "3xx", "4xx", "5xx", "other",
};

pub const BUCKET_LABELS = [11][]const u8{
    "0.001", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5",
};

pub const BUCKETS_NS = [11]u64{
    1_000_000,
    5_000_000,
    10_000_000,
    25_000_000,
    50_000_000,
    100_000_000,
    250_000_000,
    500_000_000,
    1_000_000_000,
    2_500_000_000,
    5_000_000_000,
};

pub fn methodIndex(m: httpz.Method) usize {
    return switch (m) {
        .GET => 0,
        .POST => 1,
        .PUT => 2,
        .DELETE => 3,
        .PATCH => 4,
        .HEAD => 5,
        .OPTIONS => 6,
        else => 0,
    };
}

pub fn statusClassIndex(status: u16) usize {
    if (status >= 200 and status < 300) return 0;
    if (status >= 300 and status < 400) return 1;
    if (status >= 400 and status < 500) return 2;
    if (status >= 500 and status < 600) return 3;
    return 4;
}

pub const HttpMetrics = struct {
    requests_total: struct {
        // method (7) x path_id (64) x status_class (5)
        counts: [7][MAX_PATHS][5]std.atomic.Value(u64) = initCounts(),
    } = .{},
    duration_seconds: struct {
        // histogram: method (7) x path_id (64) x bucket (11)
        buckets: [7][MAX_PATHS][11]std.atomic.Value(u64) = initBuckets(),
        sums_ns: [7][MAX_PATHS]std.atomic.Value(u64) = initSums(),
        counts: [7][MAX_PATHS]std.atomic.Value(u64) = initSums(),
    } = .{},
    in_flight: std.atomic.Value(u64) = .init(0),
    path_registry: [MAX_PATHS][]const u8 = initPathRegistry(),
    path_count: std.atomic.Value(u32) = .init(1),
    lock: std.atomic.Value(bool) = .init(false),

    fn initCounts() [7][MAX_PATHS][5]std.atomic.Value(u64) {
        @setEvalBranchQuota(100_000);
        var res: [7][MAX_PATHS][5]std.atomic.Value(u64) = undefined;
        for (&res) |*by_method| {
            for (by_method) |*by_path| {
                for (by_path) |*val| {
                    val.* = std.atomic.Value(u64).init(0);
                }
            }
        }
        return res;
    }

    fn initBuckets() [7][MAX_PATHS][11]std.atomic.Value(u64) {
        @setEvalBranchQuota(100_000);
        var res: [7][MAX_PATHS][11]std.atomic.Value(u64) = undefined;
        for (&res) |*by_method| {
            for (by_method) |*by_path| {
                for (by_path) |*val| {
                    val.* = std.atomic.Value(u64).init(0);
                }
            }
        }
        return res;
    }

    fn initSums() [7][MAX_PATHS]std.atomic.Value(u64) {
        @setEvalBranchQuota(100_000);
        var res: [7][MAX_PATHS]std.atomic.Value(u64) = undefined;
        for (&res) |*by_method| {
            for (by_method) |*val| {
                val.* = std.atomic.Value(u64).init(0);
            }
        }
        return res;
    }

    fn initPathRegistry() [MAX_PATHS][]const u8 {
        var res: [MAX_PATHS][]const u8 = undefined;
        res[0] = "unmatched";
        for (1..MAX_PATHS) |i| {
            res[i] = "";
        }
        return res;
    }

    pub fn init() HttpMetrics {
        return .{};
    }

    pub fn getOrRegisterPath(self: *HttpMetrics, pattern: []const u8) usize {
        const cur_count = self.path_count.load(.acquire);
        for (0..cur_count) |i| {
            if (std.mem.eql(u8, self.path_registry[i], pattern)) {
                return i;
            }
        }

        // Lock to register new path
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const locked_count = self.path_count.load(.acquire);
        for (0..locked_count) |i| {
            if (std.mem.eql(u8, self.path_registry[i], pattern)) {
                return i;
            }
        }

        if (locked_count >= MAX_PATHS) {
            std.log.err("z_server_metrics: MAX_PATHS ({d}) exceeded for pattern '{s}', using 'unmatched'", .{ MAX_PATHS, pattern });
            return 0;
        }

        self.path_registry[locked_count] = pattern;
        self.path_count.store(locked_count + 1, .release);
        return locked_count;
    }

    pub fn recordRequest(
        self: *HttpMetrics,
        method_idx: usize,
        path_idx: usize,
        status_idx: usize,
        duration_ns: u64,
    ) void {
        const m = if (method_idx < 7) method_idx else 0;
        const p = if (path_idx < MAX_PATHS) path_idx else 0;
        const s = if (status_idx < 5) status_idx else 4;

        _ = self.requests_total.counts[m][p][s].fetchAdd(1, .monotonic);

        for (BUCKETS_NS, 0..) |b_ns, b_i| {
            if (duration_ns <= b_ns) {
                _ = self.duration_seconds.buckets[m][p][b_i].fetchAdd(1, .monotonic);
            }
        }
        _ = self.duration_seconds.sums_ns[m][p].fetchAdd(duration_ns, .monotonic);
        _ = self.duration_seconds.counts[m][p].fetchAdd(1, .monotonic);
    }
};

pub fn getMonotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

pub fn getUnixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
        return ts.sec;
    }
    return 0;
}
