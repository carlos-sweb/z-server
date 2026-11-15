const std = @import("std");
const app = @import("app");
const config = app.config;
const c = @import("c");

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    _ = c.write(fd, data.ptr, data.len);
}

fn deleteFile(path: [*:0]const u8) void {
    _ = c.unlink(path);
}

fn cleanupDbFiles(a: std.mem.Allocator, db_path: [:0]const u8) void {
    deleteFile(db_path);
    if (std.fmt.allocPrintSentinel(a, "{s}-wal", .{db_path}, 0)) |wal| {
        defer a.free(wal);
        deleteFile(wal);
    } else |_| {}
    if (std.fmt.allocPrintSentinel(a, "{s}-shm", .{db_path}, 0)) |shm| {
        defer a.free(shm);
        deleteFile(shm);
    } else |_| {}
}

test "1. valid config file loads OK" {
    const a = std.testing.allocator;
    const json_text =
        \\{
        \\  "$schema_version": 1,
        \\  "server": {
        \\    "bind": "127.0.0.1:9090",
        \\    "handler_threads": 8,
        \\    "max_body_size": 32768
        \\  },
        \\  "sqlite": {
        \\    "path": "/tmp/test.db",
        \\    "pool_size": 8,
        \\    "synchronous": "FULL"
        \\  },
        \\  "cache": {
        \\    "nshards": 256,
        \\    "default_ttl_s": 30
        \\  }
        \\}
    ;
    const tmp_path = "/tmp/test_config_valid.json";
    try writeFile(tmp_path, json_text);
    defer deleteFile(tmp_path);

    var cfg = try config.load(a, tmp_path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try std.testing.expectEqualStrings("127.0.0.1:9090", cfg.server.bind);
    try std.testing.expectEqual(@as(?u16, 8), cfg.server.handler_threads);
    try std.testing.expectEqual(@as(u32, 32768), cfg.server.max_body_size);
    try std.testing.expectEqualStrings("/tmp/test.db", cfg.sqlite.path);
    try std.testing.expectEqual(@as(?u16, 8), cfg.sqlite.pool_size);
    try std.testing.expectEqualStrings("FULL", cfg.sqlite.synchronous);
    try std.testing.expectEqual(@as(u16, 256), cfg.cache.nshards);
    try std.testing.expectEqual(@as(u32, 30), cfg.cache.default_ttl_s);
}

test "2. relative paths resolve against config directory" {
    const a = std.testing.allocator;
    _ = c.mkdir("/tmp/zs_cfg_dir", 0o755);
    _ = c.mkdir("/tmp/zs_cfg_dir/sub", 0o755);
    defer {
        deleteFile("/tmp/zs_cfg_dir/config.json");
        _ = c.rmdir("/tmp/zs_cfg_dir/sub");
        _ = c.rmdir("/tmp/zs_cfg_dir");
    }

    const json_text =
        \\{
        \\  "sqlite": {
        \\    "path": "sub/app.db"
        \\  },
        \\  "tls": {
        \\    "cert_path": "sub/server.crt",
        \\    "key_path": "sub/server.key"
        \\  }
        \\}
    ;
    const cfg_path = "/tmp/zs_cfg_dir/config.json";
    try writeFile(cfg_path, json_text);

    var cfg = try config.load(a, cfg_path);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("/tmp/zs_cfg_dir/sub/app.db", cfg.sqlite.path);
    try std.testing.expectEqualStrings("/tmp/zs_cfg_dir/sub/server.crt", cfg.tls.cert_path.?);
    try std.testing.expectEqualStrings("/tmp/zs_cfg_dir/sub/server.key", cfg.tls.key_path.?);
}

test "3. env vars override config values" {
    var cfg = config.Config{};
    cfg.server.bind = "127.0.0.1:8080";
    cfg.server.handler_threads = 4;
    cfg.sqlite.pool_size = 4;

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();

    try map.put("Z_SERVER_BIND", "0.0.0.0:9999");
    try map.put("Z_SERVER_HANDLER_THREADS", "16");
    try map.put("Z_SERVER_SQLITE_POOL", "12");

    try cfg.applyEnvOverrides(&map);

    try std.testing.expectEqualStrings("0.0.0.0:9999", cfg.server.bind);
    try std.testing.expectEqual(@as(?u16, 16), cfg.server.handler_threads);
    try std.testing.expectEqual(@as(?u16, 12), cfg.sqlite.pool_size);
}

test "4. Z_SERVER_TLS_CERT_PATH in env fails explicitly" {
    var cfg = config.Config{};
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();

    try map.put("Z_SERVER_TLS_CERT_PATH", "/some/cert.crt");
    const res = cfg.applyEnvOverrides(&map);
    try std.testing.expectError(error.TlsPathsNotAllowedInEnv, res);
}

test "5. invalid JSON fails with parse error" {
    const a = std.testing.allocator;
    const bad_json = "not valid json {{{";
    const tmp_path = "/tmp/test_bad_json.json";
    try writeFile(tmp_path, bad_json);
    defer deleteFile(tmp_path);

    const res = config.load(a, tmp_path);
    try std.testing.expectError(error.SyntaxError, res);
}

test "6. schema_version = 2 fails with UnsupportedSchemaVersion" {
    const a = std.testing.allocator;
    const json_text =
        \\{
        \\  "$schema_version": 2
        \\}
    ;
    const tmp_path = "/tmp/test_v2.json";
    try writeFile(tmp_path, json_text);
    defer deleteFile(tmp_path);

    const res = config.load(a, tmp_path);
    try std.testing.expectError(error.UnsupportedSchemaVersion, res);
}

test "7. without config file defaults match v0.2.0" {
    const cfg = config.Config{};
    try std.testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try std.testing.expectEqualStrings("0.0.0.0:8080", cfg.server.bind);
    try std.testing.expect(cfg.server.handler_threads == null);
    try std.testing.expectEqualStrings("data/app.db", cfg.sqlite.path);
    try std.testing.expect(cfg.sqlite.pool_size == null);
    try std.testing.expectEqualStrings("NORMAL", cfg.sqlite.synchronous);
    try std.testing.expectEqual(@as(u16, 512), cfg.cache.nshards);
    try std.testing.expectEqual(false, cfg.tls.enabled);
}

test "8. tls.enabled=true and missing cert file fails validate" {
    var cfg = config.Config{};
    cfg.tls.enabled = true;
    cfg.tls.cert_path = "/nonexistent/test.crt";
    cfg.tls.key_path = "/nonexistent/test.key";

    const res = cfg.validate();
    try std.testing.expectError(error.CertFileNotFound, res);
}

test "config sqlite.synchronous=NORMAL results in PRAGMA=1" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const json_text =
        \\{
        \\  "$schema_version": 1,
        \\  "sqlite": {
        \\    "path": "/tmp/test_synch_norm.db",
        \\    "synchronous": "NORMAL"
        \\  }
        \\}
    ;
    const tmp_cfg = "/tmp/test_synch_norm.json";
    try writeFile(tmp_cfg, json_text);
    defer deleteFile(tmp_cfg);

    var cfg = try config.load(a, tmp_cfg);
    defer cfg.deinit();

    const synch_c = try a.dupeSentinel(u8, cfg.sqlite.synchronous, 0);
    defer a.free(synch_c);
    _ = c.setenv("Z_SERVER_SQLITE_SYNCHRONOUS", synch_c, 1);

    var n: u64 = undefined;
    io.random(std.mem.asBytes(&n));
    const db_path = try std.fmt.allocPrintSentinel(a, "/tmp/test_synch_norm_{d}.db", .{n}, 0);
    defer {
        cleanupDbFiles(a, db_path);
        a.free(db_path);
    }

    var p = try app.pool.Pool.init(a, io, .{ .path = db_path, .pool_size = 2 });
    defer p.deinit();

    const snap = p.snapshotSynchronous();
    try std.testing.expectEqual(@as(u8, 1), snap.first);
    try std.testing.expectEqual(true, snap.all_normal);
}

