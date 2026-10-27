//! tmux layout strings and select-layout (owner: M4 task 5).
//!
//! Pure functions over a generic `SplitTree` instantiation: the main-vertical
//! and tiled layouts, and the ratio arithmetic for split-window -l and
//! resize-pane -x/-y.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../../../tmux_shim/cli.zig");

/// Root horizontal split: the leader on the left with `leader_share` of the
/// width, `others` stacked top to bottom on the right with equal heights.
pub fn mainVertical(
    comptime Tree: type,
    gpa: Allocator,
    leader: *Tree.View,
    others: []const *Tree.View,
    leader_share: f16,
) !Tree {
    var lead = try Tree.init(gpa, leader);
    errdefer lead.deinit();
    if (others.len == 0) return lead;

    var stack = try chainViews(Tree, gpa, others, .down);
    defer stack.deinit();
    const result = try lead.split(gpa, .root, .right, leader_share, &stack);
    lead.deinit();
    return result;
}

/// Grid of `ceil(sqrt(n))` columns; rows are equal height and the panes of a
/// row are equal width. `views` fill the grid in row-major order.
pub fn tiled(comptime Tree: type, gpa: Allocator, views: []const *Tree.View) !Tree {
    std.debug.assert(views.len > 0);
    const n = views.len;
    const cols = ceilSqrt(n);
    const rows = (n + cols - 1) / cols;

    const row_trees = try gpa.alloc(Tree, rows);
    defer gpa.free(row_trees);
    var built: usize = 0;
    errdefer for (row_trees[0..built]) |*t| t.deinit();
    for (0..rows) |r| {
        const start = r * cols;
        const end = @min(start + cols, n);
        row_trees[r] = try chainViews(Tree, gpa, views[start..end], .right);
        built += 1;
    }
    built = 0; // chainTrees owns the rows from here
    return chainTrees(Tree, gpa, row_trees, .down);
}

fn ceilSqrt(n: usize) usize {
    var c: usize = 1;
    while (c * c < n) c += 1;
    return c;
}

/// One tree holding `views` in order, split `dir` with equal shares.
fn chainViews(
    comptime Tree: type,
    gpa: Allocator,
    views: []const *Tree.View,
    dir: Tree.Split.Direction,
) !Tree {
    const items = try gpa.alloc(Tree, views.len);
    defer gpa.free(items);
    var built: usize = 0;
    errdefer for (items[0..built]) |*t| t.deinit();
    for (views, 0..) |v, i| {
        items[i] = try Tree.init(gpa, v);
        built += 1;
    }
    built = 0;
    return chainTrees(Tree, gpa, items, dir);
}

/// Combine `items` into one tree, equal shares along `dir` (`.right` or
/// `.down`), built bottom-up with chain ratios 1/k. Takes ownership of every
/// item (all are deinitialised, also on error).
fn chainTrees(
    comptime Tree: type,
    gpa: Allocator,
    items: []Tree,
    dir: Tree.Split.Direction,
) !Tree {
    std.debug.assert(items.len > 0);
    var acc = items[items.len - 1];
    var i = items.len - 1;
    while (i > 0) {
        i -= 1;
        const k: f32 = @floatFromInt(items.len - i);
        const next = items[i].split(gpa, .root, dir, @floatCast(1.0 / k), &acc) catch |err| {
            acc.deinit();
            for (items[0 .. i + 1]) |*t| t.deinit();
            return err;
        };
        items[i].deinit();
        acc.deinit();
        acc = next;
    }
    return acc;
}

/// The nearest ancestor split of `at` with the given layout, and whether
/// `at` lies in its first (left/top) child.
pub fn ancestorSplit(
    comptime Tree: type,
    tree: *const Tree,
    at: Tree.Node.Handle,
    layout: Tree.Split.Layout,
) ?struct { split: Tree.Node.Handle, pane_first: bool } {
    var cur = at;
    while (cur != .root) {
        var parent: ?Tree.Node.Handle = null;
        for (tree.nodes, 0..) |node, i| switch (node) {
            .split => |s| if (s.left == cur or s.right == cur) {
                parent = @fromBackingInt(@intCast(i));
                break;
            },
            .leaf => {},
        };
        const p = parent orelse return null;
        const s = tree.nodes[p.idx()].split;
        if (s.layout == layout) return .{ .split = p, .pane_first = s.left == cur };
        cur = p;
    }
    return null;
}

/// resize-pane -x/-y: `size` is the wanted pane size (percent of
/// `window_px`, or cells). Returns the left/top share of the split's
/// `span_px`, or null when it falls outside (0, 1).
pub fn ratioFor(
    size: cli.Size,
    window_px: i32,
    span_px: i32,
    cell_px: u32,
    pane_first: bool,
) ?f16 {
    if (span_px <= 0) return null;
    const target: f32 = switch (size) {
        .percent => |p| @as(f32, @floatFromInt(window_px)) * @as(f32, @floatFromInt(p)) / 100.0,
        .cells => |c| @as(f32, @floatFromInt(c)) * @as(f32, @floatFromInt(cell_px)),
    };
    return shareToRatio(target / @as(f32, @floatFromInt(span_px)), pane_first);
}

/// split-window -l: `size` is the size of the NEW pane within the split's
/// span; null size is an even split. Returns the left/top share.
pub fn newPaneRatio(size: ?cli.Size, span_px: i32, cell_px: u32, new_first: bool) ?f16 {
    const s = size orelse return 0.5;
    return ratioFor(s, span_px, span_px, cell_px, new_first);
}

