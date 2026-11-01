//! One tab of a `Window`: a container child window holding a split tree of
//! surfaces. Heap allocated so its address is stable; the container's
//! GWLP_USERDATA points back at it. Destroy order follows SPEC section 6.4:
//! surfaces before their container, containers before the top-level window.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const Overrides = @import("Overrides.zig");
const SplitLayout = @import("SplitLayout.zig");
const Chrome = @import("Chrome.zig");
const split_drag = @import("split_drag.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const hooks_mod = @import("hooks.zig");
const title_edit = @import("title_edit.zig");
const title_rules = @import("title_rules.zig");
const util = @import("util.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");
const recovery = @import("recovery.zig");
const composition = @import("composition.zig");
const messages = @import("messages.zig");
const taskbar = @import("taskbar.zig");
const tmux_spawn = @import("tmux/spawn.zig");
const renderer = @import("../../renderer.zig");
const undo_actions = @import("actions/undo_actions.zig");
const Inspector = @import("inspector/Inspector.zig");

const log = std.log.scoped(.win32_tab);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTab");

pub const CreateOptions = struct {
    parent: ?*CoreSurface = null,
    overrides: Overrides = .none,
    context: apprt.surface.NewSurfaceContext = .tab,
    /// A tmux pane: the first surface runs this plan instead of the shell.
    tmux: ?*const tmux_spawn.Plan = null,
};

/// Source of `id`, for log correlation only.
var next_id: std.atomic.Value(u32) = .init(1);

window: *Window,
hwnd: win32.foundation.HWND,
tree: Surface.Tree,

/// Pane rectangles of `tree` as last applied to the child windows; the
/// reference for which leaves changed visibility. Pointers in it are only
/// compared, never dereferenced.
split_layout: ?SplitLayout.Layout(Surface.Tree) = null,

/// The content rectangle of the last layout that had room. While the window
/// is minimized nothing is laid out and `split_layout` is gone; `leafRects`
/// computes the pane rectangles from this.
last_content: geom.Rect = .{},

/// The surface that has (or last had) keyboard focus. Not a reference: it
/// is only trusted while it is still in `tree` (see `focusedSurface`).
focused: ?*Surface,

/// A title set by the user; wins over the surface titles.
title_override: ?[:0]u8,
id: u32,

/// Whether the container HWND was already taken down with its parent.
hwnd_destroyed: bool = false,

/// Closed by the user and kept by the close-undo (`Window.parked_tabs`).
parked: bool = false,

/// The container was selected since it was created, unparked or moved to
/// another window: `Window.selectTabFocus` shows it again without waiting
/// a DWM frame under the old tab.
shown_before: bool = false,

/// The divider being dragged, while the left button is held.
drag: ?Drag = null,

/// Brush of the divider fill and the colour it was made for.
divider_brush: ?win32.user32.HBRUSH = null,
divider_ref: u32 = 0,

const Drag = struct {
    split: Surface.Tree.Node.Handle,
    kind: DragKind,
    /// The whole rectangle of the split, for the ratio computation.
    span: geom.Rect,
    /// Cursor position minus divider centre at the press, along the axis.
    grab_offset: i32,
    /// Whether the throttled relayout timer is running.
    timer_armed: bool = false,
};

pub const DragKind = enum { horizontal, vertical };

/// Smallest size of either side of a dragged divider: two cells of the
/// axis (`cell` is one grid cell), at least 16 px.
pub fn dragMinPx(cell: apprt.action.CellSize, kind: DragKind) i32 {
    const c: u32 = if (kind == .horizontal) cell.width else cell.height;
    return @max(@as(i32, @intCast(@min(c, 1 << 20))) * 2, 16);
}

/// Throttle of the relayout while a divider is dragged.
const drag_interval_ms = 16;

/// Create the container and its first surface. The tab is not part of the
/// window's tab list yet; `Window.addTab` appends it.
pub fn create(window: *Window, opts: CreateOptions) !*Tab {
    const self = try createContainer(window);
    errdefer self.discardContainer();

    // Core's start-up actions (initial size, title, ...) reach the window
    // through the surface's `tab`, which `Surface.create` sets before init.
    const surface = try Surface.create(self, .{
        .parent = opts.parent,
        .overrides = opts.overrides,
        .context = opts.context,
        .tmux = opts.tmux,
    });
    errdefer surface.destroy();

    self.tree = try Surface.Tree.init(window.app.core_app.alloc, surface);
    self.focused = surface;

    // Core's start-up actions (`initial_size`) resize the window while the
    // surface is still initializing, and the resulting child WM_SIZE never
    // reaches core: bring core up to date now.
    self.layout();
    surface.applySize(surface.size.load(.acquire));

    return self;
}

/// A new tab in `window` holding only `s`, a surface of another tab: no new
/// surface, no new process. The tab is not part of the window's tab list yet
/// (like `create`), and `s` is still a child of its old container: the caller
/// inserts the tab and then calls `adopt` to complete the move. Nothing is
/// laid out here.
pub fn createAdopting(window: *Window, s: *Surface) !*Tab {
    const self = try createContainer(window);
    errdefer self.discardContainer();
    self.tree = try Surface.Tree.init(window.app.core_app.alloc, s);
    self.focused = s;
    return self;
}

/// The container window and the empty tab around it.
fn createContainer(window: *Window) !*Tab {
    const app = window.app;
    const alloc = app.core_app.alloc;

    try util.registerClass(&.{
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .hCursor = win32.user32.LoadCursorW(null, win32.user32.IDC_ARROW),
        .lpszClassName = class_name,
    });

    const self = try alloc.create(Tab);
    errdefer alloc.destroy(self);
    self.* = .{
        .window = window,
        .hwnd = undefined,
        .tree = .empty,
        .focused = null,
        .title_override = null,
        .id = next_id.fetchAdd(1, .monotonic),
    };

    const rect = window.contentRect();

    // The window procedure sees WM_NCCREATE before this returns and stores
    // `self` as the window's user data.
    const hwnd = win32.user32.CreateWindowExW(
        0,
        class_name,
        null,
        win32.user32.WS_CHILD | win32.user32.WS_CLIPCHILDREN | win32.user32.WS_CLIPSIBLINGS,
        rect.x,
        rect.y,
        @max(rect.w, 0),
        @max(rect.h, 0),
        window.hwnd,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    self.hwnd = hwnd;
    return self;
}

/// Undo `createContainer` after a failure: the tree holds no surface.
fn discardContainer(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    self.tree.deinit();
    _ = win32.user32.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// Ask the renderer thread of every surface to quit without waiting.
pub fn stopRenderThreads(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        if (s.initialized) s.core_surface.stopRenderThread();
    }
}

/// Then, once the renderer threads are on their way out, ask the IO thread
/// of every surface to quit. Together the two make the waits in `destroy`
/// overlap instead of adding up.
pub fn stopIoThreads(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        if (s.initialized) s.core_surface.stopIoThread();
    }
}

/// Destroy the tab and free it. Joins the core threads of every surface.
pub fn destroy(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    // Entries about the tab go first: their snapshots hold surfaces whose
    // teardown still reads this tab and its window.
    _ = undo_actions.forgetTab(self.window.app, self);
    self.stopRenderThreads();
    self.stopIoThreads();

    // Hidden first: joining the threads of many surfaces takes a moment,
    // and the panes should not sit frozen on screen meanwhile.
    _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_HIDE);

    // Every surface goes first: core teardown still reads `window`. The
    // tree and its layout are taken out of the tab, and after each surface
    // the thread answers what other threads have sent it meanwhile; those
    // messages may reach this tab. The surfaces are held by `held` while
    // the tree lets go of them, then released one by one.
    var tree = self.tree;
    self.tree = .empty;
    self.focused = null;
    if (self.split_layout) |*l| l.deinit(alloc);
    self.split_layout = null;

    var held: std.ArrayList(*Surface) = .empty;
    defer held.deinit(alloc);
    var it = tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view.ref(alloc) catch continue;
        held.append(alloc, s) catch {
            s.refs -= 1;
        };
    }
    tree.deinit();
    for (held.items) |s| {
        s.unref(alloc);
        util.serviceSentMessages();
    }

    if (!self.hwnd_destroyed) _ = win32.user32.DestroyWindow(self.hwnd);
    if (self.title_override) |t| alloc.free(t);
    alloc.destroy(self);
}

