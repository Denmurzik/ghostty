//! Renderer recovery after the health of a surface turned bad (debounced by
//! a timer on the message window).
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

pub const State = struct {};

/// `WM_TIMER` on the message window; null when the id is not ours.
pub fn timer(app: *App, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    _ = app;
    _ = wparam;
    return null;
}

pub fn rendererHealth(surface: *Surface, health: apprt.Action.Value(.renderer_health)) void {
    _ = surface;
    _ = health;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
