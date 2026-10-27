//! The tab strip model: geometry and hit testing, no drawing.
//!
//! Two rows as in Ghostty for macOS (titlebar tabs): the title row (proxy
//! icon and window title centred, the caption buttons on the right) and
//! below it the tab row, present only while tabs are listed.
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
    proxy_icon,
    minimize,
    maximize,
    close,
};

pub const Metrics = struct {
    /// The title row (titlebar mode only).
    title_h: i32,
    /// The tab row.
    tab_h: i32,
    /// Gap between the tab row's edge and the track above/below it.
    track_inset: i32,
    /// Gap between the track and a tab's pill.
    pill_inset: i32,
    /// Margin of the tab row at its sides, and its gap to the new-tab button.
    row_pad: i32,
    new_tab_d: i32,
    tab_min_w: i32,
    tab_pad: i32,
    close_w: i32,
    caption_btn_w: i32,
    icon_size: i32,
    icon_gap: i32,
    resize_band: i32,
    drag_threshold: i32,

    pub fn forDpi(dpi: u32) Metrics {
        return .{
            .title_h = geom.scale(30, dpi),
            .tab_h = geom.scale(36, dpi),
            .track_inset = geom.scale(4, dpi),
            .pill_inset = geom.scale(2, dpi),
            .row_pad = geom.scale(8, dpi),
            .new_tab_d = geom.scale(28, dpi),
            .tab_min_w = geom.scale(72, dpi),
            .tab_pad = geom.scale(10, dpi),
            .close_w = geom.scale(28, dpi),
            .caption_btn_w = geom.scale(46, dpi),
            .icon_size = geom.scale(16, dpi),
            .icon_gap = geom.scale(5, dpi),
            .resize_band = geom.scale(6, dpi),
            .drag_threshold = geom.scale(4, dpi),
        };
    }
};

/// The height of the strip: the title row (titlebar mode) plus the tab row
/// (when tabs are listed).
pub fn height(m: Metrics, mode: Mode, show_tabs: bool) i32 {
    if (mode == .hidden) return 0;
    return (if (mode == .titlebar) m.title_h else 0) + (if (show_tabs) m.tab_h else 0);
}

/// What the painter knows about titles: the width of a title as painted and
/// the width of the title area of tab `index` (so the geometry stays the
/// painter's).
pub const Measure = struct {
    ctx: ?*anyopaque = null,
    width_fn: *const fn (ctx: ?*anyopaque, title: []const u8) i32,
    area_fn: *const fn (ctx: ?*anyopaque, tab: geom.Rect, index: usize) i32,
};

