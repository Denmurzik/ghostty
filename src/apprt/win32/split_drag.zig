//! Split drag-and-drop, the pure part: drop zones, the drag state machine and
//! the "tree after move" helpers. Nothing here touches a window; the driver
//! (`split_drag_input.zig`) resolves what lies under the pointer, feeds the
//! events (screen px) and applies the returned feedback.
//!
//! Drop zones follow macOS `TerminalSplitDropZone.calculate`
//! (`TerminalSplitTreeView.swift:205-221`): the nearest edge of the target
//! pane, ties resolved left, right, top, bottom. The tree helpers follow the
//! GTK order (`class/split_tree.zig` `moveSplit`): split at the target first,
//! then remove the source by its old handle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const tab_drag = @import("tab_drag.zig");

pub const Point = tab_drag.Point;

/// Side of the target pane the dropped split lands on.
pub const Zone = enum { left, right, top, bottom };

/// Nearest edge of `pane` for the point (any coordinate space as `pane`).
/// The diagonals divide the pane into four triangles; the centre and the
/// diagonals resolve left, right, top, bottom. Relative distances in f64,
/// like the Swift original.
pub fn zoneAt(x: i32, y: i32, pane: geom.Rect) Zone {
    const w: f64 = @floatFromInt(@max(pane.w, 1));
    const h: f64 = @floatFromInt(@max(pane.h, 1));
    const rel_x = @as(f64, @floatFromInt(x - pane.x)) / w;
    const rel_y = @as(f64, @floatFromInt(y - pane.y)) / h;

    const to_left = rel_x;
    const to_right = 1 - rel_x;
    const to_top = rel_y;
    const to_bottom = 1 - rel_y;

    const min_dist = @min(@min(to_left, to_right), @min(to_top, to_bottom));
    if (min_dist == to_left) return .left;
    if (min_dist == to_right) return .right;
    if (min_dist == to_top) return .top;
    return .bottom;
}

/// The half of `pane` on the zone side (the highlight). With an odd size the
/// left and top halves are rounded down, so the right and bottom halves keep
/// the odd pixel and the two halves of a pane never overlap.
pub fn zoneRect(pane: geom.Rect, zone: Zone) geom.Rect {
    const half_w = @divFloor(pane.w, 2);
    const half_h = @divFloor(pane.h, 2);
    return switch (zone) {
        .left => .{ .x = pane.x, .y = pane.y, .w = half_w, .h = pane.h },
        .right => .{ .x = pane.x + half_w, .y = pane.y, .w = pane.w - half_w, .h = pane.h },
        .top => .{ .x = pane.x, .y = pane.y, .w = pane.w, .h = half_h },
        .bottom => .{ .x = pane.x, .y = pane.y + half_h, .w = pane.w, .h = pane.h - half_h },
    };
}

/// Split direction of the drop zone, not tied to one tree type.
pub const Direction = enum { left, right, down, up };

/// The direction a split dropped on `zone` is inserted in (top -> up,
/// bottom -> down).
pub fn direction(zone: Zone) Direction {
    return switch (zone) {
        .left => .left,
        .right => .right,
        .top => .up,
        .bottom => .down,
    };
}

/// `direction` as the `Split.Direction` of one `SplitTree` instantiation.
pub fn treeDirection(comptime Tree: type, zone: Zone) Tree.Split.Direction {
    return switch (zone) {
        .left => .left,
        .right => .right,
        .top => .up,
        .bottom => .down,
    };
}

/// What lies under the pointer, resolved by the driver.
pub const Hit = union(enum) {
    /// Outside every window of the app (desktop, other apps).
    outside,
    /// Over an app window but not on a target: title bar, quick terminal,
    /// chrome buttons, a hidden or parked window.
    blocked,
    /// A pane of the shown layout; `rect` is its rectangle in screen px.
    pane: struct { window: u32, tab: u32, surface: u32, zone: Zone, rect: geom.Rect },
    /// A tab strip: `slot` is the insertion index, `over` the tab chip under
    /// the pointer (spring-loading), if any.
    strip: struct { window: u32, slot: usize, over: ?usize },
};

pub const Event = union(enum) {
    move: struct { pt: Point, hit: Hit },
    /// The spring timer ran out.
    spring_fired,
    release,
    /// Esc or lost capture.
    cancel,
};

