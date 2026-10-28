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
/// (at least one) plus the `current` size's remainder.
pub fn snap(proposed: i32, current: i32, cell: i32) i32 {
    if (cell <= 0) return proposed;
    const extra = @mod(@max(current, 0), cell);
    const cells = @max(1, @divFloor(proposed - extra + @divFloor(cell, 2), cell));
    return cells * cell + extra;
}

/// Snap `rect` (the proposed window rectangle) in place. `nc` is the
/// non-client size, `current` the content size now, `edge` the WMSZ_* edge.
pub fn snapRect(rect: *RECT, edge: usize, nc_w: i32, nc_h: i32, cur_w: i32, cur_h: i32, cell_w: i32, cell_h: i32) void {
    const w = snap(rect.right - rect.left - nc_w, cur_w, cell_w) + nc_w;
    const h = snap(rect.bottom - rect.top - nc_h, cur_h, cell_h) + nc_h;
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

/// WM_SIZING of a window. Non-null (TRUE) when the rectangle was changed.
pub fn sizing(window: *Window, wparam: usize, lparam: isize) ?win32.foundation.LRESULT {
    if (!window.app.config.@"window-step-resize") return null;
    if (window.kind != .normal) return null;
    const cell = window.cell_size orelse return null;
    if (cell.width == 0 or cell.height == 0) return null;
    const rect: *RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));

    var now: RECT = undefined;
    if (win32.user32.GetWindowRect(window.hwnd, &now) == 0) return null;
    const nc = frame_mod.nonClientSize(window);
    snapRect(
        rect,
        wparam,
        nc.w,
        nc.h,
        now.right - now.left - nc.w,
        now.bottom - now.top - nc.h,
        @intCast(cell.width),
        @intCast(cell.height),
    );
    return 1;
}

test "win32 step resize: snap keeps the remainder and at least one cell" {
    // 10x20 cells, 4 px of padding in the current size.
    try std.testing.expectEqual(@as(i32, 804), snap(803, 804, 10));
    try std.testing.expectEqual(@as(i32, 814), snap(811, 804, 10));
    try std.testing.expectEqual(@as(i32, 794), snap(797, 804, 10));
    try std.testing.expectEqual(@as(i32, 14), snap(3, 804, 10));
    try std.testing.expectEqual(@as(i32, 37), snap(37, 804, 0));
}

test "win32 step resize: the dragged edge moves, the other stays" {
    var r: RECT = .{ .left = 100, .top = 100, .right = 911, .bottom = 650 };
    // content = rect minus nc (10, 40) = 801 x 510; now 804 x 520 -> extra 4 x 0.
    snapRect(&r, WMSZ_BOTTOMRIGHT, 10, 40, 804, 520, 10, 20);
    try std.testing.expectEqual(@as(i32, 100), r.left);
    try std.testing.expectEqual(@as(i32, 100), r.top);
    try std.testing.expectEqual(@as(i32, 914), r.right);
    try std.testing.expectEqual(@as(i32, 660), r.bottom);

    var l: RECT = .{ .left = 95, .top = 100, .right = 911, .bottom = 660 };
    snapRect(&l, WMSZ_LEFT, 10, 40, 804, 520, 10, 20);
    try std.testing.expectEqual(@as(i32, 911), l.right);
    try std.testing.expectEqual(@as(i32, 911 - 814), l.left);
    try std.testing.expectEqual(@as(i32, 660), l.bottom);
}
