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
const profiles = @import("profiles.zig");
const profiles_menu = @import("profiles_menu.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");
const global = @import("../../global.zig");

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

pub const no_sel = std.math.maxInt(usize);

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
    /// Position in `rows`; `no_sel` until a query is typed or a key moves it.
    sel: usize = no_sel,
    /// The first row shown.
    scroll: usize = 0,
};

/// One entry of the list; the text lives in the panel's arena.
const Item = struct {
    title: []const u8,
    description: []const u8,
    /// "Ctrl+Shift+P", empty when the action has no binding.
    shortcut: []const u8,
    run: Run,
};

const Run = union(enum) {
    action: input.Binding.Action,
    /// Focus the surface with this id.
    jump: u32,
    /// Start a shell profile in a new tab (or window).
    profile: struct { id: []const u8, window: bool },
};

/// What the heap block of an open palette holds; `popup` is its first field.
const Panel = struct {
    popup: overlay.Popup,
    /// Tells a posted close of this palette from one of an earlier palette.
    serial: u32,
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    entries: []filter.Entry = &.{},
    /// Row heights in DIP, parallel to `State.rows`.
    heights: []i32 = &.{},
    /// The list area in DIP the popup was last sized for.
    area: i32 = empty_h,
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

/// "PALT".
const palette_magic: u32 = 0x544C4150;

/// What `WM_GHOSTTY_OVERLAY_CMD` carries to a window. It owns its memory
/// (the action is a copy, not a view of the config) and the handler frees it.
pub const Command = struct {
    /// What `lparam` points at: every sender of `WM_GHOSTTY_OVERLAY_CMD`
    /// starts its block with a `Header`, so that a receiver can tell whose
    /// block it holds before it reads more.
    header: Header align(8) = .{ .magic = palette_magic },
    arena: std.heap.ArenaAllocator,
    kind: Kind,

    pub const Header = extern struct { magic: u32 };

    fn fromLparam(lparam: LPARAM) ?*Command {
        if (lparam == 0 or lparam == -1) return null;
        const header: *const Header = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (header.magic != palette_magic) return null;
        return @fieldParentPtr("header", @as(*align(8) Header, @alignCast(@constCast(header))));
    }

    pub const Kind = union(enum) {
        /// Closes the palette `serial` if it is still the open one.
        close: u32,
        /// Closes the palette and runs `action` on the surface `target_id`.
        execute: struct { serial: u32, target_id: u32, action: input.Binding.Action },
        /// Closes the palette and brings the surface `surface_id` forward.
        jump: struct { serial: u32, surface_id: u32 },
        /// Closes the palette and starts the shell profile `id`.
        profile: struct { serial: u32, id: []const u8, window: bool },
    };

    /// `kind` is copied: the action gets its own memory.
    fn create(alloc: Allocator, kind: Kind) !*Command {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const cmd = try arena.allocator().create(Command);
        cmd.header = .{ .magic = palette_magic };
        cmd.arena = arena;
        cmd.kind = switch (kind) {
            .execute => |e| .{ .execute = .{
                .serial = e.serial,
                .target_id = e.target_id,
                .action = try e.action.clone(cmd.arena.allocator()),
            } },
            .profile => |p| .{ .profile = .{
                .serial = p.serial,
                .id = try cmd.arena.allocator().dupe(u8, p.id),
                .window = p.window,
            } },
            else => kind,
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

/// Sizes at 96 dpi, from `CommandPaletteView`: a 500 pt wide panel, a 48 pt
/// query field, a divider, and a list of at most 200 pt with a 10 pt margin
/// and 4 pt gaps; a row is 8 pt padding around the 16 pt title and, when
/// there is a description, 2 pt and the 13 pt description.
const max_w = 500;
const query_h = 48;
const query_inset = 16;
const edit_h = 28;
const list_pad = 10;
const list_max = 200;
const row_single = 32;
const row_double = 47;
const row_gap = 4;
const row_pad = 8;
const row_radius = 5;
const empty_h = 49;
const margin = 16;
const radius = 10;

fn rowHeight(item: Item) i32 {
    return if (item.description.len > 0) row_double else row_single;
}

/// The height of the list area in DIP: the rows, capped at 200 and at what
/// a window of `client_h` leaves room for (always one row).
pub fn listHeight(heights: []const i32, client_h: i32) i32 {
    if (heights.len == 0) return empty_h;
    var content: i32 = 2 * list_pad - row_gap;
    for (heights) |h| content += h + row_gap;
    const room = client_h - 2 * margin - query_h - 1;
    const cap = @min(list_max, @max(room, heights[0] + 2 * list_pad));
    return @min(content, cap);
}

/// The popup height in DIP for a list area of `list_h`.
pub fn panelHeight(list_h: i32) i32 {
    return query_h + 1 + list_h;
}

/// How many whole rows from `scroll` fit in a list area of `area` (at least
/// one while there are rows).
pub fn fitCount(heights: []const i32, scroll: usize, area: i32) usize {
    if (scroll >= heights.len) return 0;
    const avail = area - 2 * list_pad;
    var used: i32 = 0;
    var n: usize = 0;
    for (heights[scroll..]) |h| {
        const gap: i32 = if (n > 0) row_gap else 0;
        const next = used + h + gap;
        if (next > avail and n > 0) break;
        used = next;
        n += 1;
    }
    return n;
}

/// The first row at which the last row is shown.
pub fn maxScroll(heights: []const i32, area: i32) usize {
    var s: usize = 0;
    while (s < heights.len and s + fitCount(heights, s, area) < heights.len) s += 1;
    return s;
}

/// The `scroll` that keeps `sel` among the rows shown.
pub fn scrollFor(heights: []const i32, scroll: usize, sel: usize, area: i32) usize {
    if (heights.len == 0) return 0;
    var s = @min(scroll, heights.len - 1);
    if (sel == no_sel or sel >= heights.len) return s;
    if (sel < s) s = sel;
    while (sel >= s + fitCount(heights, s, area) and s < sel) s += 1;
    return s;
}

/// Up (`-1`) or down (`+1`) from `sel`, wrapping, as on macOS; from no
/// selection up is the last row and down the first.
pub fn moveSel(sel: usize, total: usize, delta: i32) usize {
    if (total == 0) return no_sel;
    if (sel == no_sel or sel >= total) return if (delta < 0) total - 1 else 0;
    if (delta < 0) return if (sel == 0) total - 1 else sel - 1;
    return if (sel + 1 >= total) 0 else sel + 1;
}

/// A page up or down stops at the ends.
pub fn pageSel(sel: usize, total: usize, visible: usize, down: bool) usize {
    if (total == 0) return no_sel;
    if (sel == no_sel or sel >= total) return if (down) 0 else total - 1;
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

    /// The rectangles of the rows from `scroll` that fit, in px.
    fn rows(g: Geometry, heights: []const i32, scroll: usize, area_dip: i32, w: i32, dpi: u32, out: []geom.Rect) usize {
        const s = geom.scale;
        const n = @min(fitCount(heights, scroll, area_dip), out.len);
        var y = g.list_top + s(list_pad, dpi);
        for (0..n) |i| {
            const h = s(heights[scroll + i], dpi);
            out[i] = .{ .x = s(list_pad, dpi), .y = y, .w = w - 2 * s(list_pad, dpi), .h = h };
            y += h + s(row_gap, dpi);
        }
        return n;
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
        .redo,
        => false,
        else => true,
    };
}

fn itemLess(_: void, a: Item, b: Item) bool {
    return titleLess(a.title, b.title);
}

// -- Open and close ----------------------------------------------------------------

/// A surface the palette can bring forward.
const Jump = struct { id: u32, title: []const u8, pwd: []const u8 };

/// `pwd` with the home directory written as "~".
pub fn abbreviatePwd(alloc: Allocator, pwd: []const u8, home: []const u8) ![]const u8 {
    const home_trim = std.mem.trimEnd(u8, home, "\\/");
    if (home_trim.len > 0 and pwd.len >= home_trim.len and
        std.ascii.eqlIgnoreCase(pwd[0..home_trim.len], home_trim) and
        (pwd.len == home_trim.len or pwd[home_trim.len] == '/' or pwd[home_trim.len] == '\\'))
    {
        return std.fmt.allocPrint(alloc, "~{s}", .{pwd[home_trim.len..]});
    }
    return alloc.dupe(u8, pwd);
}

/// Builds the panel of a palette for `target_id` from `commands` and `jumps` (copied;
/// `keybinds` gives the shortcut texts) and registers it with the window.
/// Nothing is shown yet.
fn begin(
    window: *Window,
    target_id: u32,
    commands: []const input.Command,
    jumps: []const Jump,
    shells: []const profiles.Profile,
    home: []const u8,
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
            .size = .{ .w = max_w, .h = panelHeight(empty_h) },
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
            .run = .{ .action = try entry.action.clone(a) },
        });
    }
    for (jumps) |j| {
        const title = if (j.title.len > 0) j.title else "Untitled";
        try items.append(a, .{
            .title = try std.fmt.allocPrint(a, "Focus: {s}", .{title}),
            // The working directory, unless the title shows it already.
            .description = if (j.pwd.len > 0 and std.mem.indexOf(u8, title, j.pwd) == null) try abbreviatePwd(a, j.pwd, home) else "",
            .shortcut = "",
            .run = .{ .jump = j.id },
        });
    }
    for (shells) |p| {
        for ([_]bool{ false, true }) |as_window| {
            try items.append(a, .{
                .title = try std.fmt.allocPrint(a, "{s}: {s}", .{ if (as_window) "New Window" else "New Tab", p.name }),
                .description = "",
                .shortcut = "",
                .run = .{ .profile = .{ .id = try a.dupe(u8, p.id), .window = as_window } },
            });
        }
    }
    std.mem.sort(Item, items.items, {}, itemLess);
    panel.items = items.items;

    const entries = try a.alloc(filter.Entry, panel.items.len);
    for (panel.items, entries, 0..) |item, *e, i| e.* = .{ .title = item.title, .description = item.description, .index = i };
    panel.entries = entries;

    state.* = .{ .popup = &panel.popup, .target_id = target_id };
    errdefer {
        alloc.free(state.rows);
        alloc.free(panel.heights);
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
    alloc.free(panel.heights);
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
    // The EDIT may outlive the panel when the owner is going away: it must
    // not call back into freed memory.
    if (window.palette.edit) |edit| {
        if (user32.IsWindow(edit) != 0) _ = comctl32.RemoveWindowSubclass(edit, editProc, subclass_id);
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

    var jumps: std.ArrayList(Jump) = .empty;
    defer jumps.deinit(app.core_app.alloc);
    for (app.windows.items) |w| {
        for (w.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const v = entry.view;
                // The user's title of the tab wins over the surface's; a
                // surface without one shows the title of its tab.
                const title: []const u8 = if (tab.focused == v and tab.title_override != null)
                    tab.title_override.?
                else
                    v.title orelse tab.title();
                try jumps.append(app.core_app.alloc, .{ .id = v.id, .title = title, .pwd = v.pwd orelse "" });
            }
        }
    }

    const home = global.environ().getAlloc(app.core_app.alloc, "USERPROFILE") catch null;
    defer if (home) |h| app.core_app.alloc.free(h);

    const config = &app.config;
    const panel = try begin(window, surface.id, config.@"command-palette-entry".value.items, jumps.items, profiles.refresh(app), home orelse "", &config.keybind.set);
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
        panel.font = makeFont(13, dpi, FW_NORMAL, L("Segoe UI"));
        panel.bold_font = makeFont(13, dpi, FW_BOLD, L("Segoe UI"));
        panel.small_font = makeFont(10, dpi, FW_NORMAL, L("Segoe UI"));
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

/// Filters the entries by `text` (trimmed). As on macOS the selection starts
/// on the first row once there is a query, is dropped again when the query
/// is cleared on that first row, and is otherwise kept (within the list).
fn applyQuery(panel: *Panel, text: []const u8) !void {
    const window = panel.popup.window;
    const alloc = window.app.core_app.alloc;
    const state = &window.palette;

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    panel.query.clearRetainingCapacity();
    try panel.query.appendSlice(alloc, trimmed);

    const rows = try filter.filter(alloc, trimmed, panel.entries);
    errdefer alloc.free(rows);
    const heights = try alloc.alloc(i32, rows.len);
    for (rows, heights) |r, *h| h.* = rowHeight(panel.items[r]);
    alloc.free(state.rows);
    alloc.free(panel.heights);
    state.rows = rows;
    panel.heights = heights;

    if (rows.len == 0) {
        state.sel = no_sel;
    } else if (trimmed.len > 0) {
        state.sel = if (state.sel == no_sel) 0 else @min(state.sel, rows.len - 1);
    } else if (state.sel == 0 or state.sel >= rows.len) {
        state.sel = no_sel;
    }
    state.scroll = scrollFor(heights, 0, state.sel, listAreaDip(panel));
    panel.hover = null;
    resizeToRows(panel);
}

fn clientHeightDip(window: *const Window) i32 {
    var rc: win32.foundation.RECT = undefined;
    _ = user32.GetClientRect(window.hwnd, &rc);
    return @divTrunc((rc.bottom - rc.top) * 96, @as(i32, @intCast(@max(window.dpi, 1))));
}

/// The list area the palette has (or is about to have) in DIP.
fn listAreaDip(panel: *const Panel) i32 {
    return listHeight(panel.heights, clientHeightDip(panel.popup.window));
}

fn resizeToRows(panel: *Panel) void {
    panel.area = listAreaDip(panel);
    panel.popup.setSize(.{ .w = max_w, .h = panelHeight(panel.area) });
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

/// Whether the command is on its way; if not it is already freed.
fn postCommand(window: *Window, cmd: *Command) bool {
    const lparam: LPARAM = @bitCast(@intFromPtr(&cmd.header));
    if (user32.PostMessageW(window.hwnd, messages.WM_GHOSTTY_OVERLAY_CMD, 0, lparam) == 0) {
        log.warn("unable to post a palette command err={}", .{win32.kernel32.GetLastError()});
        cmd.destroy();
        return false;
    }
    return true;
}

fn postClose(panel: *Panel) void {
    if (panel.closing) return;
    const window = panel.popup.window;
    const cmd = Command.create(window.app.core_app.alloc, .{ .close = panel.serial }) catch return;
    _ = postCommand(window, cmd);
}

/// Runs the entry at `row` (a position in `State.rows`): the command goes to
/// the window's queue, where the palette closes and the entry runs. No row
/// (nothing selected) just closes.
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
    const kind: Command.Kind = switch (item.run) {
        .action => |a| .{ .execute = .{ .serial = panel.serial, .target_id = target, .action = a } },
        .jump => |id| .{ .jump = .{ .serial = panel.serial, .surface_id = id } },
        .profile => |p| .{ .profile = .{ .serial = panel.serial, .id = p.id, .window = p.window } },
    };
    const cmd = Command.create(window.app.core_app.alloc, kind) catch |err| {
        log.warn("unable to copy a palette action err={}", .{err});
        postClose(panel);
        return;
    };
    // Typing and clicking must not run it twice.
    panel.closing = true;
    if (!postCommand(window, cmd)) panel.closing = false;
}

fn run(panel: *Panel, action: KeyAction) void {
    const window = panel.popup.window;
    const state = &window.palette;
    const total = state.rows.len;
    const area = panel.area;
    const shown = fitCount(panel.heights, state.scroll, area);
    switch (action) {
        .up => state.sel = moveSel(state.sel, total, -1),
        .down => state.sel = moveSel(state.sel, total, 1),
        .page_up => state.sel = pageSel(state.sel, total, shown, false),
        .page_down => state.sel = pageSel(state.sel, total, shown, true),
        .execute => return postExecute(panel, state.sel),
        .close => return postClose(panel),
    }
    state.scroll = scrollFor(panel.heights, state.scroll, state.sel, area);
    panel.hover = null;
    panel.popup.invalidate();
}

fn scrollBy(panel: *Panel, notches: i32) void {
    const state = &panel.popup.window.palette;
    const max_scroll = maxScroll(panel.heights, panel.area);
    const step: i64 = @as(i64, notches) * 3;
    const next = std.math.clamp(@as(i64, @intCast(state.scroll)) - step, 0, @as(i64, @intCast(max_scroll)));
    state.scroll = @intCast(next);
    panel.hover = null;
    panel.popup.invalidate();
}

/// `WM_GHOSTTY_OVERLAY_CMD` on a top-level window; true when the command
/// was for the palette (it always is: it is the only sender).
pub fn command(window: *Window, lparam: LPARAM) bool {
    const cmd = Command.fromLparam(lparam) orelse return false;
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
        .profile => |p| {
            closeIfSerial(window, p.serial);
            profiles_menu.launch(window.app, window, p.id, p.window);
        },
        .jump => |j| {
            closeIfSerial(window, j.serial);
            for (window.app.windows.items) |w| {
                const surface = w.findSurface(j.surface_id) orelse continue;
                const index = w.tabIndex(surface.tab) orelse return true;
                surface.tab.focused = surface;
                w.selectTabFocus(index, false);
                w.activate();
                return true;
            }
        },
    }
    return true;
}

/// Commands posted to a window that is going away are never delivered: take
/// them out of its queue and free them, and take its palette down.
pub fn windowDestroying(window: *Window) void {
    var msg: user32.MSG = undefined;
    const m = messages.WM_GHOSTTY_OVERLAY_CMD;
    while (user32.PeekMessageW(&msg, window.hwnd, m, m, user32.PM_REMOVE) != 0) {
        if (Command.fromLparam(msg.lParam)) |cmd| {
            cmd.destroy();
        } else {
            overlay.freeCommand(msg.lParam);
        }
    }
    close(window);
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
    var rects: [16]geom.Rect = undefined;
    const n = g.rows(panel.heights, p.window.palette.scroll, panel.area, rc.right - rc.left, dpi, &rects);
    const x = user32.getXLparam(lparam);
    const y = user32.getYLparam(lparam);
    for (rects[0..n], 0..) |r, i| if (r.contains(x, y)) return i;
    return null;
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

const max_items = 16 * 40 + 8;

/// The items of one paint and the UTF-16 text they point to.
const Scene = struct {
    items: [max_items]Chrome.Item = undefined,
    n: usize = 0,
    text: [16 * 640]u16 = undefined,
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
    const body: Chrome.Font = .{ .size_pt = 13 };
    const small: Chrome.Font = .{ .size_pt = 10 };

    var scene: Scene = .{};
    scene.add(.{ .box = .{ .rect = .{ .x = 0, .y = g.divider_y, .w = w, .h = 1 }, .radius = 0, .fill = c.divider } });

    const total = state.rows.len;
    if (total == 0) {
        const r: geom.Rect = .{ .x = s(query_inset, dpi), .y = g.list_top, .w = w - 2 * s(query_inset, dpi), .h = ctx.rect.h - g.list_top };
        scene.add(.{ .text = .{ .rect = r, .text = L("No matches"), .font = body, .color = c.secondary, .halign = .leading } });
    }

    var rects: [16]geom.Rect = undefined;
    const area = panel.area;
    const shown = g.rows(panel.heights, state.scroll, area, w, dpi, &rects);
    for (0..shown) |i| {
        const pos = state.scroll + i;
        const item = panel.items[state.rows[pos]];
        const r = rects[i];
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
    const normal: Chrome.Font = .{ .size_pt = 13 };
    const bold: Chrome.Font = .{ .size_pt = 13, .weight = .BOLD };
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
        try jw.write(if (state.sel == no_sel) null else state.sel);
        try jw.objectField("first");
        try jw.write(if (state.rows.len > 0) panel.items[state.rows[0]].title else "");
        try jw.objectField("selected");
        try jw.write(if (state.sel != no_sel and state.sel < state.rows.len) panel.items[state.rows[state.sel]].title else "");
        try jw.objectField("target");
        try jw.write(state.target_id);
    }
    try jw.endObject();
}

// -- Tests -------------------------------------------------------------------------

test "win32 palette: scroll and selection" {
    const t = std.testing;
    // Up from the first wraps, down from the last wraps; from nothing, up is
    // the last row and down the first.
    try t.expectEqual(@as(usize, 4), moveSel(0, 5, -1));
    try t.expectEqual(@as(usize, 0), moveSel(4, 5, 1));
    try t.expectEqual(@as(usize, 2), moveSel(1, 5, 1));
    try t.expectEqual(@as(usize, 4), moveSel(no_sel, 5, -1));
    try t.expectEqual(@as(usize, 0), moveSel(no_sel, 5, 1));
    try t.expectEqual(no_sel, moveSel(0, 0, 1));
    // Pages stop at the ends.
    try t.expectEqual(@as(usize, 4), pageSel(0, 30, 4, true));
    try t.expectEqual(@as(usize, 29), pageSel(27, 30, 4, true));
    try t.expectEqual(@as(usize, 0), pageSel(2, 30, 4, false));

    // Rows of 32 DIP with 4 between: 5 fit in 200 - 2 * 10.
    const single: [30]i32 = @splat(row_single);
    try t.expectEqual(@as(usize, 5), fitCount(&single, 0, 200));
    try t.expectEqual(@as(usize, 3), fitCount(&single, 27, 200));
    try t.expectEqual(@as(usize, 0), fitCount(&single, 30, 200));
    // Taller rows: 47 + 4 + 47 + 4 + 47 = 149 fits, a fourth does not.
    const double: [10]i32 = @splat(row_double);
    try t.expectEqual(@as(usize, 3), fitCount(&double, 0, 200));
    // A single row always counts, however small the area.
    try t.expectEqual(@as(usize, 1), fitCount(&double, 0, 30));
    // The selection stays in view.
    try t.expectEqual(@as(usize, 0), scrollFor(&single, 0, 3, 200));
    try t.expectEqual(@as(usize, 1), scrollFor(&single, 0, 5, 200));
    try t.expectEqual(@as(usize, 25), scrollFor(&single, 25, 29, 200));
    try t.expectEqual(@as(usize, 5), scrollFor(&single, 10, 5, 200));
    try t.expectEqual(@as(usize, 7), scrollFor(&single, 7, no_sel, 200));
    try t.expectEqual(@as(usize, 25), maxScroll(&single, 200));
    try t.expectEqual(@as(usize, 0), maxScroll(single[0..3], 200));
    // The list is as tall as its rows, up to 200, and what a short window
    // leaves; no rows is the "No matches" line.
    try t.expectEqual(@as(i32, 2 * 10 + 32), listHeight(single[0..1], 1000));
    try t.expectEqual(@as(i32, 200), listHeight(&single, 1000));
    try t.expectEqual(@as(i32, 2 * 10 + 32), listHeight(&single, 100));
    try t.expectEqual(@as(i32, empty_h), listHeight(&.{}, 1000));
    try t.expectEqual(@as(i32, 48 + 1 + 200), panelHeight(200));
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
        .{ .action = .redo, .title = "Redo", .description = "" },
    };

    const panel = try begin(window, 42, &cmds, &.{}, &.{}, "", null);
    try panel.popup.show();
    const hwnd = panel.popup.hwnd.?;
    try std.testing.expect(window.palette.popup != null);
    try std.testing.expectEqual(@as(?u32, 42), window.palette.target_id);
    // Sorted by title, the unsupported "Redo" left out.
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
    const queued = try Command.create(alloc, .{ .execute = .{ .serial = 1, .target_id = 42, .action = .{ .text = "queued" } } });
    try std.testing.expect(command(window, @bitCast(@intFromPtr(&queued.header))));
    const stale = try Command.create(alloc, .{ .close = 1 });
    try std.testing.expect(command(window, @bitCast(@intFromPtr(&stale.header))));
    try std.testing.expect(!command(window, 0));
}

test "win32 palette: a posted close of an older palette keeps the new one" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    const window = &owner.window;
    const cmds = [_]input.Command{
        .{ .action = .{ .text = "hi" }, .title = "Send Text", .description = "" },
    };
    const first = try begin(window, 1, &cmds, &.{}, &.{}, "", null);
    const old_serial = first.serial;
    close(window);
    const second = try begin(window, 1, &cmds, &.{}, &.{}, "", null);
    defer close(window);
    try std.testing.expect(second.serial != old_serial);

    const stale = try Command.create(std.testing.allocator, .{ .close = old_serial });
    try std.testing.expect(command(window, @bitCast(@intFromPtr(&stale.header))));
    try std.testing.expect(window.palette.popup != null);

    const current = try Command.create(std.testing.allocator, .{ .close = second.serial });
    try std.testing.expect(command(window, @bitCast(@intFromPtr(&current.header))));
    try std.testing.expect(window.palette.popup == null);
}

test "win32 palette: overlay command owns a cloned action" {
    const alloc = std.testing.allocator;
    // The action points into memory a config reload frees.
    const config_text = try alloc.dupe(u8, "echo hello");
    const cmd = try Command.create(alloc, .{ .execute = .{ .serial = 3, .target_id = 9, .action = .{ .text = config_text } } });
    @memset(config_text, 0xAA);
    alloc.free(config_text);

    const e = cmd.kind.execute;
    try std.testing.expectEqual(@as(u32, 9), e.target_id);
    try std.testing.expectEqualStrings("echo hello", e.action.text);
    // Freeing the command frees the copy and the block itself.
    cmd.destroy();
}

test "win32 palette: nothing selected until a query, jump entries" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    const window = &owner.window;
    const cmds = [_]input.Command{
        .{ .action = .{ .text = "hi" }, .title = "Send Text", .description = "" },
    };
    const jumps = [_]Jump{
        .{ .id = 5, .title = "bash", .pwd = "C:/work" },
        .{ .id = 6, .title = "vim C:/work/a.txt", .pwd = "C:/work" },
        .{ .id = 7, .title = "", .pwd = "" },
    };
    const panel = try begin(window, 5, &cmds, &jumps, &.{}, "C:/Users/me", null);
    defer close(window);
    const state = &window.palette;

    try std.testing.expectEqual(@as(usize, 4), state.rows.len);
    try std.testing.expectEqual(no_sel, state.sel);
    // Sorted by title; a description makes the row taller, a title that
    // shows the directory has none.
    try std.testing.expectEqualStrings("Focus: bash", panel.items[state.rows[0]].title);
    try std.testing.expectEqualStrings("C:/work", panel.items[state.rows[0]].description);
    try std.testing.expectEqual(@as(i32, row_double), panel.heights[0]);
    try std.testing.expectEqualStrings("Focus: Untitled", panel.items[state.rows[1]].title);
    try std.testing.expectEqual(@as(i32, row_single), panel.heights[1]);
    try std.testing.expectEqualStrings("Focus: vim C:/work/a.txt", panel.items[state.rows[2]].title);
    try std.testing.expectEqual(@as(usize, 6), panel.items[state.rows[2]].run.jump);

    // A query selects the first row, clearing it on the first row drops it.
    try applyQuery(panel, "  send ");
    try std.testing.expectEqual(@as(usize, 1), state.rows.len);
    try std.testing.expectEqual(@as(usize, 0), state.sel);
    try applyQuery(panel, "");
    try std.testing.expectEqual(no_sel, state.sel);
    // A moved selection survives the query, within the list.
    try applyQuery(panel, "o");
    state.sel = 2;
    try applyQuery(panel, "oc");
    try std.testing.expect(state.sel < state.rows.len);
}