/// The focused surface if it is still in the tree, else the first leaf.
pub fn focusedSurface(self: *const Tab) ?*Surface {
    if (self.focused) |f| {
        if (self.tree.locate(f) != null) return f;
    }
    var it = self.tree.iterator();
    const first = it.next() orelse return null;
    return first.view;
}

/// Whether `SetFocus` may run for a tab of the window `own`: it activates
/// the top-level of its target, so a background window must not take it
/// (a shell exiting there would steal the activation). Activation forwards
/// focus to the active tab through `WM_SETFOCUS` anyway.
fn mayTakeFocus(active: ?win32.foundation.HWND, own: win32.foundation.HWND) bool {
    return active == own;
}

/// Give keyboard focus to the focused surface.
pub fn focus(self: *Tab) void {
    const s = self.focusedSurface() orelse return;
    if (!mayTakeFocus(win32.user32.GetActiveWindow(), self.window.hwnd)) return;
    _ = win32.user32.SetFocus(s.hwnd);
}

/// Core must not see a parked surface as the focused one.
pub fn parkSurfaces(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| parkOne(entry.view);
}

fn parkOne(s: *Surface) void {
    if (s.initialized) {
        s.core_surface.focusCallback(false) catch |err|
            log.warn("focus callback failed err={}", .{err});
        const core_app = s.app.core_app;
        if (core_app.focused_surface == &s.core_surface) core_app.focused_surface = null;
    }
    // Nothing is drawn for a surface nobody sees; the show path re-applies it.
    if (s.initialized) s.core_surface.occlusionCallback(false) catch |err|
        log.warn("occlusion callback failed err={}", .{err});
    Inspector.parkSync(s);
    taskbar.surfaceParked(s.window, s.id);
}

/// Hide the tab for the close-undo; its shells keep running.
pub fn park(self: *Tab) void {
    self.parked = true;
    self.parkSurfaces();
    self.setVisible(false);
}

pub fn unpark(self: *Tab) void {
    self.parked = false;
    self.shown_before = false;
    self.restoreProgress();
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        Inspector.parkSync(entry.view);
        // The window may have changed monitor while the tab was parked.
        entry.view.applyDpi();
    }
}

/// The progress reports the closes of a parked tab took off the taskbar.
pub fn restoreProgress(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| taskbar.surfaceRestored(self.window, entry.view.id);
}

/// The tree of the tab before and after a split was taken out.
pub const SplitSnapshot = struct { before: Surface.Tree, after: Surface.Tree };

/// Takes the split `s` out of the tab without closing it: the surface stays
/// alive (the `before` tree holds it), hidden and unfocused. Null (nothing
/// changed) when the tab has no split or memory runs out.
pub fn parkSurface(self: *Tab, s: *Surface) ?SplitSnapshot {
    const alloc = self.window.app.core_app.alloc;
    if (!self.tree.isSplit() or self.tree.locate(s) == null) return null;
    var before = self.tree.clone(alloc) catch return null;
    self.removeSurfaceRaw(s);
    if (self.tree.locate(s) != null) {
        before.deinit();
        return null;
    }
    const after = self.tree.clone(alloc) catch {
        // No snapshot to come back to: put the surface back.
        self.swapTree(before, s, true);
        return null;
    };
    s.split_parked = true;
    parkOne(s);
    return .{ .before = before, .after = after };
}

/// The pane that takes the focus when `s` leaves the tree, as `removeSurfaceRaw`
/// picks it.
fn neighbourOf(self: *Tab, s: *Surface) ?*Surface {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(s) orelse return null;
    const h = (focusAfterRemove(Surface.Tree, &self.tree, at, alloc) catch null) orelse return null;
    return switch (self.tree.nodes[h.idx()]) {
        .leaf => |v| v,
        .split => null,
    };
}

/// Makes `tree` the tree of the tab (undo or redo of a split); `s` is the
/// surface that comes or goes with it, shown when `show_s`.
pub fn swapTree(self: *Tab, tree: Surface.Tree, s: *Surface, show_s: bool) void {
    // The pane that takes the focus when `s` leaves is picked in the tree
    // that still holds it.
    const next_focus = if (!show_s and self.focused == s) self.neighbourOf(s) else null;
    self.replaceTree(tree);
    if (show_s) {
        s.split_parked = false;
        Inspector.parkSync(s);
        s.applyDpi();
        _ = win32.user32.ShowWindow(s.hwnd, win32.user32.SW_SHOW);
        self.focused = s;
        // The sweeps skipped it while it was parked.
        theme.reportScheme(s);
        recovery.checkSurface(s);
        composition.surfaceUnparked(s);
        taskbar.surfaceRestored(self.window, s.id);
    } else {
        s.split_parked = true;
        _ = win32.user32.ShowWindow(s.hwnd, win32.user32.SW_HIDE);
        parkOne(s);
        if (self.focused == s) self.focused = next_focus;
    }
    const active = self.window.activeTab() == self;
    self.applyOcclusion(self.window.tabOnScreen(self));
    hooks_mod.tabLayoutChanged(self);
    if (active) self.focus();
}

pub fn setVisible(self: *Tab, visible: bool) void {
    _ = win32.user32.ShowWindow(
        self.hwnd,
        if (visible) win32.user32.SW_SHOW else win32.user32.SW_HIDE,
    );
    if (visible) self.layout();

    self.applyOcclusion(visible and Window.windowOnScreen(self.window.screenState()));
    hooks_mod.tabShown(self, visible);
}

