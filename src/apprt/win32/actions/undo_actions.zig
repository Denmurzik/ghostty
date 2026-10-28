//! The `undo` and `redo` actions and the close-undo registry (owner: M5 Tasks
//! 15a, 15b).
//!
//! A closed tab or window is parked, not closed: its HWNDs are hidden, its
//! surfaces stay alive (shells keep running) and an entry on `app.undo` says
//! how to bring it back. An entry expires `undo-timeout` after the close;
//! then the item is closed for real. Only the user's own closes register
//! (tab `x`, tab menu, caption `x`, `close_tab`, `close_window`,
//! `close_surface`); the non-undoable primitives (`Window.removeTab`, tmux,
//! IPC, a child that exited) never do.
//!
//! This file is Task 15a: tabs, windows and groups of them. Splits, undo of
//! creation and `redo` are Task 15b.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const Tab = @import("../Tab.zig");
const Surface = @import("../Surface.zig");
const messages = @import("../messages.zig");
const undo_model = @import("../undo.zig");

const log = std.log.scoped(.win32_undo);

pub const Entry = struct {
    kind: undo_model.Kind,
    expires_ms: u64,
    window: ?*Window = null,
    tab: ?*Tab = null,
    tree: ?Surface.Tree = null,
    /// `close_tab`: where the tab was in its window.
    index: usize = 0,
    /// `group`: the members, in the order they were parked. Owned.
    group: []Entry = &.{},
};

pub const State = struct { stack: undo_model.Stack(Entry) = .{} };

fn nowMs() u64 {
    return win32.kernel32.GetTickCount64();
}

/// `undo-timeout` in ms; 0 disables undo (closes are final).
pub fn timeoutMs(app: *const App) u64 {
    return durationMs(app.config.@"undo-timeout".duration);
}

fn durationMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

pub fn enabled(app: *const App) bool {
    return timeoutMs(app) > 0;
}

/// What decides whether a close of a surface the user asked for is parked as
/// a tab (or window). Splits are Task 15b.
pub const SurfaceClose = struct {
    split: bool,
    child_exited: bool,
    /// The close came from a non-undoable source (the tmux shim).
    final: bool,
    window_parked: bool,
};

pub fn surfaceCloseUndoable(c: SurfaceClose) bool {
    return !c.split and !c.child_exited and !c.final and !c.window_parked;
}

// -- Registering -------------------------------------------------------------

/// Pushes `e`; what the push displaced (parked redo entries) is closed for
/// real, then the expiry timer is re-armed. Frees `e.group` when it fails.
fn push(app: *App, e: Entry) bool {
    const alloc = app.core_app.alloc;
    var displaced: std.ArrayList(Entry) = .empty;
    defer displaced.deinit(alloc);
    app.undo.stack.push(alloc, e, &displaced) catch |err| {
        log.warn("unable to record an undo entry err={}", .{err});
        return false;
    };
    closeAll(app, displaced.items);
    schedule(app);
    return true;
}

/// Parks `tab` of `window` and records it. False: nothing was parked, the
/// caller closes it for real. Never the last tab of a window.
pub fn closeTab(window: *Window, tab: *Tab) bool {
    const app = window.app;
    if (!enabled(app)) return false;
    const index = window.parkTab(tab) orelse return false;
    if (push(app, .{ .kind = .close_tab, .expires_ms = nowMs() + timeoutMs(app), .window = window, .tab = tab, .index = index })) return true;
    // Could not record it: put it back and let the caller close it.
    _ = window.unparkTab(tab, index);
    return false;
}

