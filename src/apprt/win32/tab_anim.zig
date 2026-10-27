//! Animation of the tab row like Ghostty for macOS: a new tab pushes its
//! neighbours and grows, a closed tab shrinks away, a reordered tab's
//! neighbours slide, and the whole row slides in when the second tab
//! appears and out when it goes. All of it lasts 0.2 s with the ease in-out
//! curve of Core Animation.
//!
//! The model (`TabStrip.Layout`, hit testing, the terminal's size) always
//! holds the final geometry; this only says where to paint. The state is
//! pure (the clock comes in as an argument) and the window runs a timer
//! only while `running`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");

pub const duration_ns: u64 = 200 * std.time.ns_per_ms;

/// Interval of the window's animation timer.
pub const step_ms = 8;

/// `CAMediaTimingFunction(name: .easeInEaseOut)`: the cubic Bezier
/// (0.42, 0, 0.58, 1), solved for x with a few Newton steps.
pub fn ease(t: f64) f64 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const x1 = 0.42;
    const x2 = 0.58;
    const y1 = 0.0;
    const y2 = 1.0;
    var s = t;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const err = bezier(s, x1, x2) - t;
        if (@abs(err) < 1e-6) break;
        const d = bezierSlope(s, x1, x2);
        if (@abs(d) < 1e-6) break;
        s -= err / d;
    }
    s = std.math.clamp(s, 0, 1);
    return bezier(s, y1, y2);
}

fn bezier(s: f64, p1: f64, p2: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

fn bezierSlope(s: f64, p1: f64, p2: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2);
}

fn lerpInt(a: i32, b: i32, p: f64) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b - a)) * p)));
}

/// `from` moved towards `to` by the eased fraction `p`; the row (y, h) is
/// the target's.
fn lerpRect(from: geom.Rect, to: geom.Rect, p: f64) geom.Rect {
    return .{ .x = lerpInt(from.x, to.x, p), .y = to.y, .w = lerpInt(from.w, to.w, p), .h = to.h };
}

pub const title_cap = 64;

