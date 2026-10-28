//! The `undo` and `redo` actions and the close-undo registry (owner: M5 Tasks
//! 15a, 15b).
//!
//! A closed tab, window or split is parked, not closed: its HWNDs are hidden,
//! its surfaces stay alive (shells keep running) and an entry on `app.undo`
//! says how to bring it back. An entry expires `undo-timeout` after it was
//! made; a parked item is then closed for real. Only the user's own closes
//! register (tab `x`, tab menu, caption `x`, `close_tab`, `close_window`,
//! `close_surface`); the non-undoable primitives (`Window.removeTab`, tmux,
//! IPC, a child that exited) never do.
//!
//! Creating a tab, window or split registers too (`new_*`): undoing it parks
//! the new item, redoing it brings it back. Undoing a close and redoing it
//! close the item again. Every entry therefore flips between two states:
//!  - tab/window entries carry `parked`: the item is parked or live;
//!  - split entries carry two snapshots of the tab's tree, `before` and
//!    `after` the change, and `current_after` says which one the tab shows.
//!    The swap happens only if the tab's tree is node-for-node the snapshot
//!    it is expected to show; any other change of the tree drops the entry.
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
    /// Tab and window entries: the item is parked right now.
    parked: bool = false,
    /// Tab entries: where the tab was in its window when it was parked.
    index: usize = 0,
    /// Split entries: the surface that comes and goes, the tab's tree before
    /// and after the change, and which of the two the tab shows now.
    surface: ?*Surface = null,
    before: ?Surface.Tree = null,
    after: ?Surface.Tree = null,
    current_after: bool = false,
    /// Set while a group is flipped: this member did.
    flipped: bool = false,
    /// `group`: the members, in the order they were parked. Owned. A member
    /// of kind `.group` is inert (already restored or forgotten).
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

/// Undo is on for a timeout of `ms`.
pub fn enabledFor(ms: u64) bool {
    return ms > 0;
}

pub fn enabled(app: *const App) bool {
    return enabledFor(timeoutMs(app));
}

/// What decides whether a close of a surface the user asked for is parked
/// (as a tab, a window or a split).
pub const SurfaceClose = struct {
    child_exited: bool,
    /// The close came from a non-undoable source (the tmux shim).
    final: bool,
    window_parked: bool,
};

pub fn surfaceCloseUndoable(c: SurfaceClose) bool {
    return !c.child_exited and !c.final and !c.window_parked;
}

// -- Registering -------------------------------------------------------------

/// Pushes `e`; what the push displaced (the redo entries) is dropped, parked
/// items among them closed for real, then the expiry timer is re-armed.
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

fn expiry(app: *const App) u64 {
    return nowMs() + timeoutMs(app);
}

/// Parks `tab` of `window` and records it. False: nothing was parked, the
/// caller closes it for real. Never the last tab of a window.
pub fn closeTab(window: *Window, tab: *Tab) bool {
    const app = window.app;
    if (!enabled(app) or window.kind != .normal) return false;
    const index = window.parkTab(tab) orelse return false;
    if (push(app, .{ .kind = .close_tab, .expires_ms = expiry(app), .window = window, .tab = tab, .index = index, .parked = true })) return true;
    // Could not record it: put it back and let the caller close it.
    window.unparkTab(tab, index) catch {};
    return false;
}

