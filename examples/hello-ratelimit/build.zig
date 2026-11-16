const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;

    const z_server_dep = b.dependency("z_server", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = b.option(bool, "strip", "Strip debug symbols") orelse false,
    });
    exe_mod.addImport("z_server", z_server_dep.module("z_server"));
    exe_mod.addImport("z_server_cache", z_server_dep.module("z_server_cache"));
    exe_mod.addImport("z_server_ratelimit", z_server_dep.module("z_server_ratelimit"));

    const exe = b.addExecutable(.{
        .name = "hello-ratelimit",
        .root_module = exe_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});

    const strip_cmd = b.addSystemCommand(&.{
        "strip",
        "-s",
        "zig-out/bin/hello-ratelimit",
    });
    strip_cmd.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&strip_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
