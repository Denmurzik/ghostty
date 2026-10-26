//! The "cols x rows" overlay shown while resizing: a small owned popup that
//! never takes focus, painted with Direct2D and hidden by a window timer.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Surface = @import("Surface.zig");
const Chrome = @import("Chrome.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_resize_overlay);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const class_name = L("GhosttyResizeOverlay");

/// `WM_MOUSEACTIVATE` result: do not activate, and eat the click.
const ma_noactivate = 3;

/// Sizes at 96 DPI, from macOS `SurfaceResizeOverlay`: 5 pt padding, 13 pt text, no margin to the edge.
const margin_px = 0;
const pad_x = 5;
const char_w = 8;
const height_px = 26;
const corner_px = 4;

pub const State = struct {
    hwnd: ?win32.foundation.HWND = null,
    /// Whether a size was already reported; `after-first` skips the first.
    armed: bool = false,
    /// The surface and grid of the last report, to ignore repeats.
    last_surface: ?*const Surface = null,
    last_cols: u32 = 0,
    last_rows: u32 = 0,
    /// What the popup paints, set when it is shown.
    text: [32]u16 = undefined,
    text_len: usize = 0,
    dpi: u32 = 96,
    pal: ?theme.Palette = null,
};

pub const Size = struct { w: i32, h: i32 };

/// The popup rectangle of `size` inside `surface`, `margin` away from the
/// edges it is attached to. Never starts left of or above the surface.
pub fn placement(
    pos: configpkg.Config.ResizeOverlayPosition,
    surface: geom.Rect,
    size: Size,
    margin: i32,
) geom.Rect {
    const left = surface.x + margin;
    const right = surface.right() - size.w - margin;
    const center_x = surface.x + @divTrunc(surface.w - size.w, 2);
    const top = surface.y + margin;
    const bottom = surface.bottom() - size.h - margin;
    const center_y = surface.y + @divTrunc(surface.h - size.h, 2);

    const x: i32, const y: i32 = switch (pos) {
        .center => .{ center_x, center_y },
        .@"top-left" => .{ left, top },
        .@"top-center" => .{ center_x, top },
        .@"top-right" => .{ right, top },
        .@"bottom-left" => .{ left, bottom },
        .@"bottom-center" => .{ center_x, bottom },
        .@"bottom-right" => .{ right, bottom },
    };
    return .{
        .x = @max(x, surface.x),
        .y = @max(y, surface.y),
        .w = size.w,
        .h = size.h,
    };
}

/// Core applied a new size to `surface`. Shows the popup with the grid size
/// as configured by `resize-overlay`.
pub fn notify(surface: *Surface, cols: u32, rows: u32) void {
    const window = surface.window;
    const state = &window.overlay;
    const config = &window.app.config;

    const was_armed = state.armed;
    state.armed = true;
    switch (config.@"resize-overlay") {
        .never => return,
        .always => {},
        .@"after-first" => if (!was_armed) return,
    }

    // Layout passes report the grid they already have; only a change shows.
    if (state.last_surface == surface and state.last_cols == cols and state.last_rows == rows) return;
    state.last_surface = surface;
    state.last_cols = cols;
    state.last_rows = rows;

    show(surface, state, config, cols, rows) catch |err| {
        log.warn("unable to show the resize overlay err={}", .{err});
    };
}

fn show(surface: *Surface, state: *State, config: *const configpkg.Config, cols: u32, rows: u32) !void {
    const window = surface.window;
    if (user32.IsIconic(window.hwnd) != 0 or user32.IsWindowVisible(surface.hwnd) == 0) return;

    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d} \u{2A2F} {d}", .{ cols, rows });
    var wide: [32]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&wide, text);
    @memcpy(state.text[0..n], wide[0..n]);
    state.text_len = n;
    state.dpi = window.dpi;

    state.pal = theme.palette(window);

    const dpi = window.dpi;
    const w = geom.scale(2 * pad_x + char_w * @as(i32, @intCast(n)), dpi);
    const h = geom.scale(height_px, dpi);

    var origin: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    _ = user32.ClientToScreen(surface.hwnd, &origin);
    var client: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(surface.hwnd, &client);
    const rect = placement(
        config.@"resize-overlay-position",
        .{ .x = origin.x, .y = origin.y, .w = client.right - client.left, .h = client.bottom - client.top },
        .{ .w = w, .h = h },
        geom.scale(margin_px, dpi),
    );

    const hwnd = try ensureWindow(window, state);
    _ = user32.SetWindowPos(
        hwnd,
        user32.HWND_TOPMOST,
        rect.x,
        rect.y,
        rect.w,
        rect.h,
        user32.SWP_NOACTIVATE | user32.SWP_SHOWWINDOW,
    );
    _ = user32.InvalidateRect(hwnd, null, 0);

    const ms: u64 = @max(1, config.@"resize-overlay-duration".duration / std.time.ns_per_ms);
    _ = user32.SetTimer(hwnd, messages.timers.resize_overlay.hide, @intCast(@min(ms, std.math.maxInt(u32))), null);
}

