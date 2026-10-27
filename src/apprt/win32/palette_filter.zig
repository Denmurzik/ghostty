//! Filter of the command palette entries, as `CommandOptionMatch` of the
//! macOS app does it: a query matches a text when it is a case-insensitive
//! substring of it, or else when it is made of the initials of the words of
//! the text ("nsr" finds "New Split Right"). An entry ranks by the field
//! that matched (title above description), and equally ranked entries keep
//! their order.
//!
//! Case is folded for ASCII only; every other byte (a UTF-8 sequence of
//! Cyrillic, say) is compared as it is, so "при" does not find "Привет"
//! while "Пр" does.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    title: []const u8,
    description: []const u8,
    /// Position in the caller's list; `filter` returns these.
    index: usize,
};

fn foldEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn cpLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

/// The first case-insensitive occurrence of `query` in `text`.
fn indexOfFold(text: []const u8, query: []const u8) ?usize {
    if (query.len > text.len) return null;
    var i: usize = 0;
    while (i + query.len <= text.len) : (i += 1) {
        if (foldEql(text[i..][0..query.len], query)) return i;
    }
    return null;
}

/// Marks the bytes of `text` that match `query` (the substring, else the
/// first character of each word the initials use). `mask` is `null` when
/// only the answer is wanted, otherwise at least `text.len` long. An empty
/// query matches nothing, as on macOS.
fn scan(query: []const u8, text: []const u8, mask: ?[]bool) bool {
    if (query.len == 0) return false;
    if (mask) |m| @memset(m[0..text.len], false);

    if (indexOfFold(text, query)) |at| {
        if (mask) |m| @memset(m[at..][0..query.len], true);
        return true;
    }

    // Initials: each word may take the next character of the query.
    var qi: usize = 0;
    var i: usize = 0;
    while (i < text.len and qi < query.len) {
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;
        const word_cp = @min(cpLen(text[i]), text.len - i);
        const query_cp = @min(cpLen(query[qi]), query.len - qi);
        if (word_cp == query_cp and foldEql(text[i..][0..word_cp], query[qi..][0..query_cp])) {
            if (mask) |m| @memset(m[i..][0..word_cp], true);
            qi += query_cp;
        }
        while (i < text.len and !isSpace(text[i])) i += 1;
    }
    return qi == query.len;
}

/// Whether `query` matches `text`.
pub fn matches(query: []const u8, text: []const u8) bool {
    return scan(query, text, null);
}

/// Like `matches`, and sets `mask[i]` for each byte of `text` the match
/// uses (`mask` must hold `text.len` entries).
pub fn matchMask(query: []const u8, text: []const u8, mask: []bool) bool {
    return scan(query, text, mask);
}

/// The rank of an entry: title 2, description 1, no match 0.
fn tier(query: []const u8, e: Entry) u8 {
    if (matches(query, e.title)) return 2;
    if (matches(query, e.description)) return 1;
    return 0;
}

/// The `index` of the entries that match, best tier first; entries of one
/// tier keep the order of `entries`. An empty query keeps every entry in
/// order. The caller frees the result.
pub fn filter(alloc: Allocator, query: []const u8, entries: []const Entry) ![]usize {
    if (query.len == 0) {
        const out = try alloc.alloc(usize, entries.len);
        for (entries, out) |e, *o| o.* = e.index;
        return out;
    }
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(alloc);
    for ([_]u8{ 2, 1 }) |want| {
        for (entries) |e| {
            if (tier(query, e) == want) try out.append(alloc, e.index);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "win32 palette filter: subsequence and ranking" {
    const alloc = std.testing.allocator;
    const entries = [_]Entry{
        .{ .title = "Toggle Inspector", .description = "", .index = 0 },
        .{ .title = "New Split Right", .description = "", .index = 1 },
        .{ .title = "Close Tab", .description = "", .index = 2 },
    };

    // Not a subsequence: "nsp" is the middle of "Inspector" only, the
    // letters of "New Split Right" do not count.
    const nsp = try filter(alloc, "nsp", &entries);
    defer alloc.free(nsp);
    try std.testing.expectEqualSlices(usize, &.{0}, nsp);
    const nsr = try filter(alloc, "nsr", &entries);
    defer alloc.free(nsr);
    try std.testing.expectEqualSlices(usize, &.{1}, nsr);
    const ti = try filter(alloc, "ti", &entries);
    defer alloc.free(ti);
    try std.testing.expectEqualSlices(usize, &.{0}, ti);

    // A substring, in any case, anywhere.
    const insp = try filter(alloc, "INSPEC", &entries);
    defer alloc.free(insp);
    try std.testing.expectEqualSlices(usize, &.{0}, insp);

    const zz = try filter(alloc, "zz", &entries);
    defer alloc.free(zz);
    try std.testing.expectEqual(@as(usize, 0), zz.len);

    // An empty query keeps the order of the list.
    const all = try filter(alloc, "", &entries);
    defer alloc.free(all);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, all);

    // A title match ranks above a description match whatever the position
    // in the text; equal ranks keep the order of the list.
    const mixed = [_]Entry{
        .{ .title = "Other", .description = "split the terminal", .index = 7 },
        .{ .title = "Focus Split: Right", .description = "", .index = 3 },
        .{ .title = "Split Right", .description = "", .index = 5 },
        .{ .title = "Third", .description = "a split too", .index = 1 },
    };
    const split = try filter(alloc, "split", &mixed);
    defer alloc.free(split);
    try std.testing.expectEqualSlices(usize, &.{ 3, 5, 7, 1 }, split);
    // The description alone is enough.
    const terminal = try filter(alloc, "terminal", &mixed);
    defer alloc.free(terminal);
    try std.testing.expectEqualSlices(usize, &.{7}, terminal);
    // Initials work on the description too.
    const stt = try filter(alloc, "stt", &mixed);
    defer alloc.free(stt);
    try std.testing.expectEqualSlices(usize, &.{7}, stt);
}

test "win32 palette filter: unicode case folding for ASCII only" {
    // Cyrillic is compared byte-wise: the same case matches, the other
    // does not (the UTF-8 bytes of "п" and "П" differ).
    try std.testing.expect(matches("при", "привет"));
    try std.testing.expect(matches("При", "Привет"));
    try std.testing.expect(!matches("при", "Привет"));
    try std.testing.expect(!matches("ПРИ", "привет"));
    // ASCII around it still folds.
    try std.testing.expect(matches("a", "Привет A"));
    // Initials compare whole characters.
    try std.testing.expect(matches("ну", "новая улица"));
    try std.testing.expect(!matches("Ну", "новая улица"));
    // An empty query matches nothing (the caller keeps all entries).
    try std.testing.expect(!matches("", "anything"));
}

test "win32 palette filter: match mask" {
    var mask: [15]bool = undefined;
    // The substring.
    try std.testing.expect(matchMask("SPLIT", "New Split Right", &mask));
    for (mask, 0..) |m, i| try std.testing.expectEqual(i >= 4 and i < 9, m);
    // The initials.
    try std.testing.expect(matchMask("nr", "New Split Right", &mask));
    for (mask, 0..) |m, i| try std.testing.expectEqual(i == 0 or i == 10, m);
    try std.testing.expect(!matchMask("nsp", "New Split Right", &mask));
}
