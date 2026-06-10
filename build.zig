const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run boo");
    const test_step = b.step("test", "Run unit tests");
    const integration_step = b.step("test-integration", "Run PTY integration tests");
    const test_all_step = b.step("test-all", "Run all tests");

    // Main executable module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libghostty-vt provides the terminal emulation core.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "boo",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Unit tests (in-process, no TTY required).
    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests: drive the real binary through a real PTY.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("exe_path", exe.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addOptions("build_options", test_opts);
    // The tests render captured client output through a terminal
    // emulator to assert what a user would actually see.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    test_all_step.dependOn(test_step);
    test_all_step.dependOn(integration_step);
}
