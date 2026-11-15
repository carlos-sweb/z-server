const std = @import("std");
const Translator = @import("translate_c").Translator;
const bearssl_sources = @import("vendor/bearssl/sources.zig").sources;

pub fn build(b: *std.Build) void {
    const static = b.option(bool, "static", "static musl build") orelse true;
    const target = b.standardTargetOptions(.{
        .default_target = if (static) .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .musl,
        } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});

    // translate-c is a *build-time* dependency: it produces a Zig module from
    // src/c/bindings.h. Application code then does `@import("c")`. There is no
    // `@cImport`.
    const translate_c_dep = b.dependency("translate_c", .{});
    const c_bindings: Translator = .init(translate_c_dep, .{
        .name = "c",
        .c_source_file = b.path("src/c/bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const c_db_bindings: Translator = .init(translate_c_dep, .{
        .name = "c",
        .c_source_file = b.path("src/db/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_db_bindings.addIncludePath(b.path("vendor/sqlite"));

    const c_cache_bindings: Translator = .init(translate_c_dep, .{
        .name = "c",
        .c_source_file = b.path("src/cache/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_cache_bindings.addIncludePath(b.path("vendor/pogocache"));

    const c_tls_bindings: Translator = .init(translate_c_dep, .{
        .name = "c",
        .c_source_file = b.path("src/tls/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_tls_bindings.addIncludePath(b.path("vendor/bearssl/inc"));

    const version_mod = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_mod = httpz_dep.module("httpz");

    const z_server_mod = b.addModule("z_server", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    z_server_mod.addImport("httpz", httpz_mod);

    const z_server_db_mod = b.addModule("z_server_db", .{
        .root_source_file = b.path("src/db/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    z_server_db_mod.addImport("c", c_db_bindings.mod);
    z_server_db_mod.addIncludePath(b.path("vendor/sqlite"));
    z_server_db_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OPEN_URI=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-std=c11",
        },
        .language = .c,
    });

    const z_server_cache_mod = b.addModule("z_server_cache", .{
        .root_source_file = b.path("src/cache/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    z_server_cache_mod.addImport("c", c_cache_bindings.mod);
    z_server_cache_mod.addIncludePath(b.path("vendor/pogocache"));
    z_server_cache_mod.addCSourceFile(.{
        .file = b.path("vendor/pogocache/pogocache.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
        .language = .c,
    });

    const z_server_tls_mod = b.addModule("z_server_tls", .{
        .root_source_file = b.path("src/tls/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    z_server_tls_mod.addImport("c", c_tls_bindings.mod);
    z_server_tls_mod.addIncludePath(b.path("vendor/bearssl/inc"));
    z_server_tls_mod.addIncludePath(b.path("vendor/bearssl/src"));
    for (bearssl_sources) |src_path| {
        z_server_tls_mod.addCSourceFile(.{
            .file = b.path(src_path),
            .flags = &.{ "-std=c99", "-D_GNU_SOURCE", "-DBR_USE_UNIX_TIME=0", "-DBR_USE_RDTSC=0", "-DBR_LE_UNALIGNED=0", "-fno-sanitize=alignment" },
            .language = .c,
        });
    }

    const z_server_config_mod = b.addModule("z_server_config", .{
        .root_source_file = b.path("src/config/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const z_server_auth_mod = b.addModule("z_server_auth", .{
        .root_source_file = b.path("src/auth/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    z_server_auth_mod.addImport("z_server_db", z_server_db_mod);
    z_server_auth_mod.addImport("z_server_cache", z_server_cache_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_bindings.mod },
            .{ .name = "version", .module = version_mod },
            .{ .name = "httpz", .module = httpz_mod },
            .{ .name = "z_server", .module = z_server_mod },
            .{ .name = "z_server_db", .module = z_server_db_mod },
            .{ .name = "z_server_cache", .module = z_server_cache_mod },
            .{ .name = "z_server_tls", .module = z_server_tls_mod },
            .{ .name = "z_server_config", .module = z_server_config_mod },
            .{ .name = "z_server_auth", .module = z_server_auth_mod },
        },
    });
    if (!static) {
        exe_mod.linkSystemLibrary("m", .{});
    }
    exe_mod.addIncludePath(b.path("src/c"));
    exe_mod.addCSourceFile(.{
        .file = b.path("src/c/bindings.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
        .language = .c,
    });

    const exe = b.addExecutable(.{
        .name = "z-server",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "version", .module = version_mod },
        },
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const http_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/http_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_mod },
            .{ .name = "app", .module = exe_mod },
            .{ .name = "c", .module = c_bindings.mod },
        },
    });
    const http_tests = b.addTest(.{
        .name = "http_smoke",
        .root_module = http_test_mod,
    });
    const run_http_tests = b.addRunArtifact(http_tests);

    const db_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/db_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_db_bindings.mod },
            .{ .name = "app", .module = exe_mod },
            .{ .name = "z_server_db", .module = z_server_db_mod },
        },
    });
    const db_tests = b.addTest(.{
        .name = "db_smoke",
        .root_module = db_test_mod,
    });
    const run_db_tests = b.addRunArtifact(db_tests);

    const items_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/items_http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_mod },
            .{ .name = "app", .module = exe_mod },
            .{ .name = "c", .module = c_bindings.mod },
        },
    });
    const items_tests = b.addTest(.{
        .name = "items_http",
        .root_module = items_test_mod,
    });
    const run_items_tests = b.addRunArtifact(items_tests);

    const cache_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cache_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = exe_mod },
            .{ .name = "z_server_cache", .module = z_server_cache_mod },
        },
    });
    const cache_tests = b.addTest(.{
        .name = "cache_smoke",
        .root_module = cache_test_mod,
    });
    const run_cache_tests = b.addRunArtifact(cache_tests);

    const config_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/config_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = exe_mod },
            .{ .name = "c", .module = c_bindings.mod },
            .{ .name = "z_server_config", .module = z_server_config_mod },
        },
    });
    const config_tests = b.addTest(.{
        .name = "config_test",
        .root_module = config_test_mod,
    });
    const run_config_tests = b.addRunArtifact(config_tests);

    const tls_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/tls_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = exe_mod },
            .{ .name = "c", .module = c_tls_bindings.mod },
            .{ .name = "z_server_tls", .module = z_server_tls_mod },
        },
    });
    const tls_tests = b.addTest(.{
        .name = "tls_test",
        .root_module = tls_test_mod,
    });
    const run_tls_tests = b.addRunArtifact(tls_tests);

    const auth_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/auth_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z_server_auth", .module = z_server_auth_mod },
            .{ .name = "z_server_db", .module = z_server_db_mod },
            .{ .name = "z_server_cache", .module = z_server_cache_mod },
        },
    });
    const auth_tests = b.addTest(.{
        .name = "auth_test",
        .root_module = auth_test_mod,
    });
    const run_auth_tests = b.addRunArtifact(auth_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_items_tests.step);
    test_step.dependOn(&run_cache_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_tls_tests.step);
    test_step.dependOn(&run_auth_tests.step);
}
