//! Overlay scroller of a surface, like the macOS one (`SurfaceScrollView`
//! with `scrollerStyle = .overlay`): it takes no width, so the grid always
//! has the whole pane. A thin knob floats over the right edge when the
//! viewport scrolls or the pointer reaches the edge, grows while the pointer
//! is on it, fades out after a pause, can be dragged, and a click on the
//! track beside it scrolls a page (SPEC §18.11).
//!
//! It is a label popup of the overlay host (`overlay.zig`): an owned layered
//! window that never takes the focus, drawn with Direct2D. It exists only
//! while the knob is shown, so an idle terminal pays nothing: no window
//! work, no timers, nothing on the key path. Core's `scrollbar` action
//! (`update`) keeps the numbers; `scrollbar = never` never creates it.
//!
//! The colours follow the terminal background (light or dark knob), as
//! macOS picks `.aqua` or `.darkAqua` from it.
const std = @import("std");
const win32 = @import("win32");
const terminal = @import("../../terminal/main.zig");
const Chrome = @import("Chrome.zig");
const Surface = @import("Surface.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");
const renderer = @import("../../renderer.zig");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Tab = @import("Tab.zig");

const log = std.log.scoped(.win32_scrollbar);

const user32 = win32.user32;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const class_name = L("GhosttyOverlayScroller");

// Sizes at 96 dpi. AppKit draws the overlay scroller itself and the repo has
// no numbers for it; these are its measured values: a 15 pt strip, a 7 pt
// knob that grows to 11 pt under the pointer, 2 pt from the edge.
const strip_w = 15;
const knob_w = 7;
const knob_w_hover = 11;
const knob_inset = 2;
const pad_v = 2;
const min_knob_h = 18;

/// The knob stays this long after the last scroll, then fades over `fade_ms`
/// (the AppKit overlay timing).
pub const hold_ms = 750;
pub const fade_ms = 400;
const fade_tick_ms = 16;

pub const State = struct {
    total: u64 = 0,
    offset: u64 = 0,
    len: u64 = 0,
    /// `scrollbar = system`: the scroller may appear.
    enabled: bool = false,
    /// A knob drag is running: the knob follows the mouse, not core.
    dragging: bool = false,
    /// Top of the knob while dragging, popup pixels.
    drag_top: i32 = 0,
    /// Distance from the knob's top to the grabbed point.
    grab: i32 = 0,
    /// The pointer is on the popup.
    hover: bool = false,
    tracking_leave: bool = false,
    /// Opacity of what is drawn; falls to 0 while fading.
    alpha: u8 = 255,
    fading: bool = false,
    fade_start: u64 = 0,
    /// The knob geometry last drawn, to skip identical redraws.
    drawn: ?Knob = null,
    popup: overlay.Popup = undefined,
    popup_made: bool = false,
};

pub const Knob = struct { y: i32, h: i32 };

// -- Geometry (pure) -------------------------------------------------------------

/// The knob in a track of `height` px: its length is the visible share of the
/// scrollback (at least `min_h`), its place the viewport's share of the
/// travel. Null when everything is visible.
pub fn knobFor(total: u64, offset: u64, len: u64, height: i32, pad: i32, min_h: i32) ?Knob {
    if (len == 0 or total <= len) return null;
    const track = height - 2 * pad;
    if (track <= 0) return null;
    const track_f: f64 = @floatFromInt(track);
    const share = @as(f64, @floatFromInt(len)) / @as(f64, @floatFromInt(total));
    const h: i32 = @intFromFloat(std.math.clamp(@round(track_f * share), @as(f64, @floatFromInt(@min(min_h, track))), track_f));
    const travel: f64 = @floatFromInt(track - h);
    const last = total - len;
    const frac = @as(f64, @floatFromInt(@min(offset, last))) / @as(f64, @floatFromInt(last));
    return .{ .y = pad + @as(i32, @intFromFloat(@round(travel * frac))), .h = h };
}

