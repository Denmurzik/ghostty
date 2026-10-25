//! A top-level Win32 window. M1 hosts exactly one surface, a child window
//! that fills the client area.
const Window = @This();

const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const renderer = @import("../../renderer.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const dialogs = @import("dialogs.zig");
const dpi = @import("dpi.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

/// `wparam` of a WM_CLOSE whose confirmation has already been taken care
/// of. A WM_CLOSE from the system (close button, Alt+F4) carries zero.
const close_confirmed: usize = 1;

hwnd: win32.foundation.HWND,
app: *App,
surface: ?*Surface = null,

/// Client-area limits reported by core, if any. Applied by
/// WM_GETMINMAXINFO.
size_limit: ?apprt.action.SizeLimit = null,

/// Size of one grid cell in pixels, as last reported by core.
cell_size: ?apprt.action.CellSize = null,

/// True while the "close anyway?" dialog is up, so that further close
/// requests do not stack more dialogs.
confirming_close: bool = false,

/// Create a hidden top-level window hosting a new surface and register it
/// with the app. Call `show` once its content is ready.
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
    self.* = .{ .hwnd = undefined, .app = app };

    // Registered with the app up front so the WM_DESTROY handler can
    // remove it unconditionally.
    app.windows.append(alloc, self) catch |err| {
        alloc.destroy(self);
        return err;
    };

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
        _ = app.windows.pop();
        alloc.destroy(self);
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

    // Core's start-up actions (initial size, title, ...) reach this window
    // through `surface`, which `Surface.create` sets before core init.
    const surface = Surface.create(self) catch |err| {
        log.err("unable to create surface err={}", .{err});
        self.destroy();
        return err;
    };
    self.syncSurface(surface);

    return self;
}

/// Destroy the window and free it. Closing the last window quits the app.
pub fn destroy(self: *Window) void {
    // The surface goes first: core teardown joins the render and IO
    // threads and still reads `window`, which must be alive until then.
    if (self.surface) |s| s.destroy();

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

/// Close the window without asking: the caller has already confirmed, or
/// nothing needs confirming. Deferred through the message queue, so it is
/// safe to call while the window's own surface is still on the stack.
pub fn requestClose(self: *Window) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, close_confirmed, 0);
}

/// Close the window as if the user had pressed the close button: asks
/// first when the surface has a running process.
pub fn requestCloseWithConfirm(self: *Window) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, 0, 0);
}

/// Resize the window so that its client area is `width` x `height`
/// physical pixels.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    const frame = self.frameSize();
    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        clampPixels(width) + frame.width,
        clampPixels(height) + frame.height,
        win32.user32.SWP_NOMOVE | win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
}

/// Where the surface child sits inside a client area. M1 has no padding
/// or tab strip, so it is the whole area.
pub fn childRect(client: win32.foundation.RECT) win32.foundation.RECT {
    return client;
}

/// A pixel count as a signed coordinate; no real window is anywhere near
/// the limit.
fn clampPixels(v: u32) i32 {
    return @intCast(@min(v, 1 << 24));
}

/// Apply core's client-area limits to a WM_GETMINMAXINFO, adding the
/// non-client frame. A zero limit leaves the system default.
fn applySizeLimit(
    info: *win32.user32.MINMAXINFO,
    limit: apprt.action.SizeLimit,
    frame_width: i32,
    frame_height: i32,
) void {
    if (limit.min_width > 0) info.ptMinTrackSize.x = clampPixels(limit.min_width) + frame_width;
    if (limit.min_height > 0) info.ptMinTrackSize.y = clampPixels(limit.min_height) + frame_height;
    if (limit.max_width > 0) info.ptMaxTrackSize.x = clampPixels(limit.max_width) + frame_width;
    if (limit.max_height > 0) info.ptMaxTrackSize.y = clampPixels(limit.max_height) + frame_height;
}

/// The non-client size: window size minus client size, at the window's DPI.
fn frameSize(self: *const Window) struct { width: i32, height: i32 } {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const style: u32 = @truncate(@as(usize, @bitCast(
        win32.user32.GetWindowLongPtrW(self.hwnd, win32.user32.GWL_STYLE),
    )));
    const ex_style: u32 = @truncate(@as(usize, @bitCast(
        win32.user32.GetWindowLongPtrW(self.hwnd, win32.user32.GWL_EXSTYLE),
    )));
    _ = win32.user32.AdjustWindowRectExForDpi(
        &rc,
        style,
        0,
        ex_style,
        win32.user32.GetDpiForWindow(self.hwnd),
    );
    return .{ .width = rc.right - rc.left, .height = rc.bottom - rc.top };
}

