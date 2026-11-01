//! Split drag session: a press on a pane's grab handle starts a drag of the
//! pane, which can end in the same tab, another tab, another window or a new
//! window. The pure rules (zones, the state machine, the tree helpers) are
//! `split_drag.zig`; this file owns the capture, the hit test across windows
//! and the feedback (ghost, zone highlight, strip marker, spring-loaded tab).
//!
//! The mouse is captured by the source's top-level window, never by a pane or
//! a tab container: a spring-loaded tab switch hides the source tab, and a
//! hidden capture window would lose the drag. One session per process, kept
//! in `App.split_drag`. The source pane is looked up by id on every event; a
//! pane that is gone (its shell exited) cancels the drag.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabStrip = @import("TabStrip.zig");
const Window = @import("Window.zig");
const drag_ghost = @import("drag_ghost.zig");
const geom = @import("geom.zig");
const grab_overlay = @import("grab_overlay.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");
const split_drag = @import("split_drag.zig");
const strip_input = @import("strip_input.zig");
const title_rules = @import("title_rules.zig");

const user32 = win32.user32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_split_drag);

/// How long the pointer rests on a tab chip before the tab is shown
/// (spring-loading).
const spring_ms = 500;
/// The drop zone is the accent at this opacity (macOS), 0.3 of 255.
const zone_alpha = 77;
/// `COLOR_HIGHLIGHT`: the system accent, as the command palette uses.
const color_highlight = 13;
/// Width of the chip ghost, DIP.
const chip_dip = 180;

pub const Session = struct {
    machine: split_drag.Machine,
    /// Looked up again by id on every event (the shell may exit).
    source_id: u32,
    source: *Surface,
    /// The source's top-level window, which holds the capture.
    capture: *Window,
    capture_id: u32,
    ghost: bool = false,
    /// Neither ghost could be made; do not try again on every move.
    ghost_failed: bool = false,
    zone_popup: ?*overlay.Popup = null,
    /// The window whose strip shows the insertion marker, and the slot.
    marker_window: ?u32 = null,
    marker_index: usize = 0,
    /// The chip the spring timer runs for.
    spring: ?struct { window: u32, index: usize } = null,
};

/// The drop-zone highlight: a label owned by the target window.
const ZonePopup = struct {
    popup: overlay.Popup,
    /// Screen px.
    rect: geom.Rect,
};

// -- Hit test ----------------------------------------------------------------------

pub const HitKind = enum { outside, blocked, strip, pane };

/// The order the pieces of a hit are resolved in: not one of our windows is
/// outside; a window that takes no drop blocks; the tab strip comes before
/// the panes; no pane under the point blocks.
pub fn classify(in: struct { ours: bool, accepts: bool, in_strip: bool, leaf: ?usize }) HitKind {
    if (!in.ours) return .outside;
    if (!in.accepts) return .blocked;
    if (in.in_strip) return .strip;
    if (in.leaf != null) return .pane;
    return .blocked;
}

fn windowOfRoot(app: *App, root: win32.foundation.HWND) ?*Window {
    for (app.windows.items) |w| {
        if (w.hwnd == root) return w;
    }
    return null;
}

/// Whether a window takes a split dropped on it.
fn accepts(w: *const Window) bool {
    if (w.tearing_down or w.parked) return false;
    if (user32.IsIconic(w.hwnd) != 0) return false;
    return QuickTerminal.acceptsTabDrop(w.kind);
}

