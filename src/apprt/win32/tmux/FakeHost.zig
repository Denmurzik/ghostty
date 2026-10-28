//! Fake host for tmux command tests (owner: M4 task 7).
//!
//! Windows are `SplitTree`s of pane ids over a fixed 1000x600 px area with
//! 10x20 px cells and a 4 px divider. Pane and window ids come from counters;
//! the pane counter is also used up by a respawn, like the real host.
const FakeHost = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const SplitLayout = @import("../SplitLayout.zig");
const geom = @import("../geom.zig");
const layout_mod = @import("layout.zig");
const commands = @import("commands.zig");
const ns_mod = @import("namespaces.zig");

pub const View = struct {
    id: u32,

    pub fn ref(self: *View, alloc: Allocator) Allocator.Error!*View {
        const ptr = try alloc.create(View);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *View, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn eql(self: *const View, other: *const View) bool {
        return self.id == other.id;
    }
};
pub const Tree = SplitTree(View);
pub const TreeLayout = SplitLayout.Layout(Tree);

pub const Pane = struct { id: u32 };
pub const Window = struct { id: u32 };

pub const area: geom.Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 600 };
pub const cell_w: u32 = 10;
pub const cell_h: u32 = 20;
pub const gap: i32 = 4;

const PaneState = struct {
    title: []u8,
    cwd: []u8,
    exited: bool = false,
    pid: u32,
};

const WindowState = struct {
    id: u32,
    tree: Tree,
    active: u32,
    /// The fake Ghostty window of a namespace (0: none).
    owner: u32 = 0,
};

pub const SpawnKind = enum { initial, split, respawn };

pub const SpawnRecord = struct {
    kind: SpawnKind,
    pane: u32,
    command: ?[]u8,
    cwd: []u8,
    start_dir: ?[]u8,
    extra_env: usize,
};

alloc: Allocator,
windows_list: std.ArrayList(WindowState) = .empty,
pane_states: std.AutoHashMapUnmanaged(u32, PaneState) = .empty,
opts: commands.Options = .{},
spawns: std.ArrayList(SpawnRecord) = .empty,
next_pane: u32 = 1,
next_window: u32 = 1,
next_owner: u32 = 100,
ns_table: ns_mod.Table = .{},
focused: u32 = 0,

/// Test hooks: errors the next split/respawn returns.
inject_split: ?commands.SplitError = null,
inject_respawn: ?commands.RespawnError = null,
/// The directory a `NoDirectory` error names.
failed_dir: []const u8 = "",

options_changed: std.ArrayList(u32) = .empty,
zoom_toggles: u32 = 0,
clipboard: ?[]u8 = null,
clipboard_denied: bool = false,
/// Test switch: send-keys answers TooLarge.
keys_too_large: bool = false,
keys: std.ArrayList([]u8) = .empty,

/// One window holding the leader pane (%1, @1).
pub fn init(alloc: Allocator) !FakeHost {
    var h: FakeHost = .{ .alloc = alloc };
    errdefer h.deinit();
    const id = try h.newPane(.initial, .{
        .command = null,
        .cwd = "C:\\work",
        .client_env = &.{},
        .extra_env = &.{},
        .start_dir = null,
    });
    var view: View = .{ .id = id };
    var tree = try Tree.init(alloc, &view);
    errdefer tree.deinit();
    try h.windows_list.append(alloc, .{ .id = h.next_window, .tree = tree, .active = id });
    h.next_window += 1;
    h.focused = id;
    return h;
}

pub fn deinit(self: *FakeHost) void {
    const a = self.alloc;
    for (self.windows_list.items) |*w| w.tree.deinit();
    self.windows_list.deinit(a);
    var it = self.pane_states.valueIterator();
    while (it.next()) |p| {
        a.free(p.title);
        a.free(p.cwd);
    }
    self.pane_states.deinit(a);
    self.opts.deinit(a);
    self.ns_table.deinit(a);
    for (self.spawns.items) |s| freeRecord(a, s);
    self.spawns.deinit(a);
    self.options_changed.deinit(a);
    if (self.clipboard) |c| a.free(c);
    for (self.keys.items) |k| a.free(k);
    self.keys.deinit(a);
}

fn freeRecord(a: Allocator, s: SpawnRecord) void {
    if (s.command) |c| a.free(c);
    a.free(s.cwd);
    if (s.start_dir) |d| a.free(d);
}