test "win32 palette: home directory is written as a tilde" {
    const alloc = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "C:/Users/me/src", "C:/Users/me", "~/src" },
        .{ "c:/users/me", "C:/Users/me/", "~" },
        .{ "C:/Users/medium", "C:/Users/me", "C:/Users/medium" },
        .{ "D:/work", "C:/Users/me", "D:/work" },
        .{ "D:/work", "", "D:/work" },
        .{ "C:\\Users\\me\\src", "C:\\Users\\me\\", "~\\src" },
    };
    for (cases) |c| {
        const got = try abbreviatePwd(alloc, c[0], c[1]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c[2], got);
    }
}

test "win32 palette: only the palette's own command block is taken" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    // Another sender's block starts with a different tag: not ours.
    var foreign: Command.Header = .{ .magic = 0x12345678 };
    try std.testing.expect(!command(&owner.window, @bitCast(@intFromPtr(&foreign))));
    try std.testing.expect(Command.fromLparam(@bitCast(@intFromPtr(&foreign))) == null);
    try std.testing.expect(!command(&owner.window, -1));
}

test "win32 palette: profile entries are listed and run their profile" {
    const owner = try TestOwner.create();
    defer owner.destroy();
    const window = &owner.window;
    const cmds = [_]input.Command{
        .{ .action = .{ .text = "hi" }, .title = "Send Text", .description = "" },
    };
    const shells = [_]profiles.Profile{
        .{ .id = "cmd", .name = "Command Prompt", .kind = .cmd, .argv = &.{}, .icon = "" },
        .{ .id = "powershell", .name = "Windows PowerShell", .kind = .powershell, .argv = &.{}, .icon = "" },
    };
    const panel = try begin(window, 1, &cmds, &.{}, &shells, "", null);
    defer close(window);
    const state = &window.palette;

    try std.testing.expectEqual(@as(usize, 5), state.rows.len);
    var tab: ?Run = null;
    var win: ?Run = null;
    for (state.rows) |r| {
        const item = panel.items[r];
        if (std.mem.eql(u8, item.title, "New Tab: Windows PowerShell")) tab = item.run;
        if (std.mem.eql(u8, item.title, "New Window: Command Prompt")) win = item.run;
    }
    try std.testing.expectEqualStrings("powershell", tab.?.profile.id);
    try std.testing.expect(!tab.?.profile.window);
    try std.testing.expectEqualStrings("cmd", win.?.profile.id);
    try std.testing.expect(win.?.profile.window);

    // The queued command owns its copy of the id.
    const id = try std.testing.allocator.dupe(u8, "powershell");
    const cmd = try Command.create(std.testing.allocator, .{ .profile = .{ .serial = 1, .id = id, .window = false } });
    @memset(id, 0xAA);
    std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("powershell", cmd.kind.profile.id);
    cmd.destroy();
}