/// The dragged split.
pub const Source = struct {
    window: u32,
    tab: u32,
    surface: u32,
    /// The source tab has more than one visible leaf.
    tab_split: bool,
    /// The source window has more than one tab.
    window_tabs: usize,
    /// Where the press landed inside the pane, in source px: the point of
    /// the pane that stays under the pointer in a new window.
    grab: Point = .{ .x = 0, .y = 0 },
};

pub const Outcome = union(enum) {
    /// A click on the handle, or a release on an invalid target.
    none,
    cancelled,
    to_pane: struct { window: u32, tab: u32, surface: u32, zone: Zone },
    new_tab: struct { window: u32, index: usize },
    /// Top-left of the new window's pane area: pointer - grab (screen px).
    new_window: Point,
};

pub const Feedback = struct {
    /// Top-left of the ghost (pointer - ghost / 2).
    ghost: ?Point = null,
    /// Highlight of the drop zone, in screen px.
    zone: ?struct { window: u32, surface: u32, rect: geom.Rect } = null,
    /// Strip insertion marker.
    marker: ?struct { window: u32, index: usize } = null,
    /// Start (or restart) the spring timer for this tab.
    spring: ?struct { window: u32, index: usize } = null,
    /// Kill the spring timer.
    spring_cancel: bool = false,
    /// Switch `window` to tab `index` now (the spring fired).
    select: ?struct { window: u32, index: usize } = null,
    done: ?Outcome = null,
};

/// Valid targets: a pane that is not the source; a pane of the source tab is
/// only valid if that tab is split.
pub fn paneValid(src: Source, hit: Hit) bool {
    const p = switch (hit) {
        .pane => |p| p,
        else => return false,
    };
    if (p.surface == src.surface) return false;
    if (p.window == src.window and p.tab == src.tab and !src.tab_split) return false;
    return true;
}

/// Outcome of a release outside every window: a new window if the source tab
/// is split or its window has other tabs (a lone pane of a lone tab stays),
/// positioned so that the grab point stays under the pointer.
pub fn outsideOutcome(src: Source, pt: Point, grab: Point) Outcome {
    if (!src.tab_split and src.window_tabs <= 1) return .none;
    return .{ .new_window = .{ .x = pt.x - grab.x, .y = pt.y - grab.y } };
}

/// Outer origin of a new window so that the grabbed point stays under the
/// pointer. `grab` is the press position inside the pane and `offset` the
/// pane's offset inside the window (caption and strip), both in source px;
/// they are scaled when the window lands on a monitor with another DPI (the
/// same correction as the tab tear-off).
pub fn newWindowOrigin(pointer: Point, grab: Point, offset: Point, src_dpi: u32, dst_dpi: u32) Point {
    if (src_dpi == 0 or src_dpi == dst_dpi) {
        return .{ .x = pointer.x - grab.x - offset.x, .y = pointer.y - grab.y - offset.y };
    }
    const scale = @as(f64, @floatFromInt(dst_dpi)) / @as(f64, @floatFromInt(src_dpi));
    const dx: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(grab.x + offset.x)) * scale));
    const dy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(grab.y + offset.y)) * scale));
    return .{ .x = pointer.x - dx, .y = pointer.y - dy };
}

const State = enum { pressed, dragging, finished };