fn record(self: *FakeHost, kind: SpawnKind, pane: u32, spawn: commands.Spawn) Allocator.Error!void {
    const a = self.alloc;
    const command = if (spawn.command) |c| try a.dupe(u8, c) else null;
    errdefer if (command) |c| a.free(c);
    const cwd = try a.dupe(u8, spawn.cwd);
    errdefer a.free(cwd);
    const start_dir = if (spawn.start_dir) |d| try a.dupe(u8, d) else null;
    errdefer if (start_dir) |d| a.free(d);
    try self.spawns.append(a, .{
        .kind = kind,
        .pane = pane,
        .command = command,
        .cwd = cwd,
        .start_dir = start_dir,
        .extra_env = spawn.extra_env.len,
    });
}

/// Allocates a pane id and its state; records the spawn.
fn newPane(self: *FakeHost, kind: SpawnKind, spawn: commands.Spawn) Allocator.Error!u32 {
    const a = self.alloc;
    const id = self.next_pane;
    const title = try a.dupe(u8, "");
    errdefer a.free(title);
    const cwd = try a.dupe(u8, spawn.start_dir orelse spawn.cwd);
    errdefer a.free(cwd);
    try self.pane_states.put(a, id, .{ .title = title, .cwd = cwd, .pid = 1000 + id });
    errdefer _ = self.pane_states.remove(id);
    try self.record(kind, id, spawn);
    self.next_pane += 1;
    return id;
}

fn windowIndex(self: *const FakeHost, id: u32) ?usize {
    for (self.windows_list.items, 0..) |w, i| if (w.id == id) return i;
    return null;
}

fn windowOfPane(self: *const FakeHost, pane: u32) ?usize {
    for (self.windows_list.items, 0..) |w, i| {
        if (leafHandle(&w.tree, pane) != null) return i;
    }
    return null;
}

pub fn leafHandle(tree: *const Tree, pane: u32) ?Tree.Node.Handle {
    for (tree.nodes, 0..) |n, i| switch (n) {
        .leaf => |v| if (v.id == pane) return @fromBackingInt(@intCast(i)),
        .split => {},
    };
    return null;
}

/// Computes the layout of window `wi`; the caller frees it.
pub fn computeLayout(self: *const FakeHost, wi: usize) !TreeLayout {
    return TreeLayout.compute(self.alloc, &self.windows_list.items[wi].tree, area, gap);
}

/// Pane ids of window `wi` in tree order.
pub fn paneIds(self: *const FakeHost, alloc: Allocator, wi: usize) ![]u32 {
    var l = try self.computeLayout(wi);
    defer l.deinit(self.alloc);
    const ids = try alloc.alloc(u32, l.leaves.len);
    for (l.leaves, ids) |leaf, *id| id.* = leaf.view.id;
    return ids;
}

pub fn windowCount(self: *const FakeHost) usize {
    return self.windows_list.items.len;
}

pub fn treeOf(self: *const FakeHost, window_id: u32) *const Tree {
    return &self.windows_list.items[self.windowIndex(window_id).?].tree;
}

pub fn titleOf(self: *const FakeHost, pane: u32) []const u8 {
    return self.pane_states.get(pane).?.title;
}

pub fn markExited(self: *FakeHost, pane: u32) void {
    self.pane_states.getPtr(pane).?.exited = true;
}

pub fn spawnsOf(self: *const FakeHost, pane: u32, kind: SpawnKind, n: usize) ?SpawnRecord {
    var seen: usize = 0;
    for (self.spawns.items) |s| {
        if (s.pane != pane or s.kind != kind) continue;
        if (seen == n) return s;
        seen += 1;
    }
    return null;
}

// Host contract (see commands.zig).

pub fn findPane(self: *FakeHost, id: u32) ?Pane {
    return if (self.pane_states.contains(id)) .{ .id = id } else null;
}

pub fn findWindow(self: *FakeHost, id: u32) ?Window {
    return if (self.windowIndex(id) != null) .{ .id = id } else null;
}

pub fn fallbackPane(self: *FakeHost) ?Pane {
    return self.findPane(self.focused);
}

pub fn windowOf(self: *FakeHost, pane: Pane) Window {
    return .{ .id = self.windows_list.items[self.windowOfPane(pane.id).?].id };
}

pub fn windows(self: *FakeHost, alloc: Allocator) Allocator.Error![]Window {
    const out = try alloc.alloc(Window, self.windows_list.items.len);
    for (self.windows_list.items, out) |w, *o| o.* = .{ .id = w.id };
    return out;
}

