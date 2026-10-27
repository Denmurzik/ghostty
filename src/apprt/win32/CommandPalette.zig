//! The command palette: a panel popup of the overlay host with an EDIT and a
//! list of the `command-palette-entry` commands of the config, filtered by
//! `palette_filter`. Sizes, fonts and colours follow `CommandPaletteView` of
//! the macOS app.
//!
//! The entries are copied when the palette opens, so a config reload cannot
//! free what the open palette shows. Running a command does not happen in
//! the EDIT's key handler: Enter posts `WM_GHOSTTY_OVERLAY_CMD` with a deep
//! copy of the action, and the handler closes the palette, gives the focus
//! back to the target surface and performs the action there (when that
//! surface is still alive).
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const filter = @import("palette_filter.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");

const user32 = win32.user32;
const gdi32 = win32.gdi32;
const comctl32 = win32.comctl32;
const uxtheme = win32.uxtheme;
const HWND = win32.foundation.HWND;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_palette);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const WM_SETFONT = 0x0030;
const EM_SETCUEBANNER = 0x1501;
const DEFAULT_CHARSET = 1;
const CLEARTYPE_QUALITY = 5;
const FW_LIGHT = 300;
const FW_NORMAL = 400;
const FW_BOLD = 700;
const COLOR_HIGHLIGHT = 13;
const MA_NOACTIVATE = 3;
const subclass_id = 1;

extern "gdi32" fn SetTextColor(user32.HDC, u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(user32.HDC, u32) callconv(.winapi) u32;

// -- State -------------------------------------------------------------------------

/// Per top-level window: the open palette, if any.
pub const State = struct {
    popup: ?*overlay.Popup = null,
    edit: ?HWND = null,
    /// The surface that was focused when the palette opened. An id, not a
    /// pointer: it is resolved through the window when a command runs, and
    /// a surface that is gone is a no-op.
    target_id: ?u32 = null,
    /// `Item` positions of the entries that match the query, best first.
    rows: []usize = &.{},
    sel: usize = 0,
    /// The first row shown.
    scroll: usize = 0,
};

/// One entry of the list; the text lives in the panel's arena.
const Item = struct {
    title: []const u8,
    description: []const u8,
    /// "Ctrl+Shift+P", empty when the action has no binding.
    shortcut: []const u8,
    action: input.Binding.Action,
};

/// What the heap block of an open palette holds; `popup` is its first field.
const Panel = struct {
    popup: overlay.Popup,
    /// Tells a posted close of this palette from one of an earlier palette.
    serial: u32,
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    entries: []filter.Entry = &.{},
    /// The query as typed, trimmed.
    query: std.ArrayList(u8) = .empty,
    /// Set while the palette closes itself: losing the focus is expected.
    closing: bool = false,
    font: ?gdi32.HFONT = null,
    bold_font: ?gdi32.HFONT = null,
    small_font: ?gdi32.HFONT = null,
    query_font: ?gdi32.HFONT = null,
    font_dpi: u32 = 0,
    brush: ?user32.HBRUSH = null,
    brush_rgb: u32 = 0,
    dark_applied: ?bool = null,
    hover: ?usize = null,
    pressed: ?usize = null,
    tracking: bool = false,

    fn of(p: *overlay.Popup) *Panel {
        return @fieldParentPtr("popup", p);
    }
};

var next_serial: u32 = 0;

/// What `WM_GHOSTTY_OVERLAY_CMD` carries to a window. It owns its memory
/// (the action is a copy, not a view of the config) and the handler frees it.
pub const Command = struct {
    arena: std.heap.ArenaAllocator,
    kind: union(enum) {
        /// Closes the palette `serial` if it is still the open one.
        close: u32,
        /// Closes the palette and runs `action` on the surface `target_id`.
        execute: struct { serial: u32, target_id: u32, action: input.Binding.Action },
    },

    fn create(alloc: Allocator, kind: enum { close, execute }, serial: u32, target_id: u32, action: ?input.Binding.Action) !*Command {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const cmd = try arena.allocator().create(Command);
        cmd.arena = arena;
        cmd.kind = switch (kind) {
            .close => .{ .close = serial },
            .execute => .{ .execute = .{
                .serial = serial,
                .target_id = target_id,
                .action = try action.?.clone(cmd.arena.allocator()),
            } },
        };
        return cmd;
    }

    fn destroy(cmd: *Command) void {
        // The block lives in its own arena.
        var arena = cmd.arena;
        arena.deinit();
    }
};

// -- Layout ------------------------------------------------------------------------

/// Sizes at 96 dpi, from `CommandPaletteView`: a 48 pt query field, a
/// divider, rows of 8 pt padding in a list with a 10 pt margin and 4 pt gaps.
/// The width and the 12 rows are the plan's (macOS stops at 500 pt wide and
/// 200 pt of rows).
const max_w = 600;
const query_h = 48;
const query_inset = 16;
const edit_h = 28;
const list_pad = 10;
const row_h = 40;
const row_gap = 4;
const row_pad = 8;
const row_radius = 5;
const max_rows = 12;
const empty_h = 49;
const margin = 16;
const radius = 10;

/// The height of the popup at 96 dpi for `n` rows shown.
pub fn panelHeight(n: usize) i32 {
    const rows: i32 = @intCast(n);
    const list = if (n == 0) empty_h else 2 * list_pad + rows * row_h + (rows - 1) * row_gap;
    return query_h + 1 + list;
}

/// How many rows fit: at most `max_rows`, and no more than a window of
/// `client_h` (DIP) leaves room for.
pub fn visibleCount(total: usize, client_h: i32) usize {
    const room = client_h - 2 * margin - query_h - 1 - 2 * list_pad;
    const fit: i32 = @max(@divTrunc(room + row_gap, row_h + row_gap), 1);
    return @min(total, @min(@as(usize, max_rows), @as(usize, @intCast(fit))));
}

/// The `scroll` that keeps `sel` among the `visible` rows from it.
pub fn scrollFor(scroll: usize, sel: usize, visible: usize, total: usize) usize {
    if (visible == 0) return 0;
    var s = scroll;
    if (sel < s) s = sel;
    if (sel >= s + visible) s = sel + 1 - visible;
    return @min(s, total -| visible);
}

/// Up (`-1`) or down (`+1`) from `sel`, wrapping, as on macOS.
pub fn moveSel(sel: usize, total: usize, delta: i32) usize {
    if (total == 0) return 0;
    if (delta < 0) return if (sel == 0) total - 1 else sel - 1;
    return if (sel + 1 >= total) 0 else sel + 1;
}

/// A page up or down stops at the ends.
pub fn pageSel(sel: usize, total: usize, visible: usize, down: bool) usize {
    if (total == 0) return 0;
    const step = @max(visible, 1);
    return if (down) @min(sel + step, total - 1) else sel -| step;
}

const Geometry = struct {
    edit: geom.Rect,
    divider_y: i32,
    list_top: i32,

    fn forWidth(w: i32, dpi: u32) Geometry {
        const s = geom.scale;
        return .{
            .edit = .{
                .x = s(query_inset, dpi),
                .y = @divTrunc(s(query_h, dpi) - s(edit_h, dpi), 2),
                .w = w - 2 * s(query_inset, dpi),
                .h = s(edit_h, dpi),
            },
            .divider_y = s(query_h, dpi),
            .list_top = s(query_h, dpi) + 1,
        };
    }

    fn row(g: Geometry, w: i32, dpi: u32, i: usize) geom.Rect {
        const s = geom.scale;
        const pitch = s(row_h, dpi) + s(row_gap, dpi);
        return .{
            .x = s(list_pad, dpi),
            .y = g.list_top + s(list_pad, dpi) + @as(i32, @intCast(i)) * pitch,
            .w = w - 2 * s(list_pad, dpi),
            .h = s(row_h, dpi),
        };
    }

    /// The index among the shown rows under `(x, y)`.
    fn rowAt(g: Geometry, w: i32, dpi: u32, shown: usize, x: i32, y: i32) ?usize {
        for (0..shown) |i| {
            if (g.row(w, dpi, i).contains(x, y)) return i;
        }
        return null;
    }
};

// -- Colours -----------------------------------------------------------------------

pub const Colors = struct {
    bg: theme.Color,
    text: theme.Color,
    secondary: theme.Color,
    accent: theme.Color,
    border: theme.Color,
    divider: theme.Color,
    selected: theme.Color,
    hover: theme.Color,
};

fn mix(a: theme.Color, b: theme.Color, t: f32) theme.Color {
    const f = struct {
        fn c(x: u8, y: u8, k: f32) u8 {
            const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
            return @intFromFloat(@round(v));
        }
    }.c;
    return .{ .r = f(a.r, b.r, t), .g = f(a.g, b.g, t), .b = f(a.b, b.b, t) };
}

/// The terminal background with the text colour its brightness calls for;
/// the macOS view blends a material with the same colour. The selection is
/// the accent at 0.2 opacity, the hover the secondary colour at 0.2.
pub fn colors(background: theme.Color, accent: theme.Color, high_contrast: ?theme.Palette) Colors {
    var bg = background;
    var text: theme.Color = undefined;
    if (high_contrast) |pal| {
        bg = pal.tab_active_bg;
        text = pal.text;
    } else {
        const lum = 0.299 * @as(f32, @floatFromInt(bg.r)) / 255 +
            0.587 * @as(f32, @floatFromInt(bg.g)) / 255 +
            0.114 * @as(f32, @floatFromInt(bg.b)) / 255;
        text = if (lum < 0.5) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } else .{ .r = 0, .g = 0, .b = 0 };
    }
    const secondary = mix(bg, text, 0.6);
    return .{
        .bg = bg,
        .text = text,
        .secondary = secondary,
        .accent = accent,
        .border = mix(bg, text, 0.25),
        .divider = mix(bg, text, 0.15),
        .selected = mix(bg, accent, 0.2),
        .hover = mix(bg, secondary, 0.2),
    };
}

