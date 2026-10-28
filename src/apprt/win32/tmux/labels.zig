//! tmux pane border labels (owner: M4 task 13, SPEC section 12.2).
//!
//! A pane gets a pill in its top-right (`pane-border-status top`) or
//! bottom-right (`bottom`) corner showing the expanded `pane-border-format`
//! with its `#[...]` runs stripped. The first `fg=` of the format (else of
//! `pane-border-style`) colours the text. The pill is a click-through
//! overlay label popup, so the overlay host moves it with the pane, hides it
//! with a hidden tab and re-owns it when the tab changes window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../Window.zig");
const hooks = @import("../hooks.zig");
const badges = @import("../badges.zig");
const Chrome = @import("../Chrome.zig");
const geom = @import("../geom.zig");
const overlay = @import("../overlay.zig");
const theme = @import("../theme.zig");
const commands = @import("commands.zig");
const format = @import("../../../tmux_shim/format.zig");
const color = @import("../../../terminal/color.zig");
const win32 = @import("win32");

const log = std.log.scoped(.win32_tmux_labels);

/// Sizes at 96 dpi, the M3 label metrics (`badges.zig`): 5 px padding, a
/// 26 px line.
const pad_x = 5;
const height_px = 26;
const radius_px = 4;
const margin_px = 4;
const text_cap = 128;

/// `App.tmux_labels`.
pub const State = struct {
    /// Where the options live: `Registry.State` hands its `Options` over
    /// with `attachOptions`. Null: no tmux window has any option.
    options: ?*const commands.Options = null,
    labels: std.ArrayList(*Label) = .empty,
};

const Label = struct {
    popup: overlay.Popup,
    surface: *Surface,
    text16: [text_cap]u16 = undefined,
    text16_len: usize = 0,
    text8: [text_cap * 3]u8 = undefined,
    text8_len: usize = 0,
    ink: ?color.RGB = null,

    fn text8Slice(self: *const Label) []const u8 {
        return self.text8[0..self.text8_len];
    }
};

// ---- pure part -------------------------------------------------------

pub const Placement = enum { top, bottom };

/// The placement for the window option `pane-border-status`.
pub fn placementOf(status: ?[]const u8) ?Placement {
    const s = status orelse return null;
    if (std.mem.eql(u8, s, "top")) return .top;
    if (std.mem.eql(u8, s, "bottom")) return .bottom;
    return null;
}

/// Where the label of a pane `cols` cells wide goes; null when it is hidden:
/// the status is off, the text is empty, or the pane is narrower than the
/// label plus two cells.
pub fn visibleAs(status: ?[]const u8, text: []const u8, cols: u32) ?Placement {
    const placement = placementOf(status) orelse return null;
    if (text.len == 0) return null;
    const cells = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (cols < cells + 2) return null;
    return placement;
}

/// `s` without its `#[...]` runs, trimmed.
pub fn stripStyles(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '#' and i + 1 < s.len and s[i + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i + 2, ']')) |end| {
                i = end + 1;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \t");
}

/// The value of the first `fg=` token of a style ("fg=red,bold" or
/// "fg=red bold").
fn fgOfStyle(style: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, style, ", \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "fg=")) return tok[3..];
    }
    return null;
}

/// The first `fg=` of the `#[...]` runs of `s`.
pub fn firstFg(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "#[")) |start| {
        const end = std.mem.indexOfScalarPos(u8, s, start + 2, ']') orelse return null;
        if (fgOfStyle(s[start + 2 .. end])) |v| return v;
        i = end + 1;
    }
    return null;
}

const ansi_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

