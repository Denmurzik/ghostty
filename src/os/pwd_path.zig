//! Windows paths from the working directory a shell reports with OSC 7.
//!
//! The text comes from terminal output, so it is untrusted: it later reaches
//! `CreateProcess` (new tabs), Explorer (the proxy icon), link resolution and
//! the title. Core calls this on Windows only, after it checked the host of
//! the URL (empty/local) and percent-decoded the path (`kitty-shell-cwd://`
//! paths are raw), so this takes the path alone and never decodes again.
//!
//! Only local drive paths come out. UNC and WebDAV paths (`//host/share`,
//! also written `\\host\share`) are refused: using one as a working directory
//! makes Windows open a connection to the host and send the user's
//! credentials to it.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest result, in UTF-16 units: what `CreateProcess` takes as the
/// current directory (MAX_PATH minus the 2 units it keeps for 8.3 names).
const max_units = 258;

/// Longest input worth looking at.
const max_input = 4096;

/// The Windows path of an OSC 7 `path` as the shells of this port write it:
///
///   * `/c/Users/x`, `/cygdrive/c/x`, `/mnt/c/x` (MSYS, Cygwin, WSL)
///   * `/C:/Users/x`, `C:/Users/x`, `/C:\Users\x` (file URLs, cmd's `$P`)
///
/// Null when the path is none of those (`/tmp`, a relative path, a WSL path
/// outside the drives, anything starting with two separators) or is not
/// safe: control and bidi characters, characters Windows paths cannot hold,
/// alternate data streams, device names, `\\?\` prefixes, trailing dots or
/// blanks, `..` above the root, more than `max_units`. `.` and `..` segments
/// are resolved here. The result is caller owned.
pub fn translate(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (path.len == 0 or path.len > max_input) return null;
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    for (path) |c| switch (c) {
        0...0x1f, 0x7f, '"', '<', '>', '|', '*', '?' => return null,
        else => {},
    };
    if (hasInvisible(path)) return null;

    // Backslashes are separators on Windows, so no segment can hold one.
    const norm = try alloc.dupe(u8, path);
    defer alloc.free(norm);
    std.mem.replaceScalar(u8, norm, '\\', '/');

    // `//host/share`, `///host/share`: a network path.
    if (std.mem.startsWith(u8, norm, "//")) return null;

    const drive = drivePrefix(norm) orelse return null;
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, norm[drive.len..], '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len == 0) return null;
            _ = segments.pop();
            continue;
        }
        if (!safeSegment(seg)) return null;
        try segments.append(alloc, seg);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ std.ascii.toUpper(drive.letter), ':' });
    if (segments.items.len == 0) try out.append(alloc, '\\');
    for (segments.items) |seg| {
        try out.append(alloc, '\\');
        try out.appendSlice(alloc, seg);
    }
    const units = std.unicode.calcUtf16LeLen(out.items) catch return null;
    if (units > max_units) {
        out.deinit(alloc);
        return null;
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

/// C1 controls, bidi/line-separator and zero-width or invisible format
/// characters that let a path look like another one: U+0080..U+009F,
/// U+00AD, U+061C, U+200B..U+200F, U+2028..U+202E, U+2060..U+2064,
/// U+2066..U+2069, U+FEFF.
fn hasInvisible(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| switch (cp) {
        0x80...0x9f, 0xad, 0x61c, 0x200b...0x200f, 0x2028...0x202e, 0x2060...0x2064, 0x2066...0x2069, 0xfeff => return true,
        else => {},
    };
    return false;
}

/// One path component Windows would take literally.
fn safeSegment(seg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, seg, ':') != null) return false;
    // Windows drops trailing dots and blanks: `a.` names `a`.
    const last = seg[seg.len - 1];
    if (last == '.' or last == ' ') return false;
    return !isDeviceName(seg);
}

/// CON, PRN, AUX, NUL, CONIN$, CONOUT$, CLOCK$, COM1-9, LPT1-9 and the
/// superscript forms COM¹-³, LPT¹-³, with or without an extension.
pub fn isDeviceName(seg: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, seg, '.') orelse seg.len;
    const stem = std.mem.trimEnd(u8, seg[0..dot], " ");
    var buf: [8]u8 = undefined;
    if (stem.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, stem);
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$", "clock$" }) |n| {
        if (std.mem.eql(u8, lower, n)) return true;
    }
    if (!std.mem.startsWith(u8, lower, "com") and !std.mem.startsWith(u8, lower, "lpt")) return false;
    const rest = lower[3..];
    if (rest.len == 1) return rest[0] >= '1' and rest[0] <= '9';
    // ¹ ² ³ are U+00B9, U+00B2, U+00B3.
    return rest.len == 2 and rest[0] == 0xc2 and (rest[1] == 0xb9 or rest[1] == 0xb2 or rest[1] == 0xb3);
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

