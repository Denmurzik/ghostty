//! The real tmux host: tmux panes are Ghostty surfaces (`%N` = `Surface.pane_id`),
//! tmux windows are Ghostty tabs (`@N` = `Tab.id`). `run` executes one request
//! of the tmux pipe on the UI thread through `commands.execute`
//! (owner: M4 task 12).
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const cli = @import("../../../tmux_shim/cli.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");
const SplitLayout = @import("../SplitLayout.zig");
const clipboard = @import("../clipboard.zig");
const secure_input = @import("../secure_input.zig");
const geom = @import("../geom.zig");
const protocol = @import("../ipc/protocol.zig");
const commands = @import("commands.zig");
const keys = @import("keys.zig");
const labels = @import("labels.zig");
const layout = @import("layout.zig");
const pane_io = @import("pane_io.zig");
const spawn = @import("spawn.zig");

const log = std.log.scoped(.win32_tmux_registry);

/// `App.tmux`.
pub const State = struct {
    /// Must keep its address from `labels.attachOptions` to `detachOptions`.
    options: commands.Options = .{},
    /// pane -> exit code of a pane whose process ended and that stays.
    exited: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// Panes created by the shim: only these obey `remain-on-exit`.
    shim_panes: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The next pane number. Like tmux's: it only goes up, and a respawn
    /// keeps its pane's number without taking one.
    next_pane: u32 = 1,

    pub fn takePane(self: *State) u32 {
        const n = self.next_pane;
        self.next_pane +%= 1;
        return n;
    }
};

pub const Reply = struct {
    code: protocol.Code,
    stdout: []const u8,
    stderr: []const u8,
};

/// Options are never evicted by tmux commands; this bounds every map (the
/// client controls names and values; the leader pane and its window live as
/// long as Ghostty). Values are capped by `commands.max_option_value`.
pub const max_options_per_map = 256;

// ---- pure decisions --------------------------------------------------

pub const ExitAction = enum { close, keep, core };

/// What a pane whose process ended does. Panes the shim did not create
/// behave as before (`core`).
pub fn exitAction(remain: commands.Options.RemainOnExit, exit_code: i32, shim_pane: bool) ExitAction {
    if (!shim_pane) return .core;
    return switch (remain) {
        .off => .close,
        .on => .keep,
        .failed => if (exit_code != 0) .keep else .close,
    };
}

/// `%N` of `TMUX_PANE`.
pub fn parseCaller(pane: []const u8) ?u32 {
    if (pane.len < 2 or pane[0] != '%') return null;
    return std.fmt.parseInt(u32, pane[1..], 10) catch null;
}

/// A pane went away. Its options go with it, unless another live surface
/// holds the same pane id (a respawn builds the new surface first).
pub fn paneGone(opts: *commands.Options, gpa: Allocator, pane_id: u32, other_alive: bool) void {
    if (other_alive) return;
    opts.dropPane(gpa, pane_id);
}

