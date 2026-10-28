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
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const hooks_mod = @import("hooks.zig");
const title_edit = @import("title_edit.zig");
const title_rules = @import("title_rules.zig");
const util = @import("util.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");
const composition = @import("composition.zig");
const messages = @import("messages.zig");
const taskbar = @import("taskbar.zig");
const tmux_spawn = @import("tmux/spawn.zig");
const renderer = @import("../../renderer.zig");

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
    errdefer _ = win32.user32.DestroyWindow(hwnd);

    // Core's start-up actions (initial size, title, ...) reach the window
    // through the surface's `tab`, which `Surface.create` sets before init.
    const surface = try Surface.create(self, .{
        .parent = opts.parent,
        .overrides = opts.overrides,
        .context = opts.context,
        .tmux = opts.tmux,
    });
    errdefer surface.destroy();

    self.tree = try Surface.Tree.init(alloc, surface);
    self.focused = surface;

    // Core's start-up actions (`initial_size`) resize the window while the
    // surface is still initializing, and the resulting child WM_SIZE never
    // reaches core: bring core up to date now.
    self.layout();
    surface.applySize(surface.size.load(.acquire));

    return self;
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

pub fn setVisible(self: *Tab, visible: bool) void {
    _ = win32.user32.ShowWindow(
        self.hwnd,
        if (visible) win32.user32.SW_SHOW else win32.user32.SW_HIDE,
    );
    if (visible) self.layout();

    self.applyOcclusion(visible);
    hooks_mod.tabShown(self, visible);
}

/// Tell core which surfaces are on screen. Only the leaves the layout shows
/// are un-occluded, and only while `shown` (the tab is the active one);
/// zoomed-out and empty-rect leaves stay occluded. A minimized window keeps
/// every surface occluded.
pub fn applyOcclusion(self: *Tab, shown: bool) void {
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
        s.core_surface.occlusionCallback(shown and !minimized and leaf_visible) catch |err|
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
    const shown = self.window.activeTab() == self and
        win32.user32.IsIconic(self.window.hwnd) == 0;
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