/// What lies under the screen point `pt`. Our own layered popups (ghost,
/// zone highlight, handle dots) are click-through and skipped by
/// `WindowFromPoint`; an owned overlay panel resolves to its window.
pub fn hitAt(app: *App, pt: split_drag.Point, src: split_drag.Source) split_drag.Hit {
    _ = src;
    const under = user32.WindowFromPoint(.{ .x = pt.x, .y = pt.y });
    const root = if (under) |u| user32.GetAncestor(u, user32.GA_ROOTOWNER) else null;
    const w: ?*Window = if (root) |r| windowOfRoot(app, r) else null;

    var in_strip = false;
    var slot: usize = 0;
    var over: ?usize = null;
    var leaf_index: ?usize = null;
    var rect: geom.Rect = .{};
    var tab_id: u32 = 0;
    var surface_id: u32 = 0;

    if (w) |win| if (accepts(win)) {
        var c: win32.foundation.POINT = .{ .x = pt.x, .y = pt.y };
        _ = user32.ScreenToClient(win.hwnd, &c);
        if (win.strip.show_tabs and win.strip.bounds.contains(c.x, c.y)) {
            in_strip = true;
            slot = strip_input.insertionIndex(win.strip.tabs.items, c.x);
            const m = TabStrip.Metrics.forDpi(win.dpi);
            over = switch (win.strip.hitTest(m, c.x, c.y, user32.IsZoomed(win.hwnd) != 0)) {
                .tab, .tab_close => |i| i,
                else => null,
            };
            // The tab on screen needs no switch.
            if (over) |i| if (win.active_tab == i) {
                over = null;
            };
        } else if (win.activeTab()) |tab| {
            const alloc = app.core_app.alloc;
            if (tab.leafRects(alloc)) |layout| {
                var l = layout;
                defer l.deinit(alloc);
                var origin: win32.foundation.POINT = .{ .x = 0, .y = 0 };
                _ = user32.ClientToScreen(tab.hwnd, &origin);
                for (l.leaves, 0..) |leaf, i| {
                    if (!leaf.visible) continue;
                    const r: geom.Rect = .{ .x = leaf.rect.x + origin.x, .y = leaf.rect.y + origin.y, .w = leaf.rect.w, .h = leaf.rect.h };
                    if (!r.contains(pt.x, pt.y)) continue;
                    leaf_index = i;
                    rect = r;
                    tab_id = tab.id;
                    surface_id = leaf.view.id;
                    break;
                }
            } else |_| {}
        }
    };

    const kind = classify(.{
        .ours = w != null,
        .accepts = if (w) |win| accepts(win) else false,
        .in_strip = in_strip,
        .leaf = leaf_index,
    });
    return switch (kind) {
        .outside => .outside,
        .blocked => .blocked,
        .strip => .{ .strip = .{ .window = w.?.id, .slot = slot, .over = over } },
        .pane => .{ .pane = .{
            .window = w.?.id,
            .tab = tab_id,
            .surface = surface_id,
            .zone = split_drag.zoneAt(pt.x, pt.y, rect),
            .rect = rect,
        } },
    };
}

// -- Entry points ------------------------------------------------------------------

fn paneSize(s: *const Surface) geom.Size {
    var rc: win32.foundation.RECT = undefined;
    if (user32.GetClientRect(s.hwnd, &rc) == 0) return .{ .w = 0, .h = 0 };
    return .{ .w = rc.right - rc.left, .h = rc.bottom - rc.top };
}

/// The pane's client area in screen px.
fn paneScreenRect(s: *const Surface) geom.Rect {
    var origin: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    _ = user32.ClientToScreen(s.hwnd, &origin);
    const size = paneSize(s);
    return .{ .x = origin.x, .y = origin.y, .w = size.w, .h = size.h };
}

fn chipSize(window: *const Window) geom.Rect {
    const m = TabStrip.Metrics.forDpi(window.dpi);
    return .{ .w = geom.scale(chip_dip, window.dpi), .h = m.tab_h };
}

/// More than one pane shown in the tab.
fn tabSplit(tab: *const Tab) bool {
    if (tab.split_layout) |l| return grab_overlay.visibleCount(l.leaves) > 1;
    return tab.tree.isSplit();
}