/// Tell core which surfaces are on screen. Only the leaves the layout shows
/// are un-occluded, and only while `shown` (the tab is the active one of a
/// window that is on screen: `Window.tabOnScreen`); zoomed-out and
/// empty-rect leaves stay occluded.
pub fn applyOcclusion(self: *Tab, shown: bool) void {
    // (A parked tab renders nothing, whatever selects it.)
    const minimized = win32.user32.IsIconic(self.window.hwnd) != 0;
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        s.minimized = minimized;
        if (!s.initialized) continue;
        const leaf_visible = if (self.split_layout) |l|
            (if (l.leafFor(s)) |leaf| leaf.visible else true)
        else
            true;
        const on_screen = onScreen(shown, leaf_visible, self.parked);
        s.core_surface.occlusionCallback(on_screen) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }
}

/// Fit the container to the window's content area and the surfaces into
/// the container. A collapsed area is left alone: there is nothing to lay
/// out, and no surface may ever be resized to 0x0.
pub fn layout(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    const rect = self.window.contentRect();
    if (rect.w <= 0 or rect.h <= 0) {
        // The cached pointers may go stale while nothing is laid out.
        if (self.split_layout) |*l| l.deinit(alloc);
        self.split_layout = null;
        return;
    }

    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        rect.x,
        rect.y,
        rect.w,
        rect.h,
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );

    self.last_content = .{ .w = rect.w, .h = rect.h };

    if (self.tree.isEmpty()) return;
    const new = Layout.compute(
        alloc,
        &self.tree,
        .{ .w = rect.w, .h = rect.h },
        SplitLayout.gapPx(self.window.dpi),
    ) catch |err| {
        log.warn("unable to lay out the split tree err={}", .{err});
        // The cached pointers may be stale by now.
        if (self.split_layout) |*l| l.deinit(alloc);
        self.split_layout = null;
        return;
    };

    const old_leaves: []const Layout.Leaf = if (self.split_layout) |l| l.leaves else &.{};
    const changes: ?[]VisibilityChange(Layout.Leaf) =
        visibilityChanges(Layout.Leaf, alloc, old_leaves, new.leaves) catch null;
    defer if (changes) |c| alloc.free(c);

    // One batch, so the panes move together.
    var hdwp = win32.user32.BeginDeferWindowPos(@intCast(new.leaves.len));
    if (hdwp != null) {
        for (new.leaves) |leaf| {
            const r = leaf.rect;
            hdwp = win32.user32.DeferWindowPos(hdwp.?, leaf.view.hwnd, null, r.x, r.y, r.w, r.h, leafFlags(leaf));
            if (hdwp == null) break;
        }
    }
    if (hdwp) |h| {
        _ = win32.user32.EndDeferWindowPos(h);
    } else {
        // The batch failed (and is gone): place every pane one by one.
        for (new.leaves) |leaf| {
            const r = leaf.rect;
            _ = win32.user32.SetWindowPos(leaf.view.hwnd, null, r.x, r.y, r.w, r.h, leafFlags(leaf));
        }
    }

    if (self.split_layout) |*l| l.deinit(alloc);
    self.split_layout = new;

    // Hidden panes are occluded; shown ones only when the tab itself is.
    const shown = self.window.tabOnScreen(self);
    for (changes orelse &.{}) |c| {
        if (c.visible and !shown) continue;
        if (!c.view.initialized) continue;
        c.view.core_surface.occlusionCallback(c.visible) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }

    hooks_mod.tabLayoutChanged(self);
}

/// Flags for placing one pane. A hidden pane keeps its position and size:
/// it must never be resized to nothing (core would shrink the pty to 0x0).
fn leafFlags(leaf: Layout.Leaf) u32 {
    return if (leaf.visible)
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE | win32.user32.SWP_SHOWWINDOW
    else
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE | win32.user32.SWP_NOMOVE |
            win32.user32.SWP_NOSIZE | win32.user32.SWP_HIDEWINDOW;
}

const Layout = SplitLayout.Layout(Surface.Tree);

pub fn VisibilityChange(comptime Leaf: type) type {
    return struct {
        view: @FieldType(Leaf, "view"),
        visible: bool,
    };
}

