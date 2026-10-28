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

    /// Replace an existing entry whose command is not Ghostty's.
    force: bool = false,

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

    /// Delete a verb only if its command names this very ghostty.exe, so
    /// that uninstalling one copy keeps the verbs of another.
    @"only-this-exe": bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: UninstallOptions) !void {
        _ = self;
        return Action.help_error;
    }
};

const supported = builtin.os.tag == .windows;

/// The test hive is honoured only with this set to `1` as well, like the
/// other test hooks, so a stray `GHOSTTY_WIN32_TEST_HIVE` cannot turn an
/// install into a silent no-op.
const test_mode_var = "GHOSTTY_WIN32_TEST_IPC";

const InstallRun = struct {
    force: bool = false,
    /// Test seam: fail the Nth write.
    fail_at: ?usize = null,
};

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
        const test_mode = if (internal_os.windows.diagnosticEnv(alloc, test_mode_var)) |v| m: {
            defer alloc.free(v);
            break :m std.mem.eql(u8, v, "1");
        } else false;
        const hive_path = if (test_mode) internal_os.windows.diagnosticEnv(alloc, test_hive_var) else null;
        if (hive_path) |path| {
            defer alloc.free(path);
            var ebuf: [1200]u8 = undefined;
            var ew = std.Io.File.stderr().writer(global.io(), &ebuf);
            ew.interface.print("using test hive {s}\n", .{path}) catch {};
            ew.interface.flush() catch {};
            hive = registry.openTestHive(path) catch |err| {
                try out.print("cannot open the test hive: {}\n", .{err});
                return 1;
            };
            root = hive;
        } else root = registry.hkcu;
    }

    switch (request) {
        .install => |o| {
            var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
                try out.print("cannot find the running executable: {}\n", .{err});
                return 1;
            };
            return install(alloc, out, root, exe_buf[0..exe_len], .{ .force = o.force });
        },
        .uninstall => |o| {
            const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch null;
            defer if (base) |b| alloc.free(b);
            var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var only_exe: ?[]const u8 = null;
            if (o.@"only-this-exe") {
                const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
                    try out.print("cannot find the running executable: {}\n", .{err});
                    return 1;
                };
                only_exe = exe_buf[0..exe_len];
            }
            return uninstall(alloc, out, root, o.all, base, only_exe);
        },
    }
}

fn printSet(out: *std.Io.Writer, subkey: []const u8, name: ?[]const u8, value: []const u8) !void {
    try out.print("set {s}\\{s}\\{s} = {s}\n", .{ explorer.verbs_root, subkey, name orelse "(default)", value });
}

/// Writes the verbs under `root`; a null `root` is a dry run that opens
/// nothing.
fn install(
    alloc: Allocator,
    out: *std.Io.Writer,
    root: ?registry.Root,
    exe_path: []const u8,
    run: InstallRun,
) !u8 {
    const writes = try explorer.installWrites(alloc, exe_path);
    defer explorer.freeWrites(alloc, writes);

    // Which of the three keys exist already: a failed run removes only the
    // keys it created, and a command that is not ours is never replaced
    // without `--force`.
    var existed: [explorer.key_names.len]bool = @splat(false);
    if (root) |r| for (explorer.key_names, 0..) |key, i| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, key });
        defer alloc.free(full);
        const command_key = try std.fmt.allocPrint(alloc, "{s}\\command", .{full});
        defer alloc.free(command_key);

        const command = registry.getString(alloc, r, command_key, null) catch null;
        defer if (command) |c| alloc.free(c);
        const menu = registry.getString(alloc, r, full, null) catch null;
        defer if (menu) |m| alloc.free(m);
        existed[i] = command != null or menu != null;

        if (command) |c| if (!explorer.ownsCommand(c) and !run.force) {
            try out.print("refusing to replace {s}: its command is not Ghostty's (use --force)\n", .{full});
            return 1;
        };
    };

    for (writes, 0..) |w, n| {
        if (root) |r| {
            const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, w.subkey });
            defer alloc.free(full);
            const injected = run.fail_at != null and run.fail_at.? == n;
            const ok = !injected and ok: {
                registry.setString(r, full, w.name, w.value) catch |err| {
                    try out.print("failed to write {s}: {}\n", .{ full, err });
                    break :ok false;
                };
                break :ok true;
            };
            if (!ok) {
                if (injected) try out.print("failed to write {s}: injected\n", .{full});
                rollback(alloc, out, r, &existed);
                return 1;
            }
        }
        try printSet(out, w.subkey, w.name, w.value);
    }
    return 0;
}

