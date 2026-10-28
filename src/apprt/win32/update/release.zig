//! Release feed parsing and version compare. Pure: no network, the caller
//! fetches and caps the body. Tags look like `win-<zon>-<N>` and the running
//! version like `<zon>-win.<N>`; releases are compared by N only, regardless
//! of the zon part, so the release process must keep N monotonic across zon
//! bumps (`1.3.2-win.5` -> `1.3.3-win.6`, not `.1`). A tag with N = u32 max
//! would silence all later announcements; only the repo owner can create it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows_version = @import("../../../build/windows_version.zig");

pub const release_prefix = "https://github.com/Denmurzik/ghostty/releases/tag/win-";
pub const endpoint = "https://api.github.com/repos/Denmurzik/ghostty/releases?per_page=20";

pub const Release = struct {
    n: u32,
    /// `<zon>-win.<N>`
    version: []const u8,
    tag: []const u8,
    html_url: []const u8,
};

pub const ParseError = error{ NotJson, NoRelease, OutOfMemory };

pub const Tag = struct { zon: []const u8, n: u32 };

/// `win-<zon>-<N>` -> zon and N.
pub fn parseTag(tag: []const u8) ?Tag {
    const rest = std.mem.cutPrefix(u8, tag, "win-") orelse return null;
    const dash = std.mem.lastIndexOfScalar(u8, rest, '-') orelse return null;
    if (dash == 0) return null;
    if (!safeZon(rest[0..dash])) return null;
    const digits = rest[dash + 1 ..];
    if (!windows_version.canonicalDigits(digits)) return null;
    const n = std.fmt.parseUnsigned(u16, digits, 10) catch return null;
    return .{ .zon = rest[0..dash], .n = n };
}

/// `[0-9A-Za-z.-]+`: nothing that could change a URL path, query or fragment.
fn safeZon(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether `url` is a release page of this fork: the fixed prefix and a tail
/// `[0-9A-Za-z.-]+-[0-9]+` (no `/`, `..` as a path step, `?`, `#`).
pub fn isReleaseUrl(url: []const u8) bool {
    const tail = std.mem.cutPrefix(u8, url, release_prefix) orelse return false;
    const dash = std.mem.lastIndexOfScalar(u8, tail, '-') orelse return false;
    if (!safeZon(tail[0..dash])) return false;
    return validN(tail[dash + 1 ..]);
}

/// Canonical digits with N <= 65535, the build's FILEVERSION limit.
fn validN(s: []const u8) bool {
    if (!windows_version.canonicalDigits(s)) return false;
    _ = std.fmt.parseUnsigned(u16, s, 10) catch return false;
    return true;
}

/// `<zon>-win.<N>` -> N. Null means a local build without a release number.
pub fn currentN(version: []const u8) ?u32 {
    return windows_version.winN(version);
}

/// Whether the zon part of a tag carries an rc/alpha/beta/pre marker after its
/// version core (`1.4.0-rc.1`). The permanent `-dev` of the zon is not one.
fn tipOnly(zon: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, zon, '-') orelse return false;
    var it = std.mem.tokenizeAny(u8, zon[dash + 1 ..], "-.");
    while (it.next()) |seg| {
        inline for (.{ "rc", "alpha", "beta", "pre" }) |m| {
            if (std.ascii.startsWithIgnoreCase(seg, m)) return true;
        }
    }
    return false;
}

/// The non-draft release with a valid tag and url and the highest N.
/// Every `win-` release is published as a GitHub pre-release, so that flag is
/// ignored: a `win-` tag counts as `stable`. With `stable_only`
/// (`auto-update-channel = stable`) only tags whose zon has an rc/alpha/beta/pre
/// marker are skipped; the `tip` channel counts them too.
pub fn newest(arena: Allocator, body: []const u8, stable_only: bool) ParseError!Release {
    if (nestingDepth(body) > max_depth) return error.NotJson;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (root != .array) return error.NotJson;

    var best: ?Release = null;
    for (root.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("draft")) |d| {
            if (d != .bool or d.bool) continue;
        }
        const tag = str(item.object.get("tag_name")) orelse continue;
        const url = str(item.object.get("html_url")) orelse continue;
        const parsed = parseTag(tag) orelse continue;
        if (stable_only and tipOnly(parsed.zon)) continue;
        if (!isReleaseUrl(url)) continue;
        if (!std.mem.eql(u8, url[release_prefix.len..], tag["win-".len..])) continue;
        if (best) |b| if (b.n >= parsed.n) continue;
        best = .{
            .n = parsed.n,
            .version = try std.fmt.allocPrint(arena, "{s}-win.{d}", .{ parsed.zon, parsed.n }),
            .tag = try arena.dupe(u8, tag),
            .html_url = try arena.dupe(u8, url),
        };
    }
    return best orelse error.NoRelease;
}

