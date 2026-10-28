//! Graphics API wrapper for Direct3D 11.
//!
//! Implements the GraphicsAPI contract that `generic.zig` relies on (see
//! docs/windows/SPEC.md §6.1). Renders headless into `Target`s until the
//! apprt hands over a `PresentTarget`.
pub const D3D11 = @This();

const std = @import("std");
const win32 = @import("win32");
const Allocator = std.mem.Allocator;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const global = @import("../global.zig");
const latency = @import("../os/main.zig").windows_latency;
const windows_os = @import("../os/main.zig").windows;
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(D3D11);
pub const Device = @import("d3d11/Device.zig");

pub const GraphicsAPI = D3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const Decor = @import("d3d11/Decor.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const SwapChain = @import("d3d11/SwapChain.zig");
pub const shaders = @import("d3d11/shaders.zig");
pub const hlsl = @import("d3d11/hlsl.zig");
pub const slots = @import("d3d11/slots.zig");

// Custom shaders are converted from shadertoy GLSL to HLSL (SPIR-V Cross).
pub const custom_shader_target: shadertoy.Target = .hlsl;
// D3D11 is Y-down like Metal.
pub const custom_shader_y_is_down = true;

/// Generic's per-frame states each hold a full-size target plus atlas
/// copies. D3D11 renames dynamic buffers on `WRITE_DISCARD` and caps
/// queueing with a maximum frame latency of 1, so more would buy nothing.
pub const swap_chain_count = 1;

const log = std.log.scoped(.d3d11);

/// How long the render thread waits for a free frame slot. The wait is
/// bounded so a swap chain that never signals (occluded, minimized) cannot
/// stall the thread, which also has to notice that it should exit.
const frame_slot_wait_ms = 100;

/// Where the swap chain presents. Provided by the apprt through an optional
/// `d3d11PresentTarget` decl on its Surface; null means headless.
pub const PresentTarget = struct {
    /// HWND of the surface child window.
    hwnd: *anyopaque,

    /// Physical client size packed with `packSize`, written by the UI
    /// thread on WM_SIZE.
    size: *const std.atomic.Value(u64),

    /// The surface's id, tagging latency trace samples.
    id: u32 = 0,

    /// Bumped by the apprt (UI thread) after the window changed parents.
    /// `SetParent` normally keeps a flip-model swap chain presenting, so a
    /// bump alone changes nothing: the render thread recreates the swap
    /// chain only when a present then fails (see `recreateOnPresentFailure`).
    /// Null: never bumped.
    generation: ?*const std.atomic.Value(u32) = null,

    /// Decoration word written by the apprt (UI thread): unfocused-split
    /// dimming and the bell border, read by the render thread each frame.
    /// Null: no decorations.
    decor: ?*const std.atomic.Value(u64) = null,

    /// Swap chain mode written by the apprt (UI thread): 0 = hwnd, 1 =
    /// composition (transparency). Read when a swap chain is (re)created; a
    /// value that differs from the live chain's mode replaces the chain on
    /// the next frame. Null: always hwnd.
    ///
    /// Contract: the renderer reads this only while drawing a frame, so the
    /// apprt follows every store with a refresh of the surface. Switching to
    /// 0 requires the apprt to release the DComp target BEFORE the store:
    /// `CreateSwapChainForHwnd` fails (WINDOW_ALREADY_COMPOSED) while the
    /// window is composed, and would be retried on every drawn frame.
    /// A minimised window needs no throttle here: the apprt's occlusion
    /// path (`Window.setMinimized` -> `Tab.applyOcclusion` -> core
    /// `visible = false`) stops drawing, and the restore redraws.
    mode: ?*const std.atomic.Value(u8) = null,

    /// Receives every composition swap chain once its first frame was
    /// presented: a visual given an empty chain shows the window's backdrop.
    /// Null: nobody can show a composition chain, so the mode is ignored.
    hand_off: ?HandOff = null,

    /// Called under the context lock, on the render thread or on the UI
    /// thread (a sync draw during resize presents too), right after the
    /// first successful present of a composition swap chain that was
    /// created or recreated, with one reference held for the callee. The callee must not call back into the
    /// renderer or wait for the UI thread (post-only): it stores the chain (releasing a previous
    /// one) and posts a wakeup, and the UI thread then does `SetContent` and
    /// `Commit`. `generation` is the target's generation the chain was
    /// created with. hwnd mode never calls it.
    pub const HandOff = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, swap_chain: *win32.dxgi.IDXGISwapChain1, generation: u32) void,
    };
};

/// Pack a size into one word so it can be read and written atomically.
/// The width lives in the high 32 bits.
pub fn packSize(w: u32, h: u32) u64 {
    return (@as(u64, w) << 32) | h;
}

/// The inverse of `packSize`.
pub fn unpackSize(v: u64) struct { width: u32, height: u32 } {
    return .{
        .width = @intCast(v >> 32),
        .height = @truncate(v),
    };
}

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *Device,

/// Where the swap chain presents; null while headless. Set by
/// `threadEnter`.
present_target: ?PresentTarget = null,

/// The swap chain of `present_target`. Created by `threadEnter` or, if the
/// window had no size yet, by the first frame; released by `threadExit`.
/// Only touched under the device context lock.
swap_chain: ?SwapChain = null,

/// The window and the `PresentTarget.generation` `swap_chain` was created
/// (or last presented successfully) with. Same locking as `swap_chain`.
swap_chain_hwnd: ?*anyopaque = null,
swap_chain_generation: u32 = 0,

/// The chain a mode change replaced, kept (its content stays on screen)
/// until the new chain presented once. Same locking as `swap_chain`.
retired_chain: ?SwapChain = null,

/// `swap_chain` is a composition chain not handed off yet: it goes to the
/// apprt with its first frame (`framePresented`). Same locking as `swap_chain`.
hand_off_pending: bool = false,

/// Whether presents wait for the vertical blank (config `window-vsync`).
vsync: bool = true,

/// Set once a swap chain failure was logged, so a broken swap chain logs
/// once rather than once per frame.
swap_chain_failure_logged: bool = false,

/// The size `setViewport` last reported. Headless `surfaceSize` returns it.
viewport: struct { width: u32, height: u32 } = .{ .width = 0, .height = 0 },

/// `GHOSTTY_D3D11_PACING_LOG=1`: log the slot wait and build time of every
/// frame. `frame_begin_ns` and `frame_slot_ns` belong to the frame in flight.
pacing_log: bool = false,
frame_begin_ns: u64 = 0,
frame_slot_ns: u64 = 0,

