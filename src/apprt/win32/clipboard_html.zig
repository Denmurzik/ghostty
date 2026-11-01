//! CF_HTML ("HTML Format") encoding and decoding. Pure functions over
//! bytes: no Win32 calls. The block read by `fragment` comes from another
//! program, so every offset in it is treated as hostile.
//!
//! Layout of a block (all offsets are byte offsets from the first byte):
//!
//!     Version:0.9\r\n
//!     StartHTML:0000000105\r\n
//!     EndHTML:0000000200\r\n
//!     StartFragment:0000000141\r\n
//!     EndFragment:0000000170\r\n
//!     <html><body>\r\n
//!     <!--StartFragment-->...<!--EndFragment-->\r\n
//!     </body>\r\n</html>
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const start_marker = "<!--StartFragment-->";
pub const end_marker = "<!--EndFragment-->";

const plain_prefix = "<html><body>\r\n";
const plain_suffix = "\r\n</body>\r\n</html>";

/// Biggest value the ten digit header fields can hold.
const max_offset: u64 = 9_999_999_999;

const header_fmt = "Version:0.9\r\n" ++
    "StartHTML:{d:0>10}\r\n" ++
    "EndHTML:{d:0>10}\r\n" ++
    "StartFragment:{d:0>10}\r\n" ++
    "EndFragment:{d:0>10}\r\n";

/// Length of the header; it is fixed because the numbers are zero padded.
const header_len: usize = std.fmt.comptimePrint(header_fmt, .{ 0, 0, 0, 0 }).len;

pub const WrapError = Allocator.Error || error{TooLarge};