test "config sqlite.synchronous=FULL results in PRAGMA=2" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const json_text =
        \\{
        \\  "$schema_version": 1,
        \\  "sqlite": {
        \\    "path": "/tmp/test_synch_full.db",
        \\    "synchronous": "FULL"
        \\  }
        \\}
    ;
    const tmp_cfg = "/tmp/test_synch_full.json";
    try writeFile(tmp_cfg, json_text);
    defer deleteFile(tmp_cfg);

    var cfg = try config.load(a, tmp_cfg);
    defer cfg.deinit();

    const synch_c = try a.dupeSentinel(u8, cfg.sqlite.synchronous, 0);
    defer a.free(synch_c);
    _ = c.setenv("Z_SERVER_SQLITE_SYNCHRONOUS", synch_c, 1);

    var n: u64 = undefined;
    io.random(std.mem.asBytes(&n));
    const db_path = try std.fmt.allocPrintSentinel(a, "/tmp/test_synch_full_{d}.db", .{n}, 0);
    defer {
        cleanupDbFiles(a, db_path);
        a.free(db_path);
    }

    var p = try app.pool.Pool.init(a, io, .{ .path = db_path, .pool_size = 2 });
    defer p.deinit();

    const snap = p.snapshotSynchronous();
    try std.testing.expectEqual(@as(u8, 2), snap.first);
    try std.testing.expectEqual(false, snap.all_normal);
}