/// Maximum bracket nesting accepted before handing the body to std.json,
/// whose Value parse is recursive.
const max_depth = 32;

/// Deepest [ / { nesting outside of strings.
fn nestingDepth(body: []const u8) usize {
    var depth: usize = 0;
    var deepest: usize = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_str) {
            if (c == '\\') i += 1 else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[', '{' => {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return deepest;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

fn load(arena: Allocator, comptime name: []const u8) ParseError!Release {
    return newest(arena, @embedFile("testdata/" ++ name ++ ".json"), false);
}

test "win32 update: newer picks the highest N" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try load(arena.allocator(), "newer");
    try std.testing.expectEqual(@as(u32, 4), r.n);
    try std.testing.expectEqualStrings("1.3.2-dev-win.4", r.version);
    try std.testing.expectEqualStrings("win-1.3.2-dev-4", r.tag);
    try std.testing.expectEqualStrings(release_prefix ++ "1.3.2-dev-4", r.html_url);
}

test "win32 update: same and older still return the newest entry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 3), (try load(arena.allocator(), "same")).n);
    try std.testing.expectEqual(@as(u32, 2), (try load(arena.allocator(), "older")).n);
}

test "win32 update: prerelease counts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 7), (try load(arena.allocator(), "prerelease-newer")).n);
}

test "win32 update: draft-only and no-win-tags have no release" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NoRelease, load(arena.allocator(), "draft-only"));
    try std.testing.expectError(error.NoRelease, load(arena.allocator(), "no-win-tags"));
}

test "win32 update: bad tags are skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 2), (try load(arena.allocator(), "bad-tag")).n);
}

test "win32 update: foreign url is skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 2), (try load(arena.allocator(), "foreign-url")).n);
}

test "win32 update: html body is not json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotJson, load(arena.allocator(), "html"));
    try std.testing.expectError(error.NotJson, newest(arena.allocator(), "{}", false));
}

test "win32 update: currentN delegates" {
    _ = windows_version;
    try std.testing.expectEqual(@as(?u32, null), currentN("1.3.2-dev-win.07"));
}

test "win32 update: parseTag and currentN" {
    const t = parseTag("win-1.3.2-dev-3").?;
    try std.testing.expectEqualStrings("1.3.2-dev", t.zon);
    try std.testing.expectEqual(@as(u32, 3), t.n);
    try std.testing.expect(parseTag("v1.3.2") == null);
    try std.testing.expect(parseTag("win-x-y") == null);
    try std.testing.expect(parseTag("win--7") == null);
    try std.testing.expectEqual(@as(?u32, 3), currentN("1.3.2-dev-win.3"));
    try std.testing.expectEqual(@as(?u32, null), currentN("1.3.2-dev"));
    try std.testing.expectEqual(@as(?u32, null), currentN("1.3.2-dev-win.x"));
}

test "win32 update: parseTag is canonical" {
    try std.testing.expect(parseTag("win-1.3.2-dev-007") == null);
    try std.testing.expect(parseTag("win-1.3.2-dev-+5") == null);
    try std.testing.expect(parseTag("win-1.3.2-dev-") == null);
    try std.testing.expect(parseTag("win-1.3.2-dev-4294967296") == null);
    try std.testing.expectEqual(@as(u32, 0), parseTag("win-1.3.2-dev-0").?.n);
    try std.testing.expectEqual(@as(u32, 10), parseTag("win-1.3.2-dev-10").?.n);
}

