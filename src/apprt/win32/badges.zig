//! Surface badges: read-only and renderer health.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_badges);

pub const State = struct {};

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

pub fn rendererHealth(surface: *Surface, health: apprt.Action.Value(.renderer_health)) void {
    _ = surface;
    _ = health;
}

pub fn readonly(app: *App, target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=readonly", .{});
    return false;
}
