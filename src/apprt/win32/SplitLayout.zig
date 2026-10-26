//! Pure split-tree layout: pane rectangles, dividers and drag ratios computed
//! from a core `SplitTree`. Integer pixels only; sizes of a split's children and
//! its gap always sum to the split's span exactly.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");

/// Layout of one `SplitTree` instantiation.
pub fn Layout(comptime Tree: type) type {
    return struct {
        const Self = @This();

        pub const Leaf = struct {
            handle: Tree.Node.Handle,
            view: *Tree.View,
            rect: geom.Rect,
            /// False for hidden (zoomed-out) leaves and leaves with an empty rect.
            visible: bool,
        };

        pub const Divider = struct {
            split: Tree.Node.Handle,
            layout: Tree.Split.Layout,
            /// The gap strip between the two children.
            rect: geom.Rect,
            /// The whole rectangle of the split, for drag ratio computation.
            span: geom.Rect,
        };

        leaves: []Leaf,
        dividers: []Divider,

        /// Lay out `tree` inside `bounds` with `gap` pixels between children.
        pub fn compute(
            alloc: Allocator,
            tree: *const Tree,
            bounds: geom.Rect,
            gap: i32,
        ) Allocator.Error!Self {
            var leaves: std.ArrayList(Leaf) = .empty;
            errdefer leaves.deinit(alloc);
            var dividers: std.ArrayList(Divider) = .empty;
            errdefer dividers.deinit(alloc);

            if (tree.nodes.len > 0) {
                if (tree.zoomed) |z| {
                    // Everything outside the zoomed node is hidden.
                    for (tree.nodes, 0..) |node, i| switch (node) {
                        .leaf => |view| try leaves.append(alloc, .{
                            .handle = @fromBackingInt(@intCast(i)),
                            .view = view,
                            .rect = .{},
                            .visible = false,
                        }),
                        .split => {},
                    };
                    var shown: std.ArrayList(Leaf) = .empty;
                    defer shown.deinit(alloc);
                    try walk(alloc, tree, z, bounds, @max(gap, 0), &shown, &dividers);
                    for (shown.items) |s| for (leaves.items) |*l| {
                        if (l.handle == s.handle) l.* = s;
                    };
                } else {
                    try walk(alloc, tree, .root, bounds, @max(gap, 0), &leaves, &dividers);
                }
            }

            const l = try leaves.toOwnedSlice(alloc);
            errdefer alloc.free(l);
            return .{ .leaves = l, .dividers = try dividers.toOwnedSlice(alloc) };
        }

        fn walk(
            alloc: Allocator,
            tree: *const Tree,
            at: Tree.Node.Handle,
            rect: geom.Rect,
            gap: i32,
            leaves: *std.ArrayList(Leaf),
            dividers: *std.ArrayList(Divider),
        ) Allocator.Error!void {
            switch (tree.nodes[at.idx()]) {
                .leaf => |view| try leaves.append(alloc, .{
                    .handle = at,
                    .view = view,
                    .rect = rect,
                    .visible = rect.w > 0 and rect.h > 0,
                }),
                .split => |s| {
                    const horizontal = s.layout == .horizontal;
                    const len = @max(if (horizontal) rect.w else rect.h, 0);
                    const g = @min(gap, len);
                    const avail = len - g;
                    const first = firstSize(avail, s.ratio);
                    const second = avail - first;

                    var a = rect;
                    var d = rect;
                    var b = rect;
                    if (horizontal) {
                        a.w = first;
                        d.x = rect.x + first;
                        d.w = g;
                        b.x = d.x + g;
                        b.w = second;
                    } else {
                        a.h = first;
                        d.y = rect.y + first;
                        d.h = g;
                        b.y = d.y + g;
                        b.h = second;
                    }

                    try dividers.append(alloc, .{
                        .split = at,
                        .layout = s.layout,
                        .rect = d,
                        .span = rect,
                    });
                    try walk(alloc, tree, s.left, a, gap, leaves, dividers);
                    try walk(alloc, tree, s.right, b, gap, leaves, dividers);
                },
            }
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.leaves);
            alloc.free(self.dividers);
            self.* = .{ .leaves = &.{}, .dividers = &.{} };
        }

        /// The leaf showing `view`, if any.
        pub fn leafFor(self: *const Self, view: *const Tree.View) ?Leaf {
            for (self.leaves) |l| {
                const same = if (@hasDecl(Tree.View, "eql"))
                    l.view.eql(view)
                else
                    l.view == view;
                if (same) return l;
            }
            return null;
        }

        /// Index of the divider whose gap strip, widened by `slop` pixels on
        /// both sides across its axis, contains the point. The widening is
        /// for hit testing only: it overlaps the panes.
        pub fn dividerAt(self: *const Self, x: i32, y: i32, slop: i32) ?usize {
            for (self.dividers, 0..) |d, i| {
                var r = d.rect;
                if (d.layout == .horizontal) {
                    r.x -= slop;
                    r.w += 2 * slop;
                } else {
                    r.y -= slop;
                    r.h += 2 * slop;
                }
                if (r.contains(x, y)) return i;
            }
            return null;
        }
    };
}

