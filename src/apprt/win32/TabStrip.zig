//! The tab strip model: geometry and hit testing, no drawing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");

pub const Mode = enum { hidden, tabs_only, titlebar };

pub const Part = union(enum) {
    nowhere,
    caption,
    resize_top,
    tab: usize,
    tab_close: usize,
    new_tab,
    minimize,
    maximize,
    close,
};

pub const Metrics = struct {
    height: i32,
    tab_min_w: i32,
    tab_max_w: i32,
    tab_pad: i32,
    close_w: i32,
    new_tab_w: i32,
    caption_btn_w: i32,
    min_drag_w: i32,
    resize_band: i32,
    drag_threshold: i32,

    pub fn forDpi(dpi: u32) Metrics {
        return .{
            .height = geom.scale(40, dpi),
            .tab_min_w = geom.scale(72, dpi),
            .tab_max_w = geom.scale(240, dpi),
            .tab_pad = geom.scale(10, dpi),
            .close_w = geom.scale(28, dpi),
            .new_tab_w = geom.scale(40, dpi),
            .caption_btn_w = geom.scale(46, dpi),
            .min_drag_w = geom.scale(48, dpi),
            .resize_band = geom.scale(6, dpi),
            .drag_threshold = geom.scale(4, dpi),
        };
    }
};

/// Width in px of a title as the strip paints it.
pub const Measure = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, title: []const u8) i32,

    pub fn width(self: Measure, title: []const u8) i32 {
        return self.func(self.ctx, title);
    }
};

/// The width of the title area of a tab `tab_w` wide: as `Chrome.tabParts`
/// with the close button, which a tab too narrow for it does without.
pub fn titleWidth(m: Metrics, tab_w: i32) i32 {
    const right_pad = if (tab_w >= 2 * m.close_w) m.close_w else m.tab_pad;
    return @max(tab_w - m.tab_pad - right_pad, 0);
}

