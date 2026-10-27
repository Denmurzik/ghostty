//! Overlay host: popups (labels, toasts, the search bar, the palette) that
//! float over a surface or a window. A popup is an owned `WS_POPUP`, never
//! topmost, so it stacks with its owner and follows it: the host moves it
//! with the owner, hides it with a minimized window or a hidden tab and
//! re-owns it when its tab moves to another window. A popup's memory belongs
//! to the feature that made it; the host only holds a reference.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const CoreApp = @import("../../App.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const geom = @import("geom.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");

const gdi32 = win32.gdi32;
const user32 = win32.user32;
const uxtheme = win32.uxtheme;
const HWND = win32.foundation.HWND;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_overlay);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const label_class = L("GhosttyOverlayLabel");
const panel_class = L("GhosttyOverlayPanel");

/// `WM_MOUSEACTIVATE` result: do not activate, and eat the click.
const ma_noactivate = 3;
const gw_owner = 4;
extern "user32" fn GetWindow(HWND, u32) callconv(.winapi) ?HWND;

pub const Size = struct { w: i32, h: i32 };
pub const Point = struct { x: i32, y: i32 };

pub const Anchor = enum {
    surface_top_right,
    surface_top_full,
    surface_bottom_left,
    surface_bottom_right,
    surface_bottom_center,
    window_top_center,
    window_bottom_center,
};

pub const Kind = enum {
    /// `WS_EX_LAYERED | TRANSPARENT | NOACTIVATE | TOOLWINDOW`, drawn with
    /// `UpdateLayeredWindow`, never takes the focus.
    label,
    /// Opaque `WS_POPUP | WS_EX_TOOLWINDOW` with rounded corners, buffered
    /// paint; may host EDIT children.
    panel,
};

pub const PaintContext = struct {
    /// A memory DC (label: a premultiplied 32bpp DIB cleared to transparent)
    /// or the buffered DC of the panel; the origin is the popup's.
    hdc: user32.HDC,
    rect: geom.Rect,
    dpi: u32,
    palette: theme.Palette,
};