/// A tmux colour: a name (`red`, `brightred`), `colourN` / `colorN`, or
/// `#rrggbb`; palette entries come from the terminal palette. `default` and
/// unknown names give null.
pub fn parseColour(name: []const u8, palette: *const color.Palette) ?color.RGB {
    if (name.len == 7 and name[0] == '#') {
        const v = std.fmt.parseInt(u24, name[1..], 16) catch return null;
        return .{ .r = @intCast(v >> 16), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
    }
    inline for (.{ "colour", "color" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            const n = std.fmt.parseInt(u16, name[prefix.len..], 10) catch return null;
            return if (n < 256) palette[n] else null;
        }
    }
    var base = name;
    var bright: usize = 0;
    if (std.mem.startsWith(u8, name, "bright")) {
        base = name["bright".len..];
        bright = 8;
    }
    for (ansi_names, 0..) |n, i| {
        if (std.mem.eql(u8, base, n)) return palette[i + bright];
    }
    return null;
}

pub const Spec = struct {
    text: []const u8,
    ink: ?color.RGB,
};

/// What the label shows and in which colour, from an expanded format.
pub fn specFor(
    arena: Allocator,
    expanded: []const u8,
    style: ?[]const u8,
    palette: *const color.Palette,
) Allocator.Error!Spec {
    const fg = firstFg(expanded) orelse (if (style) |s| fgOfStyle(s) else null);
    return .{
        .text = try stripStyles(arena, expanded),
        .ink = if (fg) |v| parseColour(v, palette) else null,
    };
}

/// Format variables of one pane.
const Ctx = struct {
    arena: Allocator,
    options: *const commands.Options,
    pane_id: u32,
    window_id: u32,
    pane_index: usize,
    pane_active: bool,
    pane_title: []const u8,
    window_index: usize,
    window_name: []const u8,
    cols: u32,
    rows: u32,

    pub fn lookup(self: *const Ctx, name: []const u8) ?[]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, name, "pane_id")) return self.print("%{d}", .{self.pane_id});
        if (eql(u8, name, "window_id")) return self.print("@{d}", .{self.window_id});
        if (eql(u8, name, "pane_index")) return self.print("{d}", .{self.pane_index});
        if (eql(u8, name, "pane_title")) return self.pane_title;
        if (eql(u8, name, "pane_active")) return if (self.pane_active) "1" else "0";
        if (eql(u8, name, "window_index")) return self.print("{d}", .{self.window_index});
        if (eql(u8, name, "window_name")) return self.window_name;
        if (eql(u8, name, "pane_width")) return self.print("{d}", .{self.cols});
        if (eql(u8, name, "pane_height")) return self.print("{d}", .{self.rows});
        if (eql(u8, name, "session_name")) return "0";
        return self.options.lookup(self.pane_id, self.window_id, name);
    }

    fn print(self: *const Ctx, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch null;
    }
};

fn expandFormat(arena: Allocator, fmt: []const u8, ctx: *const Ctx) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    format.expand(&aw.writer, fmt, ctx) catch return error.OutOfMemory;
    return aw.written();
}

// ---- glue ------------------------------------------------------------

/// Called by the registry once its options exist (and again if they move).
pub fn attachOptions(app: *App, options: *const commands.Options) void {
    app.tmux_labels.options = options;
    refreshApp(app);
}

pub fn optionsChanged(app: *App, window_id: u32) void {
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            if (tab.id == window_id) refreshTab(tab);
        }
    }
}

pub fn tabLayoutChanged(tab: *Tab) void {
    refreshTab(tab);
}

pub fn tabShown(tab: *Tab, shown: bool) void {
    // The overlay host hides and shows the popups; the text may be stale.
    if (shown) refreshTab(tab);
}

pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    _ = from;
    _ = to;
    // The overlay host re-owned the popups; the pane geometry changed.
    refreshTab(tab);
}

pub fn windowChanged(window: *Window, change: hooks.WindowChange) void {
    // A new DPI changes the text width.
    if (change != .dpi) return;
    for (window.tabs.items) |tab| refreshTab(tab);
}

pub fn surfaceDestroying(surface: *Surface) void {
    const app = surface.app;
    const state = &app.tmux_labels;
    var i: usize = 0;
    while (i < state.labels.items.len) {
        const label = state.labels.items[i];
        if (label.surface != surface) {
            i += 1;
            continue;
        }
        _ = state.labels.swapRemove(i);
        label.popup.destroy();
        app.core_app.alloc.destroy(label);
    }
    if (state.labels.items.len == 0) {
        state.labels.deinit(app.core_app.alloc);
        state.labels = .empty;
    }
}

fn refreshApp(app: *App) void {
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| refreshTab(tab);
    }
}

fn refreshTab(tab: *Tab) void {
    const app = tab.window.app;
    if (app.tmux_labels.options == null) return;
    var index: usize = 0;
    var it = tab.tree.iterator();
    while (it.next()) |entry| : (index += 1) {
        refreshSurface(app, tab, entry.view, index);
    }
}

fn labelOf(state: *State, surface: *const Surface) ?*Label {
    for (state.labels.items) |l| if (l.surface == surface) return l;
    return null;
}

