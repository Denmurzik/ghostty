//! The Windows `tmux.exe` shim: a small console exe that imports only std
//! and the std-only IPC protocol module (no SharedDeps, no libc).
const GhosttyTmuxShim = @This();

const std = @import("std");
const Config = @import("Config.zig");

exe: *std.Build.Step.Compile,
tests: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, test_filters: []const []const u8) GhosttyTmuxShim {
    const protocol = b.createModule(.{
        .root_source_file = b.path("src/apprt/win32/ipc/protocol.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tmux",
        .root_module = shimModule(b, cfg, protocol),
    });
    exe.subsystem = .console;
    const install_step = b.addInstallArtifact(exe, .{});

    const tests = b.addTest(.{
        .name = "tmux-shim-test",
        .root_module = shimModule(b, cfg, protocol),
        .filters = test_filters,
    });

    return .{ .exe = exe, .tests = tests, .install_step = install_step };
}

fn shimModule(b: *std.Build, cfg: *const Config, protocol: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/tmux_shim/main.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
        .strip = cfg.optimize != .debug,
        .link_libc = false,
    });
    mod.addImport("ipc_protocol", protocol);
    return mod;
}

/// Adds `tmux.exe` to the install target.
pub fn install(self: *const GhosttyTmuxShim) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}

/// Hooks the shim's unit tests (built for the target, run on the host)
/// into `step`.
pub fn addTests(self: *const GhosttyTmuxShim, step: *std.Build.Step) void {
    const b = self.tests.step.owner;
    step.dependOn(&b.addRunArtifact(self.tests).step);
}