pub const Machine = struct {
    src: Source,
    press: Point,
    ghost: geom.Size,
    threshold: i32,
    state: State = .pressed,
    last_pt: Point,
    last_hit: Hit = .blocked,
    /// The chip the spring timer is armed for (or already fired for).
    spring: ?struct { window: u32, index: usize } = null,
    spring_done: bool = false,

    pub fn begin(src: Source, press: Point, ghost: geom.Size, threshold: i32) Machine {
        return .{
            .src = src,
            .press = press,
            .ghost = ghost,
            .threshold = threshold,
            .last_pt = press,
        };
    }

    pub fn feed(self: *Machine, ev: Event) Feedback {
        if (self.state == .finished) return .{};
        switch (ev) {
            .cancel => {
                self.state = .finished;
                return .{ .spring_cancel = self.takeSpring(), .done = .cancelled };
            },
            .release => return self.release(),
            .spring_fired => return self.fire(),
            .move => |mv| {
                self.last_pt = mv.pt;
                self.last_hit = mv.hit;
                return self.move(mv.pt, mv.hit);
            },
        }
    }

    fn move(self: *Machine, pt: Point, hit: Hit) Feedback {
        if (self.state == .pressed) {
            const dx: i64 = pt.x - self.press.x;
            const dy: i64 = pt.y - self.press.y;
            const t: i64 = self.threshold;
            if (dx * dx + dy * dy <= t * t) return .{};
            self.state = .dragging;
        }

        var fb: Feedback = .{
            .ghost = .{ .x = pt.x - @divFloor(self.ghost.w, 2), .y = pt.y - @divFloor(self.ghost.h, 2) },
        };
        switch (hit) {
            .pane => |p| if (paneValid(self.src, hit)) {
                fb.zone = .{ .window = p.window, .surface = p.surface, .rect = zoneRect(p.rect, p.zone) };
            },
            .strip => |s| fb.marker = .{ .window = s.window, .index = s.slot },
            .outside, .blocked => {},
        }

        // Spring-load: armed when the pointer settles on another chip,
        // cancelled when it leaves the chips.
        const chip: ?struct { window: u32, index: usize } = switch (hit) {
            .strip => |s| if (s.over) |i| .{ .window = s.window, .index = i } else null,
            else => null,
        };
        if (chip) |c| {
            const same = if (self.spring) |a| a.window == c.window and a.index == c.index else false;
            if (!same) {
                self.spring = .{ .window = c.window, .index = c.index };
                self.spring_done = false;
                fb.spring = .{ .window = c.window, .index = c.index };
            }
        } else if (self.spring != null) {
            fb.spring_cancel = self.takeSpring();
        }
        return fb;
    }

    /// Clears the armed spring; returns whether a timer may still be running.
    fn takeSpring(self: *Machine) bool {
        const armed = self.spring != null and !self.spring_done;
        self.spring = null;
        self.spring_done = false;
        return armed;
    }

    fn fire(self: *Machine) Feedback {
        const armed = self.spring orelse return .{ .spring_cancel = true };
        const over_same = switch (self.last_hit) {
            .strip => |s| s.window == armed.window and s.over != null and s.over.? == armed.index,
            else => false,
        };
        if (self.state != .dragging or self.spring_done or !over_same) {
            return .{ .spring_cancel = true };
        }
        self.spring_done = true;
        // The timer has done its job; the driver kills it with `select`.
        return .{ .select = .{ .window = armed.window, .index = armed.index }, .spring_cancel = true };
    }

    fn release(self: *Machine) Feedback {
        const prev = self.state;
        self.state = .finished;
        const spring = self.takeSpring();
        const outcome: Outcome = switch (prev) {
            .pressed => .none,
            .dragging => switch (self.last_hit) {
                .pane => |p| if (paneValid(self.src, self.last_hit))
                    .{ .to_pane = .{ .window = p.window, .tab = p.tab, .surface = p.surface, .zone = p.zone } }
                else
                    .none,
                .strip => |s| .{ .new_tab = .{ .window = s.window, .index = s.slot } },
                .outside => outsideOutcome(self.src, self.last_pt, self.src.grab),
                .blocked => .none,
            },
            .finished => unreachable,
        };
        return .{ .spring_cancel = spring, .done = outcome };
    }
};

pub const MoveError = Allocator.Error || error{ SameView, ViewNotFound };

/// The tree after a same-tree move: split at `dst` with a copy of `src`
/// (ratio 0.5), then remove the old leaf of `src` by its handle, which
/// `split` keeps valid. Zoom is reset by `split`. `tree` is not modified and
/// the result holds its own view refs; on error nothing changed. `dir` is a
/// `Direction` or the tree's `Split.Direction`.
pub fn moveWithin(
    comptime Tree: type,
    gpa: Allocator,
    tree: *const Tree,
    src: *Tree.View,
    dst: *Tree.View,
    dir: anytype,
) MoveError!Tree {
    if (src == dst) return error.SameView;
    const src_at = tree.locate(src) orelse return error.ViewNotFound;
    const dst_at = tree.locate(dst) orelse return error.ViewNotFound;

    var single = try Tree.init(gpa, src);
    defer single.deinit();
    var split = try tree.split(gpa, dst_at, asTreeDirection(Tree, dir), 0.5, &single);
    defer split.deinit();
    return try split.remove(gpa, src_at);
}

/// `dst_tree` with `src` inserted next to `dst` (ratio 0.5): step one of a
/// cross-tree move. Neither input is modified; on error nothing changed.
pub fn insertInto(
    comptime Tree: type,
    gpa: Allocator,
    dst_tree: *const Tree,
    src: *Tree.View,
    dst: *Tree.View,
    dir: anytype,
) MoveError!Tree {
    if (src == dst) return error.SameView;
    const dst_at = dst_tree.locate(dst) orelse return error.ViewNotFound;

    var single = try Tree.init(gpa, src);
    defer single.deinit();
    return try dst_tree.split(gpa, dst_at, asTreeDirection(Tree, dir), 0.5, &single);
}