fn colorRef(c: theme.Color) u32 {
    return @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
}

fn currentColors(window: *const Window) Colors {
    const cfg = window.app.config.background;
    const sys = user32.GetSysColor(COLOR_HIGHLIGHT);
    const accent: theme.Color = .{ .r = @truncate(sys), .g = @truncate(sys >> 8), .b = @truncate(sys >> 16) };
    return colors(
        .{ .r = cfg.r, .g = cfg.g, .b = cfg.b },
        accent,
        if (theme.highContrast()) theme.palette(window) else null,
    );
}

// -- Entries -----------------------------------------------------------------------

/// "Ctrl+Shift+P" for a trigger; the key names of the config in words.
pub fn shortcutText(buf: []u8, trigger: input.Binding.Trigger) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    shortcutWrite(&w, trigger) catch return "";
    return w.buffered();
}

fn shortcutWrite(w: *std.Io.Writer, trigger: input.Binding.Trigger) !void {
    if (trigger.mods.super) try w.writeAll("Win+");
    if (trigger.mods.ctrl) try w.writeAll("Ctrl+");
    if (trigger.mods.alt) try w.writeAll("Alt+");
    if (trigger.mods.shift) try w.writeAll("Shift+");
    switch (trigger.key) {
        .physical => |k| try keyName(w, @tagName(k)),
        .unicode => |c| {
            var up = c;
            if (c < 0x80) up = std.ascii.toUpper(@intCast(c));
            try w.print("{u}", .{up});
        },
        .catch_all => try w.writeAll("Any"),
    }
}

/// `key_a` is "A", `digit_1` "1", `arrow_up` "Up", `page_down` "Page Down".
fn keyName(w: *std.Io.Writer, tag: []const u8) !void {
    var name = tag;
    for ([_][]const u8{ "key_", "digit_", "arrow_" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) name = name[prefix.len..];
    }
    var word_start = true;
    for (name) |c| {
        if (c == '_') {
            try w.writeByte(' ');
            word_start = true;
            continue;
        }
        try w.writeByte(if (word_start) std.ascii.toUpper(c) else c);
        word_start = false;
    }
}

