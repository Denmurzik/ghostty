//! The context menu of a terminal surface (`right-click-action =
//! context-menu`). Items, order and wording follow the surface menu of
//! Ghostty for macOS (`SurfaceView.menu(for:)`); every item there has a
//! counterpart on Windows, so none are left out.
const std = @import("std");
const win32 = @import("win32");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_context_menu);

const MF_CHECKED: u32 = 0x00000008;

pub const Command = enum(u32) {
    copy = 1,
    paste,
    split_right,
    split_left,
    split_down,
    split_up,
    close_split,
    reset_terminal,
    toggle_inspector,
    toggle_readonly,
    change_tab_title,
    change_terminal_title,
};

/// What the menu depends on at the moment it opens.
pub const State = struct {
    has_selection: bool,
    readonly: bool,
};

const Entry = union(enum) {
    separator,
    item: struct { command: Command, label: [:0]const u16 },
};

fn item(command: Command, comptime text: []const u8) Entry {
    return .{ .item = .{
        .command = command,
        .label = std.unicode.utf8ToUtf16LeStringLiteral(text),
    } };
}

const entries = entries: {
    @setEvalBranchQuota(20000);
    break :entries [_]Entry{
        item(.copy, "Copy"),
        item(.paste, "Paste"),
        .separator,
        item(.split_right, "Split Right"),
        item(.split_left, "Split Left"),
        item(.split_down, "Split Down"),
        item(.split_up, "Split Up"),
        .separator,
        item(.close_split, "Close Split"),
        .separator,
        item(.reset_terminal, "Reset Terminal"),
        item(.toggle_inspector, "Toggle Terminal Inspector"),
        item(.toggle_readonly, "Terminal Read-only"),
        .separator,
        item(.change_tab_title, "Change Tab Title..."),
        item(.change_terminal_title, "Change Terminal Title..."),
    };
};

/// Copy is only offered with a selection, as on macOS.
fn shown(command: Command, state: State) bool {
    return switch (command) {
        .copy => state.has_selection,
        else => true,
    };
}

/// The commands of the menu in order, `null` marking a separator.
/// Separators never lead, trail or double up.
pub fn layout(buf: []?Command, state: State) []?Command {
    var n: usize = 0;
    for (entries) |e| switch (e) {
        .separator => {
            if (n > 0 and buf[n - 1] != null) {
                buf[n] = null;
                n += 1;
            }
        },
        .item => |i| if (shown(i.command, state)) {
            buf[n] = i.command;
            n += 1;
        },
    };
    if (n > 0 and buf[n - 1] == null) n -= 1;
    return buf[0..n];
}

pub fn actionFor(command: Command) input.Binding.Action {
    return switch (command) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .split_right => .{ .new_split = .right },
        .split_left => .{ .new_split = .left },
        .split_down => .{ .new_split = .down },
        .split_up => .{ .new_split = .up },
        .close_split => .close_surface,
        .reset_terminal => .reset,
        .toggle_inspector => .{ .inspector = .toggle },
        .toggle_readonly => .toggle_readonly,
        .change_tab_title => .prompt_tab_title,
        .change_terminal_title => .prompt_surface_title,
    };
}

fn labelOf(command: Command) [:0]const u16 {
    for (entries) |e| switch (e) {
        .item => |i| if (i.command == command) return i.label,
        .separator => {},
    };
    unreachable;
}

/// Shows the menu at a client position of `surface` and runs the chosen
/// item. Blocks until the menu closes, so the surface is checked again
/// afterwards: it may have gone away meanwhile.
pub fn show(surface: *Surface, client_x: i32, client_y: i32) void {
    const hwnd = surface.hwnd;
    const state: State = .{
        .has_selection = surface.core_surface.hasSelection(),
        .readonly = surface.core_surface.readonly,
    };

    const menu = user32.CreatePopupMenu() orelse {
        log.warn("unable to create the context menu err={}", .{win32.kernel32.GetLastError()});
        return;
    };
    defer _ = user32.DestroyMenu(menu);

    var buf: [entries.len]?Command = undefined;
    for (layout(&buf, state)) |maybe| {
        const command = maybe orelse {
            _ = user32.AppendMenuW(menu, user32.MF_SEPARATOR, 0, null);
            continue;
        };
        const checked = command == .toggle_readonly and state.readonly;
        const flags: u32 = user32.MF_STRING | if (checked) MF_CHECKED else @as(u32, 0);
        _ = user32.AppendMenuW(menu, flags, @backingInt(command), labelOf(command).ptr);
    }

    var pt: win32.foundation.POINT = .{ .x = client_x, .y = client_y };
    _ = user32.ClientToScreen(hwnd, &pt);

    // The menu belongs to the foreground window, or it will not close
    // when the user clicks elsewhere.
    _ = user32.SetForegroundWindow(hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON,
        pt.x,
        pt.y,
        hwnd,
        null,
    );
    // Lets the loop of the menu finish before the next message.
    _ = user32.PostMessageW(hwnd, user32.WM_NULL, 0, 0);
    if (cmd <= 0) return;
    const command = std.enums.fromInt(Command, @as(u32, @intCast(cmd))) orelse return;

    // The surface may have closed while the menu was up.
    if (user32.IsWindow(hwnd) == 0) return;
    if (user32.GetWindowLongPtrW(hwnd, user32.GWLP_USERDATA) != @as(isize, @bitCast(@intFromPtr(surface)))) return;

    _ = surface.core_surface.performBindingAction(actionFor(command)) catch |err| {
        log.warn("context menu command failed command={} err={}", .{ command, err });
    };
}

test "win32 context menu: item list with a selection" {
    var buf: [entries.len]?Command = undefined;
    const got = layout(&buf, .{ .has_selection = true, .readonly = false });
    const expect = [_]?Command{
        .copy,
        .paste,
        null,
        .split_right,
        .split_left,
        .split_down,
        .split_up,
        null,
        .close_split,
        null,
        .reset_terminal,
        .toggle_inspector,
        .toggle_readonly,
        null,
        .change_tab_title,
        .change_terminal_title,
    };
    try std.testing.expectEqualSlices(?Command, &expect, got);
}

test "win32 context menu: no copy without a selection" {
    var buf: [entries.len]?Command = undefined;
    const got = layout(&buf, .{ .has_selection = false, .readonly = true });
    try std.testing.expectEqual(@as(?Command, .paste), got[0]);
    for (got) |c| try std.testing.expect(c != .copy);
    try std.testing.expect(got[got.len - 1] != null);
}

test "win32 context menu: command ids are the menu ids" {
    // 0 is "no command" for `TPM_RETURNCMD`.
    var n: u32 = 0;
    for (entries) |e| switch (e) {
        .item => |i| {
            n += 1;
            try std.testing.expectEqual(n, @backingInt(i.command));
        },
        .separator => {},
    };
}

test "win32 context menu: command to action mapping" {
    try std.testing.expectEqual(input.Binding.Action.paste_from_clipboard, actionFor(.paste));
    try std.testing.expectEqual(input.Binding.Action{ .new_split = .down }, actionFor(.split_down));
    try std.testing.expectEqual(input.Binding.Action.toggle_readonly, actionFor(.toggle_readonly));
}
