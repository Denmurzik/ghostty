//! Window-level actions: size, state, title prompt and attention.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const title_edit = @import("../title_edit.zig");
const placement = @import("../placement.zig");

const log = std.log.scoped(.win32_actions);

pub fn close_window(app: *App, target: apprt.Target, value: void) !bool {
    _ = value;
    const surface = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const window = app.windowFor(surface) orelse return false;
    window.requestCloseWithConfirm();
    return true;
}

pub fn initial_size(app: *App, target: apprt.Target, value: apprt.Action.Value(.initial_size)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    window.setInitialSize(value.width, value.height);
    return true;
}

pub fn size_limit(app: *App, target: apprt.Target, value: apprt.Action.Value(.size_limit)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    window.size_limit = value;
    return true;
}

pub fn cell_size(app: *App, target: apprt.Target, value: apprt.Action.Value(.cell_size)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    window.cell_size = value;
    return true;
}

pub fn set_window_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.set_window_title)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    try window.setTitleOverride(value.title);
    return true;
}

pub fn toggle_maximize(app: *App, target: apprt.Target, value: apprt.Action.Value(.toggle_maximize)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse return false;
    return placement.toggleMaximize(window);
}

/// The `macos_non_native*` variants behave like `native`.
pub fn toggle_fullscreen(app: *App, target: apprt.Target, value: apprt.Action.Value(.toggle_fullscreen)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse return false;
    return placement.toggleFullscreen(window);
}

pub fn toggle_window_decorations(app: *App, target: apprt.Target, value: apprt.Action.Value(.toggle_window_decorations)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse return false;
    return placement.toggleDecorations(window);
}

pub fn float_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.float_window)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    return placement.setFloat(window, value);
}

pub fn reset_window_size(app: *App, target: apprt.Target, value: apprt.Action.Value(.reset_window_size)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse return false;
    return placement.resetSize(window);
}

pub fn resize_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.resize_window)) !bool {
    const window = app.windowForTarget(target) orelse return false;
    return placement.resizeClient(window, value.width, value.height);
}

pub fn prompt_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.prompt_title)) !bool {
    return title_edit.prompt(app, target, value);
}

/// Stub until Task 26.
pub fn ring_bell(app: *App, target: apprt.Target, value: apprt.Action.Value(.ring_bell)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 26.
pub fn progress_report(app: *App, target: apprt.Target, value: apprt.Action.Value(.progress_report)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}
