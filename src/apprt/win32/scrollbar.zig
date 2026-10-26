//! Native scrollbar of a surface: the `WS_VSCROLL` bar of the surface window,
//! bound to the terminal scrollback (SPEC §18.11).
//!
//! With `scrollbar = system` the bar exists from window creation and stays
//! visible (`SIF_DISABLENOSCROLL` greys it out instead of hiding it), so the
//! client area, and with it the grid, never changes when scrollback first
//! appears. `scrollbar = never` creates the window without the style.
//!
//! macOS shows an overlay scroller that takes no space and fades out; a
//! native Windows bar always occupies `SM_CXVSCROLL` of the width, which is
//! the one deliberate difference.
const std = @import("std");
const win32 = @import("win32");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.win32_scrollbar);

const user32 = win32.user32;

pub const State = struct {
    total: u64 = 0,
    offset: u64 = 0,
    len: u64 = 0,
    /// Whether the surface window has the bar (`scrollbar = system`).
    enabled: bool = false,
    /// A thumb drag is running: the bar follows the mouse, not core.
    dragging: bool = false,
};

/// Divisor that brings the range of `total` rows into an `i32`: 1 unless the
/// scrollback is beyond 2^31 rows.
fn scaleOf(total: u64) u64 {
    return (total -| 1) / std.math.maxInt(i32) + 1;
}

/// The last row the viewport can start at.
fn maxOffset(state: State) u64 {
    return state.total -| state.len;
}

/// The scroll info for a terminal scrollbar: the range is the rows, the page
/// is the visible rows. Ranges beyond `i32` are divided down.
pub fn toScrollInfo(value: terminal.Scrollbar) user32.SCROLLINFO {
    const total: u64 = value.total;
    const len: u64 = value.len;
    const scale = scaleOf(total);
    return .{
        .fMask = user32.SIF_RANGE | user32.SIF_PAGE | user32.SIF_POS | user32.SIF_DISABLENOSCROLL,
        .nMin = 0,
        .nMax = @intCast((total -| 1) / scale),
        .nPage = @intCast(@min(@max(len / scale, @intFromBool(len > 0)), std.math.maxInt(i32))),
        .nPos = @intCast(@min(value.offset / scale, std.math.maxInt(i32))),
    };
}

/// The row to scroll to for a `WM_VSCROLL` code, if it moves anything.
/// `track` is the 32-bit `nTrackPos` of a thumb drag.
pub fn rowFor(code: u16, track: i32, state: State) ?u64 {
    const last = maxOffset(state);
    const row: u64 = switch (code) {
        user32.SB_LINEUP => state.offset -| 1,
        user32.SB_LINEDOWN => state.offset +| 1,
        user32.SB_PAGEUP => state.offset -| @max(state.len, 1),
        user32.SB_PAGEDOWN => state.offset +| @max(state.len, 1),
        user32.SB_THUMBTRACK, user32.SB_THUMBPOSITION => @as(u64, @intCast(@max(track, 0))) *| scaleOf(state.total),
        user32.SB_TOP => 0,
        user32.SB_BOTTOM => last,
        else => return null,
    };
    return @min(row, last);
}

/// Dark or light scrollbar, like the rest of the chrome. Called once the
/// surface window exists; a config or scheme change goes through
/// `theme.applyToWindow`.
pub fn init(surface: *Surface) void {
    if (!surface.scrollbar.enabled) return;
    const dark = theme.palette(surface.window).dark;
    _ = win32.uxtheme.SetWindowTheme(
        surface.hwnd,
        if (dark) std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer") else null,
        null,
    );
    // Show the bar disabled until core reports a scrollback.
    _ = update(surface, .{ .total = 0, .offset = 0, .len = 0 });
}

/// Core reported a new scrollbar. Always stores it, so the IPC state is
/// right even without a bar; moves the thumb unless the user holds it.
pub fn update(surface: *Surface, value: terminal.Scrollbar) bool {
    surface.scrollbar.total = value.total;
    surface.scrollbar.offset = value.offset;
    surface.scrollbar.len = value.len;
    if (!surface.scrollbar.enabled or surface.scrollbar.dragging) return true;
    if (surface.hwnd_destroyed) return true;

    const info = toScrollInfo(value);
    _ = user32.SetScrollInfo(surface.hwnd, user32.SB_VERT, &info, 1);
    return true;
}

