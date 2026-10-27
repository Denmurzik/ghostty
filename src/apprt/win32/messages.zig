//! Private window message ids and timer ids of the Win32 apprt. One table
//! so that no two features hand out the same `WM_APP + n`. The first four
//! keep their M1 values.
const std = @import("std");
const win32 = @import("win32");

const App = @import("App.zig");
const clipboard = @import("clipboard.zig");

/// Posted to the message window by `wakeup` to have the core app ticked.
pub const WM_GHOSTTY_WAKEUP = win32.user32.WM_APP + 1;
/// Posted to a surface window to run a clipboard read from the message loop.
pub const WM_GHOSTTY_CLIPBOARD_READ = win32.user32.WM_APP + 2;
/// Reserved for quit timer notifications; the timer itself is a `WM_TIMER`.
pub const WM_GHOSTTY_QUIT_TIMER = win32.user32.WM_APP + 3;
/// Posted to the message window by every quit source (keybind, tray, IPC):
/// confirms if needed and quits from the message loop.
pub const WM_GHOSTTY_QUIT = win32.user32.WM_APP + 4;
/// Posted to the message window by the IPC thread; lparam is a `*Pending`.
pub const WM_GHOSTTY_IPC = win32.user32.WM_APP + 5;
/// Posted to a top-level window to close one surface (wparam = surface id,
/// lparam = process active).
pub const WM_GHOSTTY_CLOSE_SURFACE = win32.user32.WM_APP + 6;
/// Posted to a top-level window to close tabs (wparam = mode, lparam = tab id).
pub const WM_GHOSTTY_CLOSE_TAB = win32.user32.WM_APP + 7;
/// Posted to a top-level window when the tab title editor finishes.
pub const WM_GHOSTTY_TITLE_EDIT_DONE = win32.user32.WM_APP + 8;
/// Tray icon callback message.
pub const WM_GHOSTTY_TRAY = win32.user32.WM_APP + 9;
/// Posted to a top-level window after an OLE drop; lparam is a `*Payload`.
pub const WM_GHOSTTY_DROP = win32.user32.WM_APP + 10;
/// Posted to a top-level window to close every window of the app.
pub const WM_GHOSTTY_CLOSE_ALL = win32.user32.WM_APP + 11;
// WM_APP + 12 ... WM_APP + 15 are reserved for M3.

/// `WM_TIMER` ids, unique per window class (a timer id is only meaningful
/// to the window that owns the timer).
pub const timers = struct {
    pub const msg_window = struct {
        /// Delayed quit (`quit-after-last-window-closed-delay`).
        pub const quit: usize = 1;
    };
    pub const tab = struct {
        /// Throttled relayout while a split divider is dragged.
        pub const divider_drag: usize = 1;
    };
    pub const resize_overlay = struct {
        /// Hides the overlay after its duration.
        pub const hide: usize = 1;
    };
    pub const surface = struct {
        /// Applies the coalesced size of a live resize to core.
        pub const resize: usize = 1;
    };
    pub const window = struct {
        /// Reserved: strip auto-scroll while a tab is dragged.
        pub const strip_autoscroll: usize = 1;
        /// Drops a stale taskbar progress report (`taskbar.zig`).
        pub const taskbar_stale: usize = 0x2600;
    };
};

test "win32 skeleton: private message ids are unique and keep M1's values" {
    const ids = [_]u32{
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_CLIPBOARD_READ,
        WM_GHOSTTY_QUIT_TIMER,
        WM_GHOSTTY_QUIT,
        WM_GHOSTTY_IPC,
        WM_GHOSTTY_CLOSE_SURFACE,
        WM_GHOSTTY_CLOSE_TAB,
        WM_GHOSTTY_TITLE_EDIT_DONE,
        WM_GHOSTTY_TRAY,
        WM_GHOSTTY_DROP,
        WM_GHOSTTY_CLOSE_ALL,
    };
    for (ids, 0..) |id, i| {
        try std.testing.expect(id > win32.user32.WM_APP);
        try std.testing.expect(id <= win32.user32.WM_APP + 15);
        for (ids[i + 1 ..]) |other| try std.testing.expect(id != other);
    }

    try std.testing.expectEqual(App.WM_GHOSTTY_WAKEUP, WM_GHOSTTY_WAKEUP);
    try std.testing.expectEqual(App.WM_GHOSTTY_QUIT, WM_GHOSTTY_QUIT);
    try std.testing.expectEqual(App.WM_GHOSTTY_QUIT_TIMER, WM_GHOSTTY_QUIT_TIMER);
    try std.testing.expectEqual(clipboard.WM_GHOSTTY_CLIPBOARD_READ, WM_GHOSTTY_CLIPBOARD_READ);
}

test "win32 skeleton: timer ids are unique per window class" {
    try std.testing.expectEqual(@as(usize, 1), timers.msg_window.quit);
    try std.testing.expectEqual(@as(usize, 1), timers.tab.divider_drag);
    try std.testing.expectEqual(@as(usize, 1), timers.resize_overlay.hide);
    try std.testing.expectEqual(@as(usize, 1), timers.surface.resize);
    try std.testing.expectEqual(@as(usize, 0x2600), timers.window.taskbar_stale);

    // A timer id is only meaningful to the window that owns it, so ids
    // must differ within one class; the top-level window has several.
    const window_ids = [_]usize{
        timers.window.strip_autoscroll,
        timers.window.taskbar_stale,
    };
    for (window_ids, 0..) |id, i| {
        for (window_ids[i + 1 ..]) |other| try std.testing.expect(id != other);
    }
}