fn capMap(map: *commands.Map, gpa: Allocator) void {
    while (map.count() > max_options_per_map) {
        const kv = map.fetchOrderedRemove(map.keys()[0]) orelse return;
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
}

/// Drops the oldest options beyond `max_options_per_map` in the global, every
/// window and every pane map.
pub fn capOptions(opts: *commands.Options, gpa: Allocator) void {
    capMap(&opts.global, gpa);
    var wit = opts.windows.valueIterator();
    while (wit.next()) |m| capMap(m, gpa);
    var pit = opts.panes.valueIterator();
    while (pit.next()) |m| capMap(m, gpa);
}

pub const Cells = struct { top: u32, left: u32, width: u32, height: u32 };

/// A pane rectangle in cells.
pub fn cellsOf(rect: geom.Rect, cell_w: u32, cell_h: u32) Cells {
    const cw: i32 = @intCast(@max(cell_w, 1));
    const ch: i32 = @intCast(@max(cell_h, 1));
    return .{
        .top = @intCast(@max(@divTrunc(rect.y, ch), 0)),
        .left = @intCast(@max(@divTrunc(rect.x, cw), 0)),
        .width = @intCast(@max(@divTrunc(rect.w, cw), 0)),
        .height = @intCast(@max(@divTrunc(rect.h, ch), 0)),
    };
}

/// The split ratio of the existing pane for a new pane of `size` in a pane
/// of `span` px; `TooSmall` for an invalid size, `NoSpace` when a side would
/// be below two cells.
pub fn splitRatio(
    span: i32,
    size: ?cli.Size,
    gap: i32,
    cell: u32,
    new_first: bool,
) error{ TooSmall, NoSpace }!f16 {
    const ratio = layout.newPaneRatio(size, span - gap, cell, new_first) orelse return error.TooSmall;
    if (!layout.fits(span, ratio, gap, @intCast(2 * cell))) return error.NoSpace;
    return ratio;
}

// ---- lookups -----------------------------------------------------------

fn surfaceOf(app: *App, pane_id: u32) ?*Surface {
    for (app.windows.items) |w| {
        for (w.tabs.items) |t| {
            var it = t.tree.iterator();
            while (it.next()) |e| {
                if (e.view.pane_id == pane_id) return e.view;
            }
        }
    }
    return null;
}

fn tabOf(app: *App, tab_id: u32) ?*Tab {
    for (app.windows.items) |w| {
        for (w.tabs.items) |t| {
            if (t.id == tab_id) return t;
        }
    }
    return null;
}

fn cellOf(s: *const Surface) struct { w: u32, h: u32 } {
    if (!s.initialized) return .{ .w = 1, .h = 1 };
    const c = s.core_surface.size.cell;
    return .{ .w = @max(c.width, 1), .h = @max(c.height, 1) };
}

// ---- the host ----------------------------------------------------------

pub const Host = struct {
    pub const Pane = struct { id: u32 };
    pub const Window = struct { id: u32 };

    app: *App,
    arena: Allocator,
    caller: ?u32,
    /// The caller's own pane, to close once the reply is out.
    deferred_close: ?u32 = null,
    /// The directory a NoDirectory error names (read by commands.zig).
    failed_dir: []const u8 = "",

    fn state(self: *Host) *State {
        return &self.app.tmux;
    }

    pub fn findPane(self: *Host, id: u32) ?Pane {
        return if (surfaceOf(self.app, id) != null) .{ .id = id } else null;
    }

    pub fn findWindow(self: *Host, id: u32) ?Window {
        return if (tabOf(self.app, id) != null) .{ .id = id } else null;
    }

    pub fn fallbackPane(self: *Host) ?Pane {
        if (self.app.last_active) |w| {
            if (w.activeTab()) |t| if (t.focusedSurface()) |s| return .{ .id = s.pane_id };
        }
        for (self.app.windows.items) |w| {
            if (w.activeTab()) |t| if (t.focusedSurface()) |s| return .{ .id = s.pane_id };
        }
        return null;
    }

    pub fn windowOf(self: *Host, pane: Pane) Window {
        const s = surfaceOf(self.app, pane.id) orelse return .{ .id = 0 };
        return .{ .id = s.tab.id };
    }

    pub fn windows(self: *Host, alloc: Allocator) Allocator.Error![]Window {
        var out: std.ArrayList(Window) = .empty;
        for (self.app.windows.items) |w| {
            for (w.tabs.items) |t| try out.append(alloc, .{ .id = t.id });
        }
        return out.items;
    }

    pub fn panes(self: *Host, alloc: Allocator, win: Window) Allocator.Error![]Pane {
        const tab = tabOf(self.app, win.id) orelse return &.{};
        var rects = try tab.leafRects(self.app.core_app.alloc);
        defer rects.deinit(self.app.core_app.alloc);
        const out = try alloc.alloc(Pane, rects.leaves.len);
        for (rects.leaves, out) |leaf, *o| o.* = .{ .id = leaf.view.pane_id };
        return out;
    }

    pub fn activePane(self: *Host, win: Window) Pane {
        const tab = tabOf(self.app, win.id) orelse return .{ .id = 0 };
        const s = tab.focusedSurface() orelse return .{ .id = 0 };
        return .{ .id = s.pane_id };
    }

    pub fn windowId(_: *Host, win: Window) u32 {
        return win.id;
    }

    pub fn exited(self: *Host, pane: Pane) bool {
        if (self.state().exited.contains(pane.id)) return true;
        const s = surfaceOf(self.app, pane.id) orelse return true;
        return s.core_surface.child_exited;
    }

    pub fn vars(self: *Host, pane: Pane) commands.Vars {
        const s = surfaceOf(self.app, pane.id) orelse return std.mem.zeroInit(commands.Vars, .{
            .pane_id = pane.id,
            .window_name = "",
            .pane_title = "",
            .pane_current_path = "",
        });
        const tab = s.tab;
        const alloc = self.app.core_app.alloc;
        var rect: geom.Rect = .{};
        var index: u32 = 0;
        if (tab.leafRects(alloc)) |r| {
            var rects = r;
            defer rects.deinit(alloc);
            for (rects.leaves, 0..) |leaf, i| {
                if (leaf.view == s) {
                    rect = leaf.rect;
                    index = @intCast(i);
                }
            }
        } else |_| {}
        const cell = cellOf(s);
        const cells = cellsOf(rect, cell.w, cell.h);
        return .{
            .pane_id = pane.id,
            .window_id = tab.id,
            .window_index = @intCast(tab.window.tabIndex(tab) orelse 0),
            .window_name = tab.title(),
            .pane_index = index,
            .pane_active = tab.focusedSurface() == s,
            .pane_title = s.getTitle() orelse "",
            .pane_top = cells.top,
            .pane_left = cells.left,
            .pane_width = cells.width,
            .pane_height = cells.height,
            // Not exposed by the pty yet; Claude Code never reads #{pane_pid}
            // (its lifecycle is not polled through tmux).
            .pane_pid = 0,
            .pane_dead = self.exited(pane),
            .pane_current_path = s.pwd orelse "",
        };
    }

    fn treeDirection(d: commands.Direction) Surface.Tree.Split.Direction {
        return switch (d) {
            .right => .right,
            .down => .down,
            .left => .left,
            .up => .up,
        };
    }

    fn planOf(self: *Host, s: commands.Spawn) error{ Unsupported, NoDirectory, OutOfMemory }!spawn.Plan {
        const exe_dir = self.app.tmux_server.exe_dir orelse "";
        var diag: spawn.Diag = .{};
        return spawn.plan(self.arena, s, exe_dir, spawn.systemProbe(), &diag) catch |err| {
            if (err == error.NoDirectory) self.failed_dir = diag.dir;
            return err;
        };
    }

    pub fn split(self: *Host, pane: Pane, req: commands.SplitRequest) commands.SplitError!Pane {
        const s = surfaceOf(self.app, pane.id) orelse return error.SpawnFailed;
        const tab = s.tab;
        const alloc = self.app.core_app.alloc;

        var rects = try tab.leafRects(alloc);
        defer rects.deinit(alloc);
        const leaf = rects.leafFor(s) orelse return error.NoSpace;
        const horizontal = req.direction == .right or req.direction == .left;
        const new_first = req.direction == .left or req.direction == .up;
        const cell = cellOf(s);
        const span = if (horizontal) leaf.rect.w else leaf.rect.h;
        const ratio = try splitRatio(
            span,
            req.size,
            SplitLayout.gapPx(tab.window.dpi),
            if (horizontal) cell.w else cell.h,
            new_first,
        );

        var plan = try self.planOf(req.spawn);
        const created = tab.splitWith(s, treeDirection(req.direction), .{
            .ratio = ratio,
            .focus = req.focus,
            .tmux = &plan,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        self.state().shim_panes.put(alloc, created.pane_id, {}) catch {};
        labels.optionsChanged(self.app, tab.id);
        return .{ .id = created.pane_id };
    }

    pub fn respawn(self: *Host, pane: Pane, req: commands.Spawn) commands.RespawnError!void {
        const s = surfaceOf(self.app, pane.id) orelse return error.SpawnFailed;
        const tab = s.tab;
        var plan = try self.planOf(req);
        // The pinned title (select-pane -T) survives; the old surface is gone after.
        const title: ?[]const u8 = if (s.title_user) |t| try self.arena.dupe(u8, t) else null;
        const created = tab.replaceSurface(s, &plan) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        const st = self.state();
        _ = st.exited.remove(pane.id);
        st.shim_panes.put(self.app.core_app.alloc, pane.id, {}) catch {};
        if (title) |t| created.setUserTitle(t) catch {};
        labels.optionsChanged(self.app, tab.id);
    }

    pub fn kill(self: *Host, pane: Pane) void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        // The reply of the caller's own pane must go out before its process dies.
        if (self.caller == pane.id) {
            self.deferred_close = pane.id;
            return;
        }
        s.tab.removeSurface(s);
    }

    pub fn focus(self: *Host, pane: Pane) void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        const tab = s.tab;
        tab.focused = s;
        if (tab.window.activeTab() == tab) tab.focus();
        labels.optionsChanged(self.app, tab.id);
    }

    pub fn setTitle(self: *Host, pane: Pane, t: []const u8) !void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        try s.setUserTitle(t);
    }

    pub fn layout(self: *Host, win: Window, which: commands.Layout) !void {
        const tab = tabOf(self.app, win.id) orelse return;
        const alloc = self.app.core_app.alloc;
        var rects = try tab.leafRects(alloc);
        defer rects.deinit(alloc);
        if (rects.leaves.len == 0) return;
        const views = try self.arena.alloc(*Surface, rects.leaves.len);
        for (rects.leaves, views) |leaf, *v| v.* = leaf.view;
        const next = switch (which) {
            .main_vertical => try layout_mod.mainVertical(Surface.Tree, alloc, views[0], views[1..], commands.main_vertical_share),
            .tiled => try layout_mod.tiled(Surface.Tree, alloc, views),
        };
        tab.replaceTree(next);
        labels.optionsChanged(self.app, tab.id);
    }

    pub fn resize(self: *Host, pane: Pane, req: commands.ResizeRequest) !void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        const tab = s.tab;
        const alloc = self.app.core_app.alloc;
        var rects = try tab.leafRects(alloc);
        defer rects.deinit(alloc);
        const at = tab.handleOf(s) orelse return;
        const cell = cellOf(s);
        const gap = SplitLayout.gapPx(tab.window.dpi);
        const axes = [_]struct { size: ?cli.Size, lay: Surface.Tree.Split.Layout }{
            .{ .size = req.x, .lay = .horizontal },
            .{ .size = req.y, .lay = .vertical },
        };
        for (axes) |ax| {
            const size = ax.size orelse continue;
            const anc = layout_mod.ancestorSplit(Surface.Tree, &tab.tree, at, ax.lay) orelse continue;
            var span: geom.Rect = .{};
            for (rects.dividers) |d| {
                if (d.split == anc.split) span = d.span;
            }
            const horizontal = ax.lay == .horizontal;
            const window_px: i32 = if (horizontal) tab.last_content.w else tab.last_content.h;
            const span_px: i32 = (if (horizontal) span.w else span.h) - gap;
            const ratio = layout_mod.ratioFor(size, window_px, span_px, if (horizontal) cell.w else cell.h, anc.pane_first) orelse continue;
            tab.tree.resizeInPlace(anc.split, ratio);
        }
        tab.layout();
    }

    pub fn toggleZoom(self: *Host, pane: Pane) void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        const tab = s.tab;
        const handle = tab.handleOf(s) orelse return;
        tab.tree.zoom(if (tab.tree.zoomed == handle) null else handle);
        tab.layout();
    }

    pub fn options(self: *Host) *commands.Options {
        return &self.state().options;
    }

    pub fn optionsChanged(self: *Host, window_id: u32) void {
        labels.optionsChanged(self.app, window_id);
    }

    pub fn gpa(self: *Host) Allocator {
        return self.app.core_app.alloc;
    }

    /// `clipboard-write` is not `deny`; `ask` counts as allowed.
    pub fn clipboardWriteAllowed(self: *Host) bool {
        return self.app.config.@"clipboard-write" != .deny;
    }

    pub fn setClipboard(self: *Host, data: []const u8) !void {
        try clipboard.write(self.app.msg_hwnd, data, secure_input.copying(self.app));
    }

    pub fn sendKeys(
        self: *Host,
        pane: Pane,
        keys_in: []const []const u8,
        literal: bool,
        hex: bool,
        repeat: u32,
    ) error{ UnknownKey, TooLarge, OutOfMemory }!void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        const bytes = try keys.encode(self.arena, keys_in, literal, hex, repeat);
        pane_io.sendKeys(self.app, s, bytes) catch |err| return if (err == error.QueueFull) error.TooLarge else error.OutOfMemory;
    }

    pub fn capture(self: *Host, pane: Pane, req: commands.CaptureRequest, w: *std.Io.Writer) !void {
        const s = surfaceOf(self.app, pane.id) orelse return;
        try pane_io.capture(s, req, w);
    }
};