fn isBodyTagEnd(c: u8) bool {
    return c == '>' or c == '/' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Index just past the `>` of the first `<body ...>` tag, if there is one.
fn bodyOpenEnd(html: []const u8) ?usize {
    var from: usize = 0;
    while (std.ascii.findIgnoreCase(html[from..], "<body")) |rel| {
        const at = from + rel;
        const after = at + "<body".len;
        if (after < html.len and isBodyTagEnd(html[after])) {
            const gt = std.mem.indexOfScalarPos(u8, html, after, '>') orelse return null;
            return gt + 1;
        }
        from = after;
    }
    return null;
}

/// Index of the last `</body` at or after `from`, if any.
fn lastBodyClose(html: []const u8, from: usize) ?usize {
    const needle = "</body";
    if (html.len < needle.len) return null;
    var i = html.len - needle.len + 1;
    while (i > from) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(html[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Wraps UTF-8 `html` as a CF_HTML block (no trailing NUL; the clipboard
/// writer adds it). Data that already carries `<!--StartFragment-->` is
/// indexed as is, data with a `<body>` tag gets the markers inside the
/// body, anything else is wrapped in a minimal document. The caller owns
/// the result.
pub fn wrap(alloc: Allocator, html: []const u8) WrapError![]u8 {
    // The document is `pre ++ s_mark ++ mid ++ e_mark ++ post`; the
    // fragment is `mid`.
    var pre: []const u8 = undefined;
    var s_mark: []const u8 = "";
    var mid: []const u8 = undefined;
    var e_mark: []const u8 = "";
    var post: []const u8 = "";

    if (std.mem.indexOf(u8, html, start_marker)) |s| {
        // Already marked: index it as is.
        const sf = s + start_marker.len;
        const ef = std.mem.indexOfPos(u8, html, sf, end_marker) orelse html.len;
        pre = html[0..sf];
        mid = html[sf..ef];
        post = html[ef..];
    } else if (bodyOpenEnd(html)) |bo| {
        const bc = lastBodyClose(html, bo) orelse html.len;
        pre = html[0..bo];
        s_mark = start_marker;
        mid = html[bo..bc];
        e_mark = end_marker;
        post = html[bc..];
    } else {
        pre = plain_prefix;
        s_mark = start_marker;
        mid = html;
        e_mark = end_marker;
        post = plain_suffix;
    }

    const doc_len: u64 = @as(u64, pre.len) + s_mark.len + mid.len + e_mark.len + post.len;
    const total: u64 = header_len + doc_len;
    if (total > max_offset) return error.TooLarge;

    const start_html: u64 = header_len;
    const end_html: u64 = total;
    const start_frag: u64 = header_len + pre.len + s_mark.len;
    const end_frag: u64 = start_frag + mid.len;

    const out = try alloc.alloc(u8, @intCast(total));
    errdefer alloc.free(out);

    const head = std.fmt.bufPrint(out, header_fmt, .{ start_html, end_html, start_frag, end_frag }) catch unreachable;
    std.debug.assert(head.len == header_len);

    var at: usize = head.len;
    for ([_][]const u8{ pre, s_mark, mid, e_mark, post }) |part| {
        @memcpy(out[at..][0..part.len], part);
        at += part.len;
    }
    std.debug.assert(at == out.len);
    return out;
}

const Header = struct {
    /// Offset of the first byte after the header lines.
    end: usize = 0,
    /// True when at least one CF_HTML key was seen.
    any: bool = false,
    start_html: ?usize = null,
    end_html: ?usize = null,
    start_fragment: ?usize = null,
    end_fragment: ?usize = null,
};

/// Header scanning stays inside this much of the block.
const max_header_bytes = 64 * 1024;
const max_header_lines = 64;

/// A decimal value no larger than `limit`. `-1` (absent), negatives,
/// non-digits, empty values and anything longer than 12 digits are null.
fn parseOffset(raw: []const u8, limit: usize) ?usize {
    const v = std.mem.trim(u8, raw, " \t");
    if (v.len == 0 or v.len > 12) return null;
    var n: u64 = 0;
    for (v) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n > limit) return null;
    return @intCast(n);
}

fn parseHeader(block: []const u8) Header {
    var h: Header = .{};
    const window = block[0..@min(block.len, max_header_bytes)];

    var pos: usize = 0;
    var lines: usize = 0;
    while (pos < window.len and lines < max_header_lines) : (lines += 1) {
        const nl = std.mem.indexOfScalarPos(u8, window, pos, '\n');
        const line_end = nl orelse window.len;
        const line = std.mem.trimEnd(u8, window[pos..line_end], "\r");

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse break;
        const key = line[0..colon];
        if (key.len == 0) break;
        for (key) |c| if (!std.ascii.isAlphabetic(c)) {
            h.end = pos;
            return finish(&h, block);
        };

        const val = line[colon + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "Version")) {
            h.any = true;
        } else if (std.ascii.eqlIgnoreCase(key, "StartHTML")) {
            h.any = true;
            h.start_html = parseOffset(val, block.len);
        } else if (std.ascii.eqlIgnoreCase(key, "EndHTML")) {
            h.any = true;
            h.end_html = parseOffset(val, block.len);
        } else if (std.ascii.eqlIgnoreCase(key, "StartFragment")) {
            h.any = true;
            h.start_fragment = parseOffset(val, block.len);
        } else if (std.ascii.eqlIgnoreCase(key, "EndFragment")) {
            h.any = true;
            h.end_fragment = parseOffset(val, block.len);
        }

        pos = if (nl) |i| i + 1 else window.len;
    }
    h.end = pos;
    return finish(&h, block);
}

/// Offsets that point into the header itself are lies.
fn finish(h: *Header, block: []const u8) Header {
    _ = block;
    inline for (.{ "start_html", "end_html", "start_fragment", "end_fragment" }) |f| {
        if (@field(h, f)) |v| {
            if (v < h.end) @field(h, f) = null;
        }
    }
    return h.*;
}

fn trimNul(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\x00");
}

/// The HTML fragment inside a CF_HTML `block`, borrowed from it, or null
/// when the block has no CF_HTML header or no usable content. Header
/// offsets are honored only when they are decimal, inside the block and in
/// order; otherwise the fragment markers, then `StartHTML..EndHTML`, then
/// everything after the header is used. Never reads out of bounds.
pub fn fragment(block: []const u8) ?[]const u8 {
    const h = parseHeader(block);
    if (!h.any) return null;

    // 1. The fragment offsets.
    if (h.start_fragment) |s| {
        if (h.end_fragment) |e| {
            if (s <= e) return block[s..e];
        }
    }

    const rest = block[h.end..];

    // 2. The markers.
    if (std.mem.indexOf(u8, rest, start_marker)) |i| {
        const s = i + start_marker.len;
        const e = std.mem.indexOfPos(u8, rest, s, end_marker) orelse rest.len;
        const frag = trimNul(rest[s..e]);
        if (frag.len > 0) return frag;
    }

    // 3. StartHTML..EndHTML, with a missing end meaning the block end.
    const sh = h.start_html orelse h.end;
    const eh = h.end_html orelse block.len;
    if (sh <= eh) {
        const html = trimNul(block[sh..eh]);
        if (html.len > 0) return html;
    }

    // 4. Whatever follows the header.
    const tail = trimNul(rest);
    if (tail.len > 0) return tail;
    return null;
}

// -- tests ----------------------------------------------------------------

fn headerField(block: []const u8, key: []const u8) usize {
    var it = std.mem.splitScalar(u8, block[0..header_len], '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, l, key) and l.len > key.len and l[key.len] == ':') {
            return std.fmt.parseInt(usize, l[key.len + 1 ..], 10) catch unreachable;
        }
    }
    unreachable;
}

test "win32 clipboard html: wrap computes offsets" {
    const alloc = std.testing.allocator;

    {
        const b = try wrap(alloc, "<b>x</b>");
        defer alloc.free(b);

        const sh = headerField(b, "StartHTML");
        const eh = headerField(b, "EndHTML");
        const sf = headerField(b, "StartFragment");
        const ef = headerField(b, "EndFragment");

        try std.testing.expect(std.mem.startsWith(u8, b, "Version:0.9\r\nStartHTML:"));
        try std.testing.expect(std.mem.startsWith(u8, b[sh..], "<html>"));
        try std.testing.expect(std.mem.startsWith(u8, b[sf..], "<b>"));
        try std.testing.expect(std.mem.startsWith(u8, b[ef..], "<!--EndFragment-->"));
        try std.testing.expectEqualStrings("<b>x</b>", b[sf..ef]);
        try std.testing.expectEqual(b.len, eh);
        try std.testing.expect(std.mem.endsWith(u8, b, "</html>"));
        try std.testing.expectEqualStrings("<b>x</b>", fragment(b).?);
    }

    // A <body> tag gets the markers inside it.
    {
        const src = "<html><body class=a>hi <i>there</i></body></html>";
        const b = try wrap(alloc, src);
        defer alloc.free(b);
        const sf = headerField(b, "StartFragment");
        const ef = headerField(b, "EndFragment");
        try std.testing.expectEqualStrings("hi <i>there</i>", b[sf..ef]);
        try std.testing.expect(std.mem.startsWith(u8, b[sf - start_marker.len ..], start_marker));
        try std.testing.expect(std.mem.indexOf(u8, b, "<body class=a><!--StartFragment-->hi") != null);
        try std.testing.expect(std.mem.indexOf(u8, b, "there</i><!--EndFragment--></body>") != null);
        try std.testing.expectEqualStrings("hi <i>there</i>", fragment(b).?);
    }

    // Uppercase tags and a missing </body>.
    {
        const b = try wrap(alloc, "<BODY>x");
        defer alloc.free(b);
        try std.testing.expectEqualStrings("x", fragment(b).?);
    }

    // `<bodyguard>` is not a body tag.
    {
        const b = try wrap(alloc, "<bodyguard>x");
        defer alloc.free(b);
        try std.testing.expect(std.mem.indexOf(u8, b, "<html><body>\r\n<!--StartFragment--><bodyguard>x") != null);
    }

    // Already marked data is indexed as is, not double-marked.
    {
        const src = "<p>a<!--StartFragment-->mid<!--EndFragment-->z</p>";
        const b = try wrap(alloc, src);
        defer alloc.free(b);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, b, start_marker));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, b, end_marker));
        try std.testing.expectEqual(header_len, headerField(b, "StartHTML"));
        try std.testing.expectEqual(b.len, headerField(b, "EndHTML"));
        try std.testing.expectEqualStrings(src, b[header_len..]);
        try std.testing.expectEqualStrings("mid", fragment(b).?);
    }

    // Empty input still produces a block that reads back as empty.
    {
        const b = try wrap(alloc, "");
        defer alloc.free(b);
        try std.testing.expectEqualStrings("", fragment(b).?);
    }

    // Round trip of non-ASCII UTF-8.
    {
        const src = "<span>\xd0\xb6\xd0\xb6</span>";
        const b = try wrap(alloc, src);
        defer alloc.free(b);
        try std.testing.expectEqualStrings(src, fragment(b).?);
    }
}

