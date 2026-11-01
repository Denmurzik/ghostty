//! Initial placement, maximize, fullscreen, always-on-top, decorations
//! toggle and the window size actions.
//!
//! All size math goes through `frame.nonClientSize`: a window size is the
//! content size (the area below the tab strip) plus the non-client size.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const Window = @import("Window.zig");
const frame = @import("frame.zig");
const geom = @import("geom.zig");
const Surface = @import("Surface.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_placement);

pub const State = struct {
    fullscreen: bool = false,
    topmost: bool = false,
    /// What `toggle_window_decorations` goes back to from `none`.
    decorations_before_none: frame.Decorations = .client,
    /// The placement and style to return to when leaving fullscreen.
    saved_valid: bool = false,
    saved_placement: user32.WINDOWPLACEMENT = .{},
    saved_style: usize = 0,
    /// The content size last reported by core (`initial_size`), physical
    /// pixels.
    initial_size: ?struct { width: u32, height: u32 } = null,
};

/// `IsZoomed ? SW_RESTORE : SW_MAXIMIZE`. Not while fullscreen.
pub fn toggleMaximize(window: *Window) bool {
    if (window.placement.fullscreen) return false;
    const cmd: i32 = if (user32.IsZoomed(window.hwnd) != 0) user32.SW_RESTORE else user32.SW_MAXIMIZE;
    _ = user32.ShowWindow(window.hwnd, cmd);
    return true;
}

/// Cover the monitor with a borderless popup, or restore the exact
/// placement and style from before.
pub fn toggleFullscreen(window: *Window) bool {
    const p = &window.placement;
    const hwnd = window.hwnd;

    if (!p.fullscreen) {
        p.saved_placement = .{};
        if (user32.GetWindowPlacement(hwnd, &p.saved_placement) == 0) {
            log.warn("GetWindowPlacement failed err={}", .{win32.kernel32.GetLastError()});
            return false;
        }
        const style: usize = @bitCast(user32.GetWindowLongPtrW(hwnd, user32.GWL_STYLE));
        const mon = monitorRect(hwnd) orelse return false;

        p.saved_style = style;
        p.saved_valid = true;
        p.fullscreen = true;

        // A hidden window (start-up) must stay hidden until `show`.
        const visible: usize = if (user32.IsWindowVisible(hwnd) != 0) user32.WS_VISIBLE else 0;
        const popup = (style & ~@as(usize, user32.WS_OVERLAPPEDWINDOW | user32.WS_MAXIMIZE)) | user32.WS_POPUP | visible;
        _ = user32.SetWindowLongPtrW(hwnd, user32.GWL_STYLE, @bitCast(popup));

        coverRect(hwnd, mon);
    } else {
        p.fullscreen = false;
        if (p.saved_valid) {
            // The system menu bit follows the decorations in force now (they
            // may have changed while fullscreen), the rest is as before.
            const sysmenu: usize = user32.WS_SYSMENU;
            const current: usize = @bitCast(user32.GetWindowLongPtrW(hwnd, user32.GWL_STYLE));
            const restored = (p.saved_style & ~sysmenu) | (current & sysmenu);
            _ = user32.SetWindowLongPtrW(hwnd, user32.GWL_STYLE, @bitCast(restored));
            _ = user32.SetWindowPlacement(hwnd, &p.saved_placement);
            p.saved_valid = false;
        }
        frame.applyDecorations(window, window.frame.decorations);
        _ = user32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            0,
            0,
            user32.SWP_FRAMECHANGED | user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE,
        );
    }

    // The strip is hidden while fullscreen.
    window.layout();
    return true;
}

/// `client`/`server` <-> `none`, through `frame.applyDecorations`.
pub fn toggleDecorations(window: *Window) bool {
    const p = &window.placement;
    // Fullscreen owns the style bits until it ends.
    if (p.fullscreen) return false;
    if (window.frame.decorations == .none) {
        frame.applyDecorations(window, p.decorations_before_none);
    } else {
        p.decorations_before_none = window.frame.decorations;
        frame.applyDecorations(window, .none);
    }
    return true;
}

pub fn setFloat(window: *Window, mode: apprt.action.FloatWindow) bool {
    const on = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !window.placement.topmost,
    };
    window.placement.topmost = on;
    _ = user32.SetWindowPos(
        window.hwnd,
        if (on) user32.HWND_TOPMOST else user32.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOACTIVATE,
    );
    return true;
}

