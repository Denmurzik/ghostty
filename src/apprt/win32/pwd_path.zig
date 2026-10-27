//! Windows paths from the working directory a shell reports with OSC 7.
//!
//! The text comes from terminal output, so it is untrusted: it later reaches
//! Explorer (the proxy icon), `shell_open` and `CreateProcess` (new tabs).
//! Core has already checked the host of the URL (empty/local only) and
//! percent-decoded the path (`kitty-shell-cwd://` paths are raw), so this
//! takes the path alone and never decodes again.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest path accepted (well under the 32767 UTF-16 unit limit).
const max_len = 4096;

/// The Windows path of an OSC 7 `path` as the shells of this port write it:
///
///   * `/c/Users/x`, `/cygdrive/c/x`, `/mnt/c/x` (MSYS, Cygwin, WSL)
///   * `/C:/Users/x`, `C:/Users/x`, `/C:\Users\x` (file URLs, cmd's `$P`)
///   * `///server/share/x` (UNC through cmd's `$P`)
///
/// Null when the path is none of those (`/tmp`, a relative path, a WSL path
/// outside the drives) or is not safe: control characters, characters
/// Windows paths cannot hold, alternate data streams, device names, `\\?\`
/// prefixes, trailing dots or blanks, `..` above the root. `.` and `..`
/// segments are resolved here. The result is caller owned.
pub fn translate(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (path.len == 0 or path.len > max_len) return null;
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    for (path) |c| switch (c) {
        0...0x1f, 0x7f, '"', '<', '>', '|', '*', '?' => return null,
        else => {},
    };

    // Backslashes are separators on Windows, so no segment can hold one.
    const norm = try alloc.dupe(u8, path);
    defer alloc.free(norm);
    std.mem.replaceScalar(u8, norm, '\\', '/');

    var rest: []const u8 = norm;
    var prefix: [2]u8 = undefined;
    var unc = false;

    if (std.mem.startsWith(u8, rest, "//")) {
        // `//server/share` or, from cmd, `///server/share`.
        unc = true;
        rest = std.mem.trimStart(u8, rest, "/");
        const server_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const server = rest[0..server_end];
        if (server.len == 0 or std.mem.eql(u8, server, ".") or std.mem.eql(u8, server, "..")) return null;
        if (std.mem.indexOfScalar(u8, server, ':') != null) return null;
    } else {
        const drive = drivePrefix(rest) orelse return null;
        prefix = .{ std.ascii.toUpper(drive.letter), ':' };
        rest = rest[drive.len..];
    }

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // A UNC path keeps its server and share.
            if (segments.items.len <= @as(usize, if (unc) 2 else 0)) return null;
            _ = segments.pop();
            continue;
        }
        if (!safeSegment(seg)) return null;
        try segments.append(alloc, seg);
    }
    if (unc and segments.items.len < 2) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (unc) {
        try out.appendSlice(alloc, "\\\\");
    } else {
        try out.appendSlice(alloc, &prefix);
        if (segments.items.len == 0) try out.append(alloc, '\\');
    }
    for (segments.items, 0..) |seg, i| {
        if (i > 0 or !unc) try out.append(alloc, '\\');
        try out.appendSlice(alloc, seg);
    }
    return try out.toOwnedSlice(alloc);
}

const Drive = struct { letter: u8, len: usize };

/// The drive at the start of `path` and how many bytes it takes.
fn drivePrefix(path: []const u8) ?Drive {
    var p = path;
    var used: usize = 0;
    inline for (.{ "/cygdrive", "/mnt" }) |root| {
        if (std.mem.startsWith(u8, p, root ++ "/")) {
            used = root.len;
            p = p[used..];
            break;
        }
    }
    // `C:/x` and `/C:/x`.
    const colon = if (p.len > 0 and p[0] == '/') p[1..] else p;
    const lead = p.len - colon.len;
    if (used == 0 and colon.len >= 2 and std.ascii.isAlphabetic(colon[0]) and colon[1] == ':' and
        (colon.len == 2 or colon[2] == '/'))
    {
        return .{ .letter = colon[0], .len = lead + 2 };
    }
    // `/c` and `/c/x` (MSYS, Cygwin, WSL).
    if (p.len >= 2 and p[0] == '/' and std.ascii.isAlphabetic(p[1]) and (p.len == 2 or p[2] == '/')) {
        return .{ .letter = p[1], .len = used + 2 };
    }
    return null;
}

