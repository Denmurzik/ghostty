//! Builds the composition spike (risk R10): a standalone GUI exe that checks
//! DirectComposition child targets, a transparent client area, Acrylic,
//! re-parenting and swap-chain mode switches. Throwaway test code, not part of
//! Ghostty; run.ps1 launches it inside the desktop lock.
//!
//! Build: zig build -j6 --build-file test/windows/composition-spike/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .msvc },
    });
    const optimize = b.standardOptimizeOption(.{});

    const win32 = b.createModule(.{
        .root_source_file = b.path("../../../pkg/win32/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{
        "user32",   "gdi32",   "dwmapi",  "imm32", "ole32", "advapi32", "d3d11",    "dxgi",
        "comctl32", "shell32", "uxtheme", "winmm", "d2d1",  "dwrite",   "comdlg32",
    }) |lib| win32.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{
        .name = "composition-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        }),
    });
    exe.subsystem = .windows;
    exe.entry = .{ .symbol_name = "mainCRTStartup" };

    b.installArtifact(exe);
}