/// The row whose knob has its top at `top` (the inverse of `knobFor`).
pub fn rowForKnobTop(total: u64, len: u64, height: i32, pad: i32, min_h: i32, top: i32) u64 {
    const knob = knobFor(total, 0, len, height, pad, min_h) orelse return 0;
    const travel = height - 2 * pad - knob.h;
    if (travel <= 0) return 0;
    const last = total - len;
    const frac = std.math.clamp(@as(f64, @floatFromInt(top - pad)) / @as(f64, @floatFromInt(travel)), 0, 1);
    return @intFromFloat(@round(frac * @as(f64, @floatFromInt(last))));
}

/// The row a click at `y` on the track scrolls to, one page toward it; null
/// on the knob itself.
pub fn pageRow(state: State, knob: Knob, y: i32) ?u64 {
    const last = state.total -| state.len;
    const page = @max(state.len, 1);
    if (y < knob.y) return state.offset -| page;
    if (y >= knob.y + knob.h) return @min(state.offset +| page, last);
    return null;
}

/// The strip over the right edge of the surface (screen coordinates).
pub fn stripRect(surface: geom.Rect, dpi: u32) geom.Rect {
    const w = @min(geom.scale(strip_w, dpi), surface.w);
    return .{ .x = surface.right() - w, .y = surface.y, .w = w, .h = surface.h };
}

/// Opacity after `elapsed` ms of fading.
pub fn fadeAlpha(elapsed: u64) u8 {
    if (elapsed >= fade_ms) return 0;
    return @intCast(255 - elapsed * 255 / fade_ms);
}

const Look = struct { knob: theme.Color, track: theme.Color, edge: theme.Color };

/// Knob, track and edge line over a light or dark terminal background.
pub fn look(dark: bool, expanded: bool, alpha: u8) Look {
    const ink: u8 = if (dark) 255 else 0;
    const scaled = struct {
        fn a(base: u32, alpha_: u8) u8 {
            return @intCast(base * alpha_ / 255);
        }
    }.a;
    return .{
        .knob = .{ .r = ink, .g = ink, .b = ink, .a = scaled(if (expanded) 0xB0 else 0x80, alpha) },
        // Collapsed, the track is only there to catch clicks (alpha 1).
        .track = .{ .r = ink, .g = ink, .b = ink, .a = if (expanded) scaled(if (dark) 0x1A else 0x10, alpha) else 1 },
        .edge = .{ .r = ink, .g = ink, .b = ink, .a = if (expanded) scaled(0x22, alpha) else 0 },
    };
}

fn isDark(bg: anytype) bool {
    const rgb: terminal.color.RGB = .{ .r = bg.r, .g = bg.g, .b = bg.b };
    return rgb.luminance() < 0.5;
}

// -- Core side ---------------------------------------------------------------------

/// Core reported a new scrollbar. Always stores it, so the IPC state is right
/// even without a scroller; shows the knob when the viewport moved.
pub fn update(surface: *Surface, value: terminal.Scrollbar) bool {
    const state = &surface.scrollbar;
    const was = state.*;
    state.total = value.total;
    state.offset = value.offset;
    state.len = value.len;
    if (!state.enabled or state.dragging or surface.hwnd_destroyed) return true;
    if (!state.popup_made and state.total <= state.len) return true;

    if (state.total <= state.len) {
        if (state.popup.visible) hide(state);
        return true;
    }
    const moved = state.offset != was.offset;
    const was_bottom = was.offset >= was.total -| was.len;
    const now_bottom = state.offset >= state.total -| state.len;
    if (state.popup_made and state.popup.visible) {
        // Output at the bottom grows the scrollback: the knob follows
        // quietly, without keeping itself on screen.
        if (moved and !(was_bottom and now_bottom)) flash(surface) else redraw(state);
    } else if (moved and !(was_bottom and now_bottom)) {
        flash(surface);
    }
    return true;
}

/// What a reloaded `scrollbar` setting does to a live surface.
pub const Reconfig = enum { none, enable, disable };

pub fn reconfig(was_enabled: bool, now_enabled: bool) Reconfig {
    if (was_enabled == now_enabled) return .none;
    return if (now_enabled) .enable else .disable;
}

/// `scrollbar` changed in the config: `never` takes the scroller away from
/// the live surfaces, `system` allows it again from the next scroll on.
pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    const now = config.scrollbar == .system;
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |e| setEnabled(e.view, now);
        }
    }
}