pub const Layout = struct {
    mode: Mode = .hidden,
    show_tabs: bool = false,
    bounds: geom.Rect = .{},
    /// The rows; empty when absent.
    title_row: geom.Rect = .{},
    tab_row: geom.Rect = .{},
    /// Tab rects in strip coordinates, already shifted by `scroll`; each
    /// spans the track's height.
    tabs: std.ArrayList(geom.Rect) = .empty,
    new_tab: ?geom.Rect = null,
    minimize: ?geom.Rect = null,
    maximize: ?geom.Rect = null,
    close: ?geom.Rect = null,
    /// The part of the title row that drags the window.
    caption: geom.Rect = .{},
    /// The title row's free area (left of the caption buttons); the title
    /// is centred in it by `placeTitle`.
    title: ?geom.Rect = null,
    proxy_icon: ?geom.Rect = null,
    title_text: geom.Rect = .{},
    /// The capsule behind the tabs.
    track: geom.Rect = .{},
    /// Where tabs are visible (the track); tabs are clipped to this.
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
        self.proxy_icon = null;
        self.title_text = .{};
        self.clip = .{};
        self.track = .{};
        self.caption = .{};
        self.title_row = .{};
        self.tab_row = .{};

        if (mode == .hidden) {
            self.bounds = .{ .x = 0, .y = 0, .w = width, .h = 0 };
            self.scroll = 0;
            return;
        }
        const title_h: i32 = if (mode == .titlebar) m.title_h else 0;
        const row_h: i32 = if (show_tabs) m.tab_h else 0;
        self.bounds = .{ .x = 0, .y = 0, .w = width, .h = title_h + row_h };

        // The title row: caption buttons (close rightmost), the rest drags.
        if (mode == .titlebar) {
            const h = m.title_h;
            self.title_row = .{ .x = 0, .y = 0, .w = width, .h = h };
            const bx = width - 3 * m.caption_btn_w;
            self.minimize = .{ .x = bx, .y = 0, .w = m.caption_btn_w, .h = h };
            self.maximize = .{ .x = bx + m.caption_btn_w, .y = 0, .w = m.caption_btn_w, .h = h };
            self.close = .{ .x = bx + 2 * m.caption_btn_w, .y = 0, .w = m.caption_btn_w, .h = h };
            self.caption = .{ .x = 0, .y = 0, .w = @max(bx, 0), .h = h };
            self.title = .{ .x = m.row_pad, .y = 0, .w = @max(bx - m.row_pad, 0), .h = h };
        }

        if (!show_tabs) {
            self.scroll = 0;
            return;
        }

        const row_y = title_h;
        self.tab_row = .{ .x = 0, .y = row_y, .w = width, .h = m.tab_h };
        const track_h = m.tab_h - 2 * m.track_inset;
        const track_y = row_y + m.track_inset;

        // Narrow windows: the new-tab button is dropped before the tabs
        // shrink below `tab_min_w`.
        const inner = width - 2 * m.row_pad;
        const keep_new_tab = inner - m.new_tab_d - m.row_pad >= m.tab_min_w;
        const track_w = @max(if (keep_new_tab) inner - m.new_tab_d - m.row_pad else inner, 0);
        if (keep_new_tab) {
            self.new_tab = .{
                .x = width - m.row_pad - m.new_tab_d,
                .y = row_y + @divTrunc(m.tab_h - m.new_tab_d, 2),
                .w = m.new_tab_d,
                .h = m.new_tab_d,
            };
        }
        self.track = .{ .x = m.row_pad, .y = track_y, .w = track_w, .h = track_h };
        self.clip = self.track;

        const n: i32 = @intCast(@min(count, std.math.maxInt(i32) / @max(m.tab_min_w, 1)));
        const scrolling = n > 0 and @divTrunc(track_w, n) < m.tab_min_w and track_w >= m.tab_min_w;
        const tab_w = if (scrolling) m.tab_min_w else @divTrunc(track_w, @max(n, 1));
        const total = if (scrolling) tab_w * n else track_w;
        const overflow = @max(total - track_w, 0);

        if (overflow == 0) {
            self.scroll = 0;
        } else {
            var sc = std.math.clamp(self.scroll, 0, overflow);
            if (active < count) {
                const left = tab_w * @as(i32, @intCast(active));
                if (left < sc) sc = left;
                if (left + tab_w > sc + track_w) sc = left + tab_w - track_w;
            }
            self.scroll = std.math.clamp(sc, 0, overflow);
        }

        try self.tabs.ensureTotalCapacity(alloc, count);
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            // Equal slots that tile the track exactly: the rounding is
            // spread over the tabs, not left at the end.
            const x0 = if (scrolling) i * tab_w else @divTrunc(i * track_w, n);
            const x1 = if (scrolling) (i + 1) * tab_w else @divTrunc((i + 1) * track_w, n);
            self.tabs.appendAssumeCapacity(.{
                .x = self.track.x + x0 - self.scroll,
                .y = track_y,
                .w = x1 - x0,
                .h = track_h,
            });
        }
    }

    /// Centres the proxy icon (when `icon`) and a title `text_w` px wide in
    /// the title row, on the window; a title that does not fit is cut.
    pub fn placeTitle(self: *Layout, m: Metrics, text_w: i32, icon: bool) void {
        self.proxy_icon = null;
        self.title_text = .{};
        const area = self.title orelse return;
        const lead: i32 = if (icon) m.icon_size + (if (text_w > 0) m.icon_gap else 0) else 0;
        const gw = @min(lead + text_w, area.w);
        if (gw <= 0) return;
        const x = std.math.clamp(@divTrunc(self.bounds.w - gw, 2), area.x, @max(area.right() - gw, area.x));
        if (icon) self.proxy_icon = .{
            .x = x,
            .y = @divTrunc(m.title_h - m.icon_size, 2),
            .w = m.icon_size,
            .h = m.icon_size,
        };
        self.title_text = .{ .x = x + lead, .y = 0, .w = @max(gw - lead, 0), .h = m.title_h };
    }

    pub fn hitTest(self: *const Layout, m: Metrics, x: i32, y: i32, maximized: bool) Part {
        if (self.mode == .hidden or !self.bounds.contains(x, y)) return .nowhere;
        if (self.mode == .titlebar and !maximized and y < m.resize_band) return .resize_top;

        if (self.close) |r| if (r.contains(x, y)) return .close;
        if (self.maximize) |r| if (r.contains(x, y)) return .maximize;
        if (self.minimize) |r| if (r.contains(x, y)) return .minimize;
        if (self.proxy_icon) |r| if (r.contains(x, y)) return .proxy_icon;
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

    /// Whether `title` does not fit the title area of tab `index`.
    pub fn tabTrimmed(self: *const Layout, index: usize, title: []const u8, measure: Measure) bool {
        if (index >= self.tabs.items.len) return false;
        const area = measure.area_fn(measure.ctx, self.tabs.items[index], index);
        return measure.width_fn(measure.ctx, title) > area;
    }

    /// Sets `trimmed` from `tabTrimmed`, `titles` having one title per tab.
    pub fn fillTrimmed(
        self: *Layout,
        alloc: Allocator,
        titles: []const []const u8,
        measure: Measure,
    ) !void {
        self.trimmed.clearRetainingCapacity();
        try self.trimmed.ensureTotalCapacity(alloc, self.tabs.items.len);
        for (0..self.tabs.items.len) |i| {
            self.trimmed.appendAssumeCapacity(i < titles.len and self.tabTrimmed(i, titles[i], measure));
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
    try std.testing.expectEqual(@as(i32, 30), m.title_h);
    try std.testing.expectEqual(@as(i32, 36), m.tab_h);
    try std.testing.expectEqual(@as(i32, 72), m.tab_min_w);
    try std.testing.expectEqual(@as(i32, 4), m.drag_threshold);
    const m2 = Metrics.forDpi(144);
    try std.testing.expectEqual(@as(i32, 45), m2.title_h);
    try std.testing.expectEqual(@as(i32, 69), m2.caption_btn_w);
}

test "win32 tabstrip: strip height is the rows present" {
    const m = Metrics.forDpi(96);
    try std.testing.expectEqual(@as(i32, 0), height(m, .hidden, true));
    try std.testing.expectEqual(@as(i32, 30), height(m, .titlebar, false));
    try std.testing.expectEqual(@as(i32, 66), height(m, .titlebar, true));
    try std.testing.expectEqual(@as(i32, 36), height(m, .tabs_only, true));
}

test "win32 tabstrip: two rows, equal tabs fill the track" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);

    try layout.compute(alloc, m, 1200, .titlebar, true, 3, 0);
    try std.testing.expectEqual(@as(i32, 66), layout.bounds.h);
    try std.testing.expectEqual(@as(i32, 30), layout.title_row.h);
    try std.testing.expectEqual(@as(i32, 30), layout.tab_row.y);
    try std.testing.expectEqual(@as(usize, 3), layout.tabs.items.len);
    // Caption buttons in the title row, close rightmost.
    try std.testing.expectEqual(@as(i32, 1062), layout.minimize.?.x);
    try std.testing.expectEqual(@as(i32, 1200), layout.close.?.right());
    try std.testing.expectEqual(@as(i32, 0), layout.close.?.y);
    try std.testing.expectEqual(@as(i32, 30), layout.close.?.h);
    // The new-tab button is round, at the far right of the tab row.
    try std.testing.expectEqual(@as(i32, 1164), layout.new_tab.?.x);
    try std.testing.expectEqual(@as(i32, 28), layout.new_tab.?.w);
    try std.testing.expectEqual(layout.new_tab.?.w, layout.new_tab.?.h);
    try std.testing.expectEqual(@as(i32, 1200 - 8), layout.new_tab.?.right());
    // The tabs tile the track exactly, on the tab row.
    try std.testing.expectEqual(layout.track.x, layout.tabs.items[0].x);
    try std.testing.expectEqual(layout.track.right(), layout.tabs.items[2].right());
    try std.testing.expectEqual(layout.tabs.items[0].right(), layout.tabs.items[1].x);
    try std.testing.expectEqual(layout.tabs.items[1].right(), layout.tabs.items[2].x);
    for (layout.tabs.items) |r| {
        try std.testing.expect(r.y >= layout.tab_row.y and r.bottom() <= layout.tab_row.bottom());
        try std.testing.expect(@abs(r.w - 382) <= 1);
    }
}

