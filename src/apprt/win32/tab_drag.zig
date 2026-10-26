//! Tab drag state machine across windows. Pure: the caller feeds pointer
//! events (screen pixels) and applies the returned feedback; nothing here
//! touches a window.
//!
//! `pressed` waits for the pointer to leave the drag threshold, then the drag
//! is either `in_strip` (live reorder inside the own strip) or `detached`
//! (ghost following the pointer, optionally over another window's strip).
//! The pointer position of the last move is in `last_pt`, for the chrome
//! painter's drag x.
const std = @import("std");
const geom = @import("geom.zig");

pub const Point = struct { x: i32, y: i32 };

/// What lies under the pointer; `index` is the insertion slot of that strip.
pub const Hit = union(enum) { none, strip: struct { window: u32, index: usize } };

pub const Event = union(enum) {
    move: struct { pt: Point, hit: Hit },
    release,
    /// Esc or lost capture.
    cancel,
};

pub const Outcome = union(enum) {
    click,
    reorder: struct { from: usize, to: usize },
    move_to: struct { window: u32, index: usize },
    /// Origin of the new window.
    tear_off: Point,
    /// New origin of the source window (it holds a single tab).
    move_window: Point,
    cancelled: struct { restore_index: usize },
};

pub const Feedback = struct {
    live_reorder: ?struct { from: usize, to: usize } = null,
    ghost: ?Point = null,
    marker: ?struct { window: u32, index: usize } = null,
    done: ?Outcome = null,
};

pub fn detachMargin(dpi: u32) i32 {
    return geom.scale(24, dpi);
}

const State = enum { pressed, in_strip, detached, finished };

pub const Machine = struct {
    source_window: u32,
    /// Index of the tab at `begin`.
    origin_index: usize,
    /// Index of the tab now (live reorder moves it).
    index: usize,
    tab_count: usize,
    press: Point,
    grab: Point,
    strip_origin: Point,
    /// Size of the source strip; the detach margin is measured from this
    /// rectangle. Set with `withStripSize`; until then the strip is a point.
    strip_size: Point = .{ .x = 0, .y = 0 },
    /// Where the strip sits inside its window, so that a new window keeps the
    /// tab under the pointer. Set with `withWindowOffset`.
    window_offset: Point = .{ .x = 0, .y = 0 },
    threshold: i32,
    detach_margin: i32,
    state: State = .pressed,
    last_pt: Point,
    last_hit: Hit = .none,

    pub fn begin(
        source_window: u32,
        tab: usize,
        tab_count: usize,
        press: Point,
        grab: Point,
        strip_origin: Point,
        threshold: i32,
        detach_margin: i32,
    ) Machine {
        return .{
            .source_window = source_window,
            .origin_index = tab,
            .index = tab,
            .tab_count = tab_count,
            .press = press,
            .grab = grab,
            .strip_origin = strip_origin,
            .threshold = threshold,
            .detach_margin = detach_margin,
            .last_pt = press,
        };
    }

    pub fn withStripSize(self: Machine, w: i32, h: i32) Machine {
        var m = self;
        m.strip_size = .{ .x = w, .y = h };
        return m;
    }

    pub fn withWindowOffset(self: Machine, off: Point) Machine {
        var m = self;
        m.window_offset = off;
        return m;
    }

    pub fn feed(self: *Machine, ev: Event) Feedback {
        if (self.state == .finished) return .{};
        switch (ev) {
            .cancel => {
                self.state = .finished;
                return .{ .done = .{ .cancelled = .{ .restore_index = self.origin_index } } };
            },
            .release => return self.release(),
            .move => |mv| {
                self.last_pt = mv.pt;
                self.last_hit = mv.hit;
                return self.move(mv.pt, mv.hit);
            },
        }
    }

    fn ownStrip(self: *const Machine, hit: Hit) ?usize {
        return switch (hit) {
            .strip => |s| if (s.window == self.source_window) s.index else null,
            .none => null,
        };
    }

    fn move(self: *Machine, pt: Point, hit: Hit) Feedback {
        switch (self.state) {
            .pressed => {
                const dx: i64 = pt.x - self.press.x;
                const dy: i64 = pt.y - self.press.y;
                const t: i64 = self.threshold;
                if (dx * dx + dy * dy <= t * t) return .{};
                self.state = if (self.ownStrip(hit) != null) .in_strip else .detached;
                return self.move(pt, hit);
            },
            .in_strip => {
                if (self.ownStrip(hit)) |slot| return self.reorderTo(slot);
                // Over another window's strip the tab is already leaving.
                if (hit == .strip or self.outsideBy(pt) > self.detach_margin) {
                    self.state = .detached;
                    return self.move(pt, hit);
                }
                return .{};
            },
            .detached => {
                if (self.ownStrip(hit)) |slot| {
                    self.state = .in_strip;
                    return self.reorderTo(slot);
                }
                var fb: Feedback = .{ .ghost = .{ .x = pt.x - self.grab.x, .y = pt.y - self.grab.y } };
                switch (hit) {
                    .strip => |s| fb.marker = .{ .window = s.window, .index = s.index },
                    .none => {},
                }
                return fb;
            },
            .finished => return .{},
        }
    }

    fn reorderTo(self: *Machine, slot: usize) Feedback {
        const to = if (self.tab_count == 0) 0 else @min(slot, self.tab_count - 1);
        if (to == self.index) return .{};
        const from = self.index;
        self.index = to;
        return .{ .live_reorder = .{ .from = from, .to = to } };
    }

    /// Distance of the point outside the source strip rectangle (0 inside).
    fn outsideBy(self: *const Machine, pt: Point) i32 {
        const left = self.strip_origin.x;
        const top = self.strip_origin.y;
        const right = left + self.strip_size.x;
        const bottom = top + self.strip_size.y;
        const dx = @max(left - pt.x, pt.x - right, 0);
        const dy = @max(top - pt.y, pt.y - bottom, 0);
        return @max(dx, dy);
    }

    fn release(self: *Machine) Feedback {
        const prev = self.state;
        self.state = .finished;
        const outcome: Outcome = switch (prev) {
            .pressed => .click,
            .in_strip => .{ .reorder = .{ .from = self.origin_index, .to = self.index } },
            .detached => switch (self.last_hit) {
                .strip => |s| .{ .move_to = .{ .window = s.window, .index = s.index } },
                .none => blk: {
                    const origin: Point = .{
                        .x = self.last_pt.x - self.grab.x - self.window_offset.x,
                        .y = self.last_pt.y - self.grab.y - self.window_offset.y,
                    };
                    break :blk if (self.tab_count == 1) .{ .move_window = origin } else .{ .tear_off = origin };
                },
            },
            .finished => unreachable,
        };
        return .{ .done = outcome };
    }
};