pub const Popup = struct {
    kind: Kind,
    anchor: Anchor,
    window: *Window,
    surface: ?*Surface = null,
    /// Logical px at 96 dpi; scaled by `window.dpi`.
    size: Size,
    margin: i32 = 8,
    paint: *const fn (p: *Popup, ctx: PaintContext) void,
    on_message: ?*const fn (p: *Popup, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT = null,
    /// Replaces `rectFor` when set: `(popup, surface rect, size in px)` to
    /// the screen rectangle.
    place: ?*const fn (p: *Popup, surface: geom.Rect, size_px: Size) geom.Rect = null,
    /// For the feature's own use.
    ctx: ?*anyopaque = null,
    /// Window class; the host registers it on first use.
    class: ?[*:0]const u16 = null,
    hwnd: ?HWND = null,
    /// Whether the feature wants the popup shown.
    visible: bool = false,
    /// A bottom-left label flips to bottom-right under the cursor.
    avoid_cursor: bool = false,
    /// Hidden by the host: the tab of `surface` is not the shown one.
    tab_hidden: bool = false,
    /// Pixel size the label was last drawn at.
    drawn: Size = .{ .w = 0, .h = 0 },

    pub fn show(p: *Popup) !void {
        try ensureWindow(p);
        p.visible = true;
        apply(p);
        p.invalidate();
    }

    pub fn hide(p: *Popup) void {
        p.visible = false;
        const hwnd = p.hwnd orelse return;
        _ = user32.KillTimer(hwnd, messages.timers.overlay.hide);
        _ = user32.ShowWindow(hwnd, user32.SW_HIDE);
    }

    pub fn invalidate(p: *Popup) void {
        const hwnd = p.hwnd orelse return;
        if (!p.visible) return;
        switch (p.kind) {
            .label => renderLabel(p) catch |err| log.warn("unable to draw an overlay label err={}", .{err}),
            .panel => _ = user32.InvalidateRect(hwnd, null, 0),
        }
    }

    pub fn setSize(p: *Popup, size: Size) void {
        p.size = size;
        if (p.hwnd == null) return;
        reposition(p);
        p.invalidate();
    }

    /// Takes the popup down; the memory stays with the feature.
    pub fn destroy(p: *Popup) void {
        p.visible = false;
        removeFromWindow(p);
        const hwnd = p.hwnd orelse return;
        util.setUserData(hwnd, null);
        p.hwnd = null;
        _ = user32.DestroyWindow(hwnd);
    }

    /// Hides the popup `ms` after now (a new call restarts the time).
    pub fn hideAfter(p: *Popup, ms: u32) void {
        const hwnd = p.hwnd orelse return;
        _ = user32.SetTimer(hwnd, messages.timers.overlay.hide, ms, null);
    }
};

/// Per top-level window: the popups it hosts.
pub const WindowState = struct {
    popups: std.ArrayList(*Popup) = .empty,
    /// Set by `beginPanelActivation`: the next deactivation of the window
    /// is caused by its own panel.
    panel_activation: bool = false,
};

/// A command for the overlay of a window, posted with
/// `messages.WM_GHOSTTY_OVERLAY_CMD`.
pub const Command = struct {};

// -- Placement -------------------------------------------------------------------

/// The screen rectangle of a popup of `size_px` for `anchor`, inside the
/// surface or window area it is attached to and never larger than it.
/// `cursor` flips a bottom-left popup to the bottom-right when it would
/// sit under it.
pub fn rectFor(
    anchor: Anchor,
    surface_screen: geom.Rect,
    window_client_screen: geom.Rect,
    size_px: Size,
    margin_px: i32,
    cursor: ?Point,
) geom.Rect {
    const area = switch (anchor) {
        .window_top_center, .window_bottom_center => window_client_screen,
        else => surface_screen,
    };
    const w = @min(size_px.w, area.w);
    const h = @min(size_px.h, area.h);
    const left = area.x + margin_px;
    const right = area.right() - w - margin_px;
    const center = area.x + @divTrunc(area.w - w, 2);
    const top = area.y + margin_px;
    const bottom = area.bottom() - h - margin_px;

    var x: i32 = undefined;
    var y: i32 = undefined;
    var width = w;
    switch (anchor) {
        .surface_top_right => {
            x = right;
            y = top;
        },
        .surface_top_full => {
            x = area.x;
            y = area.y;
            width = area.w;
        },
        .surface_bottom_left => {
            x = left;
            y = bottom;
            if (cursor) |c| {
                const under: geom.Rect = .{ .x = x, .y = y, .w = w, .h = h };
                if (under.contains(c.x, c.y)) x = right;
            }
        },
        .surface_bottom_right => {
            x = right;
            y = bottom;
        },
        .surface_bottom_center, .window_bottom_center => {
            x = center;
            y = bottom;
        },
        .window_top_center => {
            x = center;
            y = top;
        },
    }
    return .{
        .x = std.math.clamp(x, area.x, @max(area.right() - width, area.x)),
        .y = std.math.clamp(y, area.y, @max(area.bottom() - h, area.y)),
        .w = width,
        .h = h,
    };
}

fn clientScreen(hwnd: HWND) geom.Rect {
    var origin: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    _ = user32.ClientToScreen(hwnd, &origin);
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    return .{ .x = origin.x, .y = origin.y, .w = rc.right - rc.left, .h = rc.bottom - rc.top };
}

fn computeRect(p: *Popup) geom.Rect {
    const dpi = p.window.dpi;
    const size_px: Size = .{ .w = geom.scale(p.size.w, dpi), .h = geom.scale(p.size.h, dpi) };
    const win = clientScreen(p.window.hwnd);
    const surf = if (p.surface) |s| clientScreen(s.hwnd) else win;
    if (p.place) |f| return f(p, surf, size_px);

    var cursor: ?Point = null;
    if (p.avoid_cursor) {
        var pt: win32.foundation.POINT = undefined;
        if (user32.GetCursorPos(&pt) != 0) cursor = .{ .x = pt.x, .y = pt.y };
    }
    return rectFor(p.anchor, surf, win, size_px, geom.scale(p.margin, dpi), cursor);
}

fn reposition(p: *Popup) void {
    const hwnd = p.hwnd orelse return;
    const r = computeRect(p);
    _ = user32.SetWindowPos(hwnd, null, r.x, r.y, r.w, r.h, user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    if (p.kind == .label and (p.drawn.w != r.w or p.drawn.h != r.h) and p.visible) {
        renderLabel(p) catch |err| log.warn("unable to draw an overlay label err={}", .{err});
    }
}

/// Shows, moves or hides the popup to match what the feature wants and
/// what the window and tab allow.
fn apply(p: *Popup) void {
    const hwnd = p.hwnd orelse return;
    const hidden = p.tab_hidden or user32.IsIconic(p.window.hwnd) != 0;
    if (!p.visible or hidden) {
        if (user32.IsWindowVisible(hwnd) != 0) _ = user32.ShowWindow(hwnd, user32.SW_HIDE);
        return;
    }
    reposition(p);
    if (user32.IsWindowVisible(hwnd) == 0) _ = user32.ShowWindow(hwnd, user32.SW_SHOWNOACTIVATE);
}

// -- Window ----------------------------------------------------------------------

fn ensureWindow(p: *Popup) !void {
    if (p.hwnd != null) return;
    const window = p.window;

    const class = p.class orelse switch (p.kind) {
        .label => label_class,
        .panel => panel_class,
    };
    try util.registerClass(&.{
        .style = user32.CS_HREDRAW | user32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hInstance = window.app.hinstance,
        .hCursor = user32.LoadCursorW(null, user32.IDC_ARROW),
        .lpszClassName = class,
    });

    const ex_style: u32, const style: u32 = switch (p.kind) {
        .label => .{
            user32.WS_EX_LAYERED | user32.WS_EX_TRANSPARENT | user32.WS_EX_NOACTIVATE | user32.WS_EX_TOOLWINDOW,
            user32.WS_POPUP,
        },
        .panel => .{ user32.WS_EX_TOOLWINDOW, user32.WS_POPUP | user32.WS_CLIPCHILDREN },
    };
    const hwnd = user32.CreateWindowExW(
        ex_style,
        class,
        L(""),
        style,
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
    errdefer _ = user32.DestroyWindow(hwnd);

    try addToWindow(p);
    util.setUserData(hwnd, p);
    p.hwnd = hwnd;

    if (p.kind == .panel) {
        const pref: i32 = win32.dwmapi.DWMWCP_ROUND;
        _ = win32.dwmapi.DwmSetWindowAttribute(
            hwnd,
            win32.dwmapi.DWMWA_WINDOW_CORNER_PREFERENCE,
            &pref,
            @sizeOf(i32),
        );
    }
}

fn addToWindow(p: *Popup) !void {
    const state = &p.window.overlays;
    for (state.popups.items) |q| if (q == p) return;
    try state.popups.append(p.window.app.core_app.alloc, p);
}

fn removeFromWindow(p: *Popup) void {
    const state = &p.window.overlays;
    for (state.popups.items, 0..) |q, i| {
        if (q == p) {
            _ = state.popups.orderedRemove(i);
            return;
        }
    }
}

var test_palette: ?theme.Palette = null;

fn paletteOf(window: *const Window) theme.Palette {
    if (builtin.is_test) if (test_palette) |pal| return pal;
    return theme.palette(window);
}

fn context(p: *Popup, w: i32, h: i32, hdc: user32.HDC) PaintContext {
    return .{
        .hdc = hdc,
        .rect = .{ .x = 0, .y = 0, .w = w, .h = h },
        .dpi = p.window.dpi,
        .palette = paletteOf(p.window),
    };
}

/// Draws the label into a fresh premultiplied DIB and hands it to the
/// layered window.
fn renderLabel(p: *Popup) !void {
    const hwnd = p.hwnd orelse return;
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetWindowRect(hwnd, &rc);
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    if (w <= 0 or h <= 0) return;

    const dc = gdi32.CreateCompatibleDC(null) orelse return error.CreateDcFailed;
    defer _ = gdi32.DeleteDC(dc);
    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = w,
        .biHeight = -h,
        .biBitCount = 32,
    } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse
        return error.CreateBitmapFailed;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };

    p.paint(p, context(p, w, h, dc));

    const size: user32.SIZE = .{ .cx = w, .cy = h };
    const src: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    const blend: user32.BLENDFUNCTION = .{ .AlphaFormat = user32.AC_SRC_ALPHA };
    if (user32.UpdateLayeredWindow(hwnd, null, null, &size, dc, &src, 0, &blend, user32.ULW_ALPHA) == 0) {
        return error.UpdateLayeredWindowFailed;
    }
    p.drawn = .{ .w = w, .h = h };
}

fn paintPanel(p: *Popup, hwnd: HWND) void {
    var ps: user32.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = user32.EndPaint(hwnd, &ps);

    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    const params: uxtheme.BP_PAINTPARAMS = .{ .dwFlags = uxtheme.BPPF_ERASE };
    var mem: ?user32.HDC = null;
    const buffer = uxtheme.BeginBufferedPaint(hdc, &rc, uxtheme.BPBF_TOPDOWNDIB, &params, &mem);
    p.paint(p, context(p, rc.right - rc.left, rc.bottom - rc.top, mem orelse hdc));
    if (buffer) |b| _ = uxtheme.EndBufferedPaint(b, 1);
}

fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const popup = util.fromUserData(Popup, hwnd);
    if (popup) |p| {
        if (p.on_message) |f| if (f(p, msg, wparam, lparam)) |result| return result;
        switch (msg) {
            user32.WM_MOUSEACTIVATE => if (p.kind == .label) return ma_noactivate,
            user32.WM_NCHITTEST => if (p.kind == .label) return user32.HTTRANSPARENT,
            user32.WM_ERASEBKGND => return 1,
            user32.WM_PAINT => {
                switch (p.kind) {
                    .panel => paintPanel(p, hwnd),
                    // Drawn by `renderLabel`; this only validates.
                    .label => _ = user32.ValidateRect(hwnd, null),
                }
                return 0;
            },
            user32.WM_TIMER => if (wparam == messages.timers.overlay.hide) {
                p.hide();
                return 0;
            },
            else => {},
        }
    }
    if (msg == user32.WM_NCDESTROY) {
        if (popup) |p| p.hwnd = null;
        util.setUserData(hwnd, null);
    }
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// -- Hooks -----------------------------------------------------------------------

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

fn hwndOf(lparam: LPARAM) ?HWND {
    if (lparam == 0 or lparam == -1) return null;
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

fn isOwnPanel(window: *const Window, hwnd: ?HWND) bool {
    const h = hwnd orelse return false;
    for (window.overlays.popups.items) |p| {
        if (p.kind == .panel and p.hwnd == h) return true;
    }
    return false;
}

/// Whether one of the window's panels is the foreground window: the window
/// is still drawn as active then.
pub fn panelHasForeground(window: *const Window) bool {
    return isOwnPanel(window, user32.GetForegroundWindow());
}

/// A panel calls this before it moves the focus to its EDIT child, so that
/// the owner does not take the loss of the activation for its own.
pub fn beginPanelActivation(window: *Window) void {
    window.overlays.panel_activation = true;
}

/// `WM_ACTIVATE` / `WM_NCACTIVATE`: the window stays drawn as active while
/// one of its overlays has the focus.
pub fn windowMessage(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    const state = &window.overlays;
    switch (msg) {
        user32.WM_ACTIVATE => {
            if ((wparam & 0xFFFF) != user32.WA_INACTIVE) return null;
            if (!isOwnPanel(window, hwndOf(lparam))) return null;
            state.panel_activation = false;
            return 0;
        },
        user32.WM_NCACTIVATE => {
            if (wparam != 0) return null;
            if (!state.panel_activation and !isOwnPanel(window, hwndOf(lparam)) and !panelHasForeground(window)) return null;
            return 1;
        },
        else => return null,
    }
}

pub fn windowChanged(window: *Window, change: hooks.WindowChange) void {
    const state = &window.overlays;
    switch (change) {
        .moved, .sized, .dpi, .minimized, .restored => {
            for (state.popups.items) |p| {
                apply(p);
                // The size in px depends on the dpi.
                if (change == .dpi) p.invalidate();
            }
        },
        .destroying => {
            // Owned popups die with the window; their memory stays with the
            // features, which see `hwnd == null`.
            for (state.popups.items) |p| {
                p.visible = false;
                const hwnd = p.hwnd orelse continue;
                util.setUserData(hwnd, null);
                p.hwnd = null;
            }
            state.popups.deinit(window.app.core_app.alloc);
            state.popups = .empty;
        },
        .activated, .deactivated => {},
    }
}

pub fn tabShown(tab: *Tab, shown: bool) void {
    for (tab.window.overlays.popups.items) |p| {
        const s = p.surface orelse continue;
        if (s.tab != tab) continue;
        p.tab_hidden = !shown;
        apply(p);
    }
}

pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    var i: usize = 0;
    while (i < from.overlays.popups.items.len) {
        const p = from.overlays.popups.items[i];
        const s = p.surface orelse {
            i += 1;
            continue;
        };
        if (s.tab != tab) {
            i += 1;
            continue;
        }
        // `reown` takes it out of this list.
        reown(p, to) catch |err| {
            log.warn("unable to move an overlay to its new window err={}", .{err});
            p.destroy();
        };
    }
}

/// Moves the popup to `to`: new owner, new list, new place.
fn reown(p: *Popup, to: *Window) !void {
    if (p.window == to) return;
    try to.overlays.popups.append(to.app.core_app.alloc, p);
    removeFromWindow(p);
    p.window = to;
    const hwnd = p.hwnd orelse return;
    _ = user32.SetWindowLongPtrW(hwnd, user32.GWLP_HWNDPARENT, @bitCast(@intFromPtr(to.hwnd)));
    apply(p);
    p.invalidate();
}

pub fn surfaceDestroying(surface: *Surface) void {
    const state = &surface.window.overlays;
    var i: usize = 0;
    while (i < state.popups.items.len) {
        const p = state.popups.items[i];
        if (p.surface == surface) {
            p.destroy();
        } else {
            i += 1;
        }
    }
}

pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    _ = surface;
    _ = focused;
}

