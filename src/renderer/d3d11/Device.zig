//! The Direct3D 11 device context.
//!
//! Holds the DXGI factory, the D3D11 device and its immediate context. One
//! device is shared by all surface renderers. The device is free-threaded
//! (creating and releasing resources needs no lock) but the immediate
//! context is not: everything that touches it (`Map`, `UpdateSubresource`,
//! draws, ...) must run between `lockContext` and `unlockContext`.
//!
//! Surfaces take the shared device with `acquire` and give it back with
//! `release`. A renderer that sees `DXGI_ERROR_DEVICE_REMOVED/RESET` calls
//! `markLost`; the next `acquire` then creates a fresh device (a new
//! generation) and the lost one is freed when its last renderer releases it.
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const global = @import("../../global.zig");
const windows_os = @import("../../os/main.zig").windows;
const hlsl = @import("hlsl.zig");

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

/// The shared device, as `acquire` hands it out. Same type as the device
/// itself: the bookkeeping lives in the fields below.
pub const Shared = Device;

/// The options this device was created with, after env overrides.
options: Options,

device: *d3d11.ID3D11Device,
context: *d3d11.ID3D11DeviceContext,
factory: *dxgi.IDXGIFactory2,

/// The feature level the device was created with.
level: d3d11.FeatureLevel,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// Whether swap chains may be created with `ALLOW_TEARING` and present
/// with `PRESENT_ALLOW_TEARING` (variable refresh rate support).
tearing_supported: bool,

/// Guards `context`.
context_mutex: std.Io.Mutex = .init,

/// The thread that holds `context_mutex`, if tracked.
context_owner: if (track_owner) std.atomic.Value(std.Thread.Id) else void =
    if (track_owner) .init(no_owner) else {},

/// Sharing state, set by `acquire`; devices made by `init` are unshared.
/// `refs` is guarded by `registry_mutex`.
refs: usize = 0,
generation: u32 = 0,
pool_alloc: ?Allocator = null,

/// Frame targets surfaces of one size share (`Target.initShared`).
target_pool: @import("Target.zig").Pool = .{},

/// Set once a renderer saw the device removed or reset.
lost: std.atomic.Value(bool) = .init(false),

/// The first reason reported with `markLost` (an HRESULT).
lost_reason: std.atomic.Value(i32) = .init(0),

/// Debug builds: `GHOSTTY_D3D11_SIMULATE_DEVICE_LOST=<ms>` makes the device
/// report itself lost that many ms after it was created (0 = never).
simulate_lost_at_ns: u64 = 0,

pub fn init(alloc: Allocator, options: Options) !*Device {
    var opts = applyEnv(alloc, options);
    // After repeated losses on the hardware adapter (`preferWarp`).
    if (prefer_warp.load(.acquire)) opts.driver = .warp;

    const created = try createDevice(opts);
    errdefer com.release(created.device);
    errdefer com.release(created.context);
    // The DXGI debug factory only follows a device that really has the layer.
    opts.debug_layer = created.debug;

    const factory = try dxgi.createFactory(opts.debug_layer);
    errdefer com.release(factory);

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
        .tearing_supported = queryTearingSupport(factory),
    };

    log.info("d3d11 device created driver={t} level={t} debug_layer={} tearing={}", .{
        opts.driver,
        created.level,
        opts.debug_layer,
        self.tearing_supported,
    });
    logAdapter(created.device);
    logPrivateUsage("Device.init");
    return self;
}

/// Creates and frees the devices `acquire` shares. Replaced in tests.
const Factory = struct {
    create: *const fn (Allocator) anyerror!*Device,
    destroy: *const fn (Allocator, *Device) void,

    /// Whether the device still works: a removal nobody has seen yet.
    alive: *const fn (*Device) bool,
};

const real_factory: Factory = .{ .create = createShared, .destroy = destroyShared, .alive = aliveShared };

fn aliveShared(device: *Device) bool {
    device.device.checkDeviceRemoved() catch return false;
    return true;
}