/// The decor pass, created by the first frame whose decor word is non-zero.
/// Only touched under the device context lock.
decor_pass: ?Decor = null,

/// Set once creating the decor pass failed, so it is not retried every frame.
decor_failed: bool = false,

/// Frame dump state, or null if `GHOSTTY_D3D11_DUMP` is unset.
dump: ?Frame.Dump = null,

/// Set by `displayRealized` (UI thread) when this renderer's device was lost:
/// the render thread then moves to a fresh device (`recoverDevice`).
reacquire_pending: std.atomic.Value(bool) = .init(false),

/// Guards the swap of `device` against `deviceLost` reads from the UI
/// thread. Everything else reads `device` on the render thread, which is
/// also the only thread that swaps it.
device_mutex: std.Io.Mutex = .init,

/// Set while the last attempt to get a new device failed (no GPU, no WARP);
/// the recovery then backs off instead of counting a repeated loss.
recover_failed: std.atomic.Value(bool) = .init(false),

/// Per-process counter handing out `dump` file indices.
var next_renderer_index: std.atomic.Value(usize) = .init(0);

pub fn init(
    alloc: Allocator,
    device: *Device,
    opts: rendererpkg.Options,
) !D3D11 {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .vsync = opts.config.vsync,
        .device = device,
        .pacing_log = pacingLogFromEnv(alloc),
        .dump = Frame.Dump.initFromEnv(
            alloc,
            next_renderer_index.fetchAdd(1, .monotonic),
        ),
    };
}

fn pacingLogFromEnv(alloc: Allocator) bool {
    const v = windows_os.diagnosticEnv(alloc, "GHOSTTY_D3D11_PACING_LOG") orelse return false;
    defer alloc.free(v);
    return std.mem.eql(u8, v, "1");
}

