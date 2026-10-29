//! In-place title editor: a borderless themed popup over a tab, the caption or
//! the title area, holding an EDIT (R-M7-4). The popup is an overlay `.panel`
//! (owned, opaque, activation bookkeeping of the SearchBar pattern); the EDIT
//! looks like the tab label made editable: the tab's fill, its title colour
//! and font, centred. Enter commits, Esc and focus loss cancel.
//! The EDIT only posts `WM_GHOSTTY_TITLE_EDIT_DONE`; `strip_input.handle`
//! consumes it, reads the text and takes the popup down, so the control is
//! never destroyed from inside its own procedure.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");
const Chrome = @import("Chrome.zig");
const util = @import("util.zig");

const user32 = win32.user32;
const comctl32 = win32.comctl32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;
const HWND = win32.foundation.HWND;

const log = std.log.scoped(.win32_title_edit);

const WM_SETFONT = 0x0030;
const EM_SETSEL = 0x00B1;
const ES_CENTER = 0x0001;
const FW_NORMAL = 400;
const DEFAULT_CHARSET = 1;
const CLEARTYPE_QUALITY = 5;
const subclass_id = 1;

extern "gdi32" fn SetTextColor(user32.HDC, u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(user32.HDC, u32) callconv(.winapi) u32;

pub const Kind = enum { surface, tab, window };

/// What the heap block of an open editor holds; `popup` is its first field.
const Panel = struct {
    popup: overlay.Popup,
    alloc: std.mem.Allocator,
    /// The popup's rect in the window's client coordinates.
    rect: geom.Rect,
    edit: ?HWND = null,
    font: ?win32.gdi32.HFONT = null,
    brush: ?user32.HBRUSH = null,
    brush_rgb: u32 = 0,

    fn of(p: *overlay.Popup) *Panel {
        return @fieldParentPtr("popup", p);
    }
};

/// The editor of a window, kept in `strip_input.State`.
pub const Session = struct {
    /// The EDIT, a child of the popup.
    hwnd: HWND,
    /// The borderless popup that holds it.
    popup_hwnd: HWND,
    panel: *Panel,
    kind: Kind,
    /// The tab or surface being renamed (0 for the window).
    target_id: u32,
    /// Set once Enter, Esc or the focus loss posted the result.
    done: bool = false,
};

/// Trims the text; empty becomes null, which clears the title.
pub fn normalize(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Drops the CR and LF bytes in place, returning the shortened text.
fn removeLineBreaks(buf: []u8) []u8 {
    var n: usize = 0;
    for (buf) |c| {
        if (c == '\r' or c == '\n') continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// The tab's rect in the window's client coordinates (`editorRect` insets it).
pub fn tabRect(window: *const Window, index: usize) ?geom.Rect {
    if (index >= window.strip.tabs.items.len) return null;
    return window.strip.tabs.items[index];
}

/// The tab title size, in px at 96 dpi (`Chrome` `tab_pt`).
const font_px = 11;
/// The horizontal inset of the text, as on macOS, in px at 96 dpi.
const inset_px = 6;
/// The height of the popup, in px at 96 dpi.
const popup_h_px = 22;

/// The popup rect for an editor over `area` (a tab, the caption or the
/// title area), in the same coordinates: inset horizontally, one text line
/// tall, centred vertically on the area.
pub fn editorRect(area: geom.Rect, dpi: u32) geom.Rect {
    const inset = geom.scale(inset_px, dpi);
    const h = @min(geom.scale(popup_h_px, dpi), @max(area.h, 1));
    return .{
        .x = area.x + inset,
        .y = area.y + @divFloor(area.h - h, 2),
        .w = @max(area.w - 2 * inset, geom.scale(20, dpi)),
        .h = h,
    };
}

/// The height of one text line of the editor font.
fn lineHeight(dpi: u32) i32 {
    return @divFloor(geom.scale(font_px, dpi) * 4 + 1, 3);
}

/// The EDIT's colours: the tab's own fill and title colour.
pub const Colors = struct {
    field: theme.Color,
    text: theme.Color,
};

pub fn colorsFor(pal: theme.Palette) Colors {
    // The title colour is translucent ink; the popup is opaque.
    return .{ .field = pal.tab_active_bg, .text = Chrome.blend(pal.text, pal.tab_active_bg) };
}

fn colorRef(c: theme.Color) u32 {
    return @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
}

/// The editor rect for the window and surface titles: the title area, else
/// the caption, else the active tab.
pub fn titleRect(window: *const Window) geom.Rect {
    const pad = geom.scale(4, window.dpi);
    const r: geom.Rect = if (window.strip.title) |t|
        t
    else if (window.strip.caption.w > 0)
        window.strip.caption
    else if (tabRect(window, window.active_tab)) |tr|
        return tr
    else
        window.strip.bounds;
    return .{
        .x = r.x,
        .y = pad,
        .w = @max(r.w, geom.scale(20, window.dpi)),
        .h = @max(r.h - 2 * pad, 1),
    };
}

/// Opens the editor for the active tab (`.tab`), its focused surface
/// (`.surface`) or the window.
pub fn begin(window: *Window, kind: Kind, rect: geom.Rect, initial: []const u8) void {
    const id: u32 = switch (kind) {
        .window => 0,
        .tab => if (window.activeTab()) |t| t.id else 0,
        .surface => if (window.activeTab()) |t| (if (t.focusedSurface()) |s| s.id else 0) else 0,
    };
    beginFor(window, kind, id, rect, initial);
}

pub fn beginFor(window: *Window, kind: Kind, target_id: u32, area: geom.Rect, initial: []const u8) void {
    cancel(window);
    const alloc = window.app.core_app.alloc;

    const wide = util.utf16z(alloc, initial) catch |err| {
        log.warn("unable to convert the title err={}", .{err});
        return;
    };
    defer alloc.free(wide);

    const panel = alloc.create(Panel) catch |err| {
        log.warn("unable to allocate the title editor err={}", .{err});
        return;
    };
    const rect = editorRect(area, window.dpi);
    panel.* = .{
        .popup = .{
            .kind = .panel,
            .anchor = .window_top_center,
            .window = window,
            .size = .{ .w = 1, .h = 1 },
            .paint = paintPopup,
            .on_message = onMessage,
            .place = place,
        },
        .alloc = alloc,
        .rect = rect,
    };
    const p = &panel.popup;

    overlay.beginPanelActivation(window);
    p.show() catch |err| {
        log.warn("unable to show the title editor err={}", .{err});
        alloc.destroy(panel);
        return;
    };
    const popup_hwnd = p.hwnd orelse {
        alloc.destroy(panel);
        return;
    };
    // The panel rounds its corners; a label made editable is square.
    const square: i32 = win32.dwmapi.DWMWCP_DONOTROUND;
    _ = win32.dwmapi.DwmSetWindowAttribute(popup_hwnd, win32.dwmapi.DWMWA_WINDOW_CORNER_PREFERENCE, &square, @sizeOf(i32));

    const hwnd = user32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        wide,
        user32.WS_CHILD | user32.WS_VISIBLE | user32.ES_AUTOHSCROLL | ES_CENTER,
        0,
        0,
        rect.w,
        rect.h,
        popup_hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.warn("unable to create the title editor err={}", .{win32.kernel32.GetLastError()});
        p.destroy();
        alloc.destroy(panel);
        return;
    };
    panel.edit = hwnd;

    const family = if (Chrome.shared()) |sh| sh.title_family else |_| std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    panel.font = win32.gdi32.CreateFontW(
        -geom.scale(font_px, window.dpi),
        0,
        0,
        0,
        FW_NORMAL,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        0,
        0,
        CLEARTYPE_QUALITY,
        0,
        family,
    );
    if (panel.font) |f| _ = user32.SendMessageW(hwnd, WM_SETFONT, @intFromPtr(f), 1);
    layoutEdit(panel, window.dpi);

    if (comctl32.SetWindowSubclass(hwnd, editProc, subclass_id, @intFromPtr(window)) == 0) {
        log.warn("unable to subclass the title editor", .{});
    }
    window.strip_input.edit = .{ .hwnd = hwnd, .popup_hwnd = popup_hwnd, .panel = panel, .kind = kind, .target_id = target_id };

    _ = user32.SendMessageW(hwnd, EM_SETSEL, 0, -1);
    _ = user32.SetFocus(hwnd);
}

/// The EDIT is one text line tall, centred in the popup.
fn layoutEdit(panel: *Panel, dpi: u32) void {
    const edit = panel.edit orelse return;
    const h = @min(lineHeight(dpi), panel.rect.h);
    _ = user32.MoveWindow(edit, 0, @divFloor(panel.rect.h - h, 2), panel.rect.w, h, 1);
}

/// The popup sits at its rect in the window's client area; `client` is that
/// area on screen.
fn place(p: *overlay.Popup, client: geom.Rect, size_px: geom.Size) geom.Rect {
    _ = size_px;
    const r = Panel.of(p).rect;
    return .{ .x = client.x + r.x, .y = client.y + r.y, .w = r.w, .h = r.h };
}

/// The popup paints the tab's fill; the EDIT covers the rest.
fn paintPopup(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    _ = p;
    const c = colorsFor(ctx.palette);
    const brush = win32.gdi32.CreateSolidBrush(colorRef(c.field)) orelse return;
    defer _ = win32.gdi32.DeleteObject(@ptrCast(brush));
    const rc = ctx.rect.toRECT();
    _ = win32.gdi32.FillRect(ctx.hdc, &rc, brush);
}

fn onMessage(p: *overlay.Popup, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = lparam;
    const panel = Panel.of(p);
    switch (msg) {
        user32.WM_CTLCOLOREDIT => {
            const c = colorsFor(theme.palette(p.window));
            const hdc: user32.HDC = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, colorRef(c.text));
            _ = SetBkColor(hdc, colorRef(c.field));
            const rgb = colorRef(c.field);
            if (panel.brush == null or panel.brush_rgb != rgb) {
                if (panel.brush) |old| _ = win32.gdi32.DeleteObject(@ptrCast(old));
                panel.brush = win32.gdi32.CreateSolidBrush(rgb);
                panel.brush_rgb = rgb;
            }
            return if (panel.brush) |b| @bitCast(@intFromPtr(b)) else 0;
        },
        else => return null,
    }
}

/// The IPC test state of the editor: `{open, popup, edit, rect}`, the rect
/// in screen pixels.
pub fn writeState(jw: *std.json.Stringify, window: *const Window) !void {
    try jw.beginObject();
    const s = window.strip_input.edit;
    try jw.objectField("open");
    try jw.write(s != null);
    try jw.objectField("popup");
    if (s) |v| try writeHwnd(jw, v.popup_hwnd) else try jw.write(null);
    try jw.objectField("edit");
    if (s) |v| try writeHwnd(jw, v.hwnd) else try jw.write(null);
    try jw.objectField("rect");
    if (s) |v| {
        var rc: win32.foundation.RECT = undefined;
        _ = user32.GetWindowRect(v.popup_hwnd, &rc);
        try jw.write([4]i32{ rc.left, rc.top, rc.right, rc.bottom });
    } else try jw.write(null);
    try jw.endObject();
}

fn writeHwnd(jw: *std.json.Stringify, hwnd: HWND) !void {
    var buf: [32]u8 = undefined;
    try jw.write(try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(hwnd)}));
}