fn createShared(alloc: Allocator) anyerror!*Device {
    const device = try Device.init(alloc, .{});
    // Only the first generation, so the replacement stays healthy.
    if (next_generation == 1) {
        device.simulate_lost_at_ns = simulateFromEnv(alloc);
        if (device.simulate_lost_at_ns != 0) log.warn("d3d11 device loss simulation armed", .{});
    }
    return device;
}

fn destroyShared(alloc: Allocator, device: *Device) void {
    device.deinit(alloc);
}

var device_factory: Factory = real_factory;

/// Guards `current`, `next_generation` and every `refs`.
var registry_mutex: std.Io.Mutex = .init;

/// The device `acquire` hands out; the registry holds one reference to it.
var current: ?*Device = null;

var next_generation: u32 = 1;

/// Whether a device was lost and no healthy one has been created since.
var lost_seen: std.atomic.Value(bool) = .init(false);

/// Set by `preferWarp`: every device made from now on runs on WARP.
var prefer_warp: std.atomic.Value(bool) = .init(false);

/// Makes future devices (`acquire`, `init`) use the WARP software
/// rasterizer. Process-global: the recovery turns to it after the hardware
/// adapter kept failing.
pub fn preferWarp() void {
    if (prefer_warp.swap(true, .acq_rel)) return;
    log.warn("d3d11 devices now use WARP", .{});

    // A healthy hardware device that a new window made meanwhile is not
    // handed out any more; its holders keep it until they release it.
    registry_mutex.lockUncancelable(global.io());
    defer registry_mutex.unlock(global.io());
    if (current) |d| if (d.options.driver != .warp) dropRegistryRef(d);
}

/// Test hook: tests that call `preferWarp` undo it with this.
pub fn resetPreferWarp() void {
    if (comptime !builtin.is_test) @compileError("resetPreferWarp is a test hook");
    prefer_warp.store(false, .release);
}

/// Set after a loss while a custom shader was active: the renderers then
/// build no custom shader pipelines, so a shader that hangs the GPU cannot
/// take the new device down again.
var custom_shaders_disabled: std.atomic.Value(bool) = .init(false);

pub fn disableCustomShaders() void {
    custom_shaders_disabled.store(true, .release);
}

pub fn customShadersDisabled() bool {
    return custom_shaders_disabled.load(.acquire);
}

/// Test hook, like `resetPreferWarp`.
pub fn resetCustomShadersDisabled() void {
    if (comptime !builtin.is_test) @compileError("resetCustomShadersDisabled is a test hook");
    custom_shaders_disabled.store(false, .release);
}

/// The current healthy shared device, or a new one when there is none or
/// the current one was lost. Release it with `release`.
pub fn acquire(alloc: Allocator) !*Shared {
    registry_mutex.lockUncancelable(global.io());
    defer registry_mutex.unlock(global.io());

    if (current) |d| {
        if (!d.isLost() and device_factory.alive(d)) {
            d.refs += 1;
            return d;
        }
        // Lost, or removed (a TDR or driver update while no window was
        // open) without any renderer having seen it.
        if (!d.lost.swap(true, .acq_rel)) {
            d.lost_reason.store(removedReason(d), .monotonic);
            log.warn("d3d11 device generation={d} found lost on acquire", .{d.generation});
        }
        dropRegistryRef(d);
    }

    const d = try device_factory.create(alloc);
    d.pool_alloc = alloc;
    d.generation = next_generation;
    next_generation +%= 1;
    // One for the registry, one for the caller.
    d.refs = 2;
    current = d;
    lost_seen.store(false, .monotonic);
    if (d.generation > 1) log.info("d3d11 device generation={d} created after a device loss", .{d.generation});
    return d;
}

/// Gives a reference from `acquire` back. The last reference of a lost
/// device frees it.
pub fn release(shared: *Shared) void {
    registry_mutex.lockUncancelable(global.io());
    defer registry_mutex.unlock(global.io());
    unref(shared);
}

/// Drops the registry's own reference, at the end of the process. Devices
/// still referenced by renderers stay until those release them.
pub fn shutdown() void {
    registry_mutex.lockUncancelable(global.io());
    defer registry_mutex.unlock(global.io());
    if (current) |d| dropRegistryRef(d);
}