/// Alphabetical by title, as the GTK palette sorts: ASCII case folded, ":"
/// before everything so that "Foo:" comes before "Foo Bar:".
fn titleLess(a: []const u8, b: []const u8) bool {
    for (0..@min(a.len, b.len)) |i| {
        const ca = std.ascii.toLower(if (a[i] == ':') '\t' else a[i]);
        const cb = std.ascii.toLower(if (b[i] == ':') '\t' else b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

/// Actions the apprt does not run (yet).
fn supported(action: input.Binding.Action) bool {
    return switch (action) {
        .toggle_secure_input,
        .check_for_updates,
        .undo,
        .redo,
        => false,
        else => true,
    };
}

fn itemLess(_: void, a: Item, b: Item) bool {
    return titleLess(a.title, b.title);
}

// -- Open and close ----------------------------------------------------------------

/// Builds the panel of a palette for `target_id` from `commands` (copied;
/// `keybinds` gives the shortcut texts) and registers it with the window.
/// Nothing is shown yet.
fn begin(
    window: *Window,
    target_id: u32,
    commands: []const input.Command,
    keybinds: ?*const input.Binding.Set,
) !*Panel {
    const alloc = window.app.core_app.alloc;
    const state = &window.palette;
    std.debug.assert(state.popup == null);

    const panel = try alloc.create(Panel);
    errdefer alloc.destroy(panel);
    next_serial +%= 1;
    panel.* = .{
        .popup = .{
            .kind = .panel,
            .anchor = .window_top_center,
            .window = window,
            .size = .{ .w = max_w, .h = panelHeight(0) },
            .margin = margin,
            .paint = paintPopup,
            .on_message = onMessage,
            .place = place,
        },
        .serial = next_serial,
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    errdefer panel.arena.deinit();
    const a = panel.arena.allocator();

    var items: std.ArrayList(Item) = .empty;
    for (commands) |entry| {
        if (!supported(entry.action)) continue;
        const shortcut: []const u8 = blk: {
            const set = keybinds orelse break :blk "";
            const trigger = set.getTrigger(entry.action) orelse break :blk "";
            var buf: [64]u8 = undefined;
            break :blk try a.dupe(u8, shortcutText(&buf, trigger));
        };
        try items.append(a, .{
            .title = try a.dupe(u8, entry.title),
            .description = try a.dupe(u8, entry.description),
            .shortcut = shortcut,
            .action = try entry.action.clone(a),
        });
    }
    std.mem.sort(Item, items.items, {}, itemLess);
    panel.items = items.items;

    const entries = try a.alloc(filter.Entry, panel.items.len);
    for (panel.items, entries, 0..) |item, *e, i| e.* = .{ .title = item.title, .description = item.description, .index = i };
    panel.entries = entries;

    state.* = .{ .popup = &panel.popup, .target_id = target_id };
    errdefer {
        alloc.free(state.rows);
        state.* = .{};
    }
    try applyQuery(panel, "");
    return panel;
}

/// Frees what `begin` made.
fn release(panel: *Panel) void {
    const alloc = panel.popup.window.app.core_app.alloc;
    const state = &panel.popup.window.palette;
    alloc.free(state.rows);
    state.* = .{};
    freeFonts(panel);
    if (panel.brush) |b| _ = gdi32.DeleteObject(@ptrCast(b));
    panel.query.deinit(alloc);
    panel.arena.deinit();
    alloc.destroy(panel);
}

/// Takes the palette of `window` down, if there is one.
fn close(window: *Window) void {
    const p = window.palette.popup orelse return;
    const panel = Panel.of(p);
    panel.closing = true;
    // The focus goes back first: destroying the window that has it would
    // hand the activation to whatever comes next.
    if (window.palette.edit) |edit| {
        if (user32.GetFocus() == edit) {
            const to = if (window.palette.target_id) |id| (if (window.findSurface(id)) |s| s.hwnd else window.hwnd) else window.hwnd;
            _ = user32.SetFocus(to);
        }
    }
    // Takes the EDIT down with the window (unless the host already did).
    p.destroy();
    release(panel);
}

/// The palette is gone when its target is.
fn closeForTarget(window: *Window, id: u32) void {
    if (window.palette.target_id != id) return;
    close(window);
}

/// Closes the palette when `surface` is its target.
pub fn surfaceDestroying(surface: *Surface) void {
    // The target may have moved to another window with its tab.
    for (surface.window.app.windows.items) |window| closeForTarget(window, surface.id);
    closeForTarget(surface.window, surface.id);
}

fn focusedSurface(app: *App) ?*Surface {
    const fg = user32.GetForegroundWindow();
    for (app.windows.items) |window| {
        if (fg != null and window.hwnd == fg) return (window.activeTab() orelse continue).focusedSurface();
    }
    for (app.windows.items) |window| {
        if (window.activeTab()) |tab| if (tab.focusedSurface()) |s| return s;
    }
    return null;
}

pub fn toggle(app: *App, target: apprt.Target) !bool {
    const surface = switch (target) {
        .app => focusedSurface(app),
        .surface => |core| app.surfaceFor(core),
    } orelse return false;
    const window = surface.window;

    if (window.palette.popup != null) {
        close(window);
        return true;
    }

    const config = &app.config;
    const panel = try begin(window, surface.id, config.@"command-palette-entry".value.items, &config.keybind.set);
    errdefer close(window);
    try show(panel);
    return true;
}

fn show(panel: *Panel) !void {
    const p = &panel.popup;
    const window = p.window;
    const state = &window.palette;

    overlay.beginPanelActivation(window);
    try p.show();
    const hwnd = p.hwnd orelse return error.CreateWindowFailed;
    const edit = try createEdit(panel, hwnd);
    state.edit = edit;
    layoutChildren(panel);
    _ = user32.SetFocus(edit);
}

fn createEdit(panel: *Panel, parent: HWND) !HWND {
    const window = panel.popup.window;
    const edit = user32.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        user32.WS_CHILD | user32.WS_VISIBLE | user32.ES_AUTOHSCROLL,
        0,
        0,
        1,
        1,
        parent,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.warn("unable to create the palette EDIT err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = user32.DestroyWindow(edit);
    // wparam 1: the hint stays while the EDIT has the focus.
    _ = user32.SendMessageW(edit, EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(L("Execute a command\u{2026}"))));
    if (comctl32.SetWindowSubclass(edit, editProc, subclass_id, @intFromPtr(panel)) == 0) {
        log.warn("unable to subclass the palette EDIT", .{});
    }
    return edit;
}

/// Fonts, EDIT place and theme for the panel's current size, dpi and palette.
fn layoutChildren(panel: *Panel) void {
    const p = &panel.popup;
    const window = p.window;
    const edit = window.palette.edit orelse return;
    const hwnd = p.hwnd orelse return;
    const dpi = window.dpi;
    const dark = currentColors(window).text.r > 0x80;

    if (panel.font_dpi != dpi) {
        freeFonts(panel);
        panel.font = makeFont(14, dpi, FW_NORMAL, L("Segoe UI"));
        panel.bold_font = makeFont(14, dpi, FW_BOLD, L("Segoe UI"));
        panel.small_font = makeFont(11, dpi, FW_NORMAL, L("Segoe UI"));
        panel.query_font = makeFont(20, dpi, FW_LIGHT, L("Segoe UI Light"));
        panel.font_dpi = dpi;
        if (panel.query_font) |f| _ = user32.SendMessageW(edit, WM_SETFONT, @intFromPtr(f), 1);
    }
    if (panel.dark_applied != dark) {
        panel.dark_applied = dark;
        _ = uxtheme.SetWindowTheme(edit, if (dark) L("DarkMode_Explorer") else L("Explorer"), null);
    }
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    const g = Geometry.forWidth(rc.right - rc.left, dpi);
    _ = user32.MoveWindow(edit, g.edit.x, g.edit.y, g.edit.w, g.edit.h, 1);
}

fn makeFont(px: i32, dpi: u32, weight: i32, face: [*:0]const u16) ?gdi32.HFONT {
    return gdi32.CreateFontW(-geom.scale(px, dpi), 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, face);
}

fn freeFonts(panel: *Panel) void {
    inline for (.{ &panel.font, &panel.bold_font, &panel.small_font, &panel.query_font }) |f| {
        if (f.*) |h| _ = gdi32.DeleteObject(@ptrCast(h));
        f.* = null;
    }
    panel.font_dpi = 0;
}

/// The popup rectangle: centred under the top of the window, at most 80 % of
/// its width.
fn place(p: *overlay.Popup, area: geom.Rect, size_px: overlay.Size) geom.Rect {
    const w = @min(size_px.w, @divTrunc(area.w * 4, 5));
    const h = @min(size_px.h, area.h);
    const x = area.x + @divTrunc(area.w - w, 2);
    const y = area.y + geom.scale(p.margin, p.window.dpi);
    return .{
        .x = x,
        .y = std.math.clamp(y, area.y, @max(area.bottom() - h, area.y)),
        .w = w,
        .h = h,
    };
}

// -- Query -------------------------------------------------------------------------

/// Filters the entries by `text` (trimmed) and resets the selection.
fn applyQuery(panel: *Panel, text: []const u8) !void {
    const window = panel.popup.window;
    const alloc = window.app.core_app.alloc;
    const state = &window.palette;

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    panel.query.clearRetainingCapacity();
    try panel.query.appendSlice(alloc, trimmed);

    const rows = try filter.filter(alloc, trimmed, panel.entries);
    alloc.free(state.rows);
    state.rows = rows;
    state.sel = 0;
    state.scroll = 0;
    panel.hover = null;
    resizeToRows(panel);
}

fn clientHeightDip(window: *const Window) i32 {
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(window.hwnd, &rc);
    return @divTrunc((rc.bottom - rc.top) * 96, @as(i32, @intCast(@max(window.dpi, 1))));
}

fn shownRows(panel: *const Panel) usize {
    const window = panel.popup.window;
    return visibleCount(window.palette.rows.len, clientHeightDip(window));
}

fn resizeToRows(panel: *Panel) void {
    const shown = shownRows(panel);
    panel.popup.setSize(.{ .w = max_w, .h = panelHeight(shown) });
}

fn editChanged(panel: *Panel) void {
    const window = panel.popup.window;
    const alloc = window.app.core_app.alloc;
    const edit = window.palette.edit orelse return;
    const len: usize = @intCast(@max(user32.GetWindowTextLengthW(edit), 0));
    const wide = alloc.alloc(u16, len + 1) catch return;
    defer alloc.free(wide);
    const got: usize = @intCast(@max(user32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    const text = util.utf8(alloc, wide[0..got]) catch |err| {
        log.warn("unable to convert the palette query err={}", .{err});
        return;
    };
    defer alloc.free(text);
    applyQuery(panel, text) catch |err| {
        log.warn("unable to filter the palette err={}", .{err});
        return;
    };
    panel.popup.invalidate();
}

// -- Keys and commands -------------------------------------------------------------

const KeyAction = enum { up, down, page_up, page_down, execute, close };

/// The key a focused EDIT routes to the palette; Ctrl+P and Ctrl+N move as
/// the arrows do.
pub fn keyAction(vk: usize, ctrl: bool) ?KeyAction {
    return switch (vk) {
        user32.VK_UP => .up,
        user32.VK_DOWN => .down,
        user32.VK_PRIOR => .page_up,
        user32.VK_NEXT => .page_down,
        user32.VK_RETURN => .execute,
        user32.VK_ESCAPE => .close,
        'P' => if (ctrl) .up else null,
        'N' => if (ctrl) .down else null,
        else => null,
    };
}

fn postCommand(window: *Window, cmd: *Command) void {
    const lparam: LPARAM = @bitCast(@intFromPtr(cmd));
    if (user32.PostMessageW(window.hwnd, messages.WM_GHOSTTY_OVERLAY_CMD, 0, lparam) == 0) {
        log.warn("unable to post a palette command err={}", .{win32.kernel32.GetLastError()});
        cmd.destroy();
    }
}

fn postClose(panel: *Panel) void {
    if (panel.closing) return;
    const window = panel.popup.window;
    const cmd = Command.create(window.app.core_app.alloc, .close, panel.serial, 0, null) catch return;
    postCommand(window, cmd);
}

/// Runs the entry at `row` (a position in `State.rows`): the command goes to
/// the window's queue, where the palette closes and the action runs.
fn postExecute(panel: *Panel, row: usize) void {
    const window = panel.popup.window;
    const state = &window.palette;
    if (panel.closing) return;
    if (row >= state.rows.len) {
        postClose(panel);
        return;
    }
    const item = panel.items[state.rows[row]];
    const target = state.target_id orelse {
        postClose(panel);
        return;
    };
    const cmd = Command.create(window.app.core_app.alloc, .execute, panel.serial, target, item.action) catch |err| {
        log.warn("unable to copy a palette action err={}", .{err});
        postClose(panel);
        return;
    };
    // Typing and clicking must not run it twice.
    panel.closing = true;
    postCommand(window, cmd);
}

fn run(panel: *Panel, action: KeyAction) void {
    const window = panel.popup.window;
    const state = &window.palette;
    const total = state.rows.len;
    const shown = shownRows(panel);
    switch (action) {
        .up => state.sel = moveSel(state.sel, total, -1),
        .down => state.sel = moveSel(state.sel, total, 1),
        .page_up => state.sel = pageSel(state.sel, total, shown, false),
        .page_down => state.sel = pageSel(state.sel, total, shown, true),
        .execute => return postExecute(panel, state.sel),
        .close => return postClose(panel),
    }
    state.scroll = scrollFor(state.scroll, state.sel, shown, total);
    panel.popup.invalidate();
}

fn scrollBy(panel: *Panel, notches: i32) void {
    const state = &panel.popup.window.palette;
    const shown = shownRows(panel);
    const max_scroll = state.rows.len -| shown;
    const step: i64 = @as(i64, notches) * 3;
    const next = std.math.clamp(@as(i64, @intCast(state.scroll)) - step, 0, @as(i64, @intCast(max_scroll)));
    state.scroll = @intCast(next);
    panel.popup.invalidate();
}

/// `WM_GHOSTTY_OVERLAY_CMD` on a top-level window; true when the command
/// was for the palette (it always is: it is the only sender).
pub fn command(window: *Window, lparam: LPARAM) bool {
    if (lparam == 0 or lparam == -1) return false;
    const cmd: *Command = @ptrFromInt(@as(usize, @bitCast(lparam)));
    defer cmd.destroy();
    switch (cmd.kind) {
        .close => |serial| closeIfSerial(window, serial),
        .execute => |e| {
            closeIfSerial(window, e.serial);
            // A target that is gone ends the command here.
            const surface = window.findSurface(e.target_id) orelse return true;
            _ = surface.core_surface.performBindingAction(e.action) catch |err| {
                log.warn("unable to perform a palette action err={}", .{err});
            };
        },
    }
    return true;
}

fn closeIfSerial(window: *Window, serial: u32) void {
    const p = window.palette.popup orelse return;
    if (Panel.of(p).serial != serial) return;
    close(window);
}

// -- Window procedures -------------------------------------------------------------

fn editProc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    id: usize,
    ref_data: usize,
) callconv(.winapi) LRESULT {
    const panel: *Panel = @ptrFromInt(ref_data);
    switch (msg) {
        user32.WM_KEYDOWN => {
            const ctrl = user32.GetKeyState(user32.VK_CONTROL) < 0;
            if (keyAction(wparam, ctrl)) |action| {
                run(panel, action);
                return 0;
            }
        },
        // Enter, Esc and Ctrl+P / Ctrl+N as characters would only beep.
        user32.WM_CHAR => if (wparam == '\r' or wparam == 0x1B or wparam == 0x10 or wparam == 0x0E) return 0,
        user32.WM_MOUSEWHEEL => {
            scrollBy(panel, @divTrunc(user32.getWheelDelta(wparam), user32.WHEEL_DELTA));
            return 0;
        },
        user32.WM_KILLFOCUS => {
            // The focus going to the panel itself (a click on a row) is not leaving.
            const to: ?HWND = if (wparam == 0) null else @ptrFromInt(wparam);
            const own = if (to) |t| t == panel.popup.hwnd else false;
            if (!own) postClose(panel);
        },
        user32.WM_NCDESTROY => _ = comctl32.RemoveWindowSubclass(hwnd, editProc, id),
        else => {},
    }
    return comctl32.DefSubclassProc(hwnd, msg, wparam, lparam);
}

fn onMessage(p: *overlay.Popup, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    const panel = Panel.of(p);
    const window = p.window;
    const state = &window.palette;
    const hwnd = p.hwnd orelse return null;
    switch (msg) {
        // A click on a row must not take the focus from the EDIT.
        user32.WM_MOUSEACTIVATE => return MA_NOACTIVATE,
        user32.WM_COMMAND => {
            const edit = state.edit orelse return null;
            if (@as(usize, @bitCast(lparam)) != @intFromPtr(edit)) return null;
            if (user32.hiWord(wparam) == user32.EN_CHANGE) editChanged(panel);
            return 0;
        },
        user32.WM_SIZE => {
            layoutChildren(panel);
            return null;
        },
        user32.WM_CTLCOLOREDIT => {
            const c = currentColors(window);
            const hdc: user32.HDC = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, colorRef(c.text));
            _ = SetBkColor(hdc, colorRef(c.bg));
            return editBrush(panel, c.bg);
        },
        user32.WM_MOUSEMOVE => {
            if (!panel.tracking) {
                var tme: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE, .hwndTrack = hwnd };
                panel.tracking = user32.TrackMouseEvent(&tme) != 0;
            }
            setHover(panel, rowUnder(panel, lparam));
            return 0;
        },
        user32.WM_MOUSELEAVE => {
            panel.tracking = false;
            setHover(panel, null);
            return 0;
        },
        user32.WM_MOUSEWHEEL => {
            scrollBy(panel, @divTrunc(user32.getWheelDelta(wparam), user32.WHEEL_DELTA));
            return 0;
        },
        user32.WM_LBUTTONDOWN => {
            panel.pressed = rowUnder(panel, lparam);
            return 0;
        },
        user32.WM_LBUTTONUP => {
            const was = panel.pressed orelse return 0;
            panel.pressed = null;
            const row = rowUnder(panel, lparam) orelse return 0;
            if (row == was) postExecute(panel, state.scroll + row);
            return 0;
        },
        else => {},
    }
    return null;
}

/// The shown row under the cursor of a mouse message.
fn rowUnder(panel: *Panel, lparam: LPARAM) ?usize {
    const p = &panel.popup;
    const hwnd = p.hwnd orelse return null;
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    const dpi = p.window.dpi;
    const g = Geometry.forWidth(rc.right - rc.left, dpi);
    const shown = shownRows(panel);
    return g.rowAt(rc.right - rc.left, dpi, shown, user32.getXLparam(lparam), user32.getYLparam(lparam));
}

fn setHover(panel: *Panel, row: ?usize) void {
    if (panel.hover == row) return;
    panel.hover = row;
    panel.popup.invalidate();
}

/// The brush behind the EDIT text, kept for the colour it was made for.
fn editBrush(panel: *Panel, c: theme.Color) LRESULT {
    const rgb = colorRef(c);
    if (panel.brush == null or panel.brush_rgb != rgb) {
        if (panel.brush) |old| _ = gdi32.DeleteObject(@ptrCast(old));
        panel.brush = gdi32.CreateSolidBrush(rgb);
        panel.brush_rgb = rgb;
    }
    return if (panel.brush) |b| @bitCast(@intFromPtr(b)) else 0;
}

// -- Paint -------------------------------------------------------------------------

const max_items = 12 * 40 + 8;

/// The items of one paint and the UTF-16 text they point to.
const Scene = struct {
    items: [max_items]Chrome.Item = undefined,
    n: usize = 0,
    text: [max_rows * 640]u16 = undefined,
    used: usize = 0,

    fn add(s: *Scene, item: Chrome.Item) void {
        if (s.n >= s.items.len) return;
        s.items[s.n] = item;
        s.n += 1;
    }

    /// UTF-16 of `utf8` kept for the scene, cut at 256 units.
    fn wide(s: *Scene, utf8: []const u8) []const u16 {
        const room = @min(s.text.len - s.used, 256);
        const n = utf16Clip(s.text[s.used..][0..room], utf8);
        const out = s.text[s.used..][0..n];
        s.used += n;
        return out;
    }
};

fn paintPopup(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const panel = Panel.of(p);
    const window = p.window;
    const state = &window.palette;
    // A dpi change reaches the children through the next paint.
    if (panel.font_dpi != ctx.dpi or panel.dark_applied == null) layoutChildren(panel);

    const c = currentColors(window);
    const w = ctx.rect.w;
    const dpi = ctx.dpi;
    const g = Geometry.forWidth(w, dpi);
    const s = geom.scale;
    const body: Chrome.Font = .{ .size_pt = 14 };
    const small: Chrome.Font = .{ .size_pt = 11 };

    var scene: Scene = .{};
    scene.add(.{ .box = .{ .rect = .{ .x = 0, .y = g.divider_y, .w = w, .h = 1 }, .radius = 0, .fill = c.divider } });

    const total = state.rows.len;
    if (total == 0) {
        const r: geom.Rect = .{ .x = s(query_inset, dpi), .y = g.list_top, .w = w - 2 * s(query_inset, dpi), .h = ctx.rect.h - g.list_top };
        scene.add(.{ .text = .{ .rect = r, .text = L("No matches"), .font = body, .color = c.secondary, .halign = .leading } });
    }

    const shown = @min(total -| state.scroll, visibleCount(total, clientHeightDip(window)));
    for (0..shown) |i| {
        const pos = state.scroll + i;
        const item = panel.items[state.rows[pos]];
        const r = g.row(w, dpi, i);
        if (pos == state.sel) {
            scene.add(.{ .box = .{ .rect = r, .radius = s(row_radius, dpi), .fill = c.selected } });
        } else if (panel.hover == i) {
            scene.add(.{ .box = .{ .rect = r, .radius = s(row_radius, dpi), .fill = c.hover } });
        }

        const pad = s(row_pad, dpi);
        var inner: geom.Rect = .{ .x = r.x + pad, .y = r.y, .w = r.w - 2 * pad, .h = r.h };
        if (item.shortcut.len > 0) {
            const text = scene.wide(item.shortcut);
            const width = Chrome.measureText(text, small, dpi) catch 0;
            scene.add(.{ .text = .{
                .rect = .{ .x = inner.right() - width, .y = inner.y, .w = width, .h = inner.h },
                .text = text,
                .font = small,
                .color = c.secondary,
                .halign = .leading,
            } });
            inner.w -= width + pad;
        }
        const has_desc = item.description.len > 0;
        const half = @divTrunc(inner.h, 2);
        const title_rect: geom.Rect = if (has_desc) .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = half + s(2, dpi) } else inner;
        addTitle(panel, &scene, item.title, title_rect, c, dpi);
        if (has_desc) {
            const sub: geom.Rect = .{ .x = inner.x, .y = inner.y + half, .w = inner.w, .h = half - s(2, dpi) };
            scene.add(.{ .text = .{ .rect = sub, .text = scene.wide(item.description), .font = small, .color = c.secondary, .halign = .leading, .trim = true } });
        }
    }

    scene.add(.{ .stroke = .{ .rect = ctx.rect, .radius = 0, .width = 1, .color = c.border } });
    Chrome.paintItems(ctx.hdc, ctx.rect, scene.items[0..scene.n], ctx.palette, dpi, c.bg) catch |err| {
        log.warn("unable to paint the palette err={}", .{err});
    };
}

/// The title, with the characters the query matched in bold and the accent.
fn addTitle(panel: *Panel, scene: *Scene, title: []const u8, r: geom.Rect, c: Colors, dpi: u32) void {
    const normal: Chrome.Font = .{ .size_pt = 14 };
    const bold: Chrome.Font = .{ .size_pt = 14, .weight = .BOLD };
    var mask_buf: [256]bool = undefined;
    const mask: ?[]bool = blk: {
        if (panel.query.items.len == 0 or title.len > mask_buf.len) break :blk null;
        if (!filter.matchMask(panel.query.items, title, &mask_buf)) break :blk null;
        break :blk mask_buf[0..title.len];
    };
    const m = mask orelse {
        scene.add(.{ .text = .{ .rect = r, .text = scene.wide(title), .font = normal, .color = c.text, .halign = .leading, .trim = true } });
        return;
    };

    var x = r.x;
    var i: usize = 0;
    while (i < title.len and x < r.right()) {
        // A run of code points of the same kind.
        const start = i;
        const hit = runHit(title, m, i);
        while (i < title.len and runHit(title, m, i) == hit) i += cpLen(title[i]);
        const text = scene.wide(title[start..i]);
        const font = if (hit) bold else normal;
        const width = Chrome.measureText(text, font, dpi) catch break;
        scene.add(.{ .text = .{
            .rect = .{ .x = x, .y = r.y, .w = @min(width, r.right() - x), .h = r.h },
            .text = text,
            .font = font,
            .color = if (hit) c.accent else c.text,
            .halign = .leading,
        } });
        x += width;
    }
}

fn cpLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn runHit(text: []const u8, mask: []const bool, i: usize) bool {
    const end = @min(i + cpLen(text[i]), text.len);
    for (mask[i..end]) |b| if (b) return true;
    return false;
}

/// UTF-16 of `text`, cut where `out` ends.
fn utf16Clip(out: []u16, text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch 0xFFFD;
        const need: usize = if (cp >= 0x10000) 2 else 1;
        if (n + need > out.len) break;
        n += std.unicode.utf8ToUtf16Le(out[n..], slice) catch break;
    }
    return n;
}

// -- Test state --------------------------------------------------------------------

/// The IPC `state` view: the palette of the first window that has one.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("open");
    var found: ?*Window = null;
    for (app.windows.items) |window| {
        if (window.palette.popup != null) {
            found = window;
            break;
        }
    }
    try jw.write(found != null);
    if (found) |window| {
        const state = &window.palette;
        const panel = Panel.of(state.popup.?);
        const hwnd = panel.popup.hwnd;
        try jw.objectField("visible");
        try jw.write(if (hwnd) |h| user32.IsWindowVisible(h) != 0 else false);
        try jw.objectField("focused");
        try jw.write(if (state.edit) |e| user32.GetFocus() == e else false);
        try jw.objectField("query");
        try jw.write(panel.query.items);
        try jw.objectField("rows");
        try jw.write(state.rows.len);
        try jw.objectField("sel");
        try jw.write(state.sel);
        try jw.objectField("first");
        try jw.write(if (state.rows.len > 0) panel.items[state.rows[0]].title else "");
        try jw.objectField("selected");
        try jw.write(if (state.sel < state.rows.len) panel.items[state.rows[state.sel]].title else "");
        try jw.objectField("target");
        try jw.write(state.target_id);
    }
    try jw.endObject();
}

