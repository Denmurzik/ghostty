//! A top-level Win32 window. It owns a list of tabs; the active one is a
//! container child window below the tab strip, holding a split tree of
//! surfaces.
const Window = @This();

const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Overrides = @import("Overrides.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabStrip = @import("TabStrip.zig");
const dialogs = @import("dialogs.zig");
const dpi_mod = @import("dpi.zig");
const drop = @import("drop.zig");
const frame_mod = @import("frame.zig");
const geom = @import("geom.zig");
const placement_mod = @import("placement.zig");
const resize_overlay = @import("resize_overlay.zig");
const strip_input_mod = @import("strip_input.zig");
const taskbar_mod = @import("taskbar.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
const default_title = "Ghostty";

/// `wparam` of a WM_CLOSE whose confirmation has already been taken care
/// of. A WM_CLOSE from the system (close button, Alt+F4) carries zero.
const close_confirmed_wparam: usize = 1;

/// Source of `id`, for log correlation and IPC.
var next_id: std.atomic.Value(u32) = .init(1);

pub const CreateOptions = struct {
    parent: ?*CoreSurface = null,
    overrides: Overrides = .none,
    first_tab: bool = true,
};

hwnd: win32.foundation.HWND,
app: *App,
id: u32,

tabs: std.ArrayList(*Tab) = .empty,
active_tab: usize = 0,

/// The window's DPI, the single source of it: read once at creation, then
/// only by WM_DPICHANGED.
dpi: u32 = dpi_mod.default_dpi,

/// A title set by the user; wins over the active tab's title.
title_override: ?[:0]u8 = null,

strip: TabStrip.Layout = .{},
strip_input: strip_input_mod.State = .{},
frame: frame_mod.State = .{},
placement: placement_mod.State = .{},
taskbar: taskbar_mod.State = .{},
overlay: resize_overlay.State = .{},

/// Client-area limits reported by core, if any. Applied by
/// WM_GETMINMAXINFO.
size_limit: ?apprt.action.SizeLimit = null,

/// Size of one grid cell in pixels, as last reported by core.
cell_size: ?apprt.action.CellSize = null,

/// True while the "close anyway?" dialog is up, so that further close
/// requests do not stack more dialogs.
confirming_close: bool = false,

/// True once a close was confirmed and is under way.
close_confirmed: bool = false,

/// Create a hidden top-level window and register it with the app. With
/// `first_tab` it hosts a new tab; call `show` once its content is ready.
pub fn create(app: *App, opts: CreateOptions) !*Window {
    const alloc = app.core_app.alloc;

    try util.registerClass(&.{
        .style = win32.user32.CS_HREDRAW | win32.user32.CS_VREDRAW | win32.user32.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .hIcon = win32.user32.LoadIconW(null, win32.user32.IDI_APPLICATION),
        .hCursor = win32.user32.LoadCursorW(null, win32.user32.IDC_ARROW),
        // Black rather than the default white so a dark terminal does not
        // flash white before the first frame.
        .hbrBackground = @ptrCast(win32.gdi32.GetStockObject(win32.gdi32.BLACK_BRUSH)),
        .lpszClassName = class_name,
    });

    const self = try alloc.create(Window);
    self.* = .{
        .hwnd = undefined,
        .app = app,
        .id = next_id.fetchAdd(1, .monotonic),
    };

    if (opts.overrides.title) |t| self.title_override = alloc.dupeSentinel(u8, t, 0) catch |err| {
        alloc.destroy(self);
        return err;
    };

    // Registered with the app up front so the WM_DESTROY handler can
    // remove it unconditionally.
    app.windows.append(alloc, self) catch |err| {
        if (self.title_override) |t| alloc.free(t);
        alloc.destroy(self);
        return err;
    };

    // The window procedure sees WM_NCCREATE before this returns and stores
    // `self` as the window's user data.
    const hwnd = win32.user32.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(default_title),
        win32.user32.WS_OVERLAPPEDWINDOW | win32.user32.WS_CLIPCHILDREN,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        win32.user32.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        _ = app.unregisterWindow(self);
        if (self.title_override) |t| alloc.free(t);
        alloc.destroy(self);
        return error.CreateWindowFailed;
    };
    self.hwnd = hwnd;

    // The only place besides WM_DPICHANGED that reads the system value.
    const system_dpi = win32.user32.GetDpiForWindow(hwnd);
    self.dpi = if (system_dpi == 0) dpi_mod.default_dpi else system_dpi;

    theme.applyToWindow(self);
    frame_mod.apply(self);
    drop.register(self);
    self.layout();

    if (opts.first_tab) {
        // Core's start-up actions (initial size, title, ...) reach this
        // window through the new surface's `tab`.
        _ = self.addTab(.{
            .parent = opts.parent,
            .overrides = opts.overrides,
            .context = .window,
        }) catch |err| {
            log.err("unable to create the first tab err={}", .{err});
            self.destroy();
            return err;
        };
    }

    return self;
}

/// Destroy the window and free it. Closing the last window quits the app.
pub fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;

    // Tabs go first, each taking its surfaces down before its container:
    // core teardown joins the render and IO threads and still reads
    // `window`, which must be alive until then.
    while (self.tabs.pop()) |tab| tab.destroy();

    drop.revoke(self);
    resize_overlay.deinit(&self.overlay);

    // DestroyWindow runs the WM_DESTROY handler, which unregisters us.
    _ = win32.user32.DestroyWindow(self.hwnd);

    self.strip.tabs.deinit(alloc);
    self.tabs.deinit(alloc);
    if (self.title_override) |t| alloc.free(t);
    alloc.destroy(self);
}

