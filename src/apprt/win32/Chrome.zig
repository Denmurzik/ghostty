//! Painter of the tab strip and caption (Direct2D/DirectWrite). Stub: Task 18.
const win32 = @import("win32");
const Window = @import("Window.zig");
const geom = @import("geom.zig");

pub fn paint(window: *Window, hdc: win32.user32.HDC, dirty: geom.Rect) void {
    _ = window;
    _ = hdc;
    _ = dirty;
}

pub fn invalidate(window: *Window) void {
    _ = win32.user32.InvalidateRect(window.hwnd, null, 0);
}

pub fn deinitShared() void {}
