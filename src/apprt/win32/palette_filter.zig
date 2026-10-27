//! Fuzzy filter of the command palette entries: a case-insensitive
//! subsequence match of the query against the title and the description.
//!
//! Case is folded for ASCII only; every other byte (a UTF-8 sequence of
//! Cyrillic, say) is compared as it is, so "при" does not find "Привет"
//! while "Пр" does. The match is the leftmost subsequence, which is the one
//! the highlight of the title shows as well.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    title: []const u8,
    description: []const u8,
    /// Position in the caller's list; `filter` returns these.
    index: usize,
};

const base = 10;
const prefix_bonus = 15;
const word_start_bonus = 8;
const contiguous_bonus = 6;

fn fold(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn wordStart(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    return switch (text[i - 1]) {
        ' ', ':', '-', '_', '/', '.', '(', ')', '\t' => true,
        else => false,
    };
}

/// Marks the bytes of `text` the leftmost subsequence match of `query`
/// uses and returns the score. `mask` is `null` when only the score is
/// wanted, otherwise at least `text.len` long.
fn scan(query: []const u8, text: []const u8, mask: ?[]bool) ?u32 {
    if (mask) |m| @memset(m[0..text.len], false);
    var total: u32 = 0;
    var ti: usize = 0;
    var last: ?usize = null;
    for (query, 0..) |qc, qi| {
        const want = fold(qc);
        while (ti < text.len and fold(text[ti]) != want) ti += 1;
        if (ti >= text.len) return null;
        total += base;
        if (ti == 0 and qi == 0) total += prefix_bonus;
        if (wordStart(text, ti)) total += word_start_bonus;
        if (last) |l| if (l + 1 == ti) {
            total += contiguous_bonus;
        };
        if (mask) |m| m[ti] = true;
        last = ti;
        ti += 1;
    }
    return total;
}

/// The score of `query` in `text`, `null` when its bytes are not a
/// subsequence of `text`. An empty query matches everything with 0.
pub fn score(query: []const u8, text: []const u8) ?u32 {
    return scan(query, text, null);
}

/// Like `score`, and sets `mask[i]` for each byte of `text` that matched
/// (`mask` must hold `text.len` entries). Returns whether `text` matches.
pub fn matchMask(query: []const u8, text: []const u8, mask: []bool) bool {
    return scan(query, text, mask) != null;
}

fn entryScore(query: []const u8, e: Entry) ?u32 {
    const t = score(query, e.title);
    const d = score(query, e.description);
    if (t == null and d == null) return null;
    return (t orelse 0) * 2 + (d orelse 0);
}

/// The `index` of the entries that match, best first (title counts twice
/// the description); equal scores keep the order of `entries`. An empty
/// query keeps every entry in order. The caller frees the result.
pub fn filter(alloc: Allocator, query: []const u8, entries: []const Entry) ![]usize {
    const Scored = struct { score: u32, pos: usize };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);
    for (entries, 0..) |e, pos| {
        const s = entryScore(query, e) orelse continue;
        try scored.append(alloc, .{ .score = s, .pos = pos });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.pos < b.pos;
        }
    }.less);

    const out = try alloc.alloc(usize, scored.items.len);
    for (scored.items, out) |s, *o| o.* = entries[s.pos].index;
    return out;
}

test "win32 palette filter: subsequence and ranking" {
    const alloc = std.testing.allocator;
    const entries = [_]Entry{
        .{ .title = "Toggle Inspector", .description = "", .index = 0 },
        .{ .title = "New Split Right", .description = "", .index = 1 },
        .{ .title = "Close Tab", .description = "", .index = 2 },
    };

    const nsp = try filter(alloc, "nsp", &entries);
    defer alloc.free(nsp);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, nsp);

    const zz = try filter(alloc, "zz", &entries);
    defer alloc.free(zz);
    try std.testing.expectEqual(@as(usize, 0), zz.len);

    // An empty query keeps the order of the list.
    const all = try filter(alloc, "", &entries);
    defer alloc.free(all);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, all);

    // Ties are stable: both titles score the same.
    const same = [_]Entry{
        .{ .title = "Alpha", .description = "", .index = 7 },
        .{ .title = "Alpha", .description = "", .index = 3 },
        .{ .title = "Alpha", .description = "", .index = 5 },
    };
    const ties = try filter(alloc, "alp", &same);
    defer alloc.free(ties);
    try std.testing.expectEqualSlices(usize, &.{ 7, 3, 5 }, ties);

    // Case is ignored, a prefix beats a later match, a title match beats
    // the same match in the description.
    try std.testing.expect(score("SPL", "split").? == score("spl", "SPLIT").?);
    try std.testing.expect(score("spl", "Split Right").? > score("spl", "Focus Split").?);
    const desc = [_]Entry{
        .{ .title = "Other", .description = "split the terminal", .index = 0 },
        .{ .title = "Split Right", .description = "", .index = 1 },
    };
    const by_title = try filter(alloc, "split", &desc);
    defer alloc.free(by_title);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, by_title);
    // The description alone is enough to match.
    const by_desc = try filter(alloc, "terminal", &desc);
    defer alloc.free(by_desc);
    try std.testing.expectEqualSlices(usize, &.{0}, by_desc);
}

test "win32 palette filter: unicode case folding for ASCII only" {
    // Cyrillic is compared byte-wise: the same case matches, the other
    // does not (the UTF-8 bytes of "п" and "П" differ).
    try std.testing.expect(score("при", "привет") != null);
    try std.testing.expect(score("При", "Привет") != null);
    try std.testing.expect(score("при", "Привет") == null);
    try std.testing.expect(score("ПРИ", "привет") == null);
    // ASCII around it still folds.
    try std.testing.expect(score("a", "Привет A") != null);
}

test "win32 palette filter: match mask" {
    var mask: [11]bool = undefined;
    try std.testing.expect(matchMask("nsp", "New Split R", &mask));
    const want = [_]bool{ true, false, false, false, true, true, false, false, false, false, false };
    try std.testing.expectEqualSlices(bool, &want, &mask);
    try std.testing.expect(!matchMask("zz", "New Split R", &mask));
}
