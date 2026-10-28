//! Update check persistence and schedule. Pure: the caller reads and writes
//! the file and supplies the clock.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../../config.zig");
const release = @import("release.zig");

pub const State = struct {
    /// Unix seconds of the last completed check.
    last_check: i64 = 0,
    /// Highest N already announced to the user.
    notified: u32 = 0,
};

pub const Mode = enum { off, check };

const interval_s: i64 = 24 * 60 * 60;

/// Garbage or a wrong shape gives the default state.
pub fn load(arena: Allocator, json: []const u8) State {
    return std.json.parseFromSliceLeaky(State, arena, json, .{
        .ignore_unknown_fields = true,
    }) catch .{};
}

pub fn save(w: *std.Io.Writer, s: State) !void {
    try w.print("{{\"last_check\":{d},\"notified\":{d}}}\n", .{ s.last_check, s.notified });
}

/// Unset means `check`; `download` is treated as `check` on Windows.
/// Debug builds, test mode and local builds (no release number) never check.
pub fn modeFor(
    cfg: ?configpkg.Config.AutoUpdate,
    debug: bool,
    test_mode: bool,
    current_n: ?u32,
) Mode {
    if (debug or test_mode or current_n == null) return .off;
    return switch (cfg orelse .check) {
        .off => .off,
        .check, .download => .check,
    };
}

pub fn due(s: State, now_s: i64) bool {
    // A garbage or future last_check must neither panic nor block forever.
    if (s.last_check > now_s) return true;
    return now_s -| s.last_check >= interval_s;
}

pub fn shouldAnnounce(s: State, r: release.Release, current_n: u32) bool {
    return r.n > current_n and r.n > s.notified;
}

test "win32 update: modeFor" {
    const t = std.testing;
    try t.expectEqual(Mode.check, modeFor(null, false, false, 3));
    try t.expectEqual(Mode.check, modeFor(.download, false, false, 3));
    try t.expectEqual(Mode.check, modeFor(.check, false, false, 3));
    try t.expectEqual(Mode.off, modeFor(.off, false, false, 3));
    try t.expectEqual(Mode.off, modeFor(null, true, false, 3));
    try t.expectEqual(Mode.off, modeFor(null, false, true, 3));
    try t.expectEqual(Mode.off, modeFor(null, false, false, null));
}

test "win32 update: due after 24 hours" {
    const s: State = .{ .last_check = 1000 };
    try std.testing.expect(!due(s, 1000 + 24 * 3600 - 60));
    try std.testing.expect(due(s, 1000 + 24 * 3600));
    try std.testing.expect(due(.{}, 1_700_000_000));
}

test "win32 update: shouldAnnounce once per N" {
    var s: State = .{};
    const r: release.Release = .{ .n = 4, .version = "", .tag = "", .html_url = "" };
    try std.testing.expect(shouldAnnounce(s, r, 3));
    try std.testing.expect(!shouldAnnounce(s, r, 4));
    s.notified = r.n;
    try std.testing.expect(!shouldAnnounce(s, r, 3));
}

test "win32 update: state round trip and garbage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try save(&w, .{ .last_check = 1234, .notified = 5 });
    const s = load(arena.allocator(), w.buffered());
    try std.testing.expectEqual(@as(i64, 1234), s.last_check);
    try std.testing.expectEqual(@as(u32, 5), s.notified);

    const d = load(arena.allocator(), "\x00not json{{");
    try std.testing.expectEqual(@as(i64, 0), d.last_check);
    try std.testing.expectEqual(@as(u32, 0), d.notified);
    try std.testing.expectEqual(@as(i64, 0), load(arena.allocator(), "[1,2]").last_check);
}

test "win32 update: due tolerates garbage and clock going back" {
    try std.testing.expect(due(.{ .last_check = 5000 }, 1000));
    try std.testing.expect(due(.{ .last_check = std.math.minInt(i64) }, 1_700_000_000));
    try std.testing.expect(due(.{ .last_check = std.math.minInt(i64) }, std.math.maxInt(i64)));
    try std.testing.expect(!due(.{ .last_check = std.math.maxInt(i64) }, std.math.maxInt(i64)));
}