const layout_mod = layout;

/// Runs one request of the tmux pipe on the UI thread. All allocations of the
/// reply come from `arena`.
pub fn run(app: *App, req: protocol.Request, arena: Allocator) Reply {
    // The labels read the options; attached once, detached by `appStopping`.
    if (app.tmux_labels.options == null) labels.attachOptions(app, &app.tmux.options);
    app.tmux_keys.used = true;

    var host: Host = .{ .app = app, .arena = arena, .caller = parseCaller(req.pane) };
    var out: commands.Output = .{};
    commands.execute(Host, &host, arena, req.args, .{
        .caller_pane = host.caller,
        .cwd = req.cwd,
        .env = req.env,
        .stdin = req.stdin,
        .now_ms = win32.kernel32.GetTickCount64(),
        .deadline_ms = if (req.deadline_ms == 0) std.math.maxInt(u64) else req.deadline_ms,
    }, &out) catch {
        return .{ .code = .failed, .stdout = "", .stderr = "ghostty: out of memory\n" };
    };
    capOptions(&app.tmux.options, app.core_app.alloc);

    if (host.deferred_close) |id| {
        if (surfaceOf(app, id)) |s| s.close(false);
    }
    return .{
        .code = if (out.code == 0) .ok else .failed,
        .stdout = out.stdout.items,
        .stderr = out.stderr.items,
    };
}

