//! On-screen keyboard (owner: M5 Task 16). Shell until then.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");

pub fn show(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