/// `prompt_title`: the editor over the tab, or over the title area for the
/// surface and the window.
pub fn prompt(app: *App, target: apprt.Target, value: apprt.Action.Value(.prompt_title)) bool {
    const core = switch (target) {
        .app => return false,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return false;
    const window = surface.window;
    switch (value) {
        .tab => {
            const rect = if (window.tabIndex(surface.tab)) |i|
                tabRect(window, i) orelse titleRect(window)
            else
                titleRect(window);
            beginFor(window, .tab, surface.tab.id, rect, surface.tab.title());
        },
        .surface => beginFor(window, .surface, surface.id, titleRect(window), surface.getTitle() orelse ""),
        .window => {
            const initial: []const u8 = if (window.title_override) |t|
                t
            else if (window.activeTab()) |t|
                t.title()
            else
                "";
            beginFor(window, .window, 0, titleRect(window), initial);
        },
    }
    return true;
}

/// Takes the editor down when it edits `tab` or a surface of it (the tab
/// is being removed).
pub fn cancelForTab(window: *Window, tab: *const Tab) void {
    const s = window.strip_input.edit orelse return;
    const affected = switch (s.kind) {
        .window => false,
        .tab => s.target_id == tab.id,
        .surface => blk: {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.id == s.target_id) break :blk true;
            }
            break :blk false;
        },
    };
    if (affected) cancel(window);
}

