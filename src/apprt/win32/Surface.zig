//! The Win32 apprt surface: a child window of a `Window` that owns a core
//! surface. Heap allocated so its address is stable; the HWND's
//! GWLP_USERDATA points back at it. Input, clipboard and dialog handling
//! live in the sibling files and are dispatched from `wndProc`.
//!
//! Queries that core calls with `try` inside non-failing functions
//! (`getContentScale`) have an empty error set.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const renderer = @import("../../renderer.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const clipboard = @import("clipboard.zig");
const dialogs = @import("dialogs.zig");
const dpi = @import("dpi.zig");
const ime = @import("ime.zig");
const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_surface);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

/// Sent to a child window after its parent's DPI changed (winuser.h).
const WM_DPICHANGED_AFTERPARENT = 0x02E3;

/// Source of `id`, for log correlation only.
var next_id: std.atomic.Value(u32) = .init(1);

hwnd: win32.foundation.HWND,
window: *Window,
core_surface: CoreSurface,

/// Set once `core_surface` is initialized and cleared before it is torn
/// down. Window messages arriving outside that span never reach core.
initialized: bool,
id: u32,

/// Physical client size packed with `renderer.D3D11.packSize`. Written on
/// the UI thread, read by the renderer thread through the present target.
size: std.atomic.Value(u64),
content_scale: apprt.ContentScale,

/// Owned copy of the last title set by core, if any.
title: ?[:0]const u8,

/// Whether the top-level window is minimized (a WM_SIZE of 0x0).
minimized: bool = false,

/// Set by WM_NCDESTROY: the HWND is gone (for example with its parent).
hwnd_destroyed: bool = false,

keyboard_state: keyboard.State,
mouse_state: mouse.State,
ime_state: ime.State,
clipboard_state: clipboard.State,

/// Create the child window filling `window`'s client area and the core
/// surface inside it.
pub fn create(window: *Window) !*Surface {
    const app = window.app;
    const alloc = app.core_app.alloc;

    try util.registerClass(&.{
        .style = win32.user32.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .hCursor = win32.user32.LoadCursorW(null, win32.user32.IDC_ARROW),
        // No background brush: every pixel is painted by the renderer.
        .lpszClassName = class_name,
    });

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    self.* = .{
        .hwnd = undefined,
        .window = window,
        .core_surface = undefined,
        .initialized = false,
        .id = next_id.fetchAdd(1, .monotonic),
        .size = .init(0),
        .content_scale = .{ .x = 1, .y = 1 },
        .title = null,
        .keyboard_state = .{},
        .mouse_state = .{},
        .ime_state = .{},
        .clipboard_state = .{},
    };

    // Core drops surface-directed mailbox messages for surfaces it does not
    // know about, so this must precede `core_surface.init` and stay
    // registered until `destroy`.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var parent_rect: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.user32.GetClientRect(window.hwnd, &parent_rect);

    // The window procedure sees WM_NCCREATE before this returns and stores
    // `self` as the window's user data.
    const hwnd = win32.user32.CreateWindowExW(
        0,
        class_name,
        null,
        win32.user32.WS_CHILD | win32.user32.WS_VISIBLE | win32.user32.WS_CLIPSIBLINGS,
        0,
        0,
        parent_rect.right - parent_rect.left,
        parent_rect.bottom - parent_rect.top,
        window.hwnd,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = win32.user32.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    self.content_scale = dpi.contentScale(win32.user32.GetDpiForWindow(hwnd));
    const client = self.clientSize();
    self.size.store(renderer.D3D11.packSize(client.width, client.height), .release);

    // Registered up front so core's early actions (title, ...) find us.
    window.surface = self;
    errdefer window.surface = null;

    try self.core_surface.init(alloc, &app.config, app.core_app, app, self);
    self.initialized = true;

    // Core assumes focus. The child normally gets it later, via WM_SETFOCUS.
    if (win32.user32.GetFocus() != hwnd) {
        self.core_surface.focusCallback(false) catch |err|
            log.warn("focus callback failed err={}", .{err});
    }

    return self;
}

/// Tear the surface down and free it. Joins the core threads, so it must
/// not be called from one of them.
pub fn destroy(self: *Surface) void {
    self.window.app.core_app.deleteSurface(self);
    self.deinit();
}

/// Like `destroy` for a surface the core app has already dropped from its
/// list; core's `App.deinit` calls this on whatever is left.
pub fn deinit(self: *Surface) void {
    const alloc = self.window.app.core_app.alloc;

    clipboard.cancelPending(self);
    self.initialized = false;

    self.core_surface.deinit();
    if (self.window.surface == self) self.window.surface = null;

    // The parent's destruction may already have taken the child with it.
    if (!self.hwnd_destroyed) _ = win32.user32.DestroyWindow(self.hwnd);

    if (self.title) |t| alloc.free(t);
    alloc.destroy(self);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.window.app;
}

/// Close the surface, asking first when `process_active`. The close itself
/// is deferred through the window's message queue.
pub fn close(self: *Surface, process_active: bool) void {
    if (process_active and !dialogs.confirmClose(self.window.hwnd)) return;
    self.window.requestClose();
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

/// Remember the title core asked for. The window caption is set separately.
pub fn setTitle(self: *Surface, title: []const u8) Allocator.Error!void {
    const alloc = self.window.app.core_app.alloc;
    const copy = try alloc.dupeZ(u8, title);
    if (self.title) |old| alloc.free(old);
    self.title = copy;
}

pub fn getContentScale(self: *const Surface) error{}!apprt.ContentScale {
    return self.content_scale;
}

/// The physical size of the surface's client area.
pub fn getSize(self: *const Surface) error{}!apprt.SurfaceSize {
    return self.clientSize();
}

/// The cursor position in client pixels, origin top-left.
pub fn getCursorPos(self: *const Surface) error{}!apprt.CursorPos {
    var pt: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    if (win32.user32.GetCursorPos(&pt) == 0 or
        win32.user32.ScreenToClient(self.hwnd, &pt) == 0)
    {
        return .{ .x = 0, .y = 0 };
    }
    return .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) };
}

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    return clipboard.supports(clipboard_type);
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    return clipboard.request(self, clipboard_type, state);
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    return clipboard.write(self, clipboard_type, contents, confirm);
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    return global.environMap();
}

