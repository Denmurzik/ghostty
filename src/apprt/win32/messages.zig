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
/// Posted to the message window when a toast notification is clicked
/// (wparam = surface id).
pub const WM_GHOSTTY_NOTIFY_CLICK = win32.user32.WM_APP + 12;
/// Posted to a surface when a composition swap chain waits to be attached
/// (wparam = present-target generation); the chain itself waits in
/// `composition.SurfaceState`.
pub const WM_GHOSTTY_SET_CONTENT = win32.user32.WM_APP + 13;
/// Posted to a top-level window to run a dialog from the message loop
/// (wparam = `hooks.DialogKind`, lparam = heap payload owned by the handler).
pub const WM_GHOSTTY_POSTED_DIALOG = win32.user32.WM_APP + 14;
/// Posted to a top-level window to run an overlay command (lparam = heap
/// `overlay.Command`, freed by the handler).
pub const WM_GHOSTTY_OVERLAY_CMD = win32.user32.WM_APP + 15;
/// Posted to the message window by the update worker (lparam = heap
/// `Updater.Result`, freed by the receiver).
pub const WM_GHOSTTY_UPDATE_RESULT = win32.user32.WM_APP + 16;
// WM_APP + 17 ... WM_APP + 31 are reserved for M5 and later.

/// `WM_TIMER` ids, unique per window class (a timer id is only meaningful
/// to the window that owns the timer).
pub const timers = struct {
    pub const msg_window = struct {
        /// Delayed quit (`quit-after-last-window-closed-delay`).
        pub const quit: usize = 1;
        /// Debounce of the renderer recovery (`recovery.zig`).
        pub const recovery: usize = 2;
        /// Gives memory back once surfaces stopped closing (`App.scheduleMemoryRelease`).
        pub const release_memory: usize = 3;
        /// tmux `send-keys` gate and pane input timing (`tmux/pane_io.zig`).
        pub const tmux_keys: usize = 4;
        /// Update check schedule and the fetch deadline (`update/Updater.zig`).
        pub const update: usize = 5;
        /// Expiry of the oldest undo entry (`actions/undo_actions.zig`).
        pub const undo_expire: usize = 6;
        /// Delay before the jump list is rebuilt (`jumplist.zig`).
        pub const jumplist_delay: usize = 7;
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
        /// Reserved (nothing arms it: the bell border clears on key and focus, `decor.zig`).
        pub const decor: usize = 2;
        /// End of the wait for a first title; the ghost shows after it.
        pub const title_grace: usize = 3;
    };
    /// The overlay windows (`overlay.zig`).
    pub const overlay = struct {
        /// Hides a label or toast after its duration.
        pub const hide: usize = 1;
        /// Debounce of the search query (`SearchBar.zig`).
        pub const search_debounce: usize = 2;
        /// Pause before the scroller knob fades (`scrollbar.zig`).
        pub const scroller_hold: usize = 3;
        /// Frames of the scroller fade.
        pub const scroller_fade: usize = 4;
    };
    pub const inspector = struct {
        /// 30 Hz render tick (`Inspector.zig`).
        pub const render: usize = 1;
    };
    pub const window = struct {
        /// Reserved: strip auto-scroll while a tab is dragged.
        pub const strip_autoscroll: usize = 1;
        /// Drops a stale taskbar progress report (`taskbar.zig`).
        pub const taskbar_stale: usize = 0x2600;
        /// Coalesces title changes before the caption and strip follow (`title_rules.zig`).
        pub const title_debounce: usize = 0x2601;
        /// Hover delay of the tab tooltip (`strip_input.zig`).
        pub const tab_tooltip: usize = 0x2700;
        /// Frames of the tab and tab row slide animation (`tab_anim.zig`).
        pub const tab_anim: usize = 0x2701;
        /// Slide animation and autohide of the quick terminal.
        pub const quick_slide: usize = 2;
    };
};