pub fn panes(self: *FakeHost, alloc: Allocator, win: Window) Allocator.Error![]Pane {
    const wi = self.windowIndex(win.id).?;
    var l = try self.computeLayout(wi);
    defer l.deinit(self.alloc);
    const out = try alloc.alloc(Pane, l.leaves.len);
    for (l.leaves, out) |leaf, *o| o.* = .{ .id = leaf.view.id };
    return out;
}

pub fn activePane(self: *FakeHost, win: Window) Pane {
    return .{ .id = self.windows_list.items[self.windowIndex(win.id).?].active };
}

pub fn windowId(_: *FakeHost, win: Window) u32 {
    return win.id;
}

pub fn exited(self: *FakeHost, pane: Pane) bool {
    return self.pane_states.get(pane.id).?.exited;
}

pub fn vars(self: *FakeHost, pane: Pane) commands.Vars {
    const wi = self.windowOfPane(pane.id).?;
    const w = &self.windows_list.items[wi];
    var l = self.computeLayout(wi) catch unreachable;
    defer l.deinit(self.alloc);
    var rect: geom.Rect = .{};
    var index: u32 = 0;
    for (l.leaves, 0..) |leaf, i| if (leaf.view.id == pane.id) {
        rect = leaf.rect;
        index = @intCast(i);
    };
    const st = self.pane_states.get(pane.id).?;
    return .{
        .pane_id = pane.id,
        .window_id = w.id,
        .window_index = @intCast(wi),
        .window_name = "main",
        .pane_index = index,
        .pane_active = w.active == pane.id,
        .pane_title = st.title,
        .pane_top = @intCast(@divTrunc(rect.y, @as(i32, cell_h))),
        .pane_left = @intCast(@divTrunc(rect.x, @as(i32, cell_w))),
        .pane_width = @intCast(@divTrunc(rect.w, @as(i32, cell_w))),
        .pane_height = @intCast(@divTrunc(rect.h, @as(i32, cell_h))),
        .pane_pid = st.pid,
        .pane_dead = st.exited,
        .pane_current_path = st.cwd,
    };
}

fn treeDirection(d: commands.Direction) Tree.Split.Direction {
    return switch (d) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
}

pub fn split(self: *FakeHost, pane: Pane, req: commands.SplitRequest) commands.SplitError!Pane {
    if (self.inject_split) |e| {
        self.inject_split = null;
        return e;
    }
    const wi = self.windowOfPane(pane.id).?;
    var l = try self.computeLayout(wi);
    defer l.deinit(self.alloc);
    var rect: geom.Rect = .{};
    for (l.leaves) |leaf| if (leaf.view.id == pane.id) {
        rect = leaf.rect;
    };
    const horizontal = req.direction == .right or req.direction == .left;
    const span: i32 = if (horizontal) rect.w else rect.h;
    const cell: u32 = if (horizontal) cell_w else cell_h;
    const new_first = req.direction == .left or req.direction == .up;
    const ratio = layout_mod.newPaneRatio(req.size, span - gap, cell, new_first) orelse return error.TooSmall;
    if (!layout_mod.fits(span, ratio, gap, @intCast(2 * cell))) return error.NoSpace;

    const id = try self.newPane(.split, req.spawn);
    errdefer {
        self.dropPaneState(id);
    }
    var view: View = .{ .id = id };
    var other = try Tree.init(self.alloc, &view);
    defer other.deinit();
    const w = &self.windows_list.items[wi];
    const at = leafHandle(&w.tree, pane.id).?;
    const next = try w.tree.split(self.alloc, at, treeDirection(req.direction), ratio, &other);
    w.tree.deinit();
    w.tree = next;
    if (req.focus) {
        w.active = id;
        self.focused = id;
    }
    return .{ .id = id };
}

fn dropPaneState(self: *FakeHost, id: u32) void {
    if (self.pane_states.fetchRemove(id)) |kv| {
        self.alloc.free(kv.value.title);
        self.alloc.free(kv.value.cwd);
    }
    self.opts.dropPane(self.alloc, id);
}

pub fn respawn(self: *FakeHost, pane: Pane, spawn: commands.Spawn) commands.RespawnError!void {
    if (self.inject_respawn) |e| {
        self.inject_respawn = null;
        return e;
    }
    try self.record(.respawn, pane.id, spawn);
    // The real host builds a new surface: one more id is used up.
    self.next_pane += 1;
    self.pane_states.getPtr(pane.id).?.exited = false;
}