pub const Layout = struct {
    mode: Mode = .hidden,
    show_tabs: bool = false,
    bounds: geom.Rect = .{},
    /// Tab rects in strip coordinates, already shifted by `scroll`.
    tabs: std.ArrayList(geom.Rect) = .empty,
    new_tab: ?geom.Rect = null,
    minimize: ?geom.Rect = null,
    maximize: ?geom.Rect = null,
    close: ?geom.Rect = null,
    caption: geom.Rect = .{},
    title: ?geom.Rect = null,
    /// Where tabs are visible; tabs are clipped to this by the painter.
    clip: geom.Rect = .{},
    scroll: i32 = 0,
    /// Per tab: its title does not fit the title area (it is drawn with an
    /// ellipsis). Filled by `fillTrimmed`, not by `compute`.
    trimmed: std.ArrayList(bool) = .empty,

    pub fn compute(
        self: *Layout,
        alloc: Allocator,
        m: Metrics,
        width: i32,
        mode: Mode,
        show_tabs: bool,
        count: usize,
        active: usize,
    ) !void {
        self.mode = mode;
        self.show_tabs = show_tabs;
        self.tabs.clearRetainingCapacity();
        self.new_tab = null;
        self.minimize = null;
        self.maximize = null;
        self.close = null;
        self.title = null;
        self.clip = .{};
        self.caption = .{};

        if (mode == .hidden) {
            self.bounds = .{ .x = 0, .y = 0, .w = width, .h = 0 };
            self.scroll = 0;
            return;
        }
        const h = m.height;
        self.bounds = .{ .x = 0, .y = 0, .w = width, .h = h };

        // Caption buttons (titlebar mode only), close rightmost.
        var buttons_w: i32 = 0;
        if (mode == .titlebar) {
            buttons_w = 3 * m.caption_btn_w;
            const bx = width - buttons_w;
            self.minimize = .{ .x = bx, .y = 0, .w = m.caption_btn_w, .h = h };
            self.maximize = .{ .x = bx + m.caption_btn_w, .y = 0, .w = m.caption_btn_w, .h = h };
            self.close = .{ .x = bx + 2 * m.caption_btn_w, .y = 0, .w = m.caption_btn_w, .h = h };
        }
        const buttons_x = width - buttons_w;

        if (!show_tabs) {
            self.scroll = 0;
            const nx = @max(buttons_x - m.new_tab_w, m.tab_pad);
            self.new_tab = .{ .x = nx, .y = 0, .w = m.new_tab_w, .h = h };
            if (mode == .titlebar) {
                self.title = .{ .x = m.tab_pad, .y = 0, .w = @max(nx - m.tab_pad, 0), .h = h };
                self.caption = .{ .x = nx + m.new_tab_w, .y = 0, .w = @max(buttons_x - nx - m.new_tab_w, 0), .h = h };
            }
            return;
        }

        const available = width - m.tab_pad - m.new_tab_w - m.min_drag_w - buttons_w;
        // Narrow windows: the caption buttons keep their place, then the
        // new-tab button is dropped, then the tabs shrink below `tab_min_w`.
        const keep_new_tab = buttons_x - m.tab_pad - m.new_tab_w > 0;
        const room = @max(buttons_x - m.tab_pad - (if (keep_new_tab) m.new_tab_w else 0), 0);
        const clip_w = @max(available, @min(m.tab_min_w, room));
        self.clip = .{ .x = m.tab_pad, .y = 0, .w = clip_w, .h = h };

        const n: i32 = @intCast(@min(count, std.math.maxInt(i32) / @max(m.tab_max_w, 1)));
        const tab_w = if (clip_w < m.tab_min_w) clip_w else std.math.clamp(@divTrunc(clip_w, @max(n, 1)), m.tab_min_w, m.tab_max_w);
        const total = tab_w * n;
        const overflow = @max(total - clip_w, 0);

        if (overflow == 0) {
            self.scroll = 0;
        } else {
            var sc = std.math.clamp(self.scroll, 0, overflow);
            if (active < count) {
                const left = tab_w * @as(i32, @intCast(active));
                if (left < sc) sc = left;
                if (left + tab_w > sc + clip_w) sc = left + tab_w - clip_w;
            }
            self.scroll = std.math.clamp(sc, 0, overflow);
        }

        try self.tabs.ensureTotalCapacity(alloc, count);
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            self.tabs.appendAssumeCapacity(.{
                .x = self.clip.x + i * tab_w - self.scroll,
                .y = 0,
                .w = tab_w,
                .h = h,
            });
        }

        // After the last tab, or at the clip end on overflow.
        const nx = self.clip.x + @min(total, clip_w);
        var cx = nx;
        if (keep_new_tab) {
            self.new_tab = .{ .x = nx, .y = 0, .w = m.new_tab_w, .h = h };
            cx = nx + m.new_tab_w;
        }
        if (mode == .titlebar) {
            self.caption = .{ .x = cx, .y = 0, .w = @max(buttons_x - cx, 0), .h = h };
        }
    }

    pub fn hitTest(self: *const Layout, m: Metrics, x: i32, y: i32, maximized: bool) Part {
        if (self.mode == .hidden or !self.bounds.contains(x, y)) return .nowhere;
        if (self.mode == .titlebar and !maximized and y < m.resize_band) return .resize_top;

        if (self.close) |r| if (r.contains(x, y)) return .close;
        if (self.maximize) |r| if (r.contains(x, y)) return .maximize;
        if (self.minimize) |r| if (r.contains(x, y)) return .minimize;
        if (self.new_tab) |r| if (r.contains(x, y)) return .new_tab;

        if (self.clip.contains(x, y)) {
            for (self.tabs.items, 0..) |r, i| {
                if (!r.contains(x, y)) continue;
                // The pointer is over this tab, so it is the hovered one: its
                // close button (right `close_w`) is live when the tab is wide enough.
                if (r.w >= 2 * m.close_w and x >= r.right() - m.close_w) return .{ .tab_close = i };
                return .{ .tab = i };
            }
        }

        return if (self.mode == .titlebar) .caption else .nowhere;
    }

    /// Sets `trimmed` from the widths `measure` reports for `titles`, one per
    /// tab. The title area is the tab less its padding and the close button
    /// (the hovered tab shows it, and only a hovered tab has a tooltip).
    pub fn fillTrimmed(
        self: *Layout,
        alloc: Allocator,
        m: Metrics,
        titles: []const []const u8,
        measure: Measure,
    ) !void {
        self.trimmed.clearRetainingCapacity();
        try self.trimmed.ensureTotalCapacity(alloc, self.tabs.items.len);
        for (self.tabs.items, 0..) |r, i| {
            const trimmed = i < titles.len and measure.width(titles[i]) > titleWidth(m, r.w);
            self.trimmed.appendAssumeCapacity(trimmed);
        }
    }

    /// Shifts the tabs by `delta` px, clamped to `[0, overflow]`.
    pub fn scrollBy(self: *Layout, delta: i32) void {
        const n: i32 = @intCast(self.tabs.items.len);
        if (n == 0) return;
        const tab_w = self.tabs.items[0].w;
        const overflow = @max(tab_w * n - self.clip.w, 0);
        const next = std.math.clamp(self.scroll +| delta, 0, overflow);
        const diff = next - self.scroll;
        self.scroll = next;
        for (self.tabs.items) |*r| r.x -= diff;
    }

    pub fn deinit(self: *Layout, alloc: Allocator) void {
        self.tabs.deinit(alloc);
        self.trimmed.deinit(alloc);
    }
};

