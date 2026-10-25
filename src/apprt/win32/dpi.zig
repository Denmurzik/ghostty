//! DPI helpers for the Win32 apprt.
const std = @import("std");
const apprt = @import("../../apprt.zig");

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