pub fn renderDeviceOptions(self: *const Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}

/// Where the D3D11 renderer presents.
pub fn d3d11PresentTarget(self: *Surface) ?renderer.D3D11.PresentTarget {
    return .{ .hwnd = self.hwnd, .size = &self.size };
}

/// Decode a WM_SIZE message. A minimized window reports 0x0, which must
/// never reach the renderer as a size.
pub fn sizeMessage(
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) struct { packed_size: u64, visible: bool } {
    if (wparam == win32.user32.SIZE_MINIMIZED) return .{ .packed_size = 0, .visible = false };

    const bits: usize = @bitCast(lparam);
    return .{
        .packed_size = renderer.D3D11.packSize(
            @intCast(bits & 0xFFFF),
            @intCast((bits >> 16) & 0xFFFF),
        ),
        .visible = true,
    };
}

fn clientSize(self: *const Surface) apprt.SurfaceSize {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (win32.user32.GetClientRect(self.hwnd, &rc) == 0) return .{ .width = 0, .height = 0 };
    return .{
        .width = @intCast(@max(rc.right - rc.left, 0)),
        .height = @intCast(@max(rc.bottom - rc.top, 0)),
    };
}

fn handleSize(self: *Surface, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) void {
    const msg = sizeMessage(wparam, lparam);
    self.size.store(msg.packed_size, .release);
    if (!self.initialized) return;

    if (!msg.visible) {
        self.minimized = true;
        self.core_surface.occlusionCallback(false) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
        return;
    }

    if (self.minimized) {
        self.minimized = false;
        self.core_surface.occlusionCallback(true) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }

    const size = renderer.D3D11.unpackSize(msg.packed_size);
    // A zero-sized client (a collapsed parent) has nothing to lay out or draw.
    if (size.width == 0 or size.height == 0) return;

    self.core_surface.sizeCallback(.{ .width = size.width, .height = size.height }) catch |err|
        log.warn("size callback failed err={}", .{err});
    self.core_surface.draw() catch |err|
        log.warn("draw on resize failed err={}", .{err});
}

fn handleDpiChanged(self: *Surface) void {
    self.content_scale = dpi.contentScale(win32.user32.GetDpiForWindow(self.hwnd));
    if (!self.initialized) return;
    self.core_surface.contentScaleCallback(self.content_scale) catch |err|
        log.warn("content scale callback failed err={}", .{err});
}

fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.initialized) return;
    self.core_surface.focusCallback(focused) catch |err|
        log.warn("focus callback failed err={}", .{err});
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
            const self: *Surface = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            util.setUserData(hwnd, self);
        }
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = util.fromUserData(Surface, hwnd) orelse
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        win32.user32.WM_SIZE => {
            self.handleSize(wparam, lparam);
            return 0;
        },

        WM_DPICHANGED_AFTERPARENT => {
            self.handleDpiChanged();
            return 0;
        },

        win32.user32.WM_SETFOCUS => {
            self.handleFocus(true);
            return 0;
        },

        win32.user32.WM_KILLFOCUS => {
            self.handleFocus(false);
            return 0;
        },

        // The renderer paints every pixel; erasing would only flicker.
        win32.user32.WM_ERASEBKGND => return 1,

        win32.user32.WM_PAINT => {
            _ = win32.user32.ValidateRect(hwnd, null);
            return 0;
        },

        win32.user32.WM_NCDESTROY => {
            self.hwnd_destroyed = true;
            util.setUserData(hwnd, null);
            return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    if (self.initialized) {
        if (ime.handle(self, msg, wparam, lparam)) |r| return r;
        if (keyboard.handle(self, msg, wparam, lparam)) |r| return r;
        if (mouse.handle(self, msg, wparam, lparam)) |r| return r;
        if (clipboard.handle(self, msg, wparam, lparam)) |r| return r;
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test {
    _ = dpi;
    _ = keyboard;
    _ = mouse;
    _ = ime;
    _ = clipboard;
    _ = dialogs;
}

test "win32 surface: WM_SIZE decoding" {
    const user32 = win32.user32;
    const packSize = renderer.D3D11.packSize;

    const minimized = sizeMessage(user32.SIZE_MINIMIZED, 0);
    try std.testing.expectEqual(@as(u64, 0), minimized.packed_size);
    try std.testing.expect(!minimized.visible);

    // The size words of a minimized window must not leak through.
    const minimized_dirty = sizeMessage(user32.SIZE_MINIMIZED, (600 << 16) | 800);
    try std.testing.expectEqual(@as(u64, 0), minimized_dirty.packed_size);
    try std.testing.expect(!minimized_dirty.visible);

    const restored = sizeMessage(user32.SIZE_RESTORED, (600 << 16) | 800);
    try std.testing.expectEqual(packSize(800, 600), restored.packed_size);
    try std.testing.expect(restored.visible);

    const maximized = sizeMessage(user32.SIZE_MAXIMIZED, (1 << 16) | 1);
    try std.testing.expectEqual(packSize(1, 1), maximized.packed_size);
    try std.testing.expect(maximized.visible);
}