// -- Tests -------------------------------------------------------------------------

test "win32 palette: scroll and selection" {
    const t = std.testing;
    // Up from the first wraps, down from the last wraps.
    try t.expectEqual(@as(usize, 4), moveSel(0, 5, -1));
    try t.expectEqual(@as(usize, 0), moveSel(4, 5, 1));
    try t.expectEqual(@as(usize, 2), moveSel(1, 5, 1));
    try t.expectEqual(@as(usize, 0), moveSel(0, 0, 1));
    // Pages stop at the ends.
    try t.expectEqual(@as(usize, 12), pageSel(0, 30, 12, true));
    try t.expectEqual(@as(usize, 29), pageSel(25, 30, 12, true));
    try t.expectEqual(@as(usize, 0), pageSel(5, 30, 12, false));
    // The selection stays in view.
    try t.expectEqual(@as(usize, 0), scrollFor(0, 3, 12, 30));
    try t.expectEqual(@as(usize, 1), scrollFor(0, 12, 12, 30));
    try t.expectEqual(@as(usize, 18), scrollFor(18, 29, 12, 30));
    try t.expectEqual(@as(usize, 5), scrollFor(10, 5, 12, 30));
    // A tall list in a short window shows what fits, at least one row.
    try t.expectEqual(@as(usize, 12), visibleCount(40, 1000));
    try t.expectEqual(@as(usize, 3), visibleCount(3, 1000));
    try t.expectEqual(@as(usize, 1), visibleCount(40, 100));
    try t.expectEqual(@as(usize, 0), visibleCount(0, 1000));
    try t.expectEqual(@as(i32, 48 + 1 + 49), panelHeight(0));
    try t.expectEqual(@as(i32, 48 + 1 + 20 + 40), panelHeight(1));
}

