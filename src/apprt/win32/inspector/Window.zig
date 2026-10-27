//! The top-level window of one inspector: class `GhosttyInspector`, a
//! taskbar entry of its own, a dark caption. It only owns the HWND and its
//! window procedure; the imgui context and the swap chain live in the
//! `Inspector` that owns the window.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const cimgui = @import("dcimgui");
const geom = @import("../geom.zig");
const messages = @import("../messages.zig");
const util = @import("../util.zig");
const Inspector = @import("Inspector.zig").Inspector;

const log = std.log.scoped(.win32_inspector);
const user32 = win32.user32;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyInspector");

/// Render tick of an open inspector, about 30 Hz.
pub const tick_id: usize = messages.timers.inspector.render;
pub const tick_ms: u32 = 33;

/// Size of a new window in DIPs.
const default_width = 800;
const default_height = 600;

/// Resource id of the icon of the exe (`Window.zig`).
const icon_resource_id = 1;

pub const Options = struct {
    hinstance: win32.foundation.HINSTANCE,
    title: []const u8,
    dpi: u32,
    /// Hidden windows are for tests.
    show: bool = true,
};

hwnd: win32.foundation.HWND,
dpi: u32,

/// The inspector the window procedure forwards to; set by the inspector once
/// it can take messages, cleared before the window goes.
inspector: ?*Inspector = null,

/// Whether the render tick runs; it stops while the window is minimized.
timer_running: bool = false,

pub fn create(alloc: Allocator, opts: Options) !*Window {
    try util.registerClass(&.{
        .style = 0,
        .lpfnWndProc = wndProc,
        .hInstance = opts.hinstance,
        .hIcon = icon(opts.hinstance),
        .hCursor = user32.LoadCursorW(null, user32.IDC_ARROW),
        // Every pixel is painted by imgui.
        .lpszClassName = class_name,
    });

    const title = try util.utf16z(alloc, opts.title);
    defer alloc.free(title);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .hwnd = undefined, .dpi = opts.dpi };

    // The window procedure sees WM_NCCREATE before this returns and stores
    // `self` as the window's user data.
    const hwnd = user32.CreateWindowExW(
        user32.WS_EX_APPWINDOW,
        class_name,
        title,
        user32.WS_OVERLAPPEDWINDOW,
        user32.CW_USEDEFAULT,
        user32.CW_USEDEFAULT,
        geom.scale(default_width, opts.dpi),
        geom.scale(default_height, opts.dpi),
        null,
        null,
        opts.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    self.hwnd = hwnd;

    // CW_USEDEFAULT may have put the window on another monitor than the
    // surface's, which gives no WM_DPICHANGED at creation.
    const actual = user32.GetDpiForWindow(hwnd);
    if (actual != 0 and actual != opts.dpi) {
        self.dpi = actual;
        _ = user32.SetWindowPos(hwnd, null, 0, 0, geom.scale(default_width, actual), geom.scale(default_height, actual), user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    }

    const dark: win32.foundation.BOOL = 1;
    _ = win32.dwmapi.DwmSetWindowAttribute(
        hwnd,
        win32.dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(win32.foundation.BOOL),
    );

    if (opts.show) _ = user32.ShowWindow(hwnd, user32.SW_SHOW);
    return self;
}

/// Destroys the HWND, which stops its timer. Nothing reaches the inspector
/// from here on.
pub fn destroy(self: *Window, alloc: Allocator) void {
    self.inspector = null;
    util.setUserData(self.hwnd, null);
    _ = user32.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

pub fn startTimer(self: *Window) void {
    if (self.timer_running) return;
    self.timer_running = user32.SetTimer(self.hwnd, tick_id, tick_ms, null) != 0;
}

pub fn stopTimer(self: *Window) void {
    if (!self.timer_running) return;
    _ = user32.KillTimer(self.hwnd, tick_id);
    self.timer_running = false;
}

pub fn setTitle(self: *Window, alloc: Allocator, title: []const u8) void {
    const wide = util.utf16z(alloc, title) catch return;
    defer alloc.free(wide);
    _ = user32.SetWindowTextW(self.hwnd, wide);
}

/// Brings the window to the front, restoring it when minimized.
pub fn raise(self: *Window) void {
    if (user32.IsIconic(self.hwnd) != 0) _ = user32.ShowWindow(self.hwnd, user32.SW_RESTORE);
    _ = user32.ShowWindow(self.hwnd, user32.SW_SHOW);
    _ = user32.SetForegroundWindow(self.hwnd);
}

pub fn isForeground(self: *const Window) bool {
    return user32.GetForegroundWindow() == self.hwnd;
}

pub fn clientSize(self: *const Window) struct { w: u32, h: u32 } {
    var rc: win32.foundation.RECT = std.mem.zeroes(win32.foundation.RECT);
    _ = user32.GetClientRect(self.hwnd, &rc);
    return .{
        .w = @intCast(@max(0, rc.right - rc.left)),
        .h = @intCast(@max(0, rc.bottom - rc.top)),
    };
}

fn icon(hinstance: win32.foundation.HINSTANCE) ?user32.HICON {
    const id: *const anyopaque = @ptrFromInt(icon_resource_id);
    return user32.LoadIconW(hinstance, id) orelse user32.LoadIconW(null, user32.IDI_APPLICATION);
}

/// Whether a message may have changed what imgui shows: it asks for a frame
/// at the next tick.
fn changesFrame(msg: u32) bool {
    return switch (msg) {
        user32.WM_SIZE,
        user32.WM_PAINT,
        user32.WM_DPICHANGED,
        0x0007, // WM_SETFOCUS
        0x0008, // WM_KILLFOCUS
        0x0020, // WM_SETCURSOR
        0x0100...0x0109, // WM_KEYDOWN .. WM_SYSDEADCHAR
        0x0200...0x020E, // WM_MOUSEMOVE .. WM_MOUSEHWHEEL
        0x02A3, // WM_MOUSELEAVE
        => true,
        else => false,
    };
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == user32.WM_NCCREATE) {
        const cs: *const user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| util.setUserData(hwnd, param);
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(Window, hwnd) orelse
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const insp = self.inspector orelse
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // The backend looks the window up through the current context.
    cimgui.c.ImGui_SetCurrentContext(insp.ig_ctx);
    if (cimgui.ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam) != 0) {
        insp.dirty = true;
        return 1;
    }
    if (changesFrame(msg)) insp.dirty = true;

    switch (msg) {
        user32.WM_TIMER => {
            if (wparam == tick_id) insp.tick();
            return 0;
        },
        user32.WM_SIZE => {
            if (wparam == user32.SIZE_MINIMIZED) self.stopTimer() else self.startTimer();
            return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        user32.WM_ERASEBKGND => return 1,
        user32.WM_DPICHANGED => {
            const suggested: *const win32.foundation.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.dpi = @as(u32, @truncate(wparam)) & 0xFFFF;
            _ = user32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                user32.SWP_NOZORDER | user32.SWP_NOACTIVATE,
            );
            insp.dpiChanged(self.dpi);
            return 0;
        },
        user32.WM_CLOSE => {
            // Frees the window and the inspector: nothing may touch them
            // after this.
            insp.close();
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
