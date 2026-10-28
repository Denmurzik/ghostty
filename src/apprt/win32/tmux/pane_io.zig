//! send-keys gate and pane input timing (owner: M4 task 11).
//!
//! `send-keys` answers at once; its bytes wait in one FIFO and are written
//! by the `tmux_keys` timer once the head item's pane is `gate_age_ms` old
//! and its tab's layout has been quiet for `gate_settle_ms` (R-M4-6). The
//! single queue keeps the order across and within panes.
//!
//! This gate and the pty resize prime (`termio/resize_prime.zig`) stack
//! without adding delay: the gate holds the write back until long after a
//! split's resize, so the prime (a key-up prefix, no wait of its own) is
//! normally not even armed when the bytes arrive.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const global = @import("../../../global.zig");
const terminal = @import("../../../terminal/main.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");
const messages = @import("../messages.zig");
const commands = @import("commands.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.win32_tmux_pane_io);

pub const gate_age_ms = 300;
pub const gate_settle_ms = 150;
const timer_ms = 25;

pub const Item = struct {
    surface: *Surface,
    tab_id: u32,
    pane_id: u32,
    bytes: []u8,
};

/// `App.tmux_keys`.
pub const State = struct {
    queue: std.ArrayList(Item) = .empty,
    timer_armed: bool = false,
    /// Tab id to the time of its last layout change.
    tab_changed_ms: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Pane id to the first time a layout change saw it.
    pane_seen_ms: std.AutoHashMapUnmanaged(u32, u64) = .empty,
};

fn nowMs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toMilliseconds()));
}

pub fn gateOpen(created_ms: u64, tab_changed_ms: u64, now_ms: u64) bool {
    return now_ms -| created_ms >= gate_age_ms and now_ms -| tab_changed_ms >= gate_settle_ms;
}

/// Queue `bytes` for `surface`; they are written once the gate opens.
pub fn sendKeys(app: *App, surface: *Surface, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const alloc = app.core_app.alloc;
    const st = &app.tmux_keys;
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);
    try st.pane_seen_ms.ensureUnusedCapacity(alloc, 1);
    try st.queue.append(alloc, .{
        .surface = surface,
        .tab_id = surface.tab.id,
        .pane_id = surface.pane_id,
        .bytes = owned,
    });
    // A pane no layout change has seen yet counts from now.
    st.pane_seen_ms.putAssumeCapacity(surface.pane_id, st.pane_seen_ms.get(surface.pane_id) orelse nowMs());
    armTimer(app);
}

fn armTimer(app: *App) void {
    const st = &app.tmux_keys;
    if (st.timer_armed) return;
    if (win32.user32.SetTimer(app.msg_hwnd, messages.timers.msg_window.tmux_keys, timer_ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
        return;
    }
    st.timer_armed = true;
}

/// Writes the head items whose gate is open, in order; stops at the first
/// closed gate so no byte overtakes an earlier one.
fn flush(
    st: *State,
    alloc: Allocator,
    now_ms: u64,
    ctx: anytype,
    comptime deliver: fn (@TypeOf(ctx), *Surface, []const u8) void,
) void {
    while (st.queue.items.len > 0) {
        const head = st.queue.items[0];
        const created = st.pane_seen_ms.get(head.pane_id) orelse now_ms;
        const changed = st.tab_changed_ms.get(head.tab_id) orelse 0;
        if (!gateOpen(created, changed, now_ms)) return;
        _ = st.queue.orderedRemove(0);
        deliver(ctx, head.surface, head.bytes);
        alloc.free(head.bytes);
    }
}

fn write(app: *App, surface: *Surface, bytes: []const u8) void {
    if (!surface.initialized) return;
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const text = keys.toTextAction(arena.allocator(), bytes) catch return;
    _ = surface.core_surface.performBindingAction(.{ .text = text }) catch |err|
        log.warn("send-keys write failed err={}", .{err});
}

pub fn onTimer(app: *App) void {
    const st = &app.tmux_keys;
    flush(st, app.core_app.alloc, nowMs(), app, write);
    pruneTabs(st, nowMs());
    if (st.queue.items.len == 0 and st.timer_armed) {
        _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.tmux_keys);
        st.timer_armed = false;
    }
}

