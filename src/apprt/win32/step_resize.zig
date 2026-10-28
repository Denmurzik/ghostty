//! `window-step-resize`: an interactive resize (WM_SIZING) snaps the window
//! to whole terminal cells. The padding and any slack of the current size
//! are kept as they are (the same rule as macOS `resizeIncrements`), so the
//! content area always is `n * cell + extra`.
const std = @import("std");
const win32 = @import("win32");

const Window = @import("Window.zig");
const frame_mod = @import("frame.zig");

const RECT = win32.foundation.RECT;

pub const WMSZ_LEFT = 1;
pub const WMSZ_RIGHT = 2;
pub const WMSZ_TOP = 3;
pub const WMSZ_TOPLEFT = 4;
pub const WMSZ_TOPRIGHT = 5;
pub const WMSZ_BOTTOM = 6;
pub const WMSZ_BOTTOMLEFT = 7;
pub const WMSZ_BOTTOMRIGHT = 8;

/// The content size nearest to `proposed` that is a whole number of cells
/// (at least one) plus `extra` (the padding).
pub fn snap(proposed: i32, extra: i32, cell: i32) i32 {
    if (cell <= 0) return proposed;
    const cells = @max(1, @divFloor(proposed - extra + @divFloor(cell, 2), cell));
    return cells * cell + extra;
}

/// Snap `rect` (the proposed window rectangle) in place. `nc` is the
/// non-client size, `extra_*` the padding, `edge` the WMSZ_* edge.
pub fn snapRect(rect: *RECT, edge: usize, nc_w: i32, nc_h: i32, extra_w: i32, extra_h: i32, cell_w: i32, cell_h: i32) void {
    const w = snap(rect.right - rect.left - nc_w, extra_w, cell_w) + nc_w;
    const h = snap(rect.bottom - rect.top - nc_h, extra_h, cell_h) + nc_h;
    switch (edge) {
        WMSZ_LEFT, WMSZ_TOPLEFT, WMSZ_BOTTOMLEFT => rect.left = rect.right - w,
        WMSZ_RIGHT, WMSZ_TOPRIGHT, WMSZ_BOTTOMRIGHT => rect.right = rect.left + w,
        else => {},
    }
    switch (edge) {
        WMSZ_TOP, WMSZ_TOPLEFT, WMSZ_TOPRIGHT => rect.top = rect.bottom - h,
        WMSZ_BOTTOM, WMSZ_BOTTOMLEFT, WMSZ_BOTTOMRIGHT => rect.bottom = rect.top + h,
        else => {},
    }
}

/// The explicit terminal padding (left+right, top+bottom) in pixels, as core
/// scales it: points * dpi / 72, floored.
fn padding(config: anytype, dpi: u32) struct { w: i32, h: i32 } {
    const x = config.@"window-padding-x";
    const y = config.@"window-padding-y";
    return .{
        .w = scalePt(x.top_left, dpi) + scalePt(x.bottom_right, dpi),
        .h = scalePt(y.top_left, dpi) + scalePt(y.bottom_right, dpi),
    };
}

fn scalePt(points: u32, dpi: u32) i32 {
    return @intCast(points * dpi / 72);
}

/// WM_SIZING of a window. Non-null (TRUE) when the rectangle was changed.
pub fn sizing(window: *Window, wparam: usize, lparam: isize) ?win32.foundation.LRESULT {
    if (!window.app.config.@"window-step-resize") return null;
    if (window.kind != .normal) return null;
    const cell = window.cell_size orelse return null;
    if (cell.width == 0 or cell.height == 0) return null;
    const rect: *RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));

    const nc = frame_mod.nonClientSize(window);
    const pad = padding(window.app.config, window.dpi);
    snapRect(
        rect,
        wparam,
        nc.w,
        nc.h,
        pad.w,
        pad.h,
        @intCast(cell.width),
        @intCast(cell.height),
    );
    return 1;
}

test "win32 step resize: snap keeps the remainder and at least one cell" {
    // 10x20 cells, 4 px of padding in the current size.
    try std.testing.expectEqual(@as(i32, 804), snap(803, 4, 10));
    try std.testing.expectEqual(@as(i32, 814), snap(811, 4, 10));
    try std.testing.expectEqual(@as(i32, 794), snap(797, 4, 10));
    try std.testing.expectEqual(@as(i32, 14), snap(3, 4, 10));
    try std.testing.expectEqual(@as(i32, 37), snap(37, 4, 0));
}

test "win32 step resize: the dragged edge moves, the other stays" {
    var r: RECT = .{ .left = 100, .top = 100, .right = 911, .bottom = 650 };
    // content = rect minus nc (10, 40) = 801 x 510; now 804 x 520 -> extra 4 x 0.
    snapRect(&r, WMSZ_BOTTOMRIGHT, 10, 40, 4, 0, 10, 20);
    try std.testing.expectEqual(@as(i32, 100), r.left);
    try std.testing.expectEqual(@as(i32, 100), r.top);
    try std.testing.expectEqual(@as(i32, 914), r.right);
    try std.testing.expectEqual(@as(i32, 660), r.bottom);

    var l: RECT = .{ .left = 95, .top = 100, .right = 911, .bottom = 660 };
    snapRect(&l, WMSZ_LEFT, 10, 40, 4, 0, 10, 20);
    try std.testing.expectEqual(@as(i32, 911), l.right);
    try std.testing.expectEqual(@as(i32, 911 - 814), l.left);
    try std.testing.expectEqual(@as(i32, 660), l.bottom);
}

test "win32 step resize: padding scales like core" {
    try std.testing.expectEqual(@as(i32, 13), scalePt(10, 96));
    try std.testing.expectEqual(@as(i32, 0), scalePt(0, 144));
}
