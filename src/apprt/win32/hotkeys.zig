//! Global hotkeys (`global:` keybinds) registered on the message window.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");

/// Registered hotkeys; owned by `App`.
pub const State = struct {};

pub fn appStarted(app: *App) void {
    _ = app;
}

pub fn appStopping(app: *App) void {
    _ = app;
}

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_HOTKEY` on the message window; null when the message is not ours.
pub fn message(
    app: *App,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = app;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