/// Every tab layout change restarts that tab's settle time and dates the
/// panes it sees for the first time.
pub fn layoutChanged(tab: *Tab) void {
    const app = tab.window.app;
    const alloc = app.core_app.alloc;
    const st = &app.tmux_keys;
    const now = nowMs();
    st.tab_changed_ms.put(alloc, tab.id, now) catch return;
    pruneTabs(st, now);
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        // First sighting only: a pane already seen keeps its time.
        const gop = st.pane_seen_ms.getOrPut(alloc, entry.view.pane_id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = now;
    }
}

pub fn surfaceDestroying(surface: *Surface) void {
    const app = surface.app;
    dropPane(&app.tmux_keys, app.core_app.alloc, surface.pane_id);
}

fn dropPane(st: *State, alloc: Allocator, pane_id: u32) void {
    var i: usize = 0;
    while (i < st.queue.items.len) {
        if (st.queue.items[i].pane_id == pane_id) {
            alloc.free(st.queue.orderedRemove(i).bytes);
        } else i += 1;
    }
    _ = st.pane_seen_ms.remove(pane_id);
}

/// Drops the tabs whose layout has been quiet long enough: no entry means
/// quiet, so this only bounds the map. A few entries per call.
fn pruneTabs(st: *State, now_ms: u64) void {
    var stale: [16]u32 = undefined;
    var n: usize = 0;
    var it = st.tab_changed_ms.iterator();
    while (it.next()) |e| {
        if (now_ms -| e.value_ptr.* < gate_settle_ms) continue;
        stale[n] = e.key_ptr.*;
        n += 1;
        if (n == stale.len) break;
    }
    for (stale[0..n]) |k| _ = st.tab_changed_ms.remove(k);
}

fn releaseAll(st: *State, alloc: Allocator) void {
    for (st.queue.items) |i| alloc.free(i.bytes);
    st.queue.deinit(alloc);
    st.tab_changed_ms.deinit(alloc);
    st.pane_seen_ms.deinit(alloc);
    st.* = .{};
}

/// The start of `App.terminate`.
pub fn appStopping(app: *App) void {
    const st = &app.tmux_keys;
    if (st.timer_armed) _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.tmux_keys);
    releaseAll(st, app.core_app.alloc);
}

/// The visible rows, LF after each, trailing blanks trimmed per line.
pub fn capture(surface: *Surface, req: commands.CaptureRequest, w: *std.Io.Writer) !void {
    _ = req;
    if (!surface.initialized) return;
    const cs = &surface.core_surface;
    cs.renderer_state.mutex.lockUncancelable(global.io());
    defer cs.renderer_state.mutex.unlock(global.io());
    try dumpViewport(surface.app.core_app.alloc, cs.renderer_state.terminal, w);
}

fn dumpViewport(alloc: Allocator, t: *terminal.Terminal, w: *std.Io.Writer) !void {
    const screen = t.screens.active;
    var raw: std.Io.Writer.Allocating = .init(alloc);
    defer raw.deinit();
    try screen.dumpString(&raw.writer, .{
        .tl = screen.pages.getTopLeft(.active),
        .br = screen.pages.getBottomRight(.active),
        .unwrap = false,
    });
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, raw.written(), '\n');
    while (it.next()) |line| {
        if (rows == t.rows) break;
        try w.writeAll(std.mem.trimEnd(u8, line, " \r"));
        try w.writeByte('\n');
        rows += 1;
    }
    // Trailing blank rows may be left out of the dump.
    while (rows < t.rows) : (rows += 1) try w.writeByte('\n');
}

const testing = std.testing;

test "win32 tmux pane_io: gate" {
    // age 299 / 300 with a quiet tab, then settle 149 / 150 with an old pane.
    try testing.expect(!gateOpen(1000, 0, 1299));
    try testing.expect(gateOpen(1000, 0, 1300));
    try testing.expect(!gateOpen(0, 1000, 1149));
    try testing.expect(gateOpen(0, 1000, 1150));
    // Both must hold.
    try testing.expect(!gateOpen(1000, 1200, 1300));
    try testing.expect(gateOpen(1000, 1100, 1300));
}

const Sink = struct {
    got: std.ArrayList(u8) = .empty,
    fn deliver(self: *Sink, s: *Surface, bytes: []const u8) void {
        self.got.append(testing.allocator, @intCast(@intFromPtr(s) / 4096)) catch unreachable;
        self.got.appendSlice(testing.allocator, bytes) catch unreachable;
    }
};