/// Parks `targets` (tabs of `window`, never all of them) as one entry.
/// False: nothing was parked.
pub fn closeTabs(window: *Window, targets: []const *Tab) bool {
    const app = window.app;
    if (!enabled(app)) return false;
    if (targets.len == 1) return closeTab(window, targets[0]);

    const alloc = app.core_app.alloc;
    const members = alloc.alloc(Entry, targets.len) catch return false;
    var n: usize = 0;
    const expires = nowMs() + timeoutMs(app);
    for (targets) |tab| {
        const index = window.parkTab(tab) orelse break;
        members[n] = .{ .kind = .close_tab, .expires_ms = expires, .window = window, .tab = tab, .index = index };
        n += 1;
    }
    if (n < targets.len or !push(app, .{ .kind = .group, .expires_ms = expires, .window = window, .group = members })) {
        // Undo what was parked, newest first, so the indexes are right again.
        while (n > 0) {
            n -= 1;
            _ = window.unparkTab(members[n].tab.?, members[n].index);
        }
        alloc.free(members);
        return false;
    }
    return true;
}

/// Parks `window` and records it. False: nothing was parked.
pub fn closeWindow(window: *Window) bool {
    const app = window.app;
    if (!enabled(app) or window.kind != .normal) return false;
    // Closing the last window of a quitting app is final.
    if (app.closingQuits(window)) return false;
    if (!app.parkWindow(window)) return false;
    if (push(app, .{ .kind = .close_window, .expires_ms = nowMs() + timeoutMs(app), .window = window })) return true;
    _ = app.unparkWindow(window);
    return false;
}

/// Parks every window in `windows` as one entry (`close_all_windows`).
/// False: nothing was parked.
pub fn closeWindows(app: *App, windows: []const *Window) bool {
    if (!enabled(app)) return false;
    if (windows.len == 1) return closeWindow(windows[0]);
    for (windows) |w| if (w.kind != .normal) return false;
    // `close_all_windows` ends the session of an app that quits with its last window.
    if (app.endsOnLastWindow()) return false;

    const alloc = app.core_app.alloc;
    const members = alloc.alloc(Entry, windows.len) catch return false;
    var n: usize = 0;
    const expires = nowMs() + timeoutMs(app);
    for (windows) |w| {
        if (!app.parkWindow(w)) break;
        members[n] = .{ .kind = .close_window, .expires_ms = expires, .window = w };
        n += 1;
    }
    if (n < windows.len or !push(app, .{ .kind = .group, .expires_ms = expires, .group = members })) {
        while (n > 0) {
            n -= 1;
            _ = app.unparkWindow(members[n].window.?);
        }
        alloc.free(members);
        return false;
    }
    return true;
}

// -- Undo --------------------------------------------------------------------

pub fn undo(app: *App, target: apprt.Target, value: void) !bool {
    _ = target;
    _ = value;
    const entry = app.undo.stack.popUndo(nowMs()) orelse return false;
    defer schedule(app);
    if (restore(app, entry)) return true;
    // Could not bring it back (out of memory): the item is still parked, keep its entry.
    app.undo.stack.undo.append(app.core_app.alloc, entry) catch log.warn("an undo entry was lost", .{});
    return false;
}

/// Task 15b.
pub fn redo(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    return false;
}

fn restore(app: *App, entry: Entry) bool {
    switch (entry.kind) {
        .close_tab => {
            const window = entry.window orelse return false;
            const tab = entry.tab orelse return false;
            if (!window.unparkTab(tab, entry.index)) return false;
            window.activate();
            return true;
        },
        .close_window => {
            const window = entry.window orelse return false;
            if (!app.unparkWindow(window)) return false;
            window.activate();
            return true;
        },
        .group => {
            // Newest first: each tab goes back to the index it was taken from.
            var i = entry.group.len;
            var ok = false;
            while (i > 0) {
                i -= 1;
                const m = entry.group[i];
                switch (m.kind) {
                    .close_tab => {
                        const window = m.window orelse continue;
                        const tab = m.tab orelse continue;
                        if (!window.unparkTab(tab, m.index)) continue;
                        window.activate();
                    },
                    .close_window => {
                        const window = m.window orelse continue;
                        if (!app.unparkWindow(window)) continue;
                        window.activate();
                    },
                    else => continue,
                }
                ok = true;
            }
            if (ok) app.core_app.alloc.free(entry.group);
            return ok;
        },
        // Task 15b.
        else => return false,
    }
}

