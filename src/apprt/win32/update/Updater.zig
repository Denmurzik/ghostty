//! Update checker: worker thread, timer and toast (owner: M5 Task 11). Shell until then.
const Updater = @This();

const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const App = @import("../App.zig");

const Config = configpkg.Config;
const LPARAM = win32.foundation.LPARAM;

/// Filled by Task 11.
pub const Result = struct {};

pub const State = struct {
    worker: ?std.Thread = null,
    request: std.atomic.Value(usize) = .init(0),
    deadline_ms: u64 = 0,
    last: ?Result = null,
};

pub fn start(app: *App) void {
    _ = app;
}

pub fn stop(app: *App) void {
    _ = app;
}

pub fn configChanged(app: *App, config: *const Config) void {
    _ = app;
    _ = config;
}

pub fn checkNow(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

pub fn onResult(app: *App, lparam: LPARAM) void {
    _ = app;
    _ = lparam;
}

pub fn onTimer(app: *App) void {
    _ = app;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
