const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

const RawConfig = struct {
    @"$schema_version": ?u32 = null,
    schema_version: u32 = 1,
    server: ServerConfig = .{},
    sqlite: SqliteConfig = .{},
    cache: CacheConfig = .{},
    tls: TlsConfig = .{},
    logging: LoggingConfig = .{},
};

pub const Config = struct {
    schema_version: u32 = 1,
    server: ServerConfig = .{},
    sqlite: SqliteConfig = .{},
    cache: CacheConfig = .{},
    tls: TlsConfig = .{},
    logging: LoggingConfig = .{},
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }

    pub fn validate(self: *const Config) !void {
        if (self.schema_version > 1) {
            return error.UnsupportedSchemaVersion;
        }

        if (self.server.handler_threads) |t| {
            if (t == 0 or t > 128) {
                return error.HandlerThreadsOutOfRange;
            }
        }

        if (self.sqlite.pool_size) |p| {
            if (p == 0 or p > 128) {
                return error.SqlitePoolSizeOutOfRange;
            }
        }

        if (self.cache.nshards == 0 or self.cache.nshards > 65535) {
            return error.CacheNshardsOutOfRange;
        }

        if (self.tls.enabled) {
            const cert_path = self.tls.cert_path orelse {
                return error.MissingCertPath;
            };
            const key_path = self.tls.key_path orelse {
                return error.MissingKeyPath;
            };

            const cert_mode = checkFile(cert_path) catch {
                return error.CertFileNotFound;
            };
            _ = cert_mode;

            const key_mode = checkFile(key_path) catch {
                return error.KeyFileNotFound;
            };

            if ((key_mode & 0o004) != 0) {
                std.log.warn("TLS key_path '{s}' is world-readable (mode 0o{o}); consider restricting to 0600", .{ key_path, key_mode & 0o777 });
            }
        }
    }

    pub fn applyEnvOverrides(self: *Config, env: anytype) !void {
        if (env.get("Z_SERVER_TLS_CERT_PATH") != null or env.get("Z_SERVER_TLS_KEY_PATH") != null) {
            std.log.warn("TLS cert/key paths must be set via config file, not env (env vars leak via /proc/PID/environ).", .{});
            return error.TlsPathsNotAllowedInEnv;
        }

        if (env.get("Z_SERVER_BIND")) |val| {
            self.server.bind = val;
        }
        if (env.get("Z_SERVER_HANDLER_THREADS")) |val| {
            const n = std.fmt.parseInt(u16, val, 10) catch {
                std.log.warn("invalid Z_SERVER_HANDLER_THREADS: {s}", .{val});
                return error.InvalidEnvHandlerThreads;
            };
            self.server.handler_threads = n;
        }
        if (env.get("Z_SERVER_SQLITE_POOL")) |val| {
            const n = std.fmt.parseInt(u16, val, 10) catch {
                std.log.warn("invalid Z_SERVER_SQLITE_POOL: {s}", .{val});
                return error.InvalidEnvSqlitePool;
            };
            self.sqlite.pool_size = n;
        }
        if (env.get("Z_SERVER_SQLITE_SYNCHRONOUS")) |val| {
            self.sqlite.synchronous = val;
        }
    }
};

pub const ServerConfig = struct {
    bind: []const u8 = "0.0.0.0:8080",
    handler_threads: ?u16 = null,
    max_body_size: u32 = 65536,
};

pub const SqliteConfig = struct {
    path: []const u8 = "data/app.db",
    pool_size: ?u16 = null,
    synchronous: []const u8 = "NORMAL",
    busy_timeout_ms: u32 = 5000,
};

pub const CacheConfig = struct {
    nshards: u16 = 512,
    default_ttl_s: u32 = 60,
    max_value_bytes: u32 = 32768,
};

pub const TlsConfig = struct {
    enabled: bool = false,
    bind: []const u8 = "0.0.0.0:8443",
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    alpn: []const []const u8 = &.{ "http/1.1" },
    min_version: []const u8 = "1.2",
    max_conns: u32 = 256,
};

pub const LoggingConfig = struct {
    level: []const u8 = "info",
};

fn checkFile(path: []const u8) !u32 {
    var path_buf: [4096:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var statx_buf: linux.Statx = undefined;
    const rc = linux.statx(posix.AT.FDCWD, &path_buf, 0, linux.STATX.BASIC_STATS, &statx_buf);
    if (rc != 0) return error.FileNotFound;
    return statx_buf.mode;
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max_len: usize) ![]u8 {
    var path_buf: [4096:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var statx_buf: linux.Statx = undefined;
    const rc = linux.statx(posix.AT.FDCWD, &path_buf, 0, linux.STATX.BASIC_STATS, &statx_buf);
    if (rc != 0) {
        std.log.warn("cannot stat config file '{s}'", .{path});
        return error.FileNotFound;
    }
    const size: usize = @intCast(statx_buf.size);
    if (size > max_len) return error.FileTooLarge;

    const fd = posix.openatZ(posix.AT.FDCWD, &path_buf, .{ .ACCMODE = .RDONLY }, 0) catch {
        std.log.warn("cannot open config file '{s}'", .{path});
        return error.FileNotFound;
    };
    defer _ = linux.close(fd);

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    if (size > 0) {
        try list.ensureTotalCapacity(allocator, @min(size, max_len));
    }

    var chunk: [4096]u8 = undefined;
    while (list.items.len < max_len) {
        const to_read = @min(chunk.len, max_len - list.items.len);
        const n = try posix.read(fd, chunk[0..to_read]);
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
    }

    var test_byte: [1]u8 = undefined;
    const extra = try posix.read(fd, &test_byte);
    if (extra > 0) return error.FileTooLarge;

    return try list.toOwnedSlice(allocator);
}

pub fn load(allocator: Allocator, path: []const u8) !Config {
    const max_size = 1024 * 1024; // 1 MiB config limit
    const content = try readFileAlloc(allocator, path, max_size);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(RawConfig, arena_allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("failed to parse JSON config file '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };

    const raw = parsed.value;
    var cfg = Config{
        .schema_version = raw.@"$schema_version" orelse raw.schema_version,
        .server = raw.server,
        .sqlite = raw.sqlite,
        .cache = raw.cache,
        .tls = raw.tls,
        .logging = raw.logging,
        .arena = arena,
    };

    if (cfg.schema_version > 1) {
        return error.UnsupportedSchemaVersion;
    }

    const config_dir = std.fs.path.dirname(path) orelse ".";

    if (!std.fs.path.isAbsolute(cfg.sqlite.path)) {
        cfg.sqlite.path = try std.fs.path.resolve(arena_allocator, &.{ config_dir, cfg.sqlite.path });
    }

    if (cfg.tls.cert_path) |cp| {
        if (!std.fs.path.isAbsolute(cp)) {
            cfg.tls.cert_path = try std.fs.path.resolve(arena_allocator, &.{ config_dir, cp });
        }
    }

    if (cfg.tls.key_path) |kp| {
        if (!std.fs.path.isAbsolute(kp)) {
            cfg.tls.key_path = try std.fs.path.resolve(arena_allocator, &.{ config_dir, kp });
        }
    }

    return cfg;
}

pub fn applyEnvOverrides(cfg: *Config, env: anytype) !void {
    return cfg.applyEnvOverrides(env);
}

pub fn validate(cfg: *const Config) !void {
    return cfg.validate();
}
