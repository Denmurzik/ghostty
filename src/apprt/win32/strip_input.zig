//! Mouse input on the tab strip: hover, click, tab drag, wheel scroll and
//! the inline title editor's result. Caption buttons and the caption itself
//! are non-client and belong to `frame.zig`; this sees the client messages,
//! so only tabs, their close buttons and the new-tab button.
const std = @import("std");
const win32 = @import("win32");
const Chrome = @import("Chrome.zig");
const TabStrip = @import("TabStrip.zig");
const Window = @import("Window.zig");
const geom = @import("geom.zig");
const messages = @import("messages.zig");
const title_edit = @import("title_edit.zig");
const App = @import("App.zig");
const Tab = @import("Tab.zig");
const drag_ghost = @import("drag_ghost.zig");
const tab_drag = @import("tab_drag.zig");

const user32 = win32.user32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_strip_input);

const MK_LBUTTON = 0x0001;

/// A tab drag through `tab_drag.Machine`, from the press to the outcome.
pub const Session = struct {
    machine: tab_drag.Machine,
    tab: *Tab,
    /// The chip of the ghost, pixels at the source window's DPI.
    chip: geom.Rect,
    ghost: bool = false,
    /// The window whose strip shows the insertion marker.
    marker: ?u32 = null,
};

pub const State = struct {
    /// What the painter draws for the dragged tab.
    drag: ?TabStrip.Drag = null,
    session: ?Session = null,
    hover: TabStrip.Part = .nowhere,
    tracking: bool = false,
    /// Insertion marker drawn while another window's tab is dragged over
    /// this strip (Task 32).
    drop_index: ?usize = null,
    /// The pointer x (client px) of the last mouse message of a tab drag;
    /// the painter places the dragged tab with it.
    pointer_x: i32 = 0,
    /// The inline title editor, while there is one.
    edit: ?title_edit.Session = null,
};

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        user32.WM_LBUTTONDOWN, user32.WM_LBUTTONDBLCLK => {
            const x = user32.getXLparam(lparam);
            const y = user32.getYLparam(lparam);
            const part = hitTest(window, x, y);
            if (msg == user32.WM_LBUTTONDBLCLK) switch (part) {
                .tab => |i| {
                    if (title_edit.tabRect(window, i)) |rect| {
                        const tab = window.tabs.items[i];
                        title_edit.beginFor(window, .tab, tab.id, rect, tab.title());
                    }
                    return 0;
                },
                // The second press of a double click is not another click.
                .tab_close, .new_tab => return 0,
                else => {},
            };
            switch (part) {
                .tab => |i| {
                    window.selectTab(i);
                    beginDrag(window, i, x, y);
                },
                .tab_close => |i| {
                    postClose(window, i);
                    focusActive(window);
                },
                .new_tab => {
                    addTab(window);
                    focusActive(window);
                },
                else => return null,
            }
            return 0;
        },

        user32.WM_MOUSEMOVE => {
            trackLeave(window);
            const x = user32.getXLparam(lparam);
            setHover(window, hoverOf(hitTest(window, x, user32.getYLparam(lparam))));
            if (window.strip_input.session != null) {
                if (wparam & MK_LBUTTON == 0) {
                    finish(window, .cancel, true);
                } else {
                    dragTo(window, x, user32.getYLparam(lparam));
                }
            }
            return null;
        },

        user32.WM_LBUTTONUP => {
            if (window.strip_input.session == null) return null;
            finish(window, .release, true);
            return 0;
        },

        // The capture was taken (Alt+Tab, a dialog): the drag is over.
        user32.WM_CAPTURECHANGED => {
            // The focus is leaving (Alt+Tab, a dialog): do not take it back.
            if (window.strip_input.session != null) finish(window, .cancel, false);
            return null;
        },

        user32.WM_KEYDOWN => {
            if (window.strip_input.session == null or wparam != user32.VK_ESCAPE) return null;
            finish(window, .cancel, true);
            return 0;
        },

        // The window holds the focus during a drag so that Esc reaches it.
        user32.WM_SETFOCUS => {
            if (window.strip_input.session != null) return 0;
            return null;
        },

        user32.WM_MBUTTONUP => {
            switch (hitTest(window, user32.getXLparam(lparam), user32.getYLparam(lparam))) {
                .tab => |i| postClose(window, i),
                .tab_close => |i| postClose(window, i),
                else => return null,
            }
            focusActive(window);
            return 0;
        },

        user32.WM_MOUSELEAVE => {
            window.strip_input.tracking = false;
            setHover(window, .nowhere);
            return null;
        },

        // The wheel carries screen coordinates.
        user32.WM_MOUSEWHEEL => {
            var pt: win32.foundation.POINT = .{ .x = user32.getXLparam(lparam), .y = user32.getYLparam(lparam) };
            _ = user32.ScreenToClient(window.hwnd, &pt);
            const strip = &window.strip;
            if (!strip.show_tabs or !strip.bounds.contains(pt.x, pt.y) or strip.tabs.items.len == 0) return null;
            const delta: i32 = @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16))));
            // Half a tab per notch, the wheel up scrolls towards the first tab.
            const step = @divTrunc(strip.tabs.items[0].w, 2);
            strip.scrollBy(-@divTrunc(delta * step, user32.WHEEL_DELTA));
            Chrome.invalidate(window);
            return 0;
        },

        messages.WM_GHOSTTY_TITLE_EDIT_DONE => {
            title_edit.complete(window, lparam, wparam != 0);
            focusActive(window);
            return 0;
        },

        else => return null,
    }
}

