//! Represents a render target.
//!
//! A `B8G8R8A8_TYPELESS` texture with render target and shader resource
//! views. The views are `B8G8R8A8_UNORM_SRGB` when the target is sRGB, so
//! blending happens in linear space and the hardware encodes on write, and
//! `B8G8R8A8_UNORM` otherwise.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const Device = @import("Device.zig");
const Texture = @import("Texture.zig");
const global = @import("../../global.zig");

/// Options for initializing a Target
pub const Options = struct {
    device: *Device,
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
    /// Whether the views encode/decode sRGB.
    srgb: bool,
};

pub const Error = Texture.Error;

/// Textures of the targets made by `initShared`, kept per device so that
/// surfaces of one size draw into one texture instead of one each. A frame
/// clears its target first and is drawn, copied to the swap chain and
/// dumped under the device context lock, so nothing outlives it in the
/// texture; the pool's own mutex only guards the bookkeeping.
pub const Pool = struct {
    const slot_count = 8;

    const Entry = struct {
        texture: ?Texture = null,
        width: usize = 0,
        height: usize = 0,
        srgb: bool = false,
        refs: u32 = 0,
    };

    mutex: std.Io.Mutex = .init,
    entries: [slot_count]Entry = @splat(.{}),

    /// Textures in use; for tests.
    pub fn live(self: *Pool) usize {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.texture != null) n += 1;
        }
        return n;
    }
};

/// The device the target lives on.
device: *Device,

/// The backing texture. `texture.rtv` is always set.
texture: Texture,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

/// The `Pool` entry the texture belongs to; null when the target owns it.
slot: ?u8 = null,

pub fn init(opts: Options) Error!Self {
    // D3D11 rejects empty textures.
    if (opts.width == 0 or opts.height == 0) return error.InvalidArgument;

    const view_format: dxgi.Format = if (opts.srgb) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM;
    const texture = try Texture.init(.{
        .device = opts.device,
        .format = .B8G8R8A8_TYPELESS,
        .srv_format = view_format,
        .render_target = true,
        .rtv_format = view_format,
        .gamma_rtv = opts.srgb,
    }, opts.width, opts.height, null);

    return .{
        .device = opts.device,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}

/// Like `init`, but targets of the same size, format and device share one
/// texture. Only for targets drawn under one hold of the context lock that
/// start with a clear (the generic renderer's frame target); a pool without
/// a free slot gives an owned target. Content does not survive another
/// shared target's frame.
pub fn initShared(opts: Options) Error!Self {
    if (opts.width == 0 or opts.height == 0) return error.InvalidArgument;

    const pool = &opts.device.target_pool;
    pool.mutex.lockUncancelable(global.io());
    defer pool.mutex.unlock(global.io());

    var free: ?u8 = null;
    for (&pool.entries, 0..) |*e, i| {
        const texture = e.texture orelse {
            if (free == null) free = @intCast(i);
            continue;
        };
        if (e.width != opts.width or e.height != opts.height or e.srgb != opts.srgb) continue;
        e.refs += 1;
        return .{
            .device = opts.device,
            .texture = texture,
            .width = opts.width,
            .height = opts.height,
            .slot = @intCast(i),
        };
    }

    var self = try init(opts);
    if (free) |i| {
        pool.entries[i] = .{
            .texture = self.texture,
            .width = opts.width,
            .height = opts.height,
            .srgb = opts.srgb,
            .refs = 1,
        };
        self.slot = i;
    }
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.slot) |i| {
        const pool = &self.device.target_pool;
        pool.mutex.lockUncancelable(global.io());
        defer pool.mutex.unlock(global.io());
        const e = &pool.entries[i];
        e.refs -= 1;
        if (e.refs == 0) {
            e.texture.?.deinit();
            e.* = .{};
        }
    } else {
        self.texture.deinit();
    }
    self.* = undefined;
}

/// The render target view. Always present for a `Target`.
pub fn rtv(self: *const Self) *d3d11.ID3D11RenderTargetView {
    return self.texture.rtv.?;
}

