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
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Overrides = @import("Overrides.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const clipboard = @import("clipboard.zig");
const dialogs = @import("dialogs.zig");
const dpi = @import("dpi.zig");
const drop = @import("drop.zig");
const ime = @import("ime.zig");
const keyboard = @import("keyboard.zig");
const messages = @import("messages.zig");
const mouse = @import("mouse.zig");
const resize_overlay = @import("resize_overlay.zig");
const scrollbar_mod = @import("scrollbar.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_surface);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

/// The split tree of a tab holds surfaces by reference.
pub const Tree = SplitTree(Surface);

pub const CreateOptions = struct {
    /// The surface the new one is created from (font size inheritance).
    parent: ?*CoreSurface = null,
    overrides: Overrides = .none,
    context: apprt.surface.NewSurfaceContext,
};

/// Sent to a child window after its parent's DPI changed (winuser.h).
const WM_DPICHANGED_AFTERPARENT = 0x02E3;

/// Timer that applies a coalesced size to core (SPEC §6.4). The system
/// timer cannot tick faster than its ~15.6 ms resolution anyway.
const resize_timer_id: usize = 1;
const resize_interval_ms: u32 = 16;

/// Source of `id`, for log correlation only.
var next_id: std.atomic.Value(u32) = .init(1);

hwnd: win32.foundation.HWND,
/// The window of `tab`, kept in step by `Tab.setWindow`. UI thread only:
/// `Tab.setWindow` rewrites it while the renderer and IO threads run, so
/// those go through `app`.
window: *Window,
/// The app, which outlives every window and never changes. The only
/// path to the app and its allocator that is safe off the UI thread.
app: *App,
tab: *Tab,
core_surface: CoreSurface,

/// Number of owners (split trees). Zero only between `create` and the
/// first `Tree.init`; the last `unref` destroys the surface.
refs: u32 = 0,

/// Whether a bell is waiting to be seen; cleared when the surface gets focus.
bell_ringing: bool = false,

scrollbar: scrollbar_mod.State = .{},

/// The kind of shell this surface runs, for the paths pasted by a drop.
shell_kind: drop.ShellKind,

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

/// Bumped by `bumpPresentTarget` after the window changed parents.
present_generation: std.atomic.Value(u32) = .init(0),

/// Whether the top-level window is minimized (a WM_SIZE of 0x0).
minimized: bool = false,

/// Sizes waiting for the resize timer; see `ResizeCoalescer`.
resize: ResizeCoalescer = .{},

/// Set by WM_NCDESTROY: the HWND is gone (for example with its parent).
hwnd_destroyed: bool = false,

keyboard_state: keyboard.State,
mouse_state: mouse.State,
ime_state: ime.State,
clipboard_state: clipboard.State,

/// Create the child window filling `tab`'s container and the core surface
/// inside it. The surface has no owner yet (`refs` is zero): the split tree
/// that takes it over references it.
pub fn create(tab: *Tab, opts: CreateOptions) !*Surface {
    const window = tab.window;
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

    // The config of this surface alone: inherited values, then the
    // command-line overrides of its window.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
    defer config.deinit();
    try opts.overrides.apply(&config);
    if (opts.parent) |parent| {
        if (app.config.@"window-inherit-font-size") {
            config.@"font-size" = parent.font_size.points;
        }
    }

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    self.* = .{
        .hwnd = undefined,
        .window = window,
        .app = app,
        .tab = tab,
        .core_surface = undefined,
        .initialized = false,
        .shell_kind = drop.shellKindFor(config.command),
        .id = next_id.fetchAdd(1, .monotonic),
        .size = .init(0),
        .content_scale = dpi.contentScale(window.dpi),
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
    _ = win32.user32.GetClientRect(tab.hwnd, &parent_rect);

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
        tab.hwnd,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = win32.user32.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    const client = self.clientSize();
    self.size.store(renderer.D3D11.packSize(client.width, client.height), .release);

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    self.initialized = true;

    // Core assumes focus. The child normally gets it later, via WM_SETFOCUS.
    if (win32.user32.GetFocus() != hwnd) {
        self.core_surface.focusCallback(false) catch |err|
            log.warn("focus callback failed err={}", .{err});
    }

    return self;
}

/// Take a reference. The split tree calls this for every node it holds.
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.refs += 1;
    return self;
}

/// Drop a reference; the last one destroys the surface.
pub fn unref(self: *Surface, alloc: Allocator) void {
    _ = alloc;
    self.refs -= 1;
    if (self.refs == 0) self.destroy();
}

/// Identity: a surface is only equal to itself.
pub fn eql(a: *const Surface, b: *const Surface) bool {
    return a == b;
}

/// Tear the surface down and free it. Joins the core threads, so it must
/// not be called from one of them.
pub fn destroy(self: *Surface) void {
    self.app.core_app.deleteSurface(self);
    self.deinit();
}

/// Like `destroy` for a surface the core app has already dropped from its
/// list; core's `App.deinit` calls this on whatever is left.
pub fn deinit(self: *Surface) void {
    const alloc = self.app.core_app.alloc;

    clipboard.cancelPending(self);
    self.initialized = false;

    self.core_surface.deinit();

    // The parent's destruction may already have taken the child with it.
    if (!self.hwnd_destroyed) _ = win32.user32.DestroyWindow(self.hwnd);

    if (self.title) |t| alloc.free(t);
    alloc.destroy(self);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

/// Close the surface, asking first when `process_active`. Both the
/// question and the close are deferred through the window's message queue:
/// core calls this from inside a key callback or a mailbox tick, and the
/// dialog's message loop must not run in there.
pub fn close(self: *Surface, process_active: bool) void {
    _ = win32.user32.PostMessageW(
        self.window.hwnd,
        messages.WM_GHOSTTY_CLOSE_SURFACE,
        self.id,
        @intFromBool(process_active),
    );
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

/// Remember the title core asked for. The window caption is set separately.
pub fn setTitle(self: *Surface, title: []const u8) Allocator.Error!void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, title, 0);
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
    return clipboard.setClipboard(self, clipboard_type, contents, confirm);
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
    return .{
        .hwnd = self.hwnd,
        .size = &self.size,
        .id = self.id,
        .generation = &self.present_generation,
    };
}

/// Tell the render thread that the window changed parents. UI thread, after
/// `SetParent`. Never touches DXGI: the render thread recreates the swap
/// chain if the next present fails (`renderer.D3D11.PresentTarget.generation`).
pub fn bumpPresentTarget(self: *Surface) void {
    _ = self.present_generation.fetchAdd(1, .release);
    if (!self.initialized) return;
    self.core_surface.refreshCallback() catch |err|
        log.warn("refresh after re-parent failed err={}", .{err});
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

/// Coalesces the stream of WM_SIZE messages of a live resize into at most
/// one size update for core per timer tick. Pure bookkeeping, so it can be
/// tested without a window.
pub const ResizeCoalescer = struct {
    /// The size core was last given; 0 until the first one.
    applied: u64 = 0,

    /// The newest size core has not seen yet; 0 for none.
    pending: u64 = 0,

    /// Whether the resize timer is running.
    timer_armed: bool = false,

    pub const Action = enum { none, arm_timer };

    /// Note the client size of a WM_SIZE (packed). A zero dimension (a
    /// minimized or collapsed window) cancels what is pending: there is
    /// nothing to lay out. Returns `.arm_timer` when the caller has to
    /// start the timer.
    pub fn request(self: *ResizeCoalescer, packed_size: u64) Action {
        const size = renderer.D3D11.unpackSize(packed_size);
        if (size.width == 0 or size.height == 0 or packed_size == self.applied) {
            self.pending = 0;
            return .none;
        }

        self.pending = packed_size;
        if (self.timer_armed) return .none;
        self.timer_armed = true;
        return .arm_timer;
    }

    /// The timer fired, or the drag ended: the size to hand to core now, if
    /// it differs from what core has. The caller stops the timer.
    pub fn take(self: *ResizeCoalescer) ?u64 {
        self.timer_armed = false;
        if (self.pending == 0) return null;
        const size = self.pending;
        self.pending = 0;
        self.applied = size;
        return size;
    }
};

fn clientSize(self: *const Surface) apprt.SurfaceSize {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (win32.user32.GetClientRect(self.hwnd, &rc) == 0) return .{ .width = 0, .height = 0 };
    return .{
        .width = @intCast(@max(rc.right - rc.left, 0)),
        .height = @intCast(@max(rc.bottom - rc.top, 0)),
    };
}

/// Hand a size to core. Core mails it to the IO and render threads; the
/// push can wait on a full mailbox, so this is timed and only ever called
/// from the resize timer or an explicit flush, never per WM_SIZE.
pub fn applySize(self: *Surface, packed_size: u64) void {
    const size = renderer.D3D11.unpackSize(packed_size);
    // A zero-sized client (a collapsed parent) has nothing to lay out or draw.
    if (size.width == 0 or size.height == 0) return;
    if (!self.initialized) return;

    const io = global.io();
    const start = std.Io.Timestamp.now(io, .awake);
    if (self.core_surface.sizeCallback(.{ .width = size.width, .height = size.height })) {
        self.resize.applied = packed_size;
        const grid = self.core_surface.size.grid();
        resize_overlay.notify(self, grid.columns, grid.rows);
    } else |err| {
        // `take` already counted this size as applied: forget it, so the
        // next WM_SIZE of the same size tries again.
        self.resize.applied = 0;
        log.warn("size callback failed err={}", .{err});
    }
    log.debug("size callback id={} {}x{} took {} ms", .{
        self.id,
        size.width,
        size.height,
        start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds(),
    });
}

/// Apply the newest size that has not reached core yet, if any, and stop
/// the resize timer. Called by the timer and when a resize drag ends.
pub fn flushSize(self: *Surface) void {
    _ = win32.user32.KillTimer(self.hwnd, resize_timer_id);
    if (self.resize.take()) |packed_size| self.applySize(packed_size);
}

fn handleSize(self: *Surface, wparam: win32.foundation.WPARAM, lparam: win32.foundation.LPARAM) void {
    const io = global.io();
    const start = std.Io.Timestamp.now(io, .awake);
    defer log.debug("WM_SIZE id={} took {} ms", .{
        self.id,
        start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds(),
    });

    const msg = sizeMessage(wparam, lparam);
    self.size.store(msg.packed_size, .release);
    if (!self.initialized) return;

    // A minimized top-level window never sends this child a WM_SIZE (the
    // window forwards occlusion itself), so every size here is a real one.
    // Core is told from the resize timer, and the renderer picks the new
    // size up from `size` on its own thread: the UI thread never waits for
    // core while the user drags the border (SPEC §6.4).
    switch (self.resize.request(msg.packed_size)) {
        .none => {},
        .arm_timer => if (win32.user32.SetTimer(self.hwnd, resize_timer_id, resize_interval_ms, null) == 0) {
            log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
            self.flushSize();
        },
    }
}

/// Follow the window's DPI, the single source of it.
pub fn applyDpi(self: *Surface) void {
    self.content_scale = dpi.contentScale(self.window.dpi);
    if (!self.initialized) return;
    self.core_surface.contentScaleCallback(self.content_scale) catch |err|
        log.warn("content scale callback failed err={}", .{err});
}

fn handleFocus(self: *Surface, focused: bool) void {
    if (focused) {
        self.tab.focused = self;
        self.bell_ringing = false;
        Chrome.invalidate(self.window);
    }
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

        win32.user32.WM_TIMER => if (wparam == resize_timer_id) {
            self.flushSize();
            return 0;
        },

        WM_DPICHANGED_AFTERPARENT => {
            self.applyDpi();
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

test "win32 surface: resize coalescer applies only the newest size per tick" {
    const packSize = renderer.D3D11.packSize;
    var c: ResizeCoalescer = .{};

    // A burst of sizes arms the timer once and collapses to the last one.
    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(800, 600)));
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(810, 600)));
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(820, 610)));
    try std.testing.expectEqual(@as(?u64, packSize(820, 610)), c.take());

    // Nothing new: the next tick has nothing to apply.
    try std.testing.expectEqual(@as(?u64, null), c.take());

    // The timer was stopped by `take`, so the next change re-arms it.
    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(900, 700)));
    try std.testing.expectEqual(@as(?u64, packSize(900, 700)), c.take());
}