/// A left press on the grab handle of `s` at the client point `(x, y)`; the
/// press has been eaten (the terminal does not see it). Starts the drag
/// session. (The second press of a double click comes here too; the first
/// press' session has ended by then, and a session that still runs wins.)
pub fn press(s: *Surface, x: i32, y: i32) void {
    const app = s.app;
    if (app.split_drag != null) return;
    const window = s.window;
    const tab = s.tab;
    if (window.tearing_down or tab.parked or window.parked) return;

    var origin: win32.foundation.POINT = .{ .x = x, .y = y };
    _ = user32.ClientToScreen(s.hwnd, &origin);

    // The size the ghost will have: the picture, else the chip.
    const pane = paneSize(s);
    const chip = chipSize(window);
    const ghost: geom.Size = switch (drag_ghost.pickMode(app.secure.on, pane)) {
        .image => drag_ghost.snapshotSize(pane) orelse .{ .w = chip.w, .h = chip.h },
        .chip => .{ .w = chip.w, .h = chip.h },
    };
    const src: split_drag.Source = .{
        .window = window.id,
        .tab = tab.id,
        .surface = s.id,
        .tab_split = tabSplit(tab),
        .window_tabs = window.tabs.items.len,
        .grab = .{ .x = x, .y = y },
    };
    const m = TabStrip.Metrics.forDpi(window.dpi);
    app.split_drag = .{
        .machine = split_drag.Machine.begin(src, .{ .x = origin.x, .y = origin.y }, ghost, m.drag_threshold),
        .source_id = s.id,
        .source = s,
        .capture = window,
        .capture_id = window.id,
    };
    _ = user32.SetCapture(window.hwnd);
}

/// A message of a top-level window while a drag session runs (capture,
/// motion, release, cancel). Null: not handled, the next hook gets it.
pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    const app = window.app;
    const sess = &(app.split_drag orelse return null);
    if (sess.capture_id != window.id) return null;
    switch (msg) {
        user32.WM_MOUSEMOVE => {
            if (wparam & user32.MK_LBUTTON == 0) {
                end(app, .cancel, true);
            } else {
                feedMove(app, screenPoint(window, lparam));
            }
            return 0;
        },
        user32.WM_LBUTTONUP => {
            // The button went up where the last move said; the release itself
            // may be a pixel further.
            feedMove(app, screenPoint(window, lparam));
            end(app, .release, true);
            return 0;
        },
        // The capture was taken (Alt+Tab, a dialog): the drag is over, and
        // the focus is leaving, so do not take it back.
        user32.WM_CAPTURECHANGED => {
            end(app, .cancel, false);
            return 0;
        },
        user32.WM_KEYDOWN => {
            if (wparam != user32.VK_ESCAPE) return null;
            end(app, .cancel, true);
            return 0;
        },
        user32.WM_TIMER => {
            if (wparam != messages.timers.window.split_drag_spring) return null;
            feedSpring(app);
            return 0;
        },
        // The window holds the focus during the drag so that Esc reaches it.
        user32.WM_SETFOCUS => {
            if (sess.machine.state == .dragging) return 0;
            return null;
        },
        user32.WM_SETCURSOR => {
            if (user32.loWord(@bitCast(lparam)) != user32.HTCLIENT) return null;
            _ = user32.SetCursor(user32.LoadCursorW(null, user32.IDC_SIZEALL));
            return 1;
        },
        else => return null,
    }
}

fn screenPoint(window: *const Window, lparam: LPARAM) split_drag.Point {
    var pt: win32.foundation.POINT = .{ .x = user32.getXLparam(lparam), .y = user32.getYLparam(lparam) };
    _ = user32.ClientToScreen(window.hwnd, &pt);
    return .{ .x = pt.x, .y = pt.y };
}

// -- Events ------------------------------------------------------------------------

/// The source pane, if it is still in a tab of a live window.
fn findSource(app: *App, id: u32) ?*Surface {
    for (app.windows.items) |w| {
        if (w.tearing_down) continue;
        if (w.findSurface(id)) |s| return s;
    }
    return null;
}

