const std = @import("std");

pub const impl = @import("impl.zig");
pub const refresh = @import("refresh.zig");

pub const Authenticator = impl.Authenticator;
pub const Token = impl.Token;
pub const Options = impl.Options;
pub const Claims = impl.Claims;
pub const JwtError = impl.JwtError;

pub const RefreshTokenResult = refresh.RefreshTokenResult;
pub const RefreshTokenClaims = refresh.RefreshTokenClaims;
pub const createRefreshToken = refresh.createRefreshToken;
pub const validateRefreshToken = refresh.validateRefreshToken;
pub const revokeRefreshToken = refresh.revokeRefreshToken;
pub const cleanupExpiredRefreshTokens = refresh.cleanupExpiredRefreshTokens;
pub const initRefreshSchema = refresh.initSchema;

pub const Metrics = struct {
    valid: std.atomic.Value(u64) = .init(0),
    invalid_sig: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(u64) = .init(0),
    denylist: std.atomic.Value(u64) = .init(0),
};
pub var metrics: Metrics = .{};