fn hitTest(window: *const Window, x: i32, y: i32) TabStrip.Part {
    const m = TabStrip.Metrics.forDpi(window.dpi);
    return window.strip.hitTest(m, x, y, user32.IsZoomed(window.hwnd) != 0);
}

/// The parts the client hover shows; caption buttons are the frame's.
fn hoverOf(part: TabStrip.Part) TabStrip.Part {
    return switch (part) {
        .tab, .tab_close, .new_tab => part,
        else => .nowhere,
    };
}

fn trackLeave(window: *Window) void {
    if (window.strip_input.tracking) return;
    var tme: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE, .hwndTrack = window.hwnd };
    if (user32.TrackMouseEvent(&tme) != 0) window.strip_input.tracking = true;
}

fn setHover(window: *Window, part: TabStrip.Part) void {
    if (std.meta.eql(window.strip_input.hover, part)) return;
    window.strip_input.hover = part;
    // The two hovers are exclusive: the client one wins while it is set.
    if (part != .nowhere) window.frame.hover = .nowhere;
    Chrome.invalidate(window);
}

fn beginDrag(window: *Window, index: usize, x: i32, y: i32) void {
    // The selection may have scrolled the strip.
    if (index >= window.strip.tabs.items.len) return;
    const rect = window.strip.tabs.items[index];
    window.strip_input.drag = .{
        .tab = index,
        .start_x = x,
        .grab_dx = x - rect.x,
        .current = index,
    };
    window.strip_input.pointer_x = x;

    const press = toScreen(window, x, y);
    const origin = toScreen(window, window.strip.bounds.x, window.strip.bounds.y);
    var wr: win32.foundation.RECT = .{ .left = origin.x, .top = origin.y, .right = 0, .bottom = 0 };
    _ = user32.GetWindowRect(window.hwnd, &wr);
    const m = TabStrip.Metrics.forDpi(window.dpi);
    window.strip_input.session = .{
        .machine = tab_drag.Machine.begin(
            window.id,
            index,
            window.tabs.items.len,
            press,
            .{ .x = x - rect.x, .y = y - rect.y },
            .{
                .strip = .{ .x = origin.x, .y = origin.y, .w = window.strip.bounds.w, .h = window.strip.bounds.h },
                .window_offset = .{ .x = origin.x - wr.left, .y = origin.y - wr.top },
            },
            m.drag_threshold,
            tab_drag.detachMargin(window.dpi),
        ),
        .tab = window.tabs.items[index],
        .chip = .{ .w = rect.w, .h = rect.h },
    };
    _ = user32.SetCapture(window.hwnd);
}

fn toScreen(window: *const Window, x: i32, y: i32) tab_drag.Point {
    var pt: win32.foundation.POINT = .{ .x = x, .y = y };
    _ = user32.ClientToScreen(window.hwnd, &pt);
    return .{ .x = pt.x, .y = pt.y };
}

/// The slot a tab dropped at `x` takes: the first tab whose centre is right
/// of `x`, else after the last one.
pub fn insertionIndex(tabs: []const geom.Rect, x: i32) usize {
    for (tabs, 0..) |r, i| {
        if (x < r.x + @divTrunc(r.w, 2)) return i;
    }
    return tabs.len;
}

