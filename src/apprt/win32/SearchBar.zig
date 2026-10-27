//! The search bar overlay of a surface: a panel popup of the overlay host
//! with an EDIT, a "n/m" counter and the buttons next, previous and close,
//! driven by the core search (`search`, `navigate_search`, `end_search`).
//! Sizes and colours follow `SurfaceSearchOverlay` of the macOS app.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
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

const log = std.log.scoped(.win32_search);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const WM_SETFONT = 0x0030;
const EM_SETCUEBANNER = 0x1501;
const DEFAULT_CHARSET = 1;
const CLEARTYPE_QUALITY = 5;
const FW_NORMAL = 400;
const NULL_PEN = 8;
const TRANSPARENT = 1;
const DT_CENTER = 0x1;
const DT_RIGHT = 0x2;
const DT_VCENTER = 0x4;
const DT_SINGLELINE = 0x20;
const DT_NOPREFIX = 0x800;
const subclass_id = 1;

extern "gdi32" fn SetBkMode(user32.HDC, i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(user32.HDC, u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(user32.HDC, u32) callconv(.winapi) u32;
extern "gdi32" fn RoundRect(user32.HDC, i32, i32, i32, i32, i32, i32) callconv(.winapi) i32;
extern "user32" fn DrawTextW(user32.HDC, [*]const u16, i32, *win32.foundation.RECT, u32) callconv(.winapi) i32;

/// Debounce of the query after a keystroke.
const debounce_ms = 50;

/// The search state of a surface.
pub const State = struct {
    popup: ?*overlay.Popup = null,
    edit: ?HWND = null,
    total: ?usize = null,
    selected: ?usize = null,
    /// The query the core search was last given.
    needle: std.ArrayList(u8) = .empty,
};

/// What the heap block of a shown bar holds; `popup` is its first field.
const Panel = struct {
    popup: overlay.Popup,
    surface: *Surface,
    font: ?gdi32.HFONT = null,
    small_font: ?gdi32.HFONT = null,
    icon_font: ?gdi32.HFONT = null,
    font_dpi: u32 = 0,
    brush: ?user32.HBRUSH = null,
    brush_rgb: u32 = 0,
    dark_applied: ?bool = null,
    hot: Part = .none,
    pressed: Part = .none,
    tracking: bool = false,

    fn of(p: *overlay.Popup) *Panel {
        return @fieldParentPtr("popup", p);
    }
};

pub const Part = enum { none, next, previous, close };

pub const KeyAction = enum { next, previous, end, focus_surface };

/// The key a focused EDIT routes to the search: Enter and F3 go to the next
/// match, with Shift to the previous. Esc ends the search when the field is
/// empty and otherwise only gives the focus back to the surface, as on macOS.
pub fn keyAction(vk: usize, shift: bool, empty: bool) ?KeyAction {
    return switch (vk) {
        user32.VK_RETURN, user32.VK_F3 => if (shift) .previous else .next,
        user32.VK_ESCAPE => if (empty) .end else .focus_surface,
        else => null,
    };
}

/// "3/17" for the third of 17 matches, "-/17" with matches but none selected
/// (and "0/0" when there are none), "3/?" while only the selection is known
/// and "" when neither is. `selected` is the
/// zero-based index core reports.
pub fn counterText(buf: []u8, total_: ?usize, selected_: ?usize) []const u8 {
    const text = counterFmt(buf, total_, selected_) catch return "";
    return text;
}

fn counterFmt(buf: []u8, total_: ?usize, selected_: ?usize) std.fmt.BufPrintError![]const u8 {
    if (total_) |t| {
        if (selected_) |s| return std.fmt.bufPrint(buf, "{d}/{d}", .{ s + 1, t });
        if (t == 0) return std.fmt.bufPrint(buf, "0/0", .{});
        return std.fmt.bufPrint(buf, "-/{d}", .{t});
    }
    if (selected_) |s| return std.fmt.bufPrint(buf, "{d}/?", .{s + 1});
    return "";
}

// -- Layout ----------------------------------------------------------------------

/// Sizes at 96 dpi: the macOS bar has 8 pt padding, a 180 pt field with
/// 8 pt / 50 pt text insets and 26 pt high buttons 4 pt apart.
const bar_w = 360;
const bar_h = 40;
const pad = 8;
const field_h = 28;
const field_w = 236;
const edit_h = 20;
const edit_right_inset = 50;
const button_w = 32;
const button_h = 26;
const button_gap = 4;
const field_radius = 6;

pub const Layout = struct {
    field: geom.Rect,
    edit: geom.Rect,
    counter: geom.Rect,
    next: geom.Rect,
    previous: geom.Rect,
    close: geom.Rect,

    pub fn forDpi(dpi: u32) Layout {
        const s = struct {
            fn f(v: i32, d: u32) i32 {
                return geom.scale(v, d);
            }
        }.f;
        const field: geom.Rect = .{ .x = s(pad, dpi), .y = @divTrunc(s(bar_h, dpi) - s(field_h, dpi), 2), .w = s(field_w, dpi), .h = s(field_h, dpi) };
        const by = @divTrunc(s(bar_h, dpi) - s(button_h, dpi), 2);
        const b1 = field.right() + s(button_gap, dpi);
        const bw = s(button_w, dpi);
        const step = bw + s(button_gap, dpi);
        return .{
            .field = field,
            .edit = .{
                .x = field.x + s(pad, dpi),
                .y = field.y + @divTrunc(field.h - s(edit_h, dpi), 2),
                .w = field.w - s(pad, dpi) - s(edit_right_inset, dpi),
                .h = s(edit_h, dpi),
            },
            .counter = .{
                .x = field.right() - s(edit_right_inset, dpi),
                .y = field.y,
                .w = s(edit_right_inset, dpi) - s(pad, dpi),
                .h = field.h,
            },
            .next = .{ .x = b1, .y = by, .w = bw, .h = s(button_h, dpi) },
            .previous = .{ .x = b1 + step, .y = by, .w = bw, .h = s(button_h, dpi) },
            .close = .{ .x = b1 + 2 * step, .y = by, .w = bw, .h = s(button_h, dpi) },
        };
    }

    pub fn hit(l: Layout, x: i32, y: i32) Part {
        if (l.next.contains(x, y)) return .next;
        if (l.previous.contains(x, y)) return .previous;
        if (l.close.contains(x, y)) return .close;
        return .none;
    }
};

// -- Colours ---------------------------------------------------------------------

pub const Colors = struct {
    bg: theme.Color,
    text: theme.Color,
    secondary: theme.Color,
    field: theme.Color,
    hover: theme.Color,
    pressed: theme.Color,
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

/// The system window background and label colours as the resize overlay
/// takes them; the field and hover fills are `Color.primary` at 0.1 and
/// 0.2 opacity, the counter and idle glyphs `.secondary`.
pub fn colors(pal: theme.Palette) Colors {
    var bg: theme.Color = undefined;
    var text: theme.Color = undefined;
    if (theme.highContrast()) {
        bg = pal.tab_active_bg;
        text = pal.text;
    } else {
        bg = if (pal.dark) .{ .r = 0x32, .g = 0x32, .b = 0x32 } else .{ .r = 0xEC, .g = 0xEC, .b = 0xEC };
        text = if (pal.dark) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } else .{ .r = 0, .g = 0, .b = 0 };
    }
    return .{
        .bg = bg,
        .text = text,
        .secondary = mix(bg, text, 0.6),
        .field = mix(bg, text, 0.1),
        .hover = mix(bg, text, 0.1),
        .pressed = mix(bg, text, 0.2),
    };
}

fn colorRef(c: theme.Color) u32 {
    return @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
}

// -- Actions ---------------------------------------------------------------------

fn surfaceOf(app: *App, target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core| app.surfaceFor(core),
    };
}

pub fn start(app: *App, target: apprt.Target, value: apprt.Action.Value(.start_search)) bool {
    const surface = surfaceOf(app, target) orelse return false;
    show(surface, value.needle) catch |err| {
        log.warn("unable to show the search bar err={}", .{err});
        return false;
    };
    return true;
}

pub fn end(app: *App, target: apprt.Target, value: apprt.Action.Value(.end_search)) bool {
    _ = value;
    const surface = surfaceOf(app, target) orelse return false;
    const state = &surface.search;
    state.total = null;
    state.selected = null;
    state.needle.clearRetainingCapacity();
    const popup = state.popup orelse return true;

    // The focus goes back first: hiding the panel that has it would hand
    // the activation to whatever window comes next.
    if (state.edit) |edit| {
        if (user32.GetFocus() == edit) _ = user32.SetFocus(surface.hwnd);
        _ = user32.SetWindowTextW(edit, L(""));
    }
    popup.hide();
    return true;
}

pub fn total(app: *App, target: apprt.Target, value: apprt.Action.Value(.search_total)) bool {
    const surface = surfaceOf(app, target) orelse return false;
    const state = &surface.search;
    state.total = value.total;
    if (state.popup) |p| p.invalidate();
    return true;
}

pub fn selected(app: *App, target: apprt.Target, value: apprt.Action.Value(.search_selected)) bool {
    const surface = surfaceOf(app, target) orelse return false;
    const state = &surface.search;
    state.selected = value.selected;
    if (state.popup) |p| p.invalidate();
    return true;
}

fn show(surface: *Surface, needle: []const u8) !void {
    const window = surface.window;
    const state = &surface.search;
    const alloc = window.app.core_app.alloc;

    const panel: *Panel = if (state.popup) |p| Panel.of(p) else blk: {
        const panel = try alloc.create(Panel);
        errdefer alloc.destroy(panel);
        panel.* = .{
            .popup = .{
                .kind = .panel,
                .anchor = .surface_top_right,
                .window = window,
                .surface = surface,
                .size = .{ .w = bar_w, .h = bar_h },
                .paint = paintPopup,
                .on_message = onMessage,
            },
            .surface = surface,
        };
        state.popup = &panel.popup;
        break :blk panel;
    };
    const p = &panel.popup;
    // A popup whose window went away (the owner was destroyed) lost its EDIT.
    if (p.hwnd == null) state.edit = null;
    p.surface = surface;

    overlay.beginPanelActivation(window);
    try p.show();
    const hwnd = p.hwnd orelse return error.CreateWindowFailed;
    const edit = state.edit orelse try createEdit(panel, hwnd);
    state.edit = edit;

    if (needle.len > 0) {
        const wide = try util.utf16z(alloc, needle);
        defer alloc.free(wide);
        _ = user32.SetWindowTextW(edit, wide);
    }
    layoutChildren(panel);
    _ = user32.SendMessageW(edit, user32.EM_SETSEL, 0, -1);
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
        log.warn("unable to create the search EDIT err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = user32.DestroyWindow(edit);
    _ = user32.SendMessageW(edit, EM_SETCUEBANNER, 0, @bitCast(@intFromPtr(L("Search"))));
    if (comctl32.SetWindowSubclass(edit, editProc, subclass_id, @intFromPtr(panel)) == 0) {
        log.warn("unable to subclass the search EDIT", .{});
    }
    return edit;
}

/// Fonts, EDIT place and theme for the panel's current dpi and palette.
fn layoutChildren(panel: *Panel) void {
    const p = &panel.popup;
    const window = p.window;
    const edit = panel.surface.search.edit orelse return;
    const dpi = window.dpi;
    const pal = theme.palette(window);

    if (panel.font_dpi != dpi) {
        // The EDIT gets the new font before the old one is deleted.
        const old = [3]?gdi32.HFONT{ panel.font, panel.small_font, panel.icon_font };
        panel.font = makeFont(14, dpi, L("Segoe UI"));
        panel.small_font = makeFont(11, dpi, L("Segoe UI"));
        panel.icon_font = makeFont(12, dpi, L("Segoe Fluent Icons"));
        panel.font_dpi = dpi;
        if (panel.font) |f| _ = user32.SendMessageW(edit, WM_SETFONT, @intFromPtr(f), 1);
        for (old) |h| if (h) |o| {
            _ = gdi32.DeleteObject(@ptrCast(o));
        };
    }
    if (panel.dark_applied != pal.dark) {
        panel.dark_applied = pal.dark;
        _ = uxtheme.SetWindowTheme(edit, if (pal.dark) L("DarkMode_Explorer") else L("Explorer"), null);
    }
    const l = Layout.forDpi(dpi);
    _ = user32.MoveWindow(edit, l.edit.x, l.edit.y, l.edit.w, l.edit.h, 1);
}

fn makeFont(px: i32, dpi: u32, face: [*:0]const u16) ?gdi32.HFONT {
    return gdi32.CreateFontW(-geom.scale(px, dpi), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, face);
}

fn freeFonts(panel: *Panel) void {
    inline for (.{ &panel.font, &panel.small_font, &panel.icon_font }) |f| {
        if (f.*) |h| _ = gdi32.DeleteObject(@ptrCast(h));
        f.* = null;
    }
}

pub fn surfaceDestroying(surface: *Surface) void {
    const state = &surface.search;
    const alloc = surface.window.app.core_app.alloc;
    if (state.popup) |p| {
        const panel = Panel.of(p);
        // Takes the window (and its EDIT) down unless the host already did.
        p.destroy();
        freeFonts(panel);
        if (panel.brush) |b| _ = gdi32.DeleteObject(@ptrCast(b));
        alloc.destroy(panel);
    }
    state.popup = null;
    state.edit = null;
    state.needle.deinit(alloc);
    state.needle = .empty;
}

/// `WM_GHOSTTY_OVERLAY_CMD` on a top-level window; true when the command
/// was for the search bar. The bar takes none.
pub fn command(window: *Window, lparam: win32.foundation.LPARAM) bool {
    _ = window;
    _ = lparam;
    return false;
}

// -- Core --------------------------------------------------------------------------

fn perform(surface: *Surface, action: input.Binding.Action) void {
    _ = surface.core_surface.performBindingAction(action) catch |err| {
        log.warn("unable to perform a search binding action err={}", .{err});
    };
}

fn run(panel: *Panel, action: KeyAction) void {
    const surface = panel.surface;
    switch (action) {
        .next => perform(surface, .{ .navigate_search = .next }),
        .previous => perform(surface, .{ .navigate_search = .previous }),
        .end => perform(surface, .end_search),
        .focus_surface => _ = user32.SetFocus(surface.hwnd),
    }
}

/// Sends the EDIT's text to the core search when it changed.
fn sendQuery(panel: *Panel) void {
    const surface = panel.surface;
    const state = &surface.search;
    const edit = state.edit orelse return;
    const alloc = surface.window.app.core_app.alloc;

    const len: usize = @intCast(@max(user32.GetWindowTextLengthW(edit), 0));
    const wide = alloc.alloc(u16, len + 1) catch return;
    defer alloc.free(wide);
    const got: usize = @intCast(@max(user32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    const text = util.utf8(alloc, wide[0..got]) catch |err| {
        log.warn("unable to convert the search text err={}", .{err});
        return;
    };
    defer alloc.free(text);

    if (std.mem.eql(u8, text, state.needle.items)) return;
    state.needle.clearRetainingCapacity();
    state.needle.appendSlice(alloc, text) catch return;
    if (text.len == 0) {
        // Core stops the search without reporting; the counter resets here.
        state.total = null;
        state.selected = null;
        panel.popup.invalidate();
    }
    perform(surface, .{ .search = text });
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
            const shift = user32.GetKeyState(user32.VK_SHIFT) < 0;
            const empty = user32.GetWindowTextLengthW(hwnd) == 0;
            if (keyAction(wparam, shift, empty)) |action| {
                run(panel, action);
                return 0;
            }
        },
        // Enter and Esc as characters would only beep.
        user32.WM_CHAR => if (wparam == '\r' or wparam == 0x1B) return 0,
        user32.WM_NCDESTROY => _ = comctl32.RemoveWindowSubclass(hwnd, editProc, id),
        else => {},
    }
    return comctl32.DefSubclassProc(hwnd, msg, wparam, lparam);
}

fn onMessage(p: *overlay.Popup, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    const panel = Panel.of(p);
    const hwnd = p.hwnd orelse return null;
    switch (msg) {
        // The host resized the panel (dpi change): fonts and EDIT follow.
        user32.WM_SIZE => {
            layoutChildren(panel);
            return null;
        },
        user32.WM_COMMAND => {
            const edit = panel.surface.search.edit orelse return null;
            if (@as(usize, @bitCast(lparam)) != @intFromPtr(edit)) return null;
            if (user32.hiWord(wparam) == user32.EN_CHANGE) {
                _ = user32.SetTimer(hwnd, messages.timers.overlay.search_debounce, debounce_ms, null);
            }
            return 0;
        },
        user32.WM_TIMER => if (wparam == messages.timers.overlay.search_debounce) {
            _ = user32.KillTimer(hwnd, messages.timers.overlay.search_debounce);
            sendQuery(panel);
            return 0;
        },
        user32.WM_CTLCOLOREDIT => {
            const c = colors(theme.palette(p.window));
            const hdc: user32.HDC = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, colorRef(c.text));
            _ = SetBkColor(hdc, colorRef(c.field));
            return fieldBrush(panel, c.field);
        },
        user32.WM_MOUSEMOVE => {
            const part = Layout.forDpi(p.window.dpi).hit(user32.getXLparam(lparam), user32.getYLparam(lparam));
            if (!panel.tracking) {
                var tme: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE, .hwndTrack = hwnd };
                panel.tracking = user32.TrackMouseEvent(&tme) != 0;
            }
            setHot(panel, part);
            return 0;
        },
        user32.WM_MOUSELEAVE => {
            panel.tracking = false;
            setHot(panel, .none);
            return 0;
        },
        user32.WM_SETCURSOR => if (panel.hot != .none and (lparam & 0xFFFF) == 1) {
            _ = user32.SetCursor(user32.LoadCursorW(null, user32.IDC_HAND));
            return 1;
        },
        user32.WM_LBUTTONDOWN => {
            const part = Layout.forDpi(p.window.dpi).hit(user32.getXLparam(lparam), user32.getYLparam(lparam));
            if (part != .none) {
                panel.pressed = part;
                _ = user32.SetCapture(hwnd);
                p.invalidate();
            }
            return 0;
        },
        user32.WM_LBUTTONUP => {
            const was = panel.pressed;
            if (was == .none) return 0;
            panel.pressed = .none;
            _ = user32.ReleaseCapture();
            p.invalidate();
            const part = Layout.forDpi(p.window.dpi).hit(user32.getXLparam(lparam), user32.getYLparam(lparam));
            if (part != was) return 0;
            switch (part) {
                // As on macOS the chevron up is the next match.
                .next => run(panel, .next),
                .previous => run(panel, .previous),
                .close => run(panel, .end),
                .none => {},
            }
            if (part != .close) if (panel.surface.search.edit) |e| {
                _ = user32.SetFocus(e);
            };
            return 0;
        },
        user32.WM_CAPTURECHANGED => {
            panel.pressed = .none;
            p.invalidate();
            return 0;
        },
        else => {},
    }
    return null;
}

