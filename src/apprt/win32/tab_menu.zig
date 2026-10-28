//! The context menu of a tab. Items, order and wording follow the tab menu
//! of Ghostty for macOS (`TerminalWindow.configureTabContextMenuIfNeeded`):
//! the close items, "Move Tab to New Window", then "Rename Tab...". macOS
//! also has "Show All Tabs" and a colour palette; Ghostty for Windows has
//! neither feature.
const std = @import("std");
const win32 = @import("win32");
const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const messages = @import("messages.zig");
const about = @import("about.zig");
const title_edit = @import("title_edit.zig");
const strip_input = @import("strip_input.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_tab_menu);

const MF_GRAYED: u32 = 0x00000001;

pub const Command = enum(u32) {
    close_tab = 1,
    close_other_tabs,
    close_tabs_to_right,
    move_to_new_window,
    rename_tab,
    about,
};

/// What a command runs, as the actions of the same names.
pub const Action = union(enum) {
    close_tab: Window.CloseTabMode,
    move_tab_to_new_window,
    prompt_title,
    about,
};

const entries = [_]struct { command: Command, label: [:0]const u16 }{
    .{ .command = .close_tab, .label = std.unicode.utf8ToUtf16LeStringLiteral("Close Tab") },
    .{ .command = .close_other_tabs, .label = std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs") },
    .{ .command = .close_tabs_to_right, .label = std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right") },
    .{ .command = .move_to_new_window, .label = std.unicode.utf8ToUtf16LeStringLiteral("Move Tab to New Window") },
    .{ .command = .rename_tab, .label = std.unicode.utf8ToUtf16LeStringLiteral("Rename Tab...") },
    .{ .command = .about, .label = std.unicode.utf8ToUtf16LeStringLiteral("About Ghostty") },
};

/// Whether `command` does anything for the tab at `index` of `count` tabs.
pub fn enabled(command: Command, count: usize, index: usize) bool {
    return switch (command) {
        .close_tab, .rename_tab, .about => true,
        .close_other_tabs, .move_to_new_window => count > 1,
        .close_tabs_to_right => index + 1 < count,
    };
}

pub fn actionFor(command: Command) Action {
    return switch (command) {
        .close_tab => .{ .close_tab = .this },
        .close_other_tabs => .{ .close_tab = .other },
        .close_tabs_to_right => .{ .close_tab = .right },
        .move_to_new_window => .move_tab_to_new_window,
        .rename_tab => .prompt_title,
        .about => .about,
    };
}

pub fn show(window: *Window, tab_index: usize, screen_x: i32, screen_y: i32) void {
    if (tab_index >= window.tabs.items.len) return;
    // The tab may go away or move while the menu is up.
    const tab_id = window.tabs.items[tab_index].id;
    const count = window.tabs.items.len;

    strip_input.hideTooltip(window);
    const menu = user32.CreatePopupMenu() orelse {
        log.warn("unable to create the tab menu err={}", .{win32.kernel32.GetLastError()});
        return;
    };
    defer _ = user32.DestroyMenu(menu);
    for (entries) |e| {
        // The rename item is set apart from the close and move items.
        if (e.command == .rename_tab or e.command == .about) _ = user32.AppendMenuW(menu, user32.MF_SEPARATOR, 0, null);
        const flags: u32 = user32.MF_STRING | if (enabled(e.command, count, tab_index)) @as(u32, 0) else MF_GRAYED;
        _ = user32.AppendMenuW(menu, flags, @backingInt(e.command), e.label.ptr);
    }

    // The menu belongs to the foreground window, or it will not close
    // when the user clicks elsewhere.
    _ = user32.SetForegroundWindow(window.hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON,
        screen_x,
        screen_y,
        window.hwnd,
        null,
    );
    // Lets the loop of the menu finish before the next message.
    _ = user32.PostMessageW(window.hwnd, user32.WM_NULL, 0, 0);
    if (cmd <= 0) return;
    const command = std.enums.fromInt(Command, @as(u32, @intCast(cmd))) orelse return;

    for (window.tabs.items) |t| {
        if (t.id == tab_id) return run(window, t, actionFor(command));
    }
}

fn run(window: *Window, tab: *Tab, action: Action) void {
    switch (action) {
        .close_tab => |mode| _ = user32.PostMessageW(
            window.hwnd,
            messages.WM_GHOSTTY_CLOSE_TAB,
            @backingInt(mode),
            @as(isize, tab.id),
        ),
        .move_tab_to_new_window => {
            _ = window.moveTabToNewWindow(tab) catch |err| {
                log.warn("unable to move the tab to a new window err={}", .{err});
            };
        },
        .prompt_title => {
            const i = window.tabIndex(tab) orelse return;
            const rect = title_edit.tabRect(window, i) orelse return;
            title_edit.beginFor(window, .tab, tab.id, rect, tab.title());
            return;
        },
        .about => about.request(window.app),
    }
    if (window.activeTab()) |active| active.focus();
}

test "win32 tab menu: item states" {
    // One tab: nothing else to close or move.
    try std.testing.expect(enabled(.close_tab, 1, 0));
    try std.testing.expect(enabled(.rename_tab, 1, 0));
    try std.testing.expect(!enabled(.close_other_tabs, 1, 0));
    try std.testing.expect(!enabled(.close_tabs_to_right, 1, 0));
    try std.testing.expect(!enabled(.move_to_new_window, 1, 0));
    // Three tabs, the first.
    try std.testing.expect(enabled(.close_other_tabs, 3, 0));
    try std.testing.expect(enabled(.close_tabs_to_right, 3, 0));
    try std.testing.expect(enabled(.move_to_new_window, 3, 0));
    // The last tab has none to its right.
    try std.testing.expect(!enabled(.close_tabs_to_right, 3, 2));
    try std.testing.expect(enabled(.close_other_tabs, 3, 2));
    try std.testing.expect(enabled(.close_tabs_to_right, 3, 1));
}

test "win32 tab menu: command → action mapping" {
    try std.testing.expectEqual(Action{ .close_tab = .this }, actionFor(.close_tab));
    try std.testing.expectEqual(Action{ .close_tab = .other }, actionFor(.close_other_tabs));
    try std.testing.expectEqual(Action{ .close_tab = .right }, actionFor(.close_tabs_to_right));
    try std.testing.expectEqual(Action.move_tab_to_new_window, actionFor(.move_to_new_window));
    try std.testing.expectEqual(Action.prompt_title, actionFor(.rename_tab));
}

test "win32 tab menu: command ids are the menu ids" {
    // 0 is "no command" for `TPM_RETURNCMD`.
    for (entries, 1..) |e, id| try std.testing.expectEqual(@as(u32, @intCast(id)), @backingInt(e.command));
}