/// Takes the editor down when it edits `surface` (it is being removed).
pub fn cancelForSurface(window: *Window, surface: *const Surface) void {
    const s = window.strip_input.edit orelse return;
    if (s.kind == .surface and s.target_id == surface.id) cancel(window);
}

/// Takes the editor down without applying anything.
pub fn cancel(window: *Window) void {
    const s = window.strip_input.edit orelse return;
    window.strip_input.edit = null;
    teardown(s);
}

fn teardown(s: Session) void {
    // The subclass goes first: destroying the focused control sends
    // WM_KILLFOCUS, which must not post another result.
    _ = comctl32.RemoveWindowSubclass(s.hwnd, editProc, subclass_id);
    const panel = s.panel;
    // Takes the popup and its EDIT down unless the host already did.
    panel.popup.destroy();
    if (panel.font) |f| _ = win32.gdi32.DeleteObject(@ptrCast(f));
    if (panel.brush) |b| _ = win32.gdi32.DeleteObject(@ptrCast(b));
    panel.alloc.destroy(panel);
}

/// The result of the editor `hwnd` arrived: applies the text when committed
/// and takes the editor down. Stale results (an editor that is already
/// gone) are ignored.
pub fn complete(window: *Window, hwnd: LPARAM, commit: bool) void {
    const s = window.strip_input.edit orelse return;
    if (@as(isize, @bitCast(@intFromPtr(s.hwnd))) != hwnd) return;

    const alloc = window.app.core_app.alloc;
    var text: ?[]u8 = null;
    defer if (text) |t| alloc.free(t);
    if (commit) text = readText(alloc, s.hwnd);

    window.strip_input.edit = null;
    teardown(s);

    if (text) |t| apply(window, s.kind, s.target_id, normalize(removeLineBreaks(t)) orelse "");
}