/// What lies under a screen point: the tab strip of one of this process's
/// windows (insertion slot) or nothing.
pub fn hitAt(app: *App, pt: tab_drag.Point) tab_drag.Hit {
    const under = user32.WindowFromPoint(.{ .x = pt.x, .y = pt.y }) orelse return .none;
    const root = user32.GetAncestor(under, user32.GA_ROOT) orelse return .none;
    for (app.windows.items) |w| {
        if (w.hwnd != root or w.tearing_down) continue;
        var c: win32.foundation.POINT = .{ .x = pt.x, .y = pt.y };
        _ = user32.ScreenToClient(w.hwnd, &c);
        if (!w.strip.show_tabs or !w.strip.bounds.contains(c.x, c.y)) return .none;
        return .{ .strip = .{ .window = w.id, .index = insertionIndex(w.strip.tabs.items, c.x) } };
    }
    return .none;
}

/// `hitAt` for the drag's source window, whose strip answers with the
/// destination index of a live reorder.
fn hitFor(window: *Window, pt: tab_drag.Point) tab_drag.Hit {
    const hit = hitAt(window.app, pt);
    switch (hit) {
        .strip => |s| if (s.window == window.id) {
            var d = window.strip_input.drag orelse return hit;
            d.active = true;
            var c: win32.foundation.POINT = .{ .x = pt.x, .y = pt.y };
            _ = user32.ScreenToClient(window.hwnd, &c);
            _ = TabStrip.dragUpdate(&d, &window.strip, TabStrip.Metrics.forDpi(window.dpi), c.x);
            return .{ .strip = .{ .window = s.window, .index = d.current } };
        },
        .none => {},
    }
    return hit;
}

fn windowById(app: *App, id: u32) ?*Window {
    for (app.windows.items) |w| {
        if (w.id == id) return w;
    }
    return null;
}

fn dragTo(window: *Window, x: i32, y: i32) void {
    const s = &(window.strip_input.session orelse return);
    if (window.tabIndex(s.tab) == null or window.tabs.items.len != s.machine.tab_count) {
        // A tab ended behind the drag (its shell exited): the machine's
        // indices are stale.
        finish(window, .cancel, false);
        return;
    }
    window.strip_input.pointer_x = x;
    const pt = toScreen(window, x, y);
    const was_pressed = s.machine.state == .pressed;
    const fb = s.machine.feed(.{ .move = .{ .pt = pt, .hit = hitFor(window, pt) } });

    if (fb.live_reorder) |r| window.moveTab(r.from, r.to);
    setMarker(window, s, if (fb.marker) |mk| .{ .window = mk.window, .index = mk.index } else null);
    if (fb.ghost) |at| {
        if (s.ghost) {
            drag_ghost.moveTo(at);
        } else {
            drag_ghost.show(window.app, window, s.tab.title(), s.chip, at);
            s.ghost = true;
        }
    } else if (s.ghost) {
        drag_ghost.hide();
        s.ghost = false;
    }

    // The window holds the focus from here on, so that Esc reaches it.
    if (was_pressed and s.machine.state != .pressed) _ = user32.SetFocus(window.hwnd);
    if (window.strip_input.drag) |*d| {
        d.active = s.machine.state == .in_strip;
        d.current = s.machine.index;
    }
    Chrome.invalidate(window);
}

const Marker = struct { window: u32, index: usize };

/// Show the insertion marker in the strip `to` names, remove it elsewhere.
fn setMarker(window: *Window, s: *Session, to: ?Marker) void {
    if (s.marker) |old| {
        if (to == null or to.?.window != old) {
            if (windowById(window.app, old)) |w| {
                w.strip_input.drop_index = null;
                Chrome.invalidate(w);
            }
            s.marker = null;
        }
    }
    const t = to orelse return;
    const w = windowById(window.app, t.window) orelse return;
    if (w.strip_input.drop_index == t.index) return;
    w.strip_input.drop_index = t.index;
    s.marker = t.window;
    Chrome.invalidate(w);
}