pub const Entry = struct {
    id: u32,
    from: geom.Rect,
    to: geom.Rect,
    title: [title_cap]u8 = undefined,
    title_len: u8 = 0,

    fn titleSlice(self: *const Entry) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// What the painter needs of a tab that is shrinking away.
pub const ClosingRect = struct { rect: geom.Rect, title: []const u8 };

pub const State = struct {
    start_ns: u64 = 0,
    running: bool = false,
    /// In layout order.
    tabs: std.ArrayList(Entry) = .empty,
    closing: std.ArrayList(Entry) = .empty,
    /// How much of the tab row is shown, 0 (gone) to 1 (fully in).
    row_from: f64 = 0,
    row_to: f64 = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.tabs.deinit(alloc);
        self.closing.deinit(alloc);
    }

    /// The eased fraction of the animation done at `now_ns`.
    fn progress(self: *const State, now_ns: u64) f64 {
        if (!self.running) return 1;
        const dt = now_ns -| self.start_ns;
        if (dt >= duration_ns) return 1;
        return ease(@as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(duration_ns)));
    }

    fn sameIds(self: *const State, ids: []const u32) bool {
        if (self.tabs.items.len != ids.len) return false;
        for (self.tabs.items, ids) |e, id| if (e.id != id) return false;
        return true;
    }

    fn find(list: []const Entry, id: u32) ?*const Entry {
        for (list) |*e| if (e.id == id) return e;
        return null;
    }

    /// The tabs of the window changed: `ids`, `titles` and the final `targets`
    /// in layout order. With `allow` a changed set or order slides from where
    /// the tabs are painted now; otherwise (or when only the geometry changed:
    /// a resize, another DPI) everything snaps.
    pub fn retarget(
        self: *State,
        alloc: Allocator,
        now_ns: u64,
        allow: bool,
        ids: []const u32,
        titles: []const []const u8,
        targets: []const geom.Rect,
    ) Allocator.Error!void {
        std.debug.assert(ids.len == targets.len and ids.len == titles.len);
        const animate = allow and self.tabs.items.len > 0 and !self.sameIds(ids);
        const p = self.progress(now_ns);

        var next: std.ArrayList(Entry) = .empty;
        errdefer next.deinit(alloc);
        try next.ensureTotalCapacity(alloc, ids.len);
        for (ids, targets, titles) |id, to, title| {
            var e: Entry = .{ .id = id, .from = to, .to = to };
            const n = @min(title.len, title_cap);
            // Cut at a code point: the title is painted as UTF-8.
            var len = n;
            while (len > 0 and len < title.len and (title[len] & 0xC0) == 0x80) len -= 1;
            @memcpy(e.title[0..len], title[0..len]);
            e.title_len = @intCast(len);
            if (animate) {
                if (find(self.tabs.items, id)) |old| {
                    e.from = lerpRect(old.from, old.to, p);
                } else {
                    // A new tab grows out of its left edge.
                    e.from = .{ .x = to.x, .y = to.y, .w = 0, .h = to.h };
                }
            }
            next.appendAssumeCapacity(e);
        }

        var gone: std.ArrayList(Entry) = .empty;
        errdefer gone.deinit(alloc);
        if (animate) {
            for (self.tabs.items) |old| {
                if (std.mem.indexOfScalar(u32, ids, old.id) != null) continue;
                const cur = lerpRect(old.from, old.to, p);
                var e = old;
                e.from = cur;
                e.to = .{ .x = cur.x + @divTrunc(cur.w, 2), .y = cur.y, .w = 0, .h = cur.h };
                try gone.append(alloc, e);
            }
            // Tabs still shrinking from an earlier change carry on from where they are.
            for (self.closing.items) |old| {
                var e = old;
                e.from = lerpRect(old.from, old.to, p);
                try gone.append(alloc, e);
            }
        }

        self.tabs.deinit(alloc);
        self.tabs = next;
        self.closing.deinit(alloc);
        self.closing = gone;
        if (animate) {
            self.start_ns = now_ns;
            self.running = true;
        } else if (self.closing.items.len == 0 and self.row_from == self.row_to) {
            self.running = false;
        }
    }

    /// The tab row goes in (`visible`) or out. Without `animate` it jumps.
    pub fn retargetRow(self: *State, now_ns: u64, visible: bool, animate: bool) void {
        const to: f64 = if (visible) 1 else 0;
        if (to == self.row_to and (self.row_from == self.row_to or self.running)) return;
        const cur = self.rowAt(now_ns);
        self.row_to = to;
        if (animate) {
            self.row_from = cur;
            // The tab rects continue from where they are.
            const p = self.progress(now_ns);
            for (self.tabs.items) |*e| e.from = lerpRect(e.from, e.to, p);
            self.start_ns = now_ns;
            self.running = true;
        } else {
            self.row_from = to;
            if (self.closing.items.len == 0) self.running = false;
        }
    }

    /// How much of the tab row is shown at `now_ns`.
    pub fn rowAt(self: *const State, now_ns: u64) f64 {
        return self.row_from + (self.row_to - self.row_from) * self.progress(now_ns);
    }

    /// Whether the tab row is on its way out (the terminal keeps the room
    /// until it is gone, so that its grid resizes once, at the end).
    pub fn rowLeaving(self: *const State) bool {
        return self.running and self.row_to == 0 and self.row_from > 0;
    }

    /// Advances to `now_ns`; false once everything has landed (the timer
    /// can stop and the painter uses the layout).
    pub fn tick(self: *State, now_ns: u64) bool {
        if (!self.running) return false;
        if (now_ns -| self.start_ns < duration_ns) return true;
        self.running = false;
        self.closing.clearRetainingCapacity();
        self.row_from = self.row_to;
        for (self.tabs.items) |*e| e.from = e.to;
        return false;
    }

    /// Where tab `i` is painted at `now_ns`.
    pub fn rectAt(self: *const State, i: usize, now_ns: u64) geom.Rect {
        const e = self.tabs.items[i];
        return lerpRect(e.from, e.to, self.progress(now_ns));
    }

    pub fn closingAt(self: *const State, i: usize, now_ns: u64) ClosingRect {
        const e = &self.closing.items[i];
        return .{ .rect = lerpRect(e.from, e.to, self.progress(now_ns)), .title = e.titleSlice() };
    }
};

