//! Modal confirmation dialogs (MessageBoxW in M1).
//!
//! A message box runs its own message loop, so anything that shows one
//! can see its window, and the surface behind it, destroyed before the
//! call returns. Callers decide when it is safe to show one; see
//! `clipboard.zig` for how that is handled for clipboard prompts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");

const IDYES = 6;
const MB_DEFBUTTON2 = 0x00000100;

/// The codepoint that stands in for bytes that are not valid UTF-8.
const replacement: u21 = 0xFFFD;

/// First codepoint of the Unicode "Control Pictures" block: U+2400 + c is
/// the visible symbol for the control character c.
const control_pictures: u21 = 0x2400;

/// Ask whether a surface with a running process may be closed.
pub fn confirmClose(owner: win32.foundation.HWND) bool {
    return confirm(
        owner,
        "Close Terminal",
        "A process is still running in this terminal. Close it anyway?",
    );
}

/// Show a yes/no question on top of `owner`. True for yes. "No" is the
/// default button: every question asked here is about something that is
/// hard to undo. Text that does not fit the (generous) fixed buffers is
/// cut, and invalid UTF-8 shows as U+FFFD.
pub fn confirm(
    owner: win32.foundation.HWND,
    title: []const u8,
    body: []const u8,
) bool {
    var title_buf: [128]u16 = undefined;
    var body_buf: [2048]u16 = undefined;
    const result = win32.user32.MessageBoxW(
        owner,
        toWide(&body_buf, body),
        toWide(&title_buf, title),
        win32.user32.MB_YESNO | win32.user32.MB_ICONQUESTION | MB_DEFBUTTON2,
    );
    return result == IDYES;
}

/// A single-line, display-safe rendition of `text` for confirmation
/// prompts: control characters (newlines included) become their visible
/// symbols from the U+2400 block, and anything past `max_chars`
/// codepoints is replaced by one "…". Caller owns the result.
pub fn previewText(alloc: Allocator, text: []const u8, max_chars: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        if (count == max_chars) {
            try appendCodepoint(alloc, &out, 0x2026);
            break;
        }

        var cp = nextCodepoint(text, &i);
        if (cp < 0x20) {
            cp += control_pictures;
        } else if (cp == 0x7F) {
            cp = control_pictures + 0x21;
        }
        try appendCodepoint(alloc, &out, cp);
        count += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn appendCodepoint(alloc: Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(alloc, buf[0..n]);
}

/// Decode the codepoint at `text[i.*]` and advance `i`. A byte that does
/// not start a valid sequence yields U+FFFD and advances by one.
fn nextCodepoint(text: []const u8, i: *usize) u21 {
    const start = i.*;
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch {
        i.* += 1;
        return replacement;
    };
    if (start + len > text.len) {
        i.* += 1;
        return replacement;
    }
    const cp = std.unicode.utf8Decode(text[start..][0..len]) catch {
        i.* += 1;
        return replacement;
    };
    i.* += len;
    return cp;
}

/// UTF-8 to a null-terminated UTF-16 string in `buf`, cut at the buffer's
/// end (never in the middle of a surrogate pair).
fn toWide(buf: []u16, text: []const u8) [:0]u16 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = nextCodepoint(text, &i);
        const units: usize = if (cp >= 0x10000) 2 else 1;
        if (n + units + 1 > buf.len) break;

        if (units == 2) {
            const c = cp - 0x10000;
            buf[n] = 0xD800 + @as(u16, @intCast(c >> 10));
            buf[n + 1] = 0xDC00 + @as(u16, @intCast(c & 0x3FF));
        } else {
            buf[n] = @intCast(cp);
        }
        n += units;
    }

    buf[n] = 0;
    return buf[0..n :0];
}

test "win32 dialogs: preview escapes control characters and truncates" {
    const alloc = std.testing.allocator;

    // Newline, tab, CR, ESC and DEL all become visible symbols.
    {
        const out = try previewText(alloc, "a\nb\tc\r\x1b[0m\x7f", 512);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("a\u{240A}b\u{2409}c\u{240D}\u{241B}[0m\u{2421}", out);
    }

    // Truncation counts codepoints, not bytes, and appends one ellipsis.
    {
        const out = try previewText(alloc, "ЖЖЖЖЖЖЖЖЖЖ", 4);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("ЖЖЖЖ…", out);
    }

    // Text of exactly the limit is not truncated.
    {
        const out = try previewText(alloc, "😀😀😀", 3);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("😀😀😀", out);
    }

    // The documented 512 character limit.
    {
        const long = try alloc.alloc(u8, 600);
        defer alloc.free(long);
        @memset(long, 'x');
        const out = try previewText(alloc, long, 512);
        defer alloc.free(out);
        try std.testing.expectEqual(@as(usize, 512 + "…".len), out.len);
        try std.testing.expect(std.mem.endsWith(u8, out, "…"));
    }

    // Invalid UTF-8 and the empty string are fine.
    {
        const out = try previewText(alloc, "a\xffb", 512);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("a\u{FFFD}b", out);

        const empty = try previewText(alloc, "", 512);
        defer alloc.free(empty);
        try std.testing.expectEqualStrings("", empty);
    }
}

test "win32 dialogs: wide conversion handles non-BMP, invalid bytes and truncation" {
    var buf: [8]u16 = undefined;

    const wide = toWide(&buf, "aЖ😀\xff");
    try std.testing.expectEqualSlices(
        u16,
        &.{ 'a', 0x0416, 0xD83D, 0xDE00, 0xFFFD },
        wide,
    );
    try std.testing.expectEqual(@as(u16, 0), buf[wide.len]);

    // Room for 3 units plus the terminator: the surrogate pair does not fit
    // after "ab" so it is dropped whole.
    var small: [4]u16 = undefined;
    const cut = toWide(&small, "ab😀c");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b' }, cut);
}