/// Removes the verb keys this run created.
fn rollback(alloc: Allocator, out: *std.Io.Writer, root: registry.Root, existed: []const bool) void {
    for (explorer.key_names, 0..) |key, i| {
        if (existed[i]) continue;
        const full = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, key }) catch continue;
        defer alloc.free(full);
        registry.deleteTree(root, full) catch {};
        out.print("rolled back {s}\n", .{full}) catch {};
    }
}

const win = struct {
    extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, len: u32, buf: ?[*]u16, file_part: ?*?[*]u16) callconv(.winapi) u32;
    extern "kernel32" fn GetShortPathNameW(name: [*:0]const u16, buf: ?[*]u16, len: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetLongPathNameW(name: [*:0]const u16, buf: ?[*]u16, len: u32) callconv(.winapi) u32;
    extern "kernel32" fn CompareStringOrdinal(a: [*]const u16, a_len: i32, b: [*]const u16, b_len: i32, ignore_case: i32) callconv(.winapi) i32;
};

const path_cap = 2100;

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// `X:\...` or `\\server\...`. A drive-relative, rooted-only or bare name
/// would be resolved against the current directory, so it is never accepted.
fn isAbsolute(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSep(p[2])) return true;
    return p.len >= 3 and isSep(p[0]) and isSep(p[1]) and !isSep(p[2]);
}

/// R-M6-5: UTF-8 path to a full, long UTF-16 path (no `\\?\` prefix, no 8.3
/// names). A path that does not exist keeps its full form. A relative path
/// is refused (null): `GetFullPathNameW` would anchor it at our cwd, and a
/// foreign verb could then look like ours. Junctions and `subst` drives are
/// not resolved: a copy reached through another alias is missed (its verbs
/// stay), never a foreign one deleted.
fn normalizePath(path: []const u8, out: *[path_cap]u16) ?[]const u16 {
    var raw: [path_cap:0]u16 = undefined;
    var unc: [path_cap]u8 = undefined;
    const trimmed = if (std.ascii.startsWithIgnoreCase(path, "\\\\?\\UNC\\") and path.len > 8) t: {
        // \\?\UNC\server\share -> \\server\share
        if (path.len - 6 > unc.len) return null;
        unc[0] = '\\';
        @memcpy(unc[1 .. path.len - 6], path[7..]);
        break :t unc[0 .. path.len - 7 + 1];
    } else if (std.mem.startsWith(u8, path, "\\\\?\\") and path.len > 6 and path[5] == ':')
        path[4..]
    else
        path;
    if (!isAbsolute(trimmed)) return null;
    const n = std.unicode.utf8ToUtf16Le(&raw, trimmed) catch return null;
    if (n >= path_cap) return null;
    raw[n] = 0;

    var full: [path_cap:0]u16 = undefined;
    const fl = win.GetFullPathNameW(&raw, path_cap, &full, null);
    if (fl == 0 or fl >= path_cap) return null;
    full[fl] = 0;

    const ll = win.GetLongPathNameW(&full, out, path_cap);
    if (ll != 0 and ll < path_cap) return out[0..ll];
    @memcpy(out[0..fl], full[0..fl]);
    return out[0..fl];
}

