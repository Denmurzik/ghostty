//! Per-surface actions: pointer, rendering and child exit.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const mouse = @import("../mouse.zig");
const App = @import("../App.zig");

const log = std.log.scoped(.win32_actions);

pub fn mouse_shape(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_shape)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    const s = window.surface orelse return false;
    s.mouse_state.shape = value;
    mouse.refreshCursor(s);
    return true;
}

pub fn mouse_visibility(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_visibility)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    const s = window.surface orelse return false;
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
