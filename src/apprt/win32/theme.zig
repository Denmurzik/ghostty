//! Colours of the window chrome and the system colour scheme: the palette of
//! the tab strip, the dark mode of the frame and scrollbars, and the reaction
//! to a changed system theme or high contrast setting.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const frame = @import("frame.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const overlay_host = @import("overlay.zig");
const Window = @import("Window.zig");
const util = @import("util.zig");
const composition = @import("composition.zig");
const menu_theme = @import("menu_theme.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_theme);

const COLOR_WINDOW = 5;
const COLOR_WINDOWTEXT = 8;
const COLOR_HIGHLIGHT = 13;
const COLOR_HIGHLIGHTTEXT = 14;

/// The strip is painted in the terminal background (macOS-style unified
/// title row), no Mica under it (M3 Task 29, DECISIONS 2026-10-27).
const painter_over_mica = false;

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
    /// The capsule behind the tabs and the new-tab button, translucent over `strip_bg`.
    track_bg: Color = .{ .r = 255, .g = 255, .b = 255, .a = 0x14 },
    /// The selected tab, over the track.
    pill_bg: Color = .{ .r = 255, .g = 255, .b = 255, .a = 0x24 },
    /// Outline of the new-tab button and of a light selected tab.
    outline: Color = .{ .r = 255, .g = 255, .b = 255, .a = 0x26 },
    /// Thin lines between unselected tabs.
    separator: Color = .{ .r = 255, .g = 255, .b = 255, .a = 0x2E },
    /// Key labels in a tab.
    text_dim: Color = .{ .r = 255, .g = 255, .b = 255, .a = 0x80 },
};

/// The system colours that replace the palette in high contrast mode.
const SystemColors = struct {
    window: Color,
    window_text: Color,
    highlight: Color,
    highlight_text: Color,

    fn read() SystemColors {
        return .{
            .window = fromColorRef(win32.user32.GetSysColor(COLOR_WINDOW)),
            .window_text = fromColorRef(win32.user32.GetSysColor(COLOR_WINDOWTEXT)),
            .highlight = fromColorRef(win32.user32.GetSysColor(COLOR_HIGHLIGHT)),
            .highlight_text = fromColorRef(win32.user32.GetSysColor(COLOR_HIGHLIGHTTEXT)),
        };
    }
};

/// A COLORREF is 0x00BBGGRR.
fn fromColorRef(c: u32) Color {
    return .{
        .r = @truncate(c),
        .g = @truncate(c >> 8),
        .b = @truncate(c >> 16),
    };
}

fn luminanceIsDark(c: Color) bool {
    const rgb: terminal.color.RGB = .{ .r = c.r, .g = c.g, .b = c.b };
    return rgb.luminance() < 0.5;
}

/// The split divider colour when the config sets none, as on macOS: the
/// terminal background with its HSB brightness scaled down by 0.08 (light
/// background) or 0.4 (dark). Scaling the brightness keeps hue and
/// saturation, which is scaling all channels.
fn derivedDivider(bg: Color) Color {
    const lum = 0.299 * @as(f64, @floatFromInt(bg.r)) / 255 +
        0.587 * @as(f64, @floatFromInt(bg.g)) / 255 +
        0.114 * @as(f64, @floatFromInt(bg.b)) / 255;
    const amount: f64 = if (lum > 0.5) 0.08 else 0.4;
    return .{
        .r = darkenChannel(bg.r, amount),
        .g = darkenChannel(bg.g, amount),
        .b = darkenChannel(bg.b, amount),
    };
}

fn darkenChannel(c: u8, amount: f64) u8 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(c)) * (1 - amount)));
}

/// The fields of the config that the chrome depends on. Kept as a copy:
/// the config handed to `config_change` is only valid during the call.
const Inputs = struct {
    window_theme: configpkg.Config.WindowTheme,
    background: Color,
    foreground: Color,
    titlebar_background: ?Color,
    titlebar_foreground: ?Color,
    split_divider: ?Color,

    fn from(config: *const configpkg.Config) Inputs {
        return .{
            .window_theme = config.@"window-theme",
            .background = fromConfig(config.background),
            .foreground = fromConfig(config.foreground),
            .titlebar_background = if (config.@"window-titlebar-background") |c| fromConfig(c) else null,
            .titlebar_foreground = if (config.@"window-titlebar-foreground") |c| fromConfig(c) else null,
            .split_divider = if (config.@"split-divider-color") |c| fromConfig(c) else null,
        };
    }

    fn fromConfig(c: configpkg.Config.Color) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }

    fn isDark(self: Inputs, sys_dark: bool) bool {
        return switch (self.window_theme) {
            .light => false,
            .dark => true,
            .auto, .system => sys_dark,
            .ghostty => luminanceIsDark(self.background),
        };
    }
};