fn ensureWindow(window: anytype, state: *State) !win32.foundation.HWND {
    if (state.hwnd) |h| return h;

    try util.registerClass(&.{
        .style = user32.CS_HREDRAW | user32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hInstance = window.app.hinstance,
        .hCursor = user32.LoadCursorW(null, user32.IDC_ARROW),
        .lpszClassName = class_name,
    });

    const hwnd = user32.CreateWindowExW(
        user32.WS_EX_NOACTIVATE | user32.WS_EX_TOOLWINDOW,
        class_name,
        L(""),
        user32.WS_POPUP,
        0,
        0,
        1,
        1,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.warn("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    util.setUserData(hwnd, state);

    // Rounded corners of the popup, where the system draws them.
    const pref: i32 = win32.dwmapi.DWMWCP_ROUNDSMALL;
    _ = win32.dwmapi.DwmSetWindowAttribute(
        hwnd,
        win32.dwmapi.DWMWA_WINDOW_CORNER_PREFERENCE,
        &pref,
        @sizeOf(i32),
    );

    state.hwnd = hwnd;
    return hwnd;
}

pub fn deinit(state: *State) void {
    if (state.hwnd) |h| {
        // Owned popups die with their owner; this is for an explicit teardown.
        util.setUserData(h, null);
        _ = user32.DestroyWindow(h);
    }
    state.hwnd = null;
}

fn paint(hwnd: win32.foundation.HWND, state: *const State) void {
    var ps: user32.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = user32.EndPaint(hwnd, &ps);
    paintInto(hwnd, hdc, state) catch |err| log.warn("unable to paint the resize overlay err={}", .{err});
}

fn paintInto(hwnd: win32.foundation.HWND, hdc: user32.HDC, state: *const State) !void {
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    const pal = state.pal orelse return;
    try Chrome.paintLabel(hdc, geom.Rect.fromRECT(rc), state.text[0..state.text_len], pal, state.dpi);
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    switch (msg) {
        user32.WM_MOUSEACTIVATE => return ma_noactivate,
        user32.WM_NCHITTEST => return user32.HTTRANSPARENT,
        user32.WM_ERASEBKGND => return 1,
        user32.WM_PAINT => {
            if (util.fromUserData(State, hwnd)) |state| {
                paint(hwnd, state);
                return 0;
            }
        },
        user32.WM_TIMER => if (wparam == messages.timers.resize_overlay.hide) {
            _ = user32.KillTimer(hwnd, messages.timers.resize_overlay.hide);
            _ = user32.ShowWindow(hwnd, user32.SW_HIDE);
            return 0;
        },
        user32.WM_NCDESTROY => {
            if (util.fromUserData(State, hwnd)) |state| state.hwnd = null;
            util.setUserData(hwnd, null);
        },
        else => {},
    }
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "win32 overlay: placement for each position" {
    const surface: geom.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const size: Size = .{ .w = 100, .h = 40 };
    const P = configpkg.Config.ResizeOverlayPosition;
    const cases = [_]struct { pos: P, x: i32, y: i32 }{
        .{ .pos = .center, .x = 350, .y = 280 },
        .{ .pos = .@"top-left", .x = 8, .y = 8 },
        .{ .pos = .@"top-center", .x = 350, .y = 8 },
        .{ .pos = .@"top-right", .x = 692, .y = 8 },
        .{ .pos = .@"bottom-left", .x = 8, .y = 552 },
        .{ .pos = .@"bottom-center", .x = 350, .y = 552 },
        .{ .pos = .@"bottom-right", .x = 692, .y = 552 },
    };
    for (cases) |c| {
        const r = placement(c.pos, surface, size, 8);
        try std.testing.expectEqual(c.x, r.x);
        try std.testing.expectEqual(c.y, r.y);
        try std.testing.expectEqual(@as(i32, 100), r.w);
        try std.testing.expectEqual(@as(i32, 40), r.h);
    }

    // The surface origin offsets the result; a tiny surface never pushes
    // the popup up or left of it.
    const off = placement(.@"bottom-right", .{ .x = 100, .y = 50, .w = 800, .h = 600 }, size, 8);
    try std.testing.expectEqual(@as(i32, 792), off.x);
    try std.testing.expectEqual(@as(i32, 602), off.y);
    const tiny = placement(.center, .{ .x = 10, .y = 10, .w = 50, .h = 20 }, size, 8);
    try std.testing.expectEqual(@as(i32, 10), tiny.x);
    try std.testing.expectEqual(@as(i32, 10), tiny.y);
}