fn feedMove(app: *App, pt: split_drag.Point) void {
    const sess = &(app.split_drag orelse return);
    const src = findSource(app, sess.source_id) orelse return end(app, .cancel, false);
    sess.source = src;
    const hit = hitAt(app, pt, sess.machine.src);
    const was_pressed = sess.machine.state == .pressed;
    const fb = sess.machine.feed(.{ .move = .{ .pt = pt, .hit = hit } });
    apply(app, sess, src, fb, pt);
    if (app.split_drag == null) return;
    if (was_pressed and sess.machine.state == .dragging) {
        // The window holds the focus from here on, so that Esc reaches it.
        _ = user32.SetFocus(sess.capture.hwnd);
    }
}

fn feedSpring(app: *App) void {
    const sess = &(app.split_drag orelse return);
    const src = findSource(app, sess.source_id) orelse return end(app, .cancel, false);
    const fb = sess.machine.feed(.spring_fired);
    apply(app, sess, src, fb, sess.machine.last_pt);
}

const EndKind = enum { release, cancel };

/// Finish the session with a release or a cancel. `refocus`: give the
/// keyboard focus back to the source pane when nothing moved.
fn end(app: *App, kind: EndKind, refocus: bool) void {
    const sess = &(app.split_drag orelse return);
    const fb = sess.machine.feed(if (kind == .release) .release else .cancel);
    const outcome = fb.done orelse split_drag.Outcome.cancelled;
    finish(app, outcome, refocus);
}

/// Apply the feedback of one event.
fn apply(app: *App, sess: *Session, src: *Surface, fb: split_drag.Feedback, pt: split_drag.Point) void {
    if (fb.done) |outcome| return finish(app, outcome, true);

    if (fb.ghost) |at| {
        if (sess.ghost) {
            drag_ghost.moveTo(at);
        } else if (!sess.ghost_failed) {
            showGhost(app, sess, src, at, pt);
        }
    }
    setZone(app, sess, if (fb.zone) |z| .{ .window = z.window, .rect = z.rect } else null);
    setMarker(app, sess, if (fb.marker) |mk| .{ .window = mk.window, .index = mk.index } else null);

    if (fb.spring_cancel) {
        _ = user32.KillTimer(sess.capture.hwnd, messages.timers.window.split_drag_spring);
        sess.spring = null;
    }
    if (fb.spring) |sp| {
        sess.spring = .{ .window = sp.window, .index = sp.index };
        _ = user32.SetTimer(sess.capture.hwnd, messages.timers.window.split_drag_spring, spring_ms, null);
    }
    if (fb.select) |sel| {
        if (strip_input.windowById(app, sel.window)) |w| w.selectTabFocus(sel.index, false);
    }
}

// -- Ghost -------------------------------------------------------------------------

/// The drag started: the dots leave the picture, the snapshot is taken, the
/// ghost shows (the chip when the screen cannot be read).
fn showGhost(app: *App, sess: *Session, src: *Surface, at: split_drag.Point, pt: split_drag.Point) void {
    const window = src.window;
    const pane = paneSize(src);
    var shown = false;

    if (drag_ghost.pickMode(app.secure.on, pane) == .image) image: {
        const size = drag_ghost.snapshotSize(pane) orelse break :image;
        // The handle dots must not be in the picture; the screen DC sees the
        // composed desktop, so wait for a frame without them.
        if (src.grab.popup) |p| {
            p.hide();
            _ = win32.dwmapi.DwmFlush();
        }
        const alloc = app.core_app.alloc;
        const bits = drag_ghost.capture(alloc, paneScreenRect(src), size) orelse break :image;
        defer alloc.free(bits);
        shown = drag_ghost.showImage(app, bits, size, at);
    }

    if (!shown) {
        const chip = chipSize(window);
        // The chip is centred on the pointer like the picture; the machine
        // centres the following moves on its size too.
        sess.machine.ghost = .{ .w = chip.w, .h = chip.h };
        const origin: split_drag.Point = .{ .x = pt.x - @divFloor(chip.w, 2), .y = pt.y - @divFloor(chip.h, 2) };
        const title = src.shownTitle();
        drag_ghost.show(app, window, if (title.len == 0) title_rules.fallback else title, chip, origin);
    }
    sess.ghost = drag_ghost.currentMode() != null;
    sess.ghost_failed = !sess.ghost;

    // Dragging keeps the dots bright; bring them back after the snapshot.
    grab_overlay.setDragging(src, true);
    if (src.grab.popup) |p| {
        if (!p.visible and src.grab.shown != .hidden) p.show() catch {};
    }
}