fn readText(alloc: std.mem.Allocator, hwnd: HWND) ?[]u8 {
    const len: usize = @intCast(@max(user32.GetWindowTextLengthW(hwnd), 0));
    const wide = alloc.alloc(u16, len + 1) catch return null;
    defer alloc.free(wide);
    const got: usize = @intCast(@max(user32.GetWindowTextW(hwnd, wide.ptr, @intCast(wide.len)), 0));
    return util.utf8(alloc, wide[0..got]) catch |err| {
        log.warn("unable to convert the edited title err={}", .{err});
        return null;
    };
}

/// Sets the title of the target; empty clears it.
fn apply(window: *Window, kind: Kind, id: u32, title: []const u8) void {
    switch (kind) {
        .window => window.setTitleOverride(title) catch |err| log.warn("unable to set the window title err={}", .{err}),
        .tab => for (window.tabs.items) |tab| {
            if (tab.id != id) continue;
            window.setTabTitle(tab, title) catch |err| log.warn("unable to set the tab title err={}", .{err});
            break;
        },
        .surface => {
            const surface = window.findSurface(id) orelse return;
            surface.setUserTitle(title) catch |err| {
                log.warn("unable to set the surface title err={}", .{err});
                return;
            };
            window.surfaceTitleChanged(surface);
        },
    }
}

fn finish(window: *Window, hwnd: HWND, commit: bool) void {
    const s = &(window.strip_input.edit orelse return);
    if (s.hwnd != hwnd or s.done) return;
    s.done = true;
    _ = user32.PostMessageW(
        window.hwnd,
        messages.WM_GHOSTTY_TITLE_EDIT_DONE,
        @intFromBool(commit),
        @bitCast(@intFromPtr(hwnd)),
    );
}

fn editProc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    id: usize,
    ref_data: usize,
) callconv(.winapi) LRESULT {
    const window: *Window = @ptrFromInt(ref_data);
    switch (msg) {
        user32.WM_KEYDOWN => switch (wparam) {
            user32.VK_RETURN => {
                finish(window, hwnd, true);
                return 0;
            },
            user32.VK_ESCAPE => {
                finish(window, hwnd, false);
                return 0;
            },
            else => {},
        },
        // Enter and Esc as characters would only beep.
        user32.WM_CHAR => if (wparam == '\r' or wparam == 0x1B) return 0,
        user32.WM_KILLFOCUS => finish(window, hwnd, false),
        user32.WM_NCDESTROY => _ = comctl32.RemoveWindowSubclass(hwnd, editProc, id),
        else => {},
    }
    return comctl32.DefSubclassProc(hwnd, msg, wparam, lparam);
}

