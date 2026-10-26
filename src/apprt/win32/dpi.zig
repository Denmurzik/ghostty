//! DPI helpers for the Win32 apprt.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const geom = @import("geom.zig");

/// The DPI Windows reports for a 100% scale display.
pub const default_dpi: u32 = 96;

/// The content scale for a window DPI. A DPI of zero (reported for an
/// invalid window) is treated as the default.
pub fn contentScale(dpi: u32) apprt.ContentScale {
    const effective = if (dpi == 0) default_dpi else dpi;
    const scale: f32 = @as(f32, @floatFromInt(effective)) / @as(f32, @floatFromInt(default_dpi));
    return .{ .x = scale, .y = scale };
}

test "win32 dpi: content scale" {
    try std.testing.expectEqual(@as(f32, 1.0), contentScale(96).x);
    try std.testing.expectEqual(@as(f32, 1.25), contentScale(120).x);
    try std.testing.expectEqual(@as(f32, 1.5), contentScale(144).y);
    try std.testing.expectEqual(@as(f32, 1.0), contentScale(0).x);
}

/// `rect` moved to `new_dpi` without a system suggestion: the top-left
/// stays, the size follows the scale ratio.
pub fn scaledWindowRect(rect: geom.Rect, old_dpi: u32, new_dpi: u32) geom.Rect {
    const old: i64 = if (old_dpi == 0) default_dpi else old_dpi;
    const new: i64 = if (new_dpi == 0) default_dpi else new_dpi;
    return .{
        .x = rect.x,
        .y = rect.y,
        .w = @intCast(@divFloor(@as(i64, rect.w) * new + @divFloor(old, 2), old)),
        .h = @intCast(@divFloor(@as(i64, rect.h) * new + @divFloor(old, 2), old)),
    };
}

test "win32 dpi: scaled window rect" {
    const r = scaledWindowRect(.{ .x = 100, .y = 100, .w = 800, .h = 600 }, 96, 144);
    try std.testing.expectEqual(geom.Rect{ .x = 100, .y = 100, .w = 1200, .h = 900 }, r);
    const back = scaledWindowRect(r, 144, 96);
    try std.testing.expectEqual(geom.Rect{ .x = 100, .y = 100, .w = 800, .h = 600 }, back);
}

test "win32 dpi: content scale for 120/144/192" {
    try std.testing.expectEqual(@as(f32, 1.25), contentScale(120).x);
    try std.testing.expectEqual(@as(f32, 1.5), contentScale(144).x);
    try std.testing.expectEqual(@as(f32, 2.0), contentScale(192).y);
}