pub fn kill(self: *FakeHost, pane: Pane) void {
    const wi = self.windowOfPane(pane.id) orelse return;
    const w = &self.windows_list.items[wi];
    const at = leafHandle(&w.tree, pane.id).?;
    const was_active = w.active == pane.id;
    if (at == .root) {
        const wid = w.id;
        w.tree.deinit();
        _ = self.windows_list.orderedRemove(wi);
        self.opts.dropWindow(self.alloc, wid);
        if (self.focused == pane.id) {
            self.focused = if (self.windows_list.items.len > 0) self.windows_list.items[0].active else 0;
        }
    } else {
        const next = w.tree.remove(self.alloc, at) catch return;
        w.tree.deinit();
        w.tree = next;
        if (was_active) {
            const l = self.computeLayout(wi) catch return;
            var lc = l;
            defer lc.deinit(self.alloc);
            w.active = lc.leaves[0].view.id;
            if (self.focused == pane.id) self.focused = w.active;
        }
    }
    self.dropPaneState(pane.id);
}

pub fn focus(self: *FakeHost, pane: Pane) void {
    const wi = self.windowOfPane(pane.id).?;
    self.windows_list.items[wi].active = pane.id;
    self.focused = pane.id;
}

pub fn setTitle(self: *FakeHost, pane: Pane, t: []const u8) !void {
    const st = self.pane_states.getPtr(pane.id).?;
    const copy = try self.alloc.dupe(u8, t);
    self.alloc.free(st.title);
    st.title = copy;
}

pub fn layout(self: *FakeHost, win: Window, which: commands.Layout) !void {
    const wi = self.windowIndex(win.id).?;
    const ids = try self.paneIds(self.alloc, wi);
    defer self.alloc.free(ids);
    const views = try self.alloc.alloc(View, ids.len);
    defer self.alloc.free(views);
    const ptrs = try self.alloc.alloc(*View, ids.len);
    defer self.alloc.free(ptrs);
    for (ids, views, ptrs) |id, *v, *p| {
        v.* = .{ .id = id };
        p.* = v;
    }
    var next = switch (which) {
        .main_vertical => try layout_mod.mainVertical(Tree, self.alloc, ptrs[0], ptrs[1..], commands.main_vertical_share),
        .tiled => try layout_mod.tiled(Tree, self.alloc, ptrs),
    };
    errdefer next.deinit();
    const w = &self.windows_list.items[wi];
    w.tree.deinit();
    w.tree = next;
}

pub fn resize(self: *FakeHost, pane: Pane, req: commands.ResizeRequest) !void {
    const wi = self.windowOfPane(pane.id).?;
    const w = &self.windows_list.items[wi];
    var l = try self.computeLayout(wi);
    defer l.deinit(self.alloc);
    const at = leafHandle(&w.tree, pane.id).?;
    const axes = [_]struct { size: ?@import("../../../tmux_shim/cli.zig").Size, lay: Tree.Split.Layout }{
        .{ .size = req.x, .lay = .horizontal },
        .{ .size = req.y, .lay = .vertical },
    };
    for (axes) |ax| {
        const size = ax.size orelse continue;
        const anc = layout_mod.ancestorSplit(Tree, &w.tree, at, ax.lay) orelse continue;
        var span: geom.Rect = .{};
        for (l.dividers) |d| if (d.split == anc.split) {
            span = d.span;
        };
        const horizontal = ax.lay == .horizontal;
        const window_px: i32 = if (horizontal) area.w else area.h;
        const span_px: i32 = (if (horizontal) span.w else span.h) - gap;
        const cell: u32 = if (horizontal) cell_w else cell_h;
        const ratio = layout_mod.ratioFor(size, window_px, span_px, cell, anc.pane_first) orelse continue;
        w.tree.resizeInPlace(anc.split, ratio);
    }
}

pub fn toggleZoom(self: *FakeHost, pane: Pane) void {
    const wi = self.windowOfPane(pane.id).?;
    const w = &self.windows_list.items[wi];
    self.zoom_toggles += 1;
    w.tree.zoom(if (w.tree.zoomed == null) leafHandle(&w.tree, pane.id) else null);
}

pub fn options(self: *FakeHost) *commands.Options {
    return &self.opts;
}

pub fn optionsChanged(self: *FakeHost, window_id: u32) void { // contract: only called with a window
    self.options_changed.append(self.alloc, window_id) catch {};
}

pub fn gpa(self: *FakeHost) Allocator {
    return self.alloc;
}

