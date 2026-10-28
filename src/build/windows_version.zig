//! Version rules of the Windows fork: `win-` git tags and the single
//! `-win.<N>` suffix. Std only, so `build.zig` and the main test exe share it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win_infix = "-win.";

pub const TagKind = enum { tip, fork, upstream };

/// `tip` -> tip; a `win-` prefix -> fork; anything else is an upstream tag.
pub fn tagKind(tag: []const u8) TagKind {
    if (std.mem.eql(u8, tag, "tip")) return .tip;
    if (std.mem.startsWith(u8, tag, "win-")) return .fork;
    return .upstream;
}

/// Digits only, no sign, no leading zero (except "0" itself).
pub fn canonicalDigits(s: []const u8) bool {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// `<zon>-win.<N>` -> N, with `-win.<N>` at the very end and N canonical.
/// Null means a local build without a release number.
pub fn winN(version: []const u8) ?u32 {
    const i = std.mem.lastIndexOf(u8, version, win_infix) orelse return null;
    const digits = version[i + win_infix.len ..];
    if (!canonicalDigits(digits)) return null;
    return std.fmt.parseUnsigned(u32, digits, 10) catch null;
}

pub const Error = error{ BadWinSuffix, NTooLarge, WinWithBuildMetadata };

/// The raw `-Dversion-string` rule: text containing `-win.` must end in
/// `-win.<N>` (canonical N <= 65535) and carry no `+build` metadata.
pub fn checkVersionString(raw: []const u8) Error!void {
    const i = std.mem.lastIndexOf(u8, raw, win_infix) orelse return;
    if (std.mem.indexOfScalar(u8, raw, '+') != null) return error.WinWithBuildMetadata;
    const digits = raw[i + win_infix.len ..];
    if (!canonicalDigits(digits)) return error.BadWinSuffix;
    const n = std.fmt.parseUnsigned(u32, digits, 10) catch return error.NTooLarge;
    if (n > std.math.maxInt(u16)) return error.NTooLarge;
}

/// N of a parsed pre-release part (`dev-win.7`, `win.7`). Call after
/// `checkVersionString`; a missing or odd suffix is 0.
fn preN(pre: []const u8) u16 {
    const digits = if (std.mem.startsWith(u8, pre, "win."))
        pre["win.".len..]
    else if (std.mem.lastIndexOf(u8, pre, win_infix)) |i|
        pre[i + win_infix.len ..]
    else
        return 0;
    if (!canonicalDigits(digits)) return 0;
    return std.fmt.parseUnsigned(u16, digits, 10) catch 0;
}

/// `{major, minor, patch, N or 0}`.
pub fn fileVersion(v: std.SemanticVersion) [4]u16 {
    return .{
        @intCast(v.major),
        @intCast(v.minor),
        @intCast(v.patch),
        if (v.pre) |pre| preN(pre) else 0,
    };
}

pub const Exe = enum { ghostty, tmux };

/// The generated `#define`s that `dist/windows/versioninfo.rc` includes.
pub fn rcHeader(
    alloc: Allocator,
    v: std.SemanticVersion,
    debug: bool,
    exe: Exe,
) Allocator.Error![]u8 {
    const fv = fileVersion(v);
    const ver = try std.fmt.allocPrint(alloc, "{f}", .{v});
    defer alloc.free(ver);
    for (ver) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '+', '-' => {},
        else => unreachable,
    };

    const flags: u8 = (if (v.pre != null) @as(u8, 0x2) else 0) | (if (debug) @as(u8, 0x1) else 0);
    const description, const original = switch (exe) {
        .ghostty => .{ "Ghostty", "ghostty.exe" },
        .tmux => .{ "Ghostty tmux shim", "tmux.exe" },
    };
    return std.fmt.allocPrint(alloc,
        \\#define GHOSTTY_FILEVERSION {d},{d},{d},{d}
        \\#define GHOSTTY_VERSION_STR "{s}"
        \\#define GHOSTTY_FILEFLAGS 0x{X}L
        \\#define GHOSTTY_FILE_DESCRIPTION "{s}"
        \\#define GHOSTTY_ORIGINAL_FILENAME "{s}"
        \\
    , .{ fv[0], fv[1], fv[2], fv[3], ver, flags, description, original });
}

