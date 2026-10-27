//! Per-surface decorations drawn by the renderer: unfocused-split dimming
//! and the bell border. The renderer reads `Surface.decor_word` (a
//! `Word`) each frame and draws it over the finished frame; a zero word
//! costs nothing. Both follow Ghostty for macOS (`SurfaceView.swift`): a
//! rectangle of `unfocused-split-fill` at `1 - unfocused-split-opacity`
//! above every split but the focused one, and a 3 pt border of
//! `rgb(255, 204, 0)` at half opacity around a surface that rang.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Decor = @import("../../renderer/d3d11/Decor.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");

const log = std.log.scoped(.win32_decor);

const Color = configpkg.Config.Color;

pub const Word = Decor.Word;

/// Per-surface state of the decorations.
pub const State = struct {
    /// The surface rang and `bell-features = border` shows it.
    bell_border: bool = false,
};

/// How long the border of a focused surface stays: a focus-in would clear
/// it, but the surface already has the focus.
const bell_border_ms: u32 = 1000;

/// The border width, in points.
const bell_border_pt: i32 = 3;

/// The macOS border colour (`Color(red: 1.0, green: 0.8, blue: 0.0)`).
const bell_color: Color = .{ .r = 255, .g = 204, .b = 0 };

pub const Input = struct {
    /// The number of visible surfaces in the tab.
    tab_surfaces: usize,
    /// `surface == tab.focusedSurface()`: independent of the Win32 keyboard
    /// focus and of the window activation, so the search bar, the palette,
    /// dialogs and a deactivated window never dim the focused split.
    focused_in_tab: bool,
    /// Another surface of the tab is zoomed: this one is hidden.
    zoomed_other: bool,
    bell_border: bool,
    /// `unfocused-split-opacity`.
    opacity: f64,
    /// `unfocused-split-fill`.
    fill: ?Color,
    background: Color,
    bell_color: Color,
    dpi: u32,
};

fn rgb(c: Color) u24 {
    return @as(u24, c.r) | @as(u24, c.g) << 8 | @as(u24, c.b) << 16;
}

/// The decorations of one surface.
pub fn compute(in: Input) Word {
    var word: Word = .{};
    if (in.zoomed_other) return word;

    if (in.tab_surfaces >= 2 and !in.focused_in_tab) {
        const opacity = std.math.clamp(in.opacity, 0.15, 1.0);
        const alpha: u8 = @intFromFloat(@round(255.0 * (1.0 - opacity)));
        if (alpha > 0) {
            word.dim_alpha = alpha;
            word.dim_rgb = rgb(in.fill orelse in.background);
        }
    }

    if (in.bell_border) {
        word.border = true;
        word.border_px = @intCast(std.math.clamp(geom.scale(bell_border_pt, in.dpi), 1, 127));
        word.border_rgb = rgb(in.bell_color);
    }
    return word;
}

/// The word of surface `i` of `count` in a tab: `active` is the focused
/// one, `zoomed` the zoomed one if any. Zoom leaves one visible surface,
/// which is never dimmed.
fn wordFor(
    i: usize,
    count: usize,
    active: usize,
    zoomed: ?usize,
    bell_border: bool,
    config: *const configpkg.Config,
    dpi: u32,
) Word {
    return compute(.{
        .tab_surfaces = if (zoomed != null) 1 else count,
        .focused_in_tab = i == active,
        .zoomed_other = if (zoomed) |z| z != i else false,
        .bell_border = bell_border,
        .opacity = config.@"unfocused-split-opacity",
        .fill = config.@"unfocused-split-fill",
        .background = config.background,
        .bell_color = bell_color,
        .dpi = dpi,
    });
}

/// Recompute every surface of `tab`, store the words and ask the renderers
/// of the changed ones for a frame.
pub fn refreshTab(tab: *Tab) void {
    refreshTabWith(tab, &tab.window.app.config);
}

fn refreshTabWith(tab: *Tab, config: *const configpkg.Config) void {
    var count: usize = 0;
    var active: usize = std.math.maxInt(usize);
    var zoomed: ?usize = null;
    const focused = tab.focusedSurface();
    var it = tab.tree.iterator();
    while (it.next()) |entry| : (count += 1) {
        if (focused == entry.view) active = count;
        if (tab.tree.zoomed) |z| if (z == entry.handle) {
            zoomed = count;
        };
    }

    it = tab.tree.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const s = entry.view;
        store(s, wordFor(i, count, active, zoomed, s.decor.bell_border, config, tab.window.dpi));
    }
}

fn store(s: *Surface, word: Word) void {
    const raw: u64 = @bitCast(word);
    if (s.decor_word.swap(raw, .monotonic) == raw) return;
    if (s.initialized) s.core_surface.queueRedraw();
}

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| refreshTabWith(tab, config);
    }
}

pub fn surfaceCreated(surface: *Surface) void {
    _ = surface;
}

/// `WM_SETFOCUS` / `WM_KILLFOCUS` of the surface. The dim follows the tab's
/// focused surface, which a focus-in changes before this runs, so losing
/// the focus (a deactivated window, a palette) changes nothing; a focus-in
/// ends the bell border.
pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    if (focused and surface.decor.bell_border) {
        surface.decor.bell_border = false;
        _ = win32.user32.KillTimer(surface.hwnd, messages.timers.surface.decor);
    }
    refreshTab(surface.tab);
}