pub fn surfaceRectChanged(surface: *Surface) void {
    for (surface.window.overlays.popups.items) |p| {
        if (p.surface != surface) continue;
        apply(p);
    }
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("popups");
    try jw.beginArray();
    for (app.windows.items) |window| {
        for (window.overlays.popups.items) |p| {
            const hwnd = p.hwnd orelse continue;
            var rc: win32.foundation.RECT = undefined;
            _ = user32.GetWindowRect(hwnd, &rc);
            var buf: [32]u8 = undefined;
            var owner_buf: [32]u8 = undefined;
            try jw.beginObject();
            try jw.objectField("hwnd");
            try jw.write(try std.fmt.bufPrint(&buf, "{x}", .{@intFromPtr(hwnd)}));
            try jw.objectField("kind");
            try jw.write(@tagName(p.kind));
            try jw.objectField("owner");
            try jw.write(try std.fmt.bufPrint(&owner_buf, "{x}", .{@intFromPtr(window.hwnd)}));
            try jw.objectField("visible");
            try jw.write(user32.IsWindowVisible(hwnd) != 0);
            try jw.objectField("rect");
            try jw.write([4]i32{ rc.left, rc.top, rc.right, rc.bottom });
            try jw.endObject();
        }
    }
    try jw.endArray();
    try jw.endObject();
}

