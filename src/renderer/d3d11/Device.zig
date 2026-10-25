//! The Direct3D 11 device context.
//!
//! This will hold the DXGI factory, the D3D11 device and its immediate
//! context. The device is shared by all surface renderers.
//!
//! STUB: only the contract exists for now; the device is created in a
//! later task.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.d3d11);

/// Options used when creating the D3D11 device.
pub const Options = struct {
    /// Which kind of adapter to create the device on.
    driver: Driver = .hardware,

    /// Create the device with the D3D11 debug layer enabled.
    debug_layer: bool = false,
};

pub const Driver = enum {
    /// The default hardware adapter.
    hardware,

    /// The WARP software rasterizer, used on CI and in VMs.
    warp,
};

/// The options this device was created with.
options: Options,

/// The maximum 2D texture width and height supported by the device.
/// 16384 is the guaranteed minimum for feature level 11_0.
max_texture_size: u32,

pub fn init(alloc: Allocator, options: Options) !*Device {
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);

    self.* = .{
        .options = options,
        .max_texture_size = 16384,
    };
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    alloc.destroy(self);
}
