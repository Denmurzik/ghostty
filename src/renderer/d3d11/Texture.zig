//! Wrapper for handling textures.
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const Device = @import("Device.zig");

/// Options for initializing a texture.
pub const Options = struct {
    device: *Device,

    /// The format of the texture resource.
    format: dxgi.Format,

    /// The format the shader resource view reads the texture as.
    srv_format: dxgi.Format,

    /// Whether the texture can also be rendered to. Creates `rtv`.
    render_target: bool = false,

    /// The format of the render target view; `.UNKNOWN` uses `format`.
    rtv_format: dxgi.Format = .UNKNOWN,
};

pub const Error = win32.foundation.Error;

/// The device the texture lives on; `replaceRegion` uses its context.
device: *Device,

/// The format of the texture resource.
format: dxgi.Format,

/// The native texture.
texture: *d3d11.ID3D11Texture2D,

/// The view shaders sample the texture through.
srv: *d3d11.ID3D11ShaderResourceView,

/// The view the texture is rendered through, if `Options.render_target`.
rtv: ?*d3d11.ID3D11RenderTargetView,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

/// Bytes per pixel of the formats we upload data for.
fn bytesPerPixel(format: dxgi.Format) ?u32 {
    return switch (format) {
        .R8_UNORM, .A8_UNORM => 1,
        .R8G8_UNORM, .R16_UNORM => 2,
        .R8G8B8A8_UNORM,
        .R8G8B8A8_UNORM_SRGB,
        .B8G8R8A8_UNORM,
        .B8G8R8A8_UNORM_SRGB,
        .R10G10B10A2_UNORM,
        => 4,
        .R16G16B16A16_UNORM, .R16G16B16A16_FLOAT => 8,
        .R32G32B32A32_FLOAT => 16,
        else => null,
    };
}

/// Initialize a texture
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const w = std.math.cast(u32, width) orelse return error.InvalidArgument;
    const h = std.math.cast(u32, height) orelse return error.InvalidArgument;

    var initial: d3d11.SUBRESOURCE_DATA = undefined;
    if (data) |bytes| {
        const bpp = bytesPerPixel(opts.format) orelse return error.InvalidArgument;
        if (bytes.len < @as(usize, w) * h * bpp) return error.InvalidArgument;
        initial = .{
            .pSysMem = bytes.ptr,
            .SysMemPitch = w * bpp,
            .SysMemSlicePitch = 0,
        };
    }

    const texture = try opts.device.device.createTexture2D(&.{
        .Width = w,
        .Height = h,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .default,
        .BindFlags = .{
            .shader_resource = true,
            .render_target = opts.render_target,
        },
        .CPUAccessFlags = .{},
        .MiscFlags = 0,
    }, if (data != null) &initial else null);
    errdefer com.release(texture);

    const srv = try opts.device.device.createShaderResourceView(texture.asResource(), &.{
        .Format = opts.srv_format,
        .ViewDimension = .TEXTURE2D,
        .u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } },
    });
    errdefer com.release(srv);

    const rtv: ?*d3d11.ID3D11RenderTargetView = if (opts.render_target)
        try opts.device.device.createRenderTargetView(texture.asResource(), &.{
            .Format = opts.rtv_format,
            .ViewDimension = .TEXTURE2D,
            .u = .{ .Texture2D = .{ .MipSlice = 0 } },
        })
    else
        null;

    return .{
        .device = opts.device,
        .format = opts.format,
        .texture = texture,
        .srv = srv,
        .rtv = rtv,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: Self) void {
    com.release(self.rtv);
    com.release(self.srv);
    com.release(self.texture);
}

/// Replace a region of the texture with the provided data. The data is
/// tightly packed rows of `width` pixels.
///
/// Does NOT check the dimensions of the data to ensure correctness.
///
/// Uses the immediate context: the caller holds the device context lock.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    const device = self.device;
    device.assertContextLocked();

    const bpp = bytesPerPixel(self.format) orelse return error.InvalidArgument;
    const row_pitch = std.math.cast(u32, width * bpp) orelse return error.InvalidArgument;
    const box: d3d11.BOX = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };
    device.context.updateSubresource(self.texture.asResource(), 0, &box, data.ptr, row_pitch, 0);
}

test "d3d11 texture: replaceRegion writes the box" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    const tex = try init(.{
        .device = device,
        .format = .R8_UNORM,
        .srv_format = .R8_UNORM,
    }, 8, 8, &@as([64]u8, @splat(0)));
    defer tex.deinit();

    const staging = try device.device.createTexture2D(&.{
        .Width = 8,
        .Height = 8,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .R8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .staging,
        .BindFlags = .{},
        .CPUAccessFlags = .{ .read = true },
        .MiscFlags = 0,
    }, null);
    defer com.release(staging);

    device.lockContext();
    defer device.unlockContext();

    try tex.replaceRegion(2, 2, 2, 2, &.{ 1, 2, 3, 4 });
    device.context.copyResource(staging.asResource(), tex.texture.asResource());

    const mapped = try device.context.map(staging.asResource(), 0, .read, 0);
    defer device.context.unmap(staging.asResource(), 0);
    const bytes: [*]const u8 = @ptrCast(mapped.pData.?);
    const pitch = mapped.RowPitch;

    try std.testing.expectEqual(@as(u8, 1), bytes[2 * pitch + 2]);
    try std.testing.expectEqual(@as(u8, 2), bytes[2 * pitch + 3]);
    try std.testing.expectEqual(@as(u8, 3), bytes[3 * pitch + 2]);
    try std.testing.expectEqual(@as(u8, 4), bytes[3 * pitch + 3]);
    // Outside the box is untouched.
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bytes[2 * pitch + 4]);
}

test "d3d11 texture: render target creates an rtv" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    const plain = try init(.{
        .device = device,
        .format = .B8G8R8A8_UNORM_SRGB,
        .srv_format = .B8G8R8A8_UNORM_SRGB,
    }, 4, 4, null);
    defer plain.deinit();
    try std.testing.expect(plain.rtv == null);

    const target = try init(.{
        .device = device,
        .format = .B8G8R8A8_UNORM_SRGB,
        .srv_format = .B8G8R8A8_UNORM_SRGB,
        .render_target = true,
        .rtv_format = .B8G8R8A8_UNORM_SRGB,
    }, 4, 4, null);
    defer target.deinit();
    try std.testing.expect(target.rtv != null);
}
