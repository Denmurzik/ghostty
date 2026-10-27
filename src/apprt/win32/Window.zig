//! A top-level Win32 window. It owns a list of tabs; the active one is a
//! container child window below the tab strip, holding a split tree of
//! surfaces.
const Window = @This();

const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const CommandPalette = @import("CommandPalette.zig");
const Chrome = @import("Chrome.zig");
const Overrides = @import("Overrides.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabStrip = @import("TabStrip.zig");
const bell = @import("bell.zig");
const composition_mod = @import("composition.zig");
const dialogs = @import("dialogs.zig");
const dpi_mod = @import("dpi.zig");
const drop = @import("drop.zig");
const frame_mod = @import("frame.zig");
const geom = @import("geom.zig");
const hooks_mod = @import("hooks.zig");
const overlay_mod = @import("overlay.zig");
const placement_mod = @import("placement.zig");
const resize_overlay = @import("resize_overlay.zig");
const strip_input_mod = @import("strip_input.zig");
const taskbar_mod = @import("taskbar.zig");
const theme = @import("theme.zig");
const title_edit = @import("title_edit.zig");
const util = @import("util.zig");

const messages = @import("messages.zig");

const log = std.log.scoped(.win32_window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// `ID_ICON_GHOSTTY` in `dist/windows/ghostty.rc`.
const icon_resource_id = 1;
const default_title = "Ghostty";

/// A feature module's window message handler: a non-null result ends the
/// message's processing.
pub const Hook = *const fn (
    *Window,
    u32,
    win32.foundation.WPARAM,
    win32.foundation.LPARAM,
) ?win32.foundation.LRESULT;

/// The feature hooks, in dispatch order. Each one sees a message before
/// the window's own cases.
const hooks = [_]Hook{
    hooks_mod.windowMessage,
    frame_mod.handle,
    strip_input_mod.handle,
    theme.handle,
    taskbar_mod.handle,
    drop.handle,
};

/// What the window is for: the quick terminal is a window of its own kind.
pub const Kind = enum { normal, quick };

/// What `WM_GHOSTTY_CLOSE_TAB` closes (wparam), relative to the tab whose
/// id is in lparam.
pub const CloseTabMode = enum(usize) { this, other, right };

pub const CloseDecision = enum { close, ask };

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

/// The working directory last reported by one of the window's surfaces,
/// kept for `window-subtitle`.
pwd: ?[:0]u8 = null,

strip: TabStrip.Layout = .{},
strip_input: strip_input_mod.State = .{},
frame: frame_mod.State = .{},
placement: placement_mod.State = .{},
taskbar: taskbar_mod.State = .{},
overlay: resize_overlay.State = .{},

/// M3 feature state, one field per feature module.
kind: Kind = .normal,
overlays: overlay_mod.WindowState = .{},
palette: CommandPalette.State = .{},
composition: composition_mod.WindowState = .{},

/// Client-area limits reported by core, if any. Applied by
/// WM_GETMINMAXINFO.
size_limit: ?apprt.action.SizeLimit = null,

/// Size of one grid cell in pixels, as last reported by core.
cell_size: ?apprt.action.CellSize = null,

/// True while the "close anyway?" dialog is up, so that further close
/// requests do not stack more dialogs.
confirming_close: bool = false,

/// True while `beginTeardown` runs. It answers sent messages between
/// surfaces (see `util.serviceSentMessages`); those must not act on a
/// window whose tabs are half gone.
tearing_down: bool = false,

/// True once closing the window was confirmed: the next WM_CLOSE goes
/// through without asking.
close_confirmed: bool = false,

/// Create a hidden top-level window and register it with the app. With
/// `first_tab` it hosts a new tab; call `show` once its content is ready.
pub fn create(app: *App, opts: CreateOptions) !*Window {
    const alloc = app.core_app.alloc;

    try util.registerClass(&.{
        .style = win32.user32.CS_HREDRAW | win32.user32.CS_VREDRAW | win32.user32.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .hIcon = loadClassIcon(app.hinstance),
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
        frame_mod.windowStyle(frame_mod.decorationsFor(app.config.@"window-decoration")),
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

    const parent_window: ?*Window = if (opts.parent) |core| app.windowFor(core) else null;
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
        // Core's `initial_size` has set the size by now.
        self.placeInitial(parent_window);
    }

    return self;
}

/// The icon of the exe (resource 1); the generic one when the binary
/// carries no resources (tests).
fn loadClassIcon(hinstance: win32.foundation.HINSTANCE) ?win32.user32.HICON {
    const id: *const anyopaque = @ptrFromInt(icon_resource_id);
    return win32.user32.LoadIconW(hinstance, id) orelse
        win32.user32.LoadIconW(null, win32.user32.IDI_APPLICATION);
}

/// Where a cascaded window goes: the parent's origin moved by `step` on
/// both axes, back to the work area's origin once that would push the
/// window past its right or bottom edge.
pub fn cascadeOrigin(
    parent: geom.Rect,
    work: geom.Rect,
    step: i32,
    size: struct { w: i32, h: i32 },
) struct { x: i32, y: i32 } {
    const x = parent.x + step;
    const y = parent.y + step;
    if (x + size.w > work.right() or y + size.h > work.bottom()) return .{ .x = work.x, .y = work.y };
    return .{ .x = x, .y = y };
}

/// Position a new window. The first one goes where `window-position-x/y`
/// say (the system picks otherwise); later ones cascade by the caption
/// height from `parent`, else from the window that was active last.
pub fn placeInitial(self: *Window, parent: ?*Window) void {
    const user32 = win32.user32;
    const anchor = parent orelse self.app.last_active;
    if (anchor == null or anchor.? == self) {
        const x = self.app.config.@"window-position-x" orelse return;
        const y = self.app.config.@"window-position-y" orelse return;
        _ = user32.SetWindowPos(self.hwnd, null, x, y, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
        return;
    }
    const a = anchor.?;

    // A maximized, minimized or fullscreen anchor cascades from where it
    // would be restored to.
    var placed: user32.WINDOWPLACEMENT = .{};
    var rc: win32.foundation.RECT = undefined;
    const restored = user32.IsZoomed(a.hwnd) != 0 or user32.IsIconic(a.hwnd) != 0 or a.placement.fullscreen;
    if (restored) {
        if (user32.GetWindowPlacement(a.hwnd, &placed) == 0) return;
        rc = placed.rcNormalPosition;
    } else if (user32.GetWindowRect(a.hwnd, &rc) == 0) return;

    const monitor = user32.MonitorFromWindow(a.hwnd, user32.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: user32.MONITORINFO = .{};
    if (user32.GetMonitorInfoW(monitor, &info) == 0) return;

    // The placement is in workspace coordinates (origin at the work area),
    // everything else in screen coordinates.
    if (restored) {
        const dx = info.rcWork.left - info.rcMonitor.left;
        const dy = info.rcWork.top - info.rcMonitor.top;
        rc = .{ .left = rc.left + dx, .top = rc.top + dy, .right = rc.right + dx, .bottom = rc.bottom + dy };
    }

    var own: win32.foundation.RECT = undefined;
    if (user32.GetWindowRect(self.hwnd, &own) == 0) return;
    // The wrap test needs the visible edge: the shadow border of a
    // top-level window is part of its rectangle but not of what is seen.
    var visible: win32.foundation.RECT = own;
    _ = win32.dwmapi.DwmGetWindowAttribute(self.hwnd, win32.dwmapi.DWMWA_EXTENDED_FRAME_BOUNDS, &visible, @sizeOf(win32.foundation.RECT));

    const origin = cascadeOrigin(
        geom.Rect.fromRECT(rc),
        geom.Rect.fromRECT(info.rcWork),
        user32.GetSystemMetricsForDpi(user32.SM_CYCAPTION, a.dpi),
        .{ .w = visible.right - own.left, .h = visible.bottom - own.top },
    );
    _ = user32.SetWindowPos(self.hwnd, null, origin.x, origin.y, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
}

/// Destroy the window and free it. Closing the last window quits the app.
pub fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;

    self.beginTeardown();

    drop.revoke(self);
    title_edit.cancel(self);
    resize_overlay.deinit(&self.overlay);

    // DestroyWindow runs the WM_DESTROY handler, which unregisters us.
    _ = win32.user32.DestroyWindow(self.hwnd);

    self.strip.tabs.deinit(alloc);
    self.tabs.deinit(alloc);
    if (self.title_override) |t| alloc.free(t);
    if (self.pwd) |p| alloc.free(p);
    alloc.destroy(self);
}

/// Hide the window, then take the tabs down. Joining the render and IO
/// threads of a big split tree takes a while; the window must not sit on
/// screen, frozen, meanwhile. Tabs go first, each taking its surfaces down
/// before its container: core teardown still reads `window`, which must
/// be alive until then.
pub fn beginTeardown(self: *Window) void {
    const was = self.tearing_down;
    self.tearing_down = true;
    defer self.tearing_down = was;

    _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_HIDE);
    for (self.tabs.items) |tab| tab.stopRenderThreads();
    for (self.tabs.items) |tab| tab.stopIoThreads();
    while (self.tabs.pop()) |tab| tab.destroy();
}

/// Show the window at its start-up placement.
pub fn show(self: *Window) void {
    placement_mod.applyStartup(self);
    self.showPlain();
}

/// Show the window as it is: no `maximize` / `fullscreen` of the config.
pub fn showPlain(self: *Window) void {
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
    return showTabsFor(self.app.config.@"window-show-tab-bar", self.tabs.items.len);
}

/// `window-show-tab-bar` applied to a tab count.
pub fn showTabsFor(setting: configpkg.Config.WindowShowTabBar, count: usize) bool {
    return switch (setting) {
        .always => true,
        .never => false,
        .auto => count > 1,
    };
}

/// Where a new tab goes: after the active one, or at the end.
pub fn newTabIndex(
    position: configpkg.Config.WindowNewTabPosition,
    active: usize,
    count: usize,
) usize {
    return switch (position) {
        .current => @min(active + 1, count),
        .end => count,
    };
}

/// The index a `goto_tab` target selects, or null when the selection does
/// not change. Same semantics as the GTK window's `selectTab`: numbers are
/// 1-based and clamp to the last tab.
pub fn gotoIndex(target: apprt.action.GotoTab, current: usize, count: usize) ?usize {
    if (count == 0) return null;
    const goto: usize = switch (target) {
        .previous => if (current > 0) current - 1 else count - 1,
        .next => if (current < count - 1) current + 1 else 0,
        .last => count - 1,
        _ => n: {
            const v = @backingInt(target);
            if (v <= 0) return null;
            break :n @min(@as(usize, @intCast(v)) - 1, count - 1);
        },
    };
    if (goto == current) return null;
    return goto;
}

/// The index a tab at `current` lands on when moved by `amount`, wrapping
/// around the ends like the GTK window's `moveTab`; null with fewer than
/// two tabs.
pub fn moveIndex(amount: isize, current: usize, count: usize) ?usize {
    if (count <= 1) return null;
    const total: isize = @intCast(count);
    const initial = @as(isize, @intCast(current)) +| amount;
    return @intCast(@mod(initial, total));
}

/// Create a tab with its first surface, insert it where
/// `window-new-tab-position` says and select it. The error set is spelled
/// out: creating a surface can perform `new_tab`, which calls back here.
pub fn addTab(self: *Window, opts: Tab.CreateOptions) anyerror!*Tab {
    const alloc = self.app.core_app.alloc;

    const tab = try Tab.create(self, opts);
    errdefer tab.destroy();
    const index = newTabIndex(
        self.app.config.@"window-new-tab-position",
        self.active_tab,
        self.tabs.items.len,
    );
    try self.tabs.insert(alloc, index, tab);

    self.selectTab(index);
    return tab;
}

/// Move the tab at `from` to `to`; the active tab stays the same tab.
pub fn moveTab(self: *Window, from: usize, to: usize) void {
    const count = self.tabs.items.len;
    if (from >= count or to >= count or from == to) return;

    const active = self.activeTab();
    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
    if (active) |a| self.active_tab = self.tabIndex(a) orelse self.active_tab;

    self.layout();
}

/// Make the tab at `index` the visible one and give it the keyboard focus.
pub fn selectTab(self: *Window, index: usize) void {
    self.selectTabFocus(index, true);
}

/// `selectTab`, optionally without the focus move: `SetFocus` on a child of
/// a background window activates that window.
pub fn selectTabFocus(self: *Window, index: usize, focus: bool) void {
    if (index >= self.tabs.items.len) return;

    const old = self.activeTab();
    self.active_tab = index;
    const new = self.tabs.items[index];
    if (old) |o| {
        if (o != new) o.setVisible(false);
    }

    self.layout();
    // A DPI change while the tab was hidden left its size stale.
    {
        var it = new.tree.iterator();
        while (it.next()) |entry| entry.view.flushSize();
    }
    new.setVisible(true);
    if (focus) new.focus();
    self.refreshTitle();
}

/// Unlink a tab from the list and keep `active_tab` pointing at the right
/// one. False if no tab is left.
fn unlinkTab(self: *Window, tab: *Tab) bool {
    const index = self.tabIndex(tab) orelse return self.tabs.items.len != 0;
    const was_active = index == self.active_tab;
    title_edit.cancelForTab(self, tab);

    _ = self.tabs.orderedRemove(index);

    if (self.tabs.items.len == 0) {
        self.active_tab = 0;
        return false;
    }

    if (was_active) {
        self.active_tab = @min(index, self.tabs.items.len - 1);
    } else if (index < self.active_tab) {
        self.active_tab -= 1;
    }
    return true;
}

/// Take a tab out of the window and destroy it. The neighbour becomes
/// active; the last tab closes the window.
pub fn removeTab(self: *Window, tab: *Tab) void {
    if (self.tabIndex(tab) == null) return;

    // `Tab.destroy` answers sent messages; none may close this window
    // while it is in between two tabs.
    const was = self.tearing_down;
    self.tearing_down = true;
    defer self.tearing_down = was;

    if (!self.unlinkTab(tab)) {
        // Hidden first, like `beginTeardown`: the thread joins take a while.
        _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_HIDE);
        tab.destroy();
        self.requestClose(true);
        return;
    }

    // The neighbour is on screen before the thread joins of the old tab
    // begin, so the window never shows a hole.
    self.selectTab(self.active_tab);
    tab.destroy();
}

/// Take a tab out of the window without destroying it (it goes to another
/// window). The neighbour becomes active; the caller keeps the window from
/// ending up empty.
pub fn detachTab(self: *Window, tab: *Tab) void {
    if (self.tabIndex(tab) == null) return;
    if (!self.unlinkTab(tab)) return;
    const foreground = win32.user32.GetForegroundWindow();
    self.selectTabFocus(self.active_tab, foreground != null and foreground.? == self.hwnd);
}

/// Move `tab` into a new window of the same content size, cascaded from
/// this one. Null if the window has only this tab.
pub fn moveTabToNewWindow(self: *Window, tab: *Tab) !?*Window {
    const alloc = self.app.core_app.alloc;
    if (self.tabs.items.len < 2 or self.tabIndex(tab) == null) return null;

    const new = try create(self.app, .{ .first_tab = false });
    errdefer new.destroy();
    try new.tabs.ensureTotalCapacity(alloc, 1);

    // Position first: the window starts on the primary monitor, and moving
    // it to the source's monitor may change its DPI (WM_DPICHANGED is
    // handled before this returns). Only then is the size known, and the
    // cascade is checked against it.
    new.placeInitial(self);
    const content = self.contentRect();
    const scaled_w: i32 = @intCast(@divTrunc(@as(i64, content.w) * new.dpi, self.dpi));
    const scaled_h: i32 = @intCast(@divTrunc(@as(i64, content.h) * new.dpi, self.dpi));
    const size = windowSizeFor(.{ .w = scaled_w, .h = scaled_h }, frame_mod.nonClientSize(new));
    _ = win32.user32.SetWindowPos(
        new.hwnd,
        null,
        0,
        0,
        size.w,
        size.h,
        win32.user32.SWP_NOMOVE | win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
    new.placeInitial(self);

    self.detachTab(tab);
    tab.setWindow(new);
    new.tabs.appendAssumeCapacity(tab);
    new.selectTabFocus(0, false);
    new.showPlain();
    new.activate();
    return new;
}

/// Put a detached tab into this window at `index` (clamped) and select it.
/// The tab's `setWindow` has run; the caller reserved room with
/// `tabs.ensureUnusedCapacity`.
pub fn insertTab(self: *Window, tab: *Tab, index: usize) void {
    self.tabs.insertAssumeCapacity(@min(index, self.tabs.items.len), tab);
    self.selectTabFocus(self.tabIndex(tab) orelse 0, false);
}

/// A hidden window for a torn-off tab, `size` (outer, pixels at
/// `source_dpi`) scaled to the DPI of the monitor `origin` is on. Call
/// `showPlain` once the tab is in.
pub fn createForTearOff(
    app: *App,
    origin: struct { x: i32, y: i32 },
    source: *const Window,
) !*Window {
    const alloc = app.core_app.alloc;
    const new = try create(app, .{ .first_tab = false });
    errdefer new.destroy();
    try new.tabs.ensureTotalCapacity(alloc, 1);

    // Position first: moving to another monitor may change the DPI
    // (WM_DPICHANGED is handled before SetWindowPos returns).
    _ = win32.user32.SetWindowPos(
        new.hwnd,
        null,
        origin.x,
        origin.y,
        0,
        0,
        win32.user32.SWP_NOSIZE | win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
    const content = source.contentRect();
    const scaled_w: i32 = @intCast(@divTrunc(@as(i64, content.w) * new.dpi, source.dpi));
    const scaled_h: i32 = @intCast(@divTrunc(@as(i64, content.h) * new.dpi, source.dpi));
    const size = windowSizeFor(.{ .w = scaled_w, .h = scaled_h }, frame_mod.nonClientSize(new));
    _ = win32.user32.SetWindowPos(
        new.hwnd,
        null,
        origin.x,
        origin.y,
        size.w,
        size.h,
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
    return new;
}

/// Bring the window to the front, restoring it if minimized, and give the
/// active tab the keyboard focus once it is the foreground window.
pub fn activate(self: *Window) void {
    if (win32.user32.IsIconic(self.hwnd) != 0) _ = win32.user32.ShowWindow(self.hwnd, win32.user32.SW_RESTORE);
    _ = win32.user32.SetForegroundWindow(self.hwnd);
    const foreground = win32.user32.GetForegroundWindow();
    if (foreground != null and foreground.? == self.hwnd) {
        if (self.activeTab()) |tab| tab.focus();
    }
}

/// Take every window of the app down, asking once if a process is running
/// somewhere. Runs from the message loop, like the other confirmations.
fn handleCloseAll(self: *Window) void {
    const app = self.app;
    var needs = false;
    for (app.windows.items) |w| {
        if (w.needsConfirmClose()) needs = true;
    }
    if (needs and !(self.askClose(.all_windows) orelse return)) return;

    // The question ran a message loop: look at the windows afresh.
    const alloc = app.core_app.alloc;
    const all = alloc.dupe(*Window, app.windows.items) catch |err| {
        log.warn("unable to close all windows err={}", .{err});
        return;
    };
    defer alloc.free(all);
    for (all) |w| {
        w.beginTeardown();
        w.requestClose(true);
    }
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

    const decorated: ?[:0]u8 = if (self.activeTab()) |tab|
        bell.decorateTitle(alloc, text, tab) catch |err| blk: {
            log.warn("unable to decorate window title err={}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (decorated) |d| alloc.free(d);

    const wide = util.utf16z(alloc, decorated orelse text) catch |err| {
        log.warn("unable to convert window title err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    _ = win32.user32.SetWindowTextW(self.hwnd, wide);

    // The strip shows the tab titles.
    Chrome.invalidate(self);
}

/// A surface got a new title: the caption follows when it is the one the
/// active tab shows, otherwise only the strip needs a repaint.
pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    if (self.activeTab()) |tab| {
        if (tab == surface.tab and tab.focusedSurface() == surface) {
            self.refreshTitle();
            return;
        }
    }
    Chrome.invalidate(self);
}

/// Set (or, when empty, clear) the window's own title.
pub fn setTitleOverride(self: *Window, title: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]u8 = if (title.len == 0) null else try alloc.dupeSentinel(u8, title, 0);
    if (self.title_override) |old| alloc.free(old);
    self.title_override = copy;
    self.refreshTitle();
}

/// Set (or, when empty, clear) the user's title of a tab.
pub fn setTabTitle(self: *Window, tab: *Tab, title: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]u8 = if (title.len == 0) null else try alloc.dupeSentinel(u8, title, 0);
    if (tab.title_override) |old| alloc.free(old);
    tab.title_override = copy;
    self.refreshTitle();
}

/// Remember the working directory a surface reported.
pub fn setPwd(self: *Window, pwd: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, pwd, 0);
    if (self.pwd) |old| alloc.free(old);
    self.pwd = copy;
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

/// Close the window through the message queue, so it is safe to call
/// while the window's own surface is still on the stack. With `confirmed`
/// the caller has already taken care of any question; otherwise the
/// WM_CLOSE handler asks when a surface has a running process. The flag is
/// window state, not a message parameter: nothing else can post a
/// pre-confirmed close.
pub fn requestClose(self: *Window, confirmed: bool) void {
    if (confirmed) self.close_confirmed = true;
    _ = win32.user32.PostMessageW(self.hwnd, win32.user32.WM_CLOSE, 0, 0);
}

/// Close the window as if the user had pressed the close button.
pub fn requestCloseWithConfirm(self: *Window) void {
    self.requestClose(false);
}

/// Whether a close goes ahead or has to ask first.
pub fn closeDecision(confirmed: bool, needs_confirm: bool) CloseDecision {
    if (confirmed or !needs_confirm) return .close;
    return .ask;
}

/// Whether the tab at index `i` is closed by `mode` with the anchor tab
/// at index `anchor`.
fn closeModeMatches(mode: CloseTabMode, anchor: usize, i: usize) bool {
    return switch (mode) {
        .this => i == anchor,
        .other => i != anchor,
        .right => i > anchor,
    };
}

fn findTab(self: *const Window, id: u32) ?*Tab {
    for (self.tabs.items) |tab| {
        if (tab.id == id) return tab;
    }
    return null;
}

/// The first tab `mode` closes with the anchor tab `anchor_id`; null once
/// none is left or the anchor is gone.
fn nextCloseTarget(self: *const Window, mode: CloseTabMode, anchor_id: u32) ?*Tab {
    const anchor = self.tabIndex(self.findTab(anchor_id) orelse return null) orelse return null;
    for (self.tabs.items, 0..) |tab, i| {
        if (closeModeMatches(mode, anchor, i)) return tab;
    }
    return null;
}

fn closeTargetsNeedConfirm(self: *const Window, mode: CloseTabMode, anchor_id: u32) bool {
    const anchor = self.tabIndex(self.findTab(anchor_id) orelse return false) orelse return false;
    for (self.tabs.items, 0..) |tab, i| {
        if (closeModeMatches(mode, anchor, i) and tab.needsConfirmClose()) return true;
    }
    return false;
}

/// Run `list` over a message; the first non-null result wins and later
/// hooks do not see the message.
fn runHooks(
    window: *Window,
    list: []const Hook,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    for (list) |hook| {
        if (hook(window, msg, wparam, lparam)) |result| return result;
    }
    return null;
}

/// Resize the window so that its content area is `width` x `height`
/// physical pixels.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    self.placement.initial_size = .{ .width = width, .height = height };
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
pub fn windowSizeFor(content: frame_mod.Size, nc: frame_mod.Size) frame_mod.Size {
    return .{ .w = content.w + nc.w, .h = content.h + nc.h };
}

/// The inverse of `windowSizeFor`.
pub fn contentSizeFor(window_size: frame_mod.Size, nc: frame_mod.Size) frame_mod.Size {
    return .{ .w = window_size.w - nc.w, .h = window_size.h - nc.h };
}

/// A pixel count as a signed coordinate; no real window is anywhere near
/// the limit.
pub fn clampPixels(v: u32) i32 {
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
        hooks_mod.windowChanged(self, .minimized);
        return;
    }
    if (wparam != win32.user32.SIZE_RESTORED and wparam != win32.user32.SIZE_MAXIMIZED) return;

    self.setMinimized(false);
    self.layout();
    // SIZE_RESTORED also ends a maximize: features treat `.restored` as idempotent.
    if (wparam == win32.user32.SIZE_RESTORED) hooks_mod.windowChanged(self, .restored);
    hooks_mod.windowChanged(self, .sized);
}

/// Tell the active tab whether the window is minimized (its surfaces are
/// occluded then).
fn setMinimized(self: *Window, minimized: bool) void {
    const tab = self.activeTab() orelse return;
    tab.applyOcclusion(!minimized);
}

/// Follow a new DPI. Every surface of every tab gets the new content scale
/// first, so the size the move produces is already computed with it; then
/// the window moves to the system's suggested rectangle (or one computed
/// from its client size without a suggestion). Hidden surfaces get the
/// scale now and their size when their tab is shown.
pub fn applyDpi(self: *Window, new_dpi: u32, suggested: ?win32.foundation.RECT) void {
    const old_dpi = self.dpi;
    const iconic = win32.user32.IsIconic(self.hwnd) != 0;
    // The content size at the old DPI, before the frame metrics change.
    const old_nc = frame_mod.nonClientSize(self);
    self.dpi = if (new_dpi == 0) dpi_mod.default_dpi else new_dpi;

    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.applyDpi();
    }

    const zoomed = win32.user32.IsZoomed(self.hwnd) != 0;
    if (self.placement.fullscreen) {
        // The suggested rectangle is for a windowed frame; a fullscreen
        // window keeps covering its (possibly new) monitor. The saved
        // placement restores logically on that monitor when fullscreen ends.
        placement_mod.coverMonitor(self);
    } else if (zoomed) {
        self.refitMaximized();
    } else if (!iconic) {
        if (suggested) |r| {
            self.setOuterRect(geom.Rect.fromRECT(r));
        } else if (old_dpi != self.dpi) {
            var rc: win32.foundation.RECT = undefined;
            if (win32.user32.GetWindowRect(self.hwnd, &rc) != 0) {
                const outer = geom.Rect.fromRECT(rc);
                const content = dpi_mod.scaledWindowRect(
                    .{ .x = outer.x, .y = outer.y, .w = outer.w - old_nc.w, .h = outer.h - old_nc.h },
                    old_dpi,
                    self.dpi,
                );
                const size = windowSizeFor(.{ .w = content.w, .h = content.h }, frame_mod.nonClientSize(self));
                self.setOuterRect(.{ .x = outer.x, .y = outer.y, .w = size.w, .h = size.h });
            }
        }
    }

    self.layout();
    // Core gets the scale and the new size in this tick.
    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.flushSize();
    }
    hooks_mod.windowChanged(self, .dpi);
}

fn setOuterRect(self: *Window, r: geom.Rect) void {
    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        r.x,
        r.y,
        r.w,
        r.h,
        win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
}

/// Fit a maximized window to the work area of the monitor it is on now,
/// keeping it maximized: the frame overhangs the work area as the system
/// does it.
fn refitMaximized(self: *Window) void {
    const monitor = win32.user32.MonitorFromWindow(self.hwnd, win32.user32.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: win32.user32.MONITORINFO = .{};
    if (win32.user32.GetMonitorInfoW(monitor, &info) == 0) return;
    const ins = frame_mod.frameInsets(self.dpi, true, self.frame.decorations);
    const w = info.rcWork;
    _ = win32.user32.SetWindowPos(
        self.hwnd,
        null,
        w.left - ins.left,
        w.top - ins.top,
        (w.right - w.left) + ins.left + ins.right,
        (w.bottom - w.top) + ins.top + ins.bottom,
        win32.user32.SWP_FRAMECHANGED | win32.user32.SWP_NOZORDER | win32.user32.SWP_NOACTIVATE,
    );
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

/// Ask `kind`'s question unless a dialog is up already. Null: another
/// dialog is up, nothing is asked. False: the answer was "no", or the
/// window went away behind the dialog (its message loop keeps running), in
/// which case `self` must not be touched again. The caller re-checks what
/// it meant to close.
fn askClose(self: *Window, kind: dialogs.CloseKind) ?bool {
    if (self.confirming_close) return null;

    const hwnd = self.hwnd;
    self.confirming_close = true;
    const yes = dialogs.confirmCloseKind(hwnd, kind);
    if (util.fromUserData(Window, hwnd) != self) return false;
    self.confirming_close = false;
    return yes;
}

fn handleClose(self: *Window) void {
    // A confirmation only covers the tabs the window had: one added since
    // is asked about.
    const confirmed = self.close_confirmed and self.tabs.items.len == 0;
    if (closeDecision(confirmed, self.needsConfirmClose()) == .ask) {
        if (!(self.askClose(.window) orelse return)) return;
    }

    // `self` is freed here; nothing may touch it afterwards.
    self.close_confirmed = true;
    self.destroy();
}

fn handleCloseSurface(self: *Window, id: u32, process_active: bool) void {
    // The surface's tab may have moved to another window since the close
    // was posted.
    var surface = self.findSurface(id) orelse {
        for (self.app.windows.items) |w| {
            if (w == self or w.findSurface(id) == null) continue;
            _ = win32.user32.PostMessageW(w.hwnd, messages.WM_GHOSTTY_CLOSE_SURFACE, id, @intFromBool(process_active));
            break;
        }
        return;
    };

    if (closeDecision(false, process_active) == .ask) {
        const kind: dialogs.CloseKind = if (!surface.tab.tree.isSplit())
            (if (self.tabs.items.len == 1) .window else .tab)
        else
            .surface;
        if (!(self.askClose(kind) orelse return)) return;
        // Closed behind the dialog (the shell exited).
        surface = self.findSurface(id) orelse return;
    }
    surface.tab.removeSurface(surface);
}

fn handleCloseTab(self: *Window, mode: CloseTabMode, anchor_id: u32) void {
    if (self.nextCloseTarget(mode, anchor_id) == null) {
        // The anchor tab may have moved to another window since the close
        // was posted. (A mode other than `this` is posted by the user's
        // click on a live window and is not forwarded.)
        if (mode != .this) return;
        for (self.app.windows.items) |w| {
            if (w == self or w.findTab(anchor_id) == null) continue;
            _ = win32.user32.PostMessageW(w.hwnd, messages.WM_GHOSTTY_CLOSE_TAB, @backingInt(mode), @as(isize, anchor_id));
            break;
        }
        return;
    }

    if (closeDecision(false, self.closeTargetsNeedConfirm(mode, anchor_id)) == .ask) {
        if (!(self.askClose(.tab) orelse return)) return;
    }

    // Targets are looked up afresh each round. Closing the last tab posts
    // the window's close; the loop ends as the tab list empties.
    while (self.nextCloseTarget(mode, anchor_id)) |tab| self.removeTab(tab);
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

    // Reached from `serviceSentMessages` mid-teardown: nothing may act on
    // the tabs, or close the window a second time.
    if (self.tearing_down) {
        // DefWindowProc would destroy the window behind the teardown.
        if (msg == win32.user32.WM_CLOSE) return 0;
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    if (runHooks(self, &hooks, msg, wparam, lparam)) |result| return result;

    switch (msg) {
        win32.user32.WM_CLOSE => {
            self.handleClose();
            return 0;
        },

        messages.WM_GHOSTTY_CLOSE_SURFACE => {
            self.handleCloseSurface(@truncate(wparam), lparam != 0);
            return 0;
        },

        messages.WM_GHOSTTY_CLOSE_ALL => {
            self.handleCloseAll();
            return 0;
        },

        messages.WM_GHOSTTY_CLOSE_TAB => {
            const mode = std.enums.fromInt(CloseTabMode, wparam) orelse return 0;
            self.handleCloseTab(mode, @truncate(@as(usize, @bitCast(lparam))));
            return 0;
        },

        win32.user32.WM_PAINT => {
            var ps: win32.user32.PAINTSTRUCT = undefined;
            if (win32.user32.BeginPaint(hwnd, &ps)) |hdc| {
                Chrome.paint(self, hdc, geom.Rect.fromRECT(ps.rcPaint));
                _ = win32.user32.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        win32.user32.WM_MOVE => hooks_mod.windowChanged(self, .moved),

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
            const active = (wparam & 0xFFFF) != win32.user32.WA_INACTIVE;
            if (active) self.app.last_active = self;
            hooks_mod.windowChanged(self, if (active) .activated else .deactivated);
        },

        win32.user32.WM_DESTROY => {
            hooks_mod.windowChanged(self, .destroying);
            self.app.windowDestroyed(self);
            return 0;
        },

        win32.user32.WM_NCDESTROY => util.setUserData(hwnd, null),

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "win32 window: cascade wraps inside the work area" {
    const work: geom.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };

    const a = cascadeOrigin(.{ .x = 100, .y = 80, .w = 800, .h = 600 }, work, 31, .{ .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(i32, 131), a.x);
    try std.testing.expectEqual(@as(i32, 111), a.y);

    // Past the bottom edge: back to the origin of the work area.
    const b = cascadeOrigin(.{ .x = 100, .y = 450, .w = 800, .h = 600 }, work, 31, .{ .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(i32, 0), b.x);
    try std.testing.expectEqual(@as(i32, 0), b.y);

    // Past the right edge, on a work area that does not start at 0.
    const off: geom.Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1040 };
    const c = cascadeOrigin(.{ .x = -500, .y = 10, .w = 800, .h = 600 }, off, 31, .{ .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(i32, -1920), c.x);
    try std.testing.expectEqual(@as(i32, 0), c.y);

    // Exactly fitting still cascades.
    const d = cascadeOrigin(.{ .x = 1089, .y = 0, .w = 800, .h = 600 }, work, 31, .{ .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(i32, 1120), d.x);
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

test "win32 window: close decision" {
    try std.testing.expectEqual(CloseDecision.close, closeDecision(true, true));
    try std.testing.expectEqual(CloseDecision.ask, closeDecision(false, true));
    try std.testing.expectEqual(CloseDecision.close, closeDecision(false, false));
    try std.testing.expectEqual(CloseDecision.close, closeDecision(true, false));
}

test "win32 window: close tab modes pick their targets" {
    // Tabs 0..3 with the anchor at 1.
    const expect = std.testing.expectEqual;
    try expect(false, closeModeMatches(.this, 1, 0));
    try expect(true, closeModeMatches(.this, 1, 1));
    try expect(true, closeModeMatches(.other, 1, 0));
    try expect(false, closeModeMatches(.other, 1, 1));
    try expect(true, closeModeMatches(.other, 1, 3));
    try expect(false, closeModeMatches(.right, 1, 1));
    try expect(true, closeModeMatches(.right, 1, 2));
    try expect(false, closeModeMatches(.right, 1, 0));
}

const HookProbe = struct {
    var calls: [3]u32 = .{ 0, 0, 0 };
    var results: [3]?win32.foundation.LRESULT = .{ null, null, null };

    fn reset(r: [3]?win32.foundation.LRESULT) void {
        calls = .{ 0, 0, 0 };
        results = r;
    }

    fn hook(comptime n: usize) Hook {
        return struct {
            fn f(_: *Window, _: u32, _: win32.foundation.WPARAM, _: win32.foundation.LPARAM) ?win32.foundation.LRESULT {
                calls[n] += 1;
                return results[n];
            }
        }.f;
    }
};

test "win32 window: hook chain stops at the first handler" {
    const probes = [_]Hook{ HookProbe.hook(0), HookProbe.hook(1), HookProbe.hook(2) };
    const window: *Window = undefined;

    const Case = struct {
        results: [3]?win32.foundation.LRESULT,
        want: ?win32.foundation.LRESULT,
        calls: [3]u32,
    };
    const cases = [_]Case{
        .{ .results = .{ null, null, null }, .want = null, .calls = .{ 1, 1, 1 } },
        .{ .results = .{ null, 7, 9 }, .want = 7, .calls = .{ 1, 1, 0 } },
        .{ .results = .{ 5, 7, 9 }, .want = 5, .calls = .{ 1, 0, 0 } },
        .{ .results = .{ null, null, 0 }, .want = 0, .calls = .{ 1, 1, 1 } },
    };
    for (cases) |c| {
        HookProbe.reset(c.results);
        try std.testing.expectEqual(c.want, runHooks(window, &probes, 0, 0, 0));
        try std.testing.expectEqualSlices(u32, &c.calls, &HookProbe.calls);
    }
}

test "win32 window: new tab index" {
    const expect = std.testing.expectEqual;
    try expect(@as(usize, 2), newTabIndex(.current, 1, 3));
    try expect(@as(usize, 3), newTabIndex(.current, 2, 3));
    try expect(@as(usize, 0), newTabIndex(.current, 0, 0));
    try expect(@as(usize, 3), newTabIndex(.end, 0, 3));
    try expect(@as(usize, 0), newTabIndex(.end, 0, 0));
}

test "win32 window: show tabs setting" {
    try std.testing.expect(showTabsFor(.always, 1));
    try std.testing.expect(!showTabsFor(.never, 5));
    try std.testing.expect(!showTabsFor(.auto, 1));
    try std.testing.expect(showTabsFor(.auto, 2));
}

test "win32 window: goto tab index matches GTK" {
    const expect = std.testing.expectEqual;
    const G = apprt.action.GotoTab;
    const n = struct {
        fn at(v: c_int) G {
            return @fromBackingInt(@intCast(v));
        }
    }.at;

    // previous wraps 0 -> count - 1
    try expect(@as(?usize, 3), gotoIndex(.previous, 0, 4));
    try expect(@as(?usize, 0), gotoIndex(.previous, 1, 4));
    // next wraps
    try expect(@as(?usize, 0), gotoIndex(.next, 3, 4));
    try expect(@as(?usize, 2), gotoIndex(.next, 1, 4));
    // last
    try expect(@as(?usize, 3), gotoIndex(.last, 0, 4));
    try expect(@as(?usize, null), gotoIndex(.last, 3, 4));
    // numbers are 1-based
    try expect(@as(?usize, null), gotoIndex(n(0), 1, 4));
    try expect(@as(?usize, 0), gotoIndex(n(1), 2, 4));
    try expect(@as(?usize, 3), gotoIndex(n(9), 0, 4));
    try expect(@as(?usize, null), gotoIndex(n(2), 1, 4));
    // a single tab never changes
    try expect(@as(?usize, null), gotoIndex(.next, 0, 1));
    try expect(@as(?usize, null), gotoIndex(.next, 0, 0));
}

test "win32 window: move tab wraps" {
    const expect = std.testing.expectEqual;
    try expect(@as(?usize, 2), moveIndex(1, 1, 4));
    try expect(@as(?usize, 0), moveIndex(1, 3, 4));
    try expect(@as(?usize, 3), moveIndex(-1, 0, 4));
    try expect(@as(?usize, 0), moveIndex(-2, 2, 4));
    try expect(@as(?usize, 1), moveIndex(5, 0, 4));
    try expect(@as(?usize, null), moveIndex(1, 0, 1));
    try expect(@as(?usize, null), moveIndex(1, 0, 0));
}
