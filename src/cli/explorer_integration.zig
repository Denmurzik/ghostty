//! The work of `+install-explorer-integration` and
//! `+uninstall-explorer-integration` (R-M5-5): the Explorer "Open Ghostty
//! here" verbs under `HKCU\Software\Classes`. The two action files only carry
//! the help text and re-export the options.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");
const explorer = internal_os.windows_explorer;
const registry = internal_os.windows_registry;

/// Names a registry hive file to use instead of `HKEY_CURRENT_USER`. Tests
/// only: the e2e scenario and the unit tests keep the owner's registry out of
/// it. Ignored in an elevated process (`diagnosticEnv`).
const test_hive_var = "GHOSTTY_WIN32_TEST_HIVE";

pub const InstallOptions = struct {
    /// Print what would be written and open no registry key.
    @"dry-run": bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: InstallOptions) !void {
        _ = self;
        return Action.help_error;
    }
};

pub const UninstallOptions = struct {
    /// Print what would be deleted and open no registry key.
    @"dry-run": bool = false,

    /// Also remove the notification registration and its icon file.
    all: bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: UninstallOptions) !void {
        _ = self;
        return Action.help_error;
    }
};

const supported = builtin.os.tag == .windows;

pub fn runInstall(alloc: Allocator) !u8 {
    var opts: InstallOptions = .{};
    if (try parseOptions(InstallOptions, alloc, &opts)) |code| return code;
    return runWith(alloc, .{ .install = opts });
}

pub fn runUninstall(alloc: Allocator) !u8 {
    var opts: UninstallOptions = .{};
    if (try parseOptions(UninstallOptions, alloc, &opts)) |code| return code;
    return runWith(alloc, .{ .uninstall = opts });
}

fn parseOptions(comptime T: type, alloc: Allocator, opts: *T) !?u8 {
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();

    args.parse(T, alloc, opts, &iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            var buf: [256]u8 = undefined;
            var w = std.Io.File.stderr().writer(global.io(), &buf);
            w.interface.print("Error parsing args: {}\n", .{err}) catch {};
            w.interface.flush() catch {};
            return 1;
        },
    };
    return null;
}

const Request = union(enum) {
    install: InstallOptions,
    uninstall: UninstallOptions,
};

fn runWith(alloc: Allocator, request: Request) !u8 {
    var out_buf: [1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    if (comptime !supported) {
        var err_buf: [128]u8 = undefined;
        var err_writer = std.Io.File.stderr().writer(global.io(), &err_buf);
        err_writer.interface.writeAll("only supported on Windows\n") catch {};
        err_writer.interface.flush() catch {};
        return 1;
    }

    const dry_run = switch (request) {
        inline else => |o| o.@"dry-run",
    };

    // A dry run opens nothing, so it needs no root.
    var hive: ?registry.Root = null;
    defer if (hive) |h| registry.close(h);
    var root: ?registry.Root = null;
    if (!dry_run) {
        if (internal_os.windows.diagnosticEnv(alloc, test_hive_var)) |path| {
            defer alloc.free(path);
            hive = registry.openTestHive(path) catch |err| {
                try out.print("cannot open the test hive: {}\n", .{err});
                return 1;
            };
            root = hive;
        } else root = registry.hkcu;
    }

    switch (request) {
        .install => {
            var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
                try out.print("cannot find the running executable: {}\n", .{err});
                return 1;
            };
            return install(alloc, out, root, exe_buf[0..exe_len]);
        },
        .uninstall => |o| {
            const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch null;
            defer if (base) |b| alloc.free(b);
            return uninstall(alloc, out, root, o.all, base);
        },
    }
}

fn printSet(out: *std.Io.Writer, subkey: []const u8, name: ?[]const u8, value: []const u8) !void {
    try out.print("set {s}\\{s}\\{s} = {s}\n", .{ explorer.verbs_root, subkey, name orelse "(default)", value });
}

/// Writes the verbs under `root`; a null `root` is a dry run that opens
/// nothing.
fn install(alloc: Allocator, out: *std.Io.Writer, root: ?registry.Root, exe_path: []const u8) !u8 {
    const writes = try explorer.installWrites(alloc, exe_path);
    defer explorer.freeWrites(alloc, writes);

    for (writes) |w| {
        if (root) |r| {
            const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, w.subkey });
            defer alloc.free(full);
            registry.setString(r, full, w.name, w.value) catch |err| {
                try out.print("failed to write {s}: {}\n", .{ full, err });
                return 1;
            };
        }
        try printSet(out, w.subkey, w.name, w.value);
    }
    return 0;
}

