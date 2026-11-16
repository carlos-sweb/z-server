const std = @import("std");
const c = @import("c");
const limits = @import("limits.zig");
const lib = @import("lib.zig");

pub const MAX_VALUE_BYTES = limits.MAX_VALUE_BYTES;

/// 512 shards cover the handler pool (clamp(2*nproc, 4, 16)) without
/// allocating the library default of 4096 hashmaps for a localhost CRUD.
pub const DEFAULT_SHARDS: c_int = 512;

pub const Error = error{
    CacheNoMem,
    CacheInvalid,
    CacheIo,
    Other,
    ValueTooLarge,
};

pub const Cache = struct {
    ptr: *c.pogocache,

    pub fn init(allocator: std.mem.Allocator, nshards: u32) Error!Cache {
        // Pogocache 1.3.2 allocates with libc malloc; the Zig allocator is
        // accepted for API stability and unused here.
        _ = allocator;
        var opts = std.mem.zeroes(c.pogocache_opts);
        opts.nshards = @intCast(nshards);
        opts.usethreadbatch = false;
        const ptr = c.pogocache_new(&opts) orelse return error.CacheNoMem;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Cache) void {
        c.pogocache_free(self.ptr);
        self.* = undefined;
    }

    pub fn set(self: *Cache, key: []const u8, value: []const u8, ttl_seconds: u32) Error!void {
        if (value.len > MAX_VALUE_BYTES) return error.ValueTooLarge;
        var opts = std.mem.zeroes(c.pogocache_store_opts);
        opts.ttl = @as(i64, ttl_seconds) * c.POGOCACHE_SECOND;
        const rc = c.pogocache_store(
            self.ptr,
            bytesPtr(key),
            key.len,
            bytesPtr(value),
            value.len,
            &opts,
        );
        switch (rc) {
            c.POGOCACHE_INSERTED, c.POGOCACHE_REPLACED => return,
            c.POGOCACHE_NOMEM => return error.CacheNoMem,
            else => return mapRc(rc),
        }
    }

    /// pogocache_load callback: entry pointer valid only inside callback.
    /// Copy before return.
    pub fn get(self: *Cache, key: []const u8, allocator: std.mem.Allocator) Error!?[]u8 {
        var ctx = LoadCtx{ .allocator = allocator };
        var opts = std.mem.zeroes(c.pogocache_load_opts);
        opts.entry = loadEntry;
        opts.udata = &ctx;
        const rc = c.pogocache_load(self.ptr, bytesPtr(key), key.len, &opts);
        if (ctx.err) |err| return err;
        switch (rc) {
            c.POGOCACHE_FOUND => {
                _ = lib.metrics.hits.fetchAdd(1, .monotonic);
                return ctx.value;
            },
            c.POGOCACHE_NOTFOUND => {
                _ = lib.metrics.misses.fetchAdd(1, .monotonic);
                return null;
            },
            c.POGOCACHE_NOMEM => return error.CacheNoMem,
            else => return mapRc(rc),
        }
    }

    pub fn delete(self: *Cache, key: []const u8) Error!void {
        const rc = c.pogocache_delete(self.ptr, bytesPtr(key), key.len, null);
        switch (rc) {
            c.POGOCACHE_DELETED, c.POGOCACHE_NOTFOUND => return,
            c.POGOCACHE_NOMEM => return error.CacheNoMem,
            else => return mapRc(rc),
        }
    }
};

const LoadCtx = struct {
    allocator: std.mem.Allocator,
    value: ?[]u8 = null,
    err: ?Error = null,
};

fn loadEntry(
    shard: c_int,
    time: i64,
    key: ?*const anyopaque,
    keylen: usize,
    value: ?*const anyopaque,
    valuelen: usize,
    expires: i64,
    flags: u32,
    cas: u64,
    update: [*c][*c]c.pogocache_update,
    udata: ?*anyopaque,
) callconv(.c) void {
    _ = shard;
    _ = time;
    _ = key;
    _ = keylen;
    _ = expires;
    _ = flags;
    _ = cas;
    _ = update;
    const ctx: *LoadCtx = @ptrCast(@alignCast(udata.?));
    const src: []const u8 = if (valuelen == 0 or value == null)
        &.{}
    else
        @as([*]const u8, @ptrCast(value))[0..valuelen];
    ctx.value = ctx.allocator.dupe(u8, src) catch {
        ctx.err = error.CacheNoMem;
        return;
    };
}

fn bytesPtr(s: []const u8) ?*const anyopaque {
    if (s.len == 0) return @ptrCast("");
    return s.ptr;
}

fn mapRc(rc: c_int) Error {
    return switch (rc) {
        c.POGOCACHE_NOMEM => error.CacheNoMem,
        c.POGOCACHE_CANCELED => error.CacheInvalid,
        else => error.Other,
    };
}
