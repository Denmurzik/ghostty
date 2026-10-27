//! Worker that hands links to the shell off the UI thread.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const App = @import("App.zig");

pub const State = struct {};

/// Stops the worker; called at the start of `App.terminate`.
pub fn appStopping(app: *App) void {
    _ = app;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginArray();
    try jw.endArray();
}