// -- Closing for real ----------------------------------------------------------

/// Closes parked items for real: tabs first, then windows, so that a tab
/// never outlives (or is freed after) its window.
fn closeAll(app: *App, entries: []const Entry) void {
    closeAllWith(RealCloser{ .app = app }, entries);
}

const RealCloser = struct {
    app: *App,

    fn closeTab(self: RealCloser, window: *Window, tab: *Tab) void {
        _ = self;
        window.releaseParkedTab(tab);
    }

    fn closeWindow(self: RealCloser, window: *Window) void {
        self.app.releaseParkedWindow(window);
    }

    fn freeGroup(self: RealCloser, group: []Entry) void {
        self.app.core_app.alloc.free(group);
    }
};

fn closeAllWith(closer: anytype, entries: []const Entry) void {
    for ([_]bool{ false, true }) |windows_pass| {
        for (entries) |e| closeEntry(closer, e, windows_pass);
    }
    for (entries) |e| if (e.kind == .group) closer.freeGroup(e.group);
}

fn closeEntry(closer: anytype, e: Entry, windows_pass: bool) void {
    switch (e.kind) {
        .close_tab => if (!windows_pass) {
            if (e.window) |w| if (e.tab) |t| closer.closeTab(w, t);
        },
        .close_window => if (windows_pass) {
            if (e.window) |w| closer.closeWindow(w);
        },
        .group => for (e.group) |m| closeEntry(closer, m, windows_pass),
        else => {},
    }
}

/// The timer: every expired entry closes for real.
pub fn onTimer(app: *App) void {
    _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.undo_expire);
    const alloc = app.core_app.alloc;
    var expired: std.ArrayList(Entry) = .empty;
    defer expired.deinit(alloc);
    app.undo.stack.takeExpired(nowMs(), &expired, alloc) catch |err| {
        log.warn("unable to collect expired undo entries err={}", .{err});
        schedule(app);
        return;
    };
    closeAll(app, expired.items);
    schedule(app);
}

/// Quit: everything still parked closes for real, before the quit asks.
pub fn flushAll(app: *App) void {
    const alloc = app.core_app.alloc;
    var all: std.ArrayList(Entry) = .empty;
    defer all.deinit(alloc);
    app.undo.stack.takeAll(&all, alloc) catch |err| log.warn("unable to flush undo entries err={}", .{err});
    closeAll(app, all.items);
    _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.undo_expire);
    // Anything parked without an entry (should not exist) goes too.
    while (app.parked_windows.items.len > 0) app.releaseParkedWindow(app.parked_windows.items[app.parked_windows.items.len - 1]);
}

