//! App-level actions: lifecycle, windows and configuration.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");

const log = std.log.scoped(.win32_actions);

/// Confirmation (a modal loop) must not run inside the core tick, so the
/// request is posted to the message window and handled by `QuitGate`.
pub fn quit(app: *App, target: apprt.Target, value: void) !bool {
    _ = target;
    _ = value;
    if (win32.user32.PostMessageW(app.msg_hwnd, App.WM_GHOSTTY_QUIT, 0, 0) == 0) {
        log.warn("unable to post quit request", .{});
        return false;
    }
    return true;
}

pub fn quit_timer(app: *App, target: apprt.Target, value: apprt.Action.Value(.quit_timer)) !bool {
    _ = target;
    switch (value) {
        .start => app.startQuitTimer(),
        .stop => app.stopQuitTimer(),
    }
    return true;
}

/// Stub until Task 21.
pub fn new_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_window)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 21.
pub fn close_all_windows(app: *App, target: apprt.Target, value: apprt.Action.Value(.close_all_windows)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 21.
pub fn goto_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_window)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 21.
pub fn present_terminal(app: *App, target: apprt.Target, value: apprt.Action.Value(.present_terminal)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 15.
pub fn reload_config(app: *App, target: apprt.Target, value: apprt.Action.Value(.reload_config)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 15.
pub fn config_change(app: *App, target: apprt.Target, value: apprt.Action.Value(.config_change)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 15.
pub fn open_config(app: *App, target: apprt.Target, value: apprt.Action.Value(.open_config)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

/// Stub until Task 15.
pub fn color_change(app: *App, target: apprt.Target, value: apprt.Action.Value(.color_change)) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}