fn fakeSurface(n: usize) *Surface {
    return @ptrFromInt(n * 4096);
}

fn enqueue(st: *State, pane: u32, tab: u32, bytes: []const u8) !void {
    try st.queue.append(testing.allocator, .{
        .surface = fakeSurface(pane),
        .tab_id = tab,
        .pane_id = pane,
        .bytes = try testing.allocator.dupe(u8, bytes),
    });
}

fn deinitState(st: *State) void {
    for (st.queue.items) |i| testing.allocator.free(i.bytes);
    st.queue.deinit(testing.allocator);
    st.tab_changed_ms.deinit(testing.allocator);
    st.pane_seen_ms.deinit(testing.allocator);
}

test "win32 tmux pane_io: order kept across panes" {
    var st: State = .{};
    defer deinitState(&st);
    var sink: Sink = .{};
    defer sink.got.deinit(testing.allocator);
    try st.pane_seen_ms.put(testing.allocator, 1, 0);
    try st.pane_seen_ms.put(testing.allocator, 2, 900); // young
    try enqueue(&st, 2, 7, "b"); // head: pane 2 is young, blocks pane 1
    try enqueue(&st, 1, 7, "a");
    try enqueue(&st, 2, 7, "c");
    flush(&st, testing.allocator, 1000, &sink, Sink.deliver);
    try testing.expectEqual(@as(usize, 0), sink.got.items.len);
    try testing.expectEqual(@as(usize, 3), st.queue.items.len);
    flush(&st, testing.allocator, 1200, &sink, Sink.deliver);
    try testing.expectEqualSlices(u8, &.{ 2, 'b', 1, 'a', 2, 'c' }, sink.got.items);
    try testing.expectEqual(@as(usize, 0), st.queue.items.len);
}

test "win32 tmux pane_io: closed pane drops its queue" {
    var st: State = .{};
    defer deinitState(&st);
    var sink: Sink = .{};
    defer sink.got.deinit(testing.allocator);
    try st.pane_seen_ms.put(testing.allocator, 1, 0);
    try st.pane_seen_ms.put(testing.allocator, 2, 0);
    try enqueue(&st, 1, 7, "a");
    try enqueue(&st, 2, 7, "b");
    try enqueue(&st, 1, 7, "c");
    dropPane(&st, testing.allocator, 1);
    try testing.expect(st.pane_seen_ms.get(1) == null);
    flush(&st, testing.allocator, 1000, &sink, Sink.deliver);
    try testing.expectEqualSlices(u8, &.{ 2, 'b' }, sink.got.items);
}

test "win32 tmux pane_io: capture visible screen" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 4 });
    defer t.deinit(alloc);
    try t.printString("hello   ");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("tok-1");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try dumpViewport(alloc, &t, &aw.writer);
    try testing.expectEqualStrings("hello\ntok-1\n\n\n", aw.written());
}

test "win32 tmux pane_io: quiet tabs are pruned" {
    var st: State = .{};
    defer deinitState(&st);
    for (0..40) |i| try st.tab_changed_ms.put(testing.allocator, @intCast(i), 1000);
    try st.tab_changed_ms.put(testing.allocator, 100, 1900);
    // Not yet quiet: nothing goes.
    pruneTabs(&st, 1100);
    try testing.expectEqual(@as(u32, 41), st.tab_changed_ms.count());
    // Three calls clear the old ones (16 per call); the fresh tab stays.
    pruneTabs(&st, 1200);
    pruneTabs(&st, 1200);
    pruneTabs(&st, 1200);
    try testing.expectEqual(@as(u32, 1), st.tab_changed_ms.count());
    try testing.expect(st.tab_changed_ms.get(100) != null);
}

test "win32 tmux pane_io: releaseAll frees everything" {
    var st: State = .{};
    try enqueue(&st, 1, 7, "a");
    try st.pane_seen_ms.put(testing.allocator, 1, 0);
    try st.tab_changed_ms.put(testing.allocator, 7, 0);
    st.timer_armed = true;
    releaseAll(&st, testing.allocator);
    try testing.expectEqual(@as(usize, 0), st.queue.items.len);
    try testing.expect(!st.timer_armed);
    try testing.expectEqual(@as(u32, 0), st.pane_seen_ms.count());
}
