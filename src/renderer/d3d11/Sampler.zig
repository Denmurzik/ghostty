//! Wrapper for handling samplers.
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const Device = @import("Device.zig");

/// Options for initializing a sampler. Addressing is always clamp.
pub const Options = struct {
    device: *Device,
    filter: Filter = .linear,

    pub const Filter = enum { linear, nearest };
};

pub const Error = win32.foundation.Error;

/// The native sampler state.
sampler: *d3d11.ID3D11SamplerState,

/// Initialize a sampler
pub fn init(
    opts: Options,
) Error!Self {
    const sampler = try opts.device.device.createSamplerState(&.{
        .Filter = switch (opts.filter) {
            .linear => .MIN_MAG_MIP_LINEAR,
            .nearest => .MIN_MAG_MIP_POINT,
        },
        .AddressU = .CLAMP,
        .AddressV = .CLAMP,
        .AddressW = .CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = .NEVER,
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = d3d11.FLOAT32_MAX,
    });
    return .{ .sampler = sampler };
}

pub fn deinit(self: Self) void {
    com.release(self.sampler);
}

test "d3d11 sampler: creates and releases both filters" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    for ([_]Options.Filter{ .linear, .nearest }) |filter| {
        const sampler = try init(.{ .device = device, .filter = filter });
        sampler.deinit();
    }
}