pub const Drag = struct {
    tab: usize,
    start_x: i32,
    grab_dx: i32,
    active: bool = false,
    current: usize,
};

/// Feeds a pointer x to the drag. Returns the move to apply once the drag has
/// passed the threshold and the dragged tab's centre entered another slot.
pub fn dragUpdate(drag: *Drag, layout: *const Layout, m: Metrics, x: i32) ?struct { from: usize, to: usize } {
    if (!drag.active) {
        if (@abs(x - drag.start_x) < m.drag_threshold) return null;
        drag.active = true;
    }
    const tabs = layout.tabs.items;
    if (tabs.len == 0) return null;
    const w = tabs[0].w;
    const centre = x - drag.grab_dx + @divTrunc(w, 2);
    var to: usize = tabs.len - 1;
    for (tabs, 0..) |r, i| {
        if (centre < r.right()) {
            to = i;
            break;
        }
    }
    if (to == drag.current) return null;
    const from = drag.current;
    drag.current = to;
    return .{ .from = from, .to = to };
}

/// The x the painter draws the dragged tab at.
pub fn dragOffset(drag: *const Drag, layout: *const Layout, x: i32) i32 {
    const tabs = layout.tabs.items;
    if (tabs.len == 0) return x - drag.grab_dx;
    const idx = @min(drag.current, tabs.len - 1);
    if (!drag.active) return tabs[idx].x;
    const w = tabs[idx].w;
    const hi = @max(layout.clip.right() - w, layout.clip.x);
    return std.math.clamp(x - drag.grab_dx, layout.clip.x, hi);
}

test "win32 tabstrip: metrics scale with dpi" {
    const m = Metrics.forDpi(96);
    try std.testing.expectEqual(@as(i32, 40), m.height);
    try std.testing.expectEqual(@as(i32, 72), m.tab_min_w);
    try std.testing.expectEqual(@as(i32, 4), m.drag_threshold);
    const m2 = Metrics.forDpi(144);
    try std.testing.expectEqual(@as(i32, 60), m2.height);
    try std.testing.expectEqual(@as(i32, 69), m2.caption_btn_w);
}