/// Parks `targets` (tabs of `window`, never all of them) as one entry.
/// False: nothing was parked.
pub fn closeTabs(window: *Window, targets: []const *Tab) bool {
    const app = window.app;
    if (!enabled(app) or window.kind != .normal) return false;
    if (targets.len == 1) return closeTab(window, targets[0]);

    const alloc = app.core_app.alloc;
    const members = alloc.alloc(Entry, targets.len) catch return false;
    var n: usize = 0;
    const expires = expiry(app);
    for (targets) |tab| {
        const index = window.parkTab(tab) orelse break;
        members[n] = .{ .kind = .close_tab, .expires_ms = expires, .window = window, .tab = tab, .index = index, .parked = true };
        n += 1;
    }
    if (n < targets.len or !push(app, .{ .kind = .group, .expires_ms = expires, .window = window, .group = members })) {
        // Undo what was parked, newest first, so the indexes are right again.
        while (n > 0) {
            n -= 1;
            window.unparkTab(members[n].tab.?, members[n].index) catch {};
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
    if (push(app, .{ .kind = .close_window, .expires_ms = expiry(app), .window = window, .parked = true })) return true;
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
    const expires = expiry(app);
    for (windows) |w| {
        if (!app.parkWindow(w)) break;
        members[n] = .{ .kind = .close_window, .expires_ms = expires, .window = w, .parked = true };
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

/// Parks the split `s` of `tab` and records it, with the tree before and
/// after. False: nothing was parked.
pub fn closeSplit(tab: *Tab, s: *Surface) bool {
    const app = tab.window.app;
    if (!enabled(app) or tab.window.kind != .normal) return false;
    const snap = tab.parkSurface(s) orelse return false;
    if (push(app, .{
        .kind = .close_split,
        .expires_ms = expiry(app),
        .window = tab.window,
        .tab = tab,
        .surface = s,
        .before = snap.before,
        .after = snap.after,
        .current_after = true,
    })) return true;
    // Could not record it: close the split for real, as without undo.
    var before = snap.before;
    var after = snap.after;
    before.deinit();
    after.deinit();
    return true;
}

/// A tab the user created: undo parks it.
pub fn newTab(window: *Window, tab: *Tab) void {
    const app = window.app;
    if (!enabled(app) or window.kind != .normal) return;
    _ = push(app, .{ .kind = .new_tab, .expires_ms = expiry(app), .window = window, .tab = tab });
}

/// A window the user created: undo parks it.
pub fn newWindow(window: *Window) void {
    const app = window.app;
    if (!enabled(app) or window.kind != .normal) return;
    _ = push(app, .{ .kind = .new_window, .expires_ms = expiry(app), .window = window });
}

/// The tree of `tab` before a split the user asked for; pass it to
/// `newSplit`. Null when undo is off.
pub fn beginSplit(tab: *Tab) ?Surface.Tree {
    if (!enabled(tab.window.app)) return null;
    return tab.tree.clone(tab.window.app.core_app.alloc) catch null;
}

/// The split of `s` was made (`before` from `beginSplit`): undo parks `s`.
pub fn newSplit(tab: *Tab, s: *Surface, before: ?Surface.Tree) void {
    var b = before orelse return;
    const app = tab.window.app;
    const after = tab.tree.clone(app.core_app.alloc) catch {
        b.deinit();
        return;
    };
    if (!push(app, .{
        .kind = .new_split,
        .expires_ms = expiry(app),
        .window = tab.window,
        .tab = tab,
        .surface = s,
        .before = b,
        .after = after,
        .current_after = true,
    })) {
        var a = after;
        b.deinit();
        a.deinit();
    }
}

// -- Undo and redo ---------------------------------------------------------------

/// What one flip of an entry came to.
const Flip = enum {
    /// The entry flipped; it now belongs on the other stack.
    done,
    /// Some members of a group flipped (they have `flipped` set), the rest
    /// stays where it was.
    partial,
    /// Out of memory: nothing changed, the entry stays.
    failed,
    /// The thing it was about is not there any more: the entry is dropped.
    gone,
};

/// What a window flip step came to.
const WindowStep = enum { done, missing, oom };

/// Undo never gives the keyboard to a window the user cannot see (a hidden
/// quick terminal, or any window while `toggle_visibility` hides them).
fn activatable(window: *const Window) bool {
    return window.kind == .normal and win32.user32.IsWindowVisible(window.hwnd) != 0;
}

/// The live side of the flips: everything that touches windows, tabs and the
/// stacks. The flip logic below runs against any type with these methods, so
/// the unit tests drive it with a fake.
const Live = struct {
    app: *App,

    fn tabUnpark(self: Live, tab: *Tab, index: usize) error{ OutOfMemory, NotParked }!void {
        _ = self;
        return tab.window.unparkTab(tab, index);
    }

    fn tabPark(self: Live, tab: *Tab) ?usize {
        _ = self;
        return tab.window.parkTab(tab);
    }

    fn tabActivate(self: Live, tab: *Tab) void {
        _ = self;
        if (!activatable(tab.window)) return;
        tab.window.activate();
    }

    fn windowUnpark(self: Live, window: *Window) WindowStep {
        for (self.app.parked_windows.items) |w| {
            if (w == window) return if (self.app.unparkWindow(window)) .done else .oom;
        }
        return .missing;
    }

    fn windowPark(self: Live, window: *Window) WindowStep {
        for (self.app.windows.items) |w| {
            if (w == window) return if (self.app.parkWindow(window)) .done else .oom;
        }
        return .missing;
    }

    fn windowEndsSession(self: Live, window: *Window) bool {
        return self.app.closingQuits(window);
    }

    fn windowActivate(self: Live, window: *Window) void {
        _ = self;
        if (!activatable(window)) return;
        window.activate();
    }

    fn treeOf(self: Live, tab: *Tab) *const Surface.Tree {
        _ = self;
        return &tab.tree;
    }

    fn swapTree(self: Live, tab: *Tab, tree: Surface.Tree, s: *Surface, show_s: bool) void {
        _ = self;
        tab.swapTree(tree, s, show_s);
    }

    fn stack(self: Live) *undo_model.Stack(Entry) {
        return &self.app.undo.stack;
    }

    fn allocator(self: Live) Allocator {
        return self.app.core_app.alloc;
    }

    fn newExpiry(self: Live) u64 {
        return expiry(self.app);
    }

    fn closeEntries(self: Live, entries: []const Entry) void {
        closeAll(self.app, entries);
    }

    fn armTimer(self: Live) void {
        schedule(self.app);
    }
};

fn flipWith(env: anytype, e: *Entry) Flip {
    switch (e.kind) {
        .close_tab, .new_tab => return flipTabWith(env, e),
        .close_window, .new_window => return flipWindowWith(env, e),
        .close_split, .new_split => return flipSplitWith(env, e),
        .group => return flipGroupWith(env, e),
    }
}

fn flipTabWith(env: anytype, e: *Entry) Flip {
    const tab = e.tab orelse return .gone;
    if (e.parked) {
        env.tabUnpark(tab, e.index) catch |err| return switch (err) {
            error.OutOfMemory => .failed,
            error.NotParked => .gone,
        };
        e.parked = false;
        env.tabActivate(tab);
    } else {
        e.index = env.tabPark(tab) orelse {
            log.info("undo: the tab is now the only one of its window, entry dropped", .{});
            return .gone;
        };
        e.parked = true;
    }
    return .done;
}

fn flipWindowWith(env: anytype, e: *Entry) Flip {
    const window = e.window orelse return .gone;
    if (e.parked) {
        switch (env.windowUnpark(window)) {
            .done => {},
            .missing => {
                // Not in the parked list: there is nothing left to close.
                e.parked = false;
                return .gone;
            },
            .oom => return .failed,
        }
        e.parked = false;
        env.windowActivate(window);
    } else {
        // Parking the last window of an app that quits with it would end the session.
        if (env.windowEndsSession(window)) {
            log.info("undo: parking the window would end the session, entry dropped", .{});
            return .gone;
        }
        switch (env.windowPark(window)) {
            .done => {},
            .missing => return .gone,
            .oom => return .failed,
        }
        e.parked = true;
    }
    return .done;
}

fn flipSplitWith(env: anytype, e: *Entry) Flip {
    const tab = e.tab orelse return .gone;
    const s = e.surface orelse return .gone;
    const before = e.before orelse return .gone;
    const after = e.after orelse return .gone;
    const shown = if (e.current_after) &after else &before;
    const target = if (e.current_after) &before else &after;
    if (!treesEql(env.treeOf(tab), shown)) {
        log.info("undo: the tree of the tab changed since the split change, entry dropped", .{});
        return .gone;
    }
    const clone = target.clone(env.allocator()) catch return .failed;
    env.swapTree(tab, clone, s, target.locate(s) != null);
    e.current_after = !e.current_after;
    return .done;
}

fn flipGroupWith(env: anytype, e: *Entry) Flip {
    const n = e.group.len;
    // Whether the group is parked is the state of its first live member.
    var unparking = false;
    for (e.group) |m| {
        if (m.kind == .group) continue;
        unparking = m.parked;
        break;
    }
    var ok: usize = 0;
    var failed = false;
    var any_member = false;
    // Unparking goes newest first (each tab returns to the index it was
    // taken from), parking in the original order.
    var step: usize = 0;
    while (step < n) : (step += 1) {
        const m = &e.group[if (unparking) n - 1 - step else step];
        m.flipped = false;
        if (m.kind == .group) continue;
        any_member = true;
        switch (flipWith(env, m)) {
            .done => {
                m.flipped = true;
                ok += 1;
            },
            .failed => failed = true,
            .gone => m.* = .{ .kind = .group, .expires_ms = m.expires_ms },
            .partial => {},
        }
    }
    if (!any_member) return .gone;
    if (failed and ok == 0) return .failed;
    if (failed) return .partial;
    return .done;
}

fn timestamp(env: anytype, e: *Entry) void {
    e.expires_ms = env.newExpiry();
    for (e.group) |*m| m.expires_ms = e.expires_ms;
}

pub fn undo(app: *App, target: apprt.Target, value: void) !bool {
    _ = target;
    _ = value;
    const entry = app.undo.stack.popUndo(nowMs()) orelse return false;
    return finish(Live{ .app = app }, entry, .undo);
}

pub fn redo(app: *App, target: apprt.Target, value: void) !bool {
    _ = target;
    _ = value;
    const entry = app.undo.stack.popRedo(nowMs()) orelse return false;
    return finish(Live{ .app = app }, entry, .redo);
}

const Way = enum { undo, redo };

/// Flips `popped` and puts what comes out on the other stack.
fn finish(env: anytype, popped: Entry, way: Way) bool {
    defer env.armTimer();
    const alloc = env.allocator();
    var entry = popped;
    const result = flipWith(env, &entry);
    switch (result) {
        .done => {
            timestamp(env, &entry);
            keep(env, entry, way, .other);
            return true;
        },
        .partial => {
            // The members that flipped go to the other stack as a group of
            // their own; the rest stays where it was.
            var flipped_n: usize = 0;
            for (entry.group) |m| {
                if (m.kind != .group and m.flipped) flipped_n += 1;
            }
            const part = alloc.alloc(Entry, flipped_n) catch {
                keep(env, entry, way, .same);
                return true;
            };
            var k: usize = 0;
            for (entry.group) |*m| {
                if (m.kind == .group or !m.flipped) continue;
                m.flipped = false;
                part[k] = m.*;
                k += 1;
                m.* = .{ .kind = .group, .expires_ms = m.expires_ms };
            }
            var flipped: Entry = .{ .kind = .group, .expires_ms = env.newExpiry(), .group = part };
            timestamp(env, &flipped);
            keep(env, flipped, way, .other);
            keep(env, entry, way, .same);
            return true;
        },
        // Out of memory: the item is as it was, keep the entry for another try.
        .failed => {
            keep(env, entry, way, .same);
            return false;
        },
        .gone => {
            env.closeEntries(&.{entry});
            return false;
        },
    }
}

const Side = enum { same, other };

/// Puts `e` on a stack: where it came from (`same`) or the opposite one.
fn keep(env: anytype, e: Entry, way: Way, side: Side) void {
    const alloc = env.allocator();
    const to_undo = (way == .undo) == (side == .same);
    const ok = if (to_undo)
        env.stack().restoreUndo(alloc, e)
    else
        env.stack().pushRedo(alloc, e);
    ok catch {
        log.warn("an undo entry was lost", .{});
        env.closeEntries(&.{e});
    };
}

// -- Closing for real ----------------------------------------------------------

/// Closes what entries still hold: split snapshots are released first, then
/// parked tabs, then parked windows, so that nothing outlives (or is freed
/// after) what it hangs on. Entries whose item is live only give up their
/// bookkeeping.
fn closeAll(app: *App, entries: []const Entry) void {
    closeAllWith(RealCloser{ .app = app }, entries);
}

const RealCloser = struct {
    app: *App,

    fn closeSplit(self: RealCloser, e: Entry) void {
        _ = self;
        releaseSplit(e);
    }

    fn closeTab(self: RealCloser, tab: *Tab) void {
        _ = self;
        tab.window.releaseParkedTab(tab);
    }

    fn closeWindow(self: RealCloser, window: *Window) void {
        self.app.releaseParkedWindow(window);
    }

    fn freeGroup(self: RealCloser, group: []Entry) void {
        self.app.core_app.alloc.free(group);
    }
};

fn releaseSplit(e: Entry) void {
    if (e.before) |b| {
        var t = b;
        t.deinit();
    }
    if (e.after) |a| {
        var t = a;
        t.deinit();
    }
}

fn closeAllWith(closer: anytype, entries: []const Entry) void {
    for ([_]u2{ 0, 1, 2 }) |pass| {
        for (entries) |e| closeEntry(closer, e, pass);
    }
    for (entries) |e| if (e.kind == .group) closer.freeGroup(e.group);
}

fn closeEntry(closer: anytype, e: Entry, pass: u2) void {
    switch (e.kind) {
        .close_split, .new_split => if (pass == 0) closer.closeSplit(e),
        .close_tab, .new_tab => if (pass == 1 and e.parked) {
            if (e.tab) |t| closer.closeTab(t);
        },
        .close_window, .new_window => if (pass == 2 and e.parked) {
            if (e.window) |w| closer.closeWindow(w);
        },
        .group => for (e.group) |m| closeEntry(closer, m, pass),
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
    _ = forgetIn(&app.undo.stack, app.core_app.alloc, .{ .window = window });
}

/// A tab is closing for real (or moving to another window): its entries go.
/// Returns how many entries were dropped.
pub fn forgetTab(app: *App, tab: *Tab) usize {
    return forgetIn(&app.undo.stack, app.core_app.alloc, .{ .tab = tab });
}

/// A surface is leaving its tab for good: its entries go, and so do the
/// split entries whose snapshots hold it (they would keep it alive).
pub fn forgetSurface(app: *App, s: *Surface) void {
    _ = forgetIn(&app.undo.stack, app.core_app.alloc, .{ .surface = s });
}

/// A parked split surface exited by itself: its entry goes and the split
/// closes for real. False when no entry holds it.
pub fn surfaceExited(app: *App, id: u32) bool {
    var found: ?*Surface = null;
    inline for (.{ &app.undo.stack.undo, &app.undo.stack.redo }) |list| {
        for (list.items) |e| {
            if (e.surface) |s| if (s.id == id and splitParked(e)) {
                found = s;
            };
        }
    }
    const s = found orelse return false;
    forgetSurface(app, s);
    return true;
}

/// The surface of a split entry is parked while the tab shows the tree
/// without it.
pub fn splitParked(e: Entry) bool {
    return switch (e.kind) {
        .close_split => e.current_after,
        .new_split => !e.current_after,
        else => false,
    };
}

const Names = struct {
    window: ?*Window = null,
    tab: ?*Tab = null,
    surface: ?*Surface = null,
};

/// Removes from `stack` every entry (or group member) that names `n`.
/// Nothing is closed, but the snapshots a split entry holds are released.
/// Returns how many entries were removed whole.
fn forgetIn(stack: *undo_model.Stack(Entry), alloc: Allocator, n: Names) usize {
    var dropped: std.ArrayList(Entry) = .empty;
    defer dropped.deinit(alloc);
    var count: usize = 0;
    inline for (.{ &stack.undo, &stack.redo }) |list| {
        var keep_n: usize = 0;
        for (list.items) |e| {
            var e2 = e;
            if (scrub(alloc, &e2, n)) {
                count += 1;
                dropped.append(alloc, e2) catch releaseSplit(e2);
            } else {
                list.items[keep_n] = e2;
                keep_n += 1;
            }
        }
        list.shrinkRetainingCapacity(keep_n);
    }
    // Last: releasing a snapshot may tear a surface down.
    for (dropped.items) |e| releaseSplit(e);
    return count;
}

fn names(e: Entry, n: Names) bool {
    if (n.window) |w| if (e.window == w) return true;
    if (n.tab) |t| if (e.tab == t) return true;
    if (n.surface) |s| {
        if (e.surface == s) return true;
        // A snapshot that holds a surface that left the tab can never match
        // the tab again, and keeps the surface (and its process) alive.
        inline for (.{ e.before, e.after }) |snap| {
            if (snap) |t| if (t.locate(s) != null) return true;
        }
    }
    return false;
}

/// True when `e` is to be removed whole. A group keeps its allocation (it is
/// freed with its exact length) and turns the matching members inert.
fn scrub(alloc: Allocator, e: *Entry, n: Names) bool {
    if (e.kind != .group) return names(e.*, n);
    var live: usize = 0;
    for (e.group) |*m| {
        if (m.kind == .group) continue;
        if (names(m.*, n)) {
            m.* = .{ .kind = .group, .expires_ms = m.expires_ms };
        } else {
            live += 1;
        }
    }
    if (live > 0) return false;
    alloc.free(e.group);
    e.group = &.{};
    return true;
}

// -- Trees ---------------------------------------------------------------------

/// Whether two trees are node for node the same: the same views in the same
/// places, the same splits with the same ratios, the same zoom.
pub fn treesEql(a: anytype, b: anytype) bool {
    if (a.nodes.len != b.nodes.len) return false;
    if (a.zoomed != b.zoomed) return false;
    for (a.nodes, b.nodes) |x, y| {
        switch (x) {
            .leaf => |lx| switch (y) {
                .leaf => |ly| if (lx != ly) return false,
                .split => return false,
            },
            .split => |sx| switch (y) {
                .leaf => return false,
                .split => |sy| {
                    if (sx.layout != sy.layout or sx.ratio != sy.ratio) return false;
                    if (sx.left != sy.left or sx.right != sy.right) return false;
                },
            },
        }
    }
    return true;
}

// -- State ---------------------------------------------------------------------

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    var parked_tabs: usize = 0;
    for (app.windows.items) |w| parked_tabs += w.parked_tabs.items.len;
    for (app.parked_windows.items) |w| parked_tabs += w.parked_tabs.items.len;
    var parked_splits: usize = 0;
    inline for (.{ &app.undo.stack.undo, &app.undo.stack.redo }) |list| {
        for (list.items) |e| {
            if (splitParked(e)) parked_splits += 1;
        }
    }

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
    try jw.objectField("splits");
    try jw.write(parked_splits);
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
    try testing.expect(!enabledFor(durationMs(0)));
    try testing.expect(!enabledFor(durationMs(999_999)));
    try testing.expect(enabledFor(durationMs(5 * std.time.ns_per_s)));
}

const Rec = struct {
    out: *std.ArrayList(u8),
    freed: *usize,

    fn closeSplit(self: @This(), e: Entry) void {
        _ = e;
        self.out.append(testing.allocator, 's') catch unreachable;
    }
    fn closeTab(self: @This(), tab: *Tab) void {
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

test "win32 undo: expired entries close splits, then tabs, then windows; live ones only give up their entry" {
    var closed: std.ArrayList(u8) = .empty;
    defer closed.deinit(testing.allocator);
    var freed: usize = 0;
    var members = [_]Entry{
        .{ .kind = .close_tab, .expires_ms = 1, .parked = true, .window = fakeWindow(1), .tab = fakeTab(1) },
        .{ .kind = .close_tab, .expires_ms = 1, .parked = true, .window = fakeWindow(1), .tab = fakeTab(2) },
    };
    closeAllWith(Rec{ .out = &closed, .freed = &freed }, &.{
        .{ .kind = .close_window, .expires_ms = 1, .parked = true, .window = fakeWindow(1) },
        .{ .kind = .group, .expires_ms = 1, .group = &members },
        .{ .kind = .close_split, .expires_ms = 1, .tab = fakeTab(3) },
        // A live item (an undone close, a created tab): nothing to close.
        .{ .kind = .new_tab, .expires_ms = 1, .parked = false, .tab = fakeTab(4) },
        .{ .kind = .close_tab, .expires_ms = 1, .parked = false, .tab = fakeTab(5) },
        // A created window that was undone is parked: it closes.
        .{ .kind = .new_window, .expires_ms = 1, .parked = true, .window = fakeWindow(2) },
    });
    try testing.expectEqualStrings("sttww", closed.items);
    try testing.expectEqual(@as(usize, 1), freed);
}

test "win32 undo: a tmux or exited-child close is never undoable" {
    const base: SurfaceClose = .{ .child_exited = false, .final = false, .window_parked = false };
    try testing.expect(surfaceCloseUndoable(base));
    var c = base;
    c.final = true; // tmux kill-pane
    try testing.expect(!surfaceCloseUndoable(c));
    c = base;
    c.child_exited = true;
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

test "win32 undo: closing the last window of a process that cannot be reached again is final" {
    // Others open: never. Last window: follows the last-window rule.
    try testing.expect(!App.closeEndsSession(true, true, null, false));
    try testing.expect(App.closeEndsSession(false, false, null, false)); // not serving or no tray
    try testing.expect(!App.closeEndsSession(false, false, null, true)); // stays: parked
    try testing.expect(App.closeEndsSession(false, true, null, true)); // quit-after-last-window-closed
}

test "win32 undo: split entries are parked while the tab shows the tree without the surface" {
    var e: Entry = .{ .kind = .close_split, .expires_ms = 1, .current_after = true };
    try testing.expect(splitParked(e)); // closed: shows `after`
    e.current_after = false;
    try testing.expect(!splitParked(e)); // undone
    e = .{ .kind = .new_split, .expires_ms = 1, .current_after = true };
    try testing.expect(!splitParked(e)); // created: the new surface is live
    e.current_after = false;
    try testing.expect(splitParked(e)); // undone: parked
    try testing.expect(!splitParked(.{ .kind = .close_tab, .expires_ms = 1, .parked = true }));
}

const CountView = struct {
    refs: usize = 0,

    pub fn ref(self: *CountView, alloc: Allocator) Allocator.Error!*CountView {
        _ = alloc;
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *CountView, alloc: Allocator) void {
        _ = alloc;
        self.refs -= 1;
    }

    pub fn eql(a: *const CountView, b: *const CountView) bool {
        return a == b;
    }
};

test "win32 undo: a tree matches only node for node" {
    const alloc = testing.allocator;
    const Tree = @import("../../../datastruct/split_tree.zig").SplitTree(CountView);
    var va: CountView = .{};
    var vb: CountView = .{};
    var vc: CountView = .{};
    var ta: Tree = try .init(alloc, &va);
    defer ta.deinit();
    var tb: Tree = try .init(alloc, &vb);
    defer tb.deinit();
    var tc: Tree = try .init(alloc, &vc);
    defer tc.deinit();

    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();
    var ab2 = try ab.clone(alloc);
    defer ab2.deinit();
    try testing.expect(treesEql(&ab, &ab2));
    try testing.expect(treesEql(&ta, &ta));
    try testing.expect(!treesEql(&ab, &ta));

    // Another ratio, another split direction, another leaf, zoom: all differ.
    var ratio = try ta.split(alloc, .root, .right, 0.3, &tb);
    defer ratio.deinit();
    try testing.expect(!treesEql(&ab, &ratio));
    var down = try ta.split(alloc, .root, .down, 0.5, &tb);
    defer down.deinit();
    try testing.expect(!treesEql(&ab, &down));
    var ac = try ta.split(alloc, .root, .right, 0.5, &tc);
    defer ac.deinit();
    try testing.expect(!treesEql(&ab, &ac));
    var zoomed = try ab.clone(alloc);
    defer zoomed.deinit();
    zoomed.zoom(.root);
    try testing.expect(!treesEql(&ab, &zoomed));
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

    _ = forgetIn(&stack, alloc, .{ .window = fakeWindow(1) });
    try testing.expectEqual(@as(usize, 2), stack.undo.items.len);
    try testing.expectEqual(@as(usize, 2), stack.undo.items[1].group.len);
    try testing.expect(stack.undo.items[1].group[0].kind == .group);
    try testing.expectEqual(fakeTab(4), stack.undo.items[1].group[1].tab.?);

    // The last member of a group takes the group with it (and frees it).
    _ = forgetIn(&stack, alloc, .{ .tab = fakeTab(4) });
    try testing.expectEqual(@as(usize, 1), stack.undo.items.len);
    try testing.expectEqual(fakeTab(2), stack.undo.items[0].tab.?);
}

test "win32 undo: a surface or tab leaving for good drops its entries, redo included" {
    const alloc = testing.allocator;
    var stack: undo_model.Stack(Entry) = .{};
    defer stack.deinit(alloc);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(alloc);
    const s1: *Surface = @ptrFromInt(0x5000);
    const s2: *Surface = @ptrFromInt(0x5100);
    try stack.push(alloc, .{ .kind = .close_tab, .expires_ms = 100, .window = fakeWindow(1), .tab = fakeTab(1) }, &dis);
    try stack.push(alloc, .{ .kind = .new_split, .expires_ms = 100, .tab = fakeTab(2), .surface = s1 }, &dis);
    try stack.pushRedo(alloc, .{ .kind = .close_split, .expires_ms = 100, .tab = fakeTab(2), .surface = s2 });
    try stack.pushRedo(alloc, .{ .kind = .new_tab, .expires_ms = 100, .tab = fakeTab(1) });

    _ = forgetIn(&stack, alloc, .{ .surface = s2 });
    try testing.expectEqual(@as(usize, 2), stack.undo.items.len);
    try testing.expectEqual(@as(usize, 1), stack.redo.items.len);
    _ = forgetIn(&stack, alloc, .{ .tab = fakeTab(1) });
    try testing.expectEqual(@as(usize, 1), stack.undo.items.len);
    try testing.expectEqual(@as(usize, 0), stack.redo.items.len);
    try testing.expectEqual(s1, stack.undo.items[0].surface.?);
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

test "win32 undo: an entry put back with restoreUndo keeps redo" {
    const alloc = testing.allocator;
    var stack: undo_model.Stack(Entry) = .{};
    defer stack.deinit(alloc);
    try stack.pushRedo(alloc, .{ .kind = .new_tab, .expires_ms = 100, .tab = fakeTab(1) });
    try stack.restoreUndo(alloc, .{ .kind = .close_tab, .expires_ms = 100, .tab = fakeTab(2) });
    try testing.expectEqual(@as(usize, 1), stack.undo.items.len);
    try testing.expectEqual(@as(usize, 1), stack.redo.items.len);
}

// -- Flip tests: the production flip/finish against a fake environment ----------

fn fakeSurface() !*Surface {
    const s = try testing.allocator.create(Surface);
    // Only `refs` is read by the trees; it never gets near zero.
    s.refs = 1000;
    return s;
}

const Fake = struct {
    st: undo_model.Stack(Entry) = .{},
    /// The tree the fake tab shows.
    tree: Surface.Tree = .empty,
    events: std.ArrayList(u8) = .empty,
    /// The `show_s` of the last tree swap.
    shown: ?bool = null,
    oom_tab: ?*Tab = null,
    refuse_park: bool = false,
    ends_session: bool = false,
    window_missing: bool = false,
    closed_splits: usize = 0,
    closed_tabs: usize = 0,
    closed_windows: usize = 0,
    armed: usize = 0,

    fn deinit(self: *Fake) void {
        var all: std.ArrayList(Entry) = .empty;
        defer all.deinit(testing.allocator);
        self.st.takeAll(&all, testing.allocator) catch unreachable;
        closeAllWith(Closer{ .f = self }, all.items);
        self.st.deinit(testing.allocator);
        self.tree.deinit();
        self.events.deinit(testing.allocator);
    }

    fn event(self: *Fake, c: u8) void {
        self.events.append(testing.allocator, c) catch unreachable;
    }

    fn tabUnpark(self: *Fake, tab: *Tab, index: usize) error{ OutOfMemory, NotParked }!void {
        _ = index;
        if (self.oom_tab == tab) return error.OutOfMemory;
        self.event('u');
    }

    fn tabPark(self: *Fake, tab: *Tab) ?usize {
        _ = tab;
        if (self.refuse_park) return null;
        self.event('p');
        return 2;
    }

    fn tabActivate(self: *Fake, tab: *Tab) void {
        _ = tab;
        self.event('a');
    }

    fn windowUnpark(self: *Fake, window: *Window) WindowStep {
        _ = window;
        if (self.window_missing) return .missing;
        self.event('U');
        return .done;
    }

    fn windowPark(self: *Fake, window: *Window) WindowStep {
        _ = window;
        if (self.window_missing) return .missing;
        self.event('P');
        return .done;
    }

    fn windowEndsSession(self: *Fake, window: *Window) bool {
        _ = window;
        return self.ends_session;
    }

    fn windowActivate(self: *Fake, window: *Window) void {
        _ = window;
        self.event('A');
    }

    fn treeOf(self: *Fake, tab: *Tab) *const Surface.Tree {
        _ = tab;
        return &self.tree;
    }

    fn swapTree(self: *Fake, tab: *Tab, tree: Surface.Tree, s: *Surface, show_s: bool) void {
        _ = tab;
        _ = s;
        self.tree.deinit();
        self.tree = tree;
        self.shown = show_s;
    }

    fn stack(self: *Fake) *undo_model.Stack(Entry) {
        return &self.st;
    }

    fn allocator(self: *Fake) Allocator {
        _ = self;
        return testing.allocator;
    }

    fn newExpiry(self: *Fake) u64 {
        _ = self;
        return 2_000_000;
    }

    fn closeEntries(self: *Fake, entries: []const Entry) void {
        closeAllWith(Closer{ .f = self }, entries);
    }

    fn armTimer(self: *Fake) void {
        self.armed += 1;
    }

    const Closer = struct {
        f: *Fake,

        fn closeSplit(self: Closer, e: Entry) void {
            self.f.closed_splits += 1;
            releaseSplit(e);
        }
        fn closeTab(self: Closer, tab: *Tab) void {
            _ = tab;
            self.f.closed_tabs += 1;
        }
        fn closeWindow(self: Closer, window: *Window) void {
            _ = window;
            self.f.closed_windows += 1;
        }
        fn freeGroup(self: Closer, group: []Entry) void {
            _ = self;
            testing.allocator.free(group);
        }
    };

    fn push(self: *Fake, e: Entry) !void {
        var displaced: std.ArrayList(Entry) = .empty;
        defer displaced.deinit(testing.allocator);
        try self.st.push(testing.allocator, e, &displaced);
        self.closeEntries(displaced.items);
    }

    fn undo(self: *Fake) bool {
        const e = self.st.popUndo(0) orelse return false;
        return finish(self, e, .undo);
    }

    fn redo(self: *Fake) bool {
        const e = self.st.popRedo(0) orelse return false;
        return finish(self, e, .redo);
    }
};

/// Panes A and B side by side (ratio 0.3), and the tree with B taken out.
const Pair = struct {
    sa: *Surface,
    sb: *Surface,
    ab: Surface.Tree,
    only_a: Surface.Tree,

    fn init() !Pair {
        const alloc = testing.allocator;
        const sa = try fakeSurface();
        const sb = try fakeSurface();
        var ta: Surface.Tree = try .init(alloc, sa);
        defer ta.deinit();
        var tb: Surface.Tree = try .init(alloc, sb);
        defer tb.deinit();
        var ab = try ta.split(alloc, .root, .right, 0.3, &tb);
        errdefer ab.deinit();
        const only_a = try ab.remove(alloc, ab.locate(sb).?);
        return .{ .sa = sa, .sb = sb, .ab = ab, .only_a = only_a };
    }

    fn deinit(self: *Pair) void {
        self.ab.deinit();
        self.only_a.deinit();
        testing.allocator.destroy(self.sa);
        testing.allocator.destroy(self.sb);
    }

    /// The entry of a split change; the tab shows `after`.
    fn entry(self: *Pair, kind: undo_model.Kind) !Entry {
        const closing = kind == .close_split;
        return .{
            .kind = kind,
            .expires_ms = 1_000_000,
            .tab = fakeTab(1),
            .surface = self.sb,
            // Closing B: before is AB, after is A. Creating B: the other way.
            .before = try (if (closing) self.ab else self.only_a).clone(testing.allocator),
            .after = try (if (closing) self.only_a else self.ab).clone(testing.allocator),
            .current_after = true,
        };
    }
};

test "win32 undo: close split then undo restores the exact tree" {
    var p = try Pair.init();
    defer p.deinit();
    var f: Fake = .{ .tree = try p.only_a.clone(testing.allocator) };
    defer f.deinit();
    try f.push(try p.entry(.close_split));

    try testing.expect(f.undo());
    try testing.expect(treesEql(&f.tree, &p.ab)); // same panes, the old ratio
    try testing.expect(!treesEql(&f.tree, &p.only_a));
    try testing.expectEqual(true, f.shown.?); // the split is shown again
    try testing.expectEqual(@as(usize, 0), f.st.undo.items.len);
    try testing.expectEqual(@as(usize, 1), f.st.redo.items.len);
    try testing.expect(!f.st.redo.items[0].current_after);
    try testing.expectEqual(@as(usize, 1), f.armed);
}

test "win32 undo: undo after a later split change drops the entry" {
    var p = try Pair.init();
    defer p.deinit();
    // The user changed the tree after the close (here: a split of A).
    const alloc = testing.allocator;
    const sc = try fakeSurface();
    defer alloc.destroy(sc);
    var ta: Surface.Tree = try .init(alloc, p.sa);
    defer ta.deinit();
    var tc: Surface.Tree = try .init(alloc, sc);
    defer tc.deinit();
    var other = try ta.split(alloc, .root, .down, 0.5, &tc);
    defer other.deinit();

    var f: Fake = .{ .tree = try other.clone(alloc) };
    defer f.deinit();
    try f.push(try p.entry(.close_split));

    try testing.expect(!f.undo());
    try testing.expect(f.shown == null); // the tree was left alone
    try testing.expectEqual(@as(usize, 0), f.st.undo.items.len);
    try testing.expectEqual(@as(usize, 0), f.st.redo.items.len);
    try testing.expectEqual(@as(usize, 1), f.closed_splits); // snapshots released
}

test "win32 undo: redo after undo of close closes again" {
    var p = try Pair.init();
    defer p.deinit();
    var f: Fake = .{ .tree = try p.only_a.clone(testing.allocator) };
    defer f.deinit();
    try f.push(try p.entry(.close_split));

    try testing.expect(f.undo());
    try testing.expect(f.redo());
    try testing.expect(treesEql(&f.tree, &p.only_a));
    try testing.expectEqual(false, f.shown.?); // B is parked again
    try testing.expectEqual(@as(usize, 1), f.st.undo.items.len);
    try testing.expectEqual(@as(usize, 0), f.st.redo.items.len);
    try testing.expect(f.st.undo.items[0].current_after);
    // And it can be undone once more.
    try testing.expect(f.undo());
    try testing.expect(treesEql(&f.tree, &p.ab));
}

test "win32 undo: redo after undo of a closed tab parks it again" {
    var f: Fake = .{};
    defer f.deinit();
    try f.push(.{ .kind = .close_tab, .expires_ms = 1_000_000, .window = fakeWindow(1), .tab = fakeTab(1), .index = 2, .parked = true });
    try testing.expect(f.undo());
    try testing.expect(!f.st.redo.items[0].parked);
    try testing.expect(f.redo());
    try testing.expect(f.st.undo.items[0].parked);
    try testing.expectEqualStrings("uap", f.events.items);
}

test "win32 undo: new tab then undo parks it, redo restores" {
    var f: Fake = .{};
    defer f.deinit();
    try f.push(.{ .kind = .new_tab, .expires_ms = 1_000_000, .window = fakeWindow(1), .tab = fakeTab(1) });

    try testing.expect(f.undo());
    try testing.expectEqualStrings("p", f.events.items);
    try testing.expect(f.st.redo.items[0].parked);
    try testing.expectEqual(@as(usize, 2), f.st.redo.items[0].index); // where it was

    try testing.expect(f.redo());
    try testing.expectEqualStrings("pua", f.events.items);
    try testing.expect(!f.st.undo.items[0].parked);
    try testing.expectEqual(@as(usize, 0), f.st.redo.items.len);
}

test "win32 undo: undo of a created split hides it, redo shows it" {
    var p = try Pair.init();
    defer p.deinit();
    var f: Fake = .{ .tree = try p.ab.clone(testing.allocator) };
    defer f.deinit();
    try f.push(try p.entry(.new_split));

    try testing.expect(f.undo());
    try testing.expect(treesEql(&f.tree, &p.only_a));
    try testing.expectEqual(false, f.shown.?);
    try testing.expect(f.redo());
    try testing.expect(treesEql(&f.tree, &p.ab));
    try testing.expectEqual(true, f.shown.?);
}

test "win32 undo: tmux kill-pane is not undoable" {
    try testing.expect(!surfaceCloseUndoable(.{ .child_exited = false, .final = true, .window_parked = false }));
}

test "win32 undo: a failed flip keeps the entry where it was, a gone one drops it" {
    var f: Fake = .{ .oom_tab = fakeTab(1) };
    defer f.deinit();
    try f.push(.{ .kind = .close_tab, .expires_ms = 1_000_000, .window = fakeWindow(1), .tab = fakeTab(1), .parked = true });
    try testing.expect(!f.undo());
    try testing.expectEqual(@as(usize, 1), f.st.undo.items.len);
    try testing.expect(f.st.undo.items[0].parked);

    // A window that is not in the parked list any more: dropped, and nothing
    // is closed in its name.
    var g: Fake = .{ .window_missing = true };
    defer g.deinit();
    try g.push(.{ .kind = .close_window, .expires_ms = 1_000_000, .window = fakeWindow(1), .parked = true });
    try testing.expect(!g.undo());
    try testing.expectEqual(@as(usize, 0), g.st.undo.items.len);
    try testing.expectEqual(@as(usize, 0), g.st.redo.items.len);
    try testing.expectEqual(@as(usize, 0), g.closed_windows);
}

test "win32 undo: refusals drop the entry" {
    // Undoing the creation of the window that ends the session.
    var f: Fake = .{ .ends_session = true };
    defer f.deinit();
    try f.push(.{ .kind = .new_window, .expires_ms = 1_000_000, .window = fakeWindow(1) });
    try testing.expect(!f.undo());
    try testing.expectEqual(@as(usize, 0), f.st.redo.items.len);
    try testing.expectEqual(@as(usize, 0), f.st.undo.items.len);
    try testing.expectEqualStrings("", f.events.items);

    // Undoing a new tab that is now the only tab of its window.
    var g: Fake = .{ .refuse_park = true };
    defer g.deinit();
    try g.push(.{ .kind = .new_tab, .expires_ms = 1_000_000, .window = fakeWindow(1), .tab = fakeTab(1) });
    try testing.expect(!g.undo());
    try testing.expectEqual(@as(usize, 0), g.st.undo.items.len);
    try testing.expectEqual(@as(usize, 0), g.st.redo.items.len);
}

test "win32 undo: a group that flips only in part splits into a flipped group and a remainder" {
    var f: Fake = .{ .oom_tab = fakeTab(2) };
    defer f.deinit();
    const members = try testing.allocator.alloc(Entry, 3);
    for (members, 0..) |*m, i| {
        m.* = .{ .kind = .close_tab, .expires_ms = 1_000_000, .window = fakeWindow(1), .tab = fakeTab(i + 1), .index = i, .parked = true };
    }
    try f.push(.{ .kind = .group, .expires_ms = 1_000_000, .group = members });

    try testing.expect(f.undo());
    // Newest first: the third and the first came back (in group order), the second did not.
    try testing.expectEqual(@as(usize, 1), f.st.undo.items.len);
    try testing.expectEqual(@as(usize, 1), f.st.redo.items.len);
    const back = f.st.redo.items[0];
    try testing.expect(back.kind == .group);
    try testing.expectEqual(@as(usize, 2), back.group.len);
    try testing.expectEqual(fakeTab(1), back.group[0].tab.?);
    try testing.expectEqual(fakeTab(3), back.group[1].tab.?);
    try testing.expect(!back.group[0].parked);
    const rest = f.st.undo.items[0];
    try testing.expectEqual(fakeTab(2), rest.group[1].tab.?);
    try testing.expect(rest.group[1].parked);
    try testing.expect(rest.group[0].kind == .group); // inert
}

test "win32 undo: forgetting a surface drops the split entries whose snapshots hold it" {
    var p = try Pair.init();
    defer p.deinit();
    var st: undo_model.Stack(Entry) = .{};
    defer st.deinit(testing.allocator);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(testing.allocator);
    // Entry about B; its snapshots hold A as well.
    try st.push(testing.allocator, try p.entry(.close_split), &dis);
    const held = p.sa.refs;

    // A is killed (tmux kill-pane): the entry goes, and A is not kept alive.
    try testing.expectEqual(@as(usize, 1), forgetIn(&st, testing.allocator, .{ .surface = p.sa }));
    try testing.expectEqual(@as(usize, 0), st.undo.items.len);
    try testing.expect(p.sa.refs < held);
}

test "win32 undo: a tab that moves or closes takes its entries along" {
    var p = try Pair.init();
    defer p.deinit();
    var st: undo_model.Stack(Entry) = .{};
    defer st.deinit(testing.allocator);
    var dis: std.ArrayList(Entry) = .empty;
    defer dis.deinit(testing.allocator);
    try st.push(testing.allocator, try p.entry(.close_split), &dis);
    try st.push(testing.allocator, .{ .kind = .new_tab, .expires_ms = 1, .window = fakeWindow(1), .tab = fakeTab(1) }, &dis);
    try st.push(testing.allocator, .{ .kind = .new_tab, .expires_ms = 1, .window = fakeWindow(1), .tab = fakeTab(7) }, &dis);
    const held = p.sb.refs;

    try testing.expectEqual(@as(usize, 2), forgetIn(&st, testing.allocator, .{ .tab = fakeTab(1) }));
    try testing.expectEqual(@as(usize, 1), st.undo.items.len);
    try testing.expectEqual(fakeTab(7), st.undo.items[0].tab.?);
    try testing.expect(p.sb.refs < held); // the parked split's snapshots are gone
}
