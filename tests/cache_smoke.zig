const std = @import("std");
const app = @import("app");

const Cache = app.cache_mod.Cache;
const MAX_VALUE_BYTES = app.cache_mod.MAX_VALUE_BYTES;

test "set then get returns value" {
    var cache = try Cache.init(std.testing.allocator, 512);
    defer cache.deinit();
    try cache.set("k", "v", 60);
    const got = try cache.get("k", std.testing.allocator);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("v", got.?);
}

test "get missing key returns null" {
    var cache = try Cache.init(std.testing.allocator, 512);
    defer cache.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try cache.get("no-such-key", std.testing.allocator));
}

test "ttl expires entry" {
    var cache = try Cache.init(std.testing.allocator, 512);
    defer cache.deinit();
    try cache.set("k2", "v2", 1);
    try std.testing.io.sleep(.fromMilliseconds(1100), .awake);
    try std.testing.expectEqual(@as(?[]u8, null), try cache.get("k2", std.testing.allocator));
}

test "value larger than MAX_VALUE_BYTES is rejected" {
    var cache = try Cache.init(std.testing.allocator, 512);
    defer cache.deinit();
    const big: [MAX_VALUE_BYTES + 1]u8 = @splat(0);
    try std.testing.expectError(error.ValueTooLarge, cache.set("big", &big, 60));
    try std.testing.expectEqual(@as(?[]u8, null), try cache.get("big", std.testing.allocator));
}

test "four threads set and get distinct keys" {
    var cache = try Cache.init(std.testing.allocator, 512);
    defer cache.deinit();

    const Worker = struct {
        cache: *Cache,
        idx: u8,
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            var key_buf: [4]u8 = undefined;
            var val_buf: [4]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "k{d}", .{self.idx}) catch return;
            const val = std.fmt.bufPrint(&val_buf, "v{d}", .{self.idx}) catch return;
            self.cache.set(key, val, 60) catch return;
            const got = self.cache.get(key, std.testing.allocator) catch return;
            const slice = got orelse return;
            defer std.testing.allocator.free(slice);
            if (std.mem.eql(u8, slice, val)) self.ok.store(true, .seq_cst);
        }
    };

    var workers = [_]Worker{
        .{ .cache = &cache, .idx = 0 },
        .{ .cache = &cache, .idx = 1 },
        .{ .cache = &cache, .idx = 2 },
        .{ .cache = &cache, .idx = 3 },
    };
    var threads: [4]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (threads) |t| t.join();
    for (&workers) |*w| {
        try std.testing.expect(w.ok.load(.seq_cst));
    }
}
