//! Window frame: client-side decorations, hit testing of the caption and
//! the non-client size.
//!
//! With `client` decorations the caption is removed (`WM_NCCALCSIZE`), the
//! tab strip is the caption and the min/max/close buttons are the chrome
//! painter's; they answer `WM_NCHITTEST` with `HTMINBUTTON` and friends so
//! that snap layouts and caption dragging keep working. The top-level has
//! no `WS_SYSMENU` then (otherwise DWM paints its own buttons over the
//! strip, SPEC §18 item 9), so the system menu is shown from here.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");
const Chrome = @import("Chrome.zig");
const theme = @import("theme.zig");

const user32 = win32.user32;
const dwmapi = win32.dwmapi;

const log = std.log.scoped(.win32_frame);

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const Decorations = enum { client, server, none };

pub const State = struct {
    decorations: Decorations = .server,
    /// The caption button under the pointer (non-client), mutually
    /// exclusive with `Window.strip_input.hover`.
    hover: TabStrip.Part = .nowhere,
    pressed: TabStrip.Part = .nowhere,
    nc_tracking: bool = false,
};

pub const Size = struct { w: i32, h: i32 };

pub const Insets = struct { left: i32, top: i32, right: i32, bottom: i32 };

const SC_KEYMENU = 0xF100;
const SC_SIZEMASK = 0xFFF0;

extern "user32" fn GetSystemMenu(hwnd: win32.foundation.HWND, revert: win32.foundation.BOOL) callconv(.winapi) ?user32.HMENU;

pub fn decorationsFor(setting: configpkg.Config.WindowDecoration) Decorations {
    return switch (setting) {
        .auto, .client => .client,
        .server => .server,
        .none => .none,
    };
}

/// The style of the top-level window: no system menu for `client`
/// decorations.
pub fn windowStyle(decorations: Decorations) u32 {
    const base: u32 = user32.WS_OVERLAPPEDWINDOW | user32.WS_CLIPCHILDREN;
    return switch (decorations) {
        .client => base & ~@as(u32, user32.WS_SYSMENU),
        .server, .none => base,
    };
}

/// The `WM_NCHITTEST` result of a strip part. `x` is the client x of the
/// point, `width` the client width; the top corners are `3 * resize_band`.
pub fn ncHitCode(part: TabStrip.Part, x: i32, width: i32, resize_band: i32) u32 {
    return switch (part) {
        .caption => @intCast(user32.HTCAPTION),
        .minimize => @intCast(user32.HTMINBUTTON),
        .maximize => @intCast(user32.HTMAXBUTTON),
        .close => @intCast(user32.HTCLOSE),
        .resize_top => if (x < resize_band * 3)
            @intCast(user32.HTTOPLEFT)
        else if (x >= width - resize_band * 3)
            @intCast(user32.HTTOPRIGHT)
        else
            @intCast(user32.HTTOP),
        .nowhere, .tab, .tab_close, .new_tab => @intCast(user32.HTCLIENT),
    };
}

/// Widths of the sizing frame kept around the client area. With `client`
/// decorations the top is part of the strip, except when maximized, where
/// the window overhangs the monitor by the frame on every side.
pub fn frameInsets(dpi: u32, maximized: bool, decorations: Decorations) Insets {
    if (decorations == .none) return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const d = if (dpi == 0) 96 else dpi;
    const frame = user32.GetSystemMetricsForDpi(user32.SM_CXFRAME, d) +
        user32.GetSystemMetricsForDpi(user32.SM_CXPADDEDBORDER, d);
    return .{
        .left = frame,
        .top = if (maximized) frame else 0,
        .right = frame,
        .bottom = frame,
    };
}