test "win32 tabstrip: one tab leaves only the title row" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1000, .titlebar, false, 1, 0);

    try std.testing.expectEqual(@as(i32, 30), layout.bounds.h);
    try std.testing.expectEqual(@as(usize, 0), layout.tabs.items.len);
    try std.testing.expect(layout.new_tab == null);
    try std.testing.expectEqual(@as(i32, 0), layout.tab_row.h);
    try std.testing.expectEqual(layout.minimize.?.x, layout.title.?.right());
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 100, 20, false));
}

test "win32 tabstrip: title and proxy icon centred on the window" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1000, .titlebar, false, 1, 0);

    layout.placeTitle(m, 100, true);
    const icon = layout.proxy_icon.?;
    const text = layout.title_text;
    // The group (16 + 5 + 100) is centred: (1000 - 121) / 2 = 439.
    try std.testing.expectEqual(@as(i32, 439), icon.x);
    try std.testing.expectEqual(@as(i32, 460), text.x);
    try std.testing.expectEqual(@as(i32, 100), text.w);
    try std.testing.expectEqual(@as(i32, 7), icon.y);
    try std.testing.expectEqual(Part.proxy_icon, layout.hitTest(m, icon.x + 2, icon.y + 2, false));
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, text.x + 2, 15, false));

    // No icon: the text alone is centred.
    layout.placeTitle(m, 100, false);
    try std.testing.expect(layout.proxy_icon == null);
    try std.testing.expectEqual(@as(i32, 450), layout.title_text.x);

    // A title wider than the free area is cut to it, clear of the buttons.
    layout.placeTitle(m, 5000, true);
    try std.testing.expect(layout.title_text.right() <= layout.minimize.?.x);
    try std.testing.expect(layout.proxy_icon.?.x >= m.row_pad);

    // Without a title the icon sits centred alone.
    layout.placeTitle(m, 0, true);
    try std.testing.expectEqual(@as(i32, 492), layout.proxy_icon.?.x);
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
    try std.testing.expect(layout.clip.right() < layout.new_tab.?.x);

    layout.scrollBy(-10000);
    try std.testing.expectEqual(@as(i32, 0), layout.scroll);
    try std.testing.expectEqual(layout.clip.x, layout.tabs.items[0].x);
    layout.scrollBy(100000);
    try std.testing.expectEqual(layout.tabs.items[29].right(), layout.clip.right());

    // Re-layout with a different active tab pulls it back into view.
    try layout.compute(alloc, m, 800, .titlebar, true, 30, 0);
    try std.testing.expectEqual(@as(i32, 0), layout.scroll);

    // Narrow windows: tabs shrink, never overlap the new-tab button.
    for ([_]i32{ 200, 300, 340 }) |w| {
        try layout.compute(alloc, m, w, .titlebar, true, 30, 15);
        for (layout.tabs.items) |r| try std.testing.expect(r.w > 0);
        const a = layout.tabs.items[15];
        try std.testing.expect(a.x >= layout.clip.x and a.right() <= layout.clip.right());
        if (layout.new_tab) |nt| try std.testing.expect(layout.clip.right() <= nt.x);
        try std.testing.expectEqual(Part{ .tab = 15 }, layout.hitTest(m, a.x + 1, a.y + 5, true));
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

    const y_tab: i32 = 48;
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 900, 15, false));
    try std.testing.expectEqual(Part.minimize, layout.hitTest(m, 1070, 15, false));
    try std.testing.expectEqual(Part.maximize, layout.hitTest(m, 1110, 15, false));
    try std.testing.expectEqual(Part.close, layout.hitTest(m, 1190, 15, false));
    try std.testing.expectEqual(Part{ .tab = 1 }, layout.hitTest(m, 600, y_tab, false));
    try std.testing.expectEqual(Part{ .tab_close = 0 }, layout.hitTest(m, layout.tabs.items[0].right() - 5, y_tab, false));
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, 100, y_tab, false));
    try std.testing.expectEqual(Part.new_tab, layout.hitTest(m, 1175, y_tab, false));
    try std.testing.expectEqual(Part.resize_top, layout.hitTest(m, 300, 2, false));
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 300, 2, true));
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 300, 66, false));
    // The margin of the tab row drags the window.
    try std.testing.expectEqual(Part.caption, layout.hitTest(m, 3, y_tab, false));

    // tabs_only: no title row, no caption, no resize band, no buttons.
    try layout.compute(alloc, m, 1200, .tabs_only, true, 3, 0);
    try std.testing.expect(layout.minimize == null);
    try std.testing.expectEqual(@as(i32, 36), layout.bounds.h);
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 3, 18, false));
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, 100, 18, false));
}