fn asTreeDirection(comptime Tree: type, dir: anytype) Tree.Split.Direction {
    const T = @TypeOf(dir);
    if (T == Tree.Split.Direction) return dir;
    if (T == Direction) return switch (dir) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
    if (T == Zone) return treeDirection(Tree, dir);
    @compileError("direction must be a split_drag.Direction, Zone or Tree.Split.Direction");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

/// A view with an intrusive reference count: `ref` hands out the same
/// pointer, so `locate` finds views by identity and leaks show as counts.
const RcView = struct {
    label: []const u8,
    refs: u32 = 1,

    pub fn ref(self: *RcView) *RcView {
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *RcView) void {
        self.refs -= 1;
    }

    pub fn splitTreeLabel(self: *const RcView) []const u8 {
        return self.label;
    }
};

const RcTree = SplitTree(RcView);

fn treeText(tree: RcTree) ![]u8 {
    return testing.allocator.print("{f}", .{std.fmt.alt(tree, .formatText)});
}

fn expectTree(tree: RcTree, want: []const u8) !void {
    const got = try treeText(tree);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const pane100: geom.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };

test "win32 split drag: zone triangles" {
    // The centre is a tie of everything: left wins.
    try testing.expectEqual(Zone.left, zoneAt(50, 50, pane100));
    // Near each edge.
    try testing.expectEqual(Zone.left, zoneAt(5, 50, pane100));
    try testing.expectEqual(Zone.right, zoneAt(95, 50, pane100));
    try testing.expectEqual(Zone.top, zoneAt(50, 5, pane100));
    try testing.expectEqual(Zone.bottom, zoneAt(50, 95, pane100));
    // Diagonal ties: left before right before top before bottom.
    // (Powers of two keep the relative distances exact, as 0.125 + 0.875.)
    const pane128: geom.Rect = .{ .x = 0, .y = 0, .w = 128, .h = 128 };
    try testing.expectEqual(Zone.left, zoneAt(16, 16, pane128));
    try testing.expectEqual(Zone.right, zoneAt(112, 16, pane128));
    try testing.expectEqual(Zone.left, zoneAt(16, 112, pane128));
    try testing.expectEqual(Zone.right, zoneAt(112, 112, pane128));
    try testing.expectEqual(Zone.top, zoneAt(64, 16, pane128));
    try testing.expectEqual(Zone.bottom, zoneAt(64, 112, pane128));
    // Off the diagonal, the shorter distance wins.
    try testing.expectEqual(Zone.top, zoneAt(30, 10, pane100));
    try testing.expectEqual(Zone.bottom, zoneAt(70, 95, pane100));
    // A wide pane compares relative distances, not pixels: 20 px from the
    // left is 10 %, 15 px from the top is 30 %.
    const wide: geom.Rect = .{ .x = 100, .y = 200, .w = 200, .h = 50 };
    try testing.expectEqual(Zone.left, zoneAt(120, 215, wide));
    try testing.expectEqual(Zone.top, zoneAt(200, 205, wide));
    // A degenerate pane does not divide by zero.
    _ = zoneAt(0, 0, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
}

test "win32 split drag: zone rect is the half on the zone side" {
    const pane: geom.Rect = .{ .x = 10, .y = 20, .w = 101, .h = 51 };
    try testing.expectEqual(geom.Rect{ .x = 10, .y = 20, .w = 50, .h = 51 }, zoneRect(pane, .left));
    try testing.expectEqual(geom.Rect{ .x = 60, .y = 20, .w = 51, .h = 51 }, zoneRect(pane, .right));
    try testing.expectEqual(geom.Rect{ .x = 10, .y = 20, .w = 101, .h = 25 }, zoneRect(pane, .top));
    try testing.expectEqual(geom.Rect{ .x = 10, .y = 45, .w = 101, .h = 26 }, zoneRect(pane, .bottom));
    // Even sizes split exactly.
    try testing.expectEqual(geom.Rect{ .x = 50, .y = 0, .w = 50, .h = 100 }, zoneRect(pane100, .right));
    try testing.expectEqual(Direction.up, direction(.top));
    try testing.expectEqual(Direction.down, direction(.bottom));
    try testing.expectEqual(Direction.left, direction(.left));
    try testing.expectEqual(Direction.right, direction(.right));
    try testing.expectEqual(RcTree.Split.Direction.up, treeDirection(RcTree, .top));
}

/// Source: pane 7 of tab 3 of window 1.
fn testSource(tab_split: bool, window_tabs: usize) Source {
    return .{ .window = 1, .tab = 3, .surface = 7, .tab_split = tab_split, .window_tabs = window_tabs, .grab = .{ .x = 40, .y = 6 } };
}

fn testMachine(src: Source) Machine {
    return Machine.begin(src, .{ .x = 500, .y = 300 }, .{ .w = 60, .h = 40 }, 4);
}

fn paneHit(window: u32, tab: u32, surface: u32, zone: Zone) Hit {
    return .{ .pane = .{ .window = window, .tab = tab, .surface = surface, .zone = zone, .rect = pane100 } };
}

fn moveEv(x: i32, y: i32, hit: Hit) Event {
    return .{ .move = .{ .pt = .{ .x = x, .y = y }, .hit = hit } };
}

test "win32 split drag: below threshold release is none" {
    var m = testMachine(testSource(true, 1));
    // Exactly the threshold is still a click.
    var fb = m.feed(moveEv(504, 300, paneHit(1, 3, 8, .left)));
    try testing.expect(fb.ghost == null and fb.zone == null and fb.done == null);
    fb = m.feed(.release);
    try testing.expect(fb.done.? == .none);
    // Past the threshold the ghost appears, centred on the pointer.
    m = testMachine(testSource(true, 1));
    fb = m.feed(moveEv(505, 300, paneHit(1, 3, 8, .left)));
    try testing.expectEqual(Point{ .x = 475, .y = 280 }, fb.ghost.?);
}

test "win32 split drag: self pane gives no zone and release is none" {
    const src = testSource(true, 1);
    var m = testMachine(src);
    const fb = m.feed(moveEv(520, 320, paneHit(1, 3, 7, .left)));
    try testing.expect(fb.ghost != null);
    try testing.expect(fb.zone == null);
    try testing.expect(m.feed(.release).done.? == .none);
}

test "win32 split drag: pane of a single-pane source tab is invalid only for itself" {
    const single = testSource(false, 2);
    // The source itself, and (stale) any pane of the same tab.
    try testing.expect(!paneValid(single, paneHit(1, 3, 7, .left)));
    try testing.expect(!paneValid(single, paneHit(1, 3, 8, .left)));
    // Another tab of the same window, and another window.
    try testing.expect(paneValid(single, paneHit(1, 4, 8, .left)));
    try testing.expect(paneValid(single, paneHit(2, 3, 8, .left)));
    // A split source tab: siblings are valid, itself is not.
    const split = testSource(true, 1);
    try testing.expect(paneValid(split, paneHit(1, 3, 8, .right)));
    try testing.expect(!paneValid(split, paneHit(1, 3, 7, .right)));
    // Not a pane.
    try testing.expect(!paneValid(split, .outside));
    try testing.expect(!paneValid(split, .blocked));
}

test "win32 split drag: release over a pane moves there with its zone" {
    var m = testMachine(testSource(true, 1));
    const fb = m.feed(moveEv(530, 330, paneHit(1, 3, 8, .bottom)));
    try testing.expectEqual(@as(u32, 8), fb.zone.?.surface);
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 50, .w = 100, .h = 50 }, fb.zone.?.rect);
    const done = m.feed(.release).done.?.to_pane;
    try testing.expectEqual(@as(u32, 1), done.window);
    try testing.expectEqual(@as(u32, 3), done.tab);
    try testing.expectEqual(@as(u32, 8), done.surface);
    try testing.expectEqual(Zone.bottom, done.zone);
}

