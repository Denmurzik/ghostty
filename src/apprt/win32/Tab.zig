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
const util = @import("util.zig");

const log = std.log.scoped(.win32_tab);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTab");

pub const CreateOptions = struct {
    parent: ?*CoreSurface = null,
    overrides: Overrides = .none,
    context: apprt.surface.NewSurfaceContext = .tab,
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

/// The surface that has (or last had) keyboard focus. Not a reference: it
/// is only trusted while it is still in `tree` (see `focusedSurface`).
focused: ?*Surface,

/// A title set by the user; wins over the surface titles.
title_override: ?[:0]u8,
id: u32,

/// Whether the container HWND was already taken down with its parent.
hwnd_destroyed: bool = false,

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

/// Destroy the tab and free it. Joins the core threads of every surface.
pub fn destroy(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;

    // Hidden first: joining the threads of many surfaces takes a moment,
    // and the panes should not sit frozen on screen meanwhile.
    _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_HIDE);

    // Every surface goes first: core teardown still reads `window`.
    self.tree.deinit();
    self.focused = null;
    if (self.split_layout) |*l| l.deinit(alloc);

    if (!self.hwnd_destroyed) _ = win32.user32.DestroyWindow(self.hwnd);
    if (self.title_override) |t| alloc.free(t);
    alloc.destroy(self);
}

/// The focused surface if it is still in the tree, else the first leaf.
pub fn focusedSurface(self: *Tab) ?*Surface {
    if (self.focused) |f| {
        if (self.tree.locate(f) != null) return f;
    }
    var it = self.tree.iterator();
    const first = it.next() orelse return null;
    return first.view;
}

/// Give keyboard focus to the focused surface.
pub fn focus(self: *Tab) void {
    const s = self.focusedSurface() orelse return;
    _ = win32.user32.SetFocus(s.hwnd);
}

pub fn setVisible(self: *Tab, visible: bool) void {
    _ = win32.user32.ShowWindow(
        self.hwnd,
        if (visible) win32.user32.SW_SHOW else win32.user32.SW_HIDE,
    );
    if (visible) self.layout();

    // A minimized window keeps its surfaces occluded whatever the tab does.
    const minimized = win32.user32.IsIconic(self.window.hwnd) != 0;
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        s.minimized = minimized;
        if (!s.initialized) continue;
        s.core_surface.occlusionCallback(visible and !minimized) catch |err|
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

    if (self.tree.isEmpty()) return;
    const new = Layout.compute(
        alloc,
        &self.tree,
        .{ .w = rect.w, .h = rect.h },
        SplitLayout.gapPx(self.window.dpi),
    ) catch |err| {
        log.warn("unable to lay out the split tree err={}", .{err});
        return;
    };

    const old_leaves: []const Layout.Leaf = if (self.split_layout) |l| l.leaves else &.{};
    const changes: ?[]VisibilityChange(Layout.Leaf) =
        visibilityChanges(Layout.Leaf, alloc, old_leaves, new.leaves) catch null;
    defer if (changes) |c| alloc.free(c);

    // One batch, so the panes move together.
    var hdwp = win32.user32.BeginDeferWindowPos(@intCast(new.leaves.len));
    for (new.leaves) |leaf| placeLeaf(&hdwp, leaf);
    if (hdwp) |h| _ = win32.user32.EndDeferWindowPos(h);

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
}

/// Move one pane. A hidden pane keeps its position and size: it must never
/// be resized to nothing (core would shrink the pty to 0x0).
fn placeLeaf(hdwp: *?win32.user32.HDWP, leaf: Layout.Leaf) void {
    const hwnd = leaf.view.hwnd;
    const flags: u32 = if (leaf.visible)
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE | win32.user32.SWP_SHOWWINDOW
    else
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE | win32.user32.SWP_NOMOVE |
            win32.user32.SWP_NOSIZE | win32.user32.SWP_HIDEWINDOW;
    const r = leaf.rect;
    if (hdwp.*) |h| {
        // A failed call invalidates the batch; the rest go one by one.
        hdwp.* = win32.user32.DeferWindowPos(h, hwnd, null, r.x, r.y, r.w, r.h, flags);
        if (hdwp.* != null) return;
    }
    _ = win32.user32.SetWindowPos(hwnd, null, r.x, r.y, r.w, r.h, flags);
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

/// Split the pane `at`: the new surface (inheriting from it) takes the
/// other half and gets the focus.
pub fn split(
    self: *Tab,
    at: *Surface,
    direction: Surface.Tree.Split.Direction,
) SplitError!*Surface {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.handleOf(at) orelse return error.SurfaceNotInTab;

    // The error set is closed here: an inferred one would loop through core
    // (surface creation -> key callback -> binding action -> new_split).
    const surface = Surface.create(self, .{
        .parent = &at.core_surface,
        .context = .split,
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

    const new_tree = try self.tree.split(alloc, handle, direction, 0.5, &single);
    self.replaceTree(new_tree);
    surface.applySize(surface.size.load(.acquire));

    self.focused = surface;
    if (self.window.activeTab() == self) self.focus();
    return surface;
}

/// Replace the split tree, releasing the old one. The new one is laid out
/// first: joining the threads of the old surfaces takes a moment, and the
/// remaining panes should not wait for it to get their size.
pub fn replaceTree(self: *Tab, tree: Surface.Tree) void {
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
    if (self.window.activeTab() == self) self.focus();
}

/// The title shown for this tab.
pub fn title(self: *const Tab) []const u8 {
    if (self.title_override) |t| return t;
    // `focusedSurface` needs a mutable tab; the lookup does not mutate.
    const mutable: *Tab = @constCast(self);
    if (mutable.focusedSurface()) |s| {
        if (s.title) |t| return t;
    }
    return "Ghostty";
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
    self.window = window;
    _ = win32.user32.SetParent(self.hwnd, window.hwnd);
    var it = self.tree.iterator();
    while (it.next()) |entry| entry.view.window = window;
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
        // The surfaces paint every pixel of the container.
        win32.user32.WM_ERASEBKGND => return 1,

        win32.user32.WM_NCDESTROY => {
            self.hwnd_destroyed = true;
            util.setUserData(hwnd, null);
        },

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