test "win32 palette: key routing" {
    try std.testing.expectEqual(KeyAction.up, keyAction(user32.VK_UP, false).?);
    try std.testing.expectEqual(KeyAction.down, keyAction(user32.VK_DOWN, false).?);
    try std.testing.expectEqual(KeyAction.page_up, keyAction(user32.VK_PRIOR, false).?);
    try std.testing.expectEqual(KeyAction.page_down, keyAction(user32.VK_NEXT, false).?);
    try std.testing.expectEqual(KeyAction.execute, keyAction(user32.VK_RETURN, false).?);
    try std.testing.expectEqual(KeyAction.close, keyAction(user32.VK_ESCAPE, false).?);
    try std.testing.expectEqual(KeyAction.up, keyAction('P', true).?);
    try std.testing.expectEqual(KeyAction.down, keyAction('N', true).?);
    try std.testing.expect(keyAction('P', false) == null);
    try std.testing.expect(keyAction('A', true) == null);
}

test "win32 palette: shortcut text and title order" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+P", shortcutText(&buf, .{
        .key = .{ .physical = .key_p },
        .mods = .{ .ctrl = true, .shift = true },
    }));
    try std.testing.expectEqualStrings("Alt+Page Down", shortcutText(&buf, .{
        .key = .{ .physical = .page_down },
        .mods = .{ .alt = true },
    }));
    try std.testing.expectEqualStrings("Win+Up", shortcutText(&buf, .{
        .key = .{ .physical = .arrow_up },
        .mods = .{ .super = true },
    }));
    try std.testing.expectEqualStrings("Ctrl+5", shortcutText(&buf, .{
        .key = .{ .physical = .digit_5 },
        .mods = .{ .ctrl = true },
    }));
    try std.testing.expectEqualStrings("Ctrl+Shift+T", shortcutText(&buf, .{
        .key = .{ .unicode = 't' },
        .mods = .{ .ctrl = true, .shift = true },
    }));
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqualStrings("", shortcutText(&tiny, .{ .key = .{ .physical = .key_p }, .mods = .{ .ctrl = true } }));

    // As GTK: case folded, "Foo:" before "Foo Bar:".
    try std.testing.expect(titleLess("Focus Split: Left", "Focus Split Zoom"));
    try std.testing.expect(titleLess("close tab", "Close Window"));
    try std.testing.expect(titleLess("Close", "Close Tab"));
    try std.testing.expect(!titleLess("Close Tab", "Close Tab"));
}

