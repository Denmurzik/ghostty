//! The bundled ConPTY on Windows: `conpty.dll` and `OpenConsole.exe` from
//! the `Microsoft.Windows.Console.ConPTY` package (MIT, microsoft/terminal),
//! installed next to `ghostty.exe` together with the third-party notice.
//! See `windows-conpty` in the config and `vendor/conpty/README.md`.

const std = @import("std");
const Config = @import("Config.zig");
const conpty_pins = @import("conpty_pins.zig");

/// The package's name for the target architecture, null when it ships none.
pub fn arch(cpu: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => null,
    };
}

/// Adds the pair for the target and the notice to the install step. The
/// files come from `-Dconpty-dir` (the vendored layout `<arch>/<file>` or
/// an unpacked NuGet package) or else from `vendor/conpty`. Missing files
/// are a warning, not an error: Ghostty then runs on the inbox ConPTY.
pub fn install(b: *std.Build, cfg: *const Config) void {
    const a = arch(cfg.target.result.cpu.arch) orelse {
        std.log.warn("no bundled ConPTY for {s}: ghostty.exe will use the inbox ConPTY (no Kitty graphics, no SGR 58)", .{
            @tagName(cfg.target.result.cpu.arch),
        });
        return;
    };

    const io = b.graph.io;
    // `prefix` for the checks now, `root` for the install steps.
    const base = std.Io.Dir.cwd();
    const prefix = cfg.conpty_dir orelse b.root.joinString(b.allocator, "vendor/conpty") catch @panic("OOM");
    const root: std.Build.LazyPath = if (cfg.conpty_dir) |dir| .{ .cwd_relative = dir } else b.path("vendor/conpty");

    // An unpacked NuGet package has `runtimes/`; the vendored copy does not.
    const nuget = if (base.access(io, b.pathJoin(&.{ prefix, "runtimes" }), .{})) |_| true else |_| false;
    const files = [_]struct { []const u8, []const u8 }{
        .{ if (nuget) b.fmt("runtimes/win-{s}/native/conpty.dll", .{a}) else b.fmt("{s}/conpty.dll", .{a}), "conpty.dll" },
        .{ if (nuget) b.fmt("build/native/runtimes/{s}/OpenConsole.exe", .{a}) else b.fmt("{s}/OpenConsole.exe", .{a}), "OpenConsole.exe" },
    };
    for (files) |f| {
        base.access(io, b.pathJoin(&.{ prefix, f[0] }), .{}) catch {
            std.log.warn("bundled ConPTY: {s}/{s} is missing: ghostty.exe will use the inbox ConPTY (no Kitty graphics, no SGR 58)", .{ prefix, f[0] });
            return;
        };
    }

    // Whatever directory it is, the files must be the pinned ones.
    const pin_path = b.root.joinString(b.allocator, "vendor/conpty/README.md") catch @panic("OOM");
    const readme = base.readFileAlloc(io, pin_path, b.allocator, .limited(1 << 20)) catch |err|
        std.process.fatal("bundled ConPTY: cannot read the pins in {s}: {t}", .{ pin_path, err });
    for (files, [_][]const u8{ "conpty.dll", "OpenConsole.exe" }) |f, name| {
        const key = b.fmt("{s}/{s}", .{ a, name });
        const pin = conpty_pins.pinFor(readme, key) orelse
            std.process.fatal("bundled ConPTY: vendor/conpty/README.md pins no hash for {s}", .{key});
        const path = b.pathJoin(&.{ prefix, f[0] });
        const bytes = base.readFileAlloc(io, path, b.allocator, .limited(64 << 20)) catch |err|
            std.process.fatal("bundled ConPTY: cannot read {s}: {t}", .{ path, err });
        if (!conpty_pins.matches(bytes, pin))
            std.process.fatal("bundled ConPTY: {s} does not match the SHA-256 pinned in vendor/conpty/README.md ({s})", .{ path, pin });
    }

    for (files) |f| {
        b.getInstallStep().dependOn(&b.addInstallBinFile(root.path(b, f[0]), f[1]).step);
    }
    // The notice text ships as THIRD_PARTY_NOTICES.txt, staged by
    // dist/windows/package.ps1.
}
