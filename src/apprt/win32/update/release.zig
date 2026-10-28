//! Release feed parsing and version compare. Pure: no network, the caller
//! fetches and caps the body. Tags look like `win-<zon>-<N>` and the running
//! version like `<zon>-win.<N>`; releases are compared by N only, regardless
//! of the zon part, so the release process must keep N monotonic across zon
//! bumps (`1.3.2-win.5` -> `1.3.3-win.6`, not `.1`). A tag with N = u32 max
//! would silence all later announcements; only the repo owner can create it.
const std = @import("std");
const Allocator = std.mem.Allocator;

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
    const digits = rest[dash + 1 ..];
    if (!canonicalN(digits)) return null;
    const n = std.fmt.parseUnsigned(u32, digits, 10) catch return null;
    return .{ .zon = rest[0..dash], .n = n };
}

/// Digits only, no sign, no leading zero (except "0" itself).
fn canonicalN(s: []const u8) bool {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// `<zon>-win.<N>` -> N. Null means a local build without a release number.
pub fn currentN(version: []const u8) ?u32 {
    const i = std.mem.lastIndexOf(u8, version, "-win.") orelse return null;
    return std.fmt.parseUnsigned(u32, version[i + "-win.".len ..], 10) catch null;
}

/// The non-draft release with a valid tag and url and the highest N.
/// Pre-releases count.
pub fn newest(arena: Allocator, body: []const u8) ParseError!Release {
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
        if (!std.mem.startsWith(u8, url, release_prefix)) continue;
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
    return newest(arena, @embedFile("testdata/" ++ name ++ ".json"));
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
    try std.testing.expectError(error.NotJson, newest(arena.allocator(), "{}"));
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
    try std.testing.expectError(error.NoRelease, newest(a, "[]"));
    try std.testing.expectError(error.NoRelease, newest(a, "[1,null,\"x\",[],{\"tag_name\":5,\"html_url\":[]}]"));
    try std.testing.expectError(error.NoRelease, newest(a, "[{\"tag_name\":\"win-1.0-3\",\"html_url\":\"" ++ p ++ "1.0-3\",\"draft\":\"no\"}]"));
    // Numeric, not lexicographic.
    const ten = "[{\"tag_name\":\"win-1.0-9\",\"html_url\":\"" ++ p ++ "1.0-9\"},{\"tag_name\":\"win-1.0-10\",\"html_url\":\"" ++ p ++ "1.0-10\"}]";
    try std.testing.expectEqual(@as(u32, 10), (try newest(a, ten)).n);
    // Duplicate N: the first entry in feed order wins.
    const dup = "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-5\"},{\"tag_name\":\"win-1.1-5\",\"html_url\":\"" ++ p ++ "1.1-5\"}]";
    try std.testing.expectEqualStrings("win-1.0-5", (try newest(a, dup)).tag);
    // url must match the tag.
    try std.testing.expectError(error.NoRelease, newest(a, "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-6\"}]"));
    // Deep nesting is refused; brackets inside strings do not count.
    const deep = comptime brackets(100, "[") ++ brackets(100, "]");
    try std.testing.expectError(error.NotJson, newest(a, deep));
    const quoted = "[{\"tag_name\":\"win-1.0-5\",\"html_url\":\"" ++ p ++ "1.0-5\",\"body\":\"" ++ comptime brackets(100, "[") ++ "\\\"[\"}]";
    try std.testing.expectEqual(@as(u32, 5), (try newest(a, quoted)).n);
}

fn brackets(comptime n: usize, comptime c: []const u8) *const [n]u8 {
    comptime {
        var buf: [n]u8 = undefined;
        @memset(&buf, c[0]);
        const out = buf;
        return &out;
    }
}