/// Builds a block the way Chrome and Word do: a header with exact
/// offsets (`StartHTML` can be -1), `extra` header lines, then `doc`,
/// which must contain both markers.
fn realBlock(alloc: Allocator, extra: []const u8, no_html_offsets: bool, doc: []const u8, eol: []const u8) ![]u8 {
    const fmt_html = "Version:0.9{s}StartHTML:{s}{s}EndHTML:{s}{s}StartFragment:{d:0>10}{s}EndFragment:{d:0>10}{s}";
    const dummy = "0000000000";
    const probe = try std.fmt.allocPrint(alloc, fmt_html, .{ eol, dummy, eol, dummy, eol, 0, eol, 0, eol });
    defer alloc.free(probe);
    const head_len = probe.len + extra.len;

    const sf = head_len + std.mem.indexOf(u8, doc, start_marker).? + start_marker.len;
    const ef = head_len + std.mem.indexOf(u8, doc, end_marker).?;
    var sh_buf: [10]u8 = undefined;
    var eh_buf: [10]u8 = undefined;
    const sh = if (no_html_offsets) "-1" else try std.fmt.bufPrint(&sh_buf, "{d:0>10}", .{head_len});
    const eh = if (no_html_offsets) "-1" else try std.fmt.bufPrint(&eh_buf, "{d:0>10}", .{head_len + doc.len});

    // `-1` is shorter than ten digits, so the real header is shorter too;
    // recompute with the actual widths.
    const real_head = try std.fmt.allocPrint(alloc, fmt_html, .{ eol, sh, eol, eh, eol, 0, eol, 0, eol });
    defer alloc.free(real_head);
    const delta = probe.len - real_head.len;
    const sf2 = sf - delta;
    const ef2 = ef - delta;
    const head = try std.fmt.allocPrint(alloc, fmt_html, .{ eol, sh, eol, eh, eol, sf2, eol, ef2, eol });
    defer alloc.free(head);
    return std.mem.concat(alloc, u8, &.{ head, extra, doc });
}

