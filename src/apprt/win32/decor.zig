//! Per-surface decorations drawn by the renderer: unfocused-split dimming
//! and the bell border. The renderer reads `Surface.decor_word`.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");

pub const State = struct {};

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

pub fn surfaceCreated(surface: *Surface) void {
    _ = surface;
}

pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    _ = surface;
    _ = focused;
}

pub fn tabLayoutChanged(tab: *Tab) void {
    _ = tab;
}

/// `WM_TIMER` (bell border expiry) on the surface window.
pub fn timer(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    _ = surface;
    _ = wparam;
    return null;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
