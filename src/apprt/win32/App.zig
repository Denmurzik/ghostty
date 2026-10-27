//! The Win32 application runtime. Owns the process-wide message loop,
//! the hidden message-only window and the top-level windows.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const cli = @import("../../cli.zig");
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
const composition_mod = @import("composition.zig");
const dialogs = @import("dialogs.zig");
const hooks = @import("hooks.zig");
const hotkeys_mod = @import("hotkeys.zig");
const instance = @import("instance.zig");
const ipc = struct {
    const ops = @import("ipc/ops.zig");
    const protocol = @import("ipc/protocol.zig");
    const Server = @import("ipc/Server.zig");
};
const messages = @import("messages.zig");
const notify_mod = @import("notify.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const recovery_mod = @import("recovery.zig");
const shell_open_mod = @import("shell_open.zig");
const tray_mod = @import("tray.zig");
const util = @import("util.zig");
const visibility_mod = @import("visibility.zig");
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

/// The notification-area icon; only a pipe owner has one.
tray: tray_mod.State = .{},

/// This launch was handed to the running instance: no window is created and
/// `run` returns at once, so the process exits 0.
forwarded: bool = false,

/// M3 feature state, one field per feature module.
hotkeys: hotkeys_mod.State = .{},
quick: QuickTerminal.State = .{},
notify: notify_mod.State = .{},
recovery: recovery_mod.State = .{},
visibility: visibility_mod.State = .{},
shell_open: shell_open_mod.State = .{},
composition: composition_mod.AppState = .{},

/// Set while a hard config reload runs, so that the `config_change` it
/// produces is told apart from a soft apply.
reload_pending: bool = false,

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
    errdefer _ = win32.uxtheme.BufferedPaintUnInit();

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
    if (self.forwarded) return;

    // Config is owned by us; the core clones what it needs.
    try core_app.updateConfig(self, &self.config);

    const window = try Window.create(self, .{});
    errdefer window.destroy();
    window.show();
    renderer.Device.logPrivateUsage("first surface");

    if (self.serving()) tray_mod.init(self) catch |err| {
        log.warn("unable to create the notification icon err={}", .{err});
    };

    hooks.appStarted(self);
}