/// `explorer.PathEql` for the CLI.
fn pathsEqual(a: []const u8, b: []const u8) bool {
    var abuf: [path_cap]u16 = undefined;
    var bbuf: [path_cap]u16 = undefined;
    const na = normalizePath(a, &abuf) orelse return false;
    const nb = normalizePath(b, &bbuf) orelse return false;
    // CSTR_EQUAL
    return win.CompareStringOrdinal(na.ptr, @intCast(na.len), nb.ptr, @intCast(nb.len), 1) == 2;
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
    only_exe: ?[]const u8,
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
            };
            defer if (command) |c| alloc.free(c);
            const menu = registry.getString(alloc, r, full, null) catch null;
            defer if (menu) |m| alloc.free(m);
            if (command == null and menu == null) {
                try out.print("not installed: {s}\n", .{full});
                continue;
            }
            if (!explorer.ownsKeyFor(command, menu, only_exe, pathsEqual)) {
                const any_ghostty = only_exe != null and explorer.ownsKey(command, menu);
                try out.print("kept ({s}): {s}\n", .{ if (any_ghostty) "other ghostty.exe" else "not ours", full });
                continue;
            }
            registry.deleteTree(r, full) catch |err| {
                try out.print("failed to delete {s}: {}\n", .{ full, err });
                failed = true;
                continue;
            };
        }
        if (root == null and only_exe != null) {
            try out.print("delete {s} if its command names {s}\n", .{ full, only_exe.? });
        } else try out.print("delete {s}\n", .{full});
    }

    if (all) {
        // Both build modes' registrations, whichever exist.
        for (explorer.aumid_subkeys) |subkey| {
            if (root) |r| {
                registry.deleteTree(r, subkey) catch |err| {
                    try out.print("failed to delete {s}: {}\n", .{ subkey, err });
                    failed = true;
                };
            }
            try out.print("delete {s}\n", .{subkey});
        }

        if (local_app_data) |base| {
            for ([_][]const u8{ explorer.toast_icon_name, explorer.legacy_toast_icon_name }) |name| {
                const icon = try std.fmt.allocPrint(alloc, "{s}\\ghostty\\{s}", .{ base, name });
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
    }

    return if (failed) 1 else 0;
}

test "explorer cli: dry-run install prints the nine writes and opens nothing" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, null, "C:\\g\\ghostty.exe", .{}));

    const head = "set Software\\Classes\\Directory\\shell\\GhosttyOpenHere";
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, "set Software\\Classes\\"));
    }
    try std.testing.expectEqual(@as(usize, 9), n);
    // command first, then the menu text, then the (unquoted) icon
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), head ++
        "\\command\\(default) = \"C:\\g\\ghostty.exe\" \"--working-directory=%V\\.\"\n" ++ head ++
        "\\(default) = Open Ghostty here\n" ++ head ++ "\\Icon = C:\\g\\ghostty.exe,0\n"));
}

test "explorer cli: dry-run uninstall --all lists the deletes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, null, true, "C:\\Users\\x\\AppData\\Local", null));

    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, "delete "));
    }
    // 3 verbs, both AUMID keys, both icon names
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "windows-unofficial\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "windows-unofficial-debug\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\ghostty\\toast-icon.png\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, aw.written(), "\n"), "\\ghostty\\notify-icon.png"));
}

const TestHive = struct {
    tmp: std.testing.TmpDir,
    root: registry.Root,
    open: bool = true,

    fn init(alloc: Allocator, name: []const u8) !TestHive {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
        defer alloc.free(base);
        const path = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, name });
        defer alloc.free(path);
        return .{ .tmp = tmp, .root = try registry.openTestHive(path) };
    }

    /// Closes the hive and deletes its files; the private hive never
    /// reaches the real registry.
    fn deinit(self: *TestHive, name: []const u8) void {
        if (self.open) registry.close(self.root);
        self.open = false;
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            var gone = true;
            for ([_][]const u8{ "", ".LOG1", ".LOG2" }) |suffix| {
                var buf: [64]u8 = undefined;
                const file = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, suffix }) catch unreachable;
                self.tmp.dir.deleteFile(std.testing.io, file) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => gone = false,
                };
            }
            if (gone) break;
            std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        self.tmp.cleanup();
    }

    fn has(self: *TestHive, alloc: Allocator, subkey: []const u8) !bool {
        const v = try registry.getString(alloc, self.root, subkey, null);
        defer if (v) |s| alloc.free(s);
        return v != null;
    }
};

test "explorer cli: a failed install rolls back what it created" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var h = try TestHive.init(alloc, "r.hive");
    defer h.deinit("r.hive");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // Fail the menu text of the second key (write 4: command, then text).
    try std.testing.expectEqual(@as(u8, 1), try install(alloc, &aw.writer, h.root, "C:\\g\\ghostty.exe", .{ .fail_at = 4 }));
    for (explorer.key_names) |key| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, key });
        defer alloc.free(full);
        const command_key = try std.fmt.allocPrint(alloc, "{s}\\command", .{full});
        defer alloc.free(command_key);
        try std.testing.expect(!try h.has(alloc, full));
        try std.testing.expect(!try h.has(alloc, command_key));
    }
}

