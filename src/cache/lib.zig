const std = @import("std");

pub const pogocache = @import("pogocache.zig");
pub const limits = @import("limits.zig");

pub const Cache = pogocache.Cache;
pub const Error = pogocache.Error;
pub const DEFAULT_SHARDS = pogocache.DEFAULT_SHARDS;
pub const MAX_VALUE_BYTES = limits.MAX_VALUE_BYTES;
pub const CACHE_TTL_SECONDS = limits.CACHE_TTL_SECONDS;

pub const Options = struct {
    nshards: u32 = DEFAULT_SHARDS,
};

pub const Metrics = struct {
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
};
pub var metrics: Metrics = .{};
