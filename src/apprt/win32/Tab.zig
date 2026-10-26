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

    // Every surface goes first: core teardown still reads `window`.
    self.tree.deinit();
    self.focused = null;

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

    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        if (!s.initialized) continue;
        s.core_surface.occlusionCallback(visible) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }
}

/// Fit the container to the window's content area and the surfaces into
/// the container. A collapsed area is left alone: there is nothing to lay
/// out, and no surface may ever be resized to 0x0.
pub fn layout(self: *Tab) void {
    const rect = self.window.contentRect();
    if (rect.w <= 0 or rect.h <= 0) return;

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
    switch (self.tree.nodes[0]) {
        // The single leaf fills the container.
        .leaf => |s| _ = win32.user32.SetWindowPos(
            s.hwnd,
            null,
            0,
            0,
            rect.w,
            rect.h,
            win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
        ),
        .split => {},
    }
}

/// Replace the split tree, releasing the old one.
pub fn replaceTree(self: *Tab, tree: Surface.Tree) void {
    self.tree.deinit();
    self.tree = tree;
    self.layout();
}

/// Take a surface out of the tab. Focus moves to a neighbour; a tab left
/// without surfaces is removed from its window.
pub fn removeSurface(self: *Tab, s: *Surface) void {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(s) orelse return;

    if (self.focused == s) {
        self.focused = null;
        if (focusAfterRemove(Surface.Tree, &self.tree, at, alloc) catch null) |h| {
            switch (self.tree.nodes[h.idx()]) {
                .leaf => |v| self.focused = v,
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
    self.replaceTree(new_tree);
    self.focus();
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
