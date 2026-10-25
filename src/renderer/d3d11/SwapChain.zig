//! A flip-model swap chain for a window.
//!
//! Two `FLIP_DISCARD` buffers with a frame latency waitable object: the
//! renderer waits on it before encoding a frame (`waitForSlot`, only after
//! a `present`), so the render thread runs at the display rate without
//! queueing frames. Frames are rendered into a `Target` and copied into the
//! back buffer (`copyToBackbuffer`) right before `present`.
//!
//! Everything that touches the swap chain except `waitForSlot` runs under
//! the device context lock. `MakeWindowAssociation(NO_WINDOW_CHANGES)`
//! keeps DXGI from subclassing the window, so `present` never sends a
//! message to the UI thread (which may be blocked joining the render
//! thread).
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const foundation = win32.foundation;
const Device = @import("Device.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.d3d11);

extern "kernel32" fn WaitForSingleObjectEx(
    handle: foundation.HANDLE,
    milliseconds: u32,
    alertable: foundation.BOOL,
) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: foundation.HANDLE) callconv(.winapi) foundation.BOOL;

pub const Mode = enum {
    /// A swap chain on a window handle.
    hwnd,
    // .composition arrives with transparency in M3.
};

pub const Error = foundation.Error;

/// Number of back buffers; the minimum for flip model.
const buffer_count = 2;

/// The target is stored as `B8G8R8A8_TYPELESS`, so this format is copy
/// compatible with it. The stored bytes are sRGB encoded whichever view
/// wrote them, which is what a flip-model swap chain presents.
const format: dxgi.Format = .B8G8R8A8_UNORM;

device: *Device,
chain: *dxgi.IDXGISwapChain2,

/// The frame latency waitable object, closed by `deinit`.
waitable: ?foundation.HANDLE,

/// The size of the back buffers.
width: u32,
height: u32,

/// Flags the swap chain was created with, repeated by `ResizeBuffers`.
flags: u32,

/// Whether `present` ran since the last `waitForSlot`. A slot is only
/// consumed by a present, so a wait without one would block for nothing.
presented_since_wait: bool = false,

pub fn init(
    device: *Device,
    hwnd: *anyopaque,
    width: u32,
    height: u32,
    mode: Mode,
) Error!Self {
    switch (mode) {
        .hwnd => {},
    }
    if (width == 0 or height == 0) return error.InvalidArgument;

    const window: foundation.HWND = @ptrCast(hwnd);

    var flags: u32 = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    if (device.tearing_supported) flags |= dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING;

    // Before the first `Present`: DXGI must neither watch the window for
    // Alt+Enter and size changes nor subclass it.
    try device.factory.asFactory().makeWindowAssociation(
        window,
        dxgi.MWA_NO_WINDOW_CHANGES | dxgi.MWA_NO_ALT_ENTER,
    );

    const chain1 = try device.factory.createSwapChainForHwnd(device.device, window, &.{
        .Width = width,
        .Height = height,
        .Format = format,
        .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = buffer_count,
        .Scaling = .STRETCH,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .IGNORE,
        .Flags = flags,
    });
    defer com.release(chain1);

    const chain = try com.queryInterface(chain1, dxgi.IDXGISwapChain2);
    errdefer com.release(chain);

    try chain.setMaximumFrameLatency(1);
    const waitable = chain.getFrameLatencyWaitableObject();
    errdefer if (waitable) |h| {
        _ = CloseHandle(h);
    };

    log.info("d3d11 swap chain created size={d}x{d} tearing={}", .{
        width,
        height,
        flags & dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING != 0,
    });

    return .{
        .device = device,
        .chain = chain,
        .waitable = waitable,
        .width = width,
        .height = height,
        .flags = flags,
    };
}

/// Releases the swap chain. The caller holds the context lock.
pub fn deinit(self: *Self) void {
    if (self.waitable) |h| _ = CloseHandle(h);
    // The back buffers may still be queued on the context.
    self.device.context.flush();
    com.release(self.chain);
    self.* = undefined;
}