test "win32 palette: colours follow the background" {
    const accent: theme.Color = .{ .r = 0, .g = 0x78, .b = 0xD7 };
    const dark = colors(.{ .r = 0x10, .g = 0x10, .b = 0x10 }, accent, null);
    try std.testing.expectEqual(@as(u8, 0xFF), dark.text.r);
    const light = colors(.{ .r = 0xF0, .g = 0xF0, .b = 0xF0 }, accent, null);
    try std.testing.expectEqual(@as(u8, 0), light.text.r);
    // The selection is the accent at 0.2 over the background.
    try std.testing.expectEqual(@as(u8, 13), dark.selected.r);
    try std.testing.expectEqual(@as(u8, 37), dark.selected.g);
}

/// A hidden owner window with the fields the palette reads; the rest of
/// the `Window` stays undefined.
const TestOwner = struct {
    core: @import("../../App.zig"),
    app: App,
    window: Window,
    hwnd: HWND,

    fn create() !*TestOwner {
        const alloc = std.testing.allocator;
        const hinstance = win32.kernel32.GetModuleHandleW(null) orelse return error.SkipZigTest;
        const hwnd = user32.CreateWindowExW(0, L("STATIC"), L(""), user32.WS_POPUP, 100, 100, 400, 300, null, null, hinstance, null) orelse
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
        self.window.palette = .{};
        self.window.tabs = .empty;
        return self;
    }

    fn destroy(self: *TestOwner) void {
        const alloc = std.testing.allocator;
        self.window.overlays.popups.deinit(alloc);
        _ = user32.DestroyWindow(self.hwnd);
        alloc.destroy(self);
    }
};

