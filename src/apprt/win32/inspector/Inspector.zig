//! The terminal inspector window. File-level functions are the hooks; the
//! nested `Inspector` is the per-surface instance.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");

const log = std.log.scoped(.win32_inspector);

/// One inspector window, owned by the surface it inspects.
pub const Inspector = struct {};

pub fn appStopping(app: *App) void {
    _ = app;
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

pub fn action(app: *App, target: apprt.Target, mode: apprt.Action.Value(.inspector)) bool {
    _ = app;
    _ = target;
    _ = mode;
    log.debug("M3 stub action=inspector", .{});
    return false;
}

pub fn render(app: *App, target: apprt.Target) bool {
    _ = app;
    _ = target;
    log.debug("M3 stub action=render_inspector", .{});
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