fn setEnabled(surface: *Surface, now: bool) void {
    const state = &surface.scrollbar;
    switch (reconfig(state.enabled, now)) {
        .none => {},
        .enable => state.enabled = true,
        .disable => {
            state.enabled = false;
            if (state.dragging) {
                _ = user32.ReleaseCapture();
                state.dragging = false;
            }
            if (state.popup_made and state.popup.visible) hide(state);
        },
    }
}

/// The pointer moved over the surface at client `x`. Reaching the strip
/// shows the scroller, as hovering the gutter does on macOS. Costs a few
/// compares when nothing scrolls.
pub fn pointerMoved(surface: *Surface, x: i32, button_down: bool) void {
    const state = &surface.scrollbar;
    if (!state.enabled or button_down or state.total <= state.len) return;
    // `Surface.size` is kept by WM_SIZE: no syscall per mouse move.
    const width: i32 = @intCast(renderer.D3D11.unpackSize(surface.size.load(.acquire)).width);
    if (width == 0) return;
    if (x < width - geom.scale(strip_w, surface.window.dpi)) return;
    flash(surface);
}

/// Shows the knob (or keeps it) and restarts the pause before it fades.
pub fn flash(surface: *Surface) void {
    const state = &surface.scrollbar;
    if (!state.enabled or surface.hwnd_destroyed or state.total <= state.len) return;
    if (user32.IsIconic(surface.window.hwnd) != 0 or user32.IsWindowVisible(surface.hwnd) == 0) return;

    if (!state.popup_made) {
        state.popup = .{
            .kind = .label,
            .anchor = .surface_top_right,
            .window = surface.window,
            .surface = surface,
            .size = .{ .w = strip_w, .h = 0 },
            .margin = 0,
            .paint = paintPopup,
            .on_message = onMessage,
            .place = placePopup,
            .ctx = surface,
            .class = class_name,
            .click_through = false,
        };
        state.popup_made = true;
    }
    state.alpha = 255;
    state.fading = false;
    state.drawn = null;
    const p = &state.popup;
    if (p.visible) {
        redraw(state);
    } else {
        p.show() catch |err| {
            log.warn("unable to show the scroller err={}", .{err});
            return;
        };
    }
    restartHold(state);
}

/// A tab left the screen: a hidden popup gets no WM_MOUSELEAVE, so its hover
/// would stick and keep the scroller from fading.
pub fn tabShown(tab: *Tab, shown: bool) void {
    if (shown) return;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const state = &entry.view.scrollbar;
        if (!clearHover(state)) continue;
        if (state.popup_made and state.popup.visible) {
            state.drawn = null;
            restartHold(state);
        }
    }
}

/// Drops the hover state; whether there was any to drop.
fn clearHover(state: *State) bool {
    const had = state.hover or state.tracking_leave;
    state.hover = false;
    state.tracking_leave = false;
    return had;
}

test "win32 scrollbar: hiding the tab clears a stuck hover" {
    var state: State = .{ .hover = true, .tracking_leave = true };
    try std.testing.expect(clearHover(&state));
    try std.testing.expect(!state.hover and !state.tracking_leave);
    try std.testing.expect(!clearHover(&state));
}

fn restartHold(state: *State) void {
    const hwnd = state.popup.hwnd orelse return;
    _ = user32.KillTimer(hwnd, messages.timers.overlay.scroller_hold);
    _ = user32.KillTimer(hwnd, messages.timers.overlay.scroller_fade);
    state.fading = false;
    state.alpha = 255;
    if (state.hover or state.dragging) return;
    _ = user32.SetTimer(hwnd, messages.timers.overlay.scroller_hold, hold_ms, null);
}

fn hide(state: *State) void {
    const p = &state.popup;
    if (p.hwnd) |hwnd| {
        _ = user32.KillTimer(hwnd, messages.timers.overlay.scroller_hold);
        _ = user32.KillTimer(hwnd, messages.timers.overlay.scroller_fade);
    }
    p.hide();
    state.hover = false;
    state.tracking_leave = false;
    state.fading = false;
    state.alpha = 255;
    state.drawn = null;
}

