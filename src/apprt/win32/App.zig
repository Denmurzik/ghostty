//! The Win32 application runtime. Owns the process-wide message loop,
//! the hidden message-only window and the top-level windows.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Window = @import("Window.zig");
const mouse = @import("mouse.zig");
const util = @import("util.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.win32_app);

/// Posted to `msg_hwnd` by `wakeup` to have the core app ticked.
pub const WM_GHOSTTY_WAKEUP = win32.user32.WM_APP + 1;
// WM_APP + 2 is reserved for the surface clipboard message (Task 26).
/// Reserved for quit timer notifications on `msg_hwnd`.
pub const WM_GHOSTTY_QUIT_TIMER = win32.user32.WM_APP + 3;

/// Timer id on `msg_hwnd` for the delayed quit after the last window.
const quit_timer_id: usize = 1;

const msg_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessageWindow");

core_app: *CoreApp,
config: Config,
hinstance: win32.foundation.HINSTANCE,

/// Hidden message-only window: receives wakeups and timers.
msg_hwnd: win32.foundation.HWND,

/// Top-level windows, in creation order. Main thread only.
windows: std.ArrayList(*Window) = .empty,

/// True while a WM_GHOSTTY_WAKEUP is queued and not yet handled, so that
/// bursts of `wakeup` calls from other threads post a single message.
wakeup_pending: std.atomic.Value(bool) = .init(false),

pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
    _ = opts;

    // OLE (not plain COM) because drag-and-drop and the clipboard need it.
    try win32.foundation.check(win32.ole32.OleInitialize(null));
    errdefer win32.ole32.OleUninitialize();

    const hinstance = win32.kernel32.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;

    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .msg_hwnd = undefined,
    };

    try self.createMessageWindow();
    errdefer _ = win32.user32.DestroyWindow(self.msg_hwnd);

    // Config is owned by us; the core clones what it needs.
    try core_app.updateConfig(self, &self.config);

    const window = try Window.create(self);
    errdefer window.destroy();
    window.show();
}