test "windows version: tag kinds" {
    try std.testing.expectEqual(TagKind.tip, tagKind("tip"));
    try std.testing.expectEqual(TagKind.fork, tagKind("win-1.3.2-dev-3"));
    try std.testing.expectEqual(TagKind.fork, tagKind("win-x"));
    try std.testing.expectEqual(TagKind.upstream, tagKind("v1.3.2"));
    try std.testing.expectEqual(TagKind.upstream, tagKind("foo"));
}

test "windows version: winN" {
    try std.testing.expectEqual(@as(?u32, 3), winN("1.3.2-dev-win.3"));
    try std.testing.expectEqual(@as(?u32, 0), winN("1.3.2-win.0"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win.07"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win.+5"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win.1_0"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win.x"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win."));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-dev"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-dev-win.3+abc"));
}

test "windows version: version-string rule" {
    try checkVersionString("1.3.2-dev-win.7");
    try checkVersionString("1.3.2-dev");
    try std.testing.expectError(error.BadWinSuffix, checkVersionString("1.3.2-dev-win.07"));
    try std.testing.expectError(error.BadWinSuffix, checkVersionString("1.3.2-win."));
    try std.testing.expectError(error.NTooLarge, checkVersionString("1.3.2-win.65536"));
    try std.testing.expectError(error.WinWithBuildMetadata, checkVersionString("1.3.2-dev-win.3+abc"));
}

test "windows version: fileVersion" {
    try std.testing.expectEqual([4]u16{ 1, 3, 2, 7 }, fileVersion(.{ .major = 1, .minor = 3, .patch = 2, .pre = "dev-win.7" }));
    try std.testing.expectEqual([4]u16{ 1, 3, 2, 7 }, fileVersion(.{ .major = 1, .minor = 3, .patch = 2, .pre = "win.7" }));
    try std.testing.expectEqual([4]u16{ 1, 3, 2, 0 }, fileVersion(.{ .major = 1, .minor = 3, .patch = 2, .pre = "dev" }));
}

test "windows version: rc header" {
    const alloc = std.testing.allocator;
    const a = try rcHeader(alloc, .{ .major = 1, .minor = 3, .patch = 2, .pre = "dev-win.7" }, false, .ghostty);
    defer alloc.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "#define GHOSTTY_FILEVERSION 1,3,2,7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "#define GHOSTTY_VERSION_STR \"1.3.2-dev-win.7\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "#define GHOSTTY_FILEFLAGS 0x2L\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "#define GHOSTTY_FILE_DESCRIPTION \"Ghostty\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "#define GHOSTTY_ORIGINAL_FILENAME \"ghostty.exe\"\n") != null);

    const b = try rcHeader(alloc, .{ .major = 1, .minor = 3, .patch = 2 }, true, .tmux);
    defer alloc.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "#define GHOSTTY_FILEFLAGS 0x1L\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"Ghostty tmux shim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"tmux.exe\"") != null);
}

test "windows version: edge cases" {
    try checkVersionString("1.3.2-win.0");
    try checkVersionString("1.3.2-win.65535");
    try std.testing.expectError(error.NTooLarge, checkVersionString("1.3.2-win.4294967296"));
    try std.testing.expectError(error.NTooLarge, checkVersionString("1.3.2-win.99999999999999999999"));
    try std.testing.expectError(error.BadWinSuffix, checkVersionString("1.3.2-win.5-rc"));
    try std.testing.expectError(error.BadWinSuffix, checkVersionString("1.3.2-win.1-win.x"));
    try checkVersionString("1.3.2-win.1-win.2");
    try std.testing.expectEqual(@as(?u32, 2), winN("1.3.2-win.1-win.2"));
    try std.testing.expectEqual(@as(?u32, null), winN("1.3.2-win.5-rc"));
}
