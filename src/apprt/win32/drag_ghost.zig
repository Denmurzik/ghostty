//! Translucent ghost window shown while a tab or a split is dragged. One per
//! process, main thread only. A layered, click-through popup whose content is
//! a tab chip painted into a premultiplied 32bpp DIB, or (a split drag) a
//! 20 % snapshot of the pane.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Chrome = @import("Chrome.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");
const tab_drag = @import("tab_drag.zig");
const util = @import("util.zig");
const secure_input = @import("secure_input.zig");

const gdi32 = win32.gdi32;
const user32 = win32.user32;

const log = std.log.scoped(.win32_drag_ghost);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const class_name = L("GhosttyDragGhost");

/// Constant alpha over the per-pixel alpha of the chip.
const ghost_alpha = 0xD8;

/// What the ghost shows.
pub const Mode = enum { image, chip };

/// The snapshot of a pane is this share of it (macOS `previewScale`) ...
pub const scale_percent = 20;
/// ... and smaller than this it is not worth a picture: the chip shows.
pub const floor: geom.Size = .{ .w = 48, .h = 32 };

/// Size of the snapshot of a pane of `pane` px; null when it would be below
/// the floor (the chip shows instead).
pub fn snapshotSize(pane: geom.Size) ?geom.Size {
    if (pane.w <= 0 or pane.h <= 0) return null;
    const w: i32 = @intCast(@divFloor(@as(i64, pane.w) * scale_percent + 50, 100));
    const h: i32 = @intCast(@divFloor(@as(i64, pane.h) * scale_percent + 50, 100));
    if (w < floor.w or h < floor.h) return null;
    return .{ .w = w, .h = h };
}

/// The ghost of a split: the snapshot, unless secure input excludes our
/// windows from capture (the screen would give a black picture) or the pane
/// is too small.
pub fn pickMode(secure: bool, pane: geom.Size) Mode {
    if (secure) return .chip;
    return if (snapshotSize(pane) == null) .chip else .image;
}

const State = struct {
    hwnd: win32.foundation.HWND,
    /// Chip or image size in pixels (the chip at `dpi`).
    size: geom.Rect,
    dpi: u32,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    pos: tab_drag.Point,
    palette: theme.Palette,
    mode: Mode = .chip,
};

var state: ?State = null;

/// What the ghost shows now; null when there is none.
pub fn currentMode() ?Mode {
    const s = state orelse return null;
    return s.mode;
}

fn createWindow(app: *App, size: geom.Rect, at: tab_drag.Point) ?win32.foundation.HWND {
    util.registerClass(&.{
        .style = 0,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .lpszClassName = class_name,
    }) catch return null;

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
        return null;
    };
    secure_input.apply(hwnd);
    return hwnd;
}

/// `source` is the window the tab comes from: its DPI and palette style the chip.
pub fn show(app: *App, source: *const Window, title: []const u8, size: geom.Rect, at: tab_drag.Point) void {
    if (state != null) hide();
    const dpi = source.dpi;
    const hwnd = createWindow(app, size, at) orelse return;

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

extern "gdi32" fn StretchBlt(
    dst: user32.HDC,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    src: user32.HDC,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    rop: u32,
) callconv(.winapi) win32.foundation.BOOL;
extern "gdi32" fn SetStretchBltMode(dc: user32.HDC, mode: i32) callconv(.winapi) i32;
const halftone = 4;
const srccopy: u32 = 0x00CC0020;

/// Premultiplied BGRA pixels of the screen rectangle `src` (screen px),
/// shrunk to `size` with HALFTONE and made opaque. Null when the screen could
/// not be read, or the centre row is all black (a protected or overlay
/// surface does not come through the screen DC): the chip shows then. The
/// caller frees the result with `alloc`.
pub fn capture(alloc: std.mem.Allocator, src: geom.Rect, size: geom.Size) ?[]u8 {
    if (size.w <= 0 or size.h <= 0 or src.w <= 0 or src.h <= 0) return null;
    const screen = user32.GetDC(null) orelse return null;
    defer _ = user32.ReleaseDC(null, screen);
    const dc = gdi32.CreateCompatibleDC(screen) orelse return null;
    defer _ = gdi32.DeleteDC(dc);

    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = size.w,
        .biHeight = -size.h,
        .biBitCount = 32,
    } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };

    _ = SetStretchBltMode(dc, halftone);
    if (StretchBlt(dc, 0, 0, size.w, size.h, screen, src.x, src.y, src.w, src.h, srccopy) == 0) return null;
    _ = gdi32.GdiFlush();

    const n: usize = @as(usize, @intCast(size.w)) * @as(usize, @intCast(size.h)) * 4;
    const out = alloc.alloc(u8, n) catch return null;
    const mem: [*]const u8 = @ptrCast(bits orelse {
        alloc.free(out);
        return null;
    });
    @memcpy(out, mem[0..n]);
    makeOpaque(out);
    if (centreRowBlack(out, size)) {
        alloc.free(out);
        return null;
    }
    return out;
}