/// Make the child fill a client area of the given size.
fn layoutChild(surface: *Surface, client_width: i32, client_height: i32) void {
    const rect = childRect(.{ .left = 0, .top = 0, .right = client_width, .bottom = client_height });
    _ = win32.user32.SetWindowPos(
        surface.hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
}

/// Bring core up to date after surface creation. Core's start-up actions
/// (`initial_size`) resize the window while the surface is still
/// initializing, and the resulting child WM_SIZE never reaches core.
fn syncSurface(self: *Window, surface: *Surface) void {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.user32.GetClientRect(self.hwnd, &rc);
    layoutChild(surface, rc.right - rc.left, rc.bottom - rc.top);

    const size = renderer.D3D11.unpackSize(surface.size.load(.acquire));
    if (size.width == 0 or size.height == 0) return;
    surface.core_surface.sizeCallback(.{ .width = size.width, .height = size.height }) catch |err|
        log.warn("size callback failed err={}", .{err});
}

fn handleSize(self: *Window, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) void {
    const surface = self.surface orelse return;

    // The child never sees the parent's minimize (it keeps its own size),
    // so occlusion is forwarded from here.
    if (wparam == win32.user32.SIZE_MINIMIZED) {
        if (surface.minimized) return;
        surface.minimized = true;
        if (surface.initialized) surface.core_surface.occlusionCallback(false) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
        return;
    }
    if (wparam != win32.user32.SIZE_RESTORED and wparam != win32.user32.SIZE_MAXIMIZED) return;

    if (surface.minimized) {
        surface.minimized = false;
        if (surface.initialized) surface.core_surface.occlusionCallback(true) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }

    const bits: usize = @bitCast(lparam);
    layoutChild(surface, @intCast(bits & 0xFFFF), @intCast((bits >> 16) & 0xFFFF));
}

fn handleDpiChanged(self: *Window, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) void {
    const suggested: *const win32.foundation.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        suggested.left,
        suggested.top,
        suggested.right - suggested.left,
        suggested.bottom - suggested.top,
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );

    // The child is told too (WM_DPICHANGED_AFTERPARENT); core ignores the
    // repeat.
    const surface = self.surface orelse return;
    surface.content_scale = dpi.contentScale(@intCast(wparam & 0xFFFF));
    if (!surface.initialized) return;
    surface.core_surface.contentScaleCallback(surface.content_scale) catch |err|
        log.warn("content scale callback failed err={}", .{err});
}

fn handleMinMaxInfo(self: *const Window, lparam: win32.foundation.LPARAM) void {
    const limit = self.size_limit orelse return;
    const info: *win32.user32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const frame = self.frameSize();
    applySizeLimit(info, limit, frame.width, frame.height);
}

fn handleClose(self: *Window, wparam: win32.foundation.WPARAM) void {
    const hwnd = self.hwnd;
    if (wparam != close_confirmed) {
        if (self.confirming_close) return;

        if (self.surface) |s| {
            if (s.initialized and s.core_surface.needsConfirmQuit()) {
                self.confirming_close = true;
                const close = dialogs.confirmClose(hwnd);

                // The dialog runs a message loop: the window may have been
                // closed behind it (the shell exited), freeing `self`.
                if (util.fromUserData(Window, hwnd) == null) return;
                self.confirming_close = false;
                if (!close) return;
            }
        }
    }

    // `self` is freed here; nothing may touch it afterwards.
    self.destroy();
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
            self.handleClose(wparam);
            return 0;
        },

        win32.user32.WM_SIZE => {
            self.handleSize(wparam, lparam);
            return 0;
        },

        win32.user32.WM_DPICHANGED => {
            self.handleDpiChanged(wparam, lparam);
            return 0;
        },

        win32.user32.WM_GETMINMAXINFO => {
            self.handleMinMaxInfo(lparam);
            return 0;
        },

        // Keyboard input goes to the surface, never to the frame.
        win32.user32.WM_SETFOCUS => {
            if (self.surface) |s| _ = win32.user32.SetFocus(s.hwnd);
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

test "win32 window: child rect fills the client area" {
    const client: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 1280, .bottom = 720 };
    const rect = childRect(client);
    try std.testing.expectEqual(@as(i32, 0), rect.left);
    try std.testing.expectEqual(@as(i32, 0), rect.top);
    try std.testing.expectEqual(@as(i32, 1280), rect.right);
    try std.testing.expectEqual(@as(i32, 720), rect.bottom);
}

test "win32 window: size limit adds the frame and ignores zero" {
    var info: win32.user32.MINMAXINFO = std.mem.zeroes(win32.user32.MINMAXINFO);
    info.ptMinTrackSize = .{ .x = 136, .y = 39 };
    info.ptMaxTrackSize = .{ .x = 4000, .y = 3000 };

    applySizeLimit(&info, .{ .min_width = 200, .min_height = 100, .max_width = 0, .max_height = 0 }, 16, 39);
    try std.testing.expectEqual(@as(i32, 216), info.ptMinTrackSize.x);
    try std.testing.expectEqual(@as(i32, 139), info.ptMinTrackSize.y);
    try std.testing.expectEqual(@as(i32, 4000), info.ptMaxTrackSize.x);
    try std.testing.expectEqual(@as(i32, 3000), info.ptMaxTrackSize.y);

    applySizeLimit(&info, .{ .min_width = 0, .min_height = 0, .max_width = 800, .max_height = 600 }, 16, 39);
    try std.testing.expectEqual(@as(i32, 816), info.ptMaxTrackSize.x);
    try std.testing.expectEqual(@as(i32, 639), info.ptMaxTrackSize.y);
    try std.testing.expectEqual(@as(i32, 216), info.ptMinTrackSize.x);
}
