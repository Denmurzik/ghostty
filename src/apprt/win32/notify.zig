//! Desktop notifications and command-finished notices (toast, taskbar flash).
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32_notify);

pub const State = struct {};

pub fn appStarted(app: *App) void {
    _ = app;
}

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_GHOSTTY_NOTIFY_CLICK` on the message window (wparam = surface id).
pub fn clicked(app: *App, wparam: win32.foundation.WPARAM) void {
    _ = app;
    _ = wparam;
}

pub fn desktop(app: *App, target: apprt.Target, value: apprt.Action.Value(.desktop_notification)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=desktop_notification", .{});
    return false;
}

pub fn commandFinished(app: *App, target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=command_finished", .{});
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
