//! Secure input: screen-capture exclusion (owner: M5 Task 13). Shell until then.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");

pub const State = struct { on: bool = false };

pub fn perform(app: *App, target: apprt.Target, value: apprt.action.SecureInput) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

pub fn appStarted(app: *App) void {
    _ = app;
}

/// No-op while off.
pub fn apply(hwnd: win32.foundation.HWND) void {
    _ = hwnd;
}

/// `clipboard.zig` asks.
pub fn copying(app: *App) bool {
    _ = app;
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
