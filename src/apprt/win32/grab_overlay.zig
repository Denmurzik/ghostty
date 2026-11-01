//! The split grab handle on screen: the three-dot ellipsis at the top centre
//! of a pane (macOS `SurfaceGrabHandle`), its hover reveal and fade, the hit
//! test that routes a press to the drag, and the move cursor. The rules of
//! when it exists and how bright it is are `grab_handle.zig`; this file owns
//! the popup, the pointer state and the 150 ms fade.
//!
//! One `label` popup per pane, made on the first reveal and hidden once the
//! fade to nothing is over. It has no background (macOS has none) and lets
//! the mouse through, so the hit test is done here, on the surface's own
//! mouse messages.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const geom = @import("geom.zig");
const grab_handle = @import("grab_handle.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");

const user32 = win32.user32;
const log = std.log.scoped(.win32_grab_overlay);

/// Timer frame of the fade (about one 60 Hz frame).
const fade_tick_ms = 16;

/// The ellipsis glyph in DIP: three dots of this diameter ...
const dot_dip = 2;
/// ... this far apart edge to edge ...
const dot_gap_dip = 3;
/// ... centred, this far above the handle's centre line.
const dot_lift_dip = 3;

/// An opacity change running from `from` to `to` since `start` (a
/// `GetTickCount64` value).
pub const Anim = struct {
    from: f32 = 0,
    to: f32 = 0,
    start: u64 = 0,

    /// Milliseconds since the start, capped at the fade length.
    fn elapsed(a: Anim, now: u64) u32 {
        const dt = now -% a.start;
        return @intCast(@min(dt, grab_handle.fade_ms));
    }

    /// Opacity at `now`.
    pub fn at(a: Anim, now: u64) f32 {
        return grab_handle.fade(a.from, a.to, a.elapsed(now));
    }

    pub fn finished(a: Anim, now: u64) bool {
        return a.elapsed(now) >= grab_handle.fade_ms;
    }
};

pub const State = struct {
    /// Heap popup, made on the first reveal; freed in `surfaceDestroying`.
    popup: ?*overlay.Popup = null,
    /// The level the opacity is heading for.
    shown: grab_handle.Ellipsis = .hidden,
    /// Current opacity (0..1).
    opacity: f32 = 0,
    /// The pointer is over the hit area / in the reveal band.
    on_handle: bool = false,
    in_band: bool = false,
    /// A drag from this handle is running (set by `split_drag_input`).
    dragging: bool = false,
    /// The left press on the handle was eaten; its release is eaten too.
    press_eaten: bool = false,
    anim: Anim = .{},
};

// -- Pure rules -----------------------------------------------------------------

/// The three dots, in the handle's pixel box of `size`: `dot_dip` wide,
/// `dot_gap_dip` apart, centred horizontally and `dot_lift_dip` above the
/// centre line.
pub fn dots(size: geom.Size, dpi: u32) [3]geom.Rect {
    const d = geom.scale(dot_dip, dpi);
    const step = geom.scale(dot_dip + dot_gap_dip, dpi);
    const total = 2 * step + d;
    const x0 = @divFloor(size.w - total, 2);
    const y = @divFloor(size.h, 2) - geom.scale(dot_lift_dip, dpi) - @divFloor(d, 2);
    var out: [3]geom.Rect = undefined;
    for (&out, 0..) |*r, i| {
        r.* = .{ .x = x0 + @as(i32, @intCast(i)) * step, .y = y, .w = d, .h = d };
    }
    return out;
}

/// Alpha byte of an opacity.
pub fn alphaByte(opacity: f32) u8 {
    const v = std.math.clamp(opacity, 0, 1) * 255;
    return @intFromFloat(@round(v));
}

/// Number of leaves a tab shows (zoomed-out and empty ones do not count).
pub fn visibleCount(leaves: anytype) usize {
    var n: usize = 0;
    for (leaves) |leaf| {
        if (leaf.visible) n += 1;
    }
    return n;
}

/// The level the ellipsis should have: nothing without a hit area.
pub fn levelFor(mode: grab_handle.Mode, has_area: bool, in: grab_handle.Inputs) grab_handle.Ellipsis {
    if (!has_area) return .hidden;
    return grab_handle.ellipsis(mode, in);
}

/// What a left-button message does at the handle.
pub const LeftRoute = enum {
    /// Not ours: the terminal gets it as before.
    terminal,
    /// A press (or the second click of a double click) on the handle.
    grab_press,
    /// The release of a press the handle ate.
    swallow_release,
};