/// Records that `shared` was removed or reset (`reason` is the HRESULT) and
/// stops handing it out. Safe from any thread, idempotent. The caller must
/// hold a reference.
pub fn markLost(shared: *Shared, reason: i32) void {
    if (shared.lost.swap(true, .acq_rel)) return;
    shared.lost_reason.store(reason, .monotonic);
    log.warn("d3d11 device lost generation={d} reason=0x{x:0>8}", .{ shared.generation, @as(u32, @bitCast(reason)) });

    registry_mutex.lockUncancelable(global.io());
    defer registry_mutex.unlock(global.io());
    // A healthy replacement may already be current: nothing is lost then.
    if (current == shared or current == null) lost_seen.store(true, .monotonic);
    if (current == shared) dropRegistryRef(shared);
}

/// `markLost` with the reason the device reports itself.
pub fn markLostFromDevice(shared: *Shared) void {
    markLost(shared, removedReason(shared));
}

/// The HRESULT of `GetDeviceRemovedReason`, DEVICE_REMOVED when it
/// reports none (simulated loss, or a lost swap chain).
fn removedReason(d: *Device) i32 {
    if (comptime builtin.is_test) return win32.foundation.DXGI_ERROR_DEVICE_REMOVED;
    const hr = d.device.vtable.GetDeviceRemovedReason(d.device);
    return if (hr == win32.foundation.S_OK) win32.foundation.DXGI_ERROR_DEVICE_REMOVED else hr;
}

pub fn isLost(shared: *const Shared) bool {
    return shared.lost.load(.acquire);
}

/// Whether a device was lost and no healthy one exists yet. The app quits
/// instead of staying in the tray when this holds with no window left.
pub fn anyLost() bool {
    return lost_seen.load(.monotonic);
}

/// `error.DeviceLost` once the device is lost, or once its simulated loss
/// time (Debug builds) has come.
pub fn checkLost(self: *Device) error{DeviceLost}!void {
    if (self.isLost()) return error.DeviceLost;
    if (comptime builtin.mode == .debug) if (self.simulate_lost_at_ns != 0 and nowNs() >= self.simulate_lost_at_ns) {
        log.warn("d3d11 simulating a device loss generation={d}", .{self.generation});
        self.markLost(win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
        return error.DeviceLost;
    };
}

/// The registry no longer hands `d` out. Registry mutex held.
fn dropRegistryRef(d: *Device) void {
    if (current == d) current = null;
    unref(d);
}

/// Registry mutex held.
fn unref(d: *Device) void {
    std.debug.assert(d.refs > 0);
    d.refs -= 1;
    if (d.refs > 0) return;
    log.info("d3d11 device generation={d} released", .{d.generation});
    device_factory.destroy(d.pool_alloc.?, d);
}

fn nowNs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toNanoseconds()));
}

/// The loss time of `GHOSTTY_D3D11_SIMULATE_DEVICE_LOST`, Debug builds only.
fn simulateFromEnv(alloc: Allocator) u64 {
    if (builtin.mode != .debug) return 0;
    const v = windows_os.diagnosticEnv(alloc, "GHOSTTY_D3D11_SIMULATE_DEVICE_LOST") orelse return 0;
    defer alloc.free(v);
    const ms = std.fmt.parseInt(u32, v, 10) catch return 0;
    if (ms == 0) return 0;
    return nowNs() + @as(u64, ms) * std.time.ns_per_ms;
}

/// DXGI_ADAPTER_DESC.
const AdapterDesc = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    luid: u64,

    // DXGI_ADAPTER_DESC on x64: Description[128] WCHAR, 4 UINT, 3 SIZE_T,
    // LUID (two 4-byte fields, 4-aligned in the C struct).
    comptime {
        if (@sizeOf(usize) == 8) {
            std.debug.assert(@sizeOf(AdapterDesc) == 304);
            std.debug.assert(@offsetOf(AdapterDesc, "dedicated_video_memory") == 272);
            std.debug.assert(@offsetOf(AdapterDesc, "luid") == 296);
        }
    }
};