test "win32 skeleton: M3 message ids are unique and keep M1/M2 values" {
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
        WM_GHOSTTY_NOTIFY_CLICK,
        WM_GHOSTTY_SET_CONTENT,
        WM_GHOSTTY_POSTED_DIALOG,
        WM_GHOSTTY_OVERLAY_CMD,
        WM_GHOSTTY_UPDATE_RESULT,
    };
    for (ids, 0..) |id, i| {
        try std.testing.expect(id > win32.user32.WM_APP);
        try std.testing.expect(id <= win32.user32.WM_APP + 31);
        for (ids[i + 1 ..]) |other| try std.testing.expect(id != other);
    }

    try std.testing.expectEqual(win32.user32.WM_APP + 11, WM_GHOSTTY_CLOSE_ALL);
    try std.testing.expectEqual(win32.user32.WM_APP + 12, WM_GHOSTTY_NOTIFY_CLICK);
    try std.testing.expectEqual(win32.user32.WM_APP + 15, WM_GHOSTTY_OVERLAY_CMD);
    try std.testing.expectEqual(App.WM_GHOSTTY_WAKEUP, WM_GHOSTTY_WAKEUP);
    try std.testing.expectEqual(App.WM_GHOSTTY_QUIT, WM_GHOSTTY_QUIT);
    try std.testing.expectEqual(App.WM_GHOSTTY_QUIT_TIMER, WM_GHOSTTY_QUIT_TIMER);
    try std.testing.expectEqual(clipboard.WM_GHOSTTY_CLIPBOARD_READ, WM_GHOSTTY_CLIPBOARD_READ);
}

test "win32 skeleton: timer ids are unique per class incl. M3" {
    try std.testing.expectEqual(@as(usize, 1), timers.msg_window.quit);
    try std.testing.expectEqual(@as(usize, 1), timers.tab.divider_drag);
    try std.testing.expectEqual(@as(usize, 1), timers.resize_overlay.hide);
    try std.testing.expectEqual(@as(usize, 1), timers.surface.resize);
    try std.testing.expectEqual(@as(usize, 0x2600), timers.window.taskbar_stale);

    // A timer id is only meaningful to the window that owns it, so ids
    // must differ within one class; the top-level window has several.
    const classes = .{
        [_]usize{ timers.msg_window.quit, timers.msg_window.recovery, timers.msg_window.release_memory, timers.msg_window.tmux_keys, timers.msg_window.update, timers.msg_window.undo_expire, timers.msg_window.jumplist_delay },
        [_]usize{ timers.surface.resize, timers.surface.decor, timers.surface.title_grace },
        [_]usize{ timers.overlay.hide, timers.overlay.search_debounce, timers.overlay.scroller_hold, timers.overlay.scroller_fade },
        [_]usize{ timers.window.strip_autoscroll, timers.window.taskbar_stale, timers.window.quick_slide, timers.window.title_debounce, timers.window.tab_tooltip, timers.window.tab_anim },
    };
    inline for (classes) |ids| {
        for (ids, 0..) |id, i| {
            for (ids[i + 1 ..]) |other| try std.testing.expect(id != other);
        }
    }
}

test "win32 skeleton: M4 timer id unique" {
    try std.testing.expectEqual(@as(usize, 4), timers.msg_window.tmux_keys);
    const ids = [_]usize{ timers.msg_window.quit, timers.msg_window.recovery, timers.msg_window.release_memory, timers.msg_window.tmux_keys };
    for (ids, 0..) |id, i| {
        for (ids[i + 1 ..]) |other| try std.testing.expect(id != other);
    }
}

test "win32 skeleton: M5 ids" {
    try std.testing.expectEqual(win32.user32.WM_APP + 16, WM_GHOSTTY_UPDATE_RESULT);
    try std.testing.expectEqual(@as(usize, 5), timers.msg_window.update);
    try std.testing.expectEqual(@as(usize, 6), timers.msg_window.undo_expire);
    try std.testing.expectEqual(@as(usize, 7), timers.msg_window.jumplist_delay);
}