/// Show the window at its start-up placement.
pub fn show(self: *Window) void {
    placement_mod.applyStartup(self);
    _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_SHOW);
    _ = win32.user32.UpdateWindow(self.hwnd);
}

pub fn activeTab(self: *Window) ?*Tab {
    if (self.active_tab >= self.tabs.items.len) return null;
    return self.tabs.items[self.active_tab];
}

pub fn tabIndex(self: *const Window, tab: *const Tab) ?usize {
    for (self.tabs.items, 0..) |t, i| {
        if (t == tab) return i;
    }
    return null;
}

/// Whether the tab strip lists tabs (rather than only the new-tab button).
pub fn showTabs(self: *const Window) bool {
    return self.tabs.items.len > 1;
}

/// Create a tab with its first surface, append it and select it.
pub fn addTab(self: *Window, opts: Tab.CreateOptions) !*Tab {
    const alloc = self.app.core_app.alloc;

    const tab = try Tab.create(self, opts);
    errdefer tab.destroy();
    try self.tabs.append(alloc, tab);

    self.selectTab(self.tabs.items.len - 1);
    return tab;
}

/// Make the tab at `index` the visible one and give it the keyboard focus.
pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;

    const old = self.activeTab();
    self.active_tab = index;
    const new = self.tabs.items[index];
    if (old) |o| {
        if (o != new) o.setVisible(false);
    }

    self.layout();
    new.setVisible(true);
    new.focus();
    self.refreshTitle();
}

/// Take a tab out of the window and destroy it. The neighbour becomes
/// active; the last tab closes the window.
pub fn removeTab(self: *Window, tab: *Tab) void {
    const index = self.tabIndex(tab) orelse return;
    const was_active = index == self.active_tab;

    _ = self.tabs.orderedRemove(index);
    tab.destroy();

    if (self.tabs.items.len == 0) {
        self.active_tab = 0;
        self.requestClose();
        return;
    }

    if (was_active) {
        self.active_tab = @min(index, self.tabs.items.len - 1);
    } else if (index < self.active_tab) {
        self.active_tab -= 1;
    }
    self.selectTab(self.active_tab);
}

/// Lay out the tab strip and the active tab below it.
pub fn layout(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    const client = self.clientRect();

    const m = TabStrip.Metrics.forDpi(self.dpi);
    self.strip.compute(
        alloc,
        m,
        client.w,
        frame_mod.stripMode(self),
        self.showTabs(),
        self.tabs.items.len,
        self.active_tab,
    ) catch |err| log.warn("unable to lay out the tab strip err={}", .{err});

    if (self.activeTab()) |tab| tab.layout();
    Chrome.invalidate(self);
}

/// The client area below the tab strip, where the active tab goes.
pub fn contentRect(self: *const Window) geom.Rect {
    const client = self.clientRect();
    const top = @min(self.strip.bounds.h, client.h);
    return .{ .x = 0, .y = top, .w = client.w, .h = client.h - top };
}

fn clientRect(self: *const Window) geom.Rect {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.user32.GetClientRect(self.hwnd, &rc);
    return geom.Rect.fromRECT(rc);
}