fn redraw(state: *State) void {
    const p = &state.popup;
    if (!p.visible) return;
    const surface: *Surface = @ptrCast(@alignCast(p.ctx orelse return));
    const knob = currentKnob(surface);
    if (state.drawn) |d| if (knob) |k| if (d.y == k.y and d.h == k.h) return;
    p.invalidate();
    state.drawn = knob;
}

fn popupHeight(state: *const State) i32 {
    const hwnd = state.popup.hwnd orelse return 0;
    var rc: win32.foundation.RECT = undefined;
    if (user32.GetClientRect(hwnd, &rc) == 0) return 0;
    return rc.bottom - rc.top;
}

/// The knob in popup pixels, following the mouse during a drag.
fn knobAt(state: *const State, height: i32, dpi: u32) ?Knob {
    var knob = knobFor(state.total, state.offset, state.len, height, geom.scale(pad_v, dpi), geom.scale(min_knob_h, dpi)) orelse return null;
    if (state.dragging) {
        const lo = geom.scale(pad_v, dpi);
        knob.y = std.math.clamp(state.drag_top, lo, @max(height - lo - knob.h, lo));
    }
    return knob;
}

fn currentKnob(surface: *const Surface) ?Knob {
    const state = &surface.scrollbar;
    return knobAt(state, popupHeight(state), surface.window.dpi);
}

/// The knob of `surface` in pixels from the top of its surface, for the IPC
/// state; null while the scroller is not shown.
pub fn knobOf(surface: *const Surface) ?Knob {
    const state = &surface.scrollbar;
    if (!state.popup_made or !state.popup.visible) return null;
    return currentKnob(surface);
}

fn scrollTo(surface: *Surface, row: u64) void {
    if (!surface.initialized) return;
    _ = surface.core_surface.performBindingAction(.{ .scroll_to_row = @intCast(row) }) catch |err|
        log.warn("scroll_to_row failed err={}", .{err});
}

// -- Popup -------------------------------------------------------------------------

fn placePopup(p: *overlay.Popup, surface: geom.Rect, size_px: overlay.Size) geom.Rect {
    _ = size_px;
    return stripRect(surface, p.window.dpi);
}

fn paintPopup(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const surface: *Surface = @ptrCast(@alignCast(p.ctx orelse return));
    const state = &surface.scrollbar;
    const dark = isDark(surface.window.app.config.background);
    const expanded = state.hover or state.dragging;
    const colors = look(dark, expanded, state.alpha);
    const w = ctx.rect.w;
    const h = ctx.rect.h;

    var items: [3]Chrome.Item = undefined;
    var n: usize = 0;
    items[n] = .{ .box = .{ .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .radius = 0, .fill = colors.track } };
    n += 1;
    if (expanded) {
        items[n] = .{ .box = .{ .rect = .{ .x = 0, .y = 0, .w = geom.scale(1, ctx.dpi), .h = h }, .radius = 0, .fill = colors.edge } };
        n += 1;
    }
    if (knobAt(state, h, ctx.dpi)) |knob| {
        const kw = geom.scale(if (expanded) knob_w_hover else knob_w, ctx.dpi);
        items[n] = .{ .box = .{
            .rect = .{ .x = w - geom.scale(knob_inset, ctx.dpi) - kw, .y = knob.y, .w = kw, .h = knob.h },
            .radius = @divTrunc(kw, 2),
            .fill = colors.knob,
        } };
        n += 1;
    }
    Chrome.paintItems(ctx.hdc, ctx.rect, items[0..n], ctx.palette, ctx.dpi, null) catch |err| {
        log.warn("unable to paint the scroller err={}", .{err});
    };
}