test "win32 title edit: commit text normalisation" {
    const testing = std.testing;
    try testing.expectEqualStrings("renamed", normalize("renamed").?);
    try testing.expectEqualStrings("a b", normalize("  a b \t").?);
    try testing.expectEqualStrings("x", normalize("x\r\n").?);
    try testing.expect(normalize("") == null);
    try testing.expect(normalize("  \r\n ") == null);

    var buf = "a\r\nb\rc".*;
    try testing.expectEqualStrings("abc", removeLineBreaks(&buf));
}

test "win32 title edit: rect inset and centring" {
    const testing = std.testing;
    for ([_]u32{ 96, 144 }) |dpi| {
        const tab: geom.Rect = .{ .x = 100, .y = 8, .w = geom.scale(200, dpi), .h = geom.scale(34, dpi) };
        const r = editorRect(tab, dpi);
        const inset = geom.scale(6, dpi);
        try testing.expectEqual(tab.x + inset, r.x);
        try testing.expectEqual(tab.w - 2 * inset, r.w);
        try testing.expectEqual(geom.scale(22, dpi), r.h);
        // Centred: the room above and below differs by at most one px.
        const above = r.y - tab.y;
        const below = tab.bottom() - r.bottom();
        try testing.expect(above >= 0 and below >= 0);
        try testing.expect(@abs(above - below) <= 1);
    }
    // 6 px at 96, 9 px at 144.
    try testing.expectEqual(@as(i32, 106), editorRect(.{ .x = 100, .y = 0, .w = 200, .h = 34 }, 96).x);
    try testing.expectEqual(@as(i32, 109), editorRect(.{ .x = 100, .y = 0, .w = 300, .h = 51 }, 144).x);
    // A short area clamps the height; a narrow one keeps a usable width.
    const small = editorRect(.{ .x = 0, .y = 0, .w = 10, .h = 12 }, 96);
    try testing.expectEqual(@as(i32, 12), small.h);
    try testing.expectEqual(@as(i32, 20), small.w);
}

test "win32 title edit: colours follow the tab" {
    const testing = std.testing;
    const dark_pal: theme.Palette = .{
        .dark = true,
        .mica = false,
        .strip_bg = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E },
        .tab_active_bg = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E },
        .tab_hover_bg = .{ .r = 255, .g = 255, .b = 255, .a = 0x10 },
        .text = .{ .r = 255, .g = 255, .b = 255, .a = 0xE6 },
        .text_inactive = .{ .r = 255, .g = 255, .b = 255, .a = 0x80 },
        .button_hover_bg = .{ .r = 255, .g = 255, .b = 255, .a = 0x1A },
        .button_pressed_bg = .{ .r = 255, .g = 255, .b = 255, .a = 0x0E },
        .divider = .{ .r = 0x3C, .g = 0x3C, .b = 0x3C },
    };
    const dc = colorsFor(dark_pal);
    try testing.expectEqual(dark_pal.tab_active_bg, dc.field);
    // The title ink over the fill: light, but never plain white.
    try testing.expect(dc.text.r > 0xC0 and dc.text.g > 0xC0 and dc.text.b > 0xC0);
    try testing.expect(!(dc.text.r == 255 and dc.text.g == 255 and dc.text.b == 255));
    try testing.expectEqual(@as(u8, 255), dc.text.a);

    var light_pal = dark_pal;
    light_pal.dark = false;
    light_pal.tab_active_bg = .{ .r = 0xFA, .g = 0xFA, .b = 0xFA };
    light_pal.text = .{ .r = 0, .g = 0, .b = 0, .a = 0xD9 };
    const lc = colorsFor(light_pal);
    try testing.expectEqual(light_pal.tab_active_bg, lc.field);
    try testing.expect(lc.text.r < 0x50 and lc.text.g < 0x50 and lc.text.b < 0x50);
    // Never the white of a stock EDIT on a light theme's text either.
    try testing.expect(lc.field.r != lc.text.r);
}