/// Logs the adapter the device runs on. `test/windows/measure-ram.ps1` reads the
/// name from the `adapter=` field. Failures are not worth reporting.
fn logAdapter(device: *d3d11.ID3D11Device) void {
    const GetAdapterFn = *const fn (*dxgi.IDXGIDevice, *?*dxgi.IDXGIAdapter) callconv(.winapi) win32.foundation.HRESULT;
    const GetDescFn = *const fn (*dxgi.IDXGIAdapter, *AdapterDesc) callconv(.winapi) win32.foundation.HRESULT;

    const dxgi_device = com.queryInterface(device, dxgi.IDXGIDevice) catch return;
    defer com.release(dxgi_device);

    var adapter: ?*dxgi.IDXGIAdapter = null;
    const get_adapter: GetAdapterFn = @ptrCast(@alignCast(dxgi_device.vtable.GetAdapter));
    if (!win32.foundation.succeeded(get_adapter(dxgi_device, &adapter))) return;
    const a = adapter orelse return;
    defer com.release(a);

    var desc: AdapterDesc = undefined;
    const get_desc: GetDescFn = @ptrCast(@alignCast(a.vtable.GetDesc));
    if (!win32.foundation.succeeded(get_desc(a, &desc))) return;

    var name: [128 * 3]u8 = undefined;
    const len = std.mem.indexOfScalar(u16, &desc.description, 0) orelse desc.description.len;
    const n = std.unicode.utf16LeToUtf8(&name, desc.description[0..len]) catch 0;
    log.info("d3d11 adapter={s} vendor=0x{x:0>4} device=0x{x:0>4} dedicated_mb={d}", .{
        name[0..n],
        desc.vendor_id,
        desc.device_id,
        desc.dedicated_video_memory / (1024 * 1024),
    });
}

/// Debug log of the process' private bytes (`PrivateUsage`) after a start-up
/// stage, for the RAM baseline. Costs nothing when debug logging is off.
pub fn logPrivateUsage(comptime stage: []const u8) void {
    if (comptime !std.log.logEnabled(.debug, .d3d11)) return;

    var counters: win32.kernel32.PROCESS_MEMORY_COUNTERS_EX = .{};
    if (win32.kernel32.K32GetProcessMemoryInfo(
        win32.kernel32.GetCurrentProcess(),
        &counters,
        @sizeOf(win32.kernel32.PROCESS_MEMORY_COUNTERS_EX),
    ) == 0) return;

    log.debug("private usage after " ++ stage ++ ": {d} KiB (working set {d} KiB)", .{
        counters.PrivateUsage / 1024,
        counters.WorkingSetSize / 1024,
    });
}

var first_frame_logged: std.atomic.Value(bool) = .init(false);

/// `logPrivateUsage` for the first presented frame of the process.
pub fn logFirstFramePrivateUsage() void {
    if (first_frame_logged.swap(true, .monotonic)) return;
    logPrivateUsage("first frame");
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    // Every target hands its texture back before the device goes.
    std.debug.assert(self.target_pool.live() == 0);
    com.release(self.context);
    com.release(self.device);
    com.release(self.factory);
    alloc.destroy(self);
}

/// Asks the driver to give back the memory it caches for released
/// resources (swap chain buffers, targets). The caller holds the context
/// lock. Failures are not worth reporting.
pub fn trimDriver(self: *Device) void {
    self.assertContextLocked();
    const dxgi_device = com.queryInterface(self.device, dxgi.IDXGIDevice3) catch return;
    defer com.release(dxgi_device);
    dxgi_device.vtable.Trim(dxgi_device);
}

/// Compacts the process heap, which keeps the high-water mark of closed
/// surfaces' allocations. Needs no device lock; call it unlocked.
pub fn compactHeap() void {
    if (win32.kernel32.GetProcessHeap()) |h| _ = win32.kernel32.HeapCompact(h, 0);
}