/// Run the message loop until WM_QUIT.
pub fn run(self: *App) !void {
    if (self.forwarded) return;

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
    hooks.appStopping(self);
    tray_mod.deinit(self);

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

/// Whether this process owns the IPC pipe (`server != null`). A process that
/// does not (standalone after `AddressInUse`, `windows-single-instance =
/// false` next to a running instance) has no tray icon and quits after its
/// last window.
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
            self.forwarded = self.forwardLaunch(name);
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

/// Hands this launch to the instance that owns the pipe `name`, when
/// `windows-single-instance` and the arguments allow it. False: run
/// standalone (a squatter, a stale pipe, a refusal, no forwarding wanted).
fn forwardLaunch(self: *App, name: [:0]const u16) bool {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var all: std.ArrayList([]const u8) = .empty;
    var iter = cli.args.argsIterator(a, global.args()) catch return false;
    defer iter.deinit();
    while (iter.next()) |arg| all.append(a, a.dupe(u8, arg) catch return false) catch return false;
    const args = instance.withoutClass(a, all.items) catch return false;

    if (!instance.shouldForward(
        self.config.@"windows-single-instance",
        args,
        self.config.@"initial-command" != null,
    )) return false;

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(global.io(), ".", &cwd_buf) catch return false;
    const forwarded_args = instance.absolutizeWorkingDirectory(a, args, cwd_buf[0..cwd_len]) catch return false;

    switch (instance.forwardNewWindow(self.core_app.alloc, name, forwarded_args)) {
        .forwarded => return true,
        .not_our_server => log.warn("the IPC pipe is owned by another user or elevation; running standalone", .{}),
        .no_server => log.info("the IPC pipe is stale; running standalone", .{}),
        .failed => log.warn("forwarding to the running instance failed; running standalone", .{}),
    }
    return false;
}

/// Stops the IPC thread and frees the server. Only after the message loop.
fn stopServer(self: *App) void {
    const server = self.server orelse return;
    self.server = null;
    server.stop();
}

/// Handle a request from the IPC thread on the UI thread.
fn handleIpc(self: *App, pending: *ipc.Server.Pending) void {
    // Window-creating ops answer before the window is built (see
    // `handleEarly`) and give no response here.
    const response = ipc.ops.handleEarly(self, pending.alloc, pending.request, pending) orelse return;
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

/// What happens when the last window is gone. A process that does not own
/// the IPC pipe cannot be reached again, so it always ends. A pipe owner
/// stays when `quit-after-last-window-closed` is off (the tray icon and the
/// pipe keep it reachable), and otherwise quits after the delay, if any.
pub fn lastWindowAction(
    quit_after: bool,
    delay_ms: ?u32,
    pipe_owner: bool,
) enum { quit_now, quit_timer, stay } {
    if (!pipe_owner) return .quit_now;
    if (!quit_after) return .stay;
    if ((delay_ms orelse 0) == 0) return .quit_now;
    return .quit_timer;
}

/// `quit-after-last-window-closed-delay` in timer milliseconds; null if unset.
fn quitDelayMs(config: *const Config) ?u32 {
    const d = config.@"quit-after-last-window-closed-delay" orelse return null;
    return @intCast(@min(
        d.duration / std.time.ns_per_ms,
        0x7FFFFFFF, // USER_TIMER_MAXIMUM
    ));
}

/// Start the delayed quit that follows the last window closing. Called at
/// startup (before any surface exists), when the core reports that its last
/// surface is gone and when the last window is destroyed. Only has an effect
/// when no windows are open and `quit-after-last-window-closed` is set.
pub fn startQuitTimer(self: *App) void {
    self.startQuitTimerFor(&self.config);
}

/// Like `startQuitTimer`, for a config that is not applied to the app yet
/// (a runtime switch of `quit-after-last-window-closed` with no window open).
pub fn startQuitTimerFor(self: *App, config: *const Config) void {
    if (QuickTerminal.countNormal(self.windows.items) > 0) return;
    if (!config.@"quit-after-last-window-closed") return;

    if (win32.user32.SetTimer(self.msg_hwnd, quit_timer_id, quitDelayMs(config) orelse 0, null) == 0) {
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
    // The quick terminal does not keep the app open.
    if (QuickTerminal.countNormal(self.windows.items) > 0) return;
    switch (lastWindowAction(
        self.config.@"quit-after-last-window-closed",
        quitDelayMs(&self.config),
        // Without an icon nothing could bring a staying process back.
        // After a GPU device loss the process quits rather than stay resident.
        self.serving() and self.tray.hwnd != null and !renderer.Device.anyLost(),
    )) {
        .quit_now => win32.user32.PostQuitMessage(0),
        .quit_timer => self.startQuitTimer(),
        .stay => {},
    }
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

    if (hooks.appMessage(self, msg, wparam, lparam)) |result| return result;

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
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    const class: ?[]const u8 = switch (target) {
        .class => |c| c,
        .detect => null,
    };
    const name = instance.pipeNameFor(alloc, class) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ipcError("unable to build the IPC pipe name: {}", .{err});
            return error.IPCFailed;
        },
    };
    defer alloc.free(name);

    var surface_buf: [32]u8 = undefined;
    const req: ipc.protocol.Request = switch (action) {
        .new_window => .{
            .v = ipc.protocol.version,
            .op = "new-window",
            .args = argsOf(value.arguments),
        },
        .new_tab => .{
            .v = ipc.protocol.version,
            .op = "new-tab",
            .args = argsOf(value.arguments),
            .core_surface = std.fmt.bufPrint(&surface_buf, "{d}", .{value.surface_id}) catch unreachable,
        },
        .toggle_quick_terminal => .{
            .v = ipc.protocol.version,
            .op = "toggle-quick-terminal",
        },
    };

    const sent = instance.send(alloc, name, req, ipc_timeout_ms);
    defer if (sent.message) |m| alloc.free(m);
    switch (sent.result) {
        .forwarded => return true,
        .no_server => {
            ipcError("no running Ghostty instance (class {s})", .{class orelse instance.defaultClass()});
            return error.IPCFailed;
        },
        .not_our_server => {
            ipcError("the IPC pipe of class {s} is owned by a process of another user or elevation", .{class orelse instance.defaultClass()});
            return error.IPCFailed;
        },
        .failed => {
            ipcError("the running instance did not accept the request: {s}", .{sent.message orelse "no answer"});
            return error.IPCFailed;
        },
    }
}

/// How long the CLI waits for the running instance.
const ipc_timeout_ms = 3000;

fn argsOf(arguments: ?[][:0]const u8) []const []const u8 {
    const list = arguments orelse return &.{};
    // `[:0]const u8` slices are `[]const u8` slices; the list is a view.
    return @as([*]const []const u8, @ptrCast(list.ptr))[0..list.len];
}

fn ipcError(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(global.io(), &buffer);
    writer.interface.print("ghostty: " ++ fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn exitImmediately(self: *const App) bool {
    const value = @import("../../os/main.zig").windows.diagnosticEnv(
        self.core_app.alloc,
        "GHOSTTY_WIN32_EXIT_IMMEDIATELY",
    ) orelse return false;
    defer self.core_app.alloc.free(value);
    return std.mem.eql(u8, value, "1");
}

test {
    _ = util;
    _ = tray_mod;
    _ = Window;
    _ = actions;
    _ = ipc.ops;
}

test "win32 app: last window policy" {
    const Action = @typeInfo(@TypeOf(lastWindowAction)).@"fn".return_type.?;
    try std.testing.expectEqual(Action.quit_now, lastWindowAction(true, null, true));
    try std.testing.expectEqual(Action.quit_timer, lastWindowAction(true, 1000, true));
    try std.testing.expectEqual(Action.stay, lastWindowAction(false, null, true));
    try std.testing.expectEqual(Action.stay, lastWindowAction(false, 1000, true));
    try std.testing.expectEqual(Action.quit_now, lastWindowAction(false, null, false));
    try std.testing.expectEqual(Action.quit_now, lastWindowAction(true, 1000, false));
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
