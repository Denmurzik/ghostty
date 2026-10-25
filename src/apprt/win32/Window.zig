//! A top-level Win32 window. M1 hosts at most one surface per window;
//! the surface itself is attached by a later task.
const Window = @This();

const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

hwnd: win32.foundation.HWND,
app: *App,
surface: ?*Surface = null,

/// Create a hidden top-level window and register it with the app. Call
/// `show` once its content is ready.
pub fn create(app: *App) !*Window {
    const alloc = app.core_app.alloc;

    try util.registerClass(&.{
        .style = win32.user32.CS_HREDRAW | win32.user32.CS_VREDRAW | win32.user32.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .hIcon = win32.user32.LoadIconW(null, win32.user32.IDI_APPLICATION),
        .hCursor = win32.user32.LoadCursorW(null, win32.user32.IDC_ARROW),
        // Black rather than the default white so a dark terminal does not
        // flash white before the first frame.
        .hbrBackground = @ptrCast(win32.gdi32.GetStockObject(win32.gdi32.BLACK_BRUSH)),
        .lpszClassName = class_name,
    });

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .hwnd = undefined, .app = app };

    // Registered with the app up front so the WM_DESTROY handler can
    // remove it unconditionally.
    try app.windows.append(alloc, self);
    errdefer _ = app.windows.pop();

    // The window procedure sees WM_NCCREATE before this returns and stores
    // `self` as the window's user data.
    const hwnd = win32.user32.CreateWindowExW(
        0,
        class_name,
        default_title,
        win32.user32.WS_OVERLAPPEDWINDOW,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    self.hwnd = hwnd;

    const dark: win32.foundation.BOOL = @intFromBool(util.systemUsesDarkTheme());
    _ = win32.dwmapi.DwmSetWindowAttribute(
        hwnd,
        win32.dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(win32.foundation.BOOL),
    );

    return self;
}

/// Destroy the window and free it. Closing the last window quits the app.
pub fn destroy(self: *Window) void {
    // A hosted surface is destroyed before its HWND (added with hosting).
    // DestroyWindow runs the WM_DESTROY handler, which unregisters us.
    _ = win32.user32.DestroyWindow(self.hwnd);
    self.app.core_app.alloc.destroy(self);
}

pub fn show(self: *Window) void {
    _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_SHOW);
    _ = win32.user32.UpdateWindow(self.hwnd);
}

pub fn setTitle(self: *Window, title: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const wide = util.utf16z(alloc, title) catch |err| {
        log.warn("unable to convert window title err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    _ = win32.user32.SetWindowTextW(self.hwnd, wide);
}

/// Ask the window to close, as if the user had pressed the close button.
/// Deferred through the message queue, so it is safe to call while the
/// window's own surface is still on the stack.
pub fn requestClose(self: *Window) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, 0, 0);
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == win32.user32.WM_NCCREATE) {
        const cs: *const win32.user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            const self: *Window = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            util.setUserData(hwnd, self);
        }
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(Window, hwnd) orelse
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        win32.user32.WM_CLOSE => {
            // `self` is freed here; nothing may touch it afterwards.
            self.destroy();
            return 0;
        },

        win32.user32.WM_DESTROY => {
            self.app.windowDestroyed(self);
            return 0;
        },

        win32.user32.WM_NCDESTROY => util.setUserData(hwnd, null),

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