/// After every relayout of the split tree and every change of the focused
/// surface.
pub fn tabLayoutChanged(tab: *Tab) void {
    refreshTab(tab);
}

/// Shows the bell border of `surface`. A focused surface drops it after a
/// second; an unfocused one keeps it until it gets the focus.
pub fn showBellBorder(surface: *Surface, focused: bool) void {
    surface.decor.bell_border = true;
    if (focused and win32.user32.SetTimer(surface.hwnd, messages.timers.surface.decor, bell_border_ms, null) == 0)
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
    refreshTab(surface.tab);
}

/// `WM_TIMER` (bell border expiry) on the surface window.
pub fn timer(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    if (wparam != messages.timers.surface.decor) return null;
    _ = win32.user32.KillTimer(surface.hwnd, messages.timers.surface.decor);
    surface.decor.bell_border = false;
    refreshTab(surface.tab);
    return 0;
}

/// The words are not reported: the scenarios read them off the frame dumps.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}

fn testConfig() configpkg.Config {
    var c: configpkg.Config = undefined;
    c.@"unfocused-split-opacity" = 0.7;
    c.@"unfocused-split-fill" = null;
    c.background = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    return c;
}

const test_input: Input = .{
    .tab_surfaces = 2,
    .focused_in_tab = false,
    .zoomed_other = false,
    .bell_border = false,
    .opacity = 0.7,
    .fill = null,
    .background = .{ .r = 0x10, .g = 0x20, .b = 0x30 },
    .bell_color = bell_color,
    .dpi = 96,
};

test "win32 decor: dims only unfocused surfaces of multi-split tabs" {
    var in = test_input;
    const dim = compute(in);
    try std.testing.expectEqual(@as(u8, 0x4D), dim.dim_alpha);
    try std.testing.expectEqual(@as(u24, 0x302010), dim.dim_rgb);
    try std.testing.expect(!dim.border);

    in.focused_in_tab = true;
    try std.testing.expect(compute(in).isZero());

    in.focused_in_tab = false;
    in.tab_surfaces = 1;
    try std.testing.expect(compute(in).isZero());

    in.tab_surfaces = 2;
    in.zoomed_other = true;
    try std.testing.expect(compute(in).isZero());
}

test "win32 decor: opacity 1 means no dim; fill defaults to background" {
    var in = test_input;
    in.opacity = 1;
    try std.testing.expect(compute(in).isZero());

    // Below the clamp the dim is at its maximum, 1 - 0.15.
    in.opacity = 0;
    try std.testing.expectEqual(@as(u8, 217), compute(in).dim_alpha);

    in.opacity = 0.5;
    in.fill = .{ .r = 0xff, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(u24, 0x0000ff), compute(in).dim_rgb);
    in.fill = null;
    try std.testing.expectEqual(@as(u24, 0x302010), compute(in).dim_rgb);
}

test "win32 decor: bell border word" {
    var in = test_input;
    in.focused_in_tab = true;
    in.bell_border = true;
    var w = compute(in);
    try std.testing.expect(w.border);
    try std.testing.expectEqual(@as(u7, 3), w.border_px);
    try std.testing.expectEqual(@as(u24, 0x00ccff), w.border_rgb);
    try std.testing.expectEqual(@as(u8, 0), w.dim_alpha);

    in.dpi = 192;
    w = compute(in);
    try std.testing.expectEqual(@as(u7, 6), w.border_px);

    // Dim and border together on an unfocused split.
    in.focused_in_tab = false;
    w = compute(in);
    try std.testing.expect(w.border and w.dim_alpha != 0);
}

test "win32 decor: window deactivation does not dim the active split" {
    // The words depend on the tab's focused surface only: a window losing
    // the activation (`surfaceFocus(active, false)`) leaves it unchanged.
    const config = testConfig();
    const before = [2]Word{ wordFor(0, 2, 0, null, false, &config, 96), wordFor(1, 2, 0, null, false, &config, 96) };
    try std.testing.expect(before[0].isZero());
    try std.testing.expect(!before[1].isZero());
    const after = [2]Word{ wordFor(0, 2, 0, null, false, &config, 96), wordFor(1, 2, 0, null, false, &config, 96) };
    try std.testing.expectEqual(before, after);
}

test "win32 decor: split insert without focus change refreshes the tab" {
    const config = testConfig();
    try std.testing.expect(wordFor(0, 1, 0, null, false, &config, 96).isZero());

    // `tabLayoutChanged` after a 1 -> 2 split: the old surface keeps the
    // focus, the new one dims.
    try std.testing.expect(wordFor(0, 2, 0, null, false, &config, 96).isZero());
    try std.testing.expect(!wordFor(1, 2, 0, null, false, &config, 96).isZero());

    // Zoom: the zoomed surface shows alone, the others are hidden.
    try std.testing.expect(wordFor(0, 2, 1, 1, false, &config, 96).isZero());
    try std.testing.expect(wordFor(1, 2, 1, 1, false, &config, 96).isZero());
}