pub fn deinit(self: *D3D11) void {
    if (self.dump) |*d| d.deinit(self.alloc);
    // The GPU resources were released on the render thread already.
    if (self.device.pool_alloc != null) Device.release(self.device);
    self.* = undefined;
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread.
pub fn threadEnter(self: *D3D11, surface: *apprt.Surface) !void {
    // Apprts without a window (`app_runtime = none`) render headless.
    if (comptime @hasDecl(apprt.Surface, "d3d11PresentTarget")) {
        self.present_target = surface.d3d11PresentTarget();
    }

    // A window without a size yet (or a minimized one) gets its swap chain
    // from the first frame that has one.
    if (self.present_target != null) {
        const size = try self.surfaceSize();
        if (size.width > 0 and size.height > 0) {
            self.device.lockContext();
            defer self.device.unlockContext();
            _ = self.swapChain(size.width, size.height) catch {};
        }
    }
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread. Releases the swap chain before the window can go away: the
/// apprt destroys the window only after the render thread was joined.
pub fn threadExit(self: *D3D11) void {
    if (self.decor_pass != null) {
        self.device.lockContext();
        defer self.device.unlockContext();
        self.decor_pass.?.deinit();
        self.decor_pass = null;
    }

    if (self.swap_chain != null or self.retired_chain != null) {
        self.device.lockContext();
        defer self.device.unlockContext();
        self.dropSwapChain();
    }

    self.present_target = null;
}

/// The swap chain of the present target, created at the given size if it
/// does not exist yet. Failure is logged once and returned. The caller
/// holds the context lock.
pub fn swapChain(self: *D3D11, width: u32, height: u32) !*SwapChain {
    const target = self.present_target orelse return error.InvalidArgument;
    const mode = currentMode(target);
    if (self.swap_chain) |*sc| {
        if (self.swap_chain_hwnd == target.hwnd) {
            if (sc.mode == mode) return sc;
            // The apprt switched modes: the old chain keeps showing its last
            // frame until the new one presented (`presentSucceeded`). For
            // hwnd -> composition that present is visible only after the
            // UI thread's SetContent + Commit, so one gap frame is possible
            // (Task 15 may release on a committed-generation ack instead).
            self.retireSwapChain();
        } else {
            // The apprt handed over another window: the chain belongs to the old one.
            self.dropSwapChain();
        }
    }

    self.swap_chain_hwnd = target.hwnd;
    self.swap_chain_generation = currentGeneration(target);
    self.swap_chain = SwapChain.init(self.device, target.hwnd, width, height, mode) catch |err| {
        self.logSwapChainFailure("create", err);
        return err;
    };
    const sc = &self.swap_chain.?;
    sc.surface_id = target.id;
    self.hand_off_pending = mode == .composition;
    return sc;
}

/// Per-frame uniforms: a frame for a composition chain premultiplies in sRGB
/// space (`shaders/hlsl/common.hlsli` `load_color`), the way DWM blends it.
pub fn adjustUniforms(self: *const D3D11, uniforms: *shaders.Uniforms) void {
    const target = self.present_target orelse return;
    // The chain this frame is drawn into, else the one it will get.
    const mode = if (self.swap_chain) |*sc| sc.mode else currentMode(target);
    uniforms.bools.composition = self.blending.isLinear() and mode == .composition;
}

/// The mode to create a chain in: composition only when the apprt asked
/// for it and can take the chain.
fn currentMode(target: PresentTarget) SwapChain.Mode {
    const m = target.mode orelse return .hwnd;
    if (target.hand_off == null) return .hwnd;
    return if (m.load(.acquire) == 1) .composition else .hwnd;
}

fn handOff(self: *D3D11, target: PresentTarget, sc: *SwapChain) void {
    const hand_off = target.hand_off orelse return;
    // The callee owns this reference.
    const ref = win32.com.queryInterface(sc.chain, win32.dxgi.IDXGISwapChain1) catch |err| {
        self.logSwapChainFailure("hand-off", err);
        return;
    };
    hand_off.func(hand_off.ctx, ref, self.swap_chain_generation);
}

/// Moves the live chain aside so a new one of another mode can be created.
/// A chain retired earlier is released first. The caller holds the lock.
fn retireSwapChain(self: *D3D11) void {
    self.releaseRetired();
    self.retired_chain = self.swap_chain;
    self.swap_chain = null;
}

fn releaseRetired(self: *D3D11) void {
    const old = if (self.retired_chain) |*old| old else return;
    self.device.assertContextLocked();
    self.device.context.clearState();
    self.device.context.flush();
    old.deinit();
    self.retired_chain = null;
}

fn currentGeneration(target: PresentTarget) u32 {
    return if (target.generation) |g| g.load(.acquire) else 0;
}

/// Releases the swap chain so the next `swapChain` creates a new one: the
/// context is cleared and flushed first, because DXGI destroys a swap chain
/// lazily while the context still references its back buffers, which makes
/// `CreateSwapChainForHwnd` on the same window fail with E_ACCESSDENIED.
/// `SwapChain.deinit` closes the frame latency waitable; the new chain
/// starts with a fresh `Pacer`. The caller holds the context lock.
pub fn dropSwapChain(self: *D3D11) void {
    self.device.assertContextLocked();
    self.releaseRetired();
    const sc = if (self.swap_chain) |*sc| sc else return;
    self.device.context.clearState();
    self.device.context.flush();
    sc.deinit();
    self.swap_chain = null;
}

/// Whether a failed present may come from a window that changed parents
/// since the swap chain was bound to it. Only then is the chain recreated:
/// a bump alone does not break presenting. Returns true when the chain was
/// dropped and the present is worth retrying. The caller holds the lock.
pub fn recreateOnPresentFailure(self: *D3D11, err: anyerror) bool {
    switch (err) {
        // INVALID_CALL / E_ACCESSDENIED arrive as the unmapped `ComFailure`.
        // `InvalidArgument` (a zero-size target) is not a window problem.
        error.ComFailure => {},
        else => return false,
    }
    const target = self.present_target orelse return false;
    if (self.swap_chain == null) return false;
    if (currentGeneration(target) == self.swap_chain_generation) return false;

    log.info("d3d11 present failed after the window changed parents, recreating the swap chain err={}", .{err});
    self.dropSwapChain();
    return true;
}

/// The generation to hand to `presentSucceeded`, read BEFORE the present: a
/// bump that lands during the present must stay unaccepted.
pub fn presentGeneration(self: *const D3D11) u32 {
    const target = self.present_target orelse return 0;
    return currentGeneration(target);
}

/// Called after a successful present with the generation read before it: the
/// chain worked with that window state, so older bumps need no recreation.
pub fn presentSucceeded(self: *D3D11, generation: u32) void {
    self.swap_chain_generation = generation;
    // The replacement showed a frame: the old chain is no longer needed.
    self.releaseRetired();
    // A later failure is news again.
    self.swap_chain_failure_logged = false;
    self.framePresented();
}

/// After a successful present of `swap_chain`: a composition chain goes to
/// the apprt now, with a frame in it. The caller holds the lock.
pub fn framePresented(self: *D3D11) void {
    if (!self.hand_off_pending) return;
    self.device.assertContextLocked();
    self.hand_off_pending = false;
    const target = self.present_target orelse return;
    const sc = if (self.swap_chain) |*sc| sc else return;
    if (sc.mode == .composition) self.handOff(target, sc);
}

/// Logs a swap chain failure the first time only, until a present succeeds.
pub fn logSwapChainFailure(self: *D3D11, what: []const u8, err: anyerror) void {
    if (self.swap_chain_failure_logged) return;
    self.swap_chain_failure_logged = true;
    log.err("d3d11 swap chain {s} failed err={}, the surface may not show frames", .{ what, err });
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    const target = self.present_target orelse return .{
        .width = self.viewport.width,
        .height = self.viewport.height,
    };

    const size = unpackSize(target.size.load(.acquire));
    const max = self.device.max_texture_size;
    return .{
        .width = @min(size.width, max),
        .height = @min(size.height, max),
    };
}

/// Set the viewport to cover the given size in device pixels.
pub fn setViewport(self: *D3D11, width: u32, height: u32) void {
    self.viewport = .{ .width = width, .height = height };
}

/// Marks the shared device lost with the reason it reports (`Device.markLost`
/// logs the loss once).
pub fn noteDeviceLost(self: *D3D11) void {
    self.device.markLostFromDevice();
}

/// Called by the generic renderer when drawing a frame failed, from any
/// step before `Frame.complete`: a lost device is recorded.
pub fn frameFailed(self: *D3D11, err: anyerror) void {
    if (err == error.DeviceLost) return self.noteDeviceLost();
    self.device.device.checkDeviceRemoved() catch self.noteDeviceLost();
}

/// Whether the device is lost and nobody is replacing it yet: the renderer
/// draws nothing more. Render thread (or under the draw mutex).
pub fn isLost(self: *const D3D11) bool {
    if (self.reacquire_pending.load(.acquire)) return false;
    return self.device.isLost();
}

/// Whether the recovery has to act: the device is lost and no
/// `displayRealized` asked for a replacement yet. Any thread.
pub fn deviceLost(self: *const D3D11) bool {
    if (self.reacquire_pending.load(.acquire)) return false;
    const mutex: *std.Io.Mutex = @constCast(&self.device_mutex);
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());
    return self.device.isLost();
}

/// Called by the generic renderer from `displayRealized` (UI thread). A
/// lost device is replaced by the render thread at its next opportunity
/// (`recoverDevice`); with a healthy one nothing happens.
pub fn displayRealized(self: *D3D11) void {
    if (!self.deviceLost()) return;
    self.reacquire_pending.store(true, .release);
}

/// Whether the last attempt to get a new device failed. Any thread.
pub fn deviceRecoverFailed(self: *const D3D11) bool {
    return self.recover_failed.load(.acquire);
}

/// Whether `displayRealized` asked for a replacement device. Cheap, any thread.
pub fn deviceChangePending(self: *const D3D11) bool {
    return self.reacquire_pending.load(.acquire);
}

/// Moves to a fresh device generation: drops the decor pass and the swap
/// chain (the next frame creates a new chain, handing a composition chain
/// off again) and gives the lost device back. The caller (render thread,
/// draw mutex held) has released everything it created from the old
/// device. Returns false when no replacement could be made; the renderer
/// then stays lost and the recovery tries again.
pub fn recoverDevice(self: *D3D11) bool {
    if (!self.reacquire_pending.swap(false, .acq_rel)) return false;
    const old = self.device;
    if (!old.isLost() or old.pool_alloc == null) return false;

    {
        old.lockContext();
        defer old.unlockContext();
        if (self.decor_pass) |*d| d.deinit();
        self.decor_pass = null;
        self.decor_failed = false;
        self.dropSwapChain();
    }

    const fresh = Device.acquire(self.alloc) catch |err| {
        log.err("d3d11 could not create a new device err={}", .{err});
        self.recover_failed.store(true, .release);
        return false;
    };
    {
        self.device_mutex.lockUncancelable(global.io());
        defer self.device_mutex.unlock(global.io());
        self.device = fresh;
    }
    Device.release(old);
    self.swap_chain_failure_logged = false;
    self.recover_failed.store(false, .release);
    log.info("d3d11 renderer recovered generation={d}", .{fresh.generation});
    return true;
}

/// Actions taken before doing anything in `drawFrame`. The immediate
/// context is not thread safe: it is ours until `drawFrameEnd`.
pub fn drawFrameStart(self: *D3D11) void {
    self.device.lockContext();
}

/// Milliseconds until a frame skipped by the dump throttle has to be
/// redrawn so that it gets dumped; null without a dump or a pending frame.
pub fn dumpWakeMs(self: *const D3D11) ?u64 {
    const d = self.dump orelse return null;
    return d.trailingDelayMs(.now(global.io(), .awake));
}

/// Actions taken after `drawFrame` is done. Releases the context lock.
pub fn drawFrameEnd(self: *D3D11) void {
    self.device.unlockContext();
    // The frame dump's file I/O stays out of the context lock.
    if (self.dump) |*d| d.flush(self.alloc);
}

/// Draws the apprt's decorations (`PresentTarget.decor`) over `target`.
/// Nothing happens, and nothing is allocated, while the word is zero. The
/// caller holds the context lock.
pub fn drawDecor(self: *D3D11, target: *const Target) void {
    const word_ptr = (self.present_target orelse return).decor orelse return;
    const word: Decor.Word = @bitCast(word_ptr.load(.monotonic));
    if (word.isZero()) return;

    if (self.decor_pass == null) {
        if (self.decor_failed) return;
        self.decor_pass = Decor.init(self.device) catch |err| {
            log.warn("unable to create the decor pass err={}", .{err});
            self.decor_failed = true;
            return;
        };
    }
    self.decor_pass.?.draw(target, word);
}

/// Blocks until the swap chain has a free frame slot. Nothing to wait for
/// until a swap chain exists and a frame was presented.
///
/// Render thread, called by the renderer before it takes its draw mutex
/// (a sync draw on the UI thread is never held up by this wait). Polls
/// first: a free slot, or a chain idle for longer than a refresh interval,
/// costs one syscall under the context lock. Only a busy chain is waited
/// on, without the lock, so one surface pacing itself does not hold up the
/// others. A sync draw may drop the chain meanwhile (`dropSwapChain`), so
/// the wait holds its own handle and is booked only on the same chain.
pub fn waitFrameSlot(self: *D3D11) void {
    self.device.lockContext();
    defer self.device.unlockContext();

    const sc = if (self.swap_chain) |*sc| sc else return;
    if (!sc.waitArmed()) return;
    if (sc.waitForSlot(0) or sc.idle()) return;

    const w = sc.beginUnlockedWait() orelse return;
    const timed = latency.enabled() or self.pacing_log;
    const start = if (timed) nowNs() else 0;
    const result = unlocked: {
        self.device.unlockContext();
        defer self.device.lockContext();
        break :unlocked w.wait(frame_slot_wait_ms);
    };
    if (self.swap_chain) |*current| current.finishUnlockedWait(w, result);
    if (timed) {
        const waited = nowNs() -| start;
        self.frame_slot_ns = waited;
        latency.markSlotWait(waited);
    }
}

/// A frame takes a slot freed since `waitFrameSlot`, or one a synchronous
/// draw (UI thread, e.g. during resize) owes the waitable. Never blocks:
/// the caller holds the draw mutex and the context lock.
fn pollFrameSlot(self: *D3D11) void {
    const sc = if (self.swap_chain) |*sc| sc else return;
    if (sc.waitArmed()) _ = sc.waitForSlot(0);
}

fn nowNs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toNanoseconds()));
}

