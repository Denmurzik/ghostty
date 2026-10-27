//! Integer rectangles and DPI scaling shared by the window chrome code.
const std = @import("std");
const win32 = @import("win32");

/// Scale a 96-DPI value to `dpi`, rounding to nearest.
pub fn scale(v: i32, dpi: u32) i32 {
    const num = @as(i64, v) * @as(i64, dpi);
    return @intCast(@divFloor(num + 48, 96));
}

const scaleDpi = scale;

pub const Size = struct { w: i32, h: i32 };
pub const Point = struct { x: i32, y: i32 };

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    /// Whether the point is inside; the right and bottom edges are outside.
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.right() and py >= r.y and py < r.bottom();
    }

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    pub fn fromRECT(rc: win32.foundation.RECT) Rect {
        return .{ .x = rc.left, .y = rc.top, .w = rc.right - rc.left, .h = rc.bottom - rc.top };
    }

    pub fn toRECT(r: Rect) win32.foundation.RECT {
        return .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.bottom() };
    }

    /// Same as the module-level `scale`.
    pub fn scale(v: i32, dpi: u32) i32 {
        return scaleDpi(v, dpi);
    }
};

test "win32 geom: rect contains and scale" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    try std.testing.expect(r.contains(10, 10));
    try std.testing.expect(!r.contains(30, 30));
    try std.testing.expect(!r.contains(9, 15));
    try std.testing.expectEqual(@as(i32, 30), r.right());
    try std.testing.expectEqual(@as(i32, 30), r.bottom());

    try std.testing.expectEqual(@as(i32, 60), scale(40, 144));
    try std.testing.expectEqual(@as(i32, 60), Rect.scale(40, 144));
    try std.testing.expectEqual(@as(i32, 1), scale(1, 120));
    try std.testing.expectEqual(@as(i32, 40), scale(40, 96));

    try std.testing.expectEqual(r, Rect.fromRECT(r.toRECT()));
}
