//! tmux pane/window id registry and command dispatch (owner: M4 task 12).
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const protocol = @import("../ipc/protocol.zig");

/// `App.tmux`; task 12 adds fields with defaults.
pub const State = struct {};

pub const Reply = struct {
    code: protocol.Code,
    stdout: []const u8,
    stderr: []const u8,
};

pub fn run(app: *App, req: protocol.Request, arena: Allocator) Reply {
    _ = app;
    _ = req;
    _ = arena;
    return .{ .code = .failed, .stdout = "", .stderr = "ghostty: tmux is not ready" };
}

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

pub fn childExited(surface: *Surface, info: apprt.surface.Message.ChildExited) bool {
    _ = surface;
    _ = info;
    return false;
}

pub fn appStopping(app: *App) void {
    _ = app;
}
