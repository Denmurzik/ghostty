//! The Direct3D 11 device context.
//!
//! Holds the DXGI factory, the D3D11 device and its immediate context. One
//! device is shared by all surface renderers. The device is free-threaded
//! (creating and releasing resources needs no lock) but the immediate
//! context is not: everything that touches it (`Map`, `UpdateSubresource`,
//! draws, ...) must run between `lockContext` and `unlockContext`.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const global = @import("../../global.zig");

const log = std.log.scoped(.d3d11);

/// Options used when creating the D3D11 device.
pub const Options = struct {
    /// Which kind of adapter to create the device on.
    /// `GHOSTTY_D3D11_DRIVER=warp|hardware` overrides this.
    driver: Driver = .hardware,

    /// Create the device with the D3D11 debug layer enabled.
    /// `GHOSTTY_D3D11_DEBUG=1` overrides this.
    debug_layer: bool = false,
};

pub const Driver = enum {
    /// The default hardware adapter.
    hardware,

    /// The WARP software rasterizer, used on CI and in VMs.
    warp,
};

/// Whether lock ownership is tracked so misuse can be asserted.
const track_owner = std.debug.runtime_safety;

/// Sentinel for "no thread holds the context lock"; no real thread has id 0.
const no_owner: std.Thread.Id = 0;

/// The options this device was created with, after env overrides.
options: Options,

device: *d3d11.ID3D11Device,
context: *d3d11.ID3D11DeviceContext,
factory: *dxgi.IDXGIFactory2,

/// The feature level the device was created with.
level: d3d11.FeatureLevel,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// Guards `context`.
context_mutex: std.Io.Mutex = .init,

/// The thread that holds `context_mutex`, if tracked.
context_owner: if (track_owner) std.atomic.Value(std.Thread.Id) else void =
    if (track_owner) .init(no_owner) else {},

pub fn init(alloc: Allocator, options: Options) !*Device {
    const opts = applyEnv(alloc, options);

    const factory = try dxgi.createFactory(opts.debug_layer);
    errdefer com.release(factory);

    const created = try createDevice(opts);
    errdefer com.release(created.device);
    errdefer com.release(created.context);

    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);

    self.* = .{
        .options = opts,
        .device = created.device,
        .context = created.context,
        .factory = factory,
        .level = created.level,
        // 16384 is guaranteed from feature level 11_0 up, 8192 below.
        .max_texture_size = if (@backingInt(created.level) >= @backingInt(d3d11.FeatureLevel.@"11_0")) 16384 else 8192,
    };

    log.info("d3d11 device created driver={t} level={t} debug_layer={}", .{
        opts.driver,
        created.level,
        opts.debug_layer,
    });
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    com.release(self.context);
    com.release(self.device);
    com.release(self.factory);
    alloc.destroy(self);
}

/// Take the immediate context lock. Not recursive.
pub fn lockContext(self: *Device) void {
    self.context_mutex.lockUncancelable(global.io());
    if (comptime track_owner) self.context_owner.store(std.Thread.getCurrentId(), .monotonic);
}

pub fn unlockContext(self: *Device) void {
    if (comptime track_owner) {
        std.debug.assert(self.context_owner.load(.monotonic) == std.Thread.getCurrentId());
        self.context_owner.store(no_owner, .monotonic);
    }
    self.context_mutex.unlock(global.io());
}

/// Debug-asserts that the calling thread holds the context lock. Resource
/// operations that use the immediate context call this instead of locking
/// themselves, since the frame already holds the lock around them.
pub fn assertContextLocked(self: *const Device) void {
    if (comptime track_owner) {
        std.debug.assert(self.context_owner.load(.monotonic) == std.Thread.getCurrentId());
    }
}

/// Apply the `GHOSTTY_D3D11_DRIVER` / `GHOSTTY_D3D11_DEBUG` overrides.
fn applyEnv(alloc: Allocator, options: Options) Options {
    var opts = options;

    if (global.environ().getAlloc(alloc, "GHOSTTY_D3D11_DRIVER")) |v| {
        defer alloc.free(v);
        if (std.ascii.eqlIgnoreCase(v, "warp")) {
            opts.driver = .warp;
        } else if (std.ascii.eqlIgnoreCase(v, "hardware")) {
            opts.driver = .hardware;
        } else {
            log.warn("ignoring unknown GHOSTTY_D3D11_DRIVER value={s}", .{v});
        }
    } else |_| {}

    if (global.environ().getAlloc(alloc, "GHOSTTY_D3D11_DEBUG")) |v| {
        defer alloc.free(v);
        opts.debug_layer = std.mem.eql(u8, v, "1");
    } else |_| {}

    return opts;
}

fn createDevice(opts: Options) !d3d11.CreatedDevice {
    const driver: d3d11.DriverType = switch (opts.driver) {
        .hardware => .hardware,
        .warp => .warp,
    };

    if (opts.debug_layer) {
        if (d3d11.createDevice(driver, .{ .bgra_support = true, .debug = true })) |created| {
            return created;
        } else |err| {
            // The debug layer is an optional Windows feature ("Graphics
            // Tools"); without it device creation fails.
            log.warn("d3d11 debug layer unavailable err={}, retrying without", .{err});
        }
    }

    return try d3d11.createDevice(driver, .{ .bgra_support = true });
}

test "d3d11 device: WARP device has feature level >= 11_0" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    try std.testing.expect(@backingInt(device.level) >= @backingInt(d3d11.FeatureLevel.@"11_0"));
    try std.testing.expect(device.max_texture_size >= 8192);
}

test "d3d11 device: context lock is released by unlock" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    device.lockContext();
    device.assertContextLocked();
    device.unlockContext();

    // Taking it again proves unlock released it.
    device.lockContext();
    device.unlockContext();
}