/// The panes whose visibility differs between two layouts, plus every new
/// pane; these are the ones whose occlusion has to be told to core.
pub fn visibilityChanges(
    comptime Leaf: type,
    alloc: Allocator,
    old: []const Leaf,
    new: []const Leaf,
) Allocator.Error![]VisibilityChange(Leaf) {
    var out: std.ArrayList(VisibilityChange(Leaf)) = .empty;
    errdefer out.deinit(alloc);
    for (new) |n| {
        const was: ?bool = for (old) |o| {
            if (o.view == n.view) break o.visible;
        } else null;
        if (was == null or was.? != n.visible) {
            try out.append(alloc, .{ .view = n.view, .visible = n.visible });
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const SplitError = Allocator.Error || error{ SurfaceNotInTab, CreateFailed };

/// The node of a surface in this tab's tree.
pub fn handleOf(self: *const Tab, s: *const Surface) ?Surface.Tree.Node.Handle {
    return self.tree.locate(s);
}

pub const SplitOptions = struct {
    /// The share of the existing pane.
    ratio: f16 = 0.5,
    /// Whether the new pane takes the focus.
    focus: bool = true,
    /// The tmux pane number of the new surface; null: its own id.
    pane_id: ?u32 = null,
    /// A tmux pane: command, directory and environment.
    tmux: ?*const tmux_spawn.Plan = null,
};

/// The pure part of `leafRects`: the cached layout copied, else a fresh one
/// over `content`.
fn leafRectsOf(
    comptime Tree: type,
    alloc: Allocator,
    tree: *const Tree,
    cached: ?SplitLayout.Layout(Tree),
    content: geom.Rect,
    gap: i32,
) Allocator.Error!SplitLayout.Layout(Tree) {
    const L = SplitLayout.Layout(Tree);
    if (cached) |c| {
        const leaves = try alloc.dupe(L.Leaf, c.leaves);
        errdefer alloc.free(leaves);
        return .{ .leaves = leaves, .dividers = try alloc.dupe(L.Divider, c.dividers) };
    }
    return L.compute(alloc, tree, .{ .w = content.w, .h = content.h }, gap);
}

/// The pane rectangles: the applied layout, or (a minimized window has none)
/// one computed over the last content rectangle. Never null; the caller owns
/// the result (`deinit` with the app allocator).
pub fn leafRects(self: *Tab, alloc: Allocator) Allocator.Error!Layout {
    return leafRectsOf(
        Surface.Tree,
        alloc,
        &self.tree,
        self.split_layout,
        self.last_content,
        SplitLayout.gapPx(self.window.dpi),
    );
}

/// Sizes `s` from `leafRects` when the window is minimized: nothing was laid
/// out, and the surface would otherwise start at the stale full-tab size.
fn sizeFromLeafRects(self: *Tab, s: *Surface) void {
    if (win32.user32.IsIconic(self.window.hwnd) == 0) return;
    const alloc = self.window.app.core_app.alloc;
    var rects = self.leafRects(alloc) catch return;
    defer rects.deinit(alloc);
    const leaf = rects.leafFor(s) orelse return;
    if (leaf.rect.w <= 0 or leaf.rect.h <= 0) return;
    s.size.store(renderer.D3D11.packSize(@intCast(leaf.rect.w), @intCast(leaf.rect.h)), .release);
}

/// Split the pane `at`: the new surface (inheriting from it) takes the
/// other half and gets the focus.
pub fn split(
    self: *Tab,
    at: *Surface,
    direction: Surface.Tree.Split.Direction,
) SplitError!*Surface {
    return self.splitWith(at, direction, .{});
}

/// Bounds of `SplitOptions.ratio`: a split must leave both panes a share.
const min_split_ratio: f16 = 0.1;
const max_split_ratio: f16 = 0.9;

fn clampRatio(r: f16) f16 {
    if (!(r > min_split_ratio)) return min_split_ratio; // also NaN
    return @min(r, max_split_ratio);
}

pub fn splitWith(
    self: *Tab,
    at: *Surface,
    direction: Surface.Tree.Split.Direction,
    opts: SplitOptions,
) SplitError!*Surface {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.handleOf(at) orelse return error.SurfaceNotInTab;

    // The error set is closed here: an inferred one would loop through core
    // (surface creation -> key callback -> binding action -> new_split).
    const surface = Surface.create(self, .{
        .parent = &at.core_surface,
        .context = .split,
        .pane_id = opts.pane_id,
        .tmux = opts.tmux,
    }) catch |err| {
        log.warn("unable to create a split surface err={}", .{err});
        return error.CreateFailed;
    };
    var single = Surface.Tree.init(alloc, surface) catch |err| {
        surface.destroy();
        return err;
    };
    // Drops the creator's reference; the new tree holds its own.
    defer single.deinit();

    const new_tree = try self.tree.split(alloc, handle, direction, clampRatio(opts.ratio), &single);
    self.replaceTree(new_tree);
    self.sizeFromLeafRects(surface);
    surface.applySize(surface.size.load(.acquire));

    if (opts.focus) self.focused = surface;
    hooks_mod.tabLayoutChanged(self);
    if (opts.focus and self.window.activeTab() == self) self.focus();
    return surface;
}

/// Puts a new surface (same pane number, same place) where `old` is and
/// releases `old`, whose pseudo console closes. The focus moves along.
pub fn replaceSurface(
    self: *Tab,
    old: *Surface,
    plan: *const tmux_spawn.Plan,
) SplitError!*Surface {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.handleOf(old) orelse return error.SurfaceNotInTab;

    const surface = Surface.create(self, .{
        .parent = &old.core_surface,
        .context = .split,
        .pane_id = old.pane_id,
        .tmux = plan,
    }) catch |err| {
        log.warn("unable to create the replacement surface err={}", .{err});
        return error.CreateFailed;
    };
    // The new tree references the new surface itself.
    const new_tree = self.tree.replace(alloc, handle, surface) catch |err| {
        surface.destroy();
        return err;
    };
    // The old pane is gone for good: snapshots that hold it would keep its
    // process alive.
    undo_actions.forgetSurface(self.window.app, old);

    const was_focused = self.focused == old;
    title_edit.cancelForSurface(self.window, old);
    // Hidden first: the old surface's threads take a moment to join.
    _ = win32.user32.ShowWindow(old.hwnd, win32.user32.SW_HIDE);
    if (was_focused) self.focused = surface;
    self.replaceTree(new_tree);
    self.sizeFromLeafRects(surface);
    surface.applySize(surface.size.load(.acquire));

    hooks_mod.tabLayoutChanged(self);
    if (was_focused and self.window.activeTab() == self) self.focus();
    return surface;
}

/// Replace the split tree, releasing the old one. The new one is laid out
/// first: joining the threads of the old surfaces takes a moment, and the
/// remaining panes should not wait for it to get their size.
pub fn replaceTree(self: *Tab, tree: Surface.Tree) void {
    self.cancelDrag();
    var old = self.tree;
    self.tree = tree;
    self.layout();
    old.deinit();
}

/// Take a surface out of the tab. Focus moves to a neighbour; a tab left
/// without surfaces is removed from its window.
pub fn removeSurface(self: *Tab, s: *Surface) void {
    // Undo entries about the surface are void once it is gone.
    undo_actions.forgetSurface(self.window.app, s);
    self.removeSurfaceRaw(s);
}

/// `removeSurface` without touching the undo entries (the close-undo takes
/// a surface out of the tree and keeps it).
fn removeSurfaceRaw(self: *Tab, s: *Surface) void {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(s) orelse return;
    self.cancelDrag();
    title_edit.cancelForSurface(self.window, s);

    // The new focus is picked in the old tree but only taken once the
    // removal went through.
    var next_focus: ?*Surface = null;
    if (self.focused == s) {
        if (focusAfterRemove(Surface.Tree, &self.tree, at, alloc) catch null) |h| {
            switch (self.tree.nodes[h.idx()]) {
                .leaf => |v| next_focus = v,
                .split => {},
            }
        }
    }

    const new_tree = self.tree.remove(alloc, at) catch |err| {
        log.warn("unable to remove surface from the split tree err={}", .{err});
        return;
    };
    if (new_tree.isEmpty()) {
        self.window.removeTab(self);
        return;
    }
    if (self.focused == s) self.focused = next_focus;

    // Hidden before the last reference goes: the surface's threads are
    // joined as the old tree is released.
    _ = win32.user32.ShowWindow(s.hwnd, win32.user32.SW_HIDE);
    self.replaceTree(new_tree);
    hooks_mod.tabLayoutChanged(self);
    if (self.window.activeTab() == self) self.focus();
}

/// The title shown for this tab.
pub fn title(self: *const Tab) []const u8 {
    if (self.title_override) |t| return t;
    if (self.focusedSurface()) |s| return s.shownTitle();
    return title_rules.fallback;
}

/// Whether a surface of this tab is ringing the bell.
pub fn bellRinging(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.bell_ringing) return true;
    }
    return false;
}

/// Whether closing this tab would kill a running process.
pub fn needsConfirmClose(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        if (s.initialized and s.core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// Move the tab to another top-level window.
pub fn setWindow(self: *Tab, window: *Window) void {
    const from = self.window;
    self.shown_before = false;
    // A parked split keeps the window it was parked in and nothing sweeps it
    // here: the undo entries of a tab that moves end.
    if (undo_actions.forgetTab(from.app, self) > 0) log.info("undo: the tab moved to another window, its undo entries ended", .{});
    const rescale = self.window.dpi != window.dpi;
    // The progress bar of the moved surface stays on the old button otherwise.
    var moved = self.tree.iterator();
    while (moved.next()) |entry| taskbar.surfaceClosed(self.window, entry.view.id);
    self.window = window;
    _ = win32.user32.SetParent(self.hwnd, window.hwnd);
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        entry.view.window = window;
        if (rescale) entry.view.applyDpi();
        // The swap chain was made for the old parent chain.
        entry.view.bumpPresentTarget();
    }
    hooks_mod.tabReparented(self, from, window);
}

// -- Moving one pane ------------------------------------------------------------
//
// A pane moves between tabs and windows without restarting its process: the
// surface (HWND, renderer, pty, threads) stays, only its parent window, the
// two trees and the pointers change. Everything that can fail (memory) is done
// first, so a failure changes nothing; then the steps of `moveOrder` run.

pub const MoveError = Allocator.Error || error{ SurfaceNotInTab, SameSurface, TargetGone };

/// What a move does to the source side.
pub const MoveKind = enum {
    /// Inside one tab: the tree is rebuilt, nothing is reparented.
    same_tab,
    /// To another tab; the source keeps other panes.
    other_tab,
    /// To another tab; the source tab held only this pane and goes.
    emptied_tab,
    /// Like `emptied_tab`, and the source window had no other tab.
    emptied_window,
};

/// The steps of a move after the trees were prepared, in the order they run.
pub const Step = enum {
    /// Undo entries that name the pane or the tabs, a title editor on it.
    forget_undo,
    /// `Surface.reparent`: the HWND and the pointers.
    reparent,
    /// The source tab gets the tree without the pane.
    release_source,
    /// The source tab's tree becomes empty (before its removal: `Tab.destroy`
    /// must find no surface to stop, the pane lives on in the target).
    empty_source_tree,
    /// `Window.removeTab` of the emptied source tab.
    remove_source_tab,
    /// The target tab gets the tree with the pane, laid out.
    replace_target_tree,
    /// Focus, window title and tab strip, activation.
    focus_target,
    /// The source window has no tab left: it closes.
    close_source_window,
};

/// The order of a move; the code runs exactly this list, the test pins it.
/// The pane is reparented before it leaves the old tree and an emptied tree
/// is empty before its tab is removed, so neither the removal nor the old
/// container's destruction can touch the pane.
fn moveOrder(kind: MoveKind) []const Step {
    return switch (kind) {
        .same_tab => &.{ .forget_undo, .replace_target_tree, .focus_target },
        .other_tab => &.{ .forget_undo, .reparent, .release_source, .replace_target_tree, .focus_target },
        .emptied_tab => &.{ .forget_undo, .reparent, .empty_source_tree, .remove_source_tab, .replace_target_tree, .focus_target },
        .emptied_window => &.{ .forget_undo, .reparent, .empty_source_tree, .remove_source_tab, .replace_target_tree, .focus_target, .close_source_window },
    };
}

/// One prepared move.
const Move = struct {
    s: *Surface,
    source: *Tab,
    target: *Tab,
    source_window: *Window,
    kind: MoveKind,
    /// The target's tree with the pane. Null: the target's tree already
    /// holds it (a tab made by `createAdopting`), only a layout is needed.
    new_target: ?Surface.Tree,
    /// The source's tree without the pane (empty when it was the only one).
    new_source: Surface.Tree = .empty,
    /// The pane of the source that takes its focus.
    next_focus: ?*Surface = null,

    /// Everything that can fail, for a move of `s` out of its tab into
    /// `target`.
    fn prepare(s: *Surface, target: *Tab, new_target: ?Surface.Tree) MoveError!Move {
        const source = s.tab;
        const alloc = source.window.app.core_app.alloc;
        const at = source.tree.locate(s) orelse return error.SurfaceNotInTab;

        // The new focus is picked in the old tree but only taken at the release.
        var next_focus: ?*Surface = null;
        if (source.focused == s) {
            if (focusAfterRemove(Surface.Tree, &source.tree, at, alloc) catch null) |h| {
                switch (source.tree.nodes[h.idx()]) {
                    .leaf => |v| next_focus = v,
                    .split => {},
                }
            }
        }
        const new_source = try source.tree.remove(alloc, at);
        const kind: MoveKind = if (!new_source.isEmpty())
            .other_tab
        else if (source.window.tabs.items.len == 1)
            .emptied_window
        else
            .emptied_tab;
        return .{
            .s = s,
            .source = source,
            .target = target,
            .source_window = source.window,
            .kind = kind,
            .new_target = new_target,
            .new_source = new_source,
            .next_focus = next_focus,
        };
    }

    fn run(m: *Move) void {
        for (moveOrder(m.kind)) |step| switch (step) {
            .forget_undo => m.forgetUndo(),
            .reparent => m.s.reparent(m.target),
            .release_source, .empty_source_tree => {
                _ = m.source.releaseMoved(m.s, m.new_source, m.next_focus);
            },
            .remove_source_tab => m.source_window.removeTab(m.source),
            .replace_target_tree => m.replaceTarget(),
            .focus_target => m.focusTarget(),
            .close_source_window => {
                if (m.source_window.tabs.items.len == 0) m.source_window.requestClose(true);
            },
        };
    }

    fn forgetUndo(m: *Move) void {
        const app = m.target.window.app;
        if (m.kind != .same_tab) {
            // Their snapshots no longer match the trees.
            undo_actions.forgetSurface(app, m.s);
            _ = undo_actions.forgetTab(app, m.source);
            title_edit.cancelForSurface(m.source_window, m.s);
        }
        _ = undo_actions.forgetTab(app, m.target);
    }

    fn replaceTarget(m: *Move) void {
        const target = m.target;
        if (m.new_target) |t| {
            // (Laying out the new tree sizes the pane to its new place:
            // WM_SIZE, core resize, ResizePseudoConsole.)
            target.replaceTree(t);
            m.new_target = null;
        } else {
            target.layout();
        }
        target.focused = m.s;
        target.applyOcclusion(target.window.tabOnScreen(target));
        hooks_mod.tabLayoutChanged(target);
    }

    fn focusTarget(m: *Move) void {
        const tw = m.target.window;
        tw.refreshTitle();
        Chrome.invalidate(tw);
        // A closing source window is hidden and about to go.
        if (m.kind != .same_tab and m.kind != .emptied_window and m.source_window != tw) {
            m.source_window.refreshTitle();
            Chrome.invalidate(m.source_window);
        }
        tw.activate();
        m.target.focus();
    }
};

/// Same tab: move `s` next to `dst` on the `dir` side. Focus goes to `s`.
/// Nothing changed on error.
pub fn moveWithin(
    self: *Tab,
    s: *Surface,
    dst: *Surface,
    dir: Surface.Tree.Split.Direction,
) MoveError!void {
    if (s == dst) return error.SameSurface;
    if (self.tree.locate(s) == null) return error.SurfaceNotInTab;
    if (self.tree.locate(dst) == null) return error.TargetGone;
    const alloc = self.window.app.core_app.alloc;
    const new_tree = split_drag.moveWithin(Surface.Tree, alloc, &self.tree, s, dst, dir) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SameView => error.SameSurface,
        error.ViewNotFound => error.SurfaceNotInTab,
    };
    var m: Move = .{
        .s = s,
        .source = self,
        .target = self,
        .source_window = self.window,
        .kind = .same_tab,
        .new_target = new_tree,
    };
    m.run();
}

/// Other tab (of this or another window): put `s` next to `dst` of this tab
/// on the `dir` side, then take it out of its old tab. An emptied old tab is
/// removed, and an emptied old window closes, after `s` is safely reparented.
/// The process of `s` keeps running. Nothing changed on error.
pub fn adoptNextTo(
    self: *Tab,
    s: *Surface,
    dst: *Surface,
    dir: Surface.Tree.Split.Direction,
) MoveError!void {
    if (s == dst) return error.SameSurface;
    if (s.tab == self) return self.moveWithin(s, dst, dir);
    if (s.tab.tree.locate(s) == null) return error.SurfaceNotInTab;
    if (self.tree.locate(dst) == null or self.window.tabIndex(self) == null) return error.TargetGone;

    const alloc = self.window.app.core_app.alloc;
    var new_target = split_drag.insertInto(Surface.Tree, alloc, &self.tree, s, dst, dir) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SameView => error.SameSurface,
        error.ViewNotFound => error.TargetGone,
    };
    errdefer new_target.deinit();
    var m = try Move.prepare(s, self, new_target);
    m.run();
}

