//! Transparency and backdrop blur: the composition swap chain of a surface
//! and `toggle_background_opacity`.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_composition);

pub const AppState = struct {};
pub const WindowState = struct {};
pub const SurfaceState = struct {};

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    _ = tab;
    _ = from;
    _ = to;
}

pub fn surfaceCreated(surface: *Surface) void {
    _ = surface;
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

/// `WM_GHOSTTY_SET_CONTENT` on a surface (wparam = present-target generation).
pub fn setContent(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    _ = surface;
    _ = wparam;
    return null;
}

pub fn toggleOpacity(app: *App, target: apprt.Target) bool {
    _ = app;
    _ = target;
    log.debug("M3 stub action=toggle_background_opacity", .{});
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
