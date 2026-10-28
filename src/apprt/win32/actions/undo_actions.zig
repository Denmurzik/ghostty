//! The `undo` and `redo` actions and the close-undo registry (owner: M5 Tasks 15a, 15b). Shell until then.
const std = @import("std");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const Tab = @import("../Tab.zig");
const Surface = @import("../Surface.zig");
const undo_model = @import("../undo.zig");

pub const Entry = struct {
    kind: undo_model.Kind,
    expires_ms: u64,
    window: ?*Window = null,
    tab: ?*Tab = null,
    tree: ?Surface.Tree = null,
    index: usize = 0,
    group: []Entry = &.{},
};

pub const State = struct { stack: undo_model.Stack(Entry) = .{} };

pub fn undo(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

pub fn redo(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

pub fn flushAll(app: *App) void {
    _ = app;
}

pub fn onTimer(app: *App) void {
    _ = app;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