/// A `WM_VSCROLL` for the surface.
pub fn handle(surface: *Surface, wparam: win32.foundation.WPARAM) void {
    const code: u16 = @truncate(wparam);
    const state = &surface.scrollbar;

    var track: i32 = 0;
    switch (code) {
        user32.SB_THUMBTRACK, user32.SB_THUMBPOSITION => {
            // The 16 bits of the message overflow on long scrollbacks.
            var info: user32.SCROLLINFO = .{ .fMask = user32.SIF_TRACKPOS };
            if (user32.GetScrollInfo(surface.hwnd, user32.SB_VERT, &info) != 0) track = info.nTrackPos;
            state.dragging = code == user32.SB_THUMBTRACK;
        },
        user32.SB_ENDSCROLL => {
            state.dragging = false;
            // Put the thumb where core has the viewport.
            _ = update(surface, .{
                .total = @intCast(state.total),
                .offset = @intCast(state.offset),
                .len = @intCast(state.len),
            });
            return;
        },
        else => {},
    }

    const row = rowFor(code, track, state.*) orelse return;
    if (!surface.initialized) return;
    _ = surface.core_surface.performBindingAction(.{ .scroll_to_row = @intCast(row) }) catch |err|
        log.warn("scroll_to_row failed err={}", .{err});
}

fn sb(total: usize, offset: usize, len: usize) terminal.Scrollbar {
    return .{ .total = total, .offset = offset, .len = len };
}

test "win32 scrollbar: scroll info from terminal scrollbar" {
    const t = std.testing;

    const a = toScrollInfo(sb(300, 40, 24));
    try t.expectEqual(@as(i32, 0), a.nMin);
    try t.expectEqual(@as(i32, 299), a.nMax);
    try t.expectEqual(@as(u32, 24), a.nPage);
    try t.expectEqual(@as(i32, 40), a.nPos);
    try t.expect(a.fMask & user32.SIF_DISABLENOSCROLL != 0);
    try t.expectEqual(@as(u32, @sizeOf(user32.SCROLLINFO)), a.cbSize);

    // No scrollback: the page covers the range, so the bar is greyed out.
    const b = toScrollInfo(sb(24, 0, 24));
    try t.expectEqual(@as(i32, 23), b.nMax);
    try t.expectEqual(@as(u32, 24), b.nPage);

    const empty = toScrollInfo(sb(0, 0, 0));
    try t.expectEqual(@as(i32, 0), empty.nMax);

    // Beyond the i32 range everything is divided by the same factor.
    const c = toScrollInfo(sb(10_000_000_000, 5_000_000_000, 50));
    try t.expectEqual(@as(i32, 1_999_999_999), c.nMax);
    try t.expectEqual(@as(i32, 1_000_000_000), c.nPos);
    try t.expectEqual(@as(u32, 10), c.nPage);
}

test "win32 scrollbar: row for each SB code" {
    const t = std.testing;
    const s: State = .{ .total = 300, .offset = 100, .len = 24, .enabled = true };

    try t.expectEqual(@as(?u64, 99), rowFor(user32.SB_LINEUP, 0, s));
    try t.expectEqual(@as(?u64, 101), rowFor(user32.SB_LINEDOWN, 0, s));
    try t.expectEqual(@as(?u64, 76), rowFor(user32.SB_PAGEUP, 0, s));
    try t.expectEqual(@as(?u64, 124), rowFor(user32.SB_PAGEDOWN, 0, s));
    try t.expectEqual(@as(?u64, 150), rowFor(user32.SB_THUMBTRACK, 150, s));
    try t.expectEqual(@as(?u64, 150), rowFor(user32.SB_THUMBPOSITION, 150, s));
    try t.expectEqual(@as(?u64, 0), rowFor(user32.SB_TOP, 0, s));
    try t.expectEqual(@as(?u64, 276), rowFor(user32.SB_BOTTOM, 0, s));
    try t.expectEqual(@as(?u64, null), rowFor(user32.SB_ENDSCROLL, 0, s));

    // Clamped to the ends.
    const top: State = .{ .total = 300, .offset = 0, .len = 24 };
    try t.expectEqual(@as(?u64, 0), rowFor(user32.SB_LINEUP, 0, top));
    try t.expectEqual(@as(?u64, 0), rowFor(user32.SB_PAGEUP, 0, top));
    const bottom: State = .{ .total = 300, .offset = 276, .len = 24 };
    try t.expectEqual(@as(?u64, 276), rowFor(user32.SB_LINEDOWN, 0, bottom));
    try t.expectEqual(@as(?u64, 276), rowFor(user32.SB_THUMBTRACK, 290, bottom));
    try t.expectEqual(@as(?u64, 0), rowFor(user32.SB_THUMBTRACK, -5, bottom));

    // A scaled thumb position maps back to rows.
    const huge: State = .{ .total = 10_000_000_000, .offset = 0, .len = 50 };
    try t.expectEqual(@as(?u64, 5_000_000_000), rowFor(user32.SB_THUMBTRACK, 1_000_000_000, huge));
}
