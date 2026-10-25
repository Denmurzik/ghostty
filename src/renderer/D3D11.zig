//! Graphics API wrapper for Direct3D 11.
//!
//! STUB: this declares the full GraphicsAPI contract that
//! `generic.zig` relies on (see docs/windows/SPEC.md §6.1). Later tasks
//! replace the bodies, never the names.
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

pub fn init(
    alloc: Allocator,
    device: *Device,
    opts: rendererpkg.Options,
) !D3D11 {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
    };
}

pub fn deinit(self: *D3D11) void {
    self.* = undefined;
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread.
pub fn threadEnter(self: *D3D11, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread.
pub fn threadExit(self: *D3D11) void {
    _ = self;
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    _ = self;
    return .{ .width = 0, .height = 0 };
}

/// Set the viewport to cover the given size in device pixels.
pub fn setViewport(self: *const D3D11, width: u32, height: u32) void {
    _ = self;
    _ = width;
    _ = height;
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *D3D11) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *D3D11) void {
    _ = self;
}

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    return try shaders.Shaders.init(alloc, custom_shaders);
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
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

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .device = self.device,
        .format = .B8G8R8A8_UNORM_SRGB,
        .srv_format = .B8G8R8A8_UNORM_SRGB,
        // Custom shader ping-pong textures are rendered to.
        .render_target = true,
        .rtv_format = .B8G8R8A8_UNORM_SRGB,
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
    const dxgi_format: win32.dxgi.Format = if (srgb) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM;
    return switch (format) {
        .rgba => .{ .device = self.device, .format = dxgi_format, .srv_format = dxgi_format },
        // Generic only ever asks for `(.rgba, true)`.
        .gray, .bgra => @panic("unsupported image texture format for D3D11"),
    };
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

/// Begin a frame.
pub inline fn beginFrame(
    self: *const D3D11,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
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

test {
    _ = hlsl;
    _ = slots;
}