fn setHot(panel: *Panel, part: Part) void {
    if (panel.hot == part) return;
    panel.hot = part;
    panel.popup.invalidate();
}

/// The brush behind the EDIT text, kept for the colour it was made for.
fn fieldBrush(panel: *Panel, c: theme.Color) LRESULT {
    const rgb = colorRef(c);
    if (panel.brush == null or panel.brush_rgb != rgb) {
        if (panel.brush) |old| _ = gdi32.DeleteObject(@ptrCast(old));
        panel.brush = gdi32.CreateSolidBrush(rgb);
        panel.brush_rgb = rgb;
    }
    return if (panel.brush) |b| @bitCast(@intFromPtr(b)) else 0;
}

// -- Paint -------------------------------------------------------------------------

fn paintPopup(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const panel = Panel.of(p);

    const c = colors(ctx.palette);
    const l = Layout.forDpi(ctx.dpi);
    const hdc = ctx.hdc;

    fillRect(hdc, .{ .x = 0, .y = 0, .w = ctx.rect.w, .h = ctx.rect.h }, c.bg);

    const r = geom.scale(field_radius, ctx.dpi);
    roundFill(hdc, l.field, r, c.field);

    _ = SetBkMode(hdc, TRANSPARENT);
    const state = &panel.surface.search;

    var buf: [48]u8 = undefined;
    const text = counterText(&buf, state.total, state.selected);
    if (text.len > 0) {
        var wide: [48]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, text) catch 0;
        drawText(hdc, panel.small_font, wide[0..n], l.counter, c.secondary, DT_RIGHT);
    }

    const buttons = [_]struct { part: Part, rect: geom.Rect, glyph: []const u16 }{
        .{ .part = .next, .rect = l.next, .glyph = L("\u{E70E}") },
        .{ .part = .previous, .rect = l.previous, .glyph = L("\u{E70D}") },
        .{ .part = .close, .rect = l.close, .glyph = L("\u{E711}") },
    };
    for (buttons) |b| {
        const down = panel.pressed == b.part;
        const over = panel.hot == b.part;
        if (down) roundFill(hdc, b.rect, r, c.pressed) else if (over) roundFill(hdc, b.rect, r, c.hover);
        drawText(hdc, panel.icon_font, b.glyph, b.rect, if (down or over) c.text else c.secondary, DT_CENTER);
    }
}