test "win32 clipboard html: fragment of real-world blocks" {
    const alloc = std.testing.allocator;

    // Chrome style: all offsets, SourceURL and selection lines.
    {
        const extra = "StartSelection:0000000000\r\nEndSelection:0000000000\r\nSourceURL:https://example.com/a?b=c\r\n";
        const doc = "<html>\r\n<body>\r\n<!--StartFragment-->HELLO <b>WORLD</b><!--EndFragment-->\r\n</body>\r\n</html>";
        const b = try realBlock(alloc, extra, false, doc, "\r\n");
        defer alloc.free(b);
        try std.testing.expectEqualStrings("HELLO <b>WORLD</b>", fragment(b).?);
        // The same block with a NUL terminator, as the clipboard hands it out.
        const nul = try std.mem.concat(alloc, u8, &.{ b, "\x00" });
        defer alloc.free(nul);
        try std.testing.expectEqualStrings("HELLO <b>WORLD</b>", fragment(nul).?);
    }

    // Word style: -1 StartHTML/EndHTML, CRLF.
    {
        const doc = "<html><body><!--StartFragment--><p>word</p><!--EndFragment--></body></html>";
        const b = try realBlock(alloc, "", true, doc, "\r\n");
        defer alloc.free(b);
        try std.testing.expect(std.mem.indexOf(u8, b, "StartHTML:-1") != null);
        try std.testing.expectEqualStrings("<p>word</p>", fragment(b).?);
    }

    // Same with LF line ends.
    {
        const doc = "<html><!--StartFragment-->lf<!--EndFragment--></html>";
        const b = try realBlock(alloc, "SourceURL:x\n", false, doc, "\n");
        defer alloc.free(b);
        try std.testing.expectEqualStrings("lf", fragment(b).?);
    }

    // Offsets past the end: marker fallback.
    {
        const b =
            "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000009999\r\n" ++
            "StartFragment:0000009990\r\nEndFragment:0000009999\r\n" ++
            "<html><!--StartFragment-->ok<!--EndFragment--></html>";
        try std.testing.expectEqualStrings("ok", fragment(b).?);
    }

    // No fragment offsets and no markers: StartHTML..EndHTML.
    {
        const pre = "Version:0.9\r\nStartHTML:0000000055\r\nEndHTML:0000000063\r\n";
        try std.testing.expectEqual(@as(usize, 55), pre.len);
        const b = pre ++ "<b>x</b>JUNK";
        try std.testing.expectEqualStrings("<b>x</b>", fragment(b).?);
    }

    // Only a Version line: the body after the header, NUL trimmed.
    try std.testing.expectEqualStrings("<i>q</i>", fragment("Version:0.9\r\n<i>q</i>\x00\x00").?);

    // No header at all, or nothing after it.
    try std.testing.expect(fragment("<html>plain</html>") == null);
    try std.testing.expect(fragment("") == null);
    try std.testing.expect(fragment("Version:0.9\r\n") == null);
    try std.testing.expect(fragment("Hello: world\r\nbody") == null);
}