/// End the drag with `ev` (release or cancel) and apply the outcome.
fn finish(window: *Window, ev: tab_drag.Event, refocus: bool) void {
    var s = window.strip_input.session orelse return;
    window.strip_input.session = null;
    window.strip_input.drag = null;
    if (user32.GetCapture()) |c| {
        if (c == window.hwnd) _ = user32.ReleaseCapture();
    }
    setMarker(window, &s, null);
    if (s.ghost) drag_ghost.hide();
    Chrome.invalidate(window);

    // The tab may have ended behind the drag.
    if (window.tabIndex(s.tab) == null) return;
    // Another tab of the window ended behind the drag: only a cancel is safe.
    const stale = window.tabs.items.len != s.machine.tab_count;
    const outcome = s.machine.feed(if (stale) .cancel else ev).done orelse return;
    const tab = s.tab;
    switch (outcome) {
        .click, .reorder => focusActive(window),
        .cancelled => {
            restoreOrder(window, &s);
            if (refocus) focusActive(window);
        },
        .move_window => |o| {
            _ = user32.SetWindowPos(window.hwnd, null, o.x, o.y, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
            focusActive(window);
        },
        .move_to => |m| {
            const target = windowById(window.app, m.window);
            if (target == null or target.? == window) return restore(window, &s);
            const alloc = window.app.core_app.alloc;
            target.?.tabs.ensureUnusedCapacity(alloc, 1) catch return restore(window, &s);
            transfer(window, target.?, tab, m.index);
        },
        .tear_off => |o| {
            const new = Window.createForTearOff(window.app, .{ .x = o.x, .y = o.y }, window) catch |err| {
                log.warn("unable to create a window for the tab err={}", .{err});
                return restore(window, &s);
            };
            if (new.dpi != window.dpi) {
                // The grab offset was measured in source pixels.
                const m = &s.machine;
                const scale = @as(f64, @floatFromInt(new.dpi)) / @as(f64, @floatFromInt(window.dpi));
                const ox: i32 = m.last_pt.x - @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(m.grab.x + m.window_offset.x)) * scale)));
                const oy: i32 = m.last_pt.y - @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(m.grab.y + m.window_offset.y)) * scale)));
                _ = user32.SetWindowPos(new.hwnd, null, ox, oy, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
            }
            transfer(window, new, tab, 0);
        },
    }
}

/// Put the dragged tab back where it was grabbed, whatever closed since.
fn restoreOrder(window: *Window, s: *const Session) void {
    const from = window.tabIndex(s.tab) orelse return;
    const count = window.tabs.items.len;
    if (count == 0) return;
    window.moveTab(from, @min(s.machine.origin_index, count - 1));
}

fn restore(window: *Window, s: *const Session) void {
    restoreOrder(window, s);
    focusActive(window);
}

/// Move the tab to `target`. The surfaces, ptys and child processes stay;
/// only the HWND parents change. A source left without tabs closes.
fn transfer(source: *Window, target: *Window, tab: *Tab, index: usize) void {
    source.detachTab(tab);
    tab.setWindow(target);
    target.insertTab(tab, index);
    target.showPlain();
    if (source.tabs.items.len == 0) source.requestClose(true);
    target.activate();
    tab.focus();
}

fn postClose(window: *Window, index: usize) void {
    if (index >= window.tabs.items.len) return;
    _ = user32.PostMessageW(
        window.hwnd,
        messages.WM_GHOSTTY_CLOSE_TAB,
        @backingInt(Window.CloseTabMode.this),
        @as(isize, window.tabs.items[index].id),
    );
}

fn addTab(window: *Window) void {
    const parent = if (window.activeTab()) |tab|
        if (tab.focusedSurface()) |s| &s.core_surface else null
    else
        null;
    _ = window.addTab(.{ .parent = parent, .context = .tab }) catch |err| {
        log.warn("unable to create a tab err={}", .{err});
    };
}

/// Keyboard focus belongs to the active surface after any strip click.
fn focusActive(window: *Window) void {
    if (window.activeTab()) |tab| tab.focus();
}

test "win32 strip input: insertion index from x" {
    const tabs = [_]geom.Rect{
        .{ .x = 0, .w = 100, .h = 30 },
        .{ .x = 100, .w = 100, .h = 30 },
        .{ .x = 200, .w = 100, .h = 30 },
    };
    try std.testing.expectEqual(@as(usize, 0), insertionIndex(&tabs, -5));
    try std.testing.expectEqual(@as(usize, 0), insertionIndex(&tabs, 49));
    try std.testing.expectEqual(@as(usize, 1), insertionIndex(&tabs, 50));
    try std.testing.expectEqual(@as(usize, 1), insertionIndex(&tabs, 149));
    try std.testing.expectEqual(@as(usize, 2), insertionIndex(&tabs, 150));
    try std.testing.expectEqual(@as(usize, 3), insertionIndex(&tabs, 250));
    try std.testing.expectEqual(@as(usize, 3), insertionIndex(&tabs, 900));
    try std.testing.expectEqual(@as(usize, 0), insertionIndex(&.{}, 10));
}