// -- Drop zone ---------------------------------------------------------------------

const ZoneTarget = struct { window: u32, rect: geom.Rect };

fn zoneOf(p: *overlay.Popup) *ZonePopup {
    return @fieldParentPtr("popup", p);
}

fn zonePlace(p: *overlay.Popup, surface: geom.Rect, size_px: geom.Size) geom.Rect {
    _ = surface;
    _ = size_px;
    return zoneOf(p).rect;
}

fn zonePaint(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    _ = p;
    const ref = user32.GetSysColor(color_highlight);
    const fill: @import("theme.zig").Color = .{
        .r = @truncate(ref),
        .g = @truncate(ref >> 8),
        .b = @truncate(ref >> 16),
        .a = zone_alpha,
    };
    const items = [_]Chrome.Item{.{ .box = .{ .rect = ctx.rect, .radius = 0, .fill = fill } }};
    Chrome.paintItems(ctx.hdc, ctx.rect, &items, ctx.palette, ctx.dpi, null) catch |err| {
        log.warn("unable to paint the drop zone err={}", .{err});
    };
}

fn destroyZone(app: *App, sess: *Session) void {
    const p = sess.zone_popup orelse return;
    sess.zone_popup = null;
    const z = zoneOf(p);
    p.destroy();
    app.core_app.alloc.destroy(z);
}

/// Show the highlight over `target` (screen px), move it, or hide it (null).
fn setZone(app: *App, sess: *Session, target: ?ZoneTarget) void {
    const t = target orelse {
        if (sess.zone_popup) |p| p.hide();
        return;
    };
    const window = strip_input.windowById(app, t.window) orelse {
        if (sess.zone_popup) |p| p.hide();
        return;
    };
    // The highlight is owned by the window it is over.
    if (sess.zone_popup) |p| if (p.window != window) destroyZone(app, sess);

    const z: *ZonePopup = if (sess.zone_popup) |p| zoneOf(p) else blk: {
        const z = app.core_app.alloc.create(ZonePopup) catch |err| {
            log.warn("unable to make the drop zone err={}", .{err});
            return;
        };
        z.* = .{
            .popup = .{
                .kind = .label,
                .anchor = .surface_top_full,
                .window = window,
                .size = .{ .w = 1, .h = 1 },
                .margin = 0,
                .paint = zonePaint,
                .place = zonePlace,
                .click_through = true,
            },
            .rect = t.rect,
        };
        sess.zone_popup = &z.popup;
        break :blk z;
    };
    if (z.popup.visible and std.meta.eql(z.rect, t.rect)) return;
    z.rect = t.rect;
    z.popup.show() catch |err| log.warn("unable to show the drop zone err={}", .{err});
}

// -- Strip marker ------------------------------------------------------------------

const MarkerTarget = struct { window: u32, index: usize };

fn setMarker(app: *App, sess: *Session, target: ?MarkerTarget) void {
    if (sess.marker_window) |old| {
        if (target == null or target.?.window != old) {
            strip_input.showDropMarker(app, old, null);
            sess.marker_window = null;
        }
    }
    const t = target orelse return;
    strip_input.showDropMarker(app, t.window, t.index);
    sess.marker_window = t.window;
    sess.marker_index = t.index;
}

// -- End ---------------------------------------------------------------------------