/// Core sizes the window in points (its pixels divided by the content scale,
/// for `initial_size` and `resize_window`); the window is sized in physical
/// pixels.
pub fn pointsToPixels(window: *const Window, width: u32, height: u32) struct { w: u32, h: u32 } {
    return .{ .w = scalePoints(width, window.dpi), .h = scalePoints(height, window.dpi) };
}

fn scalePoints(v: u32, dpi: u32) u32 {
    const px = (@as(u64, v) * dpi) / 96;
    return @intCast(@min(px, std.math.maxInt(u32)));
}

/// Re-apply the content size core reported at start-up.
pub fn resetSize(window: *Window) bool {
    const size = window.placement.initial_size orelse return false;
    return setContentSize(window, .{ .w = Window.clampPixels(size.width), .h = Window.clampPixels(size.height) });
}

/// Resize so the content area is `width` x `height` physical pixels; 0
/// keeps that dimension. Ignored while maximized or fullscreen.
pub fn resizeClient(window: *Window, width: u32, height: u32) bool {
    const current = window.contentRect();
    const target = targetClient(
        .{ .w = current.w, .h = current.h },
        .{ .w = Window.clampPixels(width), .h = Window.clampPixels(height) },
    );
    return setContentSize(window, target);
}

/// What decides whether a `resize_window` request (`CSI 8 t`) may move the
/// window edges, like macOS (`TerminalController.resizeWindow`) and GTK
/// (`Window.resizeSurface`).
pub const ResizeContext = struct {
    quick: bool,
    tabs: usize,
    leaves: usize,
    inspector: bool,
    maximized: bool,
    fullscreen: bool,
    minimized: bool,
    /// Snapped / tiled by the shell (`IsWindowArranged`).
    arranged: bool,
};

/// Only a lone surface in a single-tab, plain window may be resized by the
/// program running in it.
pub fn resizeAllowed(c: ResizeContext) bool {
    if (c.quick or c.inspector) return false;
    if (c.maximized or c.fullscreen or c.minimized or c.arranged) return false;
    return c.tabs == 1 and c.leaves == 1;
}

/// The new window rectangle: the window size plus (requested - current)
/// surface pixels per non-zero requested dimension, clamped to `work`, the
/// top-left kept, then moved inside `work` if it sticks out.
pub fn resizeByDelta(window: geom.Rect, surface: frame.Size, requested: frame.Size, work: geom.Rect) geom.Rect {
    var w: i32 = window.w;
    var h: i32 = window.h;
    if (requested.w != 0) w = window.w + (requested.w - surface.w);
    if (requested.h != 0) h = window.h + (requested.h - surface.h);
    w = std.math.clamp(w, 1, @max(work.w, 1));
    h = std.math.clamp(h, 1, @max(work.h, 1));
    return .{
        .x = std.math.clamp(window.x, work.x, @max(work.right() - w, work.x)),
        .y = std.math.clamp(window.y, work.y, @max(work.bottom() - h, work.y)),
        .w = w,
        .h = h,
    };
}

/// `resize_window` for the surface `s`: `width` x `height` physical pixels
/// of that surface (0 keeps a dimension). False when the window is not a
/// plain single-surface one.
pub fn resizeSurface(window: *Window, s: *const Surface, width: u32, height: u32) bool {
    const hwnd = window.hwnd;
    const ctx: ResizeContext = .{
        .quick = window.kind == .quick,
        .tabs = window.tabs.items.len,
        .leaves = if (s.tab.tree.isSplit()) 2 else 1,
        .inspector = s.inspector != null,
        .maximized = user32.IsZoomed(hwnd) != 0,
        .fullscreen = window.placement.fullscreen,
        .minimized = user32.IsIconic(hwnd) != 0,
        .arranged = user32.IsWindowArranged(hwnd),
    };
    if (!resizeAllowed(ctx)) return false;

    var wrc: win32.foundation.RECT = undefined;
    if (user32.GetWindowRect(hwnd, &wrc) == 0) return false;
    var crc: win32.foundation.RECT = undefined;
    if (user32.GetClientRect(s.hwnd, &crc) == 0) return false;
    const work = workRect(hwnd) orelse return false;

    const rect = resizeByDelta(
        geom.Rect.fromRECT(wrc),
        .{ .w = crc.right - crc.left, .h = crc.bottom - crc.top },
        .{ .w = Window.clampPixels(width), .h = Window.clampPixels(height) },
        work,
    );
    return user32.SetWindowPos(
        hwnd,
        null,
        rect.x,
        rect.y,
        rect.w,
        rect.h,
        user32.SWP_NOZORDER | user32.SWP_NOACTIVATE,
    ) != 0;
}