test "explorer cli: uninstall removes a key with our menu text and no command" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var h = try TestHive.init(alloc, "o.hive");
    defer h.deinit("o.hive");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const orphan = "Software\\Classes\\Directory\\shell\\GhosttyOpenHere";
    const other = "Software\\Classes\\Drive\\shell\\GhosttyOpenHere";
    try registry.setString(h.root, orphan, null, "Open Ghostty here");
    try registry.setString(h.root, other, null, "Something else");

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, h.root, false, null, null));
    try std.testing.expect(!try h.has(alloc, orphan));
    try std.testing.expect(try h.has(alloc, other));
}

test "explorer cli: install refuses a foreign command unless forced" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var h = try TestHive.init(alloc, "f.hive");
    defer h.deinit("f.hive");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const foreign_cmd = "\"C:\\x\\code.exe\" \"%V\"";
    const foreign = "Software\\Classes\\Directory\\Background\\shell\\GhosttyOpenHere\\command";
    try registry.setString(h.root, foreign, null, foreign_cmd);

    try std.testing.expectEqual(@as(u8, 1), try install(alloc, &aw.writer, h.root, "C:\\g\\ghostty.exe", .{}));
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "--force") != null);
    {
        const got = (try registry.getString(alloc, h.root, foreign, null)).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(foreign_cmd, got);
    }
    // nothing else was written either
    try std.testing.expect(!try h.has(alloc, "Software\\Classes\\Directory\\shell\\GhosttyOpenHere\\command"));

    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, h.root, "C:\\g\\ghostty.exe", .{ .force = true }));
    const got = (try registry.getString(alloc, h.root, foreign, null)).?;
    defer alloc.free(got);
    try std.testing.expect(explorer.ownsCommand(got));
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
    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, root, "C:\\g\\ghostty.exe", .{}));
    try registry.setString(root, foreign, null, "\"C:\\x\\code.exe\" \"%V\"");

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, root, false, null, null));
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

fn seedVerbs(root: registry.Root, command: []const u8) !void {
    for (explorer.key_names) |key| {
        var buf: [256]u8 = undefined;
        const full = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ explorer.verbs_root, key });
        try registry.setString(root, full, null, explorer.menu_text);
        var cbuf: [300]u8 = undefined;
        const ck = try std.fmt.bufPrint(&cbuf, "{s}\\command", .{full});
        try registry.setString(root, ck, null, command);
    }
}

fn countVerbs(alloc: Allocator, h: *TestHive) !usize {
    var n: usize = 0;
    for (explorer.key_names) |key| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}\\command", .{ explorer.verbs_root, key });
        defer alloc.free(full);
        if (try h.has(alloc, full)) n += 1;
    }
    return n;
}

fn countLines(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, needle)) n += 1;
    }
    return n;
}

test "explorer cli: --only-this-exe deletes its own verbs and keeps a foreign one" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var h = try TestHive.init(alloc, "t.hive");
    defer h.deinit("t.hive");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(std.testing.io, &exe_buf)];

    // Our own verbs go.
    try std.testing.expectEqual(@as(u8, 0), try install(alloc, &aw.writer, h.root, exe, .{}));
    try std.testing.expectEqual(@as(usize, 3), try countVerbs(alloc, &h));
    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, h.root, false, null, exe));
    try std.testing.expectEqual(@as(usize, 0), try countVerbs(alloc, &h));

    // Another copy's verbs stay.
    aw.clearRetainingCapacity();
    try seedVerbs(h.root, "\"C:\\Other\\ghostty.exe\" \"--working-directory=%V\\.\"");
    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, h.root, false, null, exe));
    try std.testing.expectEqual(@as(usize, 3), try countVerbs(alloc, &h));
    try std.testing.expectEqual(@as(usize, 3), countLines(aw.written(), "kept (other ghostty.exe)"));

    // Without the flag they go.
    aw.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, h.root, false, null, null));
    try std.testing.expectEqual(@as(usize, 0), try countVerbs(alloc, &h));
}