/// Size of the first child of a split with `avail` pixels left after the gap.
fn firstSize(avail: i32, ratio: f16) i32 {
    if (avail <= 0) return 0;
    const r: f32 = std.math.clamp(@as(f32, ratio), 0, 1);
    const px: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(avail)) * r));
    return std.math.clamp(px, 0, avail);
}

/// The split ratio for a divider dragged so its centre is at `pos` (x for
/// horizontal splits, y for vertical), keeping both sides at least `min_px`.
pub fn ratioForDrag(
    layout_kind: enum { horizontal, vertical },
    span: geom.Rect,
    gap: i32,
    pos: i32,
    min_px: i32,
) f16 {
    const len = if (layout_kind == .horizontal) span.w else span.h;
    const origin = if (layout_kind == .horizontal) span.x else span.y;
    const avail = len - gap;
    if (avail <= 0 or avail < 2 * min_px) return 0.5;
    const first = std.math.clamp(pos - origin - @divTrunc(gap, 2), min_px, avail - min_px);
    return @floatCast(@as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(avail)));
}

/// Ratio delta for a keybind resize of `amount` pixels, relative to the whole
/// split tree `bounds` (the unit `SplitTree.resize` expects).
pub fn resizeRatio(
    direction: enum { left, right, up, down },
    amount: u16,
    bounds: geom.Rect,
) f16 {
    const horizontal = direction == .left or direction == .right;
    const total: i32 = if (horizontal) bounds.w else bounds.h;
    if (total <= 0) return 0;
    const magnitude = @min(@as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(total)), 1);
    const signed: f32 = switch (direction) {
        .right, .down => magnitude,
        .left, .up => -magnitude,
    };
    return @floatCast(signed);
}

/// Divider thickness at `dpi`: 1 DIP like Ghostty on macOS, at least 1 px.
pub fn gapPx(dpi: u32) i32 {
    return @max(geom.scale(1, dpi), 1);
}

/// Invisible grab zone on each side of the divider: macOS has 6 DIP of
/// hit area around the 1 DIP line, so 3 DIP either side.
pub fn grabSlopPx(dpi: u32) i32 {
    return geom.scale(3, dpi);
}

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

const TestTree = @import("../../datastruct/split_tree.zig").SplitTree(TestView);
const TestLayout = Layout(TestTree);

fn rectsOverlap(a: geom.Rect, b: geom.Rect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
}

/// Build a tree of `n` leaves with ids 0..n-1 by splitting random leaves with
/// random directions and ratios.
fn buildTree(alloc: Allocator, rng: std.Random, n: u32, views: []TestView) !TestTree {
    var tree = try TestTree.init(alloc, &views[0]);
    errdefer tree.deinit();
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        var one = try TestTree.init(alloc, &views[i]);
        defer one.deinit();
        var leaves: [64]TestTree.Node.Handle = undefined;
        var count: usize = 0;
        for (tree.nodes, 0..) |node, idx| if (node == .leaf) {
            leaves[count] = @fromBackingInt(@intCast(idx));
            count += 1;
        };
        const at = leaves[rng.uintLessThan(usize, count)];
        const dir = rng.enumValue(TestTree.Split.Direction);
        const ratio: f16 = @floatCast(0.1 + 0.8 * rng.float(f32));
        const next = try tree.split(alloc, at, dir, ratio, &one);
        tree.deinit();
        tree = next;
    }
    return tree;
}