/// Config `maximize` and `fullscreen` take effect when the window is
/// first shown.
pub fn applyStartup(window: *Window) void {
    const config = &window.app.config;
    if (config.maximize) _ = toggleMaximize(window);
    if (config.fullscreen != .false) _ = toggleFullscreen(window);
}

/// Cover the monitor the window is on (again), e.g. after a DPI change.
pub fn coverMonitor(window: *Window) void {
    const mon = monitorRect(window.hwnd) orelse return;
    coverRect(window.hwnd, mon);
}

fn coverRect(hwnd: win32.foundation.HWND, monitor: geom.Rect) void {
    const r = fullscreenRect(monitor);
    _ = user32.SetWindowPos(
        hwnd,
        null,
        r.x,
        r.y,
        r.w,
        r.h,
        user32.SWP_FRAMECHANGED | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE | user32.SWP_NOOWNERZORDER,
    );
}

/// What a fullscreen window covers on a monitor: all of it.
pub fn fullscreenRect(monitor: geom.Rect) geom.Rect {
    return monitor;
}

/// The content size after a resize request: a zero dimension keeps the
/// current one.
pub fn targetClient(current: frame.Size, requested: frame.Size) frame.Size {
    return .{
        .w = if (requested.w == 0) current.w else requested.w,
        .h = if (requested.h == 0) current.h else requested.h,
    };
}

fn setContentSize(window: *Window, content: frame.Size) bool {
    if (window.placement.fullscreen) return false;
    if (user32.IsZoomed(window.hwnd) != 0 or user32.IsIconic(window.hwnd) != 0) return false;
    const size = Window.windowSizeFor(content, frame.nonClientSize(window));
    return user32.SetWindowPos(
        window.hwnd,
        null,
        0,
        0,
        size.w,
        size.h,
        user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE,
    ) != 0;
}

fn monitorRect(hwnd: win32.foundation.HWND) ?geom.Rect {
    const monitor = user32.MonitorFromWindow(hwnd, user32.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info: user32.MONITORINFO = .{};
    if (user32.GetMonitorInfoW(monitor, &info) == 0) return null;
    return geom.Rect.fromRECT(info.rcMonitor);
}

fn workRect(hwnd: win32.foundation.HWND) ?geom.Rect {
    const monitor = user32.MonitorFromWindow(hwnd, user32.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info: user32.MONITORINFO = .{};
    if (user32.GetMonitorInfoW(monitor, &info) == 0) return null;
    return geom.Rect.fromRECT(info.rcWork);
}

const plain: ResizeContext = .{
    .quick = false,
    .tabs = 1,
    .leaves = 1,
    .inspector = false,
    .maximized = false,
    .fullscreen = false,
    .minimized = false,
    .arranged = false,
};

test "win32 placement: CSI 8 t only for a lone surface in a plain window" {
    try std.testing.expect(resizeAllowed(plain));
    var c = plain;
    c.quick = true;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.tabs = 2;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.tabs = 0;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.leaves = 2;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.inspector = true;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.maximized = true;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.fullscreen = true;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.minimized = true;
    try std.testing.expect(!resizeAllowed(c));
    c = plain;
    c.arranged = true;
    try std.testing.expect(!resizeAllowed(c));
}

test "win32 placement: CSI 8 t resizes by the surface delta" {
    const work: geom.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };
    const win: geom.Rect = .{ .x = 100, .y = 50, .w = 900, .h = 600 };
    const surface: frame.Size = .{ .w = 870, .h = 520 };
    // Window grows by the surface delta (the chrome stays the same).
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 50, .w = 1030, .h = 580 },
        resizeByDelta(win, surface, .{ .w = 1000, .h = 500 }, work),
    );
    // A zero dimension keeps the window's.
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 50, .w = 900, .h = 580 },
        resizeByDelta(win, surface, .{ .w = 0, .h = 500 }, work),
    );
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 50, .w = 1030, .h = 600 },
        resizeByDelta(win, surface, .{ .w = 1000, .h = 0 }, work),
    );
    try std.testing.expectEqual(win, resizeByDelta(win, surface, .{ .w = 0, .h = 0 }, work));
}

