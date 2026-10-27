//! send-keys gate and pane input timing (owner: M4 task 11).
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");

/// `App.tmux_keys`.
pub const State = struct {};

pub fn layoutChanged(tab: *Tab) void {
    _ = tab;
}

pub fn onTimer(app: *App) void {
    _ = app;
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}