/// `GHOSTTY_D3D11_PACING_LOG=1`: one line per frame, from the end of the
/// slot wait to the end of the present.
pub fn logPacing(self: *D3D11) void {
    // The slot wait belongs to the frame that just ended; the next starts at 0.
    defer self.frame_slot_ns = 0;
    if (!self.pacing_log) return;
    const build = nowNs() -| self.frame_begin_ns;
    log.info("d3d11 pacing slot_wait_ms={d:.3} build_ms={d:.3}", .{
        @as(f64, @floatFromInt(self.frame_slot_ns)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(build)) / std.time.ns_per_ms,
    });
}

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    // After a device loss with a custom shader active, no custom shaders
    // (`recovery.zig`): the generic renderer then draws straight to the target.
    const custom = if (Device.customShadersDisabled()) &.{} else custom_shaders;
    return try shaders.Shaders.init(alloc, self.device, custom);
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.initShared(.{
        .device = self.device,
        .width = width,
        .height = height,
        // An `*_SRGB` view makes the hardware encode the pixels written to
        // it *after* blending, which gives linear alpha blending rather
        // than gamma-incorrect blending.
        .srgb = self.blending.isLinear(),
    });
}

/// Returns the options to use when constructing buffers that hold
/// per-instance vertex data.
pub inline fn instanceBufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .device = self.device, .role = .vertex };
}

pub const fgBufferOptions = instanceBufferOptions;
pub const imageBufferOptions = instanceBufferOptions;
pub const bgImageBufferOptions = instanceBufferOptions;

/// Returns the options to use when constructing the cell background
/// buffer, which is read as a structured buffer.
pub inline fn bgBufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .device = self.device, .role = .structured };
}

/// Returns the options to use when constructing the uniform buffer.
pub inline fn uniformBufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .device = self.device, .role = .constant };
}

