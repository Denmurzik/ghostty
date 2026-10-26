//! The tab strip model: geometry and hit testing, no drawing. Stub: Task 10.
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
            .height = geom.scale(36, dpi),
            .tab_min_w = geom.scale(100, dpi),
            .tab_max_w = geom.scale(240, dpi),
            .tab_pad = geom.scale(12, dpi),
            .close_w = geom.scale(28, dpi),
            .new_tab_w = geom.scale(36, dpi),
            .caption_btn_w = geom.scale(46, dpi),
            .min_drag_w = geom.scale(48, dpi),
            .resize_band = geom.scale(4, dpi),
            .drag_threshold = geom.scale(6, dpi),
        };
    }
};

pub const Layout = struct {
    mode: Mode = .hidden,
    show_tabs: bool = false,
    bounds: geom.Rect = .{},
    tabs: std.ArrayList(geom.Rect) = .empty,
    new_tab: ?geom.Rect = null,
    minimize: ?geom.Rect = null,
    maximize: ?geom.Rect = null,
    close: ?geom.Rect = null,
    caption: geom.Rect = .{},
    title: ?geom.Rect = null,
    clip: geom.Rect = .{},
    scroll: i32 = 0,

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
        _ = alloc;
        _ = show_tabs;
        _ = count;
        _ = active;
        self.mode = mode;
        self.bounds = .{ .x = 0, .y = 0, .w = width, .h = if (mode == .hidden) 0 else m.height };
    }

    pub fn hitTest(self: *const Layout, m: Metrics, x: i32, y: i32, maximized: bool) Part {
        _ = self;
        _ = m;
        _ = x;
        _ = y;
        _ = maximized;
        return .nowhere;
    }

    pub fn deinit(self: *Layout, alloc: Allocator) void {
        self.tabs.deinit(alloc);
    }
};

pub const Drag = struct {
    tab: usize,
    start_x: i32,
    grab_dx: i32,
    active: bool = false,
    current: usize,
};

test "win32 tabstrip: stub compute sizes the bounds only" {
    const alloc = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(alloc);
    const m = Metrics.forDpi(96);

    try layout.compute(alloc, m, 800, .tabs_only, true, 3, 0);
    try std.testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 800, .h = m.height }, layout.bounds);
    try layout.compute(alloc, m, 800, .hidden, false, 1, 0);
    try std.testing.expectEqual(@as(i32, 0), layout.bounds.h);
    try std.testing.expectEqual(Part.nowhere, layout.hitTest(m, 5, 5, false));
}