/// Arms the timer for the earliest expiry, or stops it.
pub fn schedule(app: *App) void {
    const id = messages.timers.msg_window.undo_expire;
    const next = app.undo.stack.nextExpiry() orelse {
        _ = win32.user32.KillTimer(app.msg_hwnd, id);
        return;
    };
    const now = nowMs();
    const delay: u32 = @intCast(@min(@max(next -| now, 1), std.math.maxInt(u31)));
    if (win32.user32.SetTimer(app.msg_hwnd, id, delay, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
    }
}

// -- Forgetting ----------------------------------------------------------------

/// A window is being destroyed by other means: drop every entry that names
/// it. Its parked tabs are destroyed with it.
pub fn forget(app: *App, window: *Window) void {
    forgetIn(&app.undo.stack, app.core_app.alloc, window, null);
}

/// A parked tab closes for real by itself (its shell exited): its entry goes.
pub fn forgetTab(app: *App, tab: *Tab) void {
    forgetIn(&app.undo.stack, app.core_app.alloc, null, tab);
}

/// Removes from `stack` every entry (or group member) that names `window`
/// or `tab`. Nothing is closed.
fn forgetIn(stack: *undo_model.Stack(Entry), alloc: Allocator, window: ?*Window, tab: ?*Tab) void {
    inline for (.{ &stack.undo, &stack.redo }) |list| {
        var keep: usize = 0;
        for (list.items) |e| {
            var e2 = e;
            if (!scrub(alloc, &e2, window, tab)) {
                list.items[keep] = e2;
                keep += 1;
            }
        }
        list.shrinkRetainingCapacity(keep);
    }
}

fn names(e: Entry, window: ?*Window, tab: ?*Tab) bool {
    if (window) |w| if (e.window == w) return true;
    if (tab) |t| if (e.tab == t) return true;
    return false;
}

/// True when `e` is to be removed whole. A group keeps its allocation (it is
/// freed with its exact length) and turns the matching members inert.
fn scrub(alloc: Allocator, e: *Entry, window: ?*Window, tab: ?*Tab) bool {
    if (e.kind != .group) return names(e.*, window, tab);
    var live: usize = 0;
    for (e.group) |*m| {
        if (m.kind == .group or m.kind == .new_tab) continue;
        if (names(m.*, window, tab)) {
            m.* = .{ .kind = .new_tab, .expires_ms = m.expires_ms };
        } else {
            live += 1;
        }
    }
    if (live > 0) return false;
    alloc.free(e.group);
    e.group = &.{};
    return true;
}

// -- State ---------------------------------------------------------------------

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    var parked_tabs: usize = 0;
    for (app.windows.items) |w| parked_tabs += w.parked_tabs.items.len;
    for (app.parked_windows.items) |w| parked_tabs += w.parked_tabs.items.len;

    try jw.beginObject();
    try jw.objectField("undo");
    try jw.write(app.undo.stack.undo.items.len);
    try jw.objectField("redo");
    try jw.write(app.undo.stack.redo.items.len);
    try jw.objectField("parked");
    try jw.beginObject();
    try jw.objectField("tabs");
    try jw.write(parked_tabs);
    try jw.objectField("windows");
    try jw.write(app.parked_windows.items.len);
    try jw.endObject();
    try jw.endObject();
}

// -- Tests ---------------------------------------------------------------------

const testing = std.testing;

fn fakeWindow(n: usize) *Window {
    return @ptrFromInt(0x1000 + n * 0x100);
}

fn fakeTab(n: usize) *Tab {
    return @ptrFromInt(0x9000 + n * 0x100);
}

