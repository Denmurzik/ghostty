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
const renderer = @import("../../renderer.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const Chrome = @import("Chrome.zig");
const actions = @import("actions.zig");
const dialogs = @import("dialogs.zig");
const instance = @import("instance.zig");
const ipc = struct {
    const ops = @import("ipc/ops.zig");
    const Server = @import("ipc/Server.zig");
};
const messages = @import("messages.zig");
const util = @import("util.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.win32_app);

pub const WM_GHOSTTY_WAKEUP = messages.WM_GHOSTTY_WAKEUP;
pub const WM_GHOSTTY_QUIT_TIMER = messages.WM_GHOSTTY_QUIT_TIMER;
pub const WM_GHOSTTY_QUIT = messages.WM_GHOSTTY_QUIT;
pub const WM_GHOSTTY_IPC = messages.WM_GHOSTTY_IPC;

/// Timer id on `msg_hwnd` for the delayed quit after the last window.
const quit_timer_id: usize = messages.timers.msg_window.quit;

const msg_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessageWindow");

core_app: *CoreApp,
config: Config,
hinstance: win32.foundation.HINSTANCE,

/// Hidden message-only window: receives wakeups and timers.
msg_hwnd: win32.foundation.HWND,

/// Top-level windows, in creation order. Main thread only.
windows: std.ArrayList(*Window) = .empty,

/// The window that was active last; null when there is none.
last_active: ?*Window = null,

/// True while a WM_GHOSTTY_WAKEUP is queued and not yet handled, so that
/// bursts of `wakeup` calls from other threads post a single message.
wakeup_pending: std.atomic.Value(bool) = .init(false),

/// The IPC pipe server; null when another instance owns the pipe or the
/// server could not start. Main thread only.
server: ?*ipc.Server = null,

/// Guards the quit confirmation dialog against a second quit request
/// (its message loop keeps dispatching).
quit_gate: QuitGate = .{},

/// Decides whether a quit request proceeds. The confirmation dialog runs a
/// message loop, so further requests that arrive while it is up are dropped.
const QuitGate = struct {
    confirming: bool = false,

    /// True if the app should quit. `asker` has `fn confirm() bool`, and is
    /// only called when `needs_confirm` is set and no dialog is up already.
    fn decide(self: *QuitGate, needs_confirm: bool, asker: anytype) bool {
        if (self.confirming) return false;
        if (!needs_confirm) return true;
        self.confirming = true;
        defer self.confirming = false;
        return asker.confirm();
    }
};

pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
    _ = opts;

    // Before anything can spawn a child process.
    ipc.ops.cacheTestOps(core_app.alloc);

    // OLE (not plain COM) because drag-and-drop and the clipboard need it.
    try win32.foundation.check(win32.ole32.OleInitialize(null));
    errdefer win32.ole32.OleUninitialize();

    _ = win32.uxtheme.BufferedPaintInit();

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

    // Claimed before any window exists: a second launch 50 ms later already
    // finds the pipe and queues in it.
    self.startServer();
    errdefer self.stopServer();

    // Config is owned by us; the core clones what it needs.
    try core_app.updateConfig(self, &self.config);

    const window = try Window.create(self, .{});
    errdefer window.destroy();
    window.show();
    renderer.Device.logPrivateUsage("first surface");
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
    // The message loop is over: no WM_GHOSTTY_IPC can touch a freed request.
    self.stopServer();

    // Popped before they are destroyed: a window whose DestroyWindow fails
    // never gets to unregister itself, and must not be retried forever.
    self.last_active = null;
    while (self.windows.pop()) |window| window.destroy();
    self.windows.deinit(self.core_app.alloc);

    Chrome.deinitShared();
    _ = win32.uxtheme.BufferedPaintUnInit();

    _ = win32.user32.DestroyWindow(self.msg_hwnd);
    self.config.deinit();
    win32.ole32.OleUninitialize();
}

/// Whether this instance owns the IPC pipe.
pub fn serving(self: *const App) bool {
    return self.server != null;
}

fn startServer(self: *App) void {
    const alloc = self.core_app.alloc;
    const name = instance.pipeNameFor(alloc, self.config.class) catch |err| {
        log.warn("unable to build the IPC pipe name err={}", .{err});
        return;
    };
    defer alloc.free(name);

    const server = ipc.Server.claim(alloc, name) catch |err| switch (err) {
        error.AddressInUse => {
            log.info("another instance owns the IPC pipe", .{});
            return;
        },
        else => {
            log.warn("unable to claim the IPC pipe err={}", .{err});
            return;
        },
    };
    server.start(self.msg_hwnd) catch |err| {
        log.warn("unable to start the IPC server err={}", .{err});
        server.stop();
        return;
    };
    self.server = server;
}

/// Stops the IPC thread and frees the server. Only after the message loop.
fn stopServer(self: *App) void {
    const server = self.server orelse return;
    self.server = null;
    server.stop();
}

/// Handle a request from the IPC thread on the UI thread.
fn handleIpc(self: *App, pending: *ipc.Server.Pending) void {
    const response = ipc.ops.handle(self, pending.alloc, pending.request);
    ipc.Server.complete(pending, response);
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

pub fn stopQuitTimer(self: *App) void {
    _ = win32.user32.KillTimer(self.msg_hwnd, quit_timer_id);
}

/// Drop a window from the app's list; false if it was not listed.
pub fn unregisterWindow(self: *App, window: *Window) bool {
    if (self.last_active == window) self.last_active = null;
    for (self.windows.items, 0..) |w, i| {
        if (w != window) continue;
        _ = self.windows.orderedRemove(i);
        return true;
    }
    return false;
}

/// Called from the window procedure when a top-level window goes away.
pub fn windowDestroyed(self: *App, window: *Window) void {
    _ = self.unregisterWindow(window);
    if (self.windows.items.len == 0) win32.user32.PostQuitMessage(0);
}

/// The apprt surface of a core surface.
pub fn surfaceFor(self: *App, core: *CoreSurface) ?*Surface {
    _ = self;
    return core.rt_surface;
}

/// The window that holds a core surface.
pub fn windowFor(self: *App, core: *CoreSurface) ?*Window {
    return (self.surfaceFor(core) orelse return null).window;
}

pub fn windowForTarget(self: *App, target: apprt.Target) ?*Window {
    return switch (target) {
        .app => null,
        .surface => |s| self.windowFor(s),
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

        WM_GHOSTTY_QUIT => {
            self.handleQuit();
            return 0;
        },

        WM_GHOSTTY_IPC => {
            // After `stopServer` the request belongs to the server again.
            if (self.server == null) return 0;
            self.handleIpc(@ptrFromInt(@as(usize, @bitCast(lparam))));
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

/// Handle a `quit` request on the UI thread. Like GTK, ask first when a
/// surface has a running process (`confirm-close-surface` is applied by
/// `needsConfirmQuit`). The default answer is "No".
fn handleQuit(self: *App) void {
    const Asker = struct {
        app: *App,
        fn confirm(a: @This()) bool {
            // Owner: the most recent window. Without one nothing can be lost.
            if (a.app.windows.items.len == 0) return true;
            return dialogs.confirmCloseKind(
                a.app.windows.items[a.app.windows.items.len - 1].hwnd,
                .app,
            );
        }
    };
    if (self.quit_gate.decide(
        self.core_app.needsConfirmQuit(),
        Asker{ .app = self },
    )) win32.user32.PostQuitMessage(0);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return actions.perform(self, target, action, value);
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
    _ = actions;
    _ = ipc.ops;
}

test "win32 app: runtime is win32 on windows" {
    try std.testing.expect(build_config.app_runtime == .win32);
}

test "win32 app: quit gate asks only when confirmation is needed" {
    const Asker = struct {
        answer: bool,
        calls: u32 = 0,
        gate: ?*QuitGate = null,
        reentrant: ?bool = null,
        fn confirm(a: *@This()) bool {
            a.calls += 1;
            if (a.gate) |g| a.reentrant = g.decide(true, a);
            return a.answer;
        }
    };

    var gate: QuitGate = .{};
    var none: Asker = .{ .answer = false };
    try std.testing.expect(gate.decide(false, &none));
    try std.testing.expectEqual(@as(u32, 0), none.calls);

    var yes: Asker = .{ .answer = true };
    try std.testing.expect(gate.decide(true, &yes));
    try std.testing.expectEqual(@as(u32, 1), yes.calls);

    var no: Asker = .{ .answer = false };
    try std.testing.expect(!gate.decide(true, &no));
    try std.testing.expect(!gate.confirming);

    // A request arriving while the dialog is up is dropped, not stacked.
    var nested: Asker = .{ .answer = true, .gate = &gate };
    try std.testing.expect(gate.decide(true, &nested));
    try std.testing.expectEqual(@as(u32, 1), nested.calls);
    try std.testing.expectEqual(@as(?bool, false), nested.reentrant);
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

test "win32 app: wakeup re-arms after the queued message is handled" {
    var core_app: CoreApp = undefined;
    try core_app.init(std.testing.allocator);
    defer core_app.deinit();

    var app: App = undefined;
    app.core_app = &core_app;
    app.hinstance = win32.kernel32.GetModuleHandleW(null).?;
    app.wakeup_pending = .init(false);
    try app.createMessageWindow();
    defer _ = win32.user32.DestroyWindow(app.msg_hwnd);

    app.wakeup();
    try std.testing.expect(app.wakeup_pending.load(.acquire));

    var msg: win32.user32.MSG = undefined;
    try std.testing.expect(win32.user32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_WAKEUP,
        win32.user32.PM_REMOVE,
    ) != 0);
    _ = win32.user32.DispatchMessageW(&msg);
    try std.testing.expect(!app.wakeup_pending.load(.acquire));

    app.wakeup();
    try std.testing.expect(win32.user32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_WAKEUP,
        win32.user32.PM_REMOVE,
    ) != 0);
}
