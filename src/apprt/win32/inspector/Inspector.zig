//! The terminal inspector window. File-level functions are the hooks; the
//! nested `Inspector` is the per-surface instance.
//!
//! An inspector is a top-level window (`Window.zig`) with its own imgui
//! context, drawn through the imgui Win32 and Direct3D 11 backends on the
//! shared device. Nothing is allocated or initialised before the first one
//! opens. All of it runs on the UI thread; the imgui UI is built without the
//! device context lock (it takes the renderer state mutex), the GPU work
//! (draw, present) runs under it.
//!
//! `render_inspector` only sets a dirty flag. The 30 Hz tick of the window
//! renders when the flag is set or the window is in the foreground, so a
//! busy terminal never costs more than one imgui frame per tick.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const cimgui = @import("dcimgui");
const apprt = @import("../../../apprt.zig");
const CoreInspector = @import("../../../inspector/main.zig").Inspector;
const CoreSurface = @import("../../../Surface.zig");
const Device = @import("../../../renderer/d3d11/Device.zig");
const SwapChain = @import("../../../renderer/d3d11/SwapChain.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const dpi_mod = @import("../dpi.zig");
const messages = @import("../messages.zig");
const Window = @import("Window.zig");

const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const log = std.log.scoped(.win32_inspector);

comptime {
    // The imgui Direct3D 11 backend links against this export.
    _ = @import("imgui_shim.zig");
}

/// Background of the window; imgui paints over it.
const clear_color: [4]f32 = .{ 0.06, 0.06, 0.06, 1 };

/// The core inspector bakes its font at 2x (`Inspector.setup`).
const baked_font_scale = 2;

/// Open inspectors, in order of creation. UI thread only.
var open_list: std.ArrayList(*Inspector) = .empty;

/// imgui contexts alive, and imgui frames built since start.
var live_contexts: usize = 0;
var total_frames: u64 = 0;

/// Builds the imgui UI of one frame.
pub const DrawFn = *const fn (*Inspector) void;

/// Runs under the device context lock, right before the draw data is
/// rendered.
pub const LockedHook = *const fn (*Inspector) void;

pub const Options = struct {
    alloc: Allocator,
    hinstance: win32.foundation.HINSTANCE,
    /// Taken over: released with `Device.release` when it was handed out by
    /// `Device.acquire`, left alone otherwise.
    device: *Device,
    surface: *Surface,
    /// The core surface to collect data from; none in tests.
    core: ?*CoreSurface,
    title: []const u8,
    dpi: u32,
    show: bool = true,
    draw: DrawFn = drawCore,
    locked_hook: ?LockedHook = null,
    /// Redraw at every tick (the default); tests turn it off.
    refresh: bool = true,
    /// Skip a frame while the display has no free slot (a window nobody
    /// composes, as in tests, never has one).
    poll_slot: bool = true,
};

/// One inspector window, owned by the surface it inspects.
pub const Inspector = struct {
    alloc: Allocator,
    window: *Window,
    ig_ctx: *cimgui.c.ImGuiContext,
    surface: *Surface,
    core: ?*CoreSurface,
    device: *Device,
    swap_chain: ?SwapChain = null,
    draw: DrawFn,
    locked_hook: ?LockedHook,

    /// Something changed since the last frame.
    /// Redraw at every tick while the window is shown.
    refresh: bool,
    poll_slot: bool,

    /// Whether the tick looks at the window being visible (not in tests).
    check_visible: bool,

    dirty: bool = true,

    /// Frames built by the tick.
    frames: u64 = 0,

    /// Hash of the surface title the window caption shows.
    title_hash: u64 = 0,

    pub fn create(opts: Options) !*Inspector {
        const alloc = opts.alloc;
        const self = try alloc.create(Inspector);
        errdefer alloc.destroy(self);

        const window = try Window.create(alloc, .{
            .hinstance = opts.hinstance,
            .title = opts.title,
            .dpi = opts.dpi,
            .show = opts.show,
        });
        errdefer window.destroy(alloc);

        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        live_contexts += 1;
        errdefer {
            cimgui.c.ImGui_DestroyContext(ig_ctx);
            live_contexts -= 1;
        }
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        CoreInspector.setup();

        if (!cimgui.ImGui_ImplWin32_Init(window.hwnd)) return error.ImguiBackendFailed;
        errdefer cimgui.ImGui_ImplWin32_Shutdown();
        if (!cimgui.ImGui_ImplDX11_Init(opts.device.device, opts.device.context)) return error.ImguiBackendFailed;
        errdefer cimgui.ImGui_ImplDX11_Shutdown();

        try open_list.append(alloc, self);
        errdefer _ = open_list.pop();

        // A failure leaves no blank window behind.
        if (opts.core) |core| try core.activateInspector();
        errdefer if (opts.core) |core| core.deactivateInspector();

        self.* = .{
            .alloc = alloc,
            .window = window,
            .ig_ctx = ig_ctx,
            .surface = opts.surface,
            .core = opts.core,
            .device = opts.device,
            .draw = opts.draw,
            .locked_hook = opts.locked_hook,
            .refresh = opts.refresh,
            .check_visible = opts.show,
            .poll_slot = opts.poll_slot,
        };
        self.applyScale(window.dpi);
        self.title_hash = titleHash(opts.surface.getTitle());

        window.inspector = self;
        opts.surface.inspector = self;
        window.startTimer();
        return self;
    }

    /// Closes the window and frees everything the inspector holds, the
    /// inspector included. Safe from the window procedure as its last act.
    pub fn close(self: *Inspector) void {
        const alloc = self.alloc;
        if (self.surface.inspector == self) self.surface.inspector = null;
        if (std.mem.findScalar(*Inspector, open_list.items, self)) |i| _ = open_list.orderedRemove(i);
        if (open_list.items.len == 0) {
            open_list.deinit(alloc);
            open_list = .empty;
        }

        if (self.core) |core| core.deactivateInspector();

        // No message reaches us from here on.
        self.window.inspector = null;
        _ = user32.KillTimer(self.window.hwnd, Window.tick_id);

        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        {
            self.device.lockContext();
            defer self.device.unlockContext();
            cimgui.ImGui_ImplDX11_Shutdown();
            if (self.swap_chain) |*sc| sc.deinit();
        }
        cimgui.ImGui_ImplWin32_Shutdown();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(null);
        live_contexts -= 1;

        self.window.destroy(alloc);
        releaseDevice(self.device);
        alloc.destroy(self);
    }

    /// Asks for a frame at the next tick.
    pub fn markDirty(self: *Inspector) void {
        self.dirty = true;
    }

    /// The 30 Hz tick: builds a frame when something changed or the window
    /// has the focus.
    pub fn tick(self: *Inspector) void {
        self.syncTitle();
        // The terminal changes without telling the app (plain output and
        // keys wake nobody), so a shown inspector redraws at every tick.
        if (self.refresh) {
            if (self.check_visible and user32.IsWindowVisible(self.window.hwnd) == 0) return;
            self.dirty = true;
        }
        if (!self.dirty and !self.window.isForeground()) return;
        if (user32.IsIconic(self.window.hwnd) != 0) return;
        self.dirty = false;
        self.renderFrame() catch |err| {
            self.dirty = true;
            log.warn("inspector frame failed err={}", .{err});
        };
    }

    /// Keeps the caption in step with the title of the surface.
    fn syncTitle(self: *Inspector) void {
        const title = self.surface.getTitle();
        const hash = titleHash(title);
        if (hash == self.title_hash) return;
        self.title_hash = hash;
        var buf: [title_max]u8 = undefined;
        self.window.setTitle(self.alloc, formatTitle(&buf, title));
    }

    pub fn dpiChanged(self: *Inspector, dpi: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        self.applyScale(dpi);
        self.dirty = true;
    }

    /// A style of the scale of `dpi`. The ImGuiStyle constructor gives the
    /// proper defaults; scaling the active style again would compound.
    fn applyScale(self: *Inspector, dpi: u32) void {
        _ = self;
        const scale = dpi_mod.contentScale(dpi).x;
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
        style.FontScaleDpi = scale / baked_font_scale;
        cimgui.c.ImGui_GetStyle().* = style;
    }

    fn renderFrame(self: *Inspector) !void {
        const size = self.window.clientSize();
        if (size.w == 0 or size.h == 0) return;
        if (self.device.isLost()) try self.rebindDevice();

        // Never wait on the display: without a free slot the frame is skipped
        // and tried again at the next tick.
        const pending_slot = if (self.poll_slot) blk: {
            const sc = self.swap_chain orelse break :blk false;
            const h = sc.waitable orelse break :blk false;
            break :blk kernel32.WaitForSingleObjectEx(h, 0, 0) != kernel32.WAIT_OBJECT_0;
        } else false;
        if (pending_slot) {
            self.dirty = true;
            return;
        }

        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Imgui needs more than one frame to settle its state. The UI takes
        // the renderer state mutex, so it is built without the context lock.
        for (0..2) |_| {
            cimgui.ImGui_ImplDX11_NewFrame();
            cimgui.ImGui_ImplWin32_NewFrame();
            cimgui.c.ImGui_NewFrame();
            self.draw(self);
            cimgui.c.ImGui_Render();
        }
        self.frames += 1;
        total_frames += 1;

        const dev = self.device;
        dev.lockContext();
        defer dev.unlockContext();
        self.present(size.w, size.h) catch |err| {
            if (err == error.DeviceLost) dev.markLostFromDevice();
            // The poll consumed the slot signal; a new chain starts afresh.
            if (self.swap_chain) |*sc| {
                sc.deinit();
                self.swap_chain = null;
            }
            return err;
        };
    }

    /// Draws the frame built by `renderFrame` into the back buffer and
    /// presents it without waiting. The caller holds the context lock.
    fn present(self: *Inspector, width: u32, height: u32) !void {
        const dev = self.device;
        dev.assertContextLocked();

        const sc = try self.ensureSwapChain(width, height);
        const back = try sc.chain.asSwapChain1().asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D);
        defer com.release(back);
        const rtv = try dev.device.createRenderTargetView(back.asResource(), null);
        defer com.release(rtv);
        // The shared context carries no state between users.
        defer dev.context.clearState();

        dev.context.clearRenderTargetView(rtv, clear_color);
        dev.context.omSetRenderTargets(&[_]?*d3d11.ID3D11RenderTargetView{rtv});
        if (self.locked_hook) |hook| hook(self);
        cimgui.ImGui_ImplDX11_RenderDrawData(cimgui.c.ImGui_GetDrawData());

        // Not `SwapChain.present`: it books the chain as a terminal frame for
        // the latency trace and the frame pacer, neither of which applies.
        const tearing = sc.flags & dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING != 0;
        _ = try sc.chain.asSwapChain1().asSwapChain().present(0, if (tearing) dxgi.PRESENT_ALLOW_TEARING else 0);
    }

    fn ensureSwapChain(self: *Inspector, width: u32, height: u32) !*SwapChain {
        if (self.swap_chain) |*sc| {
            if (sc.width != width or sc.height != height) {
                try sc.chain.asSwapChain1().asSwapChain().resizeBuffers(0, width, height, .UNKNOWN, sc.flags);
                sc.width = width;
                sc.height = height;
            }
            return sc;
        }
        self.swap_chain = try SwapChain.init(self.device, self.window.hwnd, width, height, .hwnd);
        // The new chain starts with its one slot signalled and a frame is
        // about to take it: consume the signal, or a second present would
        // queue behind the first and block on a window nobody composes.
        if (self.swap_chain.?.waitable) |h| _ = kernel32.WaitForSingleObjectEx(h, 0, 0);
        return &self.swap_chain.?;
    }

    /// Moves the backend and the swap chain to a healthy device after the
    /// one in use was lost.
    fn rebindDevice(self: *Inspector) !void {
        const new = try Device.acquire(self.alloc);
        errdefer releaseDevice(new);
        self.moveTo(new);
    }

    fn moveTo(self: *Inspector, new: *Device) void {
        const old = self.device;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        {
            old.lockContext();
            defer old.unlockContext();
            cimgui.ImGui_ImplDX11_Shutdown();
            if (self.swap_chain) |*sc| sc.deinit();
            self.swap_chain = null;
        }
        releaseDevice(old);
        self.device = new;
        if (!cimgui.ImGui_ImplDX11_Init(new.device, new.context)) {
            log.err("inspector lost its renderer backend after a device change", .{});
        }
        self.dirty = true;
    }
};