test "pwd_path: drive forms" {
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

test "pwd_path: network paths are refused in every spelling" {
    // The path of `file://localhost//h/s`, `file:////h/s`,
    // `kitty-shell-cwd://localhost//h/s`, `kitty-shell-cwd:///\\h\s` (cmd
    // on a UNC directory) and the same with the slashes the other way round.
    try expectTranslate("//server/share/dir", null);
    try expectTranslate("///server/share/dir", null);
    try expectTranslate("//attacker.example/share", null);
    try expectTranslate("//attacker@SSL@443/x", null);
    try expectTranslate("/\\\\server\\share", null);
    try expectTranslate("\\\\server\\share", null);
    try expectTranslate("\\/server/share", null);
    try expectTranslate("//server/share/../../c/x", null);
    try expectTranslate("//c/x", null);
    try expectTranslate("//C:/x", null);
    try expectTranslate("//?/C:/x", null);
    try expectTranslate("//./C:/x", null);
    try expectTranslate("\\\\?\\C:\\x", null);
    try expectTranslate("\\\\.\\C:\\x", null);
    try expectTranslate("/??/C:/x", null);
}

test "pwd_path: dot segments are resolved" {
    try expectTranslate("/c/a/./b/../c", "C:\\a\\c");
    try expectTranslate("/c/a//b", "C:\\a\\b");
    try expectTranslate("/c/a/..", "C:\\");
    try expectTranslate("/c/..", null);
    try expectTranslate("/c/a/../../b", null);
    try expectTranslate("/C:/../x", null);
}

test "pwd_path: not a drive path" {
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

test "pwd_path: unsafe input is refused" {
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
    try expectTranslate("/c/\xff\xfe", null);
    // C1 controls and bidi characters.
    try expectTranslate("/c/a\xc2\x85b", null);
    try expectTranslate("/c/a\xc2\x9bb", null);
    try expectTranslate("/c/a\xe2\x80\xaeb", null);
    try expectTranslate("/c/a\xe2\x81\xa7b", null);
    try expectTranslate("/c/a\xe2\x80\xa8b", null);
    try expectTranslate("/c/a\xd8\x9cb", null);
    // Zero-width and invisible format characters.
    try expectTranslate("/c/a\xe2\x80\x8bb", null); // U+200B
    try expectTranslate("/c/a\xe2\x80\x8cb", null); // U+200C
    try expectTranslate("/c/a\xe2\x80\x8db", null); // U+200D
    try expectTranslate("/c/a\xe2\x81\xa0b", null); // U+2060
    try expectTranslate("/c/a\xe2\x81\xa4b", null); // U+2064
    try expectTranslate("/c/a\xef\xbb\xbfb", null); // U+FEFF
    try expectTranslate("/c/a\xc2\xadb", null); // U+00AD
    try expectTranslate("/c/\xc3\xa9\xc2\xa0", "C:\\\xc3\xa9\xc2\xa0");
}

test "pwd_path: device names" {
    try expectTranslate("/c/CON", null);
    try expectTranslate("/c/dir/nul.txt", null);
    try expectTranslate("/c/COM1", null);
    try expectTranslate("/c/lpt9.x", null);
    try expectTranslate("/c/CONIN$", null);
    try expectTranslate("/c/conout$.log", null);
    try expectTranslate("/c/CLOCK$", null);
    try expectTranslate("/c/COM\xc2\xb9", null);
    try expectTranslate("/c/lpt\xc2\xb2.txt", null);
    try expectTranslate("/c/COM\xc2\xb3", null);
    try expectTranslate("/c/console", "C:\\console");
    try expectTranslate("/c/com10", "C:\\com10");
    try expectTranslate("/c/com0", "C:\\com0");
    try expectTranslate("/c/COM\xc2\xb4", "C:\\COM\xc2\xb4");
}

test "pwd_path: the result fits the CreateProcess limit" {
    // "C:" + "\" + 255 units = 258.
    var buf: [3 + 256]u8 = undefined;
    @memcpy(buf[0..3], "/c/");
    @memset(buf[3..], 'a');
    var want: [3 + 255]u8 = undefined;
    @memcpy(want[0..3], "C:\\");
    @memset(want[3..], 'a');
    try expectTranslate(buf[0 .. 3 + 255], &want);
    try expectTranslate(buf[0 .. 3 + 256], null);

    // Units, not bytes: a two-byte letter is one unit.
    var cyr: [3 + 2 * 256]u8 = undefined;
    @memcpy(cyr[0..3], "/c/");
    var i: usize = 3;
    while (i < cyr.len) : (i += 2) {
        cyr[i] = 0xd0;
        cyr[i + 1] = 0xb0;
    }
    const got = try translate(std.testing.allocator, cyr[0 .. 3 + 2 * 255]);
    defer if (got) |g| std.testing.allocator.free(g);
    try std.testing.expect(got != null);
    try expectTranslate(&cyr, null);
}
