const std = @import("std");
const z_server_cache = @import("z_server_cache");

pub const Scope = enum {
    ip,
    api_key,
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    cache: ?*z_server_cache.Cache,
    mutex: std.Io.Mutex,
    map: std.AutoHashMap(MemKey, MemEntry),
    last_cleanup: i64,

    pub const MemKey = struct {
        scope: Scope,
        bucket: i64,
        id_hash: u64,
    };

    pub const MemEntry = struct {
        count: u32,
        expires_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: ?std.Io, cache: ?*z_server_cache.Cache) RateLimiter {
        return .{
            .allocator = allocator,
            .io = io,
            .cache = cache,
            .mutex = .init,
            .map = std.AutoHashMap(MemKey, MemEntry).init(allocator),
            .last_cleanup = getUnixTimestamp(),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.map.deinit();
    }

    pub fn getUnixTimestamp() i64 {
        var ts: std.posix.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts) == 0) {
            return ts.sec;
        }
        return 0;
    }

    pub fn checkAndIncrement(
        self: *RateLimiter,
        scope: Scope,
        id: []const u8,
        limit: u32,
        window_s: u32,
    ) !bool {
        if (limit == 0) return false;

        const now = getUnixTimestamp();
        const win_i64: i64 = @intCast(@max(1, window_s));
        const bucket = @divFloor(now, win_i64);

        if (self.cache) |c| {
            return self.checkAndIncrementCache(c, scope, id, bucket, limit, window_s, now);
        } else {
            return self.checkAndIncrementMem(scope, id, bucket, limit, window_s, now);
        }
    }

    fn checkAndIncrementCache(
        self: *RateLimiter,
        c: *z_server_cache.Cache,
        scope: Scope,
        id: []const u8,
        bucket: i64,
        limit: u32,
        window_s: u32,
        now: i64,
    ) !bool {
        const scope_str = switch (scope) {
            .ip => "ip",
            .api_key => "api_key",
        };

        var key_buf: [256]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&key_buf, "ratelimit:{s}:{s}:{d}", .{ scope_str, id, bucket }) catch {
            return false;
        };

        const win_i64: i64 = @intCast(@max(1, window_s));
        const reset_at = (bucket + 1) * win_i64;
        const remaining: u32 = @max(1, @as(u32, @intCast(@max(1, reset_at - now))));

        var count: u32 = 0;
        if (try c.get(cache_key, self.allocator)) |val| {
            defer self.allocator.free(val);
            count = std.fmt.parseInt(u32, val, 10) catch 0;
        }

        if (count >= limit) {
            return false;
        }

        count += 1;
        var val_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&val_buf, "{d}", .{count}) catch return false;
        try c.set(cache_key, count_str, remaining);
        return true;
    }

    fn checkAndIncrementMem(
        self: *RateLimiter,
        scope: Scope,
        id: []const u8,
        bucket: i64,
        limit: u32,
        window_s: u32,
        now: i64,
    ) !bool {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
        }
        defer {
            if (self.io) |io| {
                self.mutex.unlock(io);
            }
        }

        if (now >= self.last_cleanup + 60) {
            self.cleanupLocked(now);
            self.last_cleanup = now;
        }

        const id_hash = std.hash.Wyhash.hash(0, id);
        const key = MemKey{
            .scope = scope,
            .bucket = bucket,
            .id_hash = id_hash,
        };

        const win_i64: i64 = @intCast(@max(1, window_s));
        const expires_at = (bucket + 1) * win_i64;

        if (self.map.getPtr(key)) |entry| {
            if (entry.count >= limit) {
                return false;
            }
            entry.count += 1;
            return true;
        } else {
            try self.map.put(key, .{
                .count = 1,
                .expires_at = expires_at,
            });
            return true;
        }
    }

    pub fn cleanup(self: *RateLimiter, now: i64) void {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
        }
        defer {
            if (self.io) |io| {
                self.mutex.unlock(io);
            }
        }
        self.cleanupLocked(now);
    }

    fn cleanupLocked(self: *RateLimiter, now: i64) void {
        var to_remove = std.ArrayListUnmanaged(MemKey).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at <= now) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (to_remove.items) |k| {
            _ = self.map.remove(k);
        }
    }
};