test "explorer cli: only-this-exe matches a prefixed path" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(std.testing.io, &exe_buf)];

    const prefixed = try std.fmt.allocPrint(alloc, "\\\\?\\{s}", .{exe});
    defer alloc.free(prefixed);
    try std.testing.expect(pathsEqual(prefixed, exe));
    try std.testing.expect(pathsEqual(exe, prefixed));
    try std.testing.expect(!pathsEqual(exe, "C:\\Other\\ghostty.exe"));

    // A quoted `\\?\` command is ours; the same name in a sibling dir is not.
    const cmd = try std.fmt.allocPrint(alloc, "\"{s}\" \"%V\"", .{prefixed});
    defer alloc.free(cmd);
    try std.testing.expect(explorer.ownsKeyFor(cmd, null, exe, pathsEqual));
    const sibling = try std.fmt.allocPrint(alloc, "\"\\\\?\\C:\\Other\\{s}\" \"%V\"", .{std.fs.path.basename(exe)});
    defer alloc.free(sibling);
    try std.testing.expect(!explorer.ownsKeyFor(sibling, null, exe, pathsEqual));
}

test "explorer cli: only-this-exe normalises dots, slashes and UNC" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(pathsEqual("C:\\A\\..\\A\\Ghostty.EXE", "C:\\A\\ghostty.exe"));
    try std.testing.expect(pathsEqual("C:/A/ghostty.exe", "C:\\A\\ghostty.exe"));
    try std.testing.expect(pathsEqual("C:\\A\\ghostty.exe.", "C:\\A\\ghostty.exe"));
    try std.testing.expect(!pathsEqual("C:\\A\\..\\B\\ghostty.exe", "C:\\A\\ghostty.exe"));
    try std.testing.expect(pathsEqual("\\\\?\\UNC\\srv\\share\\g.exe", "\\\\srv\\share\\G.exe"));
}

test "explorer cli: only-this-exe never matches a relative command" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(std.testing.io, &exe_buf)];
    const base = std.fs.path.basename(exe);

    // Relative to the cwd, a bare name, a rooted path and a drive-relative one.
    try std.testing.expect(!explorer.ownsKeyFor("\"ghostty.exe\" \"%V\"", null, "C:\\A\\ghostty.exe", pathsEqual));
    try std.testing.expect(!explorer.ownsKeyFor("\"\\A\\ghostty.exe\" \"%V\"", null, "C:\\A\\ghostty.exe", pathsEqual));
    try std.testing.expect(!explorer.ownsKeyFor("\"C:ghostty.exe\" \"%V\"", null, "C:\\A\\ghostty.exe", pathsEqual));
    const rel = try std.fmt.allocPrint(alloc, "\"{s}\" \"%V\"", .{base});
    defer alloc.free(rel);
    try std.testing.expect(!explorer.ownsKeyFor(rel, null, exe, pathsEqual));
    const dots = try std.fmt.allocPrint(alloc, "\"..\\{s}\" \"%V\"", .{base});
    defer alloc.free(dots);
    try std.testing.expect(!explorer.ownsKeyFor(dots, null, exe, pathsEqual));
}

test "explorer cli: only-this-exe expands an 8.3 name" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "A Long Directory Name", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A Long Directory Name/Long Program Name.exe", .data = "x" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, "A Long Directory Name/Long Program Name.exe", alloc);
    defer alloc.free(base);

    var wide: [path_cap:0]u16 = undefined;
    const wn = try std.unicode.utf8ToUtf16Le(&wide, base);
    wide[wn] = 0;
    var short: [path_cap]u16 = undefined;
    const sl = win.GetShortPathNameW(&wide, &short, path_cap);
    try std.testing.expect(sl != 0 and sl < path_cap);
    const short8 = try std.unicode.utf16LeToUtf8Alloc(alloc, short[0..sl]);
    defer alloc.free(short8);
    // The volume has no 8.3 names: nothing to expand.
    if (std.ascii.eqlIgnoreCase(short8, base)) return error.SkipZigTest;

    try std.testing.expect(pathsEqual(short8, base));
    const cmd = try std.fmt.allocPrint(alloc, "\"{s}\" \"%V\"", .{short8});
    defer alloc.free(cmd);
    try std.testing.expect(explorer.ownsKeyFor(cmd, null, base, pathsEqual));
}

test "explorer cli: dry-run uninstall --all --only-this-exe" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try std.testing.expectEqual(@as(u8, 0), try uninstall(alloc, &aw.writer, null, true, "C:\\Users\\x\\AppData\\Local", "C:\\g\\ghostty.exe"));
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    var ifs: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, line, " if its command names C:\\g\\ghostty.exe")) ifs += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), ifs);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "windows-unofficial-debug\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\ghostty\\toast-icon.png\n") != null);
    try std.testing.expectEqual(@as(usize, 7), countLines(aw.written(), "delete "));
}