fn refreshSurface(app: *App, tab: *Tab, surface: *Surface, pane_index: usize) void {
    const state = &app.tmux_labels;
    const options = state.options orelse return;
    const alloc = app.core_app.alloc;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const window_id = tab.id;
    const pane_id = surface.pane_id;
    const status = options.lookup(pane_id, window_id, "pane-border-status");
    const fmt = options.lookup(pane_id, window_id, "pane-border-format") orelse "";
    var cols: u32 = 0;
    var rows: u32 = 0;
    if (surface.initialized) {
        const grid = surface.core_surface.size.grid();
        cols = grid.columns;
        rows = grid.rows;
    }

    var spec: Spec = .{ .text = "", .ink = null };
    if (placementOf(status) != null and fmt.len > 0) {
        const ctx: Ctx = .{
            .arena = arena,
            .options = options,
            .pane_id = pane_id,
            .window_id = window_id,
            .pane_index = pane_index,
            .pane_active = tab.focusedSurface() == surface,
            .pane_title = surface.getTitle() orelse "",
            .window_index = tab.window.tabIndex(tab) orelse 0,
            .window_name = tab.title(),
            .cols = cols,
            .rows = rows,
        };
        const expanded = expandFormat(arena, fmt, &ctx) catch return;
        spec = specFor(arena, expanded, options.lookup(pane_id, window_id, "pane-border-style"), &app.config.palette.value) catch return;
    }

    const placement = visibleAs(status, spec.text, cols) orelse {
        if (labelOf(state, surface)) |l| l.popup.hide();
        return;
    };
    const label = labelOf(state, surface) orelse (create(app, tab, surface) orelse return);

    const anchor: overlay.Anchor = switch (placement) {
        .top => .surface_top_right,
        .bottom => .surface_bottom_right,
    };
    const same = label.popup.visible and label.popup.anchor == anchor and
        std.mem.eql(u8, label.text8Slice(), spec.text) and
        std.meta.eql(label.ink, spec.ink);
    if (same) return;

    label.popup.anchor = anchor;
    label.ink = spec.ink;
    setText(label, spec.text);
    label.popup.size = .{ .w = widthOf(label, tab.window.dpi), .h = height_px };
    label.popup.show() catch |err| log.warn("unable to show a pane label err={}", .{err});
}

fn create(app: *App, tab: *Tab, surface: *Surface) ?*Label {
    const alloc = app.core_app.alloc;
    const label = alloc.create(Label) catch return null;
    label.* = .{
        .surface = surface,
        .popup = .{
            .kind = .label,
            .anchor = .surface_top_right,
            .window = surface.window,
            .surface = surface,
            .size = .{ .w = 0, .h = height_px },
            .margin = margin_px,
            .paint = paint,
            // A new popup of a hidden tab starts hidden.
            .tab_hidden = tab.window.activeTab() != tab,
        },
    };
    label.popup.ctx = label;
    app.tmux_labels.labels.append(alloc, label) catch {
        alloc.destroy(label);
        return null;
    };
    return label;
}

fn setText(label: *Label, utf8: []const u8) void {
    // Whole code points up to the cap.
    var n8: usize = 0;
    var n16: usize = 0;
    var view = std.unicode.Utf8View.init(utf8) catch {
        label.text8_len = 0;
        label.text16_len = 0;
        return;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_slice| {
        const cp = std.unicode.utf8Decode(cp_slice) catch break;
        const need: usize = if (cp >= 0x10000) 2 else 1;
        if (n16 + need > label.text16.len or n8 + cp_slice.len > label.text8.len) break;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            label.text16[n16] = @intCast(0xD800 + (v >> 10));
            label.text16[n16 + 1] = @intCast(0xDC00 + (v & 0x3FF));
        } else {
            label.text16[n16] = @intCast(cp);
        }
        n16 += need;
        @memcpy(label.text8[n8..][0..cp_slice.len], cp_slice);
        n8 += cp_slice.len;
    }
    label.text16_len = n16;
    label.text8_len = n8;
}

/// Logical width of the pill.
fn widthOf(label: *const Label, dpi: u32) i32 {
    const text = label.text16[0..label.text16_len];
    const px = Chrome.measureLabel(text, dpi) catch @divTrunc(@as(i32, @intCast(text.len)) * 8 * @as(i32, @intCast(dpi)), 96);
    return badges.logical(px, dpi) + 2 * pad_x + 1;
}

fn paint(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const label: *const Label = @ptrCast(@alignCast(p.ctx orelse return));
    const fill = badges.materialFill(ctx.palette.dark);
    const ink: theme.Color = if (label.ink) |c|
        .{ .r = c.r, .g = c.g, .b = c.b }
    else
        badges.primaryInk(ctx.palette.dark);
    const items = [_]Chrome.Item{
        .{ .box = .{ .rect = ctx.rect, .radius = geom.scale(radius_px, ctx.dpi), .fill = fill } },
        .{ .text = .{ .rect = ctx.rect, .text = label.text16[0..label.text16_len], .color = ink, .trim = true } },
    };
    Chrome.paintItems(ctx.hdc, ctx.rect, &items, ctx.palette, ctx.dpi, null) catch |err| {
        log.warn("unable to paint a pane label err={}", .{err});
    };
}

