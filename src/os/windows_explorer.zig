//! The Explorer "Open Ghostty here" entries (R-M5-5) as pure data: which keys
//! and values `+install-explorer-integration` writes, and what
//! `+uninstall-explorer-integration` recognises as its own. No registry access
//! here (see `windows_registry.zig`), so it builds and tests on any target.
//! The AUMID and the toast icon name live here too, so that the CLI revert
//! (`--all`) and the toasts agree on them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The AppUserModelID the toasts, the taskbar grouping and the jump list use.
/// The debug build has its own so that a development run never rewrites the
/// registration of an installed build.
pub const aumid = if (builtin.mode == .debug)
    "com.mitchellh.ghostty.windows-unofficial-debug"
else
    "com.mitchellh.ghostty.windows-unofficial";

/// The toast icon, under `%LOCALAPPDATA%\ghostty`.
pub const toast_icon_name = "toast-icon.png";

/// The AUMID registration key, relative to `HKCU`.
pub const aumid_subkey = "Software\\Classes\\AppUserModelId\\" ++ aumid;

/// The registrations of both build modes: `--all` removes whichever exist.
pub const aumid_subkeys = [_][]const u8{
    "Software\\Classes\\AppUserModelId\\com.mitchellh.ghostty.windows-unofficial",
    "Software\\Classes\\AppUserModelId\\com.mitchellh.ghostty.windows-unofficial-debug",
};

/// The icon file earlier builds wrote (`notify.zig`), also removed by `--all`.
pub const legacy_toast_icon_name = "notify-icon.png";

/// Whether an existing verb key is ours: its command is ours, or it has no
/// command but our menu text (what a failed install would leave behind).
pub fn ownsKey(command: ?[]const u8, menu: ?[]const u8) bool {
    if (command) |c| return ownsCommand(c);
    const m = menu orelse return false;
    return std.mem.eql(u8, m, menu_text);
}

/// One registry string value. `name` null is the `(default)` value.
pub const Write = struct {
    subkey: []const u8,
    name: ?[]const u8,
    value: []const u8,
};

/// Where the verbs live, relative to `HKCU`.
pub const verbs_root = "Software\\Classes";

/// The three verb keys, relative to `verbs_root`: a folder, the background of
/// an open folder, and a drive.
pub const key_names = [_][]const u8{
    "Directory\\shell\\GhosttyOpenHere",
    "Directory\\Background\\shell\\GhosttyOpenHere",
    "Drive\\shell\\GhosttyOpenHere",
};

pub const menu_text = "Open Ghostty here";

/// `"<exe>" "--working-directory=%V\."`. The `\.` suffix keeps a drive root's
/// backslash from escaping the closing quote (`C:\` becomes `C:\\.`).
/// Caller owns the result.
pub fn commandLine(alloc: Allocator, exe_path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "\"{s}\" \"--working-directory=%V\\.\"", .{exe_path});
}

/// The nine writes of an install (three keys: default, `Icon`, `command`),
/// subkeys relative to `verbs_root`. Free with `freeWrites`.
pub fn installWrites(alloc: Allocator, exe_path: []const u8) Allocator.Error![]Write {
    const command = try commandLine(alloc, exe_path);
    defer alloc.free(command);
    const icon = try std.fmt.allocPrint(alloc, "{s},0", .{exe_path});
    defer alloc.free(icon);

    var list: std.ArrayList(Write) = try .initCapacity(alloc, key_names.len * 3);
    errdefer {
        freeFields(alloc, list.items);
        list.deinit(alloc);
    }

    for (key_names) |key| {
        var buf: [128]u8 = undefined;
        const command_key = std.fmt.bufPrint(&buf, "{s}\\command", .{key}) catch unreachable;
        // The command goes first: a menu entry that is visible always has one.
        try add(alloc, &list, command_key, null, command);
        try add(alloc, &list, key, null, menu_text);
        try add(alloc, &list, key, "Icon", icon);
    }
    return list.toOwnedSlice(alloc);
}

fn add(
    alloc: Allocator,
    list: *std.ArrayList(Write),
    subkey: []const u8,
    name: ?[]const u8,
    value: []const u8,
) Allocator.Error!void {
    const k = try alloc.dupe(u8, subkey);
    errdefer alloc.free(k);
    const n = if (name) |s| try alloc.dupe(u8, s) else null;
    errdefer if (n) |s| alloc.free(s);
    const v = try alloc.dupe(u8, value);
    errdefer alloc.free(v);
    try list.append(alloc, .{ .subkey = k, .name = n, .value = v });
}

fn freeFields(alloc: Allocator, writes: []const Write) void {
    for (writes) |w| {
        alloc.free(w.subkey);
        if (w.name) |n| alloc.free(n);
        alloc.free(w.value);
    }
}

pub fn freeWrites(alloc: Allocator, writes: []const Write) void {
    freeFields(alloc, writes);
    alloc.free(writes);
}