// ---- lifecycle hooks -----------------------------------------------------

pub fn surfaceDestroying(surface: *Surface) void {
    const app = surface.app;
    const st = &app.tmux;
    const alloc = app.core_app.alloc;
    const pane_id = surface.pane_id;

    var other_alive = false;
    var tab_has_others = false;
    for (app.windows.items) |w| {
        for (w.tabs.items) |t| {
            var it = t.tree.iterator();
            while (it.next()) |e| {
                if (e.view == surface) continue;
                if (e.view.pane_id == pane_id) other_alive = true;
                if (t == surface.tab) tab_has_others = true;
            }
        }
    }
    paneGone(&st.options, alloc, pane_id, other_alive);
    if (!other_alive) {
        _ = st.exited.remove(pane_id);
        _ = st.shim_panes.remove(pane_id);
    }
    if (!tab_has_others) st.options.dropWindow(alloc, surface.tab.id);
}

/// `show_child_exited`: true when the pane was closed here, false to let
/// core show its message (and keep the pane when wait-after-command is on).
pub fn childExited(surface: *Surface, info: apprt.surface.Message.ChildExited) bool {
    const app = surface.app;
    const st = &app.tmux;
    const code: i32 = @bitCast(info.exit_code);
    const shim = st.shim_panes.contains(surface.pane_id);
    const remain = st.options.remainOnExit(surface.pane_id, surface.tab.id);
    switch (exitAction(remain, code, shim)) {
        .close => {
            surface.close(false);
            return true;
        },
        .keep => {
            st.exited.put(app.core_app.alloc, surface.pane_id, code) catch {};
            return false;
        },
        .core => return false,
    }
}

