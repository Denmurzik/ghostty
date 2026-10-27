//! Text helpers of the link policy; `shell_open.validate` decides. Links come
//! from terminal output, which any program controls.
const std = @import("std");
const apprt = @import("../../apprt.zig");

pub const max_len = 2048;

/// `text` and `html` are paths Ghostty wrote itself; `unknown` and `osc8`
/// come from terminal output and must go through `shell_open.validate`.
pub fn isTrusted(kind: apprt.action.OpenUrl.Kind) bool {
    return switch (kind) {
        .text, .html => true,
        .unknown, .osc8 => false,
    };
}

/// Printable ASCII without the characters RFC 3986 excludes; anything else
/// must arrive percent-encoded, so a handler that splices the URL into a
/// command line or a bidi override cannot be smuggled in.
pub fn isPlainUrl(url: []const u8) bool {
    for (url) |c| {
        if (c < 0x21 or c > 0x7e) return false;
        switch (c) {
            '\\', '<', '>', '^', '`', '{', '|', '}', '"' => return false,
            else => {},
        }
    }
    return true;
}

/// A `mailto:` header named attach or attachment makes some clients attach
/// a local file. Compares the percent-decoded header names only.
pub fn hasAttachment(buf: []u8, rest: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse return false;
    var it = std.mem.splitScalar(u8, rest[q + 1 ..], '&');
    while (it.next()) |field| {
        const key = field[0 .. std.mem.indexOfScalar(u8, field, '=') orelse field.len];
        const name = std.mem.trim(u8, percentDecode(buf, key), &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(name, "attach") or std.ascii.eqlIgnoreCase(name, "attachment")) return true;
    }
    return false;
}

/// Decodes valid `%XX` escapes into `buf`; the result is cut at `buf.len`.
pub fn percentDecode(buf: []u8, in: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len and n < buf.len) : (i += 1) {
        var c = in[i];
        if (c == '%' and i + 2 < in.len) {
            if (std.fmt.parseInt(u8, in[i + 1 .. i + 3], 16)) |d| {
                c = d;
                i += 2;
            } else |_| {}
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Index of the ':' ending a URL scheme of two or more characters, null if
/// the text has none (a single letter is a drive, not a scheme).
pub fn schemeEnd(url: []const u8) ?usize {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return null;
    for (url, 0..) |c, i| {
        if (c == ':') return if (i >= 2) i else null;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return null;
}

pub fn isSlash(c: u8) bool {
    return c == '/' or c == '\\';
}

pub fn isDriveAbsolute(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSlash(p[2]);
}

/// U+200E/200F, U+202A..202E, U+2066..2069, U+2028/2029, U+061C and U+0085 in UTF-8.
pub fn hasBidiControl(path: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < path.len) : (i += 1) {
        if (path[i] != 0xE2) continue;
        const b1 = path[i + 1];
        const b2 = path[i + 2];
        if (b1 == 0x80 and (b2 == 0x8E or b2 == 0x8F or (b2 >= 0xA8 and b2 <= 0xAE))) return true;
        if (b1 == 0x81 and b2 >= 0xA6 and b2 <= 0xA9) return true;
    }
    // U+061C and U+0085.
    return std.mem.indexOf(u8, path, "\xd8\x9c") != null or std.mem.indexOf(u8, path, "\xc2\x85") != null;
}

/// CON, PRN, AUX, NUL, CONIN$, CONOUT$, CLOCK$, COM1-9, LPT1-9 with any extension.
pub fn isDeviceName(part: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, part, '.') orelse part.len;
    const stem = std.mem.trimEnd(u8, part[0..dot], " ");
    const names = [_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$", "clock$" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(stem, n)) return true;
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') {
        if (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) return true;
    }
    return false;
}

test "win32 link policy: only terminal-controlled kinds are checked" {
    try std.testing.expect(isTrusted(.text));
    try std.testing.expect(isTrusted(.html));
    try std.testing.expect(!isTrusted(.unknown));
    try std.testing.expect(!isTrusted(.osc8));
}