/// Blocks until the swap chain can take another frame, for at most
/// `timeout_ms`. Does nothing unless a frame was presented since the last
/// wait. Does not touch the context: the caller may have released the
/// context lock for it.
pub fn waitForSlot(self: *Self, timeout_ms: u32) void {
    if (!self.presented_since_wait) return;
    self.presented_since_wait = false;

    const handle = self.waitable orelse return;
    _ = WaitForSingleObjectEx(handle, timeout_ms, 0);
}

/// Copies `target` into the back buffer, resizing the swap chain first if
/// its size differs. The caller holds the context lock.
pub fn copyToBackbuffer(
    self: *Self,
    ctx: *d3d11.ID3D11DeviceContext,
    target: *const Target,
) Error!void {
    self.device.assertContextLocked();

    const width: u32 = @intCast(target.width);
    const height: u32 = @intCast(target.height);
    if (width == 0 or height == 0) return error.InvalidArgument;
    if (width != self.width or height != self.height) try self.resize(width, height);

    // In flip model the current back buffer is always index 0. The
    // reference is dropped right away: `ResizeBuffers` needs them all gone.
    const back = try self.chain.asSwapChain1().asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D);
    defer com.release(back);
    ctx.copyResource(back.asResource(), target.texture.texture.asResource());
}

/// Presents the back buffer. With `vsync` it waits for the next vertical
/// blank, without it the frame may tear if the display supports it. An
/// occluded window is success: nothing was shown.
pub fn present(self: *Self, vsync: bool) Error!void {
    self.device.assertContextLocked();

    const tearing = !vsync and self.flags & dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING != 0;
    const hr = try self.chain.asSwapChain1().asSwapChain().present(
        @intFromBool(vsync),
        if (tearing) dxgi.PRESENT_ALLOW_TEARING else 0,
    );

    // An occluded present queues nothing, so there is no slot to wait for.
    if (hr != dxgi.STATUS_OCCLUDED) self.presented_since_wait = true;
}

/// Resizes the back buffers, repeating the creation flags. No reference to
/// a back buffer may be alive.
fn resize(self: *Self, width: u32, height: u32) Error!void {
    try self.chain.asSwapChain1().asSwapChain().resizeBuffers(0, width, height, .UNKNOWN, self.flags);
    self.width = width;
    self.height = height;
}

// Tests -----------------------------------------------------------------

const testing = std.testing;
const user32 = win32.user32;

/// A hidden window to attach swap chains to.
pub const TestWindow = struct {
    hwnd: foundation.HWND,

    pub fn init() !TestWindow {
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        const hwnd = user32.CreateWindowExW(
            0,
            class,
            null,
            user32.WS_POPUP,
            0,
            0,
            64,
            64,
            null,
            null,
            null,
            null,
        ) orelse return error.SkipZigTest;
        return .{ .hwnd = hwnd };
    }

    pub fn deinit(self: *TestWindow) void {
        _ = user32.DestroyWindow(self.hwnd);
    }
};

/// Fills a target with one colour, the way a frame would.
fn clearTarget(device: *Device, target: *Target, rgba: [4]f32) void {
    device.context.clearRenderTargetView(target.rtv(), rgba);
}

/// Reads the BGRA bytes of pixel (0, 0) of buffer 0.
fn readBackbuffer(self: *Self) ![4]u8 {
    const device = self.device;
    const back = try self.chain.asSwapChain1().asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D);
    defer com.release(back);

    const staging = try device.device.createTexture2D(&.{
        .Width = self.width,
        .Height = self.height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .staging,
        .BindFlags = .{},
        .CPUAccessFlags = .{ .read = true },
        .MiscFlags = 0,
    }, null);
    defer com.release(staging);

    device.context.copyResource(staging.asResource(), back.asResource());
    const mapped = try device.context.map(staging.asResource(), 0, .read, 0);
    defer device.context.unmap(staging.asResource(), 0);

    const src: [*]const u8 = @ptrCast(mapped.pData.?);
    return src[0..4].*;
}