/// Returns the options to use when constructing textures. Custom shader
/// ping-pong textures are typeless: the scene is drawn into them through
/// the target's views, and the custom shader passes sample and write the
/// raw stored values (`srv`, `gamma_rtv`), as shadertoy math expects.
pub inline fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .device = self.device,
        .format = .B8G8R8A8_TYPELESS,
        .srv_format = .B8G8R8A8_UNORM,
        .render_target = true,
        .rtv_format = if (self.blending.isLinear()) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM,
        .gamma_rtv = self.blending.isLinear(),
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: D3D11) Sampler.Options {
    return .{ .device = self.device, .filter = .linear };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    const dxgi_format: win32.dxgi.Format = switch (format) {
        // DXGI has no sRGB variant of a single channel format.
        .gray => .R8_UNORM,
        .rgba => if (srgb) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM,
        .bgra => if (srgb) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM,
    };
    return .{ .device = self.device, .format = dxgi_format, .srv_format = dxgi_format };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const D3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: win32.dxgi.Format = switch (atlas.format) {
        .grayscale => .R8_UNORM,
        .bgra => .B8G8R8A8_UNORM_SRGB,
        else => @panic("unsupported atlas format for D3D11 texture"),
    };

    return try Texture.init(
        .{ .device = self.device, .format = format, .srv_format = format },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame. The caller holds the context lock (`drawFrameStart`).
pub inline fn beginFrame(
    self: *D3D11,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    self.pollFrameSlot();
    if (self.pacing_log) self.frame_begin_ns = nowNs();
    return try Frame.begin(.{ .api = self }, renderer, target);
}

test "d3d11 stub: size packing roundtrip" {
    const packed_size = packSize(3840, 2160);
    try std.testing.expectEqual(@as(u64, (3840 << 32) | 2160), packed_size);

    const size = unpackSize(packed_size);
    try std.testing.expectEqual(@as(u32, 3840), size.width);
    try std.testing.expectEqual(@as(u32, 2160), size.height);

    // The extremes must not bleed into each other.
    const max = unpackSize(packSize(std.math.maxInt(u32), 0));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), max.width);
    try std.testing.expectEqual(@as(u32, 0), max.height);
}

fn testApi(blending: configpkg.Config.AlphaBlending) !D3D11 {
    const device = try Device.init(std.testing.allocator, .{ .driver = .warp });
    return .{
        .alloc = std.testing.allocator,
        .blending = blending,
        .device = device,
    };
}

test "d3d11 api: draw frame start and end own the context lock" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    api.drawFrameStart();
    api.device.assertContextLocked();
    api.drawFrameEnd();

    // Released: the lock can be taken again.
    api.drawFrameStart();
    api.drawFrameEnd();
}

test "d3d11 api: headless surface size is the viewport" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    const unset = try api.surfaceSize();
    try std.testing.expectEqual(@as(u32, 0), unset.width);
    try std.testing.expectEqual(@as(u32, 0), unset.height);

    api.setViewport(800, 600);
    const size = try api.surfaceSize();
    try std.testing.expectEqual(@as(u32, 800), size.width);
    try std.testing.expectEqual(@as(u32, 600), size.height);
}

test "d3d11 api: present target size is read and clamped" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    var packed_size: std.atomic.Value(u64) = .init(packSize(1024, 768));
    api.present_target = .{ .hwnd = undefined, .size = &packed_size };
    api.setViewport(1, 1);

    const size = try api.surfaceSize();
    try std.testing.expectEqual(@as(u32, 1024), size.width);
    try std.testing.expectEqual(@as(u32, 768), size.height);

    // A resize on the UI thread is seen by the next call.
    packed_size.store(packSize(100_000, 0), .release);
    const huge = try api.surfaceSize();
    try std.testing.expectEqual(api.device.max_texture_size, huge.width);
    try std.testing.expectEqual(@as(u32, 0), huge.height);
}

test "d3d11: surfaceSize 0x0 skips drawing" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    // A minimized window stores 0x0, which generic's `drawFrame` turns
    // into an early return before any frame, swap chain or wait.
    var packed_size: std.atomic.Value(u64) = .init(packSize(0, 0));
    api.present_target = .{ .hwnd = undefined, .size = &packed_size };

    const size = try api.surfaceSize();
    try std.testing.expectEqual(@as(u32, 0), size.width);
    try std.testing.expectEqual(@as(u32, 0), size.height);
    try std.testing.expect(api.swap_chain == null);

    // Restoring brings the size back.
    packed_size.store(packSize(640, 480), .release);
    const restored = try api.surfaceSize();
    try std.testing.expectEqual(@as(u32, 640), restored.width);
    try std.testing.expectEqual(@as(u32, 480), restored.height);
}

test "d3d11 pacing: no-op draws do not consume the latency slot" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    var target = try api.initTarget(32, 32);
    defer target.deinit();

    const io = @import("../global.zig").io();
    const Recorder = struct {
        fn completed(_: *anyopaque, _: rendererpkg.Health) void {}
    };
    var unused: u8 = 0;

    api.drawFrameStart();
    {
        var frame = try Frame.beginWithSink(
            .{ .api = &api },
            .{ .ptr = &unused, .completed = Recorder.completed },
            &target,
        );
        frame.complete(false);
    }
    api.drawFrameEnd();

    const sc = &api.swap_chain.?;
    // A hidden window may be reported occluded, which queues nothing.
    // Model a queued frame either way.
    sc.pacer.pending.store(1, .monotonic);

    // Draws that return before `beginFrame` (zero size, nothing changed)
    // only take and release the lock: they must not wait or touch the slot.
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..10) |_| {
        api.drawFrameStart();
        api.drawFrameEnd();
    }
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 20);
    try std.testing.expectEqual(@as(u32, 1), sc.pacer.pending.load(.monotonic));

    // The render thread takes the slot before its next draw (waits at most
    // `frame_slot_wait_ms`) and leaves the lock free for it.
    api.waitFrameSlot();
    api.drawFrameStart();
    api.drawFrameEnd();
}

test "d3d11 pacing: sync draws never block on the slot" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(16, 16));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    // A sync draw only reaches `beginFrame`, which polls.
    api.drawFrameStart();
    defer api.drawFrameEnd();
    const sc = try api.swapChain(16, 16);
    const io = @import("../global.zig").io();
    const never = try neverSignaled(sc);
    defer restoreWaitable(sc, never);
    sc.pacer.presented(nowNs());

    const start = std.Io.Timestamp.now(io, .awake);
    api.pollFrameSlot();
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < frame_slot_wait_ms);
    try std.testing.expectEqual(@as(u32, 1), sc.pacer.pending.load(.monotonic));
}