fn expectTiles(l: TestLayout, bounds: geom.Rect) !void {
    var area: i64 = 0;
    for (l.leaves) |leaf| {
        try std.testing.expect(leaf.rect.w >= 0 and leaf.rect.h >= 0);
        area += @as(i64, leaf.rect.w) * leaf.rect.h;
    }
    for (l.dividers) |d| {
        try std.testing.expect(d.rect.w >= 0 and d.rect.h >= 0);
        area += @as(i64, d.rect.w) * d.rect.h;
    }
    try std.testing.expectEqual(@as(i64, bounds.w) * bounds.h, area);

    for (l.leaves, 0..) |a, i| {
        try std.testing.expect(a.rect.x >= bounds.x and a.rect.right() <= bounds.right());
        try std.testing.expect(a.rect.y >= bounds.y and a.rect.bottom() <= bounds.bottom());
        for (l.leaves[i + 1 ..]) |b| try std.testing.expect(!rectsOverlap(a.rect, b.rect));
        for (l.dividers) |d| try std.testing.expect(!rectsOverlap(a.rect, d.rect));
    }
    for (l.dividers, 0..) |a, i| {
        for (l.dividers[i + 1 ..]) |b| try std.testing.expect(!rectsOverlap(a.rect, b.rect));
    }
}

test "win32 splitlayout: single leaf fills" {
    const alloc = std.testing.allocator;
    var v: TestView = .{ .id = 0 };
    var tree = try TestTree.init(alloc, &v);
    defer tree.deinit();

    const bounds: geom.Rect = .{ .x = 5, .y = 7, .w = 300, .h = 200 };
    var l = try TestLayout.compute(alloc, &tree, bounds, 4);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), l.leaves.len);
    try std.testing.expectEqual(@as(usize, 0), l.dividers.len);
    try std.testing.expectEqual(bounds, l.leaves[0].rect);
    try std.testing.expect(l.leaves[0].visible);
}

test "win32 splitlayout: horizontal 0.5 with gap 4 in 1001 px" {
    const alloc = std.testing.allocator;
    var v0: TestView = .{ .id = 0 };
    var v1: TestView = .{ .id = 1 };
    var t0 = try TestTree.init(alloc, &v0);
    defer t0.deinit();
    var t1 = try TestTree.init(alloc, &v1);
    defer t1.deinit();
    var tree = try t0.split(alloc, .root, .right, 0.5, &t1);
    defer tree.deinit();

    var l = try TestLayout.compute(alloc, &tree, .{ .w = 1001, .h = 600 }, 4);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), l.leaves.len);
    try std.testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 498, .h = 600 }, l.leaves[0].rect);
    try std.testing.expectEqual(geom.Rect{ .x = 498, .y = 0, .w = 4, .h = 600 }, l.dividers[0].rect);
    try std.testing.expectEqual(geom.Rect{ .x = 502, .y = 0, .w = 499, .h = 600 }, l.leaves[1].rect);
    try std.testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 1001, .h = 600 }, l.dividers[0].span);
}

test "win32 splitlayout: rounding sums to bounds for nested splits" {
    const alloc = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x9117);
    const rng = prng.random();

    var views: [16]TestView = undefined;
    for (&views, 0..) |*v, i| v.* = .{ .id = @intCast(i) };

    // Include the plan-review sizes: 16 panes in a 200x150 window.
    const sizes = [_]geom.Rect{
        .{ .w = 1001, .h = 777 },
        .{ .x = 3, .y = 9, .w = 640, .h = 480 },
        .{ .w = 200, .h = 150 },
    };
    for (sizes) |bounds| {
        for ([_]u32{ 4, 8, 16 }) |n| {
            var round: usize = 0;
            while (round < 25) : (round += 1) {
                var tree = try buildTree(alloc, rng, n, &views);
                defer tree.deinit();
                var l = try TestLayout.compute(alloc, &tree, bounds, 4);
                defer l.deinit(alloc);
                try std.testing.expectEqual(@as(usize, n), l.leaves.len);
                try std.testing.expectEqual(@as(usize, n - 1), l.dividers.len);
                try expectTiles(l, bounds);
            }
        }
    }
}

test "win32 splitlayout: tiny bounds produce no negative sizes" {
    const alloc = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x77);
    const rng = prng.random();
    var views: [8]TestView = undefined;
    for (&views, 0..) |*v, i| v.* = .{ .id = @intCast(i) };

    for ([_]geom.Rect{ .{ .w = 3, .h = 3 }, .{ .w = 0, .h = 0 }, .{ .w = 1, .h = 50 } }) |bounds| {
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            var tree = try buildTree(alloc, rng, 8, &views);
            defer tree.deinit();
            var l = try TestLayout.compute(alloc, &tree, bounds, 4);
            defer l.deinit(alloc);
            try expectTiles(l, bounds);
            for (l.leaves) |leaf| {
                if (leaf.rect.w == 0 or leaf.rect.h == 0) try std.testing.expect(!leaf.visible);
            }
        }
    }
}