test "win32 undo: timeout 0 disables, milliseconds otherwise" {
    try testing.expectEqual(@as(u64, 0), durationMs(0));
    try testing.expectEqual(@as(u64, 5000), durationMs(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(u64, 0), durationMs(999_999));
    // `enabled` is `timeoutMs > 0`: a zero duration never parks.
    try testing.expect(!(durationMs(0) > 0));
}

test "win32 undo: expired entries close tabs before windows" {
    const Rec = struct {
        out: *std.ArrayList(u8),
        freed: *usize,

        fn closeTab(self: @This(), window: *Window, tab: *Tab) void {
            _ = window;
            _ = tab;
            self.out.append(testing.allocator, 't') catch unreachable;
        }
        fn closeWindow(self: @This(), window: *Window) void {
            _ = window;
            self.out.append(testing.allocator, 'w') catch unreachable;
        }
        fn freeGroup(self: @This(), group: []Entry) void {
            _ = group;
            self.freed.* += 1;
        }
    };
    var closed: std.ArrayList(u8) = .empty;
    defer closed.deinit(testing.allocator);
    var freed: usize = 0;
    var members = [_]Entry{
        .{ .kind = .close_tab, .expires_ms = 1, .window = fakeWindow(1), .tab = fakeTab(1) },
        .{ .kind = .close_tab, .expires_ms = 1, .window = fakeWindow(1), .tab = fakeTab(2) },
    };
    closeAllWith(Rec{ .out = &closed, .freed = &freed }, &.{
        .{ .kind = .close_window, .expires_ms = 1, .window = fakeWindow(1) },
        .{ .kind = .group, .expires_ms = 1, .group = &members },
    });
    try testing.expectEqualStrings("ttw", closed.items);
    try testing.expectEqual(@as(usize, 1), freed);
}

test "win32 undo: a tmux or exited-child close is never undoable" {
    const base: SurfaceClose = .{ .split = false, .child_exited = false, .final = false, .window_parked = false };
    try testing.expect(surfaceCloseUndoable(base));
    var c = base;
    c.final = true; // tmux kill-pane
    try testing.expect(!surfaceCloseUndoable(c));
    c = base;
    c.child_exited = true;
    try testing.expect(!surfaceCloseUndoable(c));
    c = base;
    c.split = true;
    try testing.expect(!surfaceCloseUndoable(c));
    c = base;
    c.window_parked = true;
    try testing.expect(!surfaceCloseUndoable(c));
}

test "win32 undo: sweeps reach parked tabs" {
    var w: Window = undefined;
    w.tabs = .empty;
    w.parked_tabs = .empty;
    defer w.tabs.deinit(testing.allocator);
    defer w.parked_tabs.deinit(testing.allocator);
    try w.tabs.append(testing.allocator, fakeTab(1));
    try w.parked_tabs.append(testing.allocator, fakeTab(2));
    var it = w.allTabs();
    try testing.expectEqual(fakeTab(1), it.next().?);
    try testing.expectEqual(fakeTab(2), it.next().?);
    try testing.expect(it.next() == null);
}

test "win32 undo: a process that cannot be reached again parks nothing" {
    // closingQuits/endsOnLastWindow follow lastWindowAction.
    try testing.expect(App.lastWindowAction(false, null, false) == .quit_now);
    try testing.expect(App.lastWindowAction(false, null, true) == .stay);
    try testing.expect(App.lastWindowAction(true, null, true) != .stay);
}

test "win32 undo: forgetting a window drops its entries and group members" {
    const alloc = testing.allocator;
    var stack: undo_model.Stack(Entry) = .{};
    defer stack.deinit(alloc);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(alloc);

    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(1) }, &dis);
    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(2), .tab = fakeTab(2) }, &dis);
    const members = try alloc.alloc(Entry, 2);
    members[0] = .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(3) };
    members[1] = .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(2), .tab = fakeTab(4) };
    try stack.push(alloc, .{ .kind = .group, .expires_ms = 100, .group = members }, &dis);

    forgetIn(&stack, alloc, fakeWindow(1), null);
    try testing.expectEqual(@as(usize, 2), stack.undo.items.len);
    try testing.expectEqual(@as(usize, 2), stack.undo.items[1].group.len);
    try testing.expect(stack.undo.items[1].group[0].tab == null);
    try testing.expectEqual(fakeTab(4), stack.undo.items[1].group[1].tab.?);

    // The last member of a group takes the group with it (and frees it).
    forgetIn(&stack, alloc, null, fakeTab(4));
    try testing.expectEqual(@as(usize, 1), stack.undo.items.len);
    try testing.expectEqual(fakeTab(2), stack.undo.items[0].tab.?);
}

test "win32 undo: a child that exited while parked drops only its entry" {
    const alloc = testing.allocator;
    var stack: undo_model.Stack(Entry) = .{};
    defer stack.deinit(alloc);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(alloc);
    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(1) }, &dis);
    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(2) }, &dis);
    forgetIn(&stack, alloc, null, fakeTab(1));
    try testing.expectEqual(@as(usize, 1), stack.undo.items.len);
    try testing.expectEqual(fakeTab(2), stack.undo.items[0].tab.?);
}

test "win32 undo: an expired entry cannot be undone" {
    const alloc = testing.allocator;
    var stack: undo_model.Stack(Entry) = .{};
    defer stack.deinit(alloc);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(alloc);
    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(1) }, &dis);
    try testing.expect(stack.popUndo(100) == null);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(alloc);
    try stack.takeExpired(100, &out, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}