test "d3d11 frame slot: no lock is held during the wait" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(16, 16));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    const sc = sc: {
        api.device.lockContext();
        defer api.device.unlockContext();
        break :sc try api.swapChain(16, 16);
    };
    const never = try neverSignaled(sc);
    defer restoreWaitable(sc, never);
    sc.pacer.presented(nowNs());

    // The renderer calls `waitFrameSlot` before its draw mutex, so a sync
    // draw (here: the context lock it takes) gets through while the render
    // thread waits on a busy chain. The drawer starts well into the wait.
    const Drawer = struct {
        device: *Device,
        start: u64,
        drew: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            while (nowNs() -| self.start < 20 * std.time.ns_per_ms) std.atomic.spinLoopHint();
            self.device.lockContext();
            self.drew.store(true, .release);
            self.device.unlockContext();
        }
    };
    var drawer: Drawer = .{ .device = api.device, .start = nowNs() };
    const thread = try std.Thread.spawn(.{}, Drawer.run, .{&drawer});
    api.waitFrameSlot();
    const drew_during_wait = drawer.drew.load(.acquire);
    thread.join();
    try std.testing.expect(drew_during_wait);
    // The wait timed out: the present is still pending.
    try std.testing.expectEqual(@as(u32, 1), sc.pacer.pending.load(.monotonic));
}

/// Replaces the frame latency waitable of `sc` with an event that is never
/// set, so a wait on the chain always times out. Returns the original.
fn neverSignaled(sc: *SwapChain) !?win32.foundation.HANDLE {
    const event = win32.kernel32.CreateEventW(null, 1, 0, null) orelse
        return error.Unexpected;
    const original = sc.waitable;
    sc.waitable = event;
    return original;
}

fn restoreWaitable(sc: *SwapChain, original: ?win32.foundation.HANDLE) void {
    if (sc.waitable) |h| _ = win32.kernel32.CloseHandle(h);
    sc.waitable = original;
}

test "d3d11 frame slot: a chain dropped during the wait is not booked" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(16, 16));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const first = try api.swapChain(16, 16);
    first.pacer.presented(nowNs());
    const w = first.beginUnlockedWait() orelse return error.TestUnexpectedResult;

    // A sync draw drops the chain and presents on a new one meanwhile.
    api.dropSwapChain();
    const second = try api.swapChain(16, 16);
    second.pacer.presented(nowNs());

    // The duplicate outlives the dropped chain's handle.
    const result = w.wait(0);
    try std.testing.expect(result != .failed);
    second.finishUnlockedWait(w, .signaled);
    try std.testing.expectEqual(@as(u32, 1), second.pacer.pending.load(.monotonic));
}

test "d3d11 swapchain: no recreation without a bump" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var generation: std.atomic.Value(u32) = .init(0);
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .generation = &generation };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const first = try api.swapChain(32, 32);
    for (0..5) |_| try std.testing.expectEqual(first, try api.swapChain(32, 32));
    // Even a failed present does not recreate while the generation is unchanged.
    try std.testing.expect(!api.recreateOnPresentFailure(error.ComFailure));
    try std.testing.expectEqual(first, try api.swapChain(32, 32));
}

test "d3d11 swapchain: a bump alone keeps the swap chain, a failed present after it recreates" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var parent_a: SwapChain.TestWindow = try .init();
    defer parent_a.deinit();
    var parent_b: SwapChain.TestWindow = try .init();
    defer parent_b.deinit();
    var child: SwapChain.TestWindow = try .init();
    defer child.deinit();
    _ = win32.user32.SetParent(child.hwnd, parent_a.hwnd);

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var generation: std.atomic.Value(u32) = .init(0);
    api.present_target = .{ .hwnd = child.hwnd, .size = &packed_size, .generation = &generation };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const first = try api.swapChain(32, 32);
    try first.present(true);
    first.pacer.presented(0);
    const old_chain = first.chain;

    _ = win32.user32.SetParent(child.hwnd, parent_b.hwnd);
    _ = generation.fetchAdd(1, .release);

    // The bump alone changes nothing, other errors never recreate.
    try std.testing.expectEqual(old_chain, (try api.swapChain(32, 32)).chain);
    try std.testing.expect(!api.recreateOnPresentFailure(error.OutOfMemory));
    try std.testing.expectEqual(old_chain, api.swap_chain.?.chain);

    // A failed present after the bump drops the chain; the next one is new,
    // presents, and starts with a fresh pacer.
    try std.testing.expect(api.recreateOnPresentFailure(error.ComFailure));
    try std.testing.expect(api.swap_chain == null);
    const second = try api.swapChain(32, 32);
    try std.testing.expectEqual(@as(u32, 0), second.pacer.pending.load(.monotonic));
    try second.present(true);
    api.presentSucceeded(api.presentGeneration());
    try std.testing.expect(!api.recreateOnPresentFailure(error.ComFailure));
}

test "d3d11 swapchain: a successful present re-arms the failure log" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    // The error log fails the test runner, so only the flag is driven.
    api.swap_chain_failure_logged = true;
    api.logSwapChainFailure("create", error.OutOfMemory); // silent while armed
    api.presentSucceeded(0);
    try std.testing.expect(!api.swap_chain_failure_logged);
}

test "d3d11 swapchain: a bump between the present and its acceptance stays pending" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var generation: std.atomic.Value(u32) = .init(0);
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .generation = &generation };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);

    // The generation is read before the present; the UI thread re-parents
    // and bumps while it runs.
    const seen = api.presentGeneration();
    try sc.present(true);
    _ = generation.fetchAdd(1, .release);
    api.presentSucceeded(seen);

    // The next present fails: the bump must still allow the recreation.
    try std.testing.expect(api.recreateOnPresentFailure(error.ComFailure));
}

test "d3d11 swapchain: recreation releases every back-buffer reference first" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    _ = try api.swapChain(32, 32);

    // Dropping first (ClearState + Flush + release) must let the same
    // window get a new chain, repeatedly.
    for (0..3) |_| {
        api.dropSwapChain();
        const sc = try api.swapChain(32, 32);
        try sc.present(true);
    }
}

test "d3d11 swapchain: a different window recreates the swap chain" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var a: SwapChain.TestWindow = try .init();
    defer a.deinit();
    var b: SwapChain.TestWindow = try .init();
    defer b.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    api.present_target = .{ .hwnd = a.hwnd, .size = &packed_size };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    _ = try api.swapChain(32, 32);
    try std.testing.expectEqual(a.hwnd, @as(@TypeOf(a.hwnd), @ptrCast(api.swap_chain_hwnd.?)));
    api.present_target.?.hwnd = b.hwnd;
    const sc = try api.swapChain(32, 32);
    // A released COM object's address may be reused, so the binding is the proof.
    try std.testing.expectEqual(b.hwnd, @as(@TypeOf(b.hwnd), @ptrCast(api.swap_chain_hwnd.?)));
    try sc.present(true);
}