const testing = std.testing;

fn own(index: usize) Hit {
    return .{ .strip = .{ .window = 1, .index = index } };
}

fn testMachine(count: usize) Machine {
    return Machine.begin(1, 0, count, .{ .x = 100, .y = 10 }, .{ .x = 20, .y = 8 }, .{ .x = 0, .y = 0 }, 4, 24)
        .withStripSize(800, 40);
}

test "win32 tab drag: press and release without moving is a click" {
    var m = testMachine(3);
    const fb = m.feed(.release);
    try testing.expect(fb.done.? == .click);
}

test "win32 tab drag: below threshold stays pressed" {
    var m = testMachine(3);
    const fb = m.feed(.{ .move = .{ .pt = .{ .x = 103, .y = 10 }, .hit = own(1) } });
    try testing.expect(fb.live_reorder == null and fb.ghost == null and fb.done == null);
    try testing.expect(m.feed(.release).done.? == .click);
}

test "win32 tab drag: reorder inside the own strip" {
    var m = testMachine(3);
    const fb = m.feed(.{ .move = .{ .pt = .{ .x = 160, .y = 10 }, .hit = own(1) } });
    try testing.expectEqual(0, fb.live_reorder.?.from);
    try testing.expectEqual(1, fb.live_reorder.?.to);
    try testing.expect(fb.ghost == null);
    const done = m.feed(.release).done.?;
    try testing.expectEqual(0, done.reorder.from);
    try testing.expectEqual(1, done.reorder.to);
}

test "win32 tab drag: leaving the strip by the margin detaches and shows the ghost" {
    var m = testMachine(3);
    _ = m.feed(.{ .move = .{ .pt = .{ .x = 160, .y = 10 }, .hit = own(0) } });
    // Inside the margin the tab stays in the strip: no ghost.
    var fb = m.feed(.{ .move = .{ .pt = .{ .x = 160, .y = 40 + 24 }, .hit = .none } });
    try testing.expect(fb.ghost == null);
    fb = m.feed(.{ .move = .{ .pt = .{ .x = 160, .y = 40 + 24 + 1 }, .hit = .none } });
    try testing.expectEqual(140, fb.ghost.?.x);
    try testing.expectEqual(40 + 24 + 1 - 8, fb.ghost.?.y);
    try testing.expect(fb.marker == null);
}

test "win32 tab drag: back over the own strip re-attaches" {
    var m = testMachine(3);
    _ = m.feed(.{ .move = .{ .pt = .{ .x = 160, .y = 300 }, .hit = .none } });
    const fb = m.feed(.{ .move = .{ .pt = .{ .x = 300, .y = 20 }, .hit = own(2) } });
    try testing.expect(fb.ghost == null);
    try testing.expectEqual(2, fb.live_reorder.?.to);
    try testing.expectEqual(0, m.feed(.release).done.?.reorder.from);
}

test "win32 tab drag: drop on another window's strip" {
    var m = testMachine(3);
    const over: Hit = .{ .strip = .{ .window = 7, .index = 1 } };
    const fb = m.feed(.{ .move = .{ .pt = .{ .x = 900, .y = 20 }, .hit = over } });
    try testing.expectEqual(7, fb.marker.?.window);
    try testing.expectEqual(1, fb.marker.?.index);
    try testing.expect(fb.ghost != null);
    const done = m.feed(.release).done.?;
    try testing.expectEqual(7, done.move_to.window);
    try testing.expectEqual(1, done.move_to.index);
}

test "win32 tab drag: drop outside tears off, single tab moves the window" {
    var m = testMachine(3).withWindowOffset(.{ .x = 8, .y = 2 });
    _ = m.feed(.{ .move = .{ .pt = .{ .x = 500, .y = 400 }, .hit = .none } });
    const t = m.feed(.release).done.?.tear_off;
    try testing.expectEqual(500 - 20 - 8, t.x);
    try testing.expectEqual(400 - 8 - 2, t.y);

    var one = testMachine(1);
    _ = one.feed(.{ .move = .{ .pt = .{ .x = 500, .y = 400 }, .hit = .none } });
    const w = one.feed(.release).done.?.move_window;
    try testing.expectEqual(480, w.x);
    try testing.expectEqual(392, w.y);
}

test "win32 tab drag: Esc restores the original index" {
    var m = testMachine(3);
    _ = m.feed(.{ .move = .{ .pt = .{ .x = 300, .y = 10 }, .hit = own(2) } });
    const done = m.feed(.cancel).done.?;
    try testing.expectEqual(0, done.cancelled.restore_index);
    // Finished: later events do nothing.
    try testing.expect(m.feed(.release).done == null);
}