/// Compiles the builtin shaders ahead of the first frame. Static: the app
/// runs it on a thread of its own at startup, before any device exists.
pub fn warmup() void {
    hlsl.warmup();
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

/// Whether DXGI reports tearing support. `IDXGIFactory5` is Windows 10+,
/// so a failing query just means no tearing.
fn queryTearingSupport(factory: *dxgi.IDXGIFactory2) bool {
    const factory5 = com.queryInterface(factory, dxgi.IDXGIFactory5) catch return false;
    defer com.release(factory5);
    return factory5.supportsTearing();
}

/// Apply the `GHOSTTY_D3D11_DRIVER` / `GHOSTTY_D3D11_DEBUG` overrides.
fn applyEnv(alloc: Allocator, options: Options) Options {
    var opts = options;

    if (windows_os.diagnosticEnv(alloc, "GHOSTTY_D3D11_DRIVER")) |v| {
        defer alloc.free(v);
        if (std.ascii.eqlIgnoreCase(v, "warp")) {
            opts.driver = .warp;
        } else if (std.ascii.eqlIgnoreCase(v, "hardware")) {
            opts.driver = .hardware;
        } else {
            log.warn("ignoring unknown GHOSTTY_D3D11_DRIVER value={s}", .{v});
        }
    }

    if (windows_os.diagnosticEnv(alloc, "GHOSTTY_D3D11_DEBUG")) |v| {
        defer alloc.free(v);
        opts.debug_layer = std.mem.eql(u8, v, "1");
    }

    return opts;
}

/// A created device and whether it has the debug layer.
const Created = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    level: d3d11.FeatureLevel,
    debug: bool,
};

fn createDevice(opts: Options) !Created {
    const driver: d3d11.DriverType = switch (opts.driver) {
        .hardware => .hardware,
        .warp => .warp,
    };

    if (opts.debug_layer) {
        if (d3d11.createDevice(driver, .{ .bgra_support = true, .debug = true })) |created| {
            return .{ .device = created.device, .context = created.context, .level = created.level, .debug = true };
        } else |err| {
            // The debug layer is an optional Windows feature ("Graphics
            // Tools"); without it device creation fails.
            log.warn("d3d11 debug layer unavailable err={}, retrying without", .{err});
        }
    }

    const created = try d3d11.createDevice(driver, .{ .bgra_support = true });
    return .{ .device = created.device, .context = created.context, .level = created.level, .debug = false };
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

/// Stands in for the real device factory so the generation logic runs
/// without a GPU.
const FakeFactory = struct {
    var created: usize = 0;
    var destroyed: usize = 0;
    var healthy: bool = true;

    fn create(alloc: Allocator) anyerror!*Device {
        const d = try alloc.create(Device);
        d.* = undefined;
        d.refs = 0;
        d.lost = .init(false);
        d.lost_reason = .init(0);
        d.simulate_lost_at_ns = 0;
        created += 1;
        healthy = true;
        return d;
    }

    fn destroy(alloc: Allocator, d: *Device) void {
        alloc.destroy(d);
        destroyed += 1;
    }

    fn alive(_: *Device) bool {
        return healthy;
    }

    fn install() void {
        created = 0;
        destroyed = 0;
        healthy = true;
        device_factory = .{ .create = create, .destroy = destroy, .alive = alive };
        current = null;
        next_generation = 1;
        lost_seen.store(false, .monotonic);
    }

    fn uninstall() void {
        shutdown();
        device_factory = real_factory;
    }
};

test "d3d11 device: acquire shares the healthy device" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const a = try acquire(alloc);
    const b = try acquire(alloc);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), FakeFactory.created);
    release(a);
    release(b);
    // The registry keeps the healthy device for the next window.
    try std.testing.expectEqual(@as(usize, 0), FakeFactory.destroyed);
}

test "d3d11 device: acquire after markLost returns a new device" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const a = try acquire(alloc);
    markLost(a, win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
    try std.testing.expect(a.isLost());
    try std.testing.expect(anyLost());

    const b = try acquire(alloc);
    try std.testing.expect(a != b);
    try std.testing.expect(!b.isLost());
    try std.testing.expect(b.generation > a.generation);
    try std.testing.expect(!anyLost());
    release(b);
    release(a);
}