fn partOfHit(hit: usize) TabStrip.Part {
    return switch (hit) {
        @as(usize, @intCast(user32.HTMINBUTTON)) => .minimize,
        @as(usize, @intCast(user32.HTMAXBUTTON)) => .maximize,
        @as(usize, @intCast(user32.HTCLOSE)) => .close,
        else => .nowhere,
    };
}

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    if (msg == user32.WM_SYSCOMMAND) {
        if ((wparam & SC_SIZEMASK) != SC_KEYMENU) return null;
        // A lone Alt tap would start the menu's modal loop and freeze the
        // UI thread. Alt+Space is the system menu; no other Alt+key has a
        // menu to open.
        const key: usize = @bitCast(lparam);
        if (window.frame.decorations == .client and key == ' ') showSystemMenuBelowStrip(window);
        return 0;
    }

    if (window.frame.decorations != .client and msg != user32.WM_NCCALCSIZE) return null;
    if (window.frame.decorations == .server) return null;

    switch (msg) {
        user32.WM_NCCALCSIZE => {
            if (wparam == 0) return null;
            const params: *user32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const insets = if (window.placement.fullscreen)
                frameInsets(window.dpi, false, .none)
            else
                frameInsets(window.dpi, user32.IsZoomed(window.hwnd) != 0, window.frame.decorations);
            const rc = &params.rgrc[0];
            rc.left += insets.left;
            rc.top += insets.top;
            rc.right -= insets.right;
            rc.bottom -= insets.bottom;
            return 0;
        },

        user32.WM_NCHITTEST => {
            const res = user32.DefWindowProcW(window.hwnd, msg, wparam, lparam);
            if (res != user32.HTCLIENT) return res;

            var pt: win32.foundation.POINT = .{ .x = user32.getXLparam(lparam), .y = user32.getYLparam(lparam) };
            _ = user32.ScreenToClient(window.hwnd, &pt);
            var rc: win32.foundation.RECT = undefined;
            _ = user32.GetClientRect(window.hwnd, &rc);

            const m = TabStrip.Metrics.forDpi(window.dpi);
            const maximized = user32.IsZoomed(window.hwnd) != 0;
            const part = window.strip.hitTest(m, pt.x, pt.y, maximized);
            return @intCast(ncHitCode(part, pt.x, rc.right - rc.left, m.resize_band));
        },

        user32.WM_NCMOUSEMOVE => {
            if (!window.frame.nc_tracking) {
                var tme: user32.TRACKMOUSEEVENT = .{
                    .dwFlags = user32.TME_LEAVE | user32.TME_NONCLIENT,
                    .hwndTrack = window.hwnd,
                };
                if (user32.TrackMouseEvent(&tme) != 0) window.frame.nc_tracking = true;
            }
            setHover(window, partOfHit(wparam));
            return null;
        },

        user32.WM_NCMOUSELEAVE => {
            window.frame.nc_tracking = false;
            setHover(window, .nowhere);
            return null;
        },

        // Pointer in the client area: the strip's own hover takes over.
        user32.WM_MOUSEMOVE => {
            setHover(window, .nowhere);
            return null;
        },

        user32.WM_NCLBUTTONDOWN, user32.WM_NCLBUTTONDBLCLK => {
            const part = partOfHit(wparam);
            if (part == .nowhere) return null;
            // DefWindowProc would draw the classic button.
            window.frame.pressed = part;
            Chrome.invalidate(window);
            return 0;
        },

        user32.WM_NCLBUTTONUP => {
            const part = partOfHit(wparam);
            if (part == .nowhere) return null;
            const pressed = window.frame.pressed;
            window.frame.pressed = .nowhere;
            Chrome.invalidate(window);
            if (!std.meta.eql(pressed, part)) return 0;
            const sc: usize = switch (part) {
                .minimize => user32.SC_MINIMIZE,
                .maximize => if (user32.IsZoomed(window.hwnd) != 0) user32.SC_RESTORE else user32.SC_MAXIMIZE,
                else => user32.SC_CLOSE,
            };
            _ = user32.PostMessageW(window.hwnd, user32.WM_SYSCOMMAND, sc, 0);
            return 0;
        },

        // The button was released outside the non-client area.
        user32.WM_LBUTTONUP => {
            if (window.frame.pressed != .nowhere) {
                window.frame.pressed = .nowhere;
                Chrome.invalidate(window);
            }
            return null;
        },

        user32.WM_NCRBUTTONUP => {
            if (wparam != user32.HTCAPTION) return null;
            showSystemMenu(window, user32.getXLparam(lparam), user32.getYLparam(lparam));
            return 0;
        },

        user32.WM_NCACTIVATE => {
            Chrome.invalidate(window);
            return null;
        },

        else => return null,
    }
}