/// Both sides keep at least `min_px` after splitting `span_px` at `ratio`
/// with a `gap_px` divider.
pub fn fits(span_px: i32, ratio: f16, gap_px: i32, min_px: i32) bool {
    const avail = span_px - gap_px;
    if (avail < 2 * min_px) return false;
    const first: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(avail)) * @as(f32, ratio)));
    return first >= min_px and avail - first >= min_px;
}

/// `share` is the pane's fraction of the span; the result is the
/// left/top fraction.
fn shareToRatio(share: f32, pane_first: bool) ?f16 {
    if (!(share > 0 and share < 1)) return null;
    const r: f32 = if (pane_first) share else 1.0 - share;
    return @floatCast(r);
}

const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const SplitLayout = @import("../SplitLayout.zig");
const geom = @import("../geom.zig");

const TestView = struct {
    id: u32,

    pub fn ref(self: *TestView, alloc: Allocator) Allocator.Error!*TestView {
        const ptr = try alloc.create(TestView);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *TestView, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn eql(self: *const TestView, other: *const TestView) bool {
        return self.id == other.id;
    }
};
const TestTree = SplitTree(TestView);
const TestLayout = SplitLayout.Layout(TestTree);

fn rectOf(l: TestLayout, id: u32) geom.Rect {
    for (l.leaves) |leaf| if (leaf.view.id == id) return leaf.rect;
    unreachable;
}

test "win32 tmux layout: main-vertical leader 30% and equal stack" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v = [_]TestView{ .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
    const others = [_]*TestView{ &v[1], &v[2], &v[3] };
    var tree = try mainVertical(TestTree, alloc, &v[0], &others, 0.3);
    defer tree.deinit();

    var l = try TestLayout.compute(alloc, &tree, .{ .x = 0, .y = 0, .w = 1000, .h = 600 }, 4);
    defer l.deinit(alloc);
    const lead = rectOf(l, 0);
    const want: f32 = 0.3 * (1000 - 4);
    try testing.expect(@abs(@as(f32, @floatFromInt(lead.w)) - want) <= 1);
    const h1 = rectOf(l, 1).h;
    const h2 = rectOf(l, 2).h;
    const h3 = rectOf(l, 3).h;
    try testing.expect(@abs(h1 - h2) <= 1);
    try testing.expect(@abs(h2 - h3) <= 1);
    try testing.expect(rectOf(l, 1).y < rectOf(l, 2).y and rectOf(l, 2).y < rectOf(l, 3).y);
    try testing.expectEqual(lead.w + 4, rectOf(l, 1).x);
}

test "win32 tmux layout: tiled 5 panes is 3+2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v: [5]TestView = undefined;
    var ptrs: [5]*TestView = undefined;
    for (&v, &ptrs, 0..) |*x, *p, i| {
        x.* = .{ .id = @intCast(i) };
        p.* = x;
    }
    var tree = try tiled(TestTree, alloc, &ptrs);
    defer tree.deinit();

    var l = try TestLayout.compute(alloc, &tree, .{ .x = 0, .y = 0, .w = 900, .h = 600 }, 0);
    defer l.deinit(alloc);
    // Row 0: ids 0..2 equal thirds; row 1: ids 3..4 halves (f16 ratios, so +-2 px).
    for (0..3) |i| {
        const r = rectOf(l, @intCast(i));
        try testing.expectEqual(@as(i32, 0), r.y);
        try testing.expect(@abs(r.w - 300) <= 2);
        try testing.expectEqual(@as(i32, 300), r.h);
    }
    for (3..5) |i| {
        const r = rectOf(l, @intCast(i));
        try testing.expectEqual(@as(i32, 300), r.y);
        try testing.expect(@abs(r.w - 450) <= 2);
    }
    try testing.expect(rectOf(l, 0).x < rectOf(l, 1).x and rectOf(l, 1).x < rectOf(l, 2).x);
}

test "win32 tmux layout: new pane 70% to the right" {
    const r = newPaneRatio(.{ .percent = 70 }, 1000, 10, false).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), @as(f32, r), 0.001);
    try std.testing.expectEqual(@as(f16, 0.5), newPaneRatio(null, 1000, 10, false).?);
    try std.testing.expect(newPaneRatio(.{ .percent = 100 }, 1000, 10, false) == null);
}

test "win32 tmux layout: resize -x 30% on the right child" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v = [_]TestView{ .{ .id = 0 }, .{ .id = 1 } };
    var a = try TestTree.init(alloc, &v[0]);
    defer a.deinit();
    var b = try TestTree.init(alloc, &v[1]);
    defer b.deinit();
    var tree = try a.split(alloc, .root, .right, 0.5, &b);
    defer tree.deinit();

    const at: TestTree.Node.Handle = for (tree.nodes, 0..) |n, i| {
        if (n == .leaf and n.leaf.id == 1) break @fromBackingInt(@intCast(i));
    } else unreachable;
    const anc = ancestorSplit(TestTree, &tree, at, .horizontal).?;
    try testing.expectEqual(TestTree.Node.Handle.root, anc.split);
    try testing.expect(!anc.pane_first);
    try testing.expect(ancestorSplit(TestTree, &tree, at, .vertical) == null);

    const r = ratioFor(.{ .percent = 30 }, 1000, 1000, 10, anc.pane_first).?;
    try testing.expectApproxEqAbs(@as(f32, 0.7), @as(f32, r), 0.001);
    const rc = ratioFor(.{ .cells = 20 }, 1000, 1000, 10, true).?;
    try testing.expectApproxEqAbs(@as(f32, 0.2), @as(f32, rc), 0.001);
}

test "win32 tmux layout: fits refuses below two cells" {
    const testing = std.testing;
    try testing.expect(fits(1000, 0.5, 4, 20));
    try testing.expect(!fits(100, 0.1, 4, 20));
    try testing.expect(!fits(30, 0.5, 4, 20));
}