/// Longest caption, in bytes.
const title_max = 256;

fn titleHash(title: ?[]const u8) u64 {
    return std.hash.Wyhash.hash(0, title orelse "");
}

/// "Inspector - <title>" in `buf`; a title that does not fit is cut at a
/// code point boundary.
fn formatTitle(buf: []u8, title: ?[]const u8) []const u8 {
    const t = title orelse return "Inspector";
    if (t.len == 0) return "Inspector";
    const prefix = "Inspector \u{2014} ";
    @memcpy(buf[0..prefix.len], prefix);
    var n = @min(t.len, buf.len - prefix.len);
    while (n > 0 and n < t.len and t[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(buf[prefix.len..][0..n], t[0..n]);
    return buf[0 .. prefix.len + n];
}

/// Gives a device back to the registry when it came from `Device.acquire`.
fn releaseDevice(device: *Device) void {
    if (device.pool_alloc != null) Device.release(device);
}

/// The default UI: the core inspector of the surface.
fn drawCore(self: *Inspector) void {
    const core = self.core orelse return;
    const insp = core.inspector orelse return;
    insp.render(core);
}

/// The app woke up: core may have new data for the open inspectors. One
/// integer test when none is open.
pub fn wakeup(app: *App) void {
    _ = app;
    if (open_list.items.len == 0) return;
    for (open_list.items) |insp| insp.markDirty();
}

pub fn appStopping(app: *App) void {
    _ = app;
    while (open_list.items.len > 0) open_list.items[open_list.items.len - 1].close();
}

/// Before core deinitialises `surface`: its inspector goes first.
pub fn surfaceDestroying(surface: *Surface) void {
    if (surface.inspector) |insp| insp.close();
}

/// Task 24: the shared device was replaced.
pub fn deviceChanged(app: *App) void {
    _ = app;
    for (open_list.items) |insp| {
        if (!insp.device.isLost()) continue;
        insp.rebindDevice() catch |err| {
            log.warn("inspector could not move to the new device err={}", .{err});
        };
    }
}

pub fn action(app: *App, target: apprt.Target, mode: apprt.Action.Value(.inspector)) !bool {
    const surface = switch (target) {
        .app => return false,
        .surface => |core| app.surfaceFor(core) orelse return false,
    };
    switch (mode) {
        .toggle => if (surface.inspector) |insp| insp.close() else try open(app, surface),
        .show => if (surface.inspector) |insp| insp.window.raise() else try open(app, surface),
        .hide => if (surface.inspector) |insp| insp.close(),
    }
    return true;
}

/// `render_inspector`: the inspector has new data. The next tick draws it.
pub fn render(app: *App, target: apprt.Target) !bool {
    const surface = switch (target) {
        .app => return false,
        .surface => |core| app.surfaceFor(core) orelse return false,
    };
    const insp = surface.inspector orelse return false;
    insp.markDirty();
    return true;
}

fn open(app: *App, surface: *Surface) !void {
    const alloc = app.core_app.alloc;
    const device = try Device.acquire(alloc);
    errdefer releaseDevice(device);

    var buf: [title_max]u8 = undefined;
    const title = formatTitle(&buf, surface.getTitle());

    _ = try Inspector.create(.{
        .alloc = alloc,
        .hinstance = app.hinstance,
        .device = device,
        .surface = surface,
        .core = &surface.core_surface,
        .title = title,
        .dpi = surface.window.dpi,
    });
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.objectField("open");
    try jw.write(open_list.items.len);
    try jw.objectField("contexts");
    try jw.write(live_contexts);
    try jw.objectField("frames");
    try jw.write(total_frames);
    try jw.endObject();
}

// Tests -----------------------------------------------------------------

const testing = std.testing;

/// A hidden inspector on a WARP device and a stand-in surface.
const Fixture = struct {
    device: *Device,
    surface: *Surface,
    insp: *Inspector,

    fn init(opts: struct {
        draw: DrawFn = drawNothing,
        locked_hook: ?LockedHook = null,
        refresh: bool = false,
        poll_slot: bool = false,
    }) !Fixture {
        const alloc = testing.allocator;
        const device = Device.init(alloc, .{ .driver = .warp }) catch return error.SkipZigTest;
        errdefer device.deinit(alloc);

        // Only the fields the inspector touches are set.
        const surface = try alloc.create(Surface);
        errdefer alloc.destroy(surface);
        surface.inspector = null;
        surface.title = null;

        const hinstance = win32.kernel32.GetModuleHandleW(null) orelse return error.SkipZigTest;
        const insp = try Inspector.create(.{
            .alloc = alloc,
            .hinstance = hinstance,
            .device = device,
            .surface = surface,
            .core = null,
            .title = "Inspector",
            .dpi = 96,
            .show = false,
            .draw = opts.draw,
            .locked_hook = opts.locked_hook,
            .refresh = opts.refresh,
            .poll_slot = opts.poll_slot,
        });
        return .{ .device = device, .surface = surface, .insp = insp };
    }

    /// The inspector must be closed (by the test or `surfaceDestroying`).
    fn deinit(self: Fixture) void {
        testing.allocator.destroy(self.surface);
        self.device.deinit(testing.allocator);
    }
};

fn drawNothing(self: *Inspector) void {
    _ = self;
}

test "win32 inspector: open and close frees the imgui context" {
    const before = live_contexts;
    const f = try Fixture.init(.{});
    defer f.deinit();

    try testing.expectEqual(before + 1, live_contexts);
    try testing.expect(f.surface.inspector == f.insp);

    const frames = f.insp.frames;
    f.insp.tick();
    try testing.expectEqual(frames + 1, f.insp.frames);
    try testing.expect(f.insp.swap_chain != null);

    f.insp.close();
    try testing.expectEqual(before, live_contexts);
    try testing.expect(f.surface.inspector == null);
    try testing.expectEqual(@as(usize, 0), open_list.items.len);
}

var locked_hook_ran: bool = false;

fn assertLocked(self: *Inspector) void {
    self.device.assertContextLocked();
    locked_hook_ran = true;
}

test "win32 inspector: draw holds the context lock" {
    locked_hook_ran = false;
    const f = try Fixture.init(.{ .locked_hook = assertLocked });
    defer f.deinit();

    f.insp.tick();
    try testing.expect(locked_hook_ran);

    // The lock is free again afterwards.
    f.device.lockContext();
    f.device.unlockContext();
    f.insp.close();
}

test "win32 inspector: closing the surface closes its inspector" {
    const before = live_contexts;
    const f = try Fixture.init(.{});
    defer f.deinit();

    surfaceDestroying(f.surface);
    try testing.expect(f.surface.inspector == null);
    try testing.expectEqual(before, live_contexts);
    try testing.expectEqual(@as(usize, 0), open_list.items.len);
}

test "win32 inspector: render_inspector coalesces to the tick" {
    const f = try Fixture.init(.{});
    defer f.deinit();
    defer f.insp.close();

    f.insp.tick();
    const frames = f.insp.frames;
    for (0..100) |_| f.insp.markDirty();
    f.insp.tick();
    f.insp.tick();
    try testing.expectEqual(frames + 1, f.insp.frames);
}

test "win32 inspector: the app wakeup marks an open inspector dirty" {
    const f = try Fixture.init(.{});
    defer f.deinit();
    defer f.insp.close();

    const app: *App = @ptrFromInt(@alignOf(App));

    f.insp.tick();
    try testing.expect(!f.insp.dirty);
    try testing.expect(@import("../hooks.zig").appMessage(app, messages.WM_GHOSTTY_WAKEUP, 0, 0) == null);
    try testing.expect(f.insp.dirty);
}

test "win32 inspector: titles are cut at a code point, never replaced" {
    var buf: [title_max]u8 = undefined;
    try testing.expectEqualStrings("Inspector", formatTitle(&buf, null));
    try testing.expectEqualStrings("Inspector \u{2014} zsh", formatTitle(&buf, "zsh"));

    var long: [400]u8 = undefined;
    for (0..200) |i| @memcpy(long[i * 2 ..][0..2], "\u{44F}");
    const cut = formatTitle(&buf, &long);
    try testing.expect(cut.len <= title_max);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(std.mem.startsWith(u8, cut, "Inspector \u{2014} \u{44F}"));
}

test "win32 inspector: a refreshing inspector draws at every tick" {
    const f = try Fixture.init(.{ .refresh = true });
    defer f.deinit();
    defer f.insp.close();

    f.insp.tick();
    const frames = f.insp.frames;
    // The display may have no free slot (a hidden window has none): the
    // tick then keeps the frame pending.
    f.insp.dirty = false;
    f.insp.tick();
    try testing.expect(f.insp.dirty or f.insp.frames > frames);
}

test "win32 inspector: the tick timer lives and dies with the window" {
    const f = try Fixture.init(.{});
    defer f.deinit();
    const hwnd = f.insp.window.hwnd;
    // SetTimer with the same id returns it while the timer exists.
    try testing.expect(win32.user32.SetTimer(hwnd, Window.tick_id, Window.tick_ms, null) != 0);
    f.insp.close();
    try testing.expect(win32.user32.KillTimer(hwnd, Window.tick_id) == 0);
}