/// Completes the move into a tab made by `createAdopting(window, s)` that is
/// in its window's tab list: `s` leaves its old tab and becomes this tab's
/// pane. On error nothing changed and the caller drops the tab with
/// `dropAdopting` and `Window.removeTab`.
pub fn adopt(self: *Tab, s: *Surface) MoveError!void {
    if (s.tab == self) return error.SameSurface;
    if (self.tree.locate(s) == null) return error.TargetGone;
    if (self.window.tabIndex(self) == null) return error.TargetGone;
    var m = try Move.prepare(s, self, null);
    m.run();
}

/// A tab made by `createAdopting` whose `adopt` failed: lets go of the pane
/// without stopping it, so that `Window.removeTab` can take the tab down.
pub fn dropAdopting(self: *Tab) void {
    var old = self.tree;
    self.tree = .empty;
    self.focused = null;
    old.deinit();
}

/// The source side of a move, after the pane was reparented: the tab gets
/// `new_tree` (the old tree without `s`); returns whether the tab is now
/// empty. When it is, its tree is empty on return, so the following
/// `Window.removeTab` neither stops the threads of `s` nor destroys its HWND
/// (it is no longer a child of this container). The old tree's reference to
/// `s` is dropped here; the target tree holds the other one.
fn releaseMoved(self: *Tab, s: *Surface, new_tree: Surface.Tree, next_focus: ?*Surface) bool {
    const alloc = self.window.app.core_app.alloc;
    self.cancelDrag();
    if (self.focused == s) self.focused = next_focus;
    if (new_tree.isEmpty()) {
        var old = self.tree;
        self.tree = .empty;
        self.focused = null;
        if (self.split_layout) |*l| l.deinit(alloc);
        self.split_layout = null;
        old.deinit();
        return true;
    }
    self.replaceTree(new_tree);
    self.applyOcclusion(self.window.tabOnScreen(self));
    hooks_mod.tabLayoutChanged(self);
    return false;
}