test "win32 split drag: release on the strip makes a new tab at the slot" {
    var m = testMachine(testSource(false, 3));
    const fb = m.feed(moveEv(530, 40, .{ .strip = .{ .window = 2, .slot = 1, .over = null } }));
    try testing.expectEqual(@as(u32, 2), fb.marker.?.window);
    try testing.expectEqual(@as(usize, 1), fb.marker.?.index);
    try testing.expect(fb.zone == null);
    const done = m.feed(.release).done.?.new_tab;
    try testing.expectEqual(@as(u32, 2), done.window);
    try testing.expectEqual(@as(usize, 1), done.index);
}

test "win32 split drag: outside: new window for a split tab, for a multi-tab window, none for a lone pane" {
    const grab: Point = .{ .x = 40, .y = 6 };
    const pt: Point = .{ .x = 900, .y = 700 };
    try testing.expectEqual(Point{ .x = 860, .y = 694 }, outsideOutcome(testSource(true, 1), pt, grab).new_window);
    try testing.expectEqual(Point{ .x = 860, .y = 694 }, outsideOutcome(testSource(false, 2), pt, grab).new_window);
    try testing.expect(outsideOutcome(testSource(false, 1), pt, grab) == .none);

    // Through the machine; the grab comes from the source.
    var m = testMachine(testSource(true, 1));
    _ = m.feed(moveEv(900, 700, .outside));
    try testing.expectEqual(Point{ .x = 860, .y = 694 }, m.feed(.release).done.?.new_window);
    m = testMachine(testSource(false, 1));
    _ = m.feed(moveEv(900, 700, .outside));
    try testing.expect(m.feed(.release).done.? == .none);
    // Blocked chrome is no target.
    m = testMachine(testSource(true, 2));
    _ = m.feed(moveEv(900, 700, .blocked));
    try testing.expect(m.feed(.release).done.? == .none);
}