fn onMessage(p: *overlay.Popup, msg: u32, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) ?win32.foundation.LRESULT {
    const surface: *Surface = @ptrCast(@alignCast(p.ctx orelse return null));
    const state = &surface.scrollbar;
    const hwnd = p.hwnd orelse return null;
    switch (msg) {
        user32.WM_NCHITTEST => return user32.HTCLIENT,

        user32.WM_MOUSEMOVE => {
            if (!state.tracking_leave) {
                var tme: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE, .hwndTrack = hwnd };
                if (user32.TrackMouseEvent(&tme) != 0) state.tracking_leave = true;
            }
            if (state.dragging) {
                state.drag_top = user32.getYLparam(lparam) - state.grab;
                const dpi = surface.window.dpi;
                const row = rowForKnobTop(state.total, state.len, popupHeight(state), geom.scale(pad_v, dpi), geom.scale(min_knob_h, dpi), state.drag_top);
                scrollTo(surface, row);
                p.invalidate();
            } else if (!state.hover) {
                state.hover = true;
                restartHold(state);
                state.drawn = null;
                redraw(state);
            }
            return 0;
        },

        user32.WM_MOUSELEAVE => {
            state.tracking_leave = false;
            if (!state.dragging and state.hover) {
                state.hover = false;
                state.drawn = null;
                redraw(state);
                restartHold(state);
            }
            return 0;
        },

        user32.WM_LBUTTONDOWN => {
            const y = user32.getYLparam(lparam);
            // No knob: the scrollback shrank to one screen mid-click and the
            // popup is about to hide. The click is swallowed on purpose; passing
            // it on would mean mapping it to the surface under a closing popup
            // and could start a selection the user never aimed at.
            const knob = currentKnob(surface) orelse return 0;
            if (pageRow(state.*, knob, y)) |row| {
                scrollTo(surface, row);
            } else {
                state.dragging = true;
                state.grab = y - knob.y;
                state.drag_top = knob.y;
                _ = user32.SetCapture(hwnd);
                restartHold(state);
                p.invalidate();
            }
            return 0;
        },

        user32.WM_LBUTTONUP => {
            if (state.dragging) _ = user32.ReleaseCapture();
            return 0;
        },

        user32.WM_CAPTURECHANGED => {
            if (state.dragging) {
                state.dragging = false;
                state.hover = false;
                state.tracking_leave = false;
                state.drawn = null;
                redraw(state);
                restartHold(state);
            }
            return 0;
        },

        // The wheel over the strip scrolls the terminal as anywhere else.
        user32.WM_MOUSEWHEEL => {
            _ = user32.SendMessageW(surface.hwnd, msg, wparam, lparam);
            return 0;
        },

        user32.WM_TIMER => {
            if (wparam == messages.timers.overlay.scroller_hold) {
                _ = user32.KillTimer(hwnd, messages.timers.overlay.scroller_hold);
                if (state.hover or state.dragging) return 0;
                state.fading = true;
                state.fade_start = win32.kernel32.GetTickCount64();
                _ = user32.SetTimer(hwnd, messages.timers.overlay.scroller_fade, fade_tick_ms, null);
                return 0;
            }
            if (wparam == messages.timers.overlay.scroller_fade) {
                const a = fadeAlpha(win32.kernel32.GetTickCount64() -% state.fade_start);
                if (a == 0) {
                    hide(state);
                } else if (a != state.alpha) {
                    state.alpha = a;
                    p.invalidate();
                }
                return 0;
            }
            return null;
        },

        else => return null,
    }
}

fn sb(total: usize, offset: usize, len: usize) State {
    return .{ .total = total, .offset = offset, .len = len };
}

test "win32 scrollbar: knob length and place follow the viewport" {
    const t = std.testing;

    // 300 rows, 24 visible, 600 px high with 2 px padding: 596 px of track.
    const top = knobFor(300, 0, 24, 600, 2, 18).?;
    try t.expectEqual(@as(i32, 2), top.y);
    try t.expectEqual(@as(i32, 48), top.h);
    const bottom = knobFor(300, 276, 24, 600, 2, 18).?;
    try t.expectEqual(@as(i32, 598), bottom.y + bottom.h);
    const mid = knobFor(300, 138, 24, 600, 2, 18).?;
    try t.expectEqual(@as(i32, 2 + 274), mid.y);

    // Past the end clamps; a huge scrollback keeps the minimum length.
    try t.expectEqual(bottom.y, knobFor(300, 9999, 24, 600, 2, 18).?.y);
    const long = knobFor(10_000_000, 0, 24, 600, 2, 18).?;
    try t.expectEqual(@as(i32, 18), long.h);

    // Nothing to scroll: no knob.
    try t.expectEqual(@as(?Knob, null), knobFor(24, 0, 24, 600, 2, 18));
    try t.expectEqual(@as(?Knob, null), knobFor(0, 0, 0, 600, 2, 18));
    try t.expectEqual(@as(?Knob, null), knobFor(300, 0, 24, 3, 2, 18));
}

