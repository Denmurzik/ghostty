//! Split actions.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");

const log = std.log.scoped(.win32_actions);

/// Stub until Task 14.
pub fn new_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_split)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 14.
pub fn goto_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_split)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 14.
pub fn resize_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.resize_split)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 14.
pub fn equalize_splits(app: *App, target: apprt.Target, value: apprt.Action.Value(.equalize_splits)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 14.
pub fn toggle_split_zoom(app: *App, target: apprt.Target, value: apprt.Action.Value(.toggle_split_zoom)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}
