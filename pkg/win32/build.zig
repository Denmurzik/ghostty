const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to the MSVC ABI like the main build (see src/build/Config.zig).
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .msvc },
    });
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("win32", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.linkSystemLibrary("d3d11", .{});
    module.linkSystemLibrary("dxgi", .{});

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_spike.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win32", .module = module }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the pkg/win32 tests");
    test_step.dependOn(&run_tests.step);
}
