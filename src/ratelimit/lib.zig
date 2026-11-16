const std = @import("std");
pub const impl = @import("impl.zig");

pub const Limiter = impl.Limiter;
pub const Policy = impl.Policy;
pub const LimitBy = impl.LimitBy;
pub const Decision = impl.Decision;
pub const AuthContext = impl.AuthContext;
pub const setAuthContext = impl.setAuthContext;
pub const getAuthContext = impl.getAuthContext;
pub const extractClientIp = impl.extractClientIp;
pub const extractKey = impl.extractKey;
pub const applyRateLimit = impl.applyRateLimit;
pub const wrap = impl.wrap;
pub const wrapWithLimiter = impl.wrapWithLimiter;
pub const getDefaultLimiter = impl.getDefaultLimiter;
pub const setDefaultLimiter = impl.setDefaultLimiter;

pub const Metrics = struct {
    rejected_ip: std.atomic.Value(u64) = .init(0),
    rejected_key: std.atomic.Value(u64) = .init(0),
    rejected_global: std.atomic.Value(u64) = .init(0),
};
pub var metrics: Metrics = .{};