/// The system colour scheme; null until the first read. UI thread only.
var system_dark: ?bool = null;

/// Cached `SPI_GETHIGHCONTRAST`; null until read. UI thread only.
var high_contrast: ?bool = null;

/// What the last `config_change` delivered: the config with its
/// conditional (light/dark theme) state applied, which `App.config` is not.
var applied: ?Inputs = null;

/// The `WM_SETTINGCHANGE` broadcasts acted on last. A broadcast reaches
/// every top-level window, and two settings may arrive in the same tick
/// (ImmersiveColorSet and high contrast), so the message time alone is not
/// a key. A few slots: windows interleave the broadcasts.
var recent_settings: RecentSettings = .{};

const SettingKey = struct {
    time: i32,
    wparam: usize,
    name_hash: u64,
};

const RecentSettings = struct {
    keys: [4]?SettingKey = @splat(null),
    next: usize = 0,

    /// True if `key` was seen before; otherwise it is remembered.
    fn seen(self: *RecentSettings, key: SettingKey) bool {
        for (self.keys) |k| {
            if (k) |v| if (std.meta.eql(v, key)) return true;
        }
        self.keys[self.next] = key;
        self.next = (self.next + 1) % self.keys.len;
        return false;
    }
};

pub fn highContrast() bool {
    if (high_contrast) |hc| return hc;
    var info: win32.user32.HIGHCONTRASTW = .{};
    const ok = win32.user32.SystemParametersInfoW(
        win32.user32.SPI_GETHIGHCONTRAST,
        @sizeOf(win32.user32.HIGHCONTRASTW),
        &info,
        0,
    );
    const on = ok != 0 and (info.dwFlags & win32.user32.HCF_HIGHCONTRASTON) != 0;
    high_contrast = on;
    return on;
}

pub fn isDark(config: *const configpkg.Config, sys_dark: bool) bool {
    return Inputs.from(config).isDark(sys_dark);
}

pub fn compute(config: *const configpkg.Config, sys_dark: bool, active: bool) Palette {
    return computeWith(.from(config), sys_dark, active, if (highContrast()) SystemColors.read() else null);
}

fn computeWith(in: Inputs, sys_dark: bool, active: bool, hc: ?SystemColors) Palette {
    // An inactive window's caption text is `text_inactive`, picked by the painter.
    _ = active;

    if (hc) |sys| {
        const text = sys.window_text;
        const overlay: Color = .{ .r = text.r, .g = text.g, .b = text.b, .a = 0x30 };
        return .{
            .dark = luminanceIsDark(sys.window),
            .mica = false,
            .strip_bg = sys.window,
            .tab_active_bg = sys.window,
            .tab_hover_bg = overlay,
            .text = text,
            .text_inactive = text,
            .button_hover_bg = overlay,
            .button_pressed_bg = .{ .r = text.r, .g = text.g, .b = text.b, .a = 0x50 },
            .close_hover_bg = sys.highlight,
            .close_hover_text = sys.highlight_text,
            .divider = text,
            .track_bg = overlay,
            .pill_bg = .{ .r = text.r, .g = text.g, .b = text.b, .a = 0x50 },
            .outline = text,
            .separator = text,
            .text_dim = text,
        };
    }

    const ghostty = in.window_theme == .ghostty;
    const mica = painter_over_mica and !ghostty;

    // As on macOS the title row and the tab row are the terminal's
    // background; the ink follows its brightness (not the system scheme).
    const bg: Color = if (ghostty) (in.titlebar_background orelse in.background) else in.background;
    const dark = luminanceIsDark(bg);
    const ink: Color = if (dark) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 0, .g = 0, .b = 0 };
    const with = struct {
        fn alpha(c: Color, a: u8) Color {
            return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
        }
    };

    var p: Palette = .{
        .dark = in.isDark(sys_dark),
        .mica = mica,
        .strip_bg = bg,
        .tab_active_bg = in.background,
        .tab_hover_bg = with.alpha(ink, if (dark) 0x10 else 0x0A),
        // Primary and secondary label colours of macOS.
        .text = with.alpha(ink, if (dark) 0xE6 else 0xD9),
        .text_inactive = with.alpha(ink, 0x80),
        .text_dim = with.alpha(ink, 0x80),
        .button_hover_bg = with.alpha(ink, if (dark) 0x1A else 0x10),
        .button_pressed_bg = with.alpha(ink, if (dark) 0x0E else 0x0A),
        .divider = in.split_divider orelse derivedDivider(in.background),
        .track_bg = with.alpha(ink, if (dark) 0x14 else 0x0F),
        // Lighter than the track: white over a dark one, the window over a light one.
        .pill_bg = if (dark) with.alpha(ink, 0x24) else .{ .r = 255, .g = 255, .b = 255, .a = 0xB3 },
        .outline = with.alpha(ink, if (dark) 0x26 else 0x1F),
        .separator = with.alpha(ink, if (dark) 0x2E else 0x26),
    };

    if (ghostty) p.text = in.titlebar_foreground orelse in.foreground;
    if (mica) p.strip_bg.a = 0;
    return p;
}