test "win32 tabstrip: three tabs in 1200 px titlebar" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);

    try layout.compute(alloc, m, 1200, .titlebar, true, 3, 0);
    try std.testing.expectEqual(@as(usize, 3), layout.tabs.items.len);
    try std.testing.expectEqual(@as(i32, 240), layout.tabs.items[0].w);
    try std.testing.expectEqual(@as(i32, 10), layout.tabs.items[0].x);
    try std.testing.expectEqual(@as(i32, 1062), layout.minimize.?.x);
    try std.testing.expectEqual(@as(i32, 1200), layout.close.?.right());
    try std.testing.expectEqual(@as(i32, 730), layout.new_tab.?.x);
    try std.testing.expectEqual(@as(i32, 770), layout.caption.x);
    try std.testing.expectEqual(@as(i32, 1062), layout.caption.right());
}

test "win32 tabstrip: overflow keeps active visible" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);

    try layout.compute(alloc, m, 800, .titlebar, true, 30, 29);
    const t = layout.tabs.items[29];
    try std.testing.expect(t.x >= layout.clip.x and t.right() <= layout.clip.right());
    try std.testing.expectEqual(m.tab_min_w, t.w);
    try std.testing.expectEqual(layout.clip.right(), layout.new_tab.?.x);

    layout.scrollBy(-10000);
    try std.testing.expectEqual(@as(i32, 0), layout.scroll);
    try std.testing.expectEqual(layout.clip.x, layout.tabs.items[0].x);
    layout.scrollBy(100000);
    try std.testing.expectEqual(layout.tabs.items[29].right(), layout.clip.right());

    // Re-layout with a different active tab pulls it back into view.
    try layout.compute(alloc, m, 800, .titlebar, true, 30, 0);
    try std.testing.expectEqual(@as(i32, 0), layout.scroll);

    // Narrow windows: tabs shrink, never overlap new_tab or the buttons.
    for ([_]i32{ 200, 300, 340 }) |w| {
        try layout.compute(alloc, m, w, .titlebar, true, 30, 15);
        for (layout.tabs.items) |r| try std.testing.expect(r.w > 0);
        const a = layout.tabs.items[15];
        try std.testing.expect(a.x >= layout.clip.x and a.right() <= layout.clip.right());
        try std.testing.expect(layout.clip.right() <= layout.new_tab.?.x);
        try std.testing.expect(layout.new_tab.?.right() <= layout.minimize.?.x);
        try std.testing.expectEqual(Part{ .tab = 15 }, layout.hitTest(m, a.x + 1, 20, true));
    }
    // No room at all: new_tab dropped, buttons stay.
    try layout.compute(alloc, m, 100, .titlebar, true, 3, 0);
    try std.testing.expect(layout.new_tab == null);
    try std.testing.expect(layout.close != null);
    try std.testing.expectEqual(Part.close, layout.hitTest(m, 99, 20, true));
}

test "win32 tabstrip: hit test parts" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1200, .titlebar, true, 3, 0);

    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 900, 20, false));
    try std.testing.expectEqual(Part.minimize, layout.hitTest(m, 1070, 20, false));
    try std.testing.expectEqual(Part.maximize, layout.hitTest(m, 1110, 20, false));
    try std.testing.expectEqual(Part.close, layout.hitTest(m, 1190, 20, false));
    try std.testing.expectEqual(Part{ .tab = 1 }, layout.hitTest(m, 300, 20, false));
    try std.testing.expectEqual(Part{ .tab_close = 0 }, layout.hitTest(m, 240, 20, false));
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, 100, 20, false));
    try std.testing.expectEqual(Part.new_tab, layout.hitTest(m, 740, 20, false));
    try std.testing.expectEqual(Part.resize_top, layout.hitTest(m, 300, 2, false));
    try std.testing.expectEqual(Part{ .tab = 1 }, layout.hitTest(m, 300, 2, true));
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 300, 40, false));

    // tabs_only: no caption, no resize band, no buttons.
    try layout.compute(alloc, m, 1200, .tabs_only, true, 3, 0);
    try std.testing.expect(layout.minimize == null);
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 1100, 20, false));
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, 100, 2, false));
}

test "win32 tabstrip: tabs hidden in titlebar mode" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1000, .titlebar, false, 3, 0);

    try std.testing.expectEqual(@as(usize, 0), layout.tabs.items.len);
    try std.testing.expectEqual(@as(i32, 10), layout.title.?.x);
    try std.testing.expectEqual(layout.new_tab.?.x, layout.title.?.right());
    try std.testing.expectEqual(layout.minimize.?.x, layout.new_tab.?.right());
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 100, 20, false));
}