fn fillRect(hdc: user32.HDC, r: geom.Rect, c: theme.Color) void {
    const brush = gdi32.CreateSolidBrush(colorRef(c)) orelse return;
    defer _ = gdi32.DeleteObject(@ptrCast(brush));
    _ = gdi32.FillRect(hdc, &r.toRECT(), brush);
}

fn roundFill(hdc: user32.HDC, r: geom.Rect, radius: i32, c: theme.Color) void {
    const brush = gdi32.CreateSolidBrush(colorRef(c)) orelse return;
    defer _ = gdi32.DeleteObject(@ptrCast(brush));
    const old_brush = gdi32.SelectObject(hdc, @ptrCast(brush));
    const old_pen = gdi32.SelectObject(hdc, gdi32.GetStockObject(NULL_PEN) orelse return);
    _ = RoundRect(hdc, r.x, r.y, r.right() + 1, r.bottom() + 1, 2 * radius, 2 * radius);
    if (old_pen) |o| _ = gdi32.SelectObject(hdc, o);
    if (old_brush) |o| _ = gdi32.SelectObject(hdc, o);
}

fn drawText(hdc: user32.HDC, font: ?gdi32.HFONT, text: []const u16, r: geom.Rect, c: theme.Color, align_flag: u32) void {
    const old = if (font) |f| gdi32.SelectObject(hdc, @ptrCast(f)) else null;
    defer if (old) |o| {
        _ = gdi32.SelectObject(hdc, o);
    };
    _ = SetTextColor(hdc, colorRef(c));
    var rc = r.toRECT();
    _ = DrawTextW(hdc, text.ptr, @intCast(text.len), &rc, align_flag | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
}

// -- Test state --------------------------------------------------------------------

/// The IPC `state` view: the bar of the focused surface of the first window
/// that has one.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    for (app.windows.items) |window| {
        const tab = window.activeTab() orelse continue;
        const surface = tab.focusedSurface() orelse continue;
        const state = &surface.search;
        const p = state.popup orelse continue;
        const hwnd = p.hwnd;
        try jw.objectField("visible");
        try jw.write(if (hwnd) |h| user32.IsWindowVisible(h) != 0 else false);
        try jw.objectField("focused");
        try jw.write(if (state.edit) |e| user32.GetFocus() == e else false);
        try jw.objectField("total");
        try jw.write(state.total);
        try jw.objectField("selected");
        try jw.write(state.selected);
        try jw.objectField("needle");
        try jw.write(state.needle.items);
        break;
    }
    try jw.endObject();
}

