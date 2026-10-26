//! Decides what a link may do. Links come from terminal output, which any
//! program controls, so only web and mail URLs are handed to the shell;
//! local paths are revealed in Explorer, never executed.
const std = @import("std");

pub const max_len = 2048;

pub const Verdict = union(enum) {
    /// Hand the URL to the shell's "open" verb.
    open: []const u8,
    /// Select this local path in Explorer. Backslash form, written into the
    /// caller's buffer.
    reveal: []const u8,
    /// Do nothing; the string says why.
    refuse: []const u8,
};

/// `buf` holds the decoded path of a `reveal` verdict and must be at least
/// `max_len` bytes.
pub fn classify(buf: []u8, url: []const u8) Verdict {
    if (url.len == 0) return .{ .refuse = "empty" };
    if (url.len > max_len) return .{ .refuse = "too long" };
    for (url) |c| {
        if (c < 0x20 or c == 0x7f or c == '"') return .{ .refuse = "control or quote character" };
    }

    if (isDriveAbsolute(url)) return reveal(buf, url);
    if (url.len >= 2 and isSlash(url[0]) and isSlash(url[1])) return .{ .refuse = "UNC or device path" };

    const colon = schemeEnd(url) orelse return .{ .refuse = "relative path" };
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];

    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (!std.mem.startsWith(u8, rest, "//") or rest.len == 2 or rest[2] == '/') {
            return .{ .refuse = "web URL without host" };
        }
        return .{ .open = url };
    }
    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
        if (rest.len == 0) return .{ .refuse = "empty mailto" };
        return .{ .open = url };
    }
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return fileUrl(buf, rest);
    return .{ .refuse = "scheme not allowed" };
}

/// Index of the ':' ending a URL scheme of two or more characters, null if
/// the text has none (a single letter is a drive, not a scheme).
fn schemeEnd(url: []const u8) ?usize {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return null;
    for (url, 0..) |c, i| {
        if (c == ':') return if (i >= 2) i else null;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return null;
}

fn isSlash(c: u8) bool {
    return c == '/' or c == '\\';
}

fn isDriveAbsolute(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSlash(p[2]);
}

/// `file:///C:/x`, `file://localhost/C:/x`; a host that is not empty or
/// localhost is a network share.
fn fileUrl(buf: []u8, rest: []const u8) Verdict {
    if (!std.mem.startsWith(u8, rest, "//")) return .{ .refuse = "file URL without authority" };
    var path = rest[2..];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return .{ .refuse = "file URL without path" };
    const host = path[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) {
        return .{ .refuse = "file URL on a network host" };
    }
    path = path[slash + 1 ..];

    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        var c = path[i];
        if (c == '%') {
            if (i + 2 >= path.len) return .{ .refuse = "bad percent escape" };
            c = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch return .{ .refuse = "bad percent escape" };
            i += 2;
        }
        if (n == buf.len) return .{ .refuse = "too long" };
        buf[n] = c;
        n += 1;
    }
    const decoded = buf[0..n];
    // Decoding can produce what the raw check rejected.
    for (decoded) |c| {
        if (c < 0x20 or c == 0x7f or c == '"') return .{ .refuse = "control or quote character" };
    }
    if (!isDriveAbsolute(decoded)) return .{ .refuse = "file URL is not a local drive path" };
    return finishReveal(decoded);
}

fn reveal(buf: []u8, path: []const u8) Verdict {
    @memcpy(buf[0..path.len], path);
    return finishReveal(buf[0..path.len]);
}

/// Normalizes slashes in place and rejects names that address more than a
/// plain file: alternate streams, wildcards, device syntax.
fn finishReveal(path: []u8) Verdict {
    for (path[2..]) |c| {
        switch (c) {
            ':', '*', '?', '<', '>', '|' => return .{ .refuse = "unsafe character in path" },
            else => {},
        }
    }
    for (path) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return .{ .reveal = path };
}

fn expectOpen(url: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    const v = classify(&buf, url);
    try std.testing.expect(v == .open);
    try std.testing.expectEqualStrings(url, v.open);
}

fn expectReveal(url: []const u8, path: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    const v = classify(&buf, url);
    try std.testing.expect(v == .reveal);
    try std.testing.expectEqualStrings(path, v.reveal);
}

fn expectRefuse(url: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    const v = classify(&buf, url);
    try std.testing.expect(v == .refuse);
}

test "win32 link policy: web and mail URLs open" {
    try expectOpen("http://example.com");
    try expectOpen("HTTP://x");
    try expectOpen("https://example.com/a?b=c#d");
    try expectOpen("https://a/b.exe");
    try expectOpen("mailto:a@b.c");
    try expectOpen("MAILTO:a@b.c");
    try expectOpen("https://example.com/%2e%2e/%41");
}

test "win32 link policy: local paths only reveal" {
    try expectReveal("file:///C:/x/y.exe", "C:\\x\\y.exe");
    try expectReveal("file://localhost/C:/x/y.exe", "C:\\x\\y.exe");
    try expectReveal("FILE:///c:/My%20Dir/a.txt", "c:\\My Dir\\a.txt");
    try expectReveal("C:\\x\\y.bat", "C:\\x\\y.bat");
    try expectReveal("D:/x/y.lnk", "D:\\x\\y.lnk");
}

test "win32 link policy: network, device and odd paths are refused" {
    try expectRefuse("\\\\host\\s\\a.exe");
    try expectRefuse("//host/s/a.exe");
    try expectRefuse("\\\\?\\C:\\a");
    try expectRefuse("\\\\.\\C:\\a");
    try expectRefuse("file://host/share/a.exe");
    try expectRefuse("file:////host/share/a.exe");
    try expectRefuse("file:///%5C%5Chost%5Cshare%5Ca.exe");
    try expectRefuse("file:///C:/a%00b");
    try expectRefuse("file:///C:/a%22b");
    try expectRefuse("file:///C:/a%2");
    try expectRefuse("file:///C:/a%zz");
    try expectRefuse("file:///etc/passwd");
    try expectRefuse("file:relative");
    try expectRefuse("C:\\x\\y.txt:stream");
    try expectRefuse("C:\\x\\*.exe");
    try expectRefuse("C:foo.exe");
    try expectRefuse("calc.exe");
    try expectRefuse("..\\x.exe");
    try expectRefuse("~/x.sh");
}

test "win32 link policy: other schemes and junk are refused" {
    try expectRefuse("search-ms:query=a&crumb=location:\\\\host\\s");
    try expectRefuse("ms-settings:");
    try expectRefuse("javascript:alert(1)");
    try expectRefuse("ms-msdt:/id PCWDiagnostic");
    try expectRefuse("ftp://host/a.exe");
    try expectRefuse("http:");
    try expectRefuse("https:///x");
    try expectRefuse("mailto:");
    try expectRefuse("");
    try expectRefuse("https://a/\x00");
    try expectRefuse("https://a/\"b");
    try expectRefuse("https://a/\nb");
}

test "win32 link policy: very long input is refused" {
    var long: [max_len + 1]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..8], "https://");
    try expectRefuse(&long);
    try expectOpen(long[0..max_len]);
}
