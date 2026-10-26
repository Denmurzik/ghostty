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

const user32 = win32.user32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_strip_input);

const MK_LBUTTON = 0x0001;

pub const State = struct {
    drag: ?TabStrip.Drag = null,
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
                        title_edit.begin(window, .tab, rect, tab.title());
                    }
                    return 0;
                },
                else => {},
            };
            switch (part) {
                .tab => |i| {
                    window.selectTab(i);
                    beginDrag(window, i, x);
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
            if (window.strip_input.drag != null) {
                if (wparam & MK_LBUTTON == 0) {
                    endDrag(window);
                } else {
                    window.strip_input.pointer_x = x;
                    dragTo(window, x);
                }
            }
            return null;
        },

        user32.WM_LBUTTONUP => {
            if (window.strip_input.drag == null) return null;
            endDrag(window);
            focusActive(window);
            return 0;
        },

        // The capture was taken (Alt+Tab, a dialog): the drag is over.
        user32.WM_CAPTURECHANGED => {
            if (window.strip_input.drag != null) {
                window.strip_input.drag = null;
                Chrome.invalidate(window);
            }
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

fn beginDrag(window: *Window, index: usize, x: i32) void {
    // The selection may have scrolled the strip.
    if (index >= window.strip.tabs.items.len) return;
    window.strip_input.drag = .{
        .tab = index,
        .start_x = x,
        .grab_dx = x - window.strip.tabs.items[index].x,
        .current = index,
    };
    window.strip_input.pointer_x = x;
    _ = user32.SetCapture(window.hwnd);
}

fn dragTo(window: *Window, x: i32) void {
    const drag = &(window.strip_input.drag orelse return);
    const m = TabStrip.Metrics.forDpi(window.dpi);
    if (TabStrip.dragUpdate(drag, &window.strip, m, x)) |move| window.moveTab(move.from, move.to);
    // The painter follows the pointer while the drag is active.
    if (drag.active) Chrome.invalidate(window);
}

fn endDrag(window: *Window) void {
    window.strip_input.drag = null;
    _ = user32.ReleaseCapture();
    Chrome.invalidate(window);
}

fn postClose(window: *Window, index: usize) void {
    if (index >= window.tabs.items.len) return;
    _ = user32.PostMessageW(
        window.hwnd,
        messages.WM_GHOSTTY_CLOSE_TAB,
        @intFromEnum(Window.CloseTabMode.this),
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
