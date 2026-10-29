//! TMUX and TMUX_PANE environment for panes (owner: M4 task 8).
//!
//! Pure: it edits an `Environ.Map` and touches nothing else. Map keys are
//! case-insensitive on Windows, so `Path` and `PATH` are one entry.
const std = @import("std");
const protocol = @import("../ipc/protocol.zig");

pub const Options = struct {
    /// The `windows-tmux-shim` key. Off: only the overlays apply and
    /// TMUX / TMUX_PANE / PATH stay as they were (pre-M4 behaviour).
    enabled: bool,
    /// The tmux pipe name (UTF-8); null when the tmux server is not running.
    pipe: ?[]const u8,
    server_pid: u32,
    pane_id: u32,
    /// Directory of `tmux.exe` (next to `ghostty.exe`); null skips PATH.
    exe_dir: ?[]const u8,
    /// "K=V" entries from the tmux client (split-window / respawn-pane).
    client_env: []const []const u8 = &.{},
    /// "K=V" entries from a parsed pane command (`env A=B prog`).
    extra: []const []const u8 = &.{},
};

/// Keys an overlay never sets: ours, or set later by core.
const skipped = [_][]const u8{ "TMUX", "TMUX_PANE", "GHOSTTY_SURFACE_ID", "GHOSTTY_LOG" };

/// Order (SPEC §12.3): 1 client env, 2 TMUX / TMUX_PANE, 3 PATH, 4 extra.
pub fn apply(map: *std.process.Environ.Map, opts: Options) !void {
    try overlay(map, opts.client_env);

    if (opts.enabled) {
        if (opts.pipe) |pipe| {
            var tmux_buf: [512]u8 = undefined;
            try map.put("TMUX", try protocol.tmuxEnvValue(&tmux_buf, pipe, opts.server_pid));
            var pane_buf: [16]u8 = undefined;
            try map.put("TMUX_PANE", try std.fmt.bufPrint(&pane_buf, "%{d}", .{opts.pane_id}));
            // The shim's "outer terminal" is Ghostty, which is truecolor.
            if (map.get("CLAUDE_CODE_TMUX_TRUECOLOR") == null) {
                try map.put("CLAUDE_CODE_TMUX_TRUECOLOR", "1");
            }
        } else {
            _ = map.orderedRemove("TMUX");
            _ = map.orderedRemove("TMUX_PANE");
        }
        if (opts.exe_dir) |dir| try putPathFirst(map, dir);
    }

    try overlay(map, opts.extra);
}

fn overlay(map: *std.process.Environ.Map, entries: []const []const u8) !void {
    for (entries) |e| {
        // "=C:=C:\" style entries have an empty name.
        if (e.len == 0 or e[0] == '=') continue;
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        const key = e[0..eq];
        if (isSkipped(key)) continue;
        try map.put(key, e[eq + 1 ..]);
    }
}

fn isSkipped(key: []const u8) bool {
    for (skipped) |s| if (std.ascii.eqlIgnoreCase(key, s)) return true;
    return false;
}

fn trimmed(dir: []const u8) []const u8 {
    return std.mem.trimEnd(u8, dir, "\\/");
}

/// PATH = dir ";" PATH without the entries equal to `dir`.
fn putPathFirst(map: *std.process.Environ.Map, dir: []const u8) !void {
    const alloc = map.allocator;
    const current = map.get("PATH") orelse "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, dir);
    var it = std.mem.splitScalar(u8, current, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(trimmed(entry), trimmed(dir))) continue;
        try out.append(alloc, ';');
        try out.appendSlice(alloc, entry);
    }
    try map.put("PATH", out.items);
}

// ---- tests -----------------------------------------------------------

const test_pipe = "\\\\.\\pipe\\ghostty-tmux-42-00000000000000ab";

fn testMap(entries: []const [2][]const u8) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    errdefer m.deinit();
    for (entries) |kv| try m.put(kv[0], kv[1]);
    return m;
}

test "win32 tmux env: order and precedence" {
    var m = try testMap(&.{.{ "PATH", "C:\\u" }});
    defer m.deinit();
    try apply(&m, .{
        .enabled = true,
        .pipe = test_pipe,
        .server_pid = 42,
        .pane_id = 7,
        .exe_dir = "C:\\g",
        .client_env = &.{ "TMUX_PANE=%1", "TMUX=x", "PATH=C:\\u", "=C:=C:\\", "GHOSTTY_SURFACE_ID=1" },
    });
    try std.testing.expectEqualStrings("%7", m.get("TMUX_PANE").?);
    try std.testing.expectEqualStrings(test_pipe ++ ",42,0", m.get("TMUX").?);
    try std.testing.expectEqualStrings("C:\\g;C:\\u", m.get("PATH").?);
    try std.testing.expect(m.get("=C:") == null);
    try std.testing.expect(m.get("GHOSTTY_SURFACE_ID") == null);
}

test "win32 tmux env: Path and PATH merge" {
    var m = try testMap(&.{.{ "Path", "C:\\u;C:\\v" }});
    defer m.deinit();
    try apply(&m, .{ .enabled = true, .pipe = test_pipe, .server_pid = 42, .pane_id = 1, .exe_dir = "C:\\g" });
    try std.testing.expectEqual(@as(usize, 4), m.count()); // Path, TMUX, TMUX_PANE, CLAUDE_CODE_TMUX_TRUECOLOR
    try std.testing.expectEqualStrings("C:\\g;C:\\u;C:\\v", m.get("PATH").?);
    try std.testing.expectEqualStrings("C:\\g;C:\\u;C:\\v", m.get("Path").?);
}