fn setHover(window: *Window, part: TabStrip.Part) void {
    if (std.meta.eql(window.frame.hover, part)) return;
    window.frame.hover = part;
    if (part != .nowhere) window.strip_input.hover = .nowhere;
    Chrome.invalidate(window);
}

fn showSystemMenuBelowStrip(window: *Window) void {
    var pt: win32.foundation.POINT = .{ .x = 0, .y = window.strip.bounds.h };
    _ = user32.ClientToScreen(window.hwnd, &pt);
    showSystemMenu(window, pt.x, pt.y);
}

/// The system menu at a screen point; the chosen command is posted as
/// `WM_SYSCOMMAND`.
fn showSystemMenu(window: *Window, x: i32, y: i32) void {
    const menu = GetSystemMenu(window.hwnd, 0) orelse {
        log.warn("no system menu err={}", .{win32.kernel32.GetLastError()});
        return;
    };
    // The menu belongs to the foreground window, or it will not close
    // when the user clicks elsewhere.
    _ = user32.SetForegroundWindow(window.hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON,
        x,
        y,
        window.hwnd,
        null,
    );
    if (cmd > 0) _ = user32.PostMessageW(window.hwnd, user32.WM_SYSCOMMAND, @intCast(cmd), 0);
}

/// Bring the window's frame in line with the config: decorations, system
/// menu style, Mica and the extended frame.
pub fn apply(window: *Window) void {
    const decorations = decorationsFor(window.app.config.@"window-decoration");
    window.frame.decorations = decorations;

    const style: usize = @bitCast(user32.GetWindowLongPtrW(window.hwnd, user32.GWL_STYLE));
    const sysmenu: usize = user32.WS_SYSMENU;
    const want = (style & ~sysmenu) | (windowStyle(decorations) & sysmenu);
    if (want != style) _ = user32.SetWindowLongPtrW(window.hwnd, user32.GWL_STYLE, @bitCast(want));

    const mica = theme.palette(window).mica;
    const m = TabStrip.Metrics.forDpi(window.dpi);
    // Under the opaque painter (`theme.painter_over_mica = false`) `mica`
    // is false and the 1 px keeps the DWM top border of a restored window.
    const margins: dwmapi.MARGINS = .{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = if (decorations != .client) 0 else if (mica) m.height else 1,
        .cyBottomHeight = 0,
    };
    _ = dwmapi.DwmExtendFrameIntoClientArea(window.hwnd, &margins);

    const backdrop: i32 = if (mica) dwmapi.DWMSBT_MAINWINDOW else dwmapi.DWMSBT_NONE;
    _ = dwmapi.DwmSetWindowAttribute(
        window.hwnd,
        dwmapi.DWMWA_SYSTEMBACKDROP_TYPE,
        &backdrop,
        @sizeOf(i32),
    );

    _ = user32.SetWindowPos(
        window.hwnd,
        null,
        0,
        0,
        0,
        0,
        user32.SWP_FRAMECHANGED | user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE,
    );
    // A window still being created has no tabs; its creation lays it out.
    if (window.tabs.items.len > 0) window.layout();
}

pub fn stripMode(window: *const Window) TabStrip.Mode {
    if (window.placement.fullscreen) return .hidden;
    return switch (window.frame.decorations) {
        .client => .titlebar,
        .server, .none => if (window.showTabs()) .tabs_only else .hidden,
    };
}