test "win32 split drag: spring arms on a tab, cancels on leaving, selects when it fires over the same tab" {
    var m = testMachine(testSource(false, 3));
    const chip = Hit{ .strip = .{ .window = 1, .slot = 2, .over = 1 } };
    var fb = m.feed(moveEv(520, 40, chip));
    try testing.expectEqual(@as(usize, 1), fb.spring.?.index);
    try testing.expect(!fb.spring_cancel);
    // Staying on the same chip does not restart the timer.
    fb = m.feed(moveEv(524, 40, chip));
    try testing.expect(fb.spring == null and !fb.spring_cancel);
    // Another chip re-arms.
    fb = m.feed(moveEv(600, 40, .{ .strip = .{ .window = 1, .slot = 3, .over = 2 } }));
    try testing.expectEqual(@as(usize, 2), fb.spring.?.index);
    // Leaving to a pane cancels.
    fb = m.feed(moveEv(600, 200, paneHit(2, 9, 8, .left)));
    try testing.expect(fb.spring_cancel);
    // A stale timer message after leaving selects nothing.
    fb = m.feed(.spring_fired);
    try testing.expect(fb.select == null);

    // Arm again, fire while still over the chip.
    _ = m.feed(moveEv(520, 40, chip));
    fb = m.feed(.spring_fired);
    try testing.expectEqual(@as(usize, 1), fb.select.?.index);
    try testing.expectEqual(@as(u32, 1), fb.select.?.window);
    // It fires once; hovering on does not re-arm it.
    fb = m.feed(moveEv(521, 40, chip));
    try testing.expect(fb.spring == null);
    fb = m.feed(.spring_fired);
    try testing.expect(fb.select == null);
    // Leaving after the fire has no timer left to kill.
    fb = m.feed(moveEv(600, 200, .blocked));
    try testing.expect(!fb.spring_cancel);

    // A fire while the pointer moved to another chip selects nothing.
    m = testMachine(testSource(false, 3));
    _ = m.feed(moveEv(520, 40, chip));
    _ = m.feed(moveEv(600, 40, .{ .strip = .{ .window = 1, .slot = 3, .over = 2 } }));
    // The timer restarted for chip 2; a leftover message for chip 1 cannot
    // select chip 1 because the machine only knows chip 2 now.
    fb = m.feed(.spring_fired);
    try testing.expectEqual(@as(usize, 2), fb.select.?.index);

    // A release with an armed spring kills the timer.
    m = testMachine(testSource(false, 3));
    _ = m.feed(moveEv(520, 40, chip));
    fb = m.feed(.release);
    try testing.expect(fb.spring_cancel);
    try testing.expect(fb.done.?.new_tab.index == 2);
}

