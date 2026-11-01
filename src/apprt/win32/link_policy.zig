//! Text helpers of the link policy; `shell_open.validate` decides. Links come
//! from terminal output, which any program controls.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const internal_os = @import("../../os/main.zig");
const dialogs = @import("dialogs.zig");

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

/// Whether `s` holds a character that hides text or reorders it (see
/// `dialogs.isDeceptive` with `.link`: C1, U+061C, zero width characters,
/// bidi controls, LS/PS, word joiner, BOM). Invalid UTF-8 is not deceptive
/// here: callers that need valid text check that themselves.
pub fn hasInvisible(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        // A lead byte whose sequence is cut or broken is skipped on its own:
        // what follows it may still be a valid (deceptive) character.
        if (i + len > s.len) {
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
            i += 1;
            continue;
        };
        if (dialogs.isDeceptive(cp, .link)) return true;
        i += len;
    }
    return false;
}

/// A reserved device name (`CON`, `COM1`, `LPT¹`, ...) with any extension;
/// one definition for the links and the OSC 7 paths.
pub const isDeviceName = internal_os.pwd_path.isDeviceName;

test "win32 link policy: only terminal-controlled kinds are checked" {
    try std.testing.expect(isTrusted(.text));
    try std.testing.expect(isTrusted(.html));
    try std.testing.expect(!isTrusted(.unknown));
    try std.testing.expect(!isTrusted(.osc8));
}

test "win32 link policy: device names include the superscript forms" {
    try std.testing.expect(isDeviceName("COM1"));
    try std.testing.expect(isDeviceName("lpt9.txt"));
    try std.testing.expect(isDeviceName("COM\u{b9}"));
    try std.testing.expect(isDeviceName("LPT\u{b2}.log"));
    try std.testing.expect(!isDeviceName("COM10"));
    try std.testing.expect(!isDeviceName("comet"));
}

test "win32 link policy: invisible characters" {
    try std.testing.expect(hasInvisible("x\u{200B}"));
    try std.testing.expect(hasInvisible("\u{FEFF}x"));
    try std.testing.expect(hasInvisible("\u{2060}"));
    try std.testing.expect(hasInvisible("a\u{200D}b"));
    try std.testing.expect(hasInvisible("a\u{202E}b"));
    try std.testing.expect(hasInvisible("a\u{061C}"));
    try std.testing.expect(hasInvisible("a\u{85}b"));
    try std.testing.expect(hasInvisible("a\u{2029}"));
    try std.testing.expect(!hasInvisible("Привет/😀.txt"));
    try std.testing.expect(!hasInvisible("C:\\a\u{A0}b"));
    try std.testing.expect(!hasInvisible(""));
    // Invalid or cut UTF-8 is no crash and not deceptive on its own.
    try std.testing.expect(!hasInvisible("a\xffb"));
    try std.testing.expect(!hasInvisible("a\xe2\x80"));
    try std.testing.expect(!hasInvisible("\xc2"));
    try std.testing.expect(hasInvisible("\xff\xe2\x80\x8b"));
    // A cut lead byte does not hide what follows it.
    try std.testing.expect(hasInvisible("foo:x\xf0\xc2\x85"));
    try std.testing.expect(hasInvisible("x\xe2\x80\xe2\x80\x8b"));
    try std.testing.expect(hasInvisible("x\xf0\x9f\xe2\x80\xae"));
}
