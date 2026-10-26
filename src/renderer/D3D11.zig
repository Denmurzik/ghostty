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

/// `render_thread` outside the render thread's life; no real thread has id 0.
const no_thread: std.Thread.Id = 0;

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

/// Whether presents wait for the vertical blank (config `window-vsync`).
vsync: bool = true,

/// Set once a swap chain failure was logged, so a broken swap chain logs
/// once rather than once per frame.
swap_chain_failure_logged: bool = false,

/// The size `setViewport` last reported. Headless `surfaceSize` returns it.
viewport: struct { width: u32, height: u32 } = .{ .width = 0, .height = 0 },

/// The render thread, once `threadEnter` ran (`no_thread` before and after).
/// Draws from any other thread are the synchronous (UI thread) kind.
render_thread: std.atomic.Value(std.Thread.Id) = .init(no_thread),

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
    const v = global.environ().getAlloc(alloc, "GHOSTTY_D3D11_PACING_LOG") catch return false;
    defer alloc.free(v);
    return std.mem.eql(u8, v, "1");
}

pub fn deinit(self: *D3D11) void {
    if (self.dump) |*d| d.deinit(self.alloc);
    self.* = undefined;
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread.
pub fn threadEnter(self: *D3D11, surface: *apprt.Surface) !void {
    self.render_thread.store(std.Thread.getCurrentId(), .release);

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
        self.swap_chain.?.deinit();
        self.swap_chain = null;
    }

    self.present_target = null;
    self.render_thread.store(no_thread, .release);
}

/// The swap chain of the present target, created at the given size if it
/// does not exist yet. Failure is logged once and returned. The caller
/// holds the context lock.
pub fn swapChain(self: *D3D11, width: u32, height: u32) !*SwapChain {
    if (self.swap_chain) |*sc| return sc;

    const target = self.present_target orelse return error.InvalidArgument;
    self.swap_chain = SwapChain.init(self.device, target.hwnd, width, height, .hwnd) catch |err| {
        self.logSwapChainFailure("create", err);
        return err;
    };
    self.swap_chain.?.surface_id = target.id;
    return &self.swap_chain.?;
}

/// Logs a swap chain failure the first time only.
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

/// Actions taken before doing anything in `drawFrame`. The immediate
/// context is not thread safe: it is ours until `drawFrameEnd`.
pub fn drawFrameStart(self: *D3D11) void {
    self.device.lockContext();
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
/// The render thread polls first: a free slot, or a chain idle for longer
/// than a refresh interval, costs one syscall under the context lock. Only a
/// busy chain is waited on, without the lock, so one surface pacing itself
/// does not hold up the others. A synchronous draw (UI thread, e.g. during
/// resize) never waits: it must not stall the window.
fn waitForFrameSlot(self: *D3D11, sync: bool) void {
    const sc = if (self.swap_chain) |*sc| sc else return;
    if (!sc.waitArmed()) return;

    if (sync) {
        _ = sc.waitForSlot(0);
        return;
    }
    if (sc.waitForSlot(0) or sc.idle()) return;

    self.device.unlockContext();
    defer self.device.lockContext();
    if (!latency.enabled() and !self.pacing_log) {
        _ = sc.waitForSlot(frame_slot_wait_ms);
        return;
    }
    const start = nowNs();
    _ = sc.waitForSlot(frame_slot_wait_ms);
    const waited = nowNs() -| start;
    self.frame_slot_ns += waited;
    latency.markSlotWait(waited);
}

fn nowNs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toNanoseconds()));
}

/// `GHOSTTY_D3D11_PACING_LOG=1`: one line per frame, from the end of the
/// slot wait to the end of the present.
pub fn logPacing(self: *const D3D11) void {
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
    // Draws off the render thread are the synchronous UI thread ones.
    const sync = self.render_thread.load(.acquire) != std.Thread.getCurrentId();
    self.frame_slot_ns = 0;
    self.waitForFrameSlot(sync);
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
    // The test thread plays the render thread.
    api.render_thread.store(std.Thread.getCurrentId(), .release);
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
    sc.pacer.pending = 1;

    // Draws that return before `beginFrame` (zero size, nothing changed)
    // only take and release the lock: they must not wait or touch the slot.
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..10) |_| {
        api.drawFrameStart();
        api.drawFrameEnd();
    }
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 20);
    try std.testing.expectEqual(@as(u32, 1), sc.pacer.pending);

    // The first real frame takes the slot, on the render thread (waits at
    // most `frame_slot_wait_ms`) and holds the lock again afterwards.
    api.drawFrameStart();
    defer api.drawFrameEnd();
    api.waitForFrameSlot(false);
    api.device.assertContextLocked();
}

test "d3d11 pacing: sync draws never block on the slot" {
    var api = try testApi(.native);
    defer api.device.deinit(std.testing.allocator);
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(packSize(16, 16));
    api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer api.threadExit();

    // Before `threadEnter` no thread is the render thread: every draw is
    // a sync one.
    try std.testing.expect(api.render_thread.load(.acquire) != std.Thread.getCurrentId());

    api.drawFrameStart();
    defer api.drawFrameEnd();
    const sc = try api.swapChain(16, 16);
    sc.pacer.presented(0);

    const io = @import("../global.zig").io();
    const start = std.Io.Timestamp.now(io, .awake);
    api.waitForFrameSlot(true);
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < frame_slot_wait_ms);
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
