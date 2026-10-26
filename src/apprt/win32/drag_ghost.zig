//! Translucent ghost window shown while a tab is dragged out of its strip.
//! One per process, main thread only. A layered, click-through popup whose
//! content is a tab chip painted into a premultiplied 32bpp DIB.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Chrome = @import("Chrome.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");
const tab_drag = @import("tab_drag.zig");
const util = @import("util.zig");

const gdi32 = win32.gdi32;
const user32 = win32.user32;

const log = std.log.scoped(.win32_drag_ghost);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const class_name = L("GhosttyDragGhost");

/// Constant alpha over the per-pixel alpha of the chip.
const ghost_alpha = 0xD8;

const State = struct {
    hwnd: win32.foundation.HWND,
    /// Chip size in pixels at `dpi`.
    size: geom.Rect,
    dpi: u32,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    pos: tab_drag.Point,
    palette: theme.Palette,
};

var state: ?State = null;

/// `source` is the window the tab comes from: its DPI and palette style the chip.
pub fn show(app: *App, source: *const Window, title: []const u8, size: geom.Rect, at: tab_drag.Point) void {
    if (state != null) hide();
    const dpi = source.dpi;

    util.registerClass(&.{
        .style = 0,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .lpszClassName = class_name,
    }) catch return;

    const hwnd = user32.CreateWindowExW(
        user32.WS_EX_LAYERED | user32.WS_EX_TRANSPARENT | user32.WS_EX_TOOLWINDOW |
            user32.WS_EX_NOACTIVATE | user32.WS_EX_TOPMOST,
        class_name,
        null,
        user32.WS_POPUP,
        at.x,
        at.y,
        size.w,
        size.h,
        null,
        null,
        app.hinstance,
        null,
    ) orelse {
        log.warn("unable to create the drag ghost err={}", .{win32.kernel32.GetLastError()});
        return;
    };

    var s: State = .{ .hwnd = hwnd, .size = size, .dpi = dpi, .pos = at, .palette = theme.palette(source) };
    s.title_len = @min(title.len, s.title_buf.len);
    @memcpy(s.title_buf[0..s.title_len], title[0..s.title_len]);
    state = s;

    if (!repaint(&state.?)) {
        hide();
        return;
    }
    _ = user32.ShowWindow(hwnd, user32.SW_SHOWNOACTIVATE);
}

pub fn moveTo(at: tab_drag.Point) void {
    const s = &(state orelse return);
    s.pos = at;
    _ = user32.SetWindowPos(
        s.hwnd,
        user32.HWND_TOPMOST,
        at.x,
        at.y,
        0,
        0,
        user32.SWP_NOSIZE | user32.SWP_NOACTIVATE,
    );
}

pub fn hide() void {
    const s = state orelse return;
    state = null;
    _ = user32.DestroyWindow(s.hwnd);
}

/// Paints the chip and hands it to the compositor. False when no bitmap
/// could be made.
fn repaint(s: *State) bool {
    const screen = user32.GetDC(null) orelse return false;
    defer _ = user32.ReleaseDC(null, screen);
    const dc = gdi32.CreateCompatibleDC(screen) orelse return false;
    defer _ = gdi32.DeleteDC(dc);

    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = s.size.w,
        .biHeight = -s.size.h,
        .biBitCount = 32,
    } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };

    if (!Chrome.paintTabChip(dc, s.size, s.title_buf[0..s.title_len], s.palette, s.dpi)) return false;

    const origin: win32.foundation.POINT = .{ .x = s.pos.x, .y = s.pos.y };
    const src: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    const size: user32.SIZE = .{ .cx = s.size.w, .cy = s.size.h };
    const blend: user32.BLENDFUNCTION = .{
        .SourceConstantAlpha = ghost_alpha,
        .AlphaFormat = user32.AC_SRC_ALPHA,
    };
    if (user32.UpdateLayeredWindow(s.hwnd, screen, &origin, &size, dc, &src, 0, &blend, user32.ULW_ALPHA) == 0) {
        log.warn("UpdateLayeredWindow failed err={}", .{win32.kernel32.GetLastError()});
        return false;
    }
    return true;
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == user32.WM_DPICHANGED) {
        if (state) |*s| if (s.hwnd == hwnd) {
            const new_dpi: u32 = @intCast(wparam & 0xFFFF);
            if (new_dpi != 0 and new_dpi != s.dpi) {
                s.size.w = @intCast(@divFloor(@as(i64, s.size.w) * new_dpi + s.dpi / 2, s.dpi));
                s.size.h = @intCast(@divFloor(@as(i64, s.size.h) * new_dpi + s.dpi / 2, s.dpi));
                s.dpi = new_dpi;
                _ = repaint(s);
            }
        };
        return 0;
    }
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "win32 drag ghost: entry points compile" {
    _ = &show;
    _ = &moveTo;
    _ = &hide;
    try std.testing.expect(state == null);
}
