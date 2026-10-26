//! App-level actions: lifecycle, windows and configuration.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const App = @import("../App.zig");
const Chrome = @import("../Chrome.zig");
const Window = @import("../Window.zig");
const messages = @import("../messages.zig");
const theme = @import("../theme.zig");
const util = @import("../util.zig");
const link_policy = @import("../link_policy.zig");

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
    return true;
}

/// The question runs from the message loop of a window, not the core tick.
pub fn close_all_windows(app: *App, target: apprt.Target, value: apprt.Action.Value(.close_all_windows)) !bool {
    _ = value;
    const window = app.windowForTarget(target) orelse
        app.last_active orelse
        (if (app.windows.items.len == 0) return false else app.windows.items[app.windows.items.len - 1]);
    return win32.user32.PostMessageW(window.hwnd, messages.WM_GHOSTTY_CLOSE_ALL, 0, 0) != 0;
}

/// Previous or next window in creation order, wrapping around.
pub fn goto_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_window)) !bool {
    const windows = app.windows.items;
    const from = app.windowForTarget(target) orelse app.last_active orelse return false;
    const index = for (windows, 0..) |w, i| {
        if (w == from) break i;
    } else return false;
    const to = gotoWindowIndex(value, index, windows.len) orelse return false;
    windows[to].activate();
    return true;
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
        .app => theme.configChanged(app, value.config),
        .surface => {},
    }
    return true;
}

/// The config file is opened by the shell's "open" verb; without an
/// association it goes to Notepad. Both open a window, so this is never
/// called from tests.
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

    return shellOpen(alloc, path);
}

/// `text` and `html` are paths Ghostty wrote itself (screen and scrollback
/// files) and open like the config file. `unknown` and `osc8` come from
/// terminal output, so nothing there may run a program: web and mail URLs go
/// to the shell, local paths are only selected in Explorer (see
/// `link_policy`). Always true so the core never falls back to `os.open`.
pub fn open_url(app: *App, target: apprt.Target, value: apprt.Action.Value(.open_url)) !bool {
    _ = target;
    const alloc = app.core_app.alloc;

    if (link_policy.isTrusted(value.kind)) {
        _ = shellOpen(alloc, value.url);
        return true;
    }

    var buf: [link_policy.max_len]u8 = undefined;
    switch (link_policy.classify(&buf, value.url)) {
        .refuse => |why| log.warn("refusing to open link kind={t} why={s}", .{ value.kind, why }),
        .open => |url| {
            const wide = util.utf16z(alloc, url) catch |err| {
                log.warn("unable to convert link err={}", .{err});
                return true;
            };
            defer alloc.free(wide);
            const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
            const rc = win32.shell32.ShellExecuteW(null, open, wide.ptr, null, null, win32.user32.SW_SHOWNORMAL);
            if (rc <= 32) log.warn("unable to open link rc={}", .{rc});
        },
        .reveal => |path| {
            const params = std.fmt.allocPrint(alloc, "/select,\"{s}\"", .{path}) catch |err| {
                log.warn("unable to build explorer arguments err={}", .{err});
                return true;
            };
            defer alloc.free(params);
            const wide = util.utf16z(alloc, params) catch |err| {
                log.warn("unable to convert explorer arguments err={}", .{err});
                return true;
            };
            defer alloc.free(wide);
            const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
            const explorer = std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe");
            const rc = win32.shell32.ShellExecuteW(null, open, explorer, wide.ptr, null, win32.user32.SW_SHOWNORMAL);
            if (rc <= 32) log.warn("unable to reveal link rc={}", .{rc});
        },
    }
    return true;
}

/// Opens a file Ghostty wrote with the shell's "open" verb; without an
/// association it goes to Notepad.
fn shellOpen(alloc: std.mem.Allocator, path: []const u8) bool {
    const wide = util.utf16z(alloc, path) catch |err| {
        log.warn("unable to convert path err={}", .{err});
        return false;
    };
    defer alloc.free(wide);

    const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const rc = win32.shell32.ShellExecuteW(null, open, wide.ptr, null, null, win32.user32.SW_SHOWNORMAL);
    if (rc > 32) return true;
    if (rc != win32.shell32.SE_ERR_NOASSOC) {
        log.warn("unable to open the file rc={}", .{rc});
        return false;
    }

    const quoted = std.fmt.allocPrint(alloc, "\"{s}\"", .{path}) catch |err| {
        log.warn("unable to build notepad arguments err={}", .{err});
        return false;
    };
    defer alloc.free(quoted);
    const params = util.utf16z(alloc, quoted) catch |err| {
        log.warn("unable to convert notepad arguments err={}", .{err});
        return false;
    };
    defer alloc.free(params);
    const notepad = std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe");
    const rc2 = win32.shell32.ShellExecuteW(null, open, notepad, params.ptr, null, win32.user32.SW_SHOWNORMAL);
    if (rc2 <= 32) {
        log.warn("unable to open the file in notepad rc={}", .{rc2});
        return false;
    }
    return true;
}

/// OSC 4/10/11: with `window-theme = ghostty` the chrome follows the
/// terminal colours.
pub fn color_change(app: *App, target: apprt.Target, value: apprt.Action.Value(.color_change)) !bool {
    _ = value;
    switch (target) {
        .app => for (app.windows.items) |window| Chrome.invalidate(window),
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
