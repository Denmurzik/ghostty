//! In-place title editor: an EDIT child of the top-level window over a tab,
//! the caption or the title area. Enter commits, Esc and focus loss cancel.
//! The EDIT only posts `WM_GHOSTTY_TITLE_EDIT_DONE`; `strip_input.handle`
//! consumes it, reads the text and takes the control down, so the control is
//! never destroyed from inside its own procedure.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const util = @import("util.zig");

const user32 = win32.user32;
const comctl32 = win32.comctl32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;
const HWND = win32.foundation.HWND;

const log = std.log.scoped(.win32_title_edit);

extern "gdi32" fn CreateFontW(
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: u32,
    underline: u32,
    strike_out: u32,
    charset: u32,
    out_precision: u32,
    clip_precision: u32,
    quality: u32,
    pitch_and_family: u32,
    face: [*:0]const u16,
) callconv(.winapi) ?*anyopaque;

const WM_SETFONT = 0x0030;
const EM_SETSEL = 0x00B1;
const FW_NORMAL = 400;
const DEFAULT_CHARSET = 1;
const CLEARTYPE_QUALITY = 5;
const subclass_id = 1;

pub const Kind = enum { surface, tab, window };

/// The editor of a window, kept in `strip_input.State`.
pub const Session = struct {
    hwnd: HWND,
    font: ?*anyopaque,
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

/// The editor rect over a tab, clear of the close button.
pub fn tabRect(window: *const Window, index: usize) ?geom.Rect {
    if (index >= window.strip.tabs.items.len) return null;
    const m = TabStrip.Metrics.forDpi(window.dpi);
    const r = window.strip.tabs.items[index];
    const pad = geom.scale(8, window.dpi);
    const right_pad = if (r.w >= 2 * m.close_w) m.close_w else pad;
    return .{
        .x = r.x + pad,
        .y = geom.scale(8, window.dpi),
        .w = @max(r.w - pad - right_pad, geom.scale(20, window.dpi)),
        .h = @max(m.height - geom.scale(16, window.dpi), 1),
    };
}

/// The editor rect for the window and surface titles: the title area, else
/// the caption, else the active tab.
pub fn titleRect(window: *const Window) geom.Rect {
    const pad = geom.scale(8, window.dpi);
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

fn beginFor(window: *Window, kind: Kind, target_id: u32, rect: geom.Rect, initial: []const u8) void {
    cancel(window);
    const alloc = window.app.core_app.alloc;

    const wide = util.utf16z(alloc, initial) catch |err| {
        log.warn("unable to convert the title err={}", .{err});
        return;
    };
    defer alloc.free(wide);

    const hwnd = user32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        wide,
        user32.WS_CHILD | user32.WS_VISIBLE | user32.WS_BORDER | user32.ES_AUTOHSCROLL,
        rect.x,
        rect.y,
        rect.w,
        rect.h,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.warn("unable to create the title editor err={}", .{win32.kernel32.GetLastError()});
        return;
    };

    const font = CreateFontW(
        -geom.scale(14, window.dpi),
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
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (font) |f| _ = user32.SendMessageW(hwnd, WM_SETFONT, @intFromPtr(f), 1);

    if (comctl32.SetWindowSubclass(hwnd, editProc, subclass_id, @intFromPtr(window)) == 0) {
        log.warn("unable to subclass the title editor", .{});
    }
    window.strip_input.edit = .{ .hwnd = hwnd, .font = font, .kind = kind, .target_id = target_id };

    _ = user32.SendMessageW(hwnd, EM_SETSEL, 0, -1);
    _ = user32.SetFocus(hwnd);
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
        .surface => beginFor(window, .surface, surface.id, titleRect(window), surface.title orelse ""),
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
    _ = user32.DestroyWindow(s.hwnd);
    if (s.font) |f| _ = win32.gdi32.DeleteObject(f);
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
            const alloc = window.app.core_app.alloc;
            if (title.len == 0) {
                if (surface.title) |old| alloc.free(old);
                surface.title = null;
            } else {
                surface.setTitle(title) catch |err| {
                    log.warn("unable to set the surface title err={}", .{err});
                    return;
                };
            }
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
