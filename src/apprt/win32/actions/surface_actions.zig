//! Per-surface actions: pointer, rendering and child exit.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const mouse = @import("../mouse.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");

const log = std.log.scoped(.win32_actions);

/// The apprt surface an action is aimed at.
fn surfaceOf(app: *App, target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |s| app.surfaceFor(s),
    };
}

pub fn mouse_shape(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_shape)) !bool {
    const s = surfaceOf(app, target) orelse return false;
    s.mouse_state.shape = value;
    mouse.refreshCursor(s);
    return true;
}

pub fn mouse_visibility(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_visibility)) !bool {
    const s = surfaceOf(app, target) orelse return false;
    s.mouse_state.hidden = value == .hidden;
    mouse.refreshCursor(s);
    return true;
}

/// A false return makes core handle the exit itself, per `wait-after-command`.
pub fn show_child_exited(app: *App, target: apprt.Target, value: apprt.Action.Value(.show_child_exited)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Drawing is driven by the renderer thread; nothing to do here.
pub fn render(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return true;
}

/// Stub until Task 25.
pub fn scrollbar(app: *App, target: apprt.Target, value: apprt.Action.Value(.scrollbar)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}