/// Routes a left press (`down`) or release: a press on the handle, a second
/// click of a double click included, goes to the drag and its release is
/// swallowed; a press that reached the terminal always gets its release.
pub fn leftRoute(down: bool, hit: bool, press_eaten: bool) LeftRoute {
    if (down) return if (hit) .grab_press else .terminal;
    return if (press_eaten) .swallow_release else .terminal;
}

// -- Surface state --------------------------------------------------------------

fn visibleLeaves(tab: *const Tab) usize {
    if (tab.split_layout) |l| return visibleCount(l.leaves);
    // Not laid out (minimized): the tree decides.
    return if (tab.tree.isSplit()) 2 else 1;
}

fn exists(s: *const Surface, mode: grab_handle.Mode) bool {
    const w = s.window;
    return grab_handle.active(mode, w.placement.fullscreen, visibleLeaves(s.tab) > 1, w.kind == .quick);
}

fn paneSize(s: *const Surface) geom.Size {
    var rc: win32.foundation.RECT = undefined;
    if (user32.GetClientRect(s.hwnd, &rc) == 0) return .{ .w = 0, .h = 0 };
    return .{ .w = rc.right - rc.left, .h = rc.bottom - rc.top };
}

/// Whether a press at the client point `(x, y)` is on the handle.
pub fn hitHandle(s: *Surface, x: i32, y: i32) bool {
    if (!exists(s, s.window.app.config.@"drag-handle")) return false;
    return grab_handle.handleRect(paneSize(s), s.window.dpi).contains(x, y);
}

/// The pointer moved to the client point `(x, y)`.
pub fn pointerMoved(s: *Surface, x: i32, y: i32) void {
    setPointer(s, .{ x, y }, s.window.app.config.@"drag-handle");
}

/// The pointer left the pane.
pub fn pointerLeft(s: *Surface) void {
    setPointer(s, null, s.window.app.config.@"drag-handle");
}

/// Something the level depends on changed (config, layout, tab shown,
/// focus, fullscreen, cursor hidden): evaluate it again.
pub fn refresh(s: *Surface) void {
    setPointer(s, s.mouse_state.last_pos, s.window.app.config.@"drag-handle");
}

/// `refresh` of every pane with the mode of the new config.
pub fn configChanged(app: *App, config: *const @import("../../config.zig").Config) void {
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |e| setPointer(e.view, e.view.mouse_state.last_pos, config.@"drag-handle");
        }
    }
}

/// `refresh` of every pane of the tab.
pub fn refreshTab(tab: *Tab) void {
    var it = tab.tree.iterator();
    while (it.next()) |e| refresh(e.view);
}

/// The drag that started on this pane's handle began or ended.
pub fn setDragging(s: *Surface, dragging: bool) void {
    s.grab.dragging = dragging;
    refresh(s);
}

fn setPointer(s: *Surface, pos: ?[2]i32, mode: grab_handle.Mode) void {
    const st = &s.grab;
    const there = exists(s, mode);
    st.on_handle = false;
    st.in_band = false;
    if (there and pos != null) {
        const p = pos.?;
        const size = paneSize(s);
        const dpi = s.window.dpi;
        st.on_handle = grab_handle.handleRect(size, dpi).contains(p[0], p[1]);
        st.in_band = grab_handle.hoverBand(size, dpi).contains(p[0], p[1]);
    }
    const level = levelFor(mode, there, .{
        .pointer_visible = !s.mouse_state.hidden,
        .on_handle = st.on_handle,
        .in_band = st.in_band,
        .dragging = st.dragging,
    });
    setLevel(s, level);
}

fn setLevel(s: *Surface, level: grab_handle.Ellipsis) void {
    const st = &s.grab;
    if (level == st.shown) return;
    const now = win32.kernel32.GetTickCount64();
    // A fade that is half way starts from where it is.
    st.opacity = st.anim.at(now);
    st.anim = .{ .from = st.opacity, .to = grab_handle.opacityOf(level), .start = now };
    st.shown = level;
    if (level != .hidden) showPopup(s);
    _ = user32.SetTimer(s.hwnd, messages.timers.surface.grab_fade, fade_tick_ms, null);
}

/// `WM_TIMER` of the fade.
pub fn onTimer(s: *Surface) void {
    const st = &s.grab;
    const now = win32.kernel32.GetTickCount64();
    st.opacity = st.anim.at(now);
    if (st.popup) |p| p.invalidate();
    if (!st.anim.finished(now)) return;
    _ = user32.KillTimer(s.hwnd, messages.timers.surface.grab_fade);
    if (st.shown == .hidden) {
        if (st.popup) |p| p.hide();
    }
}

