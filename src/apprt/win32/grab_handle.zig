//! Geometry and visibility rules of the split grab handle. Pure: no window,
//! no timer. Values follow `SurfaceGrabHandle.swift` of the macOS app: an
//! 80 x 12 pt hit area at the top centre of the pane, a full-width reveal
//! band of `max(12 pt, 20 % of the pane height)` and an ellipsis that is
//! dim (0.3) in the band and bright (0.8) on the handle or while dragging.
const std = @import("std");
const configpkg = @import("../../config.zig");
const geom = @import("geom.zig");

/// `drag-handle`: always, auto or never.
pub const Mode = configpkg.Config.DragHandle;

/// Hit area in DIP (macOS `SurfaceGrabHandle.swift:7`).
pub const handle_dip: geom.Size = .{ .w = 80, .h = 12 };

/// Share of the pane height covered by the reveal band.
pub const hover_factor: f32 = 0.2;

/// Duration of the opacity fade in ms (SwiftUI `.easeInOut(duration: 0.15)`).
pub const fade_ms: u32 = 150;

/// Opacity of the ellipsis while the pointer is in the band.
pub const dim_opacity: f32 = 0.3;
/// Opacity of the ellipsis while the handle is hovered or dragged.
pub const bright_opacity: f32 = 0.8;

/// Hit area in pane client px: top centre, clamped to the pane.
pub fn handleRect(pane: geom.Size, dpi: u32) geom.Rect {
    const w = @max(0, @min(geom.scale(handle_dip.w, dpi), pane.w));
    const h = @max(0, @min(geom.scale(handle_dip.h, dpi), pane.h));
    return .{ .x = @divFloor(pane.w - w, 2), .y = 0, .w = w, .h = h };
}

/// Full-width reveal band: `max(handle height, 20 % of the pane height)`,
/// at most the pane height.
pub fn hoverBand(pane: geom.Size, dpi: u32) geom.Rect {
    const share: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(pane.h)) * hover_factor));
    const h = @max(0, @min(@max(geom.scale(handle_dip.h, dpi), share), pane.h));
    return .{ .x = 0, .y = 0, .w = @max(0, pane.w), .h = h };
}

/// Whether the hit area exists (macOS `handleVisible`). `auto` hides it only
/// for a single pane in a fullscreen window; the quick terminal never has
/// one (it takes no split drops either).
pub fn active(mode: Mode, fullscreen: bool, tree_split: bool, quick: bool) bool {
    if (quick) return false;
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => !(fullscreen and !tree_split),
    };
}

/// What the ellipsis shows: nothing, 0.3 or 0.8 opacity.
pub const Ellipsis = enum { hidden, dim, bright };

/// Inputs of `ellipsis`.
pub const Inputs = struct {
    /// The mouse pointer is visible (not hidden by `mouse-hide-while-typing`).
    pointer_visible: bool,
    /// The pointer is over the hit area.
    on_handle: bool,
    /// The pointer is in the reveal band.
    in_band: bool,
    /// A drag from this handle is running.
    dragging: bool,
};

/// macOS `ellipsisVisible` plus its opacity. `always` shows the ellipsis
/// whatever the pointer does; `auto` needs a visible pointer that is over
/// the handle, in the band, or dragging.
pub fn ellipsis(mode: Mode, in: Inputs) Ellipsis {
    const shown = switch (mode) {
        .never => false,
        .always => true,
        .auto => in.pointer_visible and (in.on_handle or in.dragging or in.in_band),
    };
    if (!shown) return .hidden;
    return if (in.on_handle or in.dragging) .bright else .dim;
}

/// Opacity value of an `Ellipsis` level.
pub fn opacityOf(level: Ellipsis) f32 {
    return switch (level) {
        .hidden => 0,
        .dim => dim_opacity,
        .bright => bright_opacity,
    };
}

/// Opacity `t_ms` after a change from `from` to `to`: 150 ms along the
/// ease-in-out curve (cubic bezier 0.42, 0, 0.58, 1) of SwiftUI's `.easeInOut`.
pub fn fade(from: f32, to: f32, t_ms: u32) f32 {
    if (t_ms == 0) return from;
    if (t_ms >= fade_ms) return to;
    const x: f64 = @as(f64, @floatFromInt(t_ms)) / @as(f64, @floatFromInt(fade_ms));
    const p = bezierY(x);
    return from + (to - from) * @as(f32, @floatCast(p));
}

/// y of the unit cubic bezier (0.42, 0, 0.58, 1) at abscissa `x`.
fn bezierY(x: f64) f64 {
    const x1 = 0.42;
    const x2 = 0.58;
    // x(s) is monotonic for x1, x2 in [0, 1]: bisect for s.
    var lo: f64 = 0;
    var hi: f64 = 1;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const mid = (lo + hi) / 2;
        if (bezier(mid, x1, x2) < x) lo = mid else hi = mid;
    }
    return bezier((lo + hi) / 2, 0, 1);
}