/// The surface to focus once `at` is removed: the previous leaf, else the
/// next one wrapped around; never `at` itself. Null if `at` is the only leaf.
pub fn focusAfterRemove(
    comptime T: type,
    tree: *const T,
    at: T.Node.Handle,
    alloc: Allocator,
) !?T.Node.Handle {
    if (try tree.goto(alloc, at, .previous)) |h| {
        if (h != at) return h;
    }
    if (try tree.goto(alloc, at, .next_wrapped)) |h| {
        if (h != at) return h;
    }
    return null;
}

fn fillDividerColor(self: *Tab, hdc: win32.user32.HDC) void {
    var rc: win32.foundation.RECT = undefined;
    if (win32.user32.GetClientRect(self.hwnd, &rc) == 0) return;
    const c = theme.palette(self.window).divider;
    const ref: u32 = @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
    if (self.divider_brush == null or self.divider_ref != ref) {
        if (self.divider_brush) |b| _ = win32.gdi32.DeleteObject(@ptrCast(b));
        self.divider_brush = win32.gdi32.CreateSolidBrush(ref);
        self.divider_ref = ref;
    }
    const brush = self.divider_brush orelse return;
    if (self.window.composition.glass) {
        // The dividers are opaque, also over glass (the panes cover the rest).
        composition.fillWithAlpha(hdc, &rc, brush, false);
    } else {
        _ = win32.gdi32.FillRect(hdc, &rc, brush);
    }
}

/// The size cursor when the pointer is over a divider or one is dragged.
pub fn cursorForPoint(self: *Tab) ?*const anyopaque {
    const kind: DragKind = if (self.drag) |d| d.kind else blk: {
        const l = self.split_layout orelse return null;
        var pt: win32.foundation.POINT = .{ .x = 0, .y = 0 };
        if (win32.user32.GetCursorPos(&pt) == 0) return null;
        if (win32.user32.ScreenToClient(self.hwnd, &pt) == 0) return null;
        const i = l.dividerAt(pt.x, pt.y, SplitLayout.grabSlopPx(self.window.dpi)) orelse return null;
        break :blk if (l.dividers[i].layout == .horizontal) .horizontal else .vertical;
    };
    return if (kind == .horizontal) win32.user32.IDC_SIZEWE else win32.user32.IDC_SIZENS;
}

/// Start a drag when a press at (x, y) of `child` (a pane, or null for the
/// container itself) is on a divider's grab zone. Whether it started.
pub fn beginDragFrom(self: *Tab, child: ?win32.foundation.HWND, x: i32, y: i32) bool {
    var pt: win32.foundation.POINT = .{ .x = x, .y = y };
    if (child) |c| {
        if (win32.user32.MapWindowPoints(c, self.hwnd, @ptrCast(&pt), 1) == 0) return false;
    }
    self.beginDrag(pt.x, pt.y);
    return self.drag != null;
}

fn beginDrag(self: *Tab, x: i32, y: i32) void {
    const l = self.split_layout orelse return;
    const i = l.dividerAt(x, y, SplitLayout.grabSlopPx(self.window.dpi)) orelse return;
    const d = l.dividers[i];
    const kind: DragKind = if (d.layout == .horizontal) .horizontal else .vertical;
    const centre = if (kind == .horizontal) d.rect.x + @divTrunc(d.rect.w, 2) else d.rect.y + @divTrunc(d.rect.h, 2);
    self.drag = .{
        .split = d.split,
        .kind = kind,
        .span = d.span,
        .grab_offset = (if (kind == .horizontal) x else y) - centre,
    };
    _ = win32.user32.SetCapture(self.hwnd);
}