/// Frees the heap `Command` of a `WM_GHOSTTY_OVERLAY_CMD` nobody claimed.
pub fn freeCommand(lparam: LPARAM) void {
    _ = lparam;
}

// -- Tests -----------------------------------------------------------------------

const surface_rect: geom.Rect = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
const window_rect: geom.Rect = .{ .x = 80, .y = 20, .w = 900, .h = 700 };

test "win32 overlay: rectFor anchors" {
    for ([_]u32{ 96, 144 }) |dpi| {
        const size: Size = .{ .w = geom.scale(100, dpi), .h = geom.scale(40, dpi) };
        const m = geom.scale(8, dpi);
        const cases = [_]struct { a: Anchor, x: i32, y: i32, w: i32 }{
            .{ .a = .surface_top_right, .x = surface_rect.right() - size.w - m, .y = surface_rect.y + m, .w = size.w },
            .{ .a = .surface_top_full, .x = surface_rect.x, .y = surface_rect.y, .w = surface_rect.w },
            .{ .a = .surface_bottom_left, .x = surface_rect.x + m, .y = surface_rect.bottom() - size.h - m, .w = size.w },
            .{ .a = .surface_bottom_right, .x = surface_rect.right() - size.w - m, .y = surface_rect.bottom() - size.h - m, .w = size.w },
            .{ .a = .surface_bottom_center, .x = surface_rect.x + @divTrunc(surface_rect.w - size.w, 2), .y = surface_rect.bottom() - size.h - m, .w = size.w },
            .{ .a = .window_top_center, .x = window_rect.x + @divTrunc(window_rect.w - size.w, 2), .y = window_rect.y + m, .w = size.w },
            .{ .a = .window_bottom_center, .x = window_rect.x + @divTrunc(window_rect.w - size.w, 2), .y = window_rect.bottom() - size.h - m, .w = size.w },
        };
        for (cases) |c| {
            const r = rectFor(c.a, surface_rect, window_rect, size, m, null);
            try std.testing.expectEqual(c.x, r.x);
            try std.testing.expectEqual(c.y, r.y);
            try std.testing.expectEqual(c.w, r.w);
            try std.testing.expectEqual(size.h, r.h);
        }
    }

    // A surface smaller than the popup: the popup shrinks to it and stays inside.
    const tiny: geom.Rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };
    for (std.enums.values(Anchor)) |a| {
        const r = rectFor(a, tiny, tiny, .{ .w = 100, .h = 40 }, 8, null);
        try std.testing.expect(r.x >= tiny.x and r.y >= tiny.y);
        try std.testing.expect(r.right() <= tiny.right() and r.bottom() <= tiny.bottom());
    }
}