// -- Tests -------------------------------------------------------------------------

test "win32 search: counter text" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("3/17", counterText(&buf, 17, 2));
    try std.testing.expectEqualStrings("1/1", counterText(&buf, 1, 0));
    try std.testing.expectEqualStrings("0/0", counterText(&buf, 0, null));
    try std.testing.expectEqualStrings("-/5", counterText(&buf, 5, null));
    try std.testing.expectEqualStrings("", counterText(&buf, null, null));
    try std.testing.expectEqualStrings("4/?", counterText(&buf, null, 3));
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqualStrings("", counterText(&tiny, 100, 5));
}

test "win32 search: key routing" {
    try std.testing.expectEqual(KeyAction.next, keyAction(user32.VK_RETURN, false, false).?);
    try std.testing.expectEqual(KeyAction.previous, keyAction(user32.VK_RETURN, true, false).?);
    try std.testing.expectEqual(KeyAction.next, keyAction(user32.VK_F3, false, false).?);
    try std.testing.expectEqual(KeyAction.previous, keyAction(user32.VK_F3, true, false).?);
    try std.testing.expectEqual(KeyAction.end, keyAction(user32.VK_ESCAPE, false, true).?);
    try std.testing.expectEqual(KeyAction.end, keyAction(user32.VK_ESCAPE, true, true).?);
    try std.testing.expectEqual(KeyAction.focus_surface, keyAction(user32.VK_ESCAPE, false, false).?);
    try std.testing.expect(keyAction('A', false, false) == null);
    try std.testing.expect(keyAction(user32.VK_SHIFT, true, false) == null);
}

test "win32 search: layout fits the bar" {
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const l = Layout.forDpi(dpi);
        const w = geom.scale(bar_w, dpi);
        const h = geom.scale(bar_h, dpi);
        try std.testing.expect(l.close.right() <= w);
        try std.testing.expect(l.field.right() < l.next.x);
        try std.testing.expect(l.next.right() < l.previous.x);
        try std.testing.expect(l.previous.right() < l.close.x);
        try std.testing.expect(l.field.bottom() <= h and l.close.bottom() <= h);
        try std.testing.expect(l.edit.x >= l.field.x and l.edit.right() <= l.counter.x);
        try std.testing.expectEqual(Part.previous, l.hit(l.previous.x + 1, l.previous.y + 1));
        try std.testing.expectEqual(Part.none, l.hit(l.field.x + 1, l.field.y + 1));
    }
    const l = Layout.forDpi(96);
    try std.testing.expectEqual(@as(i32, 360), l.close.right() + pad);
}
