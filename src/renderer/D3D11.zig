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

/// Where the swap chain presents. Provided by the apprt through an optional
/// `d3d11PresentTarget` decl on its Surface; null means headless.
pub const PresentTarget = struct {
    /// HWND of the surface child window.
    hwnd: *anyopaque,

    /// Physical client size packed with `packSize`, written by the UI
    /// thread on WM_SIZE.
    size: *const std.atomic.Value(u64),
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

/// The size `setViewport` last reported. Headless `surfaceSize` returns it.
viewport: struct { width: u32, height: u32 } = .{ .width = 0, .height = 0 },

/// The render thread, once `threadEnter` ran. Draws from any other thread
/// are the synchronous (UI thread) kind.
render_thread: ?std.Thread.Id = null,

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
        .device = device,
        .dump = Frame.Dump.initFromEnv(
            alloc,
            next_renderer_index.fetchAdd(1, .monotonic),
        ),
    };
}

pub fn deinit(self: *D3D11) void {
    if (self.dump) |*d| d.deinit(self.alloc);
    self.* = undefined;
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread.
pub fn threadEnter(self: *D3D11, surface: *apprt.Surface) !void {
    self.render_thread = std.Thread.getCurrentId();

    // Apprts without a window (`app_runtime = none`) render headless.
    if (comptime @hasDecl(apprt.Surface, "d3d11PresentTarget")) {
        self.present_target = surface.d3d11PresentTarget();
    }
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread.
pub fn threadExit(self: *D3D11) void {
    self.present_target = null;
    self.render_thread = null;
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

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *D3D11) void {
    self.device.unlockContext();
}

/// Blocks until the swap chain has a free frame slot. Nothing to wait for
/// until a swap chain exists.
fn waitForFrameSlot(self: *D3D11, sync: bool) void {
    _ = self;
    _ = sync;
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
    const sync = self.render_thread != std.Thread.getCurrentId();
    self.waitForFrameSlot(sync);
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
}