test "win32 overlay: bottom-left label avoids the cursor" {
    const size: Size = .{ .w = 100, .h = 40 };
    const plain = rectFor(.surface_bottom_left, surface_rect, window_rect, size, 8, null);
    try std.testing.expectEqual(@as(i32, 108), plain.x);

    // Under the cursor: right side. Elsewhere: stays left.
    const under = rectFor(.surface_bottom_left, surface_rect, window_rect, size, 8, .{ .x = plain.x + 5, .y = plain.y + 5 });
    try std.testing.expectEqual(@as(i32, 892 - 100), under.x);
    try std.testing.expectEqual(plain.y, under.y);
    const away = rectFor(.surface_bottom_left, surface_rect, window_rect, size, 8, .{ .x = 500, .y = 100 });
    try std.testing.expectEqual(plain.x, away.x);
}

fn noPaint(p: *Popup, ctx: PaintContext) void {
    _ = p;
    _ = ctx;
}

const test_pal: theme.Palette = .{
    .dark = true,
    .mica = false,
    .strip_bg = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
    .tab_active_bg = .{ .r = 0x30, .g = 0x60, .b = 0x90 },
    .tab_hover_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x10 },
    .text = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
    .text_inactive = .{ .r = 0x9E, .g = 0x9E, .b = 0x9E },
    .button_hover_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x15 },
    .button_pressed_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x0B },
    .divider = .{ .r = 0x3C, .g = 0x3C, .b = 0x3C },
};