/// A hand-off that counts its calls and releases the reference like the apprt
/// does after `Commit`.
const FakeHandOff = struct {
    calls: u32 = 0,
    last_generation: u32 = 0,
    alpha: ?win32.dxgi.AlphaMode = null,

    fn func(ctx: *anyopaque, chain: *win32.dxgi.IDXGISwapChain1, generation: u32) void {
        const self: *FakeHandOff = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_generation = generation;
        if (chain.getDesc1()) |desc| self.alpha = desc.AlphaMode else |_| {}
        win32.com.release(chain);
    }

    fn handOff(self: *FakeHandOff) PresentTarget.HandOff {
        return .{ .ctx = self, .func = func };
    }
};

test "d3d11 swapchain: composition mode creates a premultiplied chain and hands it off once" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var fake: FakeHandOff = .{};
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .mode = &mode, .hand_off = fake.handOff() };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);
    try std.testing.expectEqual(SwapChain.Mode.composition, sc.mode);
    // Not before its first frame: an empty chain shows the backdrop.
    try std.testing.expectEqual(@as(u32, 0), fake.calls);
    try sc.present(true);
    api.presentSucceeded(api.presentGeneration());
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expectEqual(win32.dxgi.AlphaMode.PREMULTIPLIED, fake.alpha.?);

    // Later frames reuse the chain: no second hand-off.
    for (0..3) |_| {
        try std.testing.expectEqual(sc, try api.swapChain(32, 32));
        api.presentSucceeded(api.presentGeneration());
    }
    try std.testing.expectEqual(@as(u32, 1), fake.calls);

    // A composition target without a taker stays an hwnd chain.
    api.dropSwapChain();
    api.present_target.?.hand_off = null;
    try std.testing.expectEqual(SwapChain.Mode.hwnd, (try api.swapChain(32, 32)).mode);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "d3d11 swapchain: a composition chain is handed off by framePresented, once, and not after a drop" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var fake: FakeHandOff = .{};
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .mode = &mode, .hand_off = fake.handOff() };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    _ = try api.swapChain(32, 32);
    api.dropSwapChain();
    api.framePresented();
    try std.testing.expectEqual(@as(u32, 0), fake.calls);

    // The next chain goes with its own first frame, once.
    _ = try api.swapChain(32, 32);
    api.framePresented();
    api.framePresented();
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "d3d11 swapchain: mode change recreates the chain on the next frame" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var generation: std.atomic.Value(u32) = .init(0);
    var mode: std.atomic.Value(u8) = .init(0);
    var fake: FakeHandOff = .{};
    api.present_target = .{
        .hwnd = window.hwnd,
        .size = &packed_size,
        .generation = &generation,
        .mode = &mode,
        .hand_off = fake.handOff(),
    };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const hwnd_chain = (try api.swapChain(32, 32)).chain;
    try std.testing.expectEqual(@as(u32, 0), fake.calls);

    mode.store(1, .release);
    _ = generation.fetchAdd(1, .release);
    const sc = try api.swapChain(32, 32);
    try std.testing.expectEqual(SwapChain.Mode.composition, sc.mode);
    try std.testing.expect(sc.chain != hwnd_chain);
    try std.testing.expectEqual(@as(u32, 0), fake.calls);

    // The old chain stays until the new one presented, then goes, and the
    // new one is handed off with its frame.
    try std.testing.expect(api.retired_chain != null);
    try std.testing.expectEqual(hwnd_chain, api.retired_chain.?.chain);
    try sc.present(true);
    api.presentSucceeded(api.presentGeneration());
    try std.testing.expect(api.retired_chain == null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expectEqual(@as(u32, 1), fake.last_generation);

    // And back; a second switch before a present releases the first retiree.
    mode.store(0, .release);
    const back = try api.swapChain(32, 32);
    try std.testing.expectEqual(SwapChain.Mode.hwnd, back.mode);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expect(api.retired_chain != null);
    api.dropSwapChain();
    try std.testing.expect(api.retired_chain == null);
}

/// The reference count of a COM object, read with one AddRef/Release pair.
fn refCount(obj: *win32.com.IUnknown) u32 {
    _ = obj.vtable.AddRef(obj);
    return obj.vtable.Release(obj);
}

const HoldingHandOff = struct {
    held: ?*win32.dxgi.IDXGISwapChain1 = null,

    fn func(ctx: *anyopaque, chain: *win32.dxgi.IDXGISwapChain1, generation: u32) void {
        _ = generation;
        const self: *HoldingHandOff = @ptrCast(@alignCast(ctx));
        win32.com.release(self.held);
        self.held = chain;
    }
};

test "d3d11 swapchain: hand-off reference is balanced across create, retire and drop" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var holder: HoldingHandOff = .{};
    api.present_target = .{
        .hwnd = window.hwnd,
        .size = &packed_size,
        .mode = &mode,
        .hand_off = .{ .ctx = &holder, .func = HoldingHandOff.func },
    };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);
    const unknown: *win32.com.IUnknown = @ptrCast(sc.chain);
    try std.testing.expect(holder.held == null);
    api.framePresented();
    const held = holder.held.?;

    // The chain's own reference plus the one the callee holds.
    const with_callee = refCount(unknown);
    win32.com.release(holder.held);
    holder.held = null;
    try std.testing.expectEqual(with_callee - 1, refCount(unknown));

    // A recreate hands off a new reference and does not touch the old chain's.
    mode.store(0, .release);
    const hwnd_sc = try api.swapChain(32, 32);
    try std.testing.expectEqual(SwapChain.Mode.hwnd, hwnd_sc.mode);
    api.framePresented();
    try std.testing.expect(holder.held == null);
    _ = held;
    mode.store(1, .release);
    api.dropSwapChain();
    const again = try api.swapChain(32, 32);
    const again_unknown: *win32.com.IUnknown = @ptrCast(again.chain);
    api.framePresented();
    const base = refCount(again_unknown);
    try std.testing.expect(holder.held != null);
    win32.com.release(holder.held);
    holder.held = null;
    try std.testing.expectEqual(base - 1, refCount(again_unknown));
}