fn bezier(s: f64, p1: f64, p2: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

const testing = std.testing;

fn expectRect(want: geom.Rect, got: geom.Rect) !void {
    try testing.expectEqual(want, got);
}

test "win32 grab handle: rect is 80x12 DIP top centre" {
    // 96 dpi: 80 x 12 px in a 400 wide pane.
    try expectRect(.{ .x = 160, .y = 0, .w = 80, .h = 12 }, handleRect(.{ .w = 400, .h = 300 }, 96));
    // 144 dpi: 120 x 18 px in a 601 wide pane (odd remainder floors).
    try expectRect(.{ .x = 240, .y = 0, .w = 120, .h = 18 }, handleRect(.{ .w = 601, .h = 300 }, 144));
}

test "win32 grab handle: rect clamps to a narrow pane" {
    try expectRect(.{ .x = 0, .y = 0, .w = 50, .h = 12 }, handleRect(.{ .w = 50, .h = 300 }, 96));
    try expectRect(.{ .x = 0, .y = 0, .w = 80, .h = 8 }, handleRect(.{ .w = 80, .h = 8 }, 96));
    try expectRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, handleRect(.{ .w = 0, .h = 0 }, 96));
}

test "win32 grab handle: hover band is 20 % with a 12 DIP floor and pane-height cap" {
    // 20 % of 500 = 100.
    try expectRect(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, hoverBand(.{ .w = 400, .h = 500 }, 96));
    // 20 % of 40 = 8 < 12: the floor wins.
    try expectRect(.{ .x = 0, .y = 0, .w = 400, .h = 12 }, hoverBand(.{ .w = 400, .h = 40 }, 96));
    // The floor scales: 18 px at 144 dpi.
    try expectRect(.{ .x = 0, .y = 0, .w = 400, .h = 18 }, hoverBand(.{ .w = 400, .h = 40 }, 144));
    // Never taller than the pane.
    try expectRect(.{ .x = 0, .y = 0, .w = 400, .h = 8 }, hoverBand(.{ .w = 400, .h = 8 }, 96));
}

test "win32 grab handle: auto: active unless fullscreen with one pane" {
    try testing.expect(active(.auto, false, false, false));
    try testing.expect(active(.auto, false, true, false));
    try testing.expect(active(.auto, true, true, false));
    try testing.expect(!active(.auto, true, false, false));
    try testing.expect(active(.always, true, false, false));
}

test "win32 grab handle: never: inactive" {
    try testing.expect(!active(.never, false, true, false));
    try testing.expect(!active(.never, true, true, false));
}

test "win32 grab handle: quick terminal: inactive" {
    try testing.expect(!active(.always, false, true, true));
    try testing.expect(!active(.auto, false, true, true));
}

test "win32 grab handle: ellipsis: auto hides with hidden pointer, bright on handle, dim in band, bright while dragging" {
    const idle: Inputs = .{ .pointer_visible = true, .on_handle = false, .in_band = false, .dragging = false };
    try testing.expectEqual(Ellipsis.hidden, ellipsis(.auto, idle));

    var in = idle;
    in.in_band = true;
    try testing.expectEqual(Ellipsis.dim, ellipsis(.auto, in));
    in.pointer_visible = false;
    try testing.expectEqual(Ellipsis.hidden, ellipsis(.auto, in));

    in = idle;
    in.on_handle = true;
    in.in_band = true;
    try testing.expectEqual(Ellipsis.bright, ellipsis(.auto, in));
    in.pointer_visible = false;
    try testing.expectEqual(Ellipsis.hidden, ellipsis(.auto, in));

    in = idle;
    in.dragging = true;
    try testing.expectEqual(Ellipsis.bright, ellipsis(.auto, in));

    try testing.expectEqual(Ellipsis.hidden, ellipsis(.never, .{ .pointer_visible = true, .on_handle = true, .in_band = true, .dragging = true }));
}

test "win32 grab handle: always: dim even with hidden pointer" {
    const hidden: Inputs = .{ .pointer_visible = false, .on_handle = false, .in_band = false, .dragging = false };
    try testing.expectEqual(Ellipsis.dim, ellipsis(.always, hidden));
    var in = hidden;
    in.on_handle = true;
    try testing.expectEqual(Ellipsis.bright, ellipsis(.always, in));
    try testing.expectEqual(@as(f32, 0.3), opacityOf(.dim));
    try testing.expectEqual(@as(f32, 0.8), opacityOf(.bright));
    try testing.expectEqual(@as(f32, 0), opacityOf(.hidden));
}

test "win32 grab handle: fade: 0 at start, target at 150 ms, monotonic" {
    try testing.expectEqual(@as(f32, 0), fade(0, 0.8, 0));
    try testing.expectEqual(@as(f32, 0.8), fade(0, 0.8, 150));
    try testing.expectEqual(@as(f32, 0.8), fade(0, 0.8, 900));
    try testing.expectEqual(@as(f32, 0.3), fade(0.8, 0.3, 150));
    // Ease-in-out is symmetric around the midpoint.
    try testing.expectApproxEqAbs(@as(f32, 0.4), fade(0, 0.8, 75), 0.001);

    var prev: f32 = 0;
    var t: u32 = 0;
    while (t <= 150) : (t += 1) {
        const v = fade(0, 0.8, t);
        try testing.expect(v >= prev);
        try testing.expect(v >= 0 and v <= 0.8);
        prev = v;
    }
    // Fading out is monotonic downwards.
    prev = 0.8;
    t = 0;
    while (t <= 150) : (t += 1) {
        const v = fade(0.8, 0, t);
        try testing.expect(v <= prev);
        prev = v;
    }
    // Slow start, fast middle: ease-in at 10 %.
    try testing.expect(fade(0, 1, 15) < 0.1);
}