/// A hidden owner window with the fields the host reads; the rest of the
/// `Window` stays undefined.
const TestOwner = struct {
    core: CoreApp,
    app: App,
    window: Window,
    hwnd: HWND,

    fn create(x: i32, y: i32) !*TestOwner {
        const alloc = std.testing.allocator;
        const hinstance = win32.kernel32.GetModuleHandleW(null) orelse return error.SkipZigTest;
        const hwnd = user32.CreateWindowExW(0, L("STATIC"), L(""), user32.WS_POPUP, x, y, 400, 300, null, null, hinstance, null) orelse
            return error.SkipZigTest;
        errdefer _ = user32.DestroyWindow(hwnd);
        const self = try alloc.create(TestOwner);
        self.hwnd = hwnd;
        self.core = undefined;
        self.core.alloc = alloc;
        self.app = undefined;
        self.app.core_app = &self.core;
        self.app.hinstance = hinstance;
        self.window = undefined;
        self.window.app = &self.app;
        self.window.hwnd = hwnd;
        self.window.dpi = 96;
        self.window.overlays = .{};
        test_palette = test_pal;
        return self;
    }

    fn destroy(self: *TestOwner) void {
        const alloc = std.testing.allocator;
        self.window.overlays.popups.deinit(alloc);
        _ = user32.DestroyWindow(self.hwnd);
        alloc.destroy(self);
    }

    fn popup(self: *TestOwner, kind: Kind) Popup {
        return .{
            .kind = kind,
            .anchor = .window_top_center,
            .window = &self.window,
            .size = .{ .w = 100, .h = 30 },
            .paint = noPaint,
        };
    }
};