fn showPopup(s: *Surface) void {
    const st = &s.grab;
    const p = st.popup orelse blk: {
        const alloc = s.app.core_app.alloc;
        const p = alloc.create(overlay.Popup) catch |err| {
            log.warn("unable to make the grab handle err={}", .{err});
            return;
        };
        p.* = .{
            .kind = .label,
            .anchor = .surface_top_full,
            .window = s.window,
            .surface = s,
            .size = grab_handle.handle_dip,
            .margin = 0,
            .paint = paint,
            .place = place,
            .ctx = s,
            .click_through = true,
        };
        st.popup = p;
        break :blk p;
    };
    if (p.visible and p.hwnd != null) return;
    p.tab_hidden = if (s.window.activeTab()) |t| t != s.tab else false;
    p.show() catch |err| log.warn("unable to show the grab handle err={}", .{err});
}

/// The handle's rectangle in screen px: the top centre of the pane.
fn place(p: *overlay.Popup, surface: geom.Rect, size_px: geom.Size) geom.Rect {
    _ = size_px;
    const r = grab_handle.handleRect(.{ .w = surface.w, .h = surface.h }, p.window.dpi);
    return .{ .x = surface.x + r.x, .y = surface.y + r.y, .w = r.w, .h = r.h };
}

fn paint(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const s: *Surface = @ptrCast(@alignCast(p.ctx orelse return));
    const alpha = alphaByte(s.grab.opacity);
    if (alpha == 0) return;
    var ink = ctx.palette.text;
    ink.a = alpha;
    const rects = dots(.{ .w = ctx.rect.w, .h = ctx.rect.h }, ctx.dpi);
    var items: [3]Chrome.Item = undefined;
    for (&items, rects) |*item, r| {
        item.* = .{ .box = .{ .rect = r, .radius = @divFloor(r.w, 2), .fill = ink } };
    }
    Chrome.paintItems(ctx.hdc, ctx.rect, &items, ctx.palette, ctx.dpi, null) catch |err| {
        log.warn("unable to paint the grab handle err={}", .{err});
    };
}

/// Before core tears the surface down (after the overlay host took the
/// popup's window down): stops the fade and frees the popup.
pub fn surfaceDestroying(s: *Surface) void {
    _ = user32.KillTimer(s.hwnd, messages.timers.surface.grab_fade);
    const p = s.grab.popup orelse return;
    p.destroy();
    s.app.core_app.alloc.destroy(p);
    s.grab.popup = null;
    s.grab.shown = .hidden;
    s.grab.opacity = 0;
}

// -- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn expectDots(size: geom.Size, dpi: u32, want: [3]geom.Rect) !void {
    const got = dots(size, dpi);
    for (want, got) |w, g| try testing.expectEqual(w, g);
}

test "win32 grab overlay: dots geometry at 96/144/192 dpi" {
    // 96: 2 px dots on a 5 px pitch (12 px wide), 3 px above the centre line (6).
    try expectDots(.{ .w = 80, .h = 12 }, 96, .{
        .{ .x = 34, .y = 2, .w = 2, .h = 2 },
        .{ .x = 39, .y = 2, .w = 2, .h = 2 },
        .{ .x = 44, .y = 2, .w = 2, .h = 2 },
    });
    // 144: 3 px dots on an 8 px pitch (19 px wide); centre line 9, lift 5.
    try expectDots(.{ .w = 120, .h = 18 }, 144, .{
        .{ .x = 50, .y = 3, .w = 3, .h = 3 },
        .{ .x = 58, .y = 3, .w = 3, .h = 3 },
        .{ .x = 66, .y = 3, .w = 3, .h = 3 },
    });
    // 192: 4 px dots on a 10 px pitch (24 px wide); centre line 12, lift 6.
    try expectDots(.{ .w = 160, .h = 24 }, 192, .{
        .{ .x = 68, .y = 4, .w = 4, .h = 4 },
        .{ .x = 78, .y = 4, .w = 4, .h = 4 },
        .{ .x = 88, .y = 4, .w = 4, .h = 4 },
    });
    // The dots stay centred in the box the handle rect gives at every scale.
    for ([_]u32{ 96, 120, 144, 168, 192, 240 }) |dpi| {
        const box = grab_handle.handleRect(.{ .w = 600, .h = 400 }, dpi);
        const r = dots(.{ .w = box.w, .h = box.h }, dpi);
        try testing.expect(r[0].x >= 0 and r[2].x + r[2].w <= box.w);
        try testing.expect(r[0].y >= 0 and r[0].y + r[0].h <= @divFloor(box.h, 2));
        try testing.expect(@abs((r[0].x) - (box.w - (r[2].x + r[2].w))) <= 1);
    }
}