/// Window size minus content size: frame insets plus the strip height.
pub fn nonClientSize(window: *const Window) Size {
    const strip_h: i32 = if (stripMode(window) == .hidden) 0 else TabStrip.Metrics.forDpi(window.dpi).height;

    switch (window.frame.decorations) {
        .server => {
            var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            const style: u32 = @truncate(@as(usize, @bitCast(
                user32.GetWindowLongPtrW(window.hwnd, user32.GWL_STYLE),
            )));
            const ex_style: u32 = @truncate(@as(usize, @bitCast(
                user32.GetWindowLongPtrW(window.hwnd, user32.GWL_EXSTYLE),
            )));
            _ = user32.AdjustWindowRectExForDpi(&rc, style, 0, ex_style, window.dpi);
            return .{ .w = rc.right - rc.left, .h = rc.bottom - rc.top + strip_h };
        },
        .client, .none => {
            const i = frameInsets(window.dpi, false, window.frame.decorations);
            return .{ .w = i.left + i.right, .h = i.top + i.bottom + strip_h };
        },
    }
}

test "win32 frame: decorations mapping" {
    try std.testing.expectEqual(Decorations.client, decorationsFor(.auto));
    try std.testing.expectEqual(Decorations.client, decorationsFor(.client));
    try std.testing.expectEqual(Decorations.server, decorationsFor(.server));
    try std.testing.expectEqual(Decorations.none, decorationsFor(.none));

    try std.testing.expect(windowStyle(.client) & user32.WS_SYSMENU == 0);
    try std.testing.expect(windowStyle(.server) & user32.WS_SYSMENU != 0);
    try std.testing.expect(windowStyle(.client) & user32.WS_THICKFRAME != 0);
}

test "win32 frame: hit codes incl. top corners" {
    const band = 6;
    const w = 1200;
    try std.testing.expectEqual(@as(u32, user32.HTCAPTION), ncHitCode(.caption, 500, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTMINBUTTON), ncHitCode(.minimize, 1070, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTMAXBUTTON), ncHitCode(.maximize, 1110, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTCLOSE), ncHitCode(.close, 1190, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTCLIENT), ncHitCode(.{ .tab = 2 }, 300, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTCLIENT), ncHitCode(.{ .tab_close = 2 }, 300, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTCLIENT), ncHitCode(.new_tab, 700, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTCLIENT), ncHitCode(.nowhere, 700, w, band));

    try std.testing.expectEqual(@as(u32, user32.HTTOPLEFT), ncHitCode(.resize_top, 0, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTTOPLEFT), ncHitCode(.resize_top, 17, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTTOP), ncHitCode(.resize_top, 18, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTTOP), ncHitCode(.resize_top, 1181, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTTOPRIGHT), ncHitCode(.resize_top, 1182, w, band));
    try std.testing.expectEqual(@as(u32, user32.HTTOPRIGHT), ncHitCode(.resize_top, 1199, w, band));
}

test "win32 frame: insets restored vs maximized at 96 and 144 dpi" {
    for ([_]u32{ 96, 144 }) |dpi| {
        const restored = frameInsets(dpi, false, .client);
        try std.testing.expect(restored.left > 0);
        try std.testing.expectEqual(restored.left, restored.right);
        try std.testing.expectEqual(restored.left, restored.bottom);
        try std.testing.expectEqual(@as(i32, 0), restored.top);

        const maximized = frameInsets(dpi, true, .client);
        try std.testing.expect(maximized.top > 0);
        try std.testing.expectEqual(maximized.left, maximized.top);
        try std.testing.expectEqual(restored.left, maximized.left);

        const none = frameInsets(dpi, true, .none);
        try std.testing.expectEqual(@as(i32, 0), none.top + none.left + none.right + none.bottom);
    }
    try std.testing.expect(frameInsets(144, false, .client).left > frameInsets(96, false, .client).left);
}