/// Deletes the verbs that are ours (and with `all` the notification
/// registration and icon). A null `root` is a dry run: it lists every delete
/// and opens nothing.
fn uninstall(
    alloc: Allocator,
    out: *std.Io.Writer,
    root: ?registry.Root,
    all: bool,
    local_app_data: ?[]const u8,
) !u8 {
    var failed = false;

    for (explorer.key_names) |key| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, key });
        defer alloc.free(full);

        if (root) |r| {
            const command_key = try std.fmt.allocPrint(alloc, "{s}\\command", .{full});
            defer alloc.free(command_key);
            const command = registry.getString(alloc, r, command_key, null) catch |err| {
                try out.print("failed to read {s}: {}\n", .{ command_key, err });
                failed = true;
                continue;
            } orelse {
                try out.print("not installed: {s}\n", .{full});
                continue;
            };
            defer alloc.free(command);
            if (!explorer.ownsCommand(command)) {
                try out.print("kept (not ours): {s}\n", .{full});
                continue;
            }
            registry.deleteTree(r, full) catch |err| {
                try out.print("failed to delete {s}: {}\n", .{ full, err });
                failed = true;
                continue;
            };
        }
        try out.print("delete {s}\n", .{full});
    }

    if (all) {
        if (root) |r| {
            registry.deleteTree(r, explorer.aumid_subkey) catch |err| {
                try out.print("failed to delete {s}: {}\n", .{ explorer.aumid_subkey, err });
                failed = true;
            };
        }
        try out.print("delete {s}\n", .{explorer.aumid_subkey});

        if (local_app_data) |base| {
            const icon = try std.fmt.allocPrint(alloc, "{s}\\ghostty\\{s}", .{ base, explorer.toast_icon_name });
            defer alloc.free(icon);
            if (root != null) {
                std.Io.Dir.cwd().deleteFile(global.io(), icon) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => {
                        try out.print("failed to delete {s}: {}\n", .{ icon, err });
                        failed = true;
                    },
                };
            }
            try out.print("delete {s}\n", .{icon});
        }
    }

    return if (failed) 1 else 0;
}

test "explorer cli: dry-run install prints the nine writes and opens nothing" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, null, "C:\\g\\ghostty.exe"));

    const head = "set Software\\Classes\\Directory\\shell\\GhosttyOpenHere";
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, "set Software\\Classes\\"));
    }
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), head ++ "\\(default) = Open Ghostty here\n" ++ head ++ "\\Icon = \"C:\\g\\ghostty.exe\",0\n"));
}

test "explorer cli: dry-run uninstall --all lists the deletes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, null, true, "C:\\Users\\x\\AppData\\Local"));

    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, "delete "));
    }
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, aw.written(), "\n"), "\\ghostty\\toast-icon.png"));
}

test "explorer cli: install then uninstall in a private hive keeps a foreign key" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    const hive = try std.fmt.allocPrint(alloc, "{s}\\c.hive", .{base});
    defer alloc.free(hive);

    const root = try registry.openTestHive(hive);
    var open = true;
    defer if (open) registry.close(root);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // A foreign verb on the drive key.
    const foreign = "Software\\Classes\\Drive\\shell\\GhosttyOpenHere\\command";
    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, root, "C:\\g\\ghostty.exe"));
    try registry.setString(root, foreign, null, "\"C:\\x\\code.exe\" \"%V\"");

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, root, false, null));
    for (explorer.key_names[0..2]) |key| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}\\command", .{ explorer.verbs_root, key });
        defer alloc.free(full);
        try std.testing.expect((try registry.getString(alloc, root, full, null)) == null);
    }
    const kept = (try registry.getString(alloc, root, foreign, null)).?;
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("\"C:\\x\\code.exe\" \"%V\"", kept);

    try registry.deleteTree(root, "Software\\Classes\\Drive");
    registry.close(root);
    open = false;

    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        var gone = true;
        for ([_][]const u8{ "c.hive", "c.hive.LOG1", "c.hive.LOG2" }) |name| {
            tmp.dir.deleteFile(std.testing.io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => gone = false,
            };
        }
        if (gone) break;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}