test "d3d11 device: the lost device is freed after its last release" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const a1 = try acquire(alloc);
    const a2 = try acquire(alloc);
    markLost(a1, win32.foundation.DXGI_ERROR_DEVICE_RESET);
    markLost(a2, win32.foundation.DXGI_ERROR_DEVICE_REMOVED); // idempotent
    try std.testing.expectEqual(win32.foundation.DXGI_ERROR_DEVICE_RESET, a1.lost_reason.load(.monotonic));

    release(a1);
    try std.testing.expectEqual(@as(usize, 0), FakeFactory.destroyed);
    release(a2);
    try std.testing.expectEqual(@as(usize, 1), FakeFactory.destroyed);
}

test "d3d11 device: renderers on the healthy device are unaffected" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const old = try acquire(alloc);
    markLost(old, win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
    const fresh = try acquire(alloc);
    const fresh2 = try acquire(alloc);
    try std.testing.expectEqual(fresh, fresh2);

    // The old device going away leaves the fresh one alone.
    release(old);
    try std.testing.expectEqual(@as(usize, 1), FakeFactory.destroyed);
    try std.testing.expect(!fresh.isLost());
    try fresh.checkLost();
    release(fresh);
    release(fresh2);
    try std.testing.expectEqual(@as(usize, 1), FakeFactory.destroyed);
}

test "d3d11 device: simulated loss marks the device lost once its time came" {
    FakeFactory.install();
    defer FakeFactory.uninstall();

    const d = try acquire(std.testing.allocator);
    defer release(d);
    d.simulate_lost_at_ns = nowNs() + 60 * std.time.ns_per_s;
    try d.checkLost();
    d.simulate_lost_at_ns = nowNs() -| 1;
    try std.testing.expectError(error.DeviceLost, d.checkLost());
    try std.testing.expect(d.isLost());
}

test "d3d11 device: concurrent acquire, markLost and release balance" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const Worker = struct {
        fn run(a: Allocator) void {
            for (0..200) |i| {
                const d = acquire(a) catch return;
                if (i % 50 == 0) markLost(d, win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
                release(d);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{alloc});
    for (threads) |t| t.join();

    shutdown();
    try std.testing.expectEqual(FakeFactory.created, FakeFactory.destroyed);
}

test "d3d11 device: acquire after silent removal returns a new device" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const a = try acquire(alloc);
    release(a);

    // The device dies while no renderer holds it (tray, no window).
    FakeFactory.healthy = false;
    const b = try acquire(alloc);
    try std.testing.expectEqual(@as(usize, 2), FakeFactory.created);
    try std.testing.expect(!b.isLost());
    try std.testing.expectEqual(@as(usize, 1), FakeFactory.destroyed);
    release(b);
}

test "d3d11 device: a late markLost of a replaced device is not anyLost" {
    FakeFactory.install();
    defer FakeFactory.uninstall();
    const alloc = std.testing.allocator;

    const a = try acquire(alloc);
    // Found dead by a second renderer's acquire before a's own markLost.
    FakeFactory.healthy = false;
    const b = try acquire(alloc);
    markLost(a, win32.foundation.DXGI_ERROR_DEVICE_REMOVED);
    try std.testing.expect(!anyLost());
    release(a);
    release(b);
}

test "d3d11 device: preferWarp switches the adapter" {
    defer resetPreferWarp();
    const alloc = std.testing.allocator;

    preferWarp();
    const after = try Device.init(alloc, .{ .driver = .hardware });
    defer after.deinit(alloc);
    try std.testing.expectEqual(Driver.warp, after.options.driver);
}

test "d3d11 device: custom shaders stay disabled once a loss disabled them" {
    defer resetCustomShadersDisabled();
    try std.testing.expect(!customShadersDisabled());
    disableCustomShaders();
    try std.testing.expect(customShadersDisabled());
}