test "d3d11 swapchain: composition resize keeps the hand-off count" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var fake: FakeHandOff = .{};
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .mode = &mode, .hand_off = fake.handOff() };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);
    var target = try api.initTarget(48, 40);
    defer target.deinit();
    try sc.copyToBackbuffer(api.device.context, &target);
    try std.testing.expectEqual(@as(u32, 48), sc.width);
    try std.testing.expectEqual(@as(u32, 40), sc.height);
    try sc.present(true);
    api.presentSucceeded(api.presentGeneration());
    try std.testing.expectEqual(sc, try api.swapChain(48, 40));
    api.presentSucceeded(api.presentGeneration());
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "d3d11 swapchain: waitable pacing in composition mode" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var fake: FakeHandOff = .{};
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .mode = &mode, .hand_off = fake.handOff() };
    defer api.threadExit();

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);
    try std.testing.expect(sc.waitable != null);
    try std.testing.expect(!sc.waitArmed());

    // As in hwnd mode: a present arms the wait, a wait consumes it.
    try sc.present(true);
    try std.testing.expect(sc.waitArmed());
    try std.testing.expect(sc.waitForSlot(frame_slot_wait_ms));
    try std.testing.expect(!sc.waitArmed());
}

test "d3d11 api: blending selects the target and texture formats" {
    var linear = try testApi(.linear);
    defer linear.device.deinit(std.testing.allocator);
    var native = try testApi(.native);
    defer native.device.deinit(std.testing.allocator);

    var linear_target = try linear.initTarget(4, 4);
    defer linear_target.deinit();
    var native_target = try native.initTarget(4, 4);
    defer native_target.deinit();
    // Both are typeless textures; the views differ.
    try std.testing.expectEqual(win32.dxgi.Format.B8G8R8A8_TYPELESS, linear_target.texture.format);
    try std.testing.expectEqual(win32.dxgi.Format.B8G8R8A8_TYPELESS, native_target.texture.format);

    try std.testing.expectEqual(win32.dxgi.Format.B8G8R8A8_UNORM_SRGB, linear.textureOptions().rtv_format);
    try std.testing.expectEqual(win32.dxgi.Format.B8G8R8A8_UNORM, native.textureOptions().rtv_format);
}

test "d3d11 api: image texture formats are total" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);

    const Format = win32.dxgi.Format;
    try std.testing.expectEqual(Format.R8_UNORM, api.imageTextureOptions(.gray, false).format);
    try std.testing.expectEqual(Format.R8_UNORM, api.imageTextureOptions(.gray, true).format);
    try std.testing.expectEqual(Format.R8G8B8A8_UNORM, api.imageTextureOptions(.rgba, false).format);
    try std.testing.expectEqual(Format.R8G8B8A8_UNORM_SRGB, api.imageTextureOptions(.rgba, true).format);
    try std.testing.expectEqual(Format.B8G8R8A8_UNORM, api.imageTextureOptions(.bgra, false).format);
    try std.testing.expectEqual(Format.B8G8R8A8_UNORM_SRGB, api.imageTextureOptions(.bgra, true).format);

    // The views read the format the resource was created with.
    const opts = api.imageTextureOptions(.bgra, true);
    try std.testing.expectEqual(opts.format, opts.srv_format);
}

/// A headless API on a shared device from `Device.acquire`, on WARP.
fn sharedApi() !D3D11 {
    Device.preferWarp();
    return .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .device = try Device.acquire(std.testing.allocator),
    };
}

fn lose(api: *D3D11) void {
    Device.markLost(api.device, win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
}

test "d3d11 device: renderers re-acquire a fresh generation after realize" {
    defer Device.resetPreferWarp();
    defer Device.shutdown();
    var a = try sharedApi();
    var b = try sharedApi();
    try std.testing.expectEqual(a.device, b.device);
    const old_generation = a.device.generation;

    // Nothing to recover while the device is healthy.
    try std.testing.expect(!a.deviceLost());
    a.displayRealized();
    try std.testing.expect(!a.deviceChangePending());

    lose(&a);
    try std.testing.expect(a.deviceLost());
    try std.testing.expect(b.deviceLost());
    try std.testing.expect(a.isLost());

    // Realizing asks for a new device; the renderer is no longer "lost" to the
    // sweep that asked, and draws again.
    a.displayRealized();
    b.displayRealized();
    try std.testing.expect(a.deviceChangePending());
    try std.testing.expect(!a.deviceLost());
    try std.testing.expect(!a.isLost());

    // The render threads move over; the lost generation is freed with the last
    // of them (the allocator reports a leak otherwise).
    try std.testing.expect(a.recoverDevice());
    try std.testing.expect(b.recoverDevice());
    try std.testing.expectEqual(a.device, b.device);
    try std.testing.expect(a.device.generation > old_generation);
    try std.testing.expect(!a.device.isLost());
    try std.testing.expect(!a.deviceChangePending());

    Device.release(a.device);
    Device.release(b.device);
}

test "d3d11 device: composition chain handed off again after recovery" {
    defer Device.resetPreferWarp();
    defer Device.shutdown();
    var api = try sharedApi();
    defer Device.release(api.device);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(32, 32));
    var mode: std.atomic.Value(u8) = .init(1);
    var fake: FakeHandOff = .{};
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .mode = &mode, .hand_off = fake.handOff() };
    defer api.threadExit();

    {
        api.device.lockContext();
        defer api.device.unlockContext();
        _ = try api.swapChain(32, 32);
        api.framePresented();
    }
    try std.testing.expectEqual(@as(u32, 1), fake.calls);

    lose(&api);
    api.displayRealized();
    try std.testing.expect(api.recoverDevice());
    try std.testing.expect(api.swap_chain == null);

    api.device.lockContext();
    defer api.device.unlockContext();
    const sc = try api.swapChain(32, 32);
    try std.testing.expectEqual(SwapChain.Mode.composition, sc.mode);
    api.framePresented();
    try std.testing.expectEqual(@as(u32, 2), fake.calls);
}

test "d3d11 device: custom shaders are skipped once a loss disabled them" {
    defer Device.resetPreferWarp();
    defer Device.resetCustomShadersDisabled();
    defer Device.shutdown();
    var api = try sharedApi();
    defer Device.release(api.device);

    Device.disableCustomShaders();
    var built = try api.initShaders(std.testing.allocator, &.{"void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }"});
    defer built.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), built.post_pipelines.len);
}

test {
    _ = hlsl;
    _ = slots;
    _ = Pipeline;
    _ = RenderPass;
    _ = Target;
    _ = Frame;
    _ = Decor;
    _ = SwapChain;
}
