//! Overlay windows (labels, toasts, search bar host, palette host) that
//! float over a surface.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const hooks = @import("hooks.zig");

/// Per top-level window: the overlays it hosts.
pub const WindowState = struct {};

/// A command for the overlay of a window, posted with
/// `messages.WM_GHOSTTY_OVERLAY_CMD`.
pub const Command = struct {};

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_ACTIVATE` / `WM_NCACTIVATE`: the window stays drawn as active while
/// one of its overlays has the focus.
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

pub fn tabShown(tab: *Tab, shown: bool) void {
    _ = tab;
    _ = shown;
}

pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    _ = tab;
    _ = from;
    _ = to;
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    _ = surface;
    _ = focused;
}

pub fn surfaceRectChanged(surface: *Surface) void {
    _ = surface;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}

/// Frees the heap `Command` of a `WM_GHOSTTY_OVERLAY_CMD` nobody claimed.
pub fn freeCommand(lparam: win32.foundation.LPARAM) void {
    _ = lparam;
}
