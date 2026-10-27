//! The search bar overlay of a surface.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_search);

pub const State = struct {};

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

/// `WM_GHOSTTY_OVERLAY_CMD` on a top-level window; true when the command
/// was for the search bar.
pub fn command(window: *Window, lparam: win32.foundation.LPARAM) bool {
    _ = window;
    _ = lparam;
    return false;
}

pub fn start(app: *App, target: apprt.Target, value: apprt.Action.Value(.start_search)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=start_search", .{});
    return false;
}

pub fn end(app: *App, target: apprt.Target, value: apprt.Action.Value(.end_search)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=end_search", .{});
    return false;
}

pub fn total(app: *App, target: apprt.Target, value: apprt.Action.Value(.search_total)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=search_total", .{});
    return false;
}

pub fn selected(app: *App, target: apprt.Target, value: apprt.Action.Value(.search_selected)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=search_selected", .{});
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