/// Whether a `command\(default)` value is one of ours: it starts with `"` and
/// the quoted program is a file called `ghostty.exe`. A foreign verb with the
/// same key name is left alone.
pub fn ownsCommand(command: []const u8) bool {
    if (command.len == 0 or command[0] != '"') return false;
    const end = std.mem.indexOfScalarPos(u8, command, 1, '"') orelse return false;
    const program = command[1..end];
    const sep = std.mem.lastIndexOfAny(u8, program, "\\/");
    const base = if (sep) |i| program[i + 1 ..] else program;
    return std.ascii.eqlIgnoreCase(base, "ghostty.exe");
}

test "windows explorer: install writes" {
    const alloc = std.testing.allocator;
    const writes = try installWrites(alloc, "C:\\Program Files\\Ghostty\\ghostty.exe");
    defer freeWrites(alloc, writes);

    const icon = "C:\\Program Files\\Ghostty\\ghostty.exe,0";
    const cmd = "\"C:\\Program Files\\Ghostty\\ghostty.exe\" \"--working-directory=%V\\.\"";
    try std.testing.expectEqual(@as(usize, 9), writes.len);
    for (key_names, 0..) |key, i| {
        const w = writes[i * 3 ..][0..3];
        // command first, then the menu text, then the icon
        const cmd_key = try std.fmt.allocPrint(alloc, "{s}\\command", .{key});
        defer alloc.free(cmd_key);
        try std.testing.expectEqualStrings(cmd_key, w[0].subkey);
        try std.testing.expectEqual(@as(?[]const u8, null), w[0].name);
        try std.testing.expectEqualStrings(cmd, w[0].value);

        try std.testing.expectEqualStrings(key, w[1].subkey);
        try std.testing.expectEqual(@as(?[]const u8, null), w[1].name);
        try std.testing.expectEqualStrings("Open Ghostty here", w[1].value);

        try std.testing.expectEqualStrings(key, w[2].subkey);
        try std.testing.expectEqualStrings("Icon", w[2].name.?);
        try std.testing.expectEqualStrings(icon, w[2].value);
    }
}

test "windows explorer: command line round-trips every %V shape" {
    const alloc = std.testing.allocator;
    const cmdline = @import("windows_cmdline.zig");

    var long_buf: [299]u8 = undefined;
    @memcpy(long_buf[0..3], "C:\\");
    @memset(long_buf[3..], 'd');
    const long: []const u8 = &long_buf;
    const shapes = [_][]const u8{
        "C:\\",
        "C:\\a b",
        "D:\\x#%'y",
        "C:\\Users\\Анна",
        long,
        "\\\\srv\\share\\x",
    };
    const template = try commandLine(alloc, "C:\\Program Files\\Ghostty\\ghostty.exe");
    defer alloc.free(template);

    for (shapes) |shape| {
        const line = try std.mem.replaceOwned(u8, alloc, template, "%V", shape);
        defer alloc.free(line);

        const argv = try cmdline.tokenizeWindows(alloc, line);
        defer {
            for (argv) |a| alloc.free(a);
            alloc.free(argv);
        }
        try std.testing.expectEqual(@as(usize, 2), argv.len);
        try std.testing.expectEqualStrings("C:\\Program Files\\Ghostty\\ghostty.exe", argv[0]);
        const want = try std.fmt.allocPrint(alloc, "--working-directory={s}\\.", .{shape});
        defer alloc.free(want);
        try std.testing.expectEqualStrings(want, argv[1]);
    }
}

test "windows explorer: ownsCommand" {
    try std.testing.expect(ownsCommand("\"C:\\Program Files\\Ghostty\\ghostty.exe\" \"--working-directory=%V\\.\""));
    try std.testing.expect(ownsCommand("\"D:\\x\\GHOSTTY.EXE\" \"%V\""));
    try std.testing.expect(!ownsCommand("\"C:\\x\\code.exe\" \"%V\""));
    try std.testing.expect(!ownsCommand("C:\\x\\ghostty.exe \"%V\""));
    try std.testing.expect(!ownsCommand("\"C:\\x\\ghostty.exe.bak\" \"%V\""));
    try std.testing.expect(!ownsCommand("\"C:\\x\\ghostty.exe"));
    try std.testing.expect(!ownsCommand(""));
}

test "windows explorer: ownsKey" {
    try std.testing.expect(ownsKey("\"C:\\g\\ghostty.exe\" \"%V\"", null));
    try std.testing.expect(!ownsKey("\"C:\\x\\code.exe\" \"%V\"", menu_text));
    try std.testing.expect(ownsKey(null, menu_text));
    try std.testing.expect(!ownsKey(null, "Something else"));
    try std.testing.expect(!ownsKey(null, null));
}

test "windows explorer: aumid matches the R-M3-5 value" {
    const want = if (builtin.mode == .debug)
        "com.mitchellh.ghostty.windows-unofficial-debug"
    else
        "com.mitchellh.ghostty.windows-unofficial";
    try std.testing.expectEqualStrings(want, aumid);
    try std.testing.expectEqualStrings("toast-icon.png", toast_icon_name);
}