/// Test switch: `clipboard-write = deny`.
pub fn clipboardWriteAllowed(self: *FakeHost) bool {
    return !self.clipboard_denied;
}

pub fn setClipboard(self: *FakeHost, data: []const u8) !void {
    const copy = try self.alloc.dupe(u8, data);
    if (self.clipboard) |c| self.alloc.free(c);
    self.clipboard = copy;
}

pub fn sendKeys(
    self: *FakeHost,
    pane: Pane,
    keys_in: []const []const u8,
    literal: bool,
    hex: bool,
    repeat: u32,
) error{ UnknownKey, TooLarge, OutOfMemory }!void {
    _ = pane;
    if (self.keys_too_large) return error.TooLarge;
    const body = try std.mem.join(self.alloc, "|", keys_in);
    defer self.alloc.free(body);
    const joined = try std.fmt.allocPrint(self.alloc, "{s}{s}x{d}:{s}", .{
        if (literal) "l" else "",
        if (hex) "H" else "",
        repeat,
        body,
    });
    errdefer self.alloc.free(joined);
    try self.keys.append(self.alloc, joined);
}

pub fn capture(self: *FakeHost, pane: Pane, req: commands.CaptureRequest, w: *std.Io.Writer) !void {
    _ = self;
    _ = req;
    try w.print("screen of %{d}\n", .{pane.id});
}

/// Adds a second window with one pane; returns that pane's id.
pub fn addWindow(self: *FakeHost) !u32 {
    const id = try self.newPane(.initial, .{
        .command = null,
        .cwd = "C:\\work",
        .client_env = &.{},
        .extra_env = &.{},
        .start_dir = null,
    });
    var view: View = .{ .id = id };
    var t = try Tree.init(self.alloc, &view);
    errdefer t.deinit();
    try self.windows_list.append(self.alloc, .{ .id = self.next_window, .tree = t, .active = id });
    self.next_window += 1;
    return id;
}

// External mode (R-M5-14).

pub fn namespaces(self: *FakeHost) *ns_mod.Table {
    return &self.ns_table;
}

fn addOwnedWindow(self: *FakeHost, owner: u32, spawn: commands.Spawn) commands.SplitError!Pane {
    const id = try self.newPane(.initial, spawn);
    errdefer self.dropPaneState(id);
    var view: View = .{ .id = id };
    var t = try Tree.init(self.alloc, &view);
    errdefer t.deinit();
    try self.windows_list.append(self.alloc, .{ .id = self.next_window, .tree = t, .active = id, .owner = owner });
    self.next_window += 1;
    return .{ .id = id };
}

/// A new fake Ghostty window for the namespace, with one window (tab).
pub fn newSessionWindow(self: *FakeHost, ns: *ns_mod.Namespace, name: []const u8, spawn: commands.Spawn) commands.SplitError!Pane {
    _ = name;
    const owner = self.next_owner;
    const pane = try self.addOwnedWindow(owner, spawn);
    self.next_owner += 1;
    ns.window_id = owner;
    return pane;
}

/// A new window (tab) in the Ghostty window `owner`.
pub fn newTabIn(self: *FakeHost, owner: u32, name: []const u8, spawn: commands.Spawn, select: bool) commands.SplitError!Pane {
    _ = name;
    _ = select;
    return self.addOwnedWindow(owner, spawn);
}

/// Whether some fake window still belongs to the Ghostty window `window_id`.
pub fn ghosttyWindowAlive(self: *FakeHost, window_id: u32) bool {
    for (self.windows_list.items) |w| if (w.owner == window_id) return true;
    return false;
}

/// The fake Ghostty window that shows the tab.
pub fn ghosttyWindowOf(self: *FakeHost, win: Window) u32 {
    return self.windows_list.items[self.windowIndex(win.id).?].owner;
}

/// Closes the namespace's tabs, no questions asked (by tab, not by window:
/// a torn-out tab is still the client's).
pub fn closeNamespace(self: *FakeHost, ns: *ns_mod.Namespace) void {
    for (ns.tabs.items) |t| {
        const wi = self.windowIndex(t.id) orelse continue;
        const ids = self.paneIds(self.alloc, wi) catch &[_]u32{};
        defer if (ids.len > 0) self.alloc.free(ids);
        const w = &self.windows_list.items[wi];
        w.tree.deinit();
        _ = self.windows_list.orderedRemove(wi);
        self.opts.dropWindow(self.alloc, t.id);
        for (ids) |p| {
            if (self.focused == p) self.focused = 0;
            self.dropPaneState(p);
        }
    }
}