test "win32 split drag: Esc cancels; events after finish do nothing" {
    var m = testMachine(testSource(true, 1));
    _ = m.feed(moveEv(530, 330, paneHit(1, 3, 8, .left)));
    var fb = m.feed(.cancel);
    try testing.expect(fb.done.? == .cancelled);
    fb = m.feed(moveEv(540, 340, paneHit(1, 3, 8, .left)));
    try testing.expect(fb.ghost == null and fb.zone == null and fb.done == null);
    fb = m.feed(.release);
    try testing.expect(fb.done == null);
    fb = m.feed(.cancel);
    try testing.expect(fb.done == null);

    // Cancel before the threshold too.
    m = testMachine(testSource(true, 1));
    try testing.expect(m.feed(.cancel).done.? == .cancelled);
    // A release finishes the drag as well.
    m = testMachine(testSource(true, 1));
    _ = m.feed(.release);
    try testing.expect(m.feed(.cancel).done == null);
}

test "win32 split drag: moveWithin: 2 panes swapped by dropping A on B's right" {
    const alloc = testing.allocator;
    var a: RcView = .{ .label = "A" };
    var b: RcView = .{ .label = "B" };
    var ta = try RcTree.init(alloc, &a);
    defer ta.deinit();
    var tb = try RcTree.init(alloc, &b);
    defer tb.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer tree.deinit();
    try expectTree(tree,
        \\split (layout: horizontal, ratio: 0.50)
        \\  leaf: A
        \\  leaf: B
        \\
    );

    var moved = try moveWithin(RcTree, alloc, &tree, &a, &b, Zone.right);
    defer moved.deinit();
    try expectTree(moved,
        \\split (layout: horizontal, ratio: 0.50)
        \\  leaf: B
        \\  leaf: A
        \\
    );
    // The input tree is untouched.
    try expectTree(tree,
        \\split (layout: horizontal, ratio: 0.50)
        \\  leaf: A
        \\  leaf: B
        \\
    );

    // Same view and unknown views change nothing.
    try testing.expectError(error.SameView, moveWithin(RcTree, alloc, &tree, &a, &a, Direction.left));
    var other: RcView = .{ .label = "X" };
    try testing.expectError(error.ViewNotFound, moveWithin(RcTree, alloc, &tree, &other, &b, Direction.left));
    try testing.expectError(error.ViewNotFound, moveWithin(RcTree, alloc, &tree, &a, &other, Direction.left));
    try testing.expectEqual(@as(u32, 1), other.refs);
}

test "win32 split drag: moveWithin: 3 panes into a nested split, refs balanced" {
    const alloc = testing.allocator;
    var a: RcView = .{ .label = "A" };
    var b: RcView = .{ .label = "B" };
    var c: RcView = .{ .label = "C" };
    {
        var ta = try RcTree.init(alloc, &a);
        defer ta.deinit();
        var tb = try RcTree.init(alloc, &b);
        defer tb.deinit();
        var tc = try RcTree.init(alloc, &c);
        defer tc.deinit();

        // A | (B / C)
        var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
        defer ab.deinit();
        var tree = try ab.split(alloc, ab.locate(&b).?, .down, 0.5, &tc);
        defer tree.deinit();
        try expectTree(tree,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  split (layout: vertical, ratio: 0.50)
            \\    leaf: B
            \\    leaf: C
            \\
        );

        // Drop A on C's left: A | (B / C) -> B / (A | C).
        var m1 = try moveWithin(RcTree, alloc, &tree, &a, &c, Zone.left);
        defer m1.deinit();
        try expectTree(m1,
            \\split (layout: vertical, ratio: 0.50)
            \\  leaf: B
            \\  split (layout: horizontal, ratio: 0.50)
            \\    leaf: A
            \\    leaf: C
            \\
        );

        // Drop B on A's top: (A | C) gets B above A.
        var m2 = try moveWithin(RcTree, alloc, &m1, &b, &a, Zone.top);
        defer m2.deinit();
        try expectTree(m2,
            \\split (layout: horizontal, ratio: 0.50)
            \\  split (layout: vertical, ratio: 0.50)
            \\    leaf: B
            \\    leaf: A
            \\  leaf: C
            \\
        );
        // The owner plus one ref per live tree that holds the view.
        try testing.expectEqual(@as(u32, 6), a.refs);
        try testing.expectEqual(@as(u32, 6), b.refs);
        try testing.expectEqual(@as(u32, 5), c.refs);
    }
    try testing.expectEqual(@as(u32, 1), a.refs);
    try testing.expectEqual(@as(u32, 1), b.refs);
    try testing.expectEqual(@as(u32, 1), c.refs);
}