pub fn appStopping(app: *App) void {
    const alloc = app.core_app.alloc;
    labels.detachOptions(app);
    const st = &app.tmux;
    st.options.deinit(alloc);
    st.exited.deinit(alloc);
    st.exited = .empty;
    st.shim_panes.deinit(alloc);
    st.shim_panes = .empty;
}

// ---- tests -----------------------------------------------------------

test "win32 tmux registry: childExited decision table" {
    const t = std.testing;
    // Panes the shim did not create are core's.
    try t.expectEqual(ExitAction.core, exitAction(.off, 0, false));
    try t.expectEqual(ExitAction.core, exitAction(.on, 1, false));
    // remain-on-exit off: always close.
    try t.expectEqual(ExitAction.close, exitAction(.off, 0, true));
    try t.expectEqual(ExitAction.close, exitAction(.off, 3, true));
    // on: always keep.
    try t.expectEqual(ExitAction.keep, exitAction(.on, 0, true));
    try t.expectEqual(ExitAction.keep, exitAction(.on, 3, true));
    // failed: keep only a failure.
    try t.expectEqual(ExitAction.close, exitAction(.failed, 0, true));
    try t.expectEqual(ExitAction.keep, exitAction(.failed, 3, true));
    try t.expectEqual(ExitAction.keep, exitAction(.failed, -1, true));
}

