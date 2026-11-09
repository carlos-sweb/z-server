const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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
        .link_system_libs = &.{
            .{ .name = "sqlite3" },
        },
    });
    c_bindings.addIncludePath(b.path("vendor/pogocache"));

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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_bindings.mod },
            .{ .name = "version", .module = version_mod },
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.linkSystemLibrary("m", .{});
    exe_mod.addIncludePath(b.path("vendor/pogocache"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/pogocache/pogocache.c"),
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
            .{ .name = "c", .module = c_bindings.mod },
            .{ .name = "app", .module = exe_mod },
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
        },
    });
    const cache_tests = b.addTest(.{
        .name = "cache_smoke",
        .root_module = cache_test_mod,
    });
    const run_cache_tests = b.addRunArtifact(cache_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_items_tests.step);
    test_step.dependOn(&run_cache_tests.step);
}