test "win32 split drag: moveWithin of a zoomed source unzooms" {
    const alloc = testing.allocator;
    var a: RcView = .{ .label = "A" };
    var b: RcView = .{ .label = "B" };
    {
        var ta = try RcTree.init(alloc, &a);
        defer ta.deinit();
        var tb = try RcTree.init(alloc, &b);
        defer tb.deinit();
        var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
        defer tree.deinit();
        tree.zoom(tree.locate(&a).?);
        try testing.expect(tree.zoomed != null);

        var moved = try moveWithin(RcTree, alloc, &tree, &a, &b, Zone.bottom);
        defer moved.deinit();
        try testing.expect(moved.zoomed == null);
        try expectTree(moved,
            \\split (layout: vertical, ratio: 0.50)
            \\  leaf: B
            \\  leaf: A
            \\
        );
        // The source tree keeps its zoom.
        try testing.expect(tree.zoomed != null);
    }
    try testing.expectEqual(@as(u32, 1), a.refs);
    try testing.expectEqual(@as(u32, 1), b.refs);
}

test "win32 split drag: insertInto: target grows by 2 nodes, source untouched" {
    const alloc = testing.allocator;
    var a: RcView = .{ .label = "A" };
    var b: RcView = .{ .label = "B" };
    var c: RcView = .{ .label = "C" };
    {
        var ta = try RcTree.init(alloc, &a);
        defer ta.deinit();
        var tb = try RcTree.init(alloc, &b);
        defer tb.deinit();
        var dst_tree = try ta.split(alloc, .root, .right, 0.5, &tb);
        defer dst_tree.deinit();
        var src_tree = try RcTree.init(alloc, &c);
        defer src_tree.deinit();
        const dst_nodes = dst_tree.nodes.len;
        const src_nodes = src_tree.nodes.len;
        const c_refs = c.refs;

        var grown = try insertInto(RcTree, alloc, &dst_tree, &c, &a, Zone.top);
        defer grown.deinit();
        try testing.expectEqual(dst_nodes + 2, grown.nodes.len);
        try expectTree(grown,
            \\split (layout: horizontal, ratio: 0.50)
            \\  split (layout: vertical, ratio: 0.50)
            \\    leaf: C
            \\    leaf: A
            \\  leaf: B
            \\
        );
        // The source tree and the target tree are untouched; C is held once more.
        try testing.expectEqual(src_nodes, src_tree.nodes.len);
        try testing.expect(src_tree.locate(&c) != null);
        try testing.expectEqual(dst_nodes, dst_tree.nodes.len);
        try testing.expectEqual(c_refs + 1, c.refs);

        try testing.expectError(error.SameView, insertInto(RcTree, alloc, &dst_tree, &a, &a, Zone.left));
        try testing.expectError(error.ViewNotFound, insertInto(RcTree, alloc, &dst_tree, &a, &c, Zone.left));
    }
    try testing.expectEqual(@as(u32, 1), a.refs);
    try testing.expectEqual(@as(u32, 1), b.refs);
    try testing.expectEqual(@as(u32, 1), c.refs);
}

test "win32 split drag: new-window origin keeps the grab point under the pointer" {
    const pointer: Point = .{ .x = 900, .y = 700 };
    const origin = newWindowOrigin(pointer, .{ .x = 40, .y = 6 }, .{ .x = 8, .y = 70 }, 96, 96);
    try testing.expectEqual(Point{ .x = 852, .y = 624 }, origin);
    // The pane lands at origin + offset, and the grab point at the pointer.
    try testing.expectEqual(pointer.x, origin.x + 8 + 40);
    try testing.expectEqual(pointer.y, origin.y + 70 + 6);
    // Unknown source DPI is the same-DPI path.
    try testing.expectEqual(origin, newWindowOrigin(pointer, .{ .x = 40, .y = 6 }, .{ .x = 8, .y = 70 }, 0, 144));
}

test "win32 split drag: new-window origin with a DPI change" {
    const pointer: Point = .{ .x = 900, .y = 700 };
    // 96 -> 144: (40 + 8, 6 + 70) * 1.5 = (72, 114).
    try testing.expectEqual(Point{ .x = 828, .y = 586 }, newWindowOrigin(pointer, .{ .x = 40, .y = 6 }, .{ .x = 8, .y = 70 }, 96, 144));
    // 144 -> 96: (48, 115) / 1.5 = (32, 76.67 -> 77).
    try testing.expectEqual(Point{ .x = 868, .y = 623 }, newWindowOrigin(pointer, .{ .x = 36, .y = 9 }, .{ .x = 12, .y = 106 }, 144, 96));
}
