//! Profile menu of the tab strip and the tray (owner: M5 Task 3). Shell until then.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Window = @import("Window.zig");

pub fn showForStrip(window: *Window, screen_x: i32, screen_y: i32) void {
    _ = window;
    _ = screen_x;
    _ = screen_y;
}

/// Returns the next free id.
pub fn appendTrayItems(app: *App, menu: win32.user32.HMENU, first_id: u32) u32 {
    _ = app;
    _ = menu;
    return first_id;
}

pub fn trayCommand(app: *App, id: u32) bool {
    _ = app;
    _ = id;
    return false;
}