/// Tear the session down: capture, ghost, highlight, marker, timer, the
/// source's dots. The session is already out of `App.split_drag`.
fn cleanup(app: *App, sess: *Session) void {
    // (Releasing the capture sends WM_CAPTURECHANGED to our own hook, which
    // finds no session.)
    if (user32.GetCapture()) |c| {
        if (strip_input.windowById(app, sess.capture_id)) |w| {
            if (c == w.hwnd) _ = user32.ReleaseCapture();
        }
    }
    if (sess.ghost) drag_ghost.hide();
    sess.ghost = false;
    destroyZone(app, sess);
    setMarker(app, sess, null);
    if (strip_input.windowById(app, sess.capture_id)) |w| {
        _ = user32.KillTimer(w.hwnd, messages.timers.window.split_drag_spring);
    }
    sess.spring = null;
    if (findSource(app, sess.source_id)) |s| {
        s.grab.press_eaten = false;
        grab_overlay.setDragging(s, false);
    }
}

/// The tab that takes the keyboard focus once nothing moved: the source
/// tab, unless a spring-loaded switch put another one on screen (focus on
/// the hidden pane would swallow the typing).
fn focusTabFor(comptime T: type, source: T, active: ?T) ?T {
    const a = active orelse return null;
    return if (a == source) source else a;
}

fn focusSource(s: *Surface) void {
    const tab = focusTabFor(*Tab, s.tab, s.window.activeTab()) orelse return;
    tab.focus();
}

/// End the session with `outcome` and apply it.
fn finish(app: *App, outcome: split_drag.Outcome, refocus: bool) void {
    var sess = app.split_drag orelse return;
    app.split_drag = null;
    cleanup(app, &sess);
    const src = findSource(app, sess.source_id) orelse return;

    switch (outcome) {
        .none => focusSource(src),
        .cancelled => if (refocus) focusSource(src),
        .to_pane => |t| toPane(app, src, t),
        .new_tab => |t| newTab(app, src, t.window, t.index),
        // (The outcome's own point is pointer - grab, the content's corner;
        // the window origin is worked out from the pointer.)
        .new_window => newWindow(app, src, sess.machine.last_pt, sess.machine.src.grab),
    }
}

/// Whether a pane may leave for a window of its own: the window takes drops
/// (not the quick terminal, not parked, not closing) and the pane is not the
/// only thing there is to move (the same rule as `outsideOutcome`, looked at
/// again when the drag ends, since the tabs may have changed meanwhile).
pub fn newWindowAllowed(in: struct { tab_split: bool, window_tabs: usize, accepts: bool }) bool {
    if (!in.accepts) return false;
    return in.tab_split or in.window_tabs > 1;
}

