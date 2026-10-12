const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });
    const sc2 = b.dependency("zig-sc2", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "sokol", .module = sokol.module("sokol") },
        .{ .name = "zig-sc2", .module = sc2.module("zig-sc2") },
    };
    const exe = b.addExecutable(.{
        .name = "zig_sc2_replay_watcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Watch a replay (-- --replay PATH --sc2 INSTALL_ROOT)").dependOn(&run.step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const test_run = b.addRunArtifact(tests);
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = sc2.path("src/render_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const protocol_run = b.addRunArtifact(protocol_tests);
    const test_step = b.step("test", "Run unit/protocol tests (no SC2 or display required)");
    test_step.dependOn(&test_run.step);
    test_step.dependOn(&protocol_run.step);
}