test "win32 grab overlay: opacity follows the fade" {
    const a: Anim = .{ .from = 0, .to = grab_handle.bright_opacity, .start = 1000 };
    try testing.expectEqual(@as(f32, 0), a.at(1000));
    try testing.expect(!a.finished(1000));
    try testing.expectApproxEqAbs(@as(f32, 0.4), a.at(1075), 0.001);
    try testing.expect(!a.finished(1149));
    try testing.expectEqual(grab_handle.bright_opacity, a.at(1150));
    try testing.expect(a.finished(1150));
    // Long after: still the target, never past it.
    try testing.expectEqual(grab_handle.bright_opacity, a.at(5000));

    // Monotonic up, then back down from where it was.
    var prev: f32 = 0;
    var t: u64 = 1000;
    while (t <= 1150) : (t += 1) {
        const v = a.at(t);
        try testing.expect(v >= prev);
        prev = v;
    }
    const back: Anim = .{ .from = a.at(1075), .to = 0, .start = 1075 };
    try testing.expectApproxEqAbs(@as(f32, 0.4), back.at(1075), 0.001);
    try testing.expectEqual(@as(f32, 0), back.at(1225));
    // A clock that went backwards does not overflow.
    try testing.expectEqual(grab_handle.bright_opacity, a.at(10));
}

test "win32 grab overlay: alpha is opacity times 255" {
    try testing.expectEqual(@as(u8, 0), alphaByte(0));
    try testing.expectEqual(@as(u8, 77), alphaByte(grab_handle.dim_opacity));
    try testing.expectEqual(@as(u8, 204), alphaByte(grab_handle.bright_opacity));
    try testing.expectEqual(@as(u8, 255), alphaByte(2));
    try testing.expectEqual(@as(u8, 0), alphaByte(-1));
}

test "win32 grab overlay: level needs a hit area" {
    const over: grab_handle.Inputs = .{ .pointer_visible = true, .on_handle = true, .in_band = true, .dragging = false };
    try testing.expectEqual(grab_handle.Ellipsis.bright, levelFor(.auto, true, over));
    try testing.expectEqual(grab_handle.Ellipsis.hidden, levelFor(.auto, false, over));
    try testing.expectEqual(grab_handle.Ellipsis.hidden, levelFor(.always, false, over));
}

test "win32 grab overlay: only visible leaves count" {
    const Leaf = struct { visible: bool };
    try testing.expectEqual(@as(usize, 1), visibleCount(&[_]Leaf{.{ .visible = true }}));
    try testing.expectEqual(@as(usize, 1), visibleCount(&[_]Leaf{ .{ .visible = true }, .{ .visible = false } }));
    try testing.expectEqual(@as(usize, 2), visibleCount(&[_]Leaf{ .{ .visible = true }, .{ .visible = true } }));
}

test {
    _ = grab_handle;
}

test "win32 grab overlay: an eaten press eats its release, a double click is a press" {
    // Down on the handle: the drag gets it, down elsewhere: the terminal.
    try testing.expectEqual(LeftRoute.grab_press, leftRoute(true, true, false));
    try testing.expectEqual(LeftRoute.terminal, leftRoute(true, false, false));
    // The release follows the press: eaten only after an eaten press.
    try testing.expectEqual(LeftRoute.swallow_release, leftRoute(false, true, true));
    try testing.expectEqual(LeftRoute.swallow_release, leftRoute(false, false, true));
    try testing.expectEqual(LeftRoute.terminal, leftRoute(false, true, false));
    try testing.expectEqual(LeftRoute.terminal, leftRoute(false, false, false));
}

/// The `m8.grab` array of the IPC `state` op: a row per pane whose handle is
/// shown (dim or bright, even while it still fades in). Only called with
/// `GHOSTTY_WIN32_TEST_IPC=1`.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginArray();
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |e| {
                const s = e.view;
                if (s.grab.shown == .hidden) continue;
                try jw.beginObject();
                try jw.objectField("surface");
                try jw.write(s.id);
                try jw.objectField("shown");
                try jw.write(@tagName(s.grab.shown));
                try jw.objectField("opacity");
                try jw.write(s.grab.opacity);
                try jw.endObject();
            }
        }
    }
    try jw.endArray();
}