/// Run the message loop until WM_QUIT.
pub fn run(self: *App) !void {
    // Test hook: with no window to close there is otherwise no way to leave
    // the loop, so the e2e smoke tests ask to quit before the first message.
    if (self.exitImmediately()) win32.user32.PostQuitMessage(0);

    var msg: win32.user32.MSG = undefined;
    while (win32.user32.GetMessageW(&msg, null, 0, 0) > 0) {
        // Required: translates key messages into WM_CHAR.
        _ = win32.user32.TranslateMessage(&msg);
        _ = win32.user32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    // Each window unregisters itself while being destroyed.
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
    self.windows.deinit(self.core_app.alloc);

    _ = win32.user32.DestroyWindow(self.msg_hwnd);
    self.config.deinit();
    win32.ole32.OleUninitialize();
}

/// Wake the UI thread so it ticks the core app. Callable from any thread.
/// Wakeups are coalesced: at most one message is queued at a time.
pub fn wakeup(self: *App) void {
    if (self.wakeup_pending.swap(true, .acq_rel)) return;
    if (win32.user32.PostMessageW(self.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0) == 0) {
        // Queue full or window gone: allow the next call to try again.
        self.wakeup_pending.store(false, .release);
    }
}

/// Start the delayed quit that follows the last window closing. Called at
/// startup (before any surface exists) and when the core reports that its
/// last surface is gone. Only has an effect when no windows are open and
/// `quit-after-last-window-closed` is set; closing the last window itself
/// quits immediately.
pub fn startQuitTimer(self: *App) void {
    if (self.windows.items.len > 0) return;
    if (!self.config.@"quit-after-last-window-closed") return;

    const delay_ns: u64 = if (self.config.@"quit-after-last-window-closed-delay") |d|
        d.duration
    else
        0;
    const delay_ms: u32 = @intCast(@min(
        delay_ns / std.time.ns_per_ms,
        0x7FFFFFFF, // USER_TIMER_MAXIMUM
    ));
    if (win32.user32.SetTimer(self.msg_hwnd, quit_timer_id, delay_ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
    }
}

fn stopQuitTimer(self: *App) void {
    _ = win32.user32.KillTimer(self.msg_hwnd, quit_timer_id);
}

/// Called from the window procedure when a top-level window goes away.
pub fn windowDestroyed(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w, i| {
        if (w != window) continue;
        _ = self.windows.orderedRemove(i);
        break;
    }

    if (self.windows.items.len == 0) win32.user32.PostQuitMessage(0);
}

fn windowForSurface(self: *App, surface: *CoreSurface) ?*Window {
    for (self.windows.items) |w| {
        const s = w.surface orelse continue;
        if (&s.core_surface == surface) return w;
    }
    return null;
}

fn windowForTarget(self: *App, target: apprt.Target) ?*Window {
    return switch (target) {
        .app => null,
        .surface => |s| self.windowForSurface(s),
    };
}

fn createMessageWindow(self: *App) !void {
    try util.registerClass(&.{
        .lpfnWndProc = msgWndProc,
        .hInstance = self.hinstance,
        .lpszClassName = msg_class_name,
    });

    self.msg_hwnd = win32.user32.CreateWindowExW(
        0,
        msg_class_name,
        null,
        0,
        0,
        0,
        0,
        0,
        win32.user32.HWND_MESSAGE,
        null,
        self.hinstance,
        self,
    ) orelse {
        log.err("message window creation failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
}

fn msgWndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == win32.user32.WM_NCCREATE) {
        const cs: *const win32.user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        util.setUserData(hwnd, cs.lpCreateParams);
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(App, hwnd) orelse
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_GHOSTTY_WAKEUP => {
            // Clear before ticking so a wakeup that arrives during the
            // tick queues another one instead of being lost.
            self.wakeup_pending.store(false, .release);
            self.core_app.tick(self) catch |err| {
                log.err("error ticking core app err={}", .{err});
            };
            return 0;
        },

        win32.user32.WM_TIMER => if (wparam == quit_timer_id) {
            self.stopQuitTimer();
            win32.user32.PostQuitMessage(0);
            return 0;
        },

        win32.user32.WM_NCDESTROY => util.setUserData(hwnd, null),

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            win32.user32.PostQuitMessage(0);
            return true;
        },

        .close_window => {
            const surface = switch (target) {
                .app => return false,
                .surface => |s| s,
            };
            const window = self.windowForSurface(surface) orelse return false;
            window.requestCloseWithConfirm();
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .set_title => {
            const surface = switch (target) {
                .app => return false,
                .surface => |s| s,
            };
            const window = self.windowForSurface(surface) orelse return false;
            // The surface keeps the copy that core reads back with getTitle.
            if (window.surface) |s| s.setTitle(value.title) catch |err| {
                log.warn("unable to store title err={}", .{err});
                return false;
            };
            window.setTitle(value.title);
            return true;
        },

        .initial_size => {
            const window = self.windowForTarget(target) orelse return false;
            window.setInitialSize(value.width, value.height);
            return true;
        },

        .size_limit => {
            const window = self.windowForTarget(target) orelse return false;
            window.size_limit = value;
            return true;
        },

        .cell_size => {
            const window = self.windowForTarget(target) orelse return false;
            window.cell_size = value;
            return true;
        },

        .mouse_shape => {
            const window = self.windowForTarget(target) orelse return false;
            const s = window.surface orelse return false;
            s.mouse_state.shape = value;
            mouse.refreshCursor(s);
            return true;
        },

        .mouse_visibility => {
            const window = self.windowForTarget(target) orelse return false;
            const s = window.surface orelse return false;
            s.mouse_state.hidden = value == .hidden;
            mouse.refreshCursor(s);
            return true;
        },

        // A false return makes core handle the exit itself, per
        // `wait-after-command`.
        .show_child_exited => return false,

        // Drawing is driven by the renderer thread; nothing to do here.
        .render => return true,

        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }
}

/// Send the given IPC to a running Ghostty. Static because it is called from
/// a CLI process that has no apprt App.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    switch (action) {
        .new_window => return false,
        .new_tab => return false,
        .toggle_quick_terminal => return false,
    }
}

fn exitImmediately(self: *const App) bool {
    const value = global.environ().getAlloc(
        self.core_app.alloc,
        "GHOSTTY_WIN32_EXIT_IMMEDIATELY",
    ) catch return false;
    defer self.core_app.alloc.free(value);
    return std.mem.eql(u8, value, "1");
}

test {
    _ = util;
    _ = Window;
}

test "win32 app: runtime is win32 on windows" {
    try std.testing.expect(build_config.app_runtime == .win32);
}

test "win32 app: wakeup coalesces" {
    var app: App = undefined;
    app.hinstance = win32.kernel32.GetModuleHandleW(null).?;
    app.wakeup_pending = .init(false);
    try app.createMessageWindow();
    defer _ = win32.user32.DestroyWindow(app.msg_hwnd);

    const Spammer = struct {
        fn run(a: *App) void {
            for (0..250) |_| a.wakeup();
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Spammer.run, .{&app});
    for (threads) |t| t.join();

    // Nothing pumps this queue, so only the first wakeup of each burst is
    // posted. Count what is queued without dispatching it.
    var queued: usize = 0;
    var msg: win32.user32.MSG = undefined;
    while (win32.user32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_WAKEUP,
        win32.user32.PM_REMOVE,
    ) != 0) queued += 1;
    try std.testing.expect(queued >= 1 and queued <= 4);
}