/// Whether the window counts as the active one: it is the foreground
/// window, or one of its overlay panels is.
pub fn windowActive(window: *const Window) bool {
    const fg = win32.user32.GetForegroundWindow() orelse return false;
    return fg == window.hwnd or overlay_host.panelHasForeground(window);
}

pub fn palette(window: *const Window) Palette {
    const active = windowActive(window);
    var p = computeWith(
        applied orelse .from(&window.app.config),
        system_dark orelse false,
        active,
        if (highContrast()) SystemColors.read() else null,
    );
    // A translucent window: the title and tab rows are the terminal
    // background at the terminal's alpha (the painter's target is premultiplied).
    if (composition.isTranslucent(window)) p.strip_bg.a = composition.alphaByte(window);
    return p;
}

/// Dark title bar and scrollbars of one window, and a repaint of its chrome.
/// The first call also reports the system colour scheme to core, so that the
/// `theme = light:...,dark:...` of the config is resolved before it is used.
pub fn applyToWindow(window: *Window) void {
    const app = window.app;
    if (system_dark == null) {
        const dark = util.systemUsesDarkTheme();
        system_dark = dark;
        app.core_app.colorSchemeEvent(app, if (dark) .dark else .light) catch |err| {
            log.warn("unable to report the color scheme err={}", .{err});
        };
    }

    const in: Inputs = applied orelse .from(&app.config);
    const dark = in.isDark(system_dark orelse false);

    menu_theme.apply(dark, highContrast());

    const flag: win32.foundation.BOOL = @intFromBool(dark);
    _ = win32.dwmapi.DwmSetWindowAttribute(
        window.hwnd,
        win32.dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &flag,
        @sizeOf(win32.foundation.BOOL),
    );

    const dark_explorer = std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer");
    for (window.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            _ = win32.uxtheme.SetWindowTheme(entry.view.hwnd, if (dark) dark_explorer else null, null);
        }
    }

    // Mica follows the palette, which the config or the scheme just changed.
    frame.apply(window);
    Chrome.invalidate(window);
}

fn applyToAll(app: *App) void {
    var windows = app.forEachWindow(true);
    while (windows.next()) |window| {
        if (!window.tearing_down) applyToWindow(window);
    }
}

/// Remember the config the chrome is drawn from, and apply it everywhere.
pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    applied = .from(config);
    var windows = app.forEachWindow(true);
    while (windows.next()) |window| {
        if (window.tearing_down) continue;
        applyToWindow(window);
        // A window still being created is in the list without tabs; its
        // creation lays it out itself.
        if (window.tabs.items.len > 0) window.layout();
    }
}

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        win32.user32.WM_SETTINGCHANGE => settingChangedMsg(window.app, wparam, lparam),
        win32.user32.WM_ACTIVATE => Chrome.invalidate(window),
        else => {},
    }
    return null;
}

