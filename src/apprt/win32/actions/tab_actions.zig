//! Tab actions and the title/pwd data that feeds them.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");

const log = std.log.scoped(.win32_actions);

pub fn set_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.set_title)) !bool {
    const surface = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const window = app.windowForSurface(surface) orelse return false;
    // The surface keeps the copy that core reads back with getTitle.
    if (window.surface) |s| s.setTitle(value.title) catch |err| {
        log.warn("unable to store title err={}", .{err});
        return false;
    };
    window.setTitle(value.title);
    return true;
}

/// Stub until Task 6a.
pub fn new_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_tab)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 6a.
pub fn close_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.close_tab)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 6a.
pub fn goto_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_tab)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 6a.
pub fn move_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.move_tab)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 13.
pub fn set_tab_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.set_tab_title)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 13.
pub fn copy_title_to_clipboard(app: *App, target: apprt.Target, value: apprt.Action.Value(.copy_title_to_clipboard)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 13.
pub fn pwd(app: *App, target: apprt.Target, value: apprt.Action.Value(.pwd)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 21.
pub fn move_tab_to_new_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.move_tab_to_new_window)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}