fn dragTo(self: *Tab, x: i32, y: i32) void {
    const d = &(self.drag orelse return);
    if (!isSplit(&self.tree, d.split)) {
        self.cancelDrag();
        return;
    }
    const pos = (if (d.kind == .horizontal) x else y) - d.grab_offset;
    const cell = self.window.cell_size orelse apprt.action.CellSize{ .width = 0, .height = 0 };
    const ratio = SplitLayout.ratioForDrag(
        if (d.kind == .horizontal) .horizontal else .vertical,
        d.span,
        SplitLayout.gapPx(self.window.dpi),
        pos,
        dragMinPx(cell, d.kind),
    );
    self.tree.resizeInPlace(d.split, ratio);
    if (!d.timer_armed and win32.user32.SetTimer(self.hwnd, messages.timers.tab.divider_drag, drag_interval_ms, null) != 0)
        d.timer_armed = true;
}

/// Whether `h` still names a split of `tree`.
fn isSplit(tree: anytype, h: @TypeOf(tree.*).Node.Handle) bool {
    return h.idx() < tree.nodes.len and tree.nodes[h.idx()] == .split;
}

/// Drop a drag without a layout: the tree is about to change or changed.
fn cancelDrag(self: *Tab) void {
    const d = self.drag orelse return;
    self.drag = null;
    if (d.timer_armed) _ = win32.user32.KillTimer(self.hwnd, messages.timers.tab.divider_drag);
    _ = win32.user32.ReleaseCapture();
}

/// Finish a drag: the final layout is applied now, not by the timer.
fn endDrag(self: *Tab) void {
    const d = self.drag orelse return;
    self.drag = null;
    if (d.timer_armed) _ = win32.user32.KillTimer(self.hwnd, messages.timers.tab.divider_drag);
    self.layout();
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == win32.user32.WM_NCCREATE) {
        const cs: *const win32.user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            const self: *Tab = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            util.setUserData(hwnd, self);
        }
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(Tab, hwnd) orelse
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // The surfaces cover the container except for the divider strips.
        win32.user32.WM_ERASEBKGND => {
            self.fillDividerColor(@ptrFromInt(wparam));
            return 1;
        },

        win32.user32.WM_PAINT => {
            var ps: win32.user32.PAINTSTRUCT = undefined;
            if (win32.user32.BeginPaint(hwnd, &ps)) |hdc| {
                self.fillDividerColor(hdc);
                _ = win32.user32.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        win32.user32.WM_SETCURSOR => {
            if (win32.user32.loWord(@bitCast(lparam)) == win32.user32.HTCLIENT) {
                if (self.cursorForPoint()) |cursor| {
                    _ = win32.user32.SetCursor(win32.user32.LoadCursorW(null, cursor));
                    return 1;
                }
            }
        },

        win32.user32.WM_LBUTTONDOWN => {
            _ = self.beginDragFrom(null, win32.user32.getXLparam(lparam), win32.user32.getYLparam(lparam));
            return 0;
        },

        win32.user32.WM_MOUSEMOVE => {
            if (self.drag != null) {
                self.dragTo(win32.user32.getXLparam(lparam), win32.user32.getYLparam(lparam));
                return 0;
            }
        },

        win32.user32.WM_LBUTTONUP => {
            if (self.drag != null) {
                // The capture change ends the drag.
                _ = win32.user32.ReleaseCapture();
                self.endDrag();
                self.focus();
            }
            return 0;
        },

        win32.user32.WM_CAPTURECHANGED => {
            self.endDrag();
            return 0;
        },

        win32.user32.WM_TIMER => if (wparam == messages.timers.tab.divider_drag) {
            if (self.drag) |*d| {
                d.timer_armed = false;
                _ = win32.user32.KillTimer(hwnd, messages.timers.tab.divider_drag);
                self.layout();
            }
            return 0;
        },

        win32.user32.WM_NCDESTROY => {
            self.hwnd_destroyed = true;
            if (self.divider_brush) |b| _ = win32.gdi32.DeleteObject(@ptrCast(b));
            self.divider_brush = null;
            util.setUserData(hwnd, null);
        },

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "win32 tab: drag minimum is two cells" {
    const cell: apprt.action.CellSize = .{ .width = 9, .height = 18 };
    try std.testing.expectEqual(@as(i32, 18), dragMinPx(cell, .horizontal));
    try std.testing.expectEqual(@as(i32, 36), dragMinPx(cell, .vertical));
    try std.testing.expectEqual(@as(i32, 16), dragMinPx(.{ .width = 0, .height = 0 }, .horizontal));
}

test "win32 tab: drag split must exist in the tree" {
    const alloc = std.testing.allocator;
    const TestTree = SplitTree(TestView);
    var va: TestView = .{ .label = "A" };
    var vb: TestView = .{ .label = "B" };
    var ta: TestTree = try .init(alloc, &va);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &vb);
    defer tb.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer tree.deinit();

    try std.testing.expect(isSplit(&tree, .root));
    try std.testing.expect(!isSplit(&ta, .root));
    try std.testing.expect(!isSplit(&tree, @fromBackingInt(40)));
}

const TestView = struct {
    label: []const u8,

    pub fn ref(self: *TestView, alloc: Allocator) Allocator.Error!*TestView {
        const ptr = try alloc.create(TestView);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *TestView, alloc: Allocator) void {
        alloc.destroy(self);
    }
};

test "win32 tab: focus after removing a leaf" {
    const alloc = std.testing.allocator;
    const TestTree = SplitTree(TestView);

    var va: TestView = .{ .label = "A" };
    var vb: TestView = .{ .label = "B" };
    var vc: TestView = .{ .label = "C" };
    var ta: TestTree = try .init(alloc, &va);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &vb);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, &vc);
    defer tc.deinit();

    // A | (B / C)
    var bc = try tb.split(alloc, .root, .down, 0.5, &tc);
    defer bc.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &bc);
    defer tree.deinit();

    const labelAt = struct {
        fn f(t: *const TestTree, h: TestTree.Node.Handle) []const u8 {
            return t.nodes[h.idx()].leaf.label;
        }
    }.f;
    const find = struct {
        fn f(t: *const TestTree, label: []const u8) TestTree.Node.Handle {
            var it = t.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.view.label, label)) return e.handle;
            }
            unreachable;
        }
    }.f;

    // The previous leaf takes the focus.
    const after_b = (try focusAfterRemove(TestTree, &tree, find(&tree, "B"), alloc)).?;
    try std.testing.expectEqualStrings("A", labelAt(&tree, after_b));

    // The first leaf has no previous one: the next follows.
    const after_a = (try focusAfterRemove(TestTree, &tree, find(&tree, "A"), alloc)).?;
    try std.testing.expectEqualStrings("B", labelAt(&tree, after_a));

    // A single leaf has no neighbour.
    var single: TestTree = try .init(alloc, &va);
    defer single.deinit();
    try std.testing.expectEqual(
        @as(?TestTree.Node.Handle, null),
        try focusAfterRemove(TestTree, &single, .root, alloc),
    );
}