const testing = std.testing;

fn r(x: i32, w: i32) geom.Rect {
    return .{ .x = x, .y = 4, .w = w, .h = 28 };
}

test "win32 tab anim: ease is the Core Animation ease in-out" {
    try testing.expectEqual(@as(f64, 0), ease(0));
    try testing.expectEqual(@as(f64, 1), ease(1));
    try testing.expectEqual(@as(f64, 0), ease(-1));
    try testing.expectEqual(@as(f64, 1), ease(2));
    try testing.expectApproxEqAbs(@as(f64, 0.5), ease(0.5), 1e-4);
    // Slow at both ends, monotone.
    try testing.expect(ease(0.1) < 0.1);
    try testing.expect(ease(0.9) > 0.9);
    var last: f64 = 0;
    var t: f64 = 0.05;
    while (t <= 1) : (t += 0.05) {
        const v = ease(t);
        try testing.expect(v >= last);
        last = v;
    }
}

test "win32 tab anim: a new tab pushes the others and grows" {
    const alloc = testing.allocator;
    var st: State = .{};
    defer st.deinit(alloc);
    const t = std.time.ns_per_ms;

    // First layout: nothing to animate from.
    try st.retarget(alloc, 0, true, &.{ 1, 2 }, &.{ "a", "b" }, &.{ r(8, 100), r(108, 100) });
    try testing.expect(!st.running);
    try testing.expectEqual(r(108, 100), st.rectAt(1, 0));

    // A third tab: the others shrink to a third of the track, the new one grows.
    try st.retarget(alloc, 1000 * t, true, &.{ 1, 2, 3 }, &.{ "a", "b", "c" }, &.{ r(8, 68), r(76, 68), r(144, 64) });
    try testing.expect(st.running);
    try testing.expectEqual(r(108, 100), st.rectAt(1, 1000 * t));
    try testing.expectEqual(@as(i32, 0), st.rectAt(2, 1000 * t).w);
    try testing.expectEqual(@as(i32, 144), st.rectAt(2, 1000 * t).x);
    // Half way (the curve is symmetric): halfway between old and new.
    const mid = st.rectAt(1, 1000 * t + duration_ns / 2);
    try testing.expectEqual(@as(i32, 92), mid.x);
    try testing.expectEqual(@as(i32, 84), mid.w);
    // At the end exactly the layout.
    try testing.expect(st.tick(1000 * t + 100 * t));
    try testing.expect(!st.tick(1000 * t + 200 * t));
    try testing.expectEqual(r(144, 64), st.rectAt(2, 1000 * t + 300 * t));
    try testing.expect(!st.running);
}

test "win32 tab anim: a closed tab shrinks away and is dropped at the end" {
    const alloc = testing.allocator;
    var st: State = .{};
    defer st.deinit(alloc);
    const t = std.time.ns_per_ms;

    try st.retarget(alloc, 0, true, &.{ 1, 2, 3 }, &.{ "a", "b", "c" }, &.{ r(8, 67), r(75, 67), r(142, 66) });
    try st.retarget(alloc, 10 * t, true, &.{ 1, 3 }, &.{ "a", "c" }, &.{ r(8, 100), r(108, 100) });
    try testing.expect(st.running);
    try testing.expectEqual(@as(usize, 1), st.closing.items.len);
    const c0 = st.closingAt(0, 10 * t);
    try testing.expectEqualStrings("b", c0.title);
    try testing.expectEqual(@as(i32, 67), c0.rect.w);
    const c1 = st.closingAt(0, 10 * t + duration_ns);
    try testing.expectEqual(@as(i32, 0), c1.rect.w);
    // The survivor slides from its old slot to the new one.
    try testing.expectEqual(@as(i32, 142), st.rectAt(1, 10 * t).x);
    try testing.expectEqual(@as(i32, 108), st.rectAt(1, 10 * t + duration_ns).x);

    try testing.expect(!st.tick(10 * t + duration_ns));
    try testing.expectEqual(@as(usize, 0), st.closing.items.len);
}