/// GDI leaves the alpha byte alone: the snapshot is opaque.
fn makeOpaque(bgra: []u8) void {
    var i: usize = 3;
    while (i < bgra.len) : (i += 4) bgra[i] = 255;
}

/// Whether every pixel of the middle row is black (colour channels only).
pub fn centreRowBlack(bgra: []const u8, size: geom.Size) bool {
    if (size.w <= 0 or size.h <= 0) return true;
    const w: usize = @intCast(size.w);
    const row: usize = @intCast(@divFloor(size.h, 2));
    const start = row * w * 4;
    if (start + w * 4 > bgra.len) return true;
    var x: usize = 0;
    while (x < w) : (x += 1) {
        const p = bgra[start + x * 4 ..][0..3];
        if (p[0] != 0 or p[1] != 0 or p[2] != 0) return false;
    }
    return true;
}

/// Shows the snapshot `bgra` (`size` px, premultiplied) at `at`. False when
/// the window or its bitmap could not be made; nothing is shown then.
pub fn showImage(app: *App, bgra: []const u8, size: geom.Size, at: tab_drag.Point) bool {
    if (state != null) hide();
    const n: usize = @as(usize, @intCast(@max(size.w, 0))) * @as(usize, @intCast(@max(size.h, 0))) * 4;
    if (n == 0 or bgra.len < n) return false;
    const rect: geom.Rect = .{ .w = size.w, .h = size.h };
    const hwnd = createWindow(app, rect, at) orelse return false;
    state = .{ .hwnd = hwnd, .size = rect, .dpi = 96, .pos = at, .palette = undefined, .mode = .image };
    if (!presentImage(&state.?, bgra[0..n])) {
        hide();
        return false;
    }
    _ = user32.ShowWindow(hwnd, user32.SW_SHOWNOACTIVATE);
    return true;
}

fn presentImage(s: *State, bgra: []const u8) bool {
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
    const dst: [*]u8 = @ptrCast(bits orelse return false);
    @memcpy(dst[0..bgra.len], bgra);

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
        if (state) |*s| if (s.hwnd == hwnd and s.mode == .chip) {
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

test "win32 drag ghost: snapshot size is 20 % with the 48x32 floor" {
    const t = std.testing;
    try t.expectEqual(geom.Size{ .w = 200, .h = 120 }, snapshotSize(.{ .w = 1000, .h = 600 }).?);
    try t.expectEqual(geom.Size{ .w = 384, .h = 216 }, snapshotSize(.{ .w = 1920, .h = 1080 }).?);
    // Rounded to the nearest pixel.
    try t.expectEqual(geom.Size{ .w = 61, .h = 61 }, snapshotSize(.{ .w = 305, .h = 304 }).?);
    // Exactly on the floor.
    try t.expectEqual(geom.Size{ .w = 48, .h = 32 }, snapshotSize(.{ .w = 240, .h = 160 }).?);
    // One pixel under it on either side.
    try t.expect(snapshotSize(.{ .w = 235, .h = 160 }) == null);
    try t.expect(snapshotSize(.{ .w = 240, .h = 155 }) == null);
    try t.expect(snapshotSize(.{ .w = 0, .h = 600 }) == null);
    try t.expect(snapshotSize(.{ .w = 1000, .h = -1 }) == null);
}

test "win32 drag ghost: secure input forces the chip" {
    const big: geom.Size = .{ .w = 1000, .h = 600 };
    try std.testing.expectEqual(Mode.chip, pickMode(true, big));
    try std.testing.expectEqual(Mode.image, pickMode(false, big));
    // A pane too small for a picture shows the chip as well.
    try std.testing.expectEqual(Mode.chip, pickMode(false, .{ .w = 200, .h = 100 }));
}

test "win32 drag ghost: a black centre row means no usable snapshot" {
    var px: [4 * 3 * 3]u8 = @splat(0);
    makeOpaque(&px);
    try std.testing.expect(centreRowBlack(&px, .{ .w = 3, .h = 3 }));
    // A lit pixel in the middle row (blue channel).
    px[(1 * 3 + 2) * 4] = 7;
    try std.testing.expect(!centreRowBlack(&px, .{ .w = 3, .h = 3 }));
    // Another row does not count.
    px[(1 * 3 + 2) * 4] = 0;
    px[0] = 9;
    try std.testing.expect(centreRowBlack(&px, .{ .w = 3, .h = 3 }));
    // A short buffer is unusable.
    try std.testing.expect(centreRowBlack(px[0..8], .{ .w = 3, .h = 3 }));
}
