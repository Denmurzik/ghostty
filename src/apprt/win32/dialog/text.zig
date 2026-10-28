//! Text for the dialog: UTF-8 to UTF-16 conversion that never lets a
//! control or bidi character through unseen. A confirmation shows the very
//! text the user is asked about, so a character that reorders or hides
//! other characters is written out as `<U+202E>` instead of being drawn.
const std = @import("std");

/// The codepoint that stands in for bytes that are not valid UTF-8.
pub const replacement: u21 = 0xFFFD;

/// First codepoint of the Unicode "Control Pictures" block: U+2400 + c is
/// the visible symbol for the control character c.
pub const control_pictures: u21 = 0x2400;

/// Decode the codepoint at `text[i.*]` and advance `i`. A byte that does
/// not start a valid sequence yields U+FFFD and advances by one.
pub fn nextCodepoint(text: []const u8, i: *usize) u21 {
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

/// Characters that change how text is ordered or hide it: bidi controls,
/// zero width and invisible formatting characters, the BOM, NEL, the line
/// and paragraph separators, Hangul fillers, interlinear annotation marks and
/// tag characters. A superset of shell_open.hasForbidden's bidi set.
pub fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0x0085, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x180E, 0x3164, 0xFEFF, 0xFFA0 => true,
        0x180B...0x180D => true,
        0xFFF9...0xFFFB => true,
        // Tag characters: invisible text that survives a paste.
        0xE0000...0xE007F => true,
        0x200B...0x200F => true,
        0x2028...0x202E => true,
        0x2060...0x2064 => true,
        0x2066...0x206F => true,
        else => false,
    };
}

/// Appends UTF-16 units to a fixed buffer; a character that does not fit
/// is dropped whole.
const Sink = struct {
    buf: []u16,
    n: usize = 0,

    fn room(self: *const Sink, units: usize) bool {
        return self.n + units + 1 <= self.buf.len;
    }

    fn unit(self: *Sink, u: u16) bool {
        if (!self.room(1)) return false;
        self.buf[self.n] = u;
        self.n += 1;
        return true;
    }

    fn codepoint(self: *Sink, cp: u21) bool {
        if (cp < 0x10000) return self.unit(@intCast(cp));
        if (!self.room(2)) return false;
        const c = cp - 0x10000;
        self.buf[self.n] = 0xD800 + @as(u16, @intCast(c >> 10));
        self.buf[self.n + 1] = 0xDC00 + @as(u16, @intCast(c & 0x3FF));
        self.n += 2;
        return true;
    }

    /// `<U+XXXX>`, all or nothing.
    fn escape(self: *Sink, cp: u21) bool {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "<U+{X:0>4}>", .{cp}) catch unreachable;
        if (!self.room(s.len)) return false;
        for (s) |c| _ = self.unit(c);
        return true;
    }

    fn spaces(self: *Sink, count: usize) bool {
        if (!self.room(count)) return false;
        for (0..count) |_| _ = self.unit(' ');
        return true;
    }
};

pub const Mode = enum {
    /// Control characters, newlines included, become control pictures:
    /// a single line of text.
    single_line,
    /// Newlines stay; tabs become four spaces.
    paragraphs,
};

/// UTF-8 to a null-terminated UTF-16 string in `buf`, cut at the buffer's
/// end (never in the middle of a surrogate pair or an escape). Invalid
/// bytes show as U+FFFD. Control characters and invisible or bidi
/// formatting characters never reach the output as themselves.
pub fn toWide(buf: []u16, text: []const u8, mode: Mode) [:0]u16 {
    var sink: Sink = .{ .buf = buf };
    var i: usize = 0;
    while (i < text.len) {
        const cp = nextCodepoint(text, &i);
        const para = mode == .paragraphs;
        const ok = switch (cp) {
            '\n' => if (para) sink.unit('\n') else sink.codepoint(control_pictures + '\n'),
            '\r' => if (para) true else sink.codepoint(control_pictures + '\r'),
            '\t' => if (para) sink.spaces(4) else sink.codepoint(control_pictures + '\t'),
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => sink.codepoint(control_pictures + cp),
            0x7F => sink.codepoint(control_pictures + 0x21),
            0x80...0x9F => sink.escape(cp),
            else => if (isInvisible(cp)) sink.escape(cp) else sink.codepoint(cp),
        };
        if (!ok) break;
    }
    buf[sink.n] = 0;
    return buf[0..sink.n :0];
}

