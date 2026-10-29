const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const log = std.log.scoped(.os);

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    return switch (builtin.target.os.tag) {
        // On macOS, we can ask the system.
        .macos => macos: {
            const NSEvent = objc.getClass("NSEvent") orelse {
                log.err("NSEvent class not found. Can't get click interval.", .{});
                return null;
            };

            // Get the interval and convert to ms
            const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
            const ms = @as(u32, @intFromFloat(@ceil(interval * 1000)));
            break :macos ms;
        },

        // On Windows, the system double-click time (Settings, Mouse).
        .windows => windows: {
            const win = struct {
                extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
            };
            break :windows win.GetDoubleClickTime();
        },

        else => null,
    };
}

test "windows mouse: double-click time" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    const win = struct {
        extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
    };
    const got = clickInterval() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(win.GetDoubleClickTime(), got);
}
