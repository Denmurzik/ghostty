//! Tab actions and the title/pwd data that feeds them.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const clipboard = @import("../clipboard.zig");
const messages = @import("../messages.zig");

const log = std.log.scoped(.win32_actions);

/// The window an action applies to: the target surface's, else (app
/// target) the most recently active one.
fn windowOf(app: *App, target: apprt.Target) ?*Window {
    return switch (target) {
        .surface => app.windowForTarget(target),
        .app => app.last_active,
    };
}

pub fn set_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.set_title)) !bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    // The surface keeps the copy that core reads back with getTitle.
    surface.setTitle(value.title) catch |err| {
        log.warn("unable to store title err={}", .{err});
        return false;
    };
    surface.window.surfaceTitleChanged(surface);
    return true;
}

pub fn new_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_tab)) !bool {
    _ = value;
    switch (target) {
        .surface => |core| {
            const window = app.windowFor(core) orelse return false;
            _ = try window.addTab(.{ .parent = core, .context = .tab });
        },
        .app => if (app.last_active) |window| {
            _ = try window.addTab(.{ .context = .tab });
        } else {
            const window = Window.create(app, .{}) catch |err| {
                log.warn("unable to create a window err={}", .{err});
                return false;
            };
            window.show();
        },
    }
    return true;
}

pub fn close_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.close_tab)) !bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const mode: Window.CloseTabMode = switch (value) {
        .this => .this,
        .other => .other,
        .right => .right,
    };
    // The handler may ask a question, so it runs from the message loop.
    return win32.user32.PostMessageW(
        surface.window.hwnd,
        messages.WM_GHOSTTY_CLOSE_TAB,
        @intFromEnum(mode),
        @as(isize, surface.tab.id),
    ) != 0;
}

pub fn goto_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_tab)) !bool {
    const window = windowOf(app, target) orelse return false;
    const index = Window.gotoIndex(value, window.active_tab, window.tabs.items.len) orelse return false;
    window.selectTab(index);
    return true;
}

pub fn move_tab(app: *App, target: apprt.Target, value: apprt.Action.Value(.move_tab)) !bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const window = surface.window;
    const from = window.tabIndex(surface.tab) orelse return false;
    const to = Window.moveIndex(value.amount, from, window.tabs.items.len) orelse return false;
    if (to == from) return false;
    window.moveTab(from, to);
    return true;
}

pub fn set_tab_title(app: *App, target: apprt.Target, value: apprt.Action.Value(.set_tab_title)) !bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    try surface.window.setTabTitle(surface.tab, value.title);
    return true;
}

pub fn copy_title_to_clipboard(app: *App, target: apprt.Target, value: apprt.Action.Value(.copy_title_to_clipboard)) !bool {
    _ = value;
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const title = surface.getTitle() orelse return false;
    if (title.len == 0) return false;
    clipboard.write(surface.hwnd, title) catch |err| {
        log.warn("unable to copy the title err={}", .{err});
        return false;
    };
    return true;
}

pub fn pwd(app: *App, target: apprt.Target, value: apprt.Action.Value(.pwd)) !bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    try surface.window.setPwd(value.pwd);
    return true;
}

/// False when the window has only this tab.
pub fn move_tab_to_new_window(app: *App, target: apprt.Target, value: apprt.Action.Value(.move_tab_to_new_window)) !bool {
    _ = value;
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const moved = surface.window.moveTabToNewWindow(surface.tab) catch |err| {
        log.warn("unable to move the tab to a new window err={}", .{err});
        return false;
    };
    return moved != null;
}