test "win32 splitlayout: zoom hides siblings" {
    const alloc = std.testing.allocator;
    var v0: TestView = .{ .id = 0 };
    var v1: TestView = .{ .id = 1 };
    var t0 = try TestTree.init(alloc, &v0);
    defer t0.deinit();
    var t1 = try TestTree.init(alloc, &v1);
    defer t1.deinit();
    var tree = try t0.split(alloc, .root, .right, 0.5, &t1);
    defer tree.deinit();
    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |v| if (v.id == 1) tree.zoom(@fromBackingInt(@intCast(i))),
        .split => {},
    };
    try std.testing.expect(tree.zoomed != null);

    const bounds: geom.Rect = .{ .w = 800, .h = 600 };
    var l = try TestLayout.compute(alloc, &tree, bounds, 4);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), l.dividers.len);
    try std.testing.expectEqual(@as(usize, 2), l.leaves.len);
    try std.testing.expect(!l.leafFor(&v0).?.visible);
    try std.testing.expect(l.leafFor(&v1).?.visible);
    try std.testing.expectEqual(bounds, l.leafFor(&v1).?.rect);
}

test "win32 splitlayout: divider hit and drag ratio clamp" {
    const alloc = std.testing.allocator;
    var v0: TestView = .{ .id = 0 };
    var v1: TestView = .{ .id = 1 };
    var t0 = try TestTree.init(alloc, &v0);
    defer t0.deinit();
    var t1 = try TestTree.init(alloc, &v1);
    defer t1.deinit();
    var tree = try t0.split(alloc, .root, .right, 0.5, &t1);
    defer tree.deinit();

    var l = try TestLayout.compute(alloc, &tree, .{ .w = 1001, .h = 600 }, 4);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(?usize, 0), l.dividerAt(498, 10, 0));
    try std.testing.expectEqual(@as(?usize, 0), l.dividerAt(501, 599, 0));
    try std.testing.expectEqual(@as(?usize, null), l.dividerAt(497, 10, 0));
    try std.testing.expectEqual(@as(?usize, null), l.dividerAt(502, 10, 0));
    // The grab zone widens across the axis only.
    try std.testing.expectEqual(@as(?usize, 0), l.dividerAt(495, 10, 3));
    try std.testing.expectEqual(@as(?usize, 0), l.dividerAt(504, 10, 3));
    try std.testing.expectEqual(@as(?usize, null), l.dividerAt(494, 10, 3));
    try std.testing.expectEqual(@as(?usize, null), l.dividerAt(505, 10, 3));
    try std.testing.expectEqual(@as(?usize, null), l.dividerAt(500, 600, 3));

    const span = l.dividers[0].span;
    const avail: f32 = 997;
    const hi: f16 = @floatCast((avail - 50) / avail);
    const lo: f16 = @floatCast(50 / avail);
    try std.testing.expectEqual(hi, ratioForDrag(.horizontal, span, 4, 5000, 50));
    try std.testing.expectEqual(lo, ratioForDrag(.horizontal, span, 4, -5000, 50));
    // Divider centre at 500 gives first = 498 of 997.
    try std.testing.expectEqual(@as(f16, @floatCast(@as(f32, 498) / avail)), ratioForDrag(.horizontal, span, 4, 500, 50));
    // Too small to honour the minimum: centred.
    try std.testing.expectEqual(@as(f16, 0.5), ratioForDrag(.vertical, .{ .w = 10, .h = 90 }, 4, 0, 50));
}

test "win32 splitlayout: resizeRatio matches GTK" {
    const bounds: geom.Rect = .{ .w = 1000, .h = 500 };
    try std.testing.expectEqual(@as(f16, 0.1), resizeRatio(.right, 100, bounds));
    try std.testing.expectEqual(@as(f16, -0.1), resizeRatio(.left, 100, bounds));
    try std.testing.expectEqual(@as(f16, -0.1), resizeRatio(.up, 50, bounds));
    try std.testing.expectEqual(@as(f16, 0.1), resizeRatio(.down, 50, bounds));
    try std.testing.expectEqual(@as(f16, 1), resizeRatio(.down, 5000, bounds));
    try std.testing.expectEqual(@as(f16, -1), resizeRatio(.left, 5000, bounds));
    try std.testing.expectEqual(@as(f16, 0), resizeRatio(.left, 5, .{}));
}

test "win32 splitlayout: gapPx scales and never reaches zero" {
    try std.testing.expectEqual(@as(i32, 1), gapPx(96));
    try std.testing.expectEqual(@as(i32, 2), gapPx(168));
    try std.testing.expectEqual(@as(i32, 1), gapPx(1));
    try std.testing.expectEqual(@as(i32, 3), grabSlopPx(96));
    try std.testing.expectEqual(@as(i32, 5), grabSlopPx(168));
}
