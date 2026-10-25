//! Proof for building a GUI-subsystem (`/SUBSYSTEM:WINDOWS`) executable that
//! links libc and uses a plain Zig `main`.
//!
//! With `subsystem = .windows` the linker looks for `WinMain` unless the entry
//! point is overridden. Pointing the entry at the CRT's `mainCRTStartup` makes
//! the CRT startup call Zig's `main` instead.
//!
//! Build: zig build --build-file test/windows/gui-entry/build.zig
//! Run:   ./test/windows/gui-entry/zig-out/bin/gui-entry.exe; echo rc=$?  (7)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .msvc },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gui-entry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.subsystem = .windows;
    exe.entry = .{ .symbol_name = "mainCRTStartup" };

    b.installArtifact(exe);
}
