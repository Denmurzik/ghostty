//! Initial placement, maximize, fullscreen and always-on-top. Stub: Task 22.
const Window = @import("Window.zig");
const geom = @import("geom.zig");

pub const State = struct {
    fullscreen: bool = false,
    topmost: bool = false,
    saved_valid: bool = false,
    saved_rect: geom.Rect = .{},
    saved_show_cmd: u32 = 0,
    saved_style: usize = 0,
    initial_size: ?struct { width: u32, height: u32 } = null,
};

pub fn applyStartup(window: *Window) void {
    _ = window;
}