/// The system colour scheme changed (or was simulated by the test op).
pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void {
    system_dark = scheme == .dark;
    app.core_app.colorSchemeEvent(app, scheme) catch |err| {
        log.warn("unable to report the color scheme err={}", .{err});
    };
    var windows = app.forEachWindow(true);
    while (windows.next()) |window| {
        if (window.tearing_down) continue;
        var all_tabs = window.allTabs();
        while (all_tabs.next()) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.core().colorSchemeCallback(scheme) catch |err| {
                    log.warn("unable to report the color scheme to a surface err={}", .{err});
                };
            }
        }
    }
    applyToAll(app);
}

/// `WM_SETTINGCHANGE`; `lparam` is the name of the changed setting, if any.
/// A broadcast reaches every top-level window, only the first one acts.
pub fn settingChanged(app: *App, lparam: LPARAM) void {
    settingChangedMsg(app, 0, lparam);
}

pub fn settingChangedMsg(app: *App, wparam: WPARAM, lparam: LPARAM) void {
    const name: ?[]const u16 = if (lparam == 0) null else std.mem.span(@as([*:0]const u16, @ptrFromInt(@as(usize, @bitCast(lparam)))));
    if (recent_settings.seen(.{
        .time = win32.user32.GetMessageTime(),
        .wparam = wparam,
        .name_hash = if (name) |n| std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(n)) else 0,
    })) return;

    if (name) |wide| {
        if (std.mem.eql(u16, wide, std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet"))) {
            const dark = util.systemUsesDarkTheme();
            if (system_dark != dark) schemeChanged(app, if (dark) .dark else .light);
            return;
        }
        if (!std.mem.eql(u16, wide, std.unicode.utf8ToUtf16LeStringLiteral("WindowsThemeElement"))) return;
    }

    // WindowsThemeElement, or SPI_SETHIGHCONTRAST (no name).
    high_contrast = null;
    applyToAll(app);
}

test "win32 theme: dark and light palettes" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();

    // The strip is the terminal background (default #282C34, dark): the ink is
    // white, whatever the system scheme says.
    const dark = computeWith(.from(&cfg), true, true, null);
    try std.testing.expect(dark.dark);
    try std.testing.expectEqual(Color{ .r = 0x28, .g = 0x2C, .b = 0x34 }, dark.strip_bg);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0xE6 }, dark.text);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x80 }, dark.text_inactive);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x10 }, dark.tab_hover_bg);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x1A }, dark.button_hover_bg);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x0E }, dark.button_pressed_bg);
    // The track and the selected pill are lighter than the background.
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x14 }, dark.track_bg);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0x24 }, dark.pill_bg);
    // Default background #282C34 is dark: darkened by 0.4.
    try std.testing.expectEqual(Color{ .r = 24, .g = 26, .b = 31 }, dark.divider);
    try std.testing.expectEqual(Color{ .r = cfg.background.r, .g = cfg.background.g, .b = cfg.background.b }, dark.tab_active_bg);
    try std.testing.expect(dark.strip_bg.a == 255);

    const sys_light = computeWith(.from(&cfg), false, true, null);
    try std.testing.expect(!sys_light.dark);
    try std.testing.expectEqual(dark.text, sys_light.text);
    try std.testing.expectEqual(dark.strip_bg, sys_light.strip_bg);

    // A light terminal background gives black ink and a white pill on a grey track.
    cfg.background = .{ .r = 0xFA, .g = 0xFA, .b = 0xFA };
    const light = computeWith(.from(&cfg), false, true, null);
    try std.testing.expectEqual(Color{ .r = 0xFA, .g = 0xFA, .b = 0xFA }, light.strip_bg);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0xD9 }, light.text);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0x80 }, light.text_inactive);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0x0F }, light.track_bg);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 0xB3 }, light.pill_bg);
    cfg.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
    try std.testing.expectEqual(Color{ .r = 235, .g = 235, .b = 235 }, derivedDivider(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(Color{ .r = 235, .g = 235, .b = 235 }, derivedDivider(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, derivedDivider(.{ .r = 0, .g = 0, .b = 0 }));

    // window-theme light/dark ignores the system scheme, and the divider
    // colour of the config wins.
    cfg.@"window-theme" = .light;
    cfg.@"split-divider-color" = .{ .r = 1, .g = 2, .b = 3 };
    const forced = computeWith(.from(&cfg), true, true, null);
    try std.testing.expect(!forced.dark);
    try std.testing.expectEqual(Color{ .r = 1, .g = 2, .b = 3 }, forced.divider);
    cfg.@"window-theme" = .dark;
    try std.testing.expect(isDark(&cfg, false));
}

test "win32 theme: ghostty theme follows background luminance" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();
    cfg.@"window-theme" = .ghostty;

    cfg.background = .{ .r = 0xFA, .g = 0xFA, .b = 0xFA };
    try std.testing.expect(!isDark(&cfg, true));
    try std.testing.expect(!computeWith(.from(&cfg), true, true, null).dark);

    cfg.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    try std.testing.expect(isDark(&cfg, false));
    try std.testing.expect(computeWith(.from(&cfg), false, true, null).dark);
}

test "win32 theme: titlebar colours only with window-theme ghostty" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();
    cfg.@"window-titlebar-background" = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    cfg.@"window-titlebar-foreground" = .{ .r = 0x44, .g = 0x55, .b = 0x66 };

    const plain = computeWith(.from(&cfg), true, true, null);
    try std.testing.expectEqual(@as(u8, 0x28), plain.strip_bg.r);
    try std.testing.expectEqual(@as(u8, 0xFF), plain.text.r);

    cfg.@"window-theme" = .ghostty;
    const ghostty = computeWith(.from(&cfg), true, true, null);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, ghostty.strip_bg);
    try std.testing.expectEqual(Color{ .r = 0x44, .g = 0x55, .b = 0x66 }, ghostty.text);

    // Without the overrides the terminal colours are used.
    cfg.@"window-titlebar-background" = null;
    cfg.@"window-titlebar-foreground" = null;
    const fallback = computeWith(.from(&cfg), true, true, null);
    try std.testing.expectEqual(Color{ .r = cfg.background.r, .g = cfg.background.g, .b = cfg.background.b }, fallback.strip_bg);
    try std.testing.expectEqual(Color{ .r = cfg.foreground.r, .g = cfg.foreground.g, .b = cfg.foreground.b }, fallback.text);
}