/// Drop outside every window: the pane gets a window of its own, as large as
/// the pane was, with the grabbed point under the pointer.
fn newWindow(app: *App, src: *Surface, pointer: split_drag.Point, grab: split_drag.Point) void {
    const window = src.window;
    if (!newWindowAllowed(.{
        .tab_split = tabSplit(src.tab),
        .window_tabs = window.tabs.items.len,
        .accepts = accepts(window) and !src.tab.parked,
    })) return focusSource(src);

    // Everything is measured before anything moves.
    const pane = paneSize(src);
    const at = paneScreenRect(src);
    var wr: win32.foundation.RECT = undefined;
    if (user32.GetWindowRect(window.hwnd, &wr) == 0) return focusSource(src);
    const offset: split_drag.Point = .{ .x = at.x - wr.left, .y = at.y - wr.top };
    const origin = split_drag.newWindowOrigin(pointer, grab, offset, window.dpi, window.dpi);

    const new = Window.createForTearOff(app, .{ .x = origin.x, .y = origin.y }, window, .{ .w = pane.w, .h = pane.h }) catch |err| {
        log.warn("unable to make a window for the split err={}", .{err});
        return focusSource(src);
    };
    if (new.dpi != window.dpi) {
        // The grab and the offset were measured in source pixels.
        const o = split_drag.newWindowOrigin(pointer, grab, offset, window.dpi, new.dpi);
        _ = user32.SetWindowPos(new.hwnd, null, o.x, o.y, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    }

    // (`createForTearOff` reserved the room for the tab.) The window has no
    // tab to lose: when anything fails it is simply destroyed again.
    const tab = Tab.createAdopting(new, src) catch |err| {
        log.warn("unable to make a tab for the split err={}", .{err});
        new.destroy();
        return focusSource(src);
    };
    new.tabs.appendAssumeCapacity(tab);
    tab.adopt(src) catch |err| {
        log.warn("unable to move the split to a new window err={}", .{err});
        tab.dropAdopting();
        new.removeTab(tab);
        return focusSource(src);
    };
    new.selectTabFocus(0, false);
    new.showPlain();
    new.activate();
}

fn findTab(window: *const Window, id: u32) ?*Tab {
    for (window.tabs.items) |t| {
        if (t.id == id) return t;
    }
    return null;
}

fn findIn(tab: *const Tab, id: u32) ?*Surface {
    var it = tab.tree.iterator();
    while (it.next()) |e| {
        if (e.view.id == id) return e.view;
    }
    return null;
}

/// Drop onto a pane: the same tab rearranges, another tab adopts the pane.
fn toPane(app: *App, src: *Surface, t: @FieldType(split_drag.Outcome, "to_pane")) void {
    const window = strip_input.windowById(app, t.window) orelse return focusSource(src);
    const tab = findTab(window, t.tab) orelse return focusSource(src);
    const dst = findIn(tab, t.surface) orelse return focusSource(src);
    const dir = split_drag.treeDirection(Surface.Tree, t.zone);
    // (`adoptNextTo` moves within the tab when `src` already lives in it.)
    tab.adoptNextTo(src, dst, dir) catch |err| {
        log.warn("unable to move the split err={}", .{err});
        focusSource(src);
    };
}

/// Drop onto a tab strip: the pane becomes a tab of its own at `slot`.
fn newTab(app: *App, src: *Surface, window_id: u32, slot: usize) void {
    const window = strip_input.windowById(app, window_id) orelse return focusSource(src);
    if (!accepts(window)) return focusSource(src);
    // A lone pane of a lone tab dropped on its own strip stays where it is.
    if (src.window == window and window.tabs.items.len == 1 and !src.tab.tree.isSplit()) {
        return focusSource(src);
    }
    const alloc = app.core_app.alloc;
    window.tabs.ensureUnusedCapacity(alloc, 1) catch return focusSource(src);
    const tab = Tab.createAdopting(window, src) catch |err| {
        log.warn("unable to make a tab for the split err={}", .{err});
        return focusSource(src);
    };
    window.insertTab(tab, slot);
    tab.adopt(src) catch |err| {
        log.warn("unable to move the split to a new tab err={}", .{err});
        tab.dropAdopting();
        window.removeTab(tab);
        focusSource(src);
    };
}

// -- Tests -------------------------------------------------------------------------

test "win32 split drag input: hit resolution order" {
    const t = std.testing;
    // Not one of our windows: outside, whatever else is claimed.
    try t.expectEqual(HitKind.outside, classify(.{ .ours = false, .accepts = true, .in_strip = true, .leaf = 0 }));
    // A window that takes no drop blocks, strip and pane included.
    try t.expectEqual(HitKind.blocked, classify(.{ .ours = true, .accepts = false, .in_strip = true, .leaf = 0 }));
    try t.expectEqual(HitKind.blocked, classify(.{ .ours = true, .accepts = false, .in_strip = false, .leaf = 1 }));
    // The strip comes before the panes.
    try t.expectEqual(HitKind.strip, classify(.{ .ours = true, .accepts = true, .in_strip = true, .leaf = 0 }));
    try t.expectEqual(HitKind.strip, classify(.{ .ours = true, .accepts = true, .in_strip = true, .leaf = null }));
    // A pane.
    try t.expectEqual(HitKind.pane, classify(.{ .ours = true, .accepts = true, .in_strip = false, .leaf = 2 }));
    // No leaf under the point (title bar, a divider): blocked.
    try t.expectEqual(HitKind.blocked, classify(.{ .ours = true, .accepts = true, .in_strip = false, .leaf = null }));
}

/// The capture window is being destroyed: the drag ends without an outcome
/// (no `WM_CAPTURECHANGED` is guaranteed on every teardown path).
pub fn windowDestroying(window: *Window) void {
    const sess = window.app.split_drag orelse return;
    if (sess.capture_id != window.id) return;
    finish(window.app, .cancelled, false);
}

/// The `m8.split_drag` object of the IPC `state` op. Only called with
/// `GHOSTTY_WIN32_TEST_IPC=1`.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    const sess = app.split_drag;
    try jw.objectField("active");
    try jw.write(sess != null);

    try jw.objectField("ghost");
    if (drag_ghost.currentMode()) |mode| try jw.write(@tagName(mode)) else try jw.write(null);

    try jw.objectField("zone");
    zone: {
        const s = sess orelse break :zone try jw.write(null);
        const p = s.zone_popup orelse break :zone try jw.write(null);
        if (!p.visible) break :zone try jw.write(null);
        const r = zoneOf(p).rect;
        try jw.write([4]i32{ r.x, r.y, r.w, r.h });
    }

    try jw.objectField("marker");
    marker: {
        const s = sess orelse break :marker try jw.write(null);
        const w = s.marker_window orelse break :marker try jw.write(null);
        try jw.beginObject();
        try jw.objectField("window");
        try jw.write(w);
        try jw.objectField("index");
        try jw.write(s.marker_index);
        try jw.endObject();
    }
    try jw.endObject();
}

