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
    for ([_][]const u8{
        "user32",   "gdi32",   "dwmapi",  "imm32", "ole32", "advapi32", "d3d11", "dxgi",
        "comctl32", "shell32", "uxtheme", "winmm", "d2d1",  "dwrite",
    }) |lib| module.linkSystemLibrary(lib, .{});

    const test_step = b.step("test", "Run the pkg/win32 tests");
    for ([_][]const u8{ "test_spike.zig", "test_user32.zig", "test_d2d.zig" }) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "win32", .module = module }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
