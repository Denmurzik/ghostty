//! tmux pane/window labels (owner: M4 task 13).
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../Window.zig");
const hooks = @import("../hooks.zig");

/// `App.tmux_labels`.
pub const State = struct {};

pub fn optionsChanged(app: *App, window_id: u32) void {
    _ = app;
    _ = window_id;
}

pub fn tabLayoutChanged(tab: *Tab) void {
    _ = tab;
}

pub fn tabShown(tab: *Tab, shown: bool) void {
    _ = tab;
    _ = shown;
}

pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    _ = tab;
    _ = from;
    _ = to;
}

pub fn windowChanged(window: *Window, change: hooks.WindowChange) void {
    _ = window;
    _ = change;
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}