fn fragmentChecked(block: []const u8) void {
    if (fragment(block)) |f| {
        const lo = @intFromPtr(block.ptr);
        const hi = lo + block.len;
        const p = @intFromPtr(f.ptr);
        std.debug.assert(p >= lo and p + f.len <= hi);
    }
}

const hostile_corpus = [_][]const u8{
    "Version:0.9\r\nStartHTML:99999999999\r\nEndHTML:99999999999\r\nStartFragment:99999999999\r\nEndFragment:99999999999\r\n<b>x</b>",
    "Version:0.9\r\nStartHTML:-5\r\nEndHTML:-7\r\nStartFragment:-2\r\nEndFragment:-9\r\n<b>x</b>",
    "Version:0.9\r\nStartHTML:0000000100\r\nEndHTML:0000000050\r\nStartFragment:0000000090\r\nEndFragment:0000000060\r\nabc",
    "Version:0.9\r\nStartHTML:12ab\r\nEndHTML:0x10\r\nStartFragment: \r\nEndFragment:\r\n<i>y</i>",
    "Version:0.9\r\nStartHTML:18446744073709551616\r\nEndHTML:00000000000000000001\r\nStartFragment:+3\r\nEndFragment:3.0\r\nzz",
    "Version:0.9\r\nStartFragment:0000000000\r\nEndFragment:0000000005\r\nabcdefghij",
    "StartFragment:5\nEndFragment:2\n",
    "Version:0.9\r\nStartHTML:5",
    "Version:0.9\r\n<!--StartFragment-->",
    "Version:0.9\r\n<!--EndFragment--><!--StartFragment-->x",
    "Version:\x00\x00\x00:::\r\n\r\n\r\n",
    ":",
    "\r\n",
    "\n\n\n",
    "a:b\r\nVersion:1\r\n",
};

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [768]u8 = undefined;
    const n = smith.slice(&buf);
    fragmentChecked(buf[0..n]);
}

test "win32 clipboard html: hostile headers" {
    // Direct corpus run, independent of whether the runner is fuzzing.
    for (hostile_corpus) |b| fragmentChecked(b);

    // Every prefix and a deterministic byte-mutation sweep of the corpus.
    var prng = std.Random.DefaultPrng.init(0x6767);
    const rand = prng.random();
    var scratch: [512]u8 = undefined;
    for (hostile_corpus) |b| {
        var i: usize = 0;
        while (i <= b.len) : (i += 1) fragmentChecked(b[0..i]);

        const len = @min(b.len, scratch.len);
        var round: usize = 0;
        while (round < 200) : (round += 1) {
            @memcpy(scratch[0..len], b[0..len]);
            const edits = rand.intRangeAtMost(usize, 1, 4);
            for (0..edits) |_| {
                if (len == 0) break;
                scratch[rand.uintLessThan(usize, len)] = rand.int(u8);
            }
            fragmentChecked(scratch[0..len]);
        }
    }

    // A header that never ends and a very long run of header lines.
    var big: [70_000]u8 = undefined;
    @memset(&big, 'a');
    @memcpy(big[0..12], "Version:0.9\n");
    fragmentChecked(&big);
    var lines: [4096]u8 = undefined;
    for (0..lines.len / 4) |i| @memcpy(lines[i * 4 ..][0..4], "A:1\n");
    fragmentChecked(&lines);

    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &hostile_corpus });
}