test "win32 scrollbar: dragging maps the knob top back to rows" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 0), rowForKnobTop(300, 24, 600, 2, 18, -50));
    try t.expectEqual(@as(u64, 276), rowForKnobTop(300, 24, 600, 2, 18, 9999));
    try t.expectEqual(@as(u64, 138), rowForKnobTop(300, 24, 600, 2, 18, 2 + 274));

    // The knob drawn for a row maps back to that row (within a pixel's worth).
    for ([_]u64{ 0, 1, 50, 137, 276 }) |row| {
        const k = knobFor(300, row, 24, 600, 2, 18).?;
        const back = rowForKnobTop(300, 24, 600, 2, 18, k.y);
        try t.expect(back + 1 >= row and back <= row + 1);
    }
}

test "win32 scrollbar: a click on the track pages toward it" {
    const t = std.testing;
    const s = sb(300, 100, 24);
    const knob = knobFor(s.total, s.offset, s.len, 600, 2, 18).?;

    try t.expectEqual(@as(?u64, 76), pageRow(s, .{ .y = knob.y, .h = knob.h }, knob.y - 1));
    try t.expectEqual(@as(?u64, 124), pageRow(s, knob, knob.y + knob.h));
    try t.expectEqual(@as(?u64, null), pageRow(s, knob, knob.y + 1));

    // Clamped to the ends.
    const near_top = sb(300, 10, 24);
    try t.expectEqual(@as(?u64, 0), pageRow(near_top, .{ .y = 20, .h = 40 }, 5));
    const near_end = sb(300, 270, 24);
    try t.expectEqual(@as(?u64, 276), pageRow(near_end, .{ .y = 500, .h = 40 }, 590));
}

test "win32 scrollbar: a config reload enables or disables the scroller" {
    const t = std.testing;
    try t.expectEqual(Reconfig.none, reconfig(true, true));
    try t.expectEqual(Reconfig.none, reconfig(false, false));
    try t.expectEqual(Reconfig.disable, reconfig(true, false));
    try t.expectEqual(Reconfig.enable, reconfig(false, true));
}

test "win32 scrollbar: strip sits on the right edge and fades out" {
    const t = std.testing;
    const surface: geom.Rect = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    const r = stripRect(surface, 96);
    try t.expectEqual(@as(i32, 885), r.x);
    try t.expectEqual(@as(i32, 15), r.w);
    try t.expectEqual(@as(i32, 600), r.h);
    try t.expectEqual(@as(i32, 23), stripRect(surface, 144).w);
    // Never wider than the surface.
    try t.expectEqual(@as(i32, 8), stripRect(.{ .x = 0, .y = 0, .w = 8, .h = 100 }, 96).w);

    try t.expectEqual(@as(u8, 255), fadeAlpha(0));
    try t.expect(fadeAlpha(fade_ms / 2) < 140 and fadeAlpha(fade_ms / 2) > 120);
    try t.expectEqual(@as(u8, 0), fadeAlpha(fade_ms));
    try t.expectEqual(@as(u8, 0), fadeAlpha(10_000));
}

test "win32 scrollbar: colours follow the background and grow on hover" {
    const t = std.testing;
    const dark_idle = look(true, false, 255);
    try t.expectEqual(@as(u8, 255), dark_idle.knob.r);
    try t.expectEqual(@as(u8, 0x80), dark_idle.knob.a);
    try t.expectEqual(@as(u8, 1), dark_idle.track.a);
    try t.expectEqual(@as(u8, 0), dark_idle.edge.a);

    const light_hover = look(false, true, 255);
    try t.expectEqual(@as(u8, 0), light_hover.knob.r);
    try t.expect(light_hover.knob.a > dark_idle.knob.a);
    try t.expect(light_hover.track.a > 1);

    // Fading scales every alpha down.
    const half = look(true, true, 128);
    try t.expect(half.knob.a < look(true, true, 255).knob.a);

    try t.expect(isDark(.{ .r = 0x1e, .g = 0x1e, .b = 0x2e }));
    try t.expect(!isDark(.{ .r = 0xfa, .g = 0xfa, .b = 0xfa }));
}
