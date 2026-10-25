//! The Win32 application runtime. Owns the process-wide message loop.
//! This is the minimal version: window management, wakeup and actions
//! arrive with later tasks.
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
const Config = configpkg.Config;

const log = std.log.scoped(.win32_app);

core_app: *CoreApp,
config: Config,
hinstance: win32.foundation.HINSTANCE,

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
    };

    // Config is owned by us; the core clones what it needs.
    try core_app.updateConfig(self, &self.config);
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
    self.config.deinit();
    win32.ole32.OleUninitialize();
}

/// Wake the UI thread so it ticks the core app. Callable from any thread.
/// A no-op until the hidden message window exists.
pub fn wakeup(self: *App) void {
    _ = self;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;
    log.debug("unimplemented action={}", .{action});
    return false;
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

test "win32 app: runtime is win32 on windows" {
    try std.testing.expect(build_config.app_runtime == .win32);
}
