//! Window frame: client-side decorations, hit testing of the caption and
//! the non-client size. Stub: Task 17.
const std = @import("std");
const win32 = @import("win32");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const Decorations = enum { client, server, none };

pub const State = struct {
    decorations: Decorations = .server,
    hover: TabStrip.Part = .nowhere,
    pressed: TabStrip.Part = .nowhere,
    nc_tracking: bool = false,
};

pub const Size = struct { w: i32, h: i32 };

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}

pub fn apply(window: *Window) void {
    _ = window;
}

pub fn stripMode(window: *const Window) TabStrip.Mode {
    _ = window;
    return .hidden;
}

/// Window size minus content size: frame insets plus the strip height.
pub fn nonClientSize(window: *const Window) Size {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const style: u32 = @truncate(@as(usize, @bitCast(
        win32.user32.GetWindowLongPtrW(window.hwnd, win32.user32.GWL_STYLE),
    )));
    const ex_style: u32 = @truncate(@as(usize, @bitCast(
        win32.user32.GetWindowLongPtrW(window.hwnd, win32.user32.GWL_EXSTYLE),
    )));
    _ = win32.user32.AdjustWindowRectExForDpi(
        &rc,
        style,
        0,
        ex_style,
        window.dpi,
    );
    return .{ .w = rc.right - rc.left, .h = rc.bottom - rc.top };
}
