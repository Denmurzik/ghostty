//! App-level actions: lifecycle, windows and configuration.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const App = @import("../App.zig");
const Chrome = @import("../Chrome.zig");
const QuickTerminal = @import("../QuickTerminal.zig");
const Window = @import("../Window.zig");
const hooks = @import("../hooks.zig");
const shell_open = @import("../shell_open.zig");
const messages = @import("../messages.zig");
const undo_actions = @import("undo_actions.zig");
const theme = @import("../theme.zig");
const tray = @import("../tray.zig");
const util = @import("../util.zig");

const Config = configpkg.Config;

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

/// A surface target is the parent of the new window (its working directory
/// and cascade origin); the app target has none.
pub fn new_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_window)) !bool {
    _ = value;
    const parent = switch (target) {
        .app => null,
        .surface => |core| core,
    };
    const window = Window.create(app, .{ .parent = parent }) catch |err| {
        log.warn("unable to create a window err={}", .{err});
        return false;
    };
    window.show();
    window.activate();
    undo_actions.newWindow(window);
    return true;
}

/// The question runs from the message loop of a window, not the core tick.
pub fn close_all_windows(app: *App, target: apprt.Target, value: apprt.Action.Value(.close_all_windows)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse
        app.last_active orelse
        (app.lastNormalWindow() orelse return false);
    return win32.user32.PostMessageW(window.hwnd, messages.WM_GHOSTTY_CLOSE_ALL, 0, 0) != 0;
}

/// Previous or next window in creation order, wrapping around.
pub fn goto_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_window)) !bool {
    const windows = app.windows.items;
    const from = app.windowForTarget(target) orelse app.last_active orelse return false;
    const index = for (windows, 0..) |w, i| {
        if (w == from) break i;
    } else return false;
    // The quick terminal is not part of the cycle.
    var to = index;
    for (windows) |_| {
        to = gotoWindowIndex(value, to, windows.len) orelse return false;
        if (windows[to].kind == .normal and windows[to] != from) {
            windows[to].activate();
            return true;
        }
    }
    return false;
}

/// The window `goto_window` lands on; null when there is no other one.
pub fn gotoWindowIndex(direction: apprt.action.GotoWindow, current: usize, count: usize) ?usize {
    if (count < 2) return null;
    return switch (direction) {
        .next => (current + 1) % count,
        .previous => (current + count - 1) % count,
    };
}

/// Restore the window if minimized, bring it to the front and focus the
/// surface in its tab.
pub fn present_terminal(app: *App, target: apprt.Target, value: apprt.Action.Value(.present_terminal)) !bool {
    _ = value;
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const window = surface.window;
    const index = window.tabIndex(surface.tab) orelse return false;

    surface.tab.focused = surface;
    window.selectTabFocus(index, false);
    window.activate();
    return true;
}

/// Soft: the config in memory is applied again (a new colour scheme, a
/// surface asking for its config). Hard: the files are read again; the old
/// config is freed once core and the windows hold the new one.
pub fn reload_config(app: *App, target: apprt.Target, value: apprt.Action.Value(.reload_config)) !bool {
    if (value.soft) {
        try updateTarget(app, target, &app.config);
        return true;
    }

    // Seen by the config_change this reload produces: its hooks tell a reload
    // from a soft apply.
    app.reload_pending = true;
    defer app.reload_pending = false;

    var config = Config.load(app.core_app.alloc) catch |err| {
        log.warn("unable to reload the config err={}", .{err});
        return false;
    };
    errdefer config.deinit();
    try updateTarget(app, target, &config);

    var old = app.config;
    app.config = config;
    old.deinit();
    return true;
}

fn updateTarget(app: *App, target: apprt.Target, config: *const Config) !void {
    switch (target) {
        .app => try app.core_app.updateConfig(app, config),
        .surface => |core| try core.updateConfig(config),
    }
}

/// The app-level config (with its conditional state applied) changed: the
/// chrome follows it. A surface-level change has nothing for the chrome.
pub fn config_change(app: *App, target: apprt.Target, value: apprt.Action.Value(.config_change)) !bool {
    switch (target) {
        .app => {
            theme.configChanged(app, value.config);
            tray.syncTo(app, value.config.@"quit-after-last-window-closed");
            hooks.configChanged(app, value.config, app.reload_pending);
            // With no window open nothing else would start (or cancel) the quit.
            if (QuickTerminal.countOpen(app.windows.items, app.quick.shown) == 0) {
                if (value.config.@"quit-after-last-window-closed") {
                    app.startQuitTimerFor(value.config);
                } else app.stopQuitTimer();
            }
        },
        .surface => {},
    }
    return true;
}

/// The config file is opened by the shell's "open" verb; without an
/// association it goes to Notepad. Both open a window, so this is never
/// called from tests (which record it instead).
pub fn open_config(app: *App, target: apprt.Target, value: apprt.Action.Value(.open_config)) !bool {
    _ = target;
    // `new_window` runs `$EDITOR` in a terminal on GTK; here both ask the shell.
    _ = value;

    const alloc = app.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("unable to get the config file path err={}", .{err});
        return false;
    };
    defer alloc.free(path);

    shell_open.openPath(app, path);
    return true;
}

/// OSC 4/10/11: with `window-theme = ghostty` the chrome follows the
/// terminal colours.
pub fn color_change(app: *App, target: apprt.Target, value: apprt.Action.Value(.color_change)) !bool {
    _ = value;
    switch (target) {
        .app => {
            var windows = app.forEachWindow(true);
            while (windows.next()) |window| Chrome.invalidate(window);
        },
        .surface => if (app.windowForTarget(target)) |window| Chrome.invalidate(window),
    }
    return true;
}

test "win32 window: goto_window wraps over the window list" {
    try std.testing.expectEqual(@as(?usize, null), gotoWindowIndex(.next, 0, 1));
    try std.testing.expectEqual(@as(?usize, 1), gotoWindowIndex(.next, 0, 3));
    try std.testing.expectEqual(@as(?usize, 0), gotoWindowIndex(.next, 2, 3));
    try std.testing.expectEqual(@as(?usize, 2), gotoWindowIndex(.previous, 0, 3));
    try std.testing.expectEqual(@as(?usize, 0), gotoWindowIndex(.previous, 1, 3));
}