fn windowRect(hwnd: HWND) geom.Rect {
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetWindowRect(hwnd, &rc);
    return geom.Rect.fromRECT(rc);
}

test "win32 overlay: popups follow a moved owner" {
    const owner = try TestOwner.create(100, 100);
    defer owner.destroy();
    var label = owner.popup(.label);
    try label.show();
    defer label.destroy();
    const hwnd = label.hwnd.?;

    const before = windowRect(hwnd);
    _ = user32.SetWindowPos(owner.hwnd, null, 160, 130, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    windowChanged(&owner.window, .moved);
    const after = windowRect(hwnd);
    try std.testing.expectEqual(before.x + 60, after.x);
    try std.testing.expectEqual(before.y + 30, after.y);
    try std.testing.expectEqual(before.w, after.w);
    try std.testing.expectEqual(before.h, after.h);

    // The label is owned, not topmost.
    try std.testing.expectEqual(@as(?HWND, owner.hwnd), GetWindow(hwnd, gw_owner));
    const ex: usize = @bitCast(user32.GetWindowLongPtrW(hwnd, user32.GWL_EXSTYLE));
    try std.testing.expect(ex & user32.WS_EX_TOPMOST == 0);
    try std.testing.expect(ex & user32.WS_EX_NOACTIVATE != 0);
}

test "win32 overlay: re-owning on tab re-parent" {
    const a = try TestOwner.create(100, 100);
    defer a.destroy();
    const b = try TestOwner.create(500, 300);
    defer b.destroy();
    var label = a.popup(.label);
    try label.show();
    defer label.destroy();
    const hwnd = label.hwnd.?;
    try std.testing.expectEqual(@as(?HWND, a.hwnd), GetWindow(hwnd, gw_owner));

    try reown(&label, &b.window);
    try std.testing.expectEqual(@as(?HWND, b.hwnd), GetWindow(hwnd, gw_owner));
    try std.testing.expectEqual(@as(usize, 0), a.window.overlays.popups.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.window.overlays.popups.items.len);
    // Positioned on the new owner: its top centre.
    const r = windowRect(hwnd);
    const client = clientScreen(b.hwnd);
    try std.testing.expect(r.x >= client.x and r.right() <= client.right());
    try std.testing.expectEqual(client.y + 8, r.y);
}

test "win32 overlay: panel activation keeps the owner active" {
    const owner = try TestOwner.create(100, 100);
    defer owner.destroy();
    var panel = owner.popup(.panel);
    try panel.show();
    defer panel.destroy();
    const ph: LPARAM = @bitCast(@intFromPtr(panel.hwnd.?));
    const inactive: WPARAM = user32.WA_INACTIVE;

    // The owner is deactivated by its own panel: both messages are swallowed
    // (the owner's Window.active stays true), however the panel got the focus.
    beginPanelActivation(&owner.window);
    try std.testing.expectEqual(@as(?LRESULT, 1), windowMessage(&owner.window, user32.WM_NCACTIVATE, 0, 0));
    try std.testing.expectEqual(@as(?LRESULT, 0), windowMessage(&owner.window, user32.WM_ACTIVATE, inactive, ph));
    try std.testing.expect(!owner.window.overlays.panel_activation);
    try std.testing.expectEqual(@as(?LRESULT, 1), windowMessage(&owner.window, user32.WM_NCACTIVATE, 0, ph));

    // Any other deactivation is the window's own.
    try std.testing.expectEqual(@as(?LRESULT, null), windowMessage(&owner.window, user32.WM_NCACTIVATE, 0, 0));
    try std.testing.expectEqual(@as(?LRESULT, null), windowMessage(&owner.window, user32.WM_ACTIVATE, inactive, 0));
    try std.testing.expectEqual(@as(?LRESULT, null), windowMessage(&owner.window, user32.WM_ACTIVATE, inactive, @bitCast(@intFromPtr(owner.hwnd))));
    // Activation is never swallowed.
    try std.testing.expectEqual(@as(?LRESULT, null), windowMessage(&owner.window, user32.WM_ACTIVATE, user32.WA_ACTIVE, ph));
    try std.testing.expectEqual(@as(?LRESULT, null), windowMessage(&owner.window, user32.WM_NCACTIVATE, 1, 0));
}
