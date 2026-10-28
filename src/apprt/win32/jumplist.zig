//! Taskbar jump list (owner: M5 Task 4). Shell until then.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const App = @import("App.zig");

const Config = configpkg.Config;

pub fn schedule(app: *App) void {
    _ = app;
}

pub fn configChanged(app: *App, config: *const Config) void {
    _ = app;
    _ = config;
}

pub fn stop(app: *App) void {
    _ = app;
}

/// The `+new-tab` fallback when no instance runs; true when it handled the call.
pub fn newTabFallback(alloc: Allocator, class: ?[]const u8, args: []const [:0]const u8) bool {
    _ = alloc;
    _ = class;
    _ = args;
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}

/// The `jumplist_delay` timer fired.
pub fn onTimer(app: *App) void {
    _ = app;
}
