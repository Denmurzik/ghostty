//! Colours of the window chrome and the system colour scheme. Stub: Task 15.
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const util = @import("util.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

pub const Palette = struct {
    dark: bool,
    mica: bool,
    strip_bg: Color,
    tab_active_bg: Color,
    tab_hover_bg: Color,
    text: Color,
    text_inactive: Color,
    button_hover_bg: Color,
    button_pressed_bg: Color,
    close_hover_bg: Color = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C },
    close_hover_text: Color = .{ .r = 255, .g = 255, .b = 255 },
    divider: Color,
};

pub fn palette(window: *const Window) Palette {
    _ = window;
    return .{
        .dark = true,
        .mica = false,
        .strip_bg = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
        .tab_active_bg = .{ .r = 0x2D, .g = 0x2D, .b = 0x2D },
        .tab_hover_bg = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
        .text = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .text_inactive = .{ .r = 0x9D, .g = 0x9D, .b = 0x9D },
        .button_hover_bg = .{ .r = 0x33, .g = 0x33, .b = 0x33 },
        .button_pressed_bg = .{ .r = 0x3D, .g = 0x3D, .b = 0x3D },
        .divider = .{ .r = 0x3A, .g = 0x3A, .b = 0x3A },
    };
}

pub fn applyToWindow(window: *Window) void {
    const dark: win32.foundation.BOOL = @intFromBool(util.systemUsesDarkTheme());
    _ = win32.dwmapi.DwmSetWindowAttribute(
        window.hwnd,
        win32.dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(win32.foundation.BOOL),
    );
}

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}

pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void {
    _ = app;
    _ = scheme;
}