test "win32 tab anim: reorder slides, same tabs snap, retarget continues" {
    const alloc = testing.allocator;
    var st: State = .{};
    defer st.deinit(alloc);
    const t = std.time.ns_per_ms;

    try st.retarget(alloc, 0, true, &.{ 1, 2 }, &.{ "a", "b" }, &.{ r(8, 100), r(108, 100) });
    try st.retarget(alloc, t, true, &.{ 2, 1 }, &.{ "b", "a" }, &.{ r(8, 100), r(108, 100) });
    try testing.expect(st.running);
    try testing.expectEqual(@as(i32, 108), st.rectAt(0, t).x);
    try testing.expectEqual(@as(i32, 8), st.rectAt(1, t).x);
    try testing.expectEqual(@as(i32, 8), st.rectAt(0, t + duration_ns).x);

    // A resize with the same tabs: no animation, the rects are the new ones.
    try st.retarget(alloc, 5 * t, true, &.{ 2, 1 }, &.{ "b", "a" }, &.{ r(8, 200), r(208, 200) });
    try testing.expect(!st.running);
    try testing.expectEqual(r(208, 200), st.rectAt(1, 5 * t));

    // Not allowed (DPI change): snaps even though the order changed.
    try st.retarget(alloc, 6 * t, false, &.{ 1, 2 }, &.{ "a", "b" }, &.{ r(12, 150), r(162, 150) });
    try testing.expect(!st.running);
    try testing.expectEqual(r(12, 150), st.rectAt(0, 6 * t));

    // A change in the middle of an animation starts from where the tab is painted.
    try st.retarget(alloc, 10 * t, true, &.{ 2, 1 }, &.{ "b", "a" }, &.{ r(12, 150), r(162, 150) });
    const mid = 10 * t + duration_ns / 2;
    const painted = st.rectAt(0, mid);
    try st.retarget(alloc, mid, true, &.{ 1, 2 }, &.{ "a", "b" }, &.{ r(12, 150), r(162, 150) });
    try testing.expectEqual(painted, st.rectAt(1, mid));
}

test "win32 tab anim: the row slides in and out, the terminal keeps the room while it leaves" {
    const alloc = testing.allocator;
    var st: State = .{};
    defer st.deinit(alloc);
    const t = std.time.ns_per_ms;

    // Starts hidden; it slides in.
    st.retargetRow(0, true, true);
    try testing.expect(st.running);
    try testing.expect(!st.rowLeaving());
    try testing.expectEqual(@as(f64, 0), st.rowAt(0));
    try testing.expectApproxEqAbs(@as(f64, 0.5), st.rowAt(duration_ns / 2), 1e-3);
    try testing.expectEqual(@as(f64, 1), st.rowAt(duration_ns));
    try testing.expect(!st.tick(duration_ns));
    try testing.expectEqual(@as(f64, 1), st.rowAt(duration_ns + t));

    // Out again.
    st.retargetRow(1000 * t, false, true);
    try testing.expect(st.rowLeaving());
    try testing.expectEqual(@as(f64, 1), st.rowAt(1000 * t));
    try testing.expectEqual(@as(f64, 0), st.rowAt(1000 * t + duration_ns));
    try testing.expect(!st.tick(1000 * t + duration_ns));
    try testing.expect(!st.rowLeaving());

    // Without animation the row jumps.
    st.retargetRow(3000 * t, true, false);
    try testing.expect(!st.running);
    try testing.expectEqual(@as(f64, 1), st.rowAt(3000 * t));
}