test "win32 palette: target closed while open" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    const window = &owner.window;
    const cmds = [_]input.Command{
        .{ .action = .{ .new_split = .right }, .title = "Split Right", .description = "Split the terminal to the right." },
        .{ .action = .{ .text = "hi" }, .title = "Send Text", .description = "" },
        .{ .action = .undo, .title = "Undo", .description = "" },
    };

    const panel = try begin(window, 42, &cmds, null);
    try panel.popup.show();
    const hwnd = panel.popup.hwnd.?;
    try std.testing.expect(window.palette.popup != null);
    try std.testing.expectEqual(@as(?u32, 42), window.palette.target_id);
    // Sorted by title, the unsupported "Undo" left out.
    try std.testing.expectEqual(@as(usize, 2), window.palette.rows.len);
    try std.testing.expectEqualStrings("Send Text", panel.items[window.palette.rows[0]].title);

    // Another surface going away leaves the palette alone.
    closeForTarget(window, 7);
    try std.testing.expect(window.palette.popup != null);

    // The target going away closes it and frees everything (the testing
    // allocator reports a leak).
    closeForTarget(window, 42);
    try std.testing.expect(window.palette.popup == null);
    try std.testing.expect(window.palette.target_id == null);
    try std.testing.expectEqual(@as(usize, 0), window.palette.rows.len);
    try std.testing.expectEqual(@as(usize, 0), window.overlays.popups.items.len);
    try std.testing.expectEqual(@as(i32, 0), user32.IsWindow(hwnd));

    // A command queued for the gone target is a no-op that frees its copy.
    const alloc = std.testing.allocator;
    const queued = try Command.create(alloc, .execute, 1, 42, .{ .text = "queued" });
    try std.testing.expect(command(window, @bitCast(@intFromPtr(queued))));
    const stale = try Command.create(alloc, .close, 1, 0, null);
    try std.testing.expect(command(window, @bitCast(@intFromPtr(stale))));
    try std.testing.expect(!command(window, 0));
}