test "d3d11 swapchain: copyToBackbuffer puts the target into the back buffer" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    var target = try Target.init(.{ .device = device, .width = 32, .height = 16, .srgb = false });
    defer target.deinit();
    var chain = try init(device, window.hwnd, 32, 16, .hwnd);

    device.lockContext();
    defer device.unlockContext();
    defer chain.deinit();

    clearTarget(device, &target, .{ 1, 0, 0, 1 });
    try chain.copyToBackbuffer(device.context, &target);

    // Between the copy and the present: the content of a discarded buffer
    // is undefined afterwards. BGRA red.
    const px = try readBackbuffer(&chain);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &px);
}

test "d3d11 swapchain: sRGB view stores encoded bytes the back buffer keeps" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    // The linear-blending target encodes on write; the copy must not.
    var target = try Target.init(.{ .device = device, .width = 8, .height = 8, .srgb = true });
    defer target.deinit();
    var chain = try init(device, window.hwnd, 8, 8, .hwnd);

    device.lockContext();
    defer device.unlockContext();
    defer chain.deinit();

    // Linear 0.5 encodes to sRGB 188.
    clearTarget(device, &target, .{ 0.5, 0.5, 0.5, 1 });
    try chain.copyToBackbuffer(device.context, &target);
    const px = try readBackbuffer(&chain);
    for (px[0..3]) |c| try testing.expect(c >= 187 and c <= 189);
    try testing.expectEqual(@as(u8, 255), px[3]);
}

test "d3d11 swapchain: present returns ok or occluded" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    var target = try Target.init(.{ .device = device, .width = 16, .height = 16, .srgb = false });
    defer target.deinit();
    var chain = try init(device, window.hwnd, 16, 16, .hwnd);

    device.lockContext();
    defer device.unlockContext();
    defer chain.deinit();

    // Both interval kinds; a failure HRESULT would be an error here.
    for ([_]bool{ true, false }) |vsync| {
        clearTarget(device, &target, .{ 0, 1, 0, 1 });
        try chain.copyToBackbuffer(device.context, &target);
        try chain.present(vsync);
    }
}

test "d3d11 swapchain: waitForSlot only waits after a present" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    var chain = try init(device, window.hwnd, 16, 16, .hwnd);
    device.lockContext();
    defer device.unlockContext();
    defer chain.deinit();

    // Nothing presented: returns at once whatever the timeout.
    const io = @import("../../global.zig").io();
    const start = std.Io.Timestamp.now(io, .awake);
    chain.waitForSlot(5000);
    try testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 1000);

    // A present arms the wait, and the wait disarms it.
    chain.presented_since_wait = true;
    chain.waitForSlot(0);
    try testing.expect(!chain.presented_since_wait);
}

test "d3d11 swapchain: resize 1x1 and back keeps creation flags" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    var chain = try init(device, window.hwnd, 64, 32, .hwnd);

    device.lockContext();
    defer device.unlockContext();
    defer chain.deinit();

    const created = try chain.chain.asSwapChain1().getDesc1();
    try testing.expect(created.Flags & dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT != 0);
    try testing.expectEqual(chain.flags, created.Flags);

    for ([_][2]u32{ .{ 1, 1 }, .{ 64, 32 }, .{ 200, 3 } }) |size| {
        var target = try Target.init(.{ .device = device, .width = size[0], .height = size[1], .srgb = false });
        defer target.deinit();
        clearTarget(device, &target, .{ 0, 0, 1, 1 });
        try chain.copyToBackbuffer(device.context, &target);

        const desc = try chain.chain.asSwapChain1().getDesc1();
        try testing.expectEqual(size[0], desc.Width);
        try testing.expectEqual(size[1], desc.Height);
        try testing.expectEqual(created.Flags, desc.Flags);
        try testing.expectEqual(created.BufferCount, desc.BufferCount);
        try testing.expectEqual(created.Format, desc.Format);
        try testing.expectEqual(dxgi.SwapEffect.FLIP_DISCARD, desc.SwapEffect);

        const px = try readBackbuffer(&chain);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &px);
        try chain.present(true);
    }
}

test "d3d11 swapchain: zero size is rejected" {
    const device = try Device.init(testing.allocator, .{ .driver = .warp });
    defer device.deinit(testing.allocator);
    var window: TestWindow = try .init();
    defer window.deinit();

    try testing.expectError(error.InvalidArgument, init(device, window.hwnd, 0, 10, .hwnd));
}