test "win32 tabstrip: narrow tab has no close hit" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    var m = Metrics.forDpi(96);
    m.tab_min_w = 50;
    try layout.compute(alloc, m, 130, .tabs_only, true, 2, 0);
    // Two 50 px tabs in a 114 px track (new-tab dropped or kept, the tabs are narrow).
    const r = layout.tabs.items[0];
    try std.testing.expect(r.w < 2 * m.close_w);
    try std.testing.expectEqual(Part{ .tab = 0 }, layout.hitTest(m, r.right() - 2, r.y + 5, false));
}

test "win32 tabstrip: drag reorder after threshold" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    try layout.compute(alloc, m, 1200, .titlebar, true, 3, 0);
    const w = layout.tabs.items[0].w;

    // Grab tab 0 at its middle.
    var drag: Drag = .{ .tab = 0, .start_x = 200, .grab_dx = 190, .current = 0 };
    try std.testing.expect(dragUpdate(&drag, &layout, m, 203) == null);
    try std.testing.expect(!drag.active);
    try std.testing.expect(dragUpdate(&drag, &layout, m, 260) == null);
    try std.testing.expect(drag.active);
    // The dragged centre enters slot 1 once it passes the first slot's end.
    const a = dragUpdate(&drag, &layout, m, w + 20 + 190 - @divTrunc(w, 2)).?;
    try std.testing.expectEqual(@as(usize, 0), a.from);
    try std.testing.expectEqual(@as(usize, 1), a.to);
    try std.testing.expect(dragUpdate(&drag, &layout, m, w + 30 + 190 - @divTrunc(w, 2)) == null);
    // Past the end stays on the last slot.
    const b = dragUpdate(&drag, &layout, m, 5000).?;
    try std.testing.expectEqual(@as(usize, 1), b.from);
    try std.testing.expectEqual(@as(usize, 2), b.to);
    try std.testing.expect(dragUpdate(&drag, &layout, m, 5000) == null);
    try std.testing.expectEqual(layout.clip.x, dragOffset(&drag, &layout, -500));
    try std.testing.expectEqual(layout.clip.right() - layout.tabs.items[2].w, dragOffset(&drag, &layout, 5000));
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