/// One path component Windows would take literally.
fn safeSegment(seg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, seg, ':') != null) return false;
    // Windows drops trailing dots and blanks: `a.` names `a`.
    const last = seg[seg.len - 1];
    if (last == '.' or last == ' ') return false;
    // Device names, with or without an extension.
    const dot = std.mem.indexOfScalar(u8, seg, '.') orelse seg.len;
    const stem = std.mem.trimEnd(u8, seg[0..dot], " ");
    if (stem.len != 3 and stem.len != 4) return true;
    var buf: [4]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, stem);
    if (stem.len == 3) {
        for ([_][]const u8{ "con", "prn", "aux", "nul" }) |n| {
            if (std.mem.eql(u8, lower, n)) return false;
        }
        return true;
    }
    return !((std.mem.startsWith(u8, lower, "com") or std.mem.startsWith(u8, lower, "lpt")) and
        lower[3] >= '1' and lower[3] <= '9');
}

fn expectTranslate(path: []const u8, want: ?[]const u8) !void {
    const got = try translate(std.testing.allocator, path);
    defer if (got) |g| std.testing.allocator.free(g);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(w, got.?);
    } else {
        try std.testing.expect(got == null);
    }
}

test "win32 pwd_path: drive forms" {
    try expectTranslate("/c/Users/x", "C:\\Users\\x");
    try expectTranslate("/c", "C:\\");
    try expectTranslate("/c/", "C:\\");
    try expectTranslate("/D/work dir/Проект", "D:\\work dir\\Проект");
    try expectTranslate("/cygdrive/c/Users/x", "C:\\Users\\x");
    try expectTranslate("/mnt/d/src", "D:\\src");
    try expectTranslate("/C:/Users/x", "C:\\Users\\x");
    try expectTranslate("/C:", "C:\\");
    try expectTranslate("C:/Users/x", "C:\\Users\\x");
    try expectTranslate("/C:\\Users\\my dir", "C:\\Users\\my dir");
    try expectTranslate("/C:\\Users\\a#b%20c", "C:\\Users\\a#b%20c");
}

test "win32 pwd_path: unc" {
    try expectTranslate("///server/share/dir", "\\\\server\\share\\dir");
    try expectTranslate("/\\\\server\\share", "\\\\server\\share");
    try expectTranslate("//server/share/a/../b", "\\\\server\\share\\b");
    try expectTranslate("///server", null);
    try expectTranslate("///server/", null);
    try expectTranslate("///server/share/..", null);
    try expectTranslate("//?/C:/x", null);
    try expectTranslate("//./pipe/x", null);
}

test "win32 pwd_path: dot segments are resolved" {
    try expectTranslate("/c/a/./b/../c", "C:\\a\\c");
    try expectTranslate("/c/a//b", "C:\\a\\b");
    try expectTranslate("/c/a/..", "C:\\");
    try expectTranslate("/c/..", null);
    try expectTranslate("/c/a/../../b", null);
    try expectTranslate("/C:/../x", null);
}

test "win32 pwd_path: not a drive path" {
    try expectTranslate("", null);
    try expectTranslate("/", null);
    try expectTranslate("/tmp", null);
    try expectTranslate("/usr/bin", null);
    try expectTranslate("/home/x", null);
    try expectTranslate("/mnt/wsl/x", null);
    try expectTranslate("/mnt/cc/x", null);
    try expectTranslate("relative/dir", null);
    try expectTranslate("1:/x", null);
}

test "win32 pwd_path: unsafe input is refused" {
    try expectTranslate("/c/a\x00b", null);
    try expectTranslate("/c/a\nb", null);
    try expectTranslate("/c/a\x1b[31m", null);
    try expectTranslate("/c/a\x7fb", null);
    try expectTranslate("/c/a|b", null);
    try expectTranslate("/c/a*b", null);
    try expectTranslate("/c/a?b", null);
    try expectTranslate("/c/a\"b", null);
    try expectTranslate("/c/file:stream", null);
    try expectTranslate("/c/dir/x::$DATA", null);
    try expectTranslate("/c/a.", null);
    try expectTranslate("/c/a ", null);
    try expectTranslate("/c/CON", null);
    try expectTranslate("/c/dir/nul.txt", null);
    try expectTranslate("/c/COM1", null);
    try expectTranslate("/c/lpt9.x", null);
    try expectTranslate("/c/console", "C:\\console");
    try expectTranslate("/c/com10", "C:\\com10");
    try expectTranslate("/c/\xff\xfe", null);
    try expectTranslate("\\\\?\\C:\\x", null);
    try expectTranslate("/??/C:/x", null);
}

test "win32 pwd_path: too long is refused" {
    var long: [max_len + 3]u8 = undefined;
    @memcpy(long[0..3], "/c/");
    @memset(long[3..], 'a');
    try expectTranslate(&long, null);
}
