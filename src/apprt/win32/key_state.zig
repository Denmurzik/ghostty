//! Key sequence and key table indicator.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_key_state);

pub const State = struct {};

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

pub fn sequence(app: *App, target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=key_sequence", .{});
    return false;
}

pub fn table(app: *App, target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=key_table", .{});
    return false;
}