test "win32 tab: split layout hides zoomed-out leaves" {
    const alloc = std.testing.allocator;
    const TestTree = SplitTree(TestView);
    const TestLayout = SplitLayout.Layout(TestTree);

    var va: TestView = .{ .label = "A" };
    var vb: TestView = .{ .label = "B" };
    var ta: TestTree = try .init(alloc, &va);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &vb);
    defer tb.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer tree.deinit();

    const bounds: @import("geom.zig").Rect = .{ .w = 800, .h = 600 };
    var plain = try TestLayout.compute(alloc, &tree, bounds, 4);
    defer plain.deinit(alloc);

    // The first layout reports every pane.
    const first = try visibilityChanges(TestLayout.Leaf, alloc, &.{}, plain.leaves);
    defer alloc.free(first);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    for (first) |c| try std.testing.expect(c.visible);

    // Zoom on: the others go invisible, the zoomed one stays untouched.
    var it = tree.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.view.label, "B")) tree.zoom(e.handle);
    }
    var zoomed = try TestLayout.compute(alloc, &tree, bounds, 4);
    defer zoomed.deinit(alloc);
    const on = try visibilityChanges(TestLayout.Leaf, alloc, plain.leaves, zoomed.leaves);
    defer alloc.free(on);
    try std.testing.expectEqual(@as(usize, 1), on.len);
    try std.testing.expectEqualStrings("A", on[0].view.label);
    try std.testing.expect(!on[0].visible);

    // Zoom off: they come back.
    const off = try visibilityChanges(TestLayout.Leaf, alloc, zoomed.leaves, plain.leaves);
    defer alloc.free(off);
    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqualStrings("A", off[0].view.label);
    try std.testing.expect(off[0].visible);

    // Nothing changed, nothing reported.
    const same = try visibilityChanges(TestLayout.Leaf, alloc, plain.leaves, plain.leaves);
    defer alloc.free(same);
    try std.testing.expectEqual(@as(usize, 0), same.len);
}

test "win32 tab: focus is taken only inside the active top-level" {
    const a: win32.foundation.HWND = @ptrFromInt(0x1000);
    const b: win32.foundation.HWND = @ptrFromInt(0x2000);
    try std.testing.expect(mayTakeFocus(a, a));
    try std.testing.expect(!mayTakeFocus(b, a));
    try std.testing.expect(!mayTakeFocus(null, a));
}

test "win32 tab: split ratio is clamped" {
    try std.testing.expectEqual(@as(f16, 0.1), clampRatio(0));
    try std.testing.expectEqual(@as(f16, 0.1), clampRatio(-1));
    try std.testing.expectEqual(@as(f16, 0.1), clampRatio(std.math.nan(f16)));
    try std.testing.expectEqual(@as(f16, 0.9), clampRatio(1));
    try std.testing.expectEqual(@as(f16, 0.9), clampRatio(std.math.inf(f16)));
    try std.testing.expectEqual(@as(f16, 0.5), clampRatio(0.5));
}

test "win32 tab: leaf rects while minimized" {
    const alloc = std.testing.allocator;
    const TestTree = SplitTree(TestView);
    const TestLayout = SplitLayout.Layout(TestTree);

    var va: TestView = .{ .label = "A" };
    var vb: TestView = .{ .label = "B" };
    var ta: TestTree = try .init(alloc, &va);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &vb);
    defer tb.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer tree.deinit();

    const content: geom.Rect = .{ .w = 800, .h = 600 };
    // No applied layout (minimized): computed over the stored content.
    var fresh = try leafRectsOf(TestTree, alloc, &tree, null, content, 4);
    defer fresh.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), fresh.leaves.len);
    for (fresh.leaves) |l| {
        try std.testing.expect(l.visible);
        try std.testing.expect(l.rect.w > 0 and l.rect.h == 600);
    }
    try std.testing.expectEqual(@as(i32, 800), fresh.leaves[0].rect.w + 4 + fresh.leaves[1].rect.w);

    // An applied layout is copied, not recomputed.
    var applied = try TestLayout.compute(alloc, &tree, .{ .w = 400, .h = 300 }, 4);
    defer applied.deinit(alloc);
    var copy = try leafRectsOf(TestTree, alloc, &tree, applied, content, 4);
    defer copy.deinit(alloc);
    try std.testing.expectEqual(applied.leaves[0].rect.w, copy.leaves[0].rect.w);
    try std.testing.expect(copy.leaves.ptr != applied.leaves.ptr);
}

/// Whether a leaf renders: its tab is the active one of a window that is on
/// screen (`shown`), the layout shows the leaf and the tab is not parked (a
/// hidden item presents no frames).
fn onScreen(shown: bool, leaf_visible: bool, parked: bool) bool {
    return shown and leaf_visible and !parked;
}

test "win32 tab: only the active tab of an on-screen window renders" {
    try std.testing.expect(onScreen(true, true, false));
    try std.testing.expect(!onScreen(true, true, true)); // parked tab
    try std.testing.expect(!onScreen(false, true, false)); // inactive tab, or the window shows nothing
    try std.testing.expect(!onScreen(true, false, false)); // zoomed-out or empty-rect pane
}

test "win32 tab: move order reparents before remove and empties before removeTab" {
    const indexOf = struct {
        fn f(steps: []const Step, step: Step) ?usize {
            for (steps, 0..) |x, i| if (x == step) return i;
            return null;
        }
    }.f;

    // Inside a tab nothing is reparented or released.
    const same = moveOrder(.same_tab);
    try std.testing.expect(indexOf(same, .reparent) == null);
    try std.testing.expect(indexOf(same, .release_source) == null);
    try std.testing.expect(indexOf(same, .remove_source_tab) == null);
    try std.testing.expect(indexOf(same, .replace_target_tree).? < indexOf(same, .focus_target).?);

    // To a tab that keeps other panes: reparent, then leave the old tree.
    const other = moveOrder(.other_tab);
    try std.testing.expect(indexOf(other, .reparent).? < indexOf(other, .release_source).?);
    try std.testing.expect(indexOf(other, .remove_source_tab) == null);
    try std.testing.expect(indexOf(other, .close_source_window) == null);
    try std.testing.expectEqual(Step.forget_undo, other[0]);

    // An emptied tab: reparent, empty the tree, only then remove the tab.
    inline for (.{ MoveKind.emptied_tab, MoveKind.emptied_window }) |kind| {
        const steps = moveOrder(kind);
        const reparent = indexOf(steps, .reparent).?;
        const empty = indexOf(steps, .empty_source_tree).?;
        const remove = indexOf(steps, .remove_source_tab).?;
        try std.testing.expect(reparent < empty);
        try std.testing.expect(empty < remove);
        try std.testing.expect(remove < indexOf(steps, .replace_target_tree).?);
        try std.testing.expect(indexOf(steps, .release_source) == null);
    }

    // The window closes last, and only when it lost its last tab.
    try std.testing.expect(indexOf(moveOrder(.emptied_tab), .close_source_window) == null);
    const window = moveOrder(.emptied_window);
    try std.testing.expectEqual(Step.close_source_window, window[window.len - 1]);
}