test "win32 tmux registry: options survive respawn and drop on kill" {
    const gpa = std.testing.allocator;
    var opts: commands.Options = .{};
    defer opts.deinit(gpa);
    try opts.set(gpa, .{ .pane = 5 }, "pane-border-style", "fg=red");
    try opts.set(gpa, .{ .window = 1 }, "pane-border-status", "top");

    // Respawn: the new surface is alive when the old one goes.
    paneGone(&opts, gpa, 5, true);
    try std.testing.expectEqualStrings("fg=red", opts.panes.get(5).?.get("pane-border-style").?);
    // Kill: nobody holds the id.
    paneGone(&opts, gpa, 5, false);
    try std.testing.expect(opts.panes.get(5) == null);
    // Window options are not touched by a pane.
    try std.testing.expect(opts.windows.get(1) != null);
}

test "win32 tmux registry: option maps are capped" {
    const gpa = std.testing.allocator;
    var opts: commands.Options = .{};
    defer opts.deinit(gpa);
    var buf: [16]u8 = undefined;
    for (0..max_options_per_map + 10) |i| {
        const name = try std.fmt.bufPrint(&buf, "opt{d}", .{i});
        try opts.set(gpa, .global, name, "v");
        try opts.set(gpa, .{ .pane = 1 }, name, "v");
        try opts.set(gpa, .{ .window = 1 }, name, "v");
    }
    capOptions(&opts, gpa);
    try std.testing.expectEqual(@as(usize, max_options_per_map), opts.global.count());
    try std.testing.expectEqual(@as(usize, max_options_per_map), opts.panes.get(1).?.count());
    try std.testing.expectEqual(@as(usize, max_options_per_map), opts.windows.get(1).?.count());
    // The oldest went.
    try std.testing.expect(opts.global.get("opt0") == null);
    try std.testing.expect(opts.panes.get(1).?.get("opt0") == null);
    try std.testing.expect(opts.global.get("opt265") != null);
}

test "win32 tmux registry: caller pane from request" {
    try std.testing.expectEqual(@as(?u32, 3), parseCaller("%3"));
    try std.testing.expectEqual(@as(?u32, 12), parseCaller("%12"));
    try std.testing.expectEqual(@as(?u32, null), parseCaller(""));
    try std.testing.expectEqual(@as(?u32, null), parseCaller("3"));
    try std.testing.expectEqual(@as(?u32, null), parseCaller("%"));
    try std.testing.expectEqual(@as(?u32, null), parseCaller("%x"));
    try std.testing.expectEqual(@as(?u32, null), parseCaller("%-1"));
    try std.testing.expectEqual(@as(?u32, null), parseCaller("%1 "));
}

test "win32 tmux registry: cells and split ratio from a leaf rectangle" {
    // The rectangle comes from leafRects over the stored content area, so a
    // minimized window still has non-zero cells.
    const rect: geom.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const cells = cellsOf(rect, 10, 20);
    try std.testing.expectEqual(@as(u32, 80), cells.width);
    try std.testing.expectEqual(@as(u32, 30), cells.height);
    try std.testing.expectEqual(@as(u32, 0), cells.top);
    const right: geom.Rect = .{ .x = 410, .y = 100, .w = 390, .h = 500 };
    const rc = cellsOf(right, 10, 20);
    try std.testing.expectEqual(@as(u32, 41), rc.left);
    try std.testing.expectEqual(@as(u32, 5), rc.top);
    try std.testing.expectEqual(@as(u32, 39), rc.width);

    // fits: an even split of 800 px, a 30% request, a too-small one.
    try std.testing.expectEqual(@as(f16, 0.5), try splitRatio(800, null, 4, 10, false));
    _ = try splitRatio(800, .{ .percent = 30 }, 4, 10, false);
    try std.testing.expectError(error.NoSpace, splitRatio(30, null, 4, 10, false));
    try std.testing.expectError(error.TooSmall, splitRatio(800, .{ .cells = 0 }, 4, 10, false));
}

test "win32 tmux registry: pane numbers only go up" {
    var st: State = .{};
    // The leader, a split, (a respawn of the split takes none), another split.
    try std.testing.expectEqual(@as(u32, 1), st.takePane());
    try std.testing.expectEqual(@as(u32, 2), st.takePane());
    try std.testing.expectEqual(@as(u32, 3), st.takePane());
    // A pane that went away does not give its number back.
    try std.testing.expectEqual(@as(u32, 4), st.takePane());
    try std.testing.expectEqual(@as(u32, 5), st.next_pane);
}