/// The `labels` array of the `tmux` object of the IPC `state` op: every
/// label with its text, colour, visibility and screen rectangle, and the
/// screen rectangle of its pane.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginArray();
    for (app.tmux_labels.labels.items) |label| {
        const hwnd = label.popup.hwnd;
        var rc: win32.foundation.RECT = std.mem.zeroes(win32.foundation.RECT);
        var pane_rc: win32.foundation.RECT = std.mem.zeroes(win32.foundation.RECT);
        _ = win32.user32.GetWindowRect(label.surface.hwnd, &pane_rc);
        const visible = if (hwnd) |h| win32.user32.IsWindowVisible(h) != 0 else false;
        if (hwnd) |h| _ = win32.user32.GetWindowRect(h, &rc);
        try jw.beginObject();
        try jw.objectField("pane");
        try jw.print("\"%{d}\"", .{label.surface.pane_id});
        try jw.objectField("text");
        try jw.write(label.text8Slice());
        try jw.objectField("ink");
        if (label.ink) |c| try jw.print("\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ c.r, c.g, c.b }) else try jw.write(null);
        try jw.objectField("anchor");
        try jw.write(@tagName(label.popup.anchor));
        try jw.objectField("visible");
        try jw.write(visible);
        try jw.objectField("rect");
        try jw.write([4]i32{ rc.left, rc.top, rc.right, rc.bottom });
        try jw.objectField("pane_rect");
        try jw.write([4]i32{ pane_rc.left, pane_rc.top, pane_rc.right, pane_rc.bottom });
        try jw.endObject();
    }
    try jw.endArray();
}

// ---- tests -----------------------------------------------------------

test "win32 tmux labels: text and colour from Claude's border format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const spec = try specFor(a, "#[fg=red,bold] alpha #[default]", null, &color.default);
    try std.testing.expectEqualStrings("alpha", spec.text);
    try std.testing.expectEqual(color.default[1], spec.ink.?);

    // Through the real expansion of Claude's format.
    var options: commands.Options = .{};
    const ctx: Ctx = .{
        .arena = a,
        .options = &options,
        .pane_id = 3,
        .window_id = 1,
        .pane_index = 0,
        .pane_active = true,
        .pane_title = "alpha",
        .window_index = 0,
        .window_name = "w",
        .cols = 80,
        .rows = 24,
    };
    const expanded = try expandFormat(a, "#[fg=blue,bold] #{pane_title} #[default]", &ctx);
    const s2 = try specFor(a, expanded, null, &color.default);
    try std.testing.expectEqualStrings("alpha", s2.text);
    try std.testing.expectEqual(color.default[4], s2.ink.?);

    // The style option colours a format without its own fg.
    const s3 = try specFor(a, "beta", "fg=green", &color.default);
    try std.testing.expectEqualStrings("beta", s3.text);
    try std.testing.expectEqual(color.default[2], s3.ink.?);
}

test "win32 tmux labels: colour208 and default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const orange = try specFor(a, "#[fg=colour208]x", null, &color.default);
    try std.testing.expectEqual(color.default[208], orange.ink.?);
    const bright = try specFor(a, "#[fg=brightred]x", null, &color.default);
    try std.testing.expectEqual(color.default[9], bright.ink.?);
    const hex = try specFor(a, "#[fg=#102030]x", null, &color.default);
    try std.testing.expectEqual(@as(u8, 0x20), hex.ink.?.g);
    // `default` (and an unknown name) is no colour, even with a style option.
    const def = try specFor(a, "#[fg=default]x", "fg=red", &color.default);
    try std.testing.expect(def.ink == null);
    const unknown = try specFor(a, "#[fg=nope]x", null, &color.default);
    try std.testing.expect(unknown.ink == null);
    try std.testing.expect(parseColour("colour999", &color.default) == null);
    // No fg anywhere.
    const plain = try specFor(a, "#[bold]x#[default]", null, &color.default);
    try std.testing.expectEqualStrings("x", plain.text);
    try std.testing.expect(plain.ink == null);
}

test "win32 tmux labels: hidden when status off or pane too narrow" {
    try std.testing.expectEqual(Placement.top, visibleAs("top", "alpha", 40).?);
    try std.testing.expectEqual(Placement.bottom, visibleAs("bottom", "alpha", 40).?);
    try std.testing.expect(visibleAs("off", "alpha", 40) == null);
    try std.testing.expect(visibleAs(null, "alpha", 40) == null);
    try std.testing.expect(visibleAs("top", "", 40) == null);
    // label + 2 cells: "alpha" is 5.
    try std.testing.expect(visibleAs("top", "alpha", 7) != null);
    try std.testing.expect(visibleAs("top", "alpha", 6) == null);
    // Cells, not bytes.
    try std.testing.expect(visibleAs("top", "\xd0\xb0\xd0\xb1", 4) != null);
}
