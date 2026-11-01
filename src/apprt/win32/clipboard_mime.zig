//! Pure helpers for custom clipboard formats named after MIME types
//! (`RegisterClipboardFormatW(L"image/png")`) and for `text/uri-list`.
//! No Win32 calls: everything here is plain bytes in, bytes out.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest accepted format name, in bytes.
pub const max_name_len = 255;

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '!', '#', '$', '&', '^', '_', '.', '+', '-' => true,
        else => false,
    };
}

fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isTokenChar(c)) return false;
    return true;
}

/// True when `name` has the shape `token "/" token [";" params]`: ASCII,
/// no spaces or control bytes, at most 255 bytes. This is how a clipboard
/// format name is told apart from a native one (`HTML Format`,
/// `FileGroupDescriptorW`, ...), so it is deliberately strict.
pub fn isMimeName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
    if (!isToken(name[0..slash])) return false;

    const rest = name[slash + 1 ..];
    const semi = std.mem.indexOfScalar(u8, rest, ';');
    const subtype = if (semi) |i| rest[0..i] else rest;
    if (!isToken(subtype)) return false;

    if (semi) |i| {
        // Parameters: printable ASCII without space.
        for (rest[i + 1 ..]) |c| {
            if (c <= 0x20 or c >= 0x7f) return false;
        }
    }
    return true;
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Appends `s` with every byte that is not an RFC 3986 unreserved
/// character percent-encoded, except `/` which separates segments.
fn appendEncoded(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(alloc, c);
        } else {
            try out.appendSlice(alloc, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
}

pub const UriError = Allocator.Error || error{InvalidUtf16};

/// Builds a `text/uri-list` body: one `file:` URI per path, each followed
/// by `\r\n`. A drive path `C:\a b` becomes `file:///C:/a%20b`, a UNC path
/// `\\srv\share\x` becomes `file://srv/share/x`. Paths are UTF-16 (native
/// endian, as Windows delivers them); a lone surrogate is an error, an
/// empty path is skipped. The caller owns the result.
pub fn uriList(alloc: Allocator, paths: []const []const u16) UriError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (paths) |path| {
        if (path.len == 0) continue;
        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidUtf16,
        };
        defer alloc.free(utf8);

        // Backslashes become slashes before anything else looks at it.
        const norm = try alloc.dupe(u8, utf8);
        defer alloc.free(norm);
        std.mem.replaceScalar(u8, norm, '\\', '/');

        var p: []const u8 = norm;
        // Long-path prefixes: `\\?\C:\x` and `\\?\UNC\srv\share`.
        if (std.mem.startsWith(u8, p, "//?/") or std.mem.startsWith(u8, p, "//./")) {
            p = p[4..];
            if (p.len >= 4 and std.ascii.eqlIgnoreCase(p[0..3], "UNC") and p[3] == '/') {
                // `UNC/srv/share` -> UNC form without the leading slashes.
                try out.appendSlice(alloc, "file://");
                try appendEncoded(alloc, &out, p[4..]);
                try out.appendSlice(alloc, "\r\n");
                continue;
            }
        }

        if (std.mem.startsWith(u8, p, "//")) {
            // UNC: the first segment is the host.
            try out.appendSlice(alloc, "file://");
            try appendEncoded(alloc, &out, p[2..]);
        } else if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') {
            // Drive letter: the colon stays literal.
            try out.appendSlice(alloc, "file:///");
            try out.append(alloc, p[0]);
            try out.append(alloc, ':');
            try appendEncoded(alloc, &out, p[2..]);
        } else {
            try out.appendSlice(alloc, "file://");
            if (p[0] != '/') try out.append(alloc, '/');
            try appendEncoded(alloc, &out, p);
        }
        try out.appendSlice(alloc, "\r\n");
    }

    return out.toOwnedSlice(alloc);
}

test "win32 clipboard mime: names" {
    const t = std.testing;
    try t.expect(isMimeName("image/png"));
    try t.expect(isMimeName("text/plain;charset=utf-8"));
    try t.expect(isMimeName("application/x.foo+json"));
    try t.expect(isMimeName("a/b"));

    try t.expect(!isMimeName("PNG"));
    try t.expect(!isMimeName("HTML Format"));
    try t.expect(!isMimeName("FileGroupDescriptorW"));
    try t.expect(!isMimeName("a/ b"));
    try t.expect(!isMimeName("a /b"));
    try t.expect(!isMimeName("/x"));
    try t.expect(!isMimeName("x/"));
    try t.expect(!isMimeName(""));
    try t.expect(!isMimeName("a/b/c"));
    try t.expect(!isMimeName("text/plain; charset=utf-8"));
    try t.expect(!isMimeName("image/p\xc3\xb1g"));
    try t.expect(!isMimeName("image/png\x00"));

    // Length limit: 255 bytes pass, 256 and 300 do not.
    var buf: [300]u8 = undefined;
    @memset(&buf, 'a');
    buf[1] = '/';
    try t.expect(isMimeName(buf[0..255]));
    try t.expect(!isMimeName(buf[0..256]));
    try t.expect(!isMimeName(buf[0..300]));
}

fn u16Lit(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "win32 clipboard mime: uri list" {
    const alloc = std.testing.allocator;

    // `C:\My Files\<Cyrillic zhe>.txt`, the non-ASCII letter built from a
    // code point so the source stays ASCII.
    const path = [_]u16{
        'C', ':', '\\', 'M', 'y', ' ', 'F', 'i', 'l', 'e', 's', '\\', 0x0436, '.', 't', 'x', 't',
    };
    {
        const got = try uriList(alloc, &.{&path});
        defer alloc.free(got);
        try std.testing.expectEqualStrings("file:///C:/My%20Files/%D0%B6.txt\r\n", got);
    }

    // UNC.
    {
        const got = try uriList(alloc, &.{u16Lit("\\\\srv\\share\\x")});
        defer alloc.free(got);
        try std.testing.expectEqualStrings("file://srv/share/x\r\n", got);
    }

    // Several paths, long-path prefixes, characters that need escaping.
    {
        const got = try uriList(alloc, &.{
            u16Lit("\\\\?\\C:\\a#b%c"),
            u16Lit("\\\\?\\UNC\\srv\\s\\x"),
            u16Lit(""),
            u16Lit("D:\\q"),
        });
        defer alloc.free(got);
        try std.testing.expectEqualStrings(
            "file:///C:/a%23b%25c\r\nfile://srv/s/x\r\nfile:///D:/q\r\n",
            got,
        );
    }

    // Surrogate pair: U+1F600 encodes as F0 9F 98 80.
    {
        const p = [_]u16{ 'C', ':', '\\', 0xD83D, 0xDE00 };
        const got = try uriList(alloc, &.{&p});
        defer alloc.free(got);
        try std.testing.expectEqualStrings("file:///C:/%F0%9F%98%80\r\n", got);
    }

    // A lone surrogate is refused, nothing leaks.
    {
        const p = [_]u16{ 'C', ':', '\\', 0xD83D };
        try std.testing.expectError(error.InvalidUtf16, uriList(alloc, &.{&p}));
    }

    // No paths: empty list.
    {
        const got = try uriList(alloc, &.{});
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
}
