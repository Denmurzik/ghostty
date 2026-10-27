//! Shows the errors of the config (at start-up and after a reload).
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

pub fn appStarted(app: *App) void {
    _ = app;
}

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `config_errors`.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    _ = window;
    _ = lparam;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