test "win32 palette: a posted close of an older palette keeps the new one" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    const window = &owner.window;
    const cmds = [_]input.Command{
        .{ .action = .{ .text = "hi" }, .title = "Send Text", .description = "" },
    };
    const first = try begin(window, 1, &cmds, null);
    const old_serial = first.serial;
    close(window);
    const second = try begin(window, 1, &cmds, null);
    defer close(window);
    try std.testing.expect(second.serial != old_serial);

    const stale = try Command.create(std.testing.allocator, .close, old_serial, 0, null);
    try std.testing.expect(command(window, @bitCast(@intFromPtr(stale))));
    try std.testing.expect(window.palette.popup != null);

    const current = try Command.create(std.testing.allocator, .close, second.serial, 0, null);
    try std.testing.expect(command(window, @bitCast(@intFromPtr(current))));
    try std.testing.expect(window.palette.popup == null);
}

test "win32 palette: overlay command owns a cloned action" {
    const alloc = std.testing.allocator;
    // The action points into memory a config reload frees.
    const config_text = try alloc.dupe(u8, "echo hello");
    const cmd = try Command.create(alloc, .execute, 3, 9, .{ .text = config_text });
    @memset(config_text, 0xAA);
    alloc.free(config_text);

    const e = cmd.kind.execute;
    try std.testing.expectEqual(@as(u32, 9), e.target_id);
    try std.testing.expectEqualStrings("echo hello", e.action.text);
    // Freeing the command frees the copy and the block itself.
    cmd.destroy();
}