test "win32 tabstrip: narrow tab has no close hit" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    var m = Metrics.forDpi(96);
    m.tab_min_w = 50;
    m.tab_max_w = 50;
    try layout.compute(alloc, m, 800, .tabs_only, true, 2, 0);
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, 55, 20, false));
}

test "win32 tabstrip: drag reorder after threshold" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1200, .titlebar, true, 3, 0);

    // Grab tab 0 at x = 50 (grab_dx 40, the tab starts at 10).
    var drag: Drag = .{ .tab = 0, .start_x = 50, .grab_dx = 40, .current = 0 };
    try std.testing.expect(dragUpdate(&drag, &layout, m, 53) == null);
    try std.testing.expect(!drag.active);
    // Dragged centre = x - 40 + 120; it enters slot 1 (x >= 250) at x = 170.
    try std.testing.expect(dragUpdate(&drag, &layout, m, 160) == null);
    try std.testing.expect(drag.active);
    const a = dragUpdate(&drag, &layout, m, 180).?;
    try std.testing.expectEqual(@as(usize, 0), a.from);
    try std.testing.expectEqual(@as(usize, 1), a.to);
    try std.testing.expect(dragUpdate(&drag, &layout, m, 190) == null);
    const b = dragUpdate(&drag, &layout, m, 420).?;
    try std.testing.expectEqual(@as(usize, 1), b.from);
    try std.testing.expectEqual(@as(usize, 2), b.to);
    // Past the end stays on the last slot.
    try std.testing.expect(dragUpdate(&drag, &layout, m, 5000) == null);
    try std.testing.expectEqual(@as(i32, 10), dragOffset(&drag, &layout, -500));
    try std.testing.expectEqual(layout.clip.right() - 240, dragOffset(&drag, &layout, 5000));
}

test "win32 tabstrip: hidden mode has zero height" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 800, .hidden, true, 3, 0);
    try std.testing.expectEqual(@as(i32, 0), layout.bounds.h);
    try std.testing.expectEqual(@as(usize, 0), layout.tabs.items.len);
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 5, 5, false));
}

fn fakeWidth(_: ?*anyopaque, title: []const u8) i32 {
    return @intCast(title.len * 8);
}

test "win32 tabstrip: trimmed flags from the measure callback" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    // 30 tabs in 800 px: every tab is tab_min_w (72) wide, the title area 72 - 10 - 28 = 34.
    try layout.compute(alloc, m, 800, .titlebar, true, 30, 0);
    try std.testing.expectEqual(@as(i32, 34), titleWidth(m, layout.tabs.items[0].w));

    var titles: [30][]const u8 = @splat("ab");
    titles[1] = "a title that does not fit";
    titles[2] = "abcd"; // 32 px: fits
    titles[3] = "abcde"; // 40 px: does not
    try layout.fillTrimmed(alloc, m, &titles, .{ .func = fakeWidth });
    try std.testing.expectEqual(@as(usize, 30), layout.trimmed.items.len);
    try std.testing.expect(!layout.trimmed.items[0]);
    try std.testing.expect(layout.trimmed.items[1]);
    try std.testing.expect(!layout.trimmed.items[2]);
    try std.testing.expect(layout.trimmed.items[3]);

    // Wide tabs: the same long title fits 240 px less 38.
    try layout.compute(alloc, m, 1200, .titlebar, true, 2, 0);
    var two = [_][]const u8{ "short", "xxxxxxxxxxxxxxxxxxxxxxxxxx" };
    try layout.fillTrimmed(alloc, m, &two, .{ .func = fakeWidth });
    try std.testing.expectEqual(@as(usize, 2), layout.trimmed.items.len);
    try std.testing.expect(!layout.trimmed.items[0]);
    try std.testing.expect(layout.trimmed.items[1]);
}