test "win32 update: odd json types, duplicates, url mismatch, depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = release_prefix;
    // Odd types are skipped, not fatal.
    try std.testing.expectError(error.NoRelease, newest(a, "[]", false));
    try std.testing.expectError(error.NoRelease, newest(a, "[1,null,\"x\",[],{\"tag_name\":5,\"html_url\":[]}]", false));
    try std.testing.expectError(error.NoRelease, newest(a, "[{\"tag_name\":\"win-1.0-3\",\"html_url\":\"" ++ p ++ "1.0-3\",\"draft\":\"no\"}]", false));
    // Numeric, not lexicographic.
    const ten = "[{\"tag_name\":\"win-1.0-9\",\"html_url\":\"" ++ p ++ "1.0-9\"},{\"tag_name\":\"win-1.0-10\",\"html_url\":\"" ++ p ++ "1.0-10\"}]";
    try std.testing.expectEqual(@as(u32, 10), (try newest(a, ten, false)).n);
    // Duplicate N: the first entry in feed order wins.
    const dup = "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-5\"},{\"tag_name\":\"win-1.1-5\",\"html_url\":\"" ++ p ++ "1.1-5\"}]";
    try std.testing.expectEqualStrings("win-1.0-5", (try newest(a, dup, false)).tag);
    // url must match the tag.
    try std.testing.expectError(error.NoRelease, newest(a, "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-6\"}]", false));
    // Deep nesting is refused; brackets inside strings do not count.
    const deep = comptime brackets(100, "[") ++ brackets(100, "]");
    try std.testing.expectError(error.NotJson, newest(a, deep, false));
    const quoted = "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-5\",\"body\":\"" ++ comptime brackets(100, "[") ++ "\\\"[\"}]";
    try std.testing.expectEqual(@as(u32, 5), (try newest(a, quoted, false)).n);
}

fn brackets(comptime n: usize, comptime c: []const u8) *const [n]u8 {
    comptime {
        var buf: [n]u8 = undefined;
        @memset(&buf, c[0]);
        const out = buf;
        return &out;
    }
}

test "win32 update: release url tail is restricted" {
    const p = release_prefix;
    try std.testing.expect(isReleaseUrl(p ++ "1.3.2-dev-4"));
    try std.testing.expect(!isReleaseUrl(p ++ "x/../../../../attacker/repo-1"));
    try std.testing.expect(!isReleaseUrl(p ++ "1.3.2-dev-4?x=1"));
    try std.testing.expect(!isReleaseUrl(p ++ "1.3.2-dev-4#f"));
    try std.testing.expect(!isReleaseUrl(p ++ "1.3.2%2Fdev-4"));
    try std.testing.expect(!isReleaseUrl(p ++ "-4"));
    try std.testing.expect(!isReleaseUrl(p ++ "1.3.2-dev-04"));
    try std.testing.expect(!isReleaseUrl("https://evil.example/" ++ "1.3.2-dev-4"));
    try std.testing.expect(parseTag("win-x/../y-1") == null);
    try std.testing.expect(parseTag("win-1.0?a-1") == null);
}

test "win32 update: stable channel counts win- tags despite the pre-release flag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = @embedFile("testdata/prerelease-newer.json");
    try std.testing.expectEqual(@as(u32, 7), (try newest(arena.allocator(), body, false)).n);
    try std.testing.expectEqual(@as(u32, 7), (try newest(arena.allocator(), body, true)).n);
}

test "win32 update: stable skips rc tags, tip accepts them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\[{"tag_name":"win-1.4.0-rc.1-9","html_url":"https://github.com/Denmurzik/ghostty/releases/tag/win-1.4.0-rc.1-9","draft":false,"prerelease":true},
        \\ {"tag_name":"win-1.3.2-dev-8","html_url":"https://github.com/Denmurzik/ghostty/releases/tag/win-1.3.2-dev-8","draft":false,"prerelease":true}]
    ;
    try std.testing.expectEqual(@as(u32, 9), (try newest(a, body, false)).n);
    try std.testing.expectEqual(@as(u32, 8), (try newest(a, body, true)).n);
    try std.testing.expect(tipOnly("1.4.0-rc.1"));
    try std.testing.expect(tipOnly("1.4.0-beta2"));
    try std.testing.expect(!tipOnly("1.3.2-dev"));
    try std.testing.expect(!tipOnly("1.3.2"));
}

test "win32 update: N is capped at 65535 like the build" {
    try std.testing.expectEqual(@as(u32, 65535), parseTag("win-1.0-65535").?.n);
    try std.testing.expect(parseTag("win-1.0-65536") == null);
    try std.testing.expect(!isReleaseUrl(release_prefix ++ "1.0-65536"));
    try std.testing.expect(isReleaseUrl(release_prefix ++ "1.0-65535"));
}

// The std-only build helpers have no test root of their own.
test {
    _ = @import("../../../build/conpty_pins.zig");
}
