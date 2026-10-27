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

const Color = configpkg.Config.Color;

pub const Word = Decor.Word;

/// Per-surface state of the decorations.
pub const State = struct {
    /// The surface rang and `bell-features = border` shows it.
    bell_border: bool = false,

    /// Ends the bell border; whether there was one.
    pub fn clearBell(self: *State) bool {
        const was = self.bell_border;
        self.bell_border = false;
        return was;
    }
};

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

/// One surface of a tab, as `refresh` sees it.
const Entry = struct {
    /// It is the tab's focused surface.
    focused: bool,
    /// It is the zoomed surface.
    zoomed: bool,
    bell_border: bool,
    word: *std.atomic.Value(u64),
    /// Asked for a frame when its word changed; null in tests.
    surface: ?*Surface = null,
};

/// Computes and stores the word of every entry of a tab of `count`
/// surfaces, `it` yielding them. Zoom leaves one visible surface, which is
/// never dimmed. A changed word asks the renderer for a frame.
fn refresh(
    it: anytype,
    count: usize,
    any_zoomed: bool,
    config: *const configpkg.Config,
    dpi: u32,
) void {
    var iter = it;
    while (iter.next()) |e| {
        const word = compute(.{
            .tab_surfaces = if (any_zoomed) 1 else count,
            .focused_in_tab = e.focused,
            .zoomed_other = any_zoomed and !e.zoomed,
            .bell_border = e.bell_border,
            .opacity = config.@"unfocused-split-opacity",
            .fill = config.@"unfocused-split-fill",
            .background = config.background,
            .bell_color = bell_color,
            .dpi = dpi,
        });
        const raw: u64 = @bitCast(word);
        if (e.word.swap(raw, .monotonic) == raw) continue;
        if (e.surface) |s| if (s.initialized) s.core_surface.queueRedraw();
    }
}

/// The entries of a tab's split tree.
const TabEntries = struct {
    it: Surface.Tree.Iterator,
    focused: ?*Surface,
    zoomed: ?Surface.Tree.Node.Handle,

    fn next(self: *TabEntries) ?Entry {
        const e = self.it.next() orelse return null;
        return .{
            .focused = self.focused == e.view,
            .zoomed = if (self.zoomed) |z| z == e.handle else false,
            .bell_border = e.view.decor.bell_border,
            .word = &e.view.decor_word,
            .surface = e.view,
        };
    }
};

/// Recompute every surface of `tab`, store the words and ask the renderers
/// of the changed ones for a frame.
pub fn refreshTab(tab: *Tab) void {
    refreshTabWith(tab, &tab.window.app.config);
}

fn refreshTabWith(tab: *Tab, config: *const configpkg.Config) void {
    var count: usize = 0;
    var counter = tab.tree.iterator();
    while (counter.next()) |_| count += 1;

    refresh(TabEntries{
        .it = tab.tree.iterator(),
        .focused = tab.focusedSurface(),
        .zoomed = tab.tree.zoomed,
    }, count, tab.tree.zoomed != null, config, tab.window.dpi);
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
/// focused surface, which `Surface.handleFocus` already refreshed through
/// `tabLayoutChanged`, so only a focus-in that ends the bell border needs a
/// refresh of its own.
pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    if (focused and surface.decor.clearBell()) refreshTab(surface.tab);
}

/// A key press on the surface ends the bell border (macOS does the same).
/// One flag test on the key path.
pub fn keyDown(surface: *Surface) void {
    if (surface.decor.bell_border and surface.decor.clearBell()) refreshTab(surface.tab);
}

/// After every relayout of the split tree and every change of the focused
/// surface.
pub fn tabLayoutChanged(tab: *Tab) void {
    refreshTab(tab);
}

/// Shows the bell border of `surface` until a key press or the focus.
pub fn showBellBorder(surface: *Surface) void {
    surface.decor.bell_border = true;
    refreshTab(surface.tab);
}

/// The words are not reported: the scenarios read them off the frame dumps.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
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

fn testConfig() configpkg.Config {
    var c: configpkg.Config = undefined;
    c.@"unfocused-split-opacity" = 0.7;
    c.@"unfocused-split-fill" = null;
    c.background = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    return c;
}

/// Entries over a slice, for `refresh`.
const SliceEntries = struct {
    items: []const Entry,
    i: usize = 0,

    fn next(self: *SliceEntries) ?Entry {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn entry(word: *std.atomic.Value(u64), focused: bool) Entry {
    return .{ .focused = focused, .zoomed = false, .bell_border = false, .word = word };
}

fn load(word: *const std.atomic.Value(u64)) Word {
    return @bitCast(word.load(.monotonic));
}

test "win32 decor: window deactivation does not dim the active split" {
    // `surfaceFocus(active, false)` changes nothing: the refresh follows
    // the tab's focused surface, which a deactivated window keeps.
    const config = testConfig();
    var a: std.atomic.Value(u64) = .init(0);
    var b: std.atomic.Value(u64) = .init(0);
    const entries = [_]Entry{ entry(&a, true), entry(&b, false) };
    refresh(SliceEntries{ .items = &entries }, 2, false, &config, 96);
    try std.testing.expect(load(&a).isZero());
    try std.testing.expect(!load(&b).isZero());

    // A focus-out never clears a bell border, so it asks for no refresh.
    var state: State = .{};
    try std.testing.expect(!state.clearBell());
    refresh(SliceEntries{ .items = &entries }, 2, false, &config, 96);
    try std.testing.expect(load(&a).isZero());
}

test "win32 decor: split insert without focus change refreshes the tab" {
    const config = testConfig();
    var a: std.atomic.Value(u64) = .init(0);
    var b: std.atomic.Value(u64) = .init(0);

    const one = [_]Entry{entry(&a, true)};
    refresh(SliceEntries{ .items = &one }, 1, false, &config, 96);
    try std.testing.expect(load(&a).isZero());

    // `tabLayoutChanged` after the 1 -> 2 split: the old surface keeps the
    // focus, the new one dims.
    const two = [_]Entry{ entry(&a, true), entry(&b, false) };
    refresh(SliceEntries{ .items = &two }, 2, false, &config, 96);
    try std.testing.expect(load(&a).isZero());
    try std.testing.expectEqual(@as(u8, 0x4D), load(&b).dim_alpha);

    // Zoom the first: neither is dimmed.
    var zoomed = two;
    zoomed[0].zoomed = true;
    refresh(SliceEntries{ .items = &zoomed }, 2, true, &config, 96);
    try std.testing.expect(load(&a).isZero());
    try std.testing.expect(load(&b).isZero());
}

test "win32 decor: a bell border is cleared once" {
    var state: State = .{ .bell_border = true };
    try std.testing.expect(state.clearBell());
    try std.testing.expect(!state.bell_border);
    try std.testing.expect(!state.clearBell());
}