test "win32 split drag input: new window only when allowed" {
    const t = std.testing;
    // A split tab, or a window with other tabs, may give a pane away.
    try t.expect(newWindowAllowed(.{ .tab_split = true, .window_tabs = 1, .accepts = true }));
    try t.expect(newWindowAllowed(.{ .tab_split = false, .window_tabs = 2, .accepts = true }));
    // A lone pane of a lone tab stays (macOS).
    try t.expect(!newWindowAllowed(.{ .tab_split = false, .window_tabs = 1, .accepts = true }));
    // A window that takes no drop (quick terminal, parked, closing) gives nothing.
    try t.expect(!newWindowAllowed(.{ .tab_split = true, .window_tabs = 3, .accepts = false }));
    // The same rule as the machine's: the two agree on every source.
    const grab: split_drag.Point = .{ .x = 1, .y = 1 };
    for ([_]bool{ false, true }) |split| {
        for ([_]usize{ 1, 2, 5 }) |tabs| {
            const src: split_drag.Source = .{ .window = 1, .tab = 1, .surface = 1, .tab_split = split, .window_tabs = tabs, .grab = grab };
            const out = split_drag.outsideOutcome(src, .{ .x = 10, .y = 10 }, grab);
            const machine_says = out == .new_window;
            try t.expectEqual(machine_says, newWindowAllowed(.{ .tab_split = split, .window_tabs = tabs, .accepts = true }));
        }
    }
}

test "win32 split drag input: refocus follows the tab on screen" {
    const t = std.testing;
    var a: u8 = 0;
    var b: u8 = 0;
    // The source tab is still shown: it gets the focus.
    try t.expectEqual(@as(?*u8, &a), focusTabFor(*u8, &a, &a));
    // A spring-loaded switch put another tab on screen: that one does.
    try t.expectEqual(@as(?*u8, &b), focusTabFor(*u8, &a, &b));
    // Nothing on screen: nobody.
    try t.expectEqual(@as(?*u8, null), focusTabFor(*u8, &a, null));
}