/// Show the title of the window: the user's, else the active tab's.
pub fn refreshTitle(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    const text: []const u8 = if (self.title_override) |t|
        t
    else if (self.activeTab()) |tab|
        tab.title()
    else
        default_title;

    const wide = util.utf16z(alloc, text) catch |err| {
        log.warn("unable to convert window title err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    _ = win32.user32.SetWindowTextW(self.hwnd, wide);
}

/// Whether closing the window would kill a running process.
pub fn needsConfirmClose(self: *const Window) bool {
    for (self.tabs.items) |tab| {
        if (tab.needsConfirmClose()) return true;
    }
    return false;
}

pub fn findSurface(self: *Window, id: u32) ?*Surface {
    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.id == id) return entry.view;
        }
    }
    return null;
}

/// Close the window without asking: the caller has already confirmed, or
/// nothing needs confirming. Deferred through the message queue, so it is
/// safe to call while the window's own surface is still on the stack.
pub fn requestClose(self: *Window) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, close_confirmed_wparam, 0);
}

/// Close the window as if the user had pressed the close button: asks
/// first when a surface has a running process.
pub fn requestCloseWithConfirm(self: *Window) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, 0, 0);
}

/// Resize the window so that its content area is `width` x `height`
/// physical pixels.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    const size = windowSizeFor(
        .{ .w = clampPixels(width), .h = clampPixels(height) },
        frame_mod.nonClientSize(self),
    );
    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        size.w,
        size.h,
        win32.user32.SWP_NOMOVE | win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
}

/// The window size that leaves `content` for the terminal.
fn windowSizeFor(content: frame_mod.Size, nc: frame_mod.Size) frame_mod.Size {
    return .{ .w = content.w + nc.w, .h = content.h + nc.h };
}

/// The inverse of `windowSizeFor`.
fn contentSizeFor(window_size: frame_mod.Size, nc: frame_mod.Size) frame_mod.Size {
    return .{ .w = window_size.w - nc.w, .h = window_size.h - nc.h };
}

/// A pixel count as a signed coordinate; no real window is anywhere near
/// the limit.
fn clampPixels(v: u32) i32 {
    return @intCast(@min(v, 1 << 24));
}

/// Apply core's client-area limits to a WM_GETMINMAXINFO, adding the
/// non-client size. A zero limit leaves the system default.
fn applySizeLimit(
    info: *win32.user32.MINMAXINFO,
    limit: apprt.action.SizeLimit,
    nc: frame_mod.Size,
) void {
    if (limit.min_width > 0) info.ptMinTrackSize.x = clampPixels(limit.min_width) + nc.w;
    if (limit.min_height > 0) info.ptMinTrackSize.y = clampPixels(limit.min_height) + nc.h;
    if (limit.max_width > 0) info.ptMaxTrackSize.x = clampPixels(limit.max_width) + nc.w;
    if (limit.max_height > 0) info.ptMaxTrackSize.y = clampPixels(limit.max_height) + nc.h;
}

fn handleSize(self: *Window, wparam: win32.foundation.WPARAM) void {
    // The children never see the parent's minimize (they keep their size),
    // so occlusion is forwarded from here.
    if (wparam == win32.user32.SIZE_MINIMIZED) {
        self.setMinimized(true);
        return;
    }
    if (wparam != win32.user32.SIZE_RESTORED and wparam != win32.user32.SIZE_MAXIMIZED) return;

    self.setMinimized(false);
    self.layout();
}

/// Tell the visible surfaces whether the window is minimized.
fn setMinimized(self: *Window, minimized: bool) void {
    const tab = self.activeTab() orelse return;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const s = entry.view;
        if (s.minimized == minimized) continue;
        s.minimized = minimized;
        if (s.initialized) s.core_surface.occlusionCallback(!minimized) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }
}

/// Follow a new DPI: the window moves to the system's suggested rectangle
/// and every surface gets the new content scale.
pub fn applyDpi(self: *Window, new_dpi: u32, suggested: ?win32.foundation.RECT) void {
    self.dpi = if (new_dpi == 0) dpi_mod.default_dpi else new_dpi;

    if (suggested) |r| {
        _ = win32.user32.SetWindowPos(
            self.hwnd,
            null,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
        );
    }

    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.applyDpi();
    }
    self.layout();
}