test "win32 theme: the strip is opaque, no mica under it" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();

    const p = computeWith(.from(&cfg), true, true, null);
    try std.testing.expect(!p.mica);
    try std.testing.expectEqual(@as(u8, 255), p.strip_bg.a);

    cfg.@"window-theme" = .ghostty;
    const solid = computeWith(.from(&cfg), true, true, null);
    try std.testing.expect(!solid.mica);
    try std.testing.expectEqual(@as(u8, 255), solid.strip_bg.a);
}

test "win32 theme: high contrast disables mica" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();

    const sys: SystemColors = .{
        .window = .{ .r = 0, .g = 0, .b = 0 },
        .window_text = .{ .r = 0xFF, .g = 0xFF, .b = 0 },
        .highlight = .{ .r = 0x1A, .g = 0xEB, .b = 0xFF },
        .highlight_text = .{ .r = 0, .g = 0, .b = 0 },
    };
    const p = computeWith(.from(&cfg), false, true, sys);
    try std.testing.expect(!p.mica);
    try std.testing.expect(p.dark);
    try std.testing.expectEqual(sys.window, p.strip_bg);
    try std.testing.expectEqual(sys.window_text, p.text);
    try std.testing.expectEqual(sys.window_text, p.divider);
    try std.testing.expectEqual(sys.highlight, p.close_hover_bg);
    try std.testing.expectEqual(sys.highlight_text, p.close_hover_text);
}

test "win32 theme: colorref channel order" {
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, fromColorRef(0x00332211));
}

test "win32 theme: settings broadcast dedup keys on time, wparam and name" {
    var r: RecentSettings = .{};
    const color: SettingKey = .{ .time = 100, .wparam = 0, .name_hash = 1 };
    const contrast: SettingKey = .{ .time = 100, .wparam = 0x43, .name_hash = 0 };

    try std.testing.expect(!r.seen(color));
    // A different setting in the same tick is not a duplicate.
    try std.testing.expect(!r.seen(contrast));
    // The same broadcasts arriving at the next window are.
    try std.testing.expect(r.seen(color));
    try std.testing.expect(r.seen(contrast));
    // Same name, later tick: a new change.
    try std.testing.expect(!r.seen(.{ .time = 101, .wparam = 0, .name_hash = 1 }));
}
