//! The quick terminal: a window that slides in from a screen edge.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const hooks = @import("hooks.zig");

const log = std.log.scoped(.win32_quick);

pub const State = struct {};

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_ACTIVATE` (autohide) and `WM_TIMER` (slide) on a quick window.
pub fn windowMessage(
    window: *Window,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}

pub fn windowChanged(window: *Window, change: hooks.WindowChange) void {
    _ = window;
    _ = change;
}

pub fn toggle(app: *App) bool {
    _ = app;
    log.debug("M3 stub action=toggle_quick_terminal", .{});
    return false;
}

/// The `toggle-quick-terminal` IPC op; false when there is nothing to toggle.
pub fn ipcToggle(app: *App) bool {
    _ = app;
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