/// Copies the target into CPU memory as tightly packed BGRA8 rows (the
/// raw stored bytes, so sRGB targets return encoded values). Caller owns
/// the returned slice. For tests and the frame dump hook.
///
/// Uses the immediate context: the caller holds the device context lock.
pub fn readPixelsAlloc(self: *const Self, alloc: Allocator) (Error || Allocator.Error)![]u8 {
    const device = self.device;
    device.assertContextLocked();

    const staging = try device.device.createTexture2D(&.{
        .Width = @intCast(self.width),
        .Height = @intCast(self.height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_TYPELESS,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .staging,
        .BindFlags = .{},
        .CPUAccessFlags = .{ .read = true },
        .MiscFlags = 0,
    }, null);
    defer com.release(staging);

    device.context.copyResource(staging.asResource(), self.texture.texture.asResource());

    const mapped = try device.context.map(staging.asResource(), 0, .read, 0);
    defer device.context.unmap(staging.asResource(), 0);

    const row_bytes = self.width * 4;
    const out = try alloc.alloc(u8, row_bytes * self.height);
    errdefer alloc.free(out);

    const src: [*]const u8 = @ptrCast(mapped.pData.?);
    for (0..self.height) |y| {
        @memcpy(out[y * row_bytes ..][0..row_bytes], src[y * mapped.RowPitch ..][0..row_bytes]);
    }
    return out;
}

test "d3d11 target: srgb flag selects the view formats" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var linear = try init(.{ .device = device, .width = 4, .height = 2, .srgb = false });
    defer linear.deinit();
    try std.testing.expectEqual(@as(usize, 4), linear.width);
    try std.testing.expectEqual(@as(usize, 2), linear.height);
    try std.testing.expectEqual(dxgi.Format.B8G8R8A8_TYPELESS, linear.texture.format);

    var srgb = try init(.{ .device = device, .width = 4, .height = 2, .srgb = true });
    defer srgb.deinit();

    try std.testing.expectError(error.InvalidArgument, init(.{ .device = device, .width = 0, .height = 2, .srgb = true }));
}

test "d3d11 target: readPixelsAlloc returns tightly packed rows" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    // 3 pixels wide so the row pitch (256 aligned) differs from 12 bytes.
    var target = try init(.{ .device = device, .width = 3, .height = 2, .srgb = false });
    defer target.deinit();

    device.lockContext();
    defer device.unlockContext();

    device.context.clearRenderTargetView(target.rtv(), .{ 1, 0, 0, 1 });
    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);

    try std.testing.expectEqual(@as(usize, 3 * 2 * 4), pixels.len);
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        // BGRA: red.
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[i..][0..4]);
    }
}

test "d3d11 target: shared targets of one size share a texture until the last is gone" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var a = try initShared(.{ .device = device, .width = 6, .height = 4, .srgb = true });
    var b = try initShared(.{ .device = device, .width = 6, .height = 4, .srgb = true });
    var other_size = try initShared(.{ .device = device, .width = 6, .height = 5, .srgb = true });
    var other_format = try initShared(.{ .device = device, .width = 6, .height = 4, .srgb = false });
    try std.testing.expect(a.texture.texture == b.texture.texture);
    try std.testing.expect(a.texture.texture != other_size.texture.texture);
    try std.testing.expect(a.texture.texture != other_format.texture.texture);
    try std.testing.expectEqual(@as(usize, 3), device.target_pool.live());

    a.deinit();
    try std.testing.expectEqual(@as(usize, 3), device.target_pool.live());
    b.deinit();
    try std.testing.expectEqual(@as(usize, 2), device.target_pool.live());
    other_size.deinit();
    other_format.deinit();
    try std.testing.expectEqual(@as(usize, 0), device.target_pool.live());
}

test "d3d11 target: a full pool hands out owned targets" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var targets: [Pool.slot_count + 1]Self = undefined;
    for (&targets, 0..) |*t, i| t.* = try initShared(.{ .device = device, .width = 2 + i, .height = 2, .srgb = false });
    try std.testing.expect(targets[Pool.slot_count].slot == null);
    try std.testing.expectEqual(@as(usize, Pool.slot_count), device.target_pool.live());
    for (&targets) |*t| t.deinit();
    try std.testing.expectEqual(@as(usize, 0), device.target_pool.live());
}