test "win32 tmux env: exe dir moved to front, not duplicated" {
    var m = try testMap(&.{.{ "PATH", "C:\\u;c:\\G\\;C:\\v;C:\\g" }});
    defer m.deinit();
    try apply(&m, .{ .enabled = true, .pipe = null, .server_pid = 0, .pane_id = 1, .exe_dir = "C:\\g" });
    try std.testing.expectEqualStrings("C:\\g;C:\\u;C:\\v", m.get("PATH").?);

    var empty = try testMap(&.{});
    defer empty.deinit();
    try apply(&empty, .{ .enabled = true, .pipe = null, .server_pid = 0, .pane_id = 1, .exe_dir = "C:\\g" });
    try std.testing.expectEqualStrings("C:\\g", empty.get("PATH").?);
}

test "win32 tmux env: no pipe removes TMUX" {
    var m = try testMap(&.{ .{ "TMUX", "outer" }, .{ "TMUX_PANE", "%9" }, .{ "PATH", "C:\\u" } });
    defer m.deinit();
    try apply(&m, .{ .enabled = true, .pipe = null, .server_pid = 0, .pane_id = 1, .exe_dir = null });
    try std.testing.expect(m.get("TMUX") == null);
    try std.testing.expect(m.get("TMUX_PANE") == null);
    try std.testing.expectEqualStrings("C:\\u", m.get("PATH").?);
}

test "win32 tmux env: extra overrides client env" {
    var m = try testMap(&.{.{ "PATH", "C:\\u" }});
    defer m.deinit();
    try apply(&m, .{
        .enabled = true,
        .pipe = test_pipe,
        .server_pid = 42,
        .pane_id = 3,
        .exe_dir = "C:\\g",
        .client_env = &.{ "A=1", "B=1" },
        .extra = &.{ "A=2", "PATH=C:\\own", "TMUX=nope", "EMPTY=" },
    });
    try std.testing.expectEqualStrings("2", m.get("A").?);
    try std.testing.expectEqualStrings("1", m.get("B").?);
    try std.testing.expectEqualStrings("C:\\own", m.get("PATH").?);
    try std.testing.expectEqualStrings(test_pipe ++ ",42,0", m.get("TMUX").?);
    try std.testing.expectEqualStrings("", m.get("EMPTY").?);
}

test "win32 tmux env: disabled sets no TMUX and does not prepend" {
    var m = try testMap(&.{.{ "PATH", "C:\\u" }});
    defer m.deinit();
    try apply(&m, .{
        .enabled = false,
        .pipe = test_pipe,
        .server_pid = 42,
        .pane_id = 7,
        .exe_dir = "C:\\g",
        .client_env = &.{ "A=1", "TMUX=x" },
        .extra = &.{"B=2"},
    });
    try std.testing.expect(m.get("TMUX") == null);
    try std.testing.expect(m.get("TMUX_PANE") == null);
    try std.testing.expectEqualStrings("C:\\u", m.get("PATH").?);
    try std.testing.expectEqualStrings("1", m.get("A").?);
    try std.testing.expectEqualStrings("2", m.get("B").?);
}

test "win32 tmux env: disabled keeps an inherited TMUX" {
    var m = try testMap(&.{ .{ "TMUX", "outer" }, .{ "TMUX_PANE", "%5" } });
    defer m.deinit();
    try apply(&m, .{ .enabled = false, .pipe = test_pipe, .server_pid = 42, .pane_id = 7, .exe_dir = "C:\\g" });
    try std.testing.expectEqualStrings("outer", m.get("TMUX").?);
    try std.testing.expectEqualStrings("%5", m.get("TMUX_PANE").?);
}

test "win32 tmux env: map keys are case-insensitive" {
    var m = try testMap(&.{.{ "Path", "x" }});
    defer m.deinit();
    try std.testing.expectEqualStrings("x", m.get("PATH").?);
    try std.testing.expectEqualStrings("x", m.get("path").?);
}

test "win32 config: windows-tmux-shim defaults to false" {
    const Config = @import("../../../config.zig").Config;
    const field = std.meta.fieldInfo(Config, .@"windows-tmux-shim");
    try std.testing.expect(field.type == bool);
    try std.testing.expect(!field.attrs.defaultValue(bool).?);
}

test "win32 tmux env: truecolor hint with the shim" {
    var m = try testMap(&.{});
    defer m.deinit();
    try apply(&m, .{ .enabled = true, .pipe = test_pipe, .server_pid = 42, .pane_id = 1, .exe_dir = null });
    try std.testing.expectEqualStrings("1", m.get("CLAUDE_CODE_TMUX_TRUECOLOR").?);

    var kept = try testMap(&.{.{ "CLAUDE_CODE_TMUX_TRUECOLOR", "0" }});
    defer kept.deinit();
    try apply(&kept, .{ .enabled = true, .pipe = test_pipe, .server_pid = 42, .pane_id = 1, .exe_dir = null });
    try std.testing.expectEqualStrings("0", kept.get("CLAUDE_CODE_TMUX_TRUECOLOR").?);

    var off = try testMap(&.{});
    defer off.deinit();
    try apply(&off, .{ .enabled = false, .pipe = test_pipe, .server_pid = 42, .pane_id = 1, .exe_dir = null });
    try std.testing.expect(off.get("CLAUDE_CODE_TMUX_TRUECOLOR") == null);

    var nopipe = try testMap(&.{});
    defer nopipe.deinit();
    try apply(&nopipe, .{ .enabled = true, .pipe = null, .server_pid = 0, .pane_id = 1, .exe_dir = null });
    try std.testing.expect(nopipe.get("CLAUDE_CODE_TMUX_TRUECOLOR") == null);
}
