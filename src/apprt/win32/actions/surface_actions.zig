//! Per-surface actions: pointer, rendering and child exit.
const std = @import("std");
const apprt = @import("../../../apprt.zig");
const mouse = @import("../mouse.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const scrollbar_mod = @import("../scrollbar.zig");
const tmux_registry = @import("../tmux/Registry.zig");

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
/// A pane the tmux shim created follows `remain-on-exit`: closed here (true)
/// or kept for core's message (false).
pub fn show_child_exited(app: *App, target: apprt.Target, value: apprt.Action.Value(.show_child_exited)) !bool {
    const s = surfaceOf(app, target) orelse return false;
    return tmux_registry.childExited(s, value);
}

/// Drawing is driven by the renderer thread; nothing to do here.
pub fn render(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return true;
}

/// The viewport or the scrollback changed: update the overlay scroller.
pub fn scrollbar(app: *App, target: apprt.Target, value: apprt.Action.Value(.scrollbar)) !bool {
    const s = surfaceOf(app, target) orelse return false;
    return scrollbar_mod.update(s, value);
}