fn handleDpiChanged(self: *Window, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) void {
    const suggested: *const win32.foundation.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    self.applyDpi(@intCast(wparam & 0xFFFF), suggested.*);
}

fn handleMinMaxInfo(self: *const Window, lparam: win32.foundation.LPARAM) void {
    const limit = self.size_limit orelse return;
    const info: *win32.user32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
    applySizeLimit(info, limit, frame_mod.nonClientSize(self));
}

fn handleClose(self: *Window, wparam: win32.foundation.WPARAM) void {
    const hwnd = self.hwnd;
    if (wparam != close_confirmed_wparam) {
        if (self.confirming_close) return;

        if (self.needsConfirmClose()) {
            self.confirming_close = true;
            const close = dialogs.confirmClose(hwnd);

            // The dialog runs a message loop: the window may have been
            // closed behind it (the shell exited), freeing `self`.
            if (util.fromUserData(Window, hwnd) == null) return;
            self.confirming_close = false;
            if (!close) return;
        }
    }

    // `self` is freed here; nothing may touch it afterwards.
    self.close_confirmed = true;
    self.destroy();
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
            const self: *Window = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            util.setUserData(hwnd, self);
        }
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(Window, hwnd) orelse
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        win32.user32.WM_CLOSE => {
            self.handleClose(wparam);
            return 0;
        },

        win32.user32.WM_SIZE => {
            self.handleSize(wparam);
            return 0;
        },

        // The drag is over: do not leave the last size waiting for the timer.
        win32.user32.WM_EXITSIZEMOVE => {
            if (self.activeTab()) |tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| entry.view.flushSize();
            }
        },

        win32.user32.WM_DPICHANGED => {
            self.handleDpiChanged(wparam, lparam);
            return 0;
        },

        win32.user32.WM_GETMINMAXINFO => {
            self.handleMinMaxInfo(lparam);
            return 0;
        },

        // Keyboard input goes to the surface, never to the frame.
        win32.user32.WM_SETFOCUS => {
            if (self.activeTab()) |tab| tab.focus();
            return 0;
        },

        win32.user32.WM_ACTIVATE => {
            if ((wparam & 0xFFFF) != win32.user32.WA_INACTIVE) self.app.last_active = self;
        },

        win32.user32.WM_DESTROY => {
            self.app.windowDestroyed(self);
            return 0;
        },

        win32.user32.WM_NCDESTROY => util.setUserData(hwnd, null),

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "win32 window: content size round-trips through nonClientSize" {
    const nc: frame_mod.Size = .{ .w = 16, .h = 39 };
    const content: frame_mod.Size = .{ .w = 800, .h = 600 };

    const outer = windowSizeFor(content, nc);
    try std.testing.expectEqual(@as(i32, 816), outer.w);
    try std.testing.expectEqual(@as(i32, 639), outer.h);

    const back = contentSizeFor(outer, nc);
    try std.testing.expectEqual(content.w, back.w);
    try std.testing.expectEqual(content.h, back.h);
}

test "win32 window: size limit adds the frame and ignores zero" {
    const nc: frame_mod.Size = .{ .w = 16, .h = 39 };
    var info: win32.user32.MINMAXINFO = std.mem.zeroes(win32.user32.MINMAXINFO);
    info.ptMinTrackSize = .{ .x = 136, .y = 39 };
    info.ptMaxTrackSize = .{ .x = 4000, .y = 3000 };

    applySizeLimit(&info, .{ .min_width = 200, .min_height = 100, .max_width = 0, .max_height = 0 }, nc);
    try std.testing.expectEqual(@as(i32, 216), info.ptMinTrackSize.x);
    try std.testing.expectEqual(@as(i32, 139), info.ptMinTrackSize.y);
    try std.testing.expectEqual(@as(i32, 4000), info.ptMaxTrackSize.x);
    try std.testing.expectEqual(@as(i32, 3000), info.ptMaxTrackSize.y);

    applySizeLimit(&info, .{ .min_width = 0, .min_height = 0, .max_width = 800, .max_height = 600 }, nc);
    try std.testing.expectEqual(@as(i32, 816), info.ptMaxTrackSize.x);
    try std.testing.expectEqual(@as(i32, 639), info.ptMaxTrackSize.y);
    try std.testing.expectEqual(@as(i32, 216), info.ptMinTrackSize.x);
}
