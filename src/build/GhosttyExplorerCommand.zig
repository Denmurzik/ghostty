//! `ghostty-explorer.dll`: the `IExplorerCommand` COM server of the Windows
//! 11 top-level "Open Ghostty here" entry. Like `tmux.exe` it imports only
//! std (no SharedDeps, no libc); it links ole32 for `CoTaskMemAlloc`.
const GhosttyExplorerCommand = @This();

const std = @import("std");
const Config = @import("Config.zig");
const windows_version = @import("windows_version.zig");

lib: *std.Build.Step.Compile,
tests: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, test_filters: []const []const u8) GhosttyExplorerCommand {
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ghostty-explorer",
        .root_module = commandModule(b, cfg),
    });
    if (cfg.target.result.os.tag == .windows) {
        const header = windows_version.rcHeader(
            b.allocator,
            cfg.version,
            cfg.optimize == .debug,
            .explorer_command,
        ) catch @panic("OOM");
        lib.root_module.addWin32ResourceFile(.{
            .file = b.path("dist/windows/explorer-command.rc"),
            .include_paths = &.{
                b.addWriteFiles().add("ghostty_version.h", header).dirname(),
            },
        });
    }
    // No DllMain: nothing to do on attach/detach (see main.zig).
    lib.entry = .disabled;
    const install_step = b.addInstallArtifact(lib, .{});

    const tests = b.addTest(.{
        .name = "explorer-command-test",
        .root_module = commandModule(b, cfg),
        .filters = test_filters,
    });

    return .{ .lib = lib, .tests = tests, .install_step = install_step };
}

fn commandModule(b: *std.Build, cfg: *const Config) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/explorer_command/main.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
        .strip = cfg.strip,
        .link_libc = false,
        // No DllMain, so no TLS directory: thread-locals in std (panic
        // state) become plain globals instead of needing `_tls_index`.
        .single_threaded = true,
    });
    mod.linkSystemLibrary("ole32", .{});
    return mod;
}

/// Adds `ghostty-explorer.dll` to the install target.
pub fn install(self: *const GhosttyExplorerCommand) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}

/// Hooks the unit tests (built for the target, run on the host) into `step`.
pub fn addTests(self: *const GhosttyExplorerCommand, step: *std.Build.Step) void {
    const b = self.tests.step.owner;
    step.dependOn(&b.addRunArtifact(self.tests).step);
}