test "win32 placement: CSI 8 t clamps to the work area and keeps the top-left" {
    const work: geom.Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1040 };
    const win: geom.Rect = .{ .x = -1500, .y = 100, .w = 900, .h = 600 };
    const surface: frame.Size = .{ .w = 870, .h = 520 };
    // Too big: clamped to the work area, then moved inside.
    try std.testing.expectEqual(
        work,
        resizeByDelta(win, surface, .{ .w = 5000, .h = 5000 }, work),
    );
    // Fits when it grows to the right: the top-left stays.
    try std.testing.expectEqual(
        geom.Rect{ .x = -1500, .y = 100, .w = 1200, .h = 600 },
        resizeByDelta(win, surface, .{ .w = 1170, .h = 520 }, work),
    );
    // Sticks out at the right / bottom: moved back in, size kept.
    try std.testing.expectEqual(
        geom.Rect{ .x = -1600, .y = 100, .w = 1600, .h = 600 },
        resizeByDelta(win, surface, .{ .w = 1570, .h = 520 }, work),
    );
    try std.testing.expectEqual(
        geom.Rect{ .x = -1500, .y = 40, .w = 900, .h = 1000 },
        resizeByDelta(win, surface, .{ .w = 870, .h = 920 }, work),
    );
    // Shrinks: the top-left stays.
    try std.testing.expectEqual(
        geom.Rect{ .x = -1500, .y = 100, .w = 500, .h = 300 },
        resizeByDelta(win, surface, .{ .w = 470, .h = 220 }, work),
    );
}

test "win32 placement: core points scale to physical pixels" {
    try std.testing.expectEqual(@as(u32, 1623), scalePoints(1623, 96));
    // 1.75: the 167 columns of 17 px that core divided by the scale.
    try std.testing.expectEqual(@as(u32, 2840), scalePoints(1623, 168));
    // A zero dimension still means "keep".
    try std.testing.expectEqual(@as(u32, 0), scalePoints(0, 168));
    try std.testing.expectEqual(@as(u32, 1361), scalePoints(778, 168));
}

test "win32 placement: resize keeps a zero dimension" {
    const cur: frame.Size = .{ .w = 900, .h = 500 };
    try std.testing.expectEqual(frame.Size{ .w = 800, .h = 600 }, targetClient(cur, .{ .w = 800, .h = 600 }));
    try std.testing.expectEqual(frame.Size{ .w = 900, .h = 600 }, targetClient(cur, .{ .w = 0, .h = 600 }));
    try std.testing.expectEqual(frame.Size{ .w = 800, .h = 500 }, targetClient(cur, .{ .w = 800, .h = 0 }));
    try std.testing.expectEqual(cur, targetClient(cur, .{ .w = 0, .h = 0 }));
}

test "win32 placement: fullscreen covers the monitor" {
    const mon: geom.Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1080 };
    try std.testing.expectEqual(mon, fullscreenRect(mon));
}

test "win32 placement: window size from content size per decorations" {
    const strip_h: i32 = 40;
    const content: frame.Size = .{ .w = 800, .h = 600 };
    for ([_]u32{ 96, 144 }) |dpi| {
        for ([_]frame.Decorations{ .client, .none }) |decorations| {
            const i = frame.frameInsets(dpi, false, decorations);
            const nc: frame.Size = .{ .w = i.left + i.right, .h = i.top + i.bottom + strip_h };
            const win = Window.windowSizeFor(content, nc);
            // The window is bigger by exactly the insets plus the strip
            // and the content comes back out of it.
            try std.testing.expectEqual(content.w + i.left + i.right, win.w);
            try std.testing.expectEqual(content.h + i.top + i.bottom + strip_h, win.h);
            try std.testing.expectEqual(content, Window.contentSizeFor(win, nc));
        }
    }
    // `none` has no sizing frame: only the strip is non-client.
    const none = frame.frameInsets(96, false, .none);
    try std.testing.expectEqual(frame.Size{ .w = 800, .h = 640 }, Window.windowSizeFor(content, .{ .w = none.left + none.right, .h = none.top + none.bottom + strip_h }));
}
