//! `toggle_visibility`: hides or shows every window of the app.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const App = @import("App.zig");

const log = std.log.scoped(.win32_visibility);

pub const State = struct {};

pub fn toggle(app: *App) bool {
    _ = app;
    log.debug("M3 stub action=toggle_visibility", .{});
    return false;
}
