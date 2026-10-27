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

// Custom shaders are GLSL-sourced until a later milestone adds HLSL
// output; until then they are logged and skipped.
pub const custom_shader_target: shadertoy.Target = .glsl;
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

/// Frame dump state, or null if `GHOSTTY_D3D11_DUMP` is unset.
dump: ?Frame.Dump = null,

/// Set once a device loss was logged, so a lost device logs once rather
/// than once per frame.
device_lost_logged: bool = false,

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
    if (self.swap_chain != null) {
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
    if (self.swap_chain) |*sc| {
        if (self.swap_chain_hwnd == target.hwnd) return sc;
        // The apprt handed over another window: the chain belongs to the old one.
        self.dropSwapChain();
    }

    self.swap_chain_hwnd = target.hwnd;
    self.swap_chain_generation = currentGeneration(target);
    self.swap_chain = SwapChain.init(self.device, target.hwnd, width, height, .hwnd) catch |err| {
        self.logSwapChainFailure("create", err);
        return err;
    };
    self.swap_chain.?.surface_id = target.id;
    return &self.swap_chain.?;
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
    // A later failure is news again.
    self.swap_chain_failure_logged = false;
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

/// Marks the shared device lost with the reason it reports and logs it
/// once for this renderer.
pub fn noteDeviceLost(self: *D3D11) void {
    self.device.markLostFromDevice();
    if (self.device_lost_logged) return;
    self.device_lost_logged = true;
    log.err("d3d11 device lost reason=0x{x:0>8}, the surface will not draw", .{
        @as(u32, @bitCast(self.device.lost_reason.load(.monotonic))),
    });
}

/// Called by the generic renderer when drawing a frame failed, from any
/// step before `Frame.complete`: a lost device is recorded.
pub fn frameFailed(self: *D3D11, err: anyerror) void {
    if (err == error.DeviceLost) return self.noteDeviceLost();
    self.device.device.checkDeviceRemoved() catch self.noteDeviceLost();
}

/// Whether the device is lost: the renderer draws nothing more.
pub fn isLost(self: *const D3D11) bool {
    return self.device.isLost();
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
    return try shaders.Shaders.init(alloc, self.device, custom_shaders);
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.init(.{
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
/// ping-pong textures are rendered to, so they match the target's format.
pub inline fn textureOptions(self: D3D11) Texture.Options {
    const format: win32.dxgi.Format = if (self.blending.isLinear())
        .B8G8R8A8_UNORM_SRGB
    else
        .B8G8R8A8_UNORM;
    return .{
        .device = self.device,
        .format = format,
        .srv_format = format,
        .render_target = true,
        .rtv_format = format,
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

test {
    _ = hlsl;
    _ = slots;
    _ = Pipeline;
    _ = RenderPass;
    _ = Target;
    _ = Frame;
    _ = SwapChain;
}