test "win32 surface: resize coalescer ignores sizes core already has" {
    const packSize = renderer.D3D11.packSize;
    var c: ResizeCoalescer = .{};

    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(800, 600)));
    try std.testing.expectEqual(@as(?u64, packSize(800, 600)), c.take());

    // Same size again: no timer.
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(800, 600)));
    try std.testing.expectEqual(@as(?u64, null), c.take());

    // Dragged away and back before the tick: nothing to tell core.
    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(900, 600)));
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(800, 600)));
    try std.testing.expectEqual(@as(?u64, null), c.take());
}

test "win32 surface: resize coalescer drops zero sizes" {
    const packSize = renderer.D3D11.packSize;
    var c: ResizeCoalescer = .{};

    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(0, 0)));
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(packSize(800, 0)));
    try std.testing.expectEqual(@as(?u64, null), c.take());

    // Minimizing while a size is pending cancels it; the restore brings a
    // fresh one.
    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(800, 600)));
    try std.testing.expectEqual(ResizeCoalescer.Action.none, c.request(0));
    try std.testing.expectEqual(@as(?u64, null), c.take());
    try std.testing.expectEqual(ResizeCoalescer.Action.arm_timer, c.request(packSize(800, 600)));
    try std.testing.expectEqual(@as(?u64, packSize(800, 600)), c.take());
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