pub const Stripped = struct { len: usize, accel: u16 };

/// `&Close` to `Close` with its accelerator: `&&` is a literal `&`.
/// Returns the label length in `out` and the accelerator character
/// (uppercased ASCII letter or digit), 0 for none.
pub fn stripAccelerator(out: []u16, label: []const u16) Stripped {
    var n: usize = 0;
    var accel: u16 = 0;
    var i: usize = 0;
    while (i < label.len and n < out.len) : (i += 1) {
        const c = label[i];
        if (c == '&' and i + 1 < label.len) {
            i += 1;
            const next = label[i];
            if (next != '&' and accel == 0) {
                accel = if (next >= 'a' and next <= 'z') next - 32 else next;
            }
            out[n] = next;
            n += 1;
            continue;
        }
        out[n] = c;
        n += 1;
    }
    const valid = (accel >= 'A' and accel <= 'Z') or (accel >= '0' and accel <= '9');
    return .{ .len = n, .accel = if (valid) accel else 0 };
}

test "win32 dialog text: controls and bidi are shown, not obeyed" {
    var buf: [128]u16 = undefined;

    // Single line: newline, ESC and DEL become symbols.
    const one = toWide(&buf, "a\nb\x1b\x7f", .single_line);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0x240A, 'b', 0x241B, 0x2421 }, one);

    // Paragraphs keep newlines, drop CR and spread tabs.
    const para = toWide(&buf, "a\r\nb\tc", .paragraphs);
    try std.testing.expectEqualSlices(u16, &.{ 'a', '\n', 'b', ' ', ' ', ' ', ' ', 'c' }, para);

    // RLO and a zero width space are written out.
    var expect: [64]u16 = undefined;
    const out = toWide(&buf, "evil\u{202E}gnp.exe\u{200B}", .paragraphs);
    const want = try std.unicode.utf8ToUtf16Le(&expect, "evil<U+202E>gnp.exe<U+200B>");
    try std.testing.expectEqualSlices(u16, expect[0..want], out);

    // A C1 control is written out as well.
    const c1 = toWide(&buf, "x\u{0085}y", .single_line);
    const want2 = try std.unicode.utf8ToUtf16Le(&expect, "x<U+0085>y");
    try std.testing.expectEqualSlices(u16, expect[0..want2], c1);
}

test "win32 dialog text: tag characters and fillers are written out" {
    var buf: [128]u16 = undefined;
    var expect: [64]u16 = undefined;
    const out = toWide(&buf, "a\u{E0041}b\u{3164}c\u{FFF9}", .paragraphs);
    const want = try std.unicode.utf8ToUtf16Le(&expect, "a<U+E0041>b<U+3164>c<U+FFF9>");
    try std.testing.expectEqualSlices(u16, expect[0..want], out);
}

test "win32 dialog text: truncation never splits an escape or a pair" {
    var buf: [8]u16 = undefined;
    // Room for 7 units: "ab" then the 8 unit escape does not fit.
    const cut = toWide(&buf, "ab\u{202E}c", .paragraphs);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b' }, cut);
    try std.testing.expectEqual(@as(u16, 0), buf[cut.len]);

    const cut2 = toWide(&buf, "abcdef😀", .paragraphs);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 'd', 'e', 'f' }, cut2);

    const wide = toWide(&buf, "aЖ😀\xff", .paragraphs);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0x0416, 0xD83D, 0xDE00, 0xFFFD }, wide);
}

test "win32 dialog text: accelerator stripping" {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    var out: [16]u16 = undefined;
    const r = stripAccelerator(&out, w("&Close"));
    try std.testing.expectEqualSlices(u16, w("Close"), out[0..r.len]);
    try std.testing.expectEqual(@as(u16, 'C'), r.accel);

    const r2 = stripAccelerator(&out, w("Fish && &chips"));
    try std.testing.expectEqualSlices(u16, w("Fish & chips"), out[0..r2.len]);
    try std.testing.expectEqual(@as(u16, 'C'), r2.accel);

    const r3 = stripAccelerator(&out, w("Cancel"));
    try std.testing.expectEqual(@as(u16, 0), r3.accel);
    try std.testing.expectEqual(@as(usize, 6), r3.len);
}