/// A title area for the tests: the tab less 38 px (the padding and the close button of a narrow tab).
fn fakeArea(_: ?*anyopaque, tab: geom.Rect, _: usize) i32 {
    return @max(tab.w - 38, 0);
}

const fake_measure: Measure = .{ .width_fn = fakeWidth, .area_fn = fakeArea };

test "win32 tabstrip: trimmed flags from the measure callback" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);
    // 30 tabs in 800 px: every tab is tab_min_w (72) wide, the title area 34.
    try layout.compute(alloc, m, 800, .titlebar, true, 30, 0);
    try std.testing.expectEqual(@as(i32, 34), fakeArea(null, layout.tabs.items[0], 0));

    var titles: [30][]const u8 = @splat("");
    titles[1] = "a title that does not fit";
    titles[2] = "abcd"; // 32 px: fits
    titles[3] = "abcde"; // 40 px: does not
    try layout.fillTrimmed(alloc, &titles, fake_measure);
    try std.testing.expectEqual(@as(usize, 30), layout.trimmed.items.len);
    try std.testing.expect(!layout.trimmed.items[0]);
    try std.testing.expect(layout.trimmed.items[1]);
    try std.testing.expect(!layout.trimmed.items[2]);
    try std.testing.expect(layout.trimmed.items[3]);

    // Wide tabs: the same long title fits 38 px less than the tab.
    try layout.compute(alloc, m, 600, .titlebar, true, 2, 0);
    var two = [_][]const u8{ "short", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" };
    try layout.fillTrimmed(alloc, &two, fake_measure);
    try std.testing.expect(layout.tabTrimmed(1, two[1], fake_measure));
    try std.testing.expect(!layout.tabTrimmed(0, two[0], fake_measure));
    try std.testing.expect(!layout.tabTrimmed(9, two[1], fake_measure));
    try std.testing.expectEqual(@as(usize, 2), layout.trimmed.items.len);
    try std.testing.expect(!layout.trimmed.items[0]);
    try std.testing.expect(layout.trimmed.items[1]);
}
