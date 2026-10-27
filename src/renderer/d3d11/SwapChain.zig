//! A flip-model swap chain for a window.
//!
//! Two `FLIP_DISCARD` buffers with a frame latency waitable object: the
//! renderer waits on it before encoding a frame (`waitForSlot`, only after
//! a `present`), so the render thread runs at the display rate without
//! queueing frames. Frames are rendered into a `Target` and copied into the
//! back buffer (`copyToBackbuffer`) right before `present`.
//!
//! Everything that touches the swap chain except `waitForSlot` runs under
//! the device context lock; `pacer` is atomic so that wait needs no lock. `MakeWindowAssociation(NO_WINDOW_CHANGES)`
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
const kernel32 = win32.kernel32;
const Device = @import("Device.zig");
const Target = @import("Target.zig");
const latency = @import("../../os/main.zig").windows_latency;

const log = std.log.scoped(.d3d11);

const ns_per_ms = std.time.ns_per_ms;

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

/// Presents not yet matched by a wait (see `Pacer`). Atomic: the render
/// thread waits without the draw mutex while a sync draw may present.
pacer: Pacer = .{},

/// The id of the surface this chain presents for (latency trace tag).
surface_id: u32 = 0,

/// Set once a failing wait was logged.
wait_failed_logged: std.atomic.Value(bool) = .init(false),

/// Unique per created chain: a new chain may reuse the old one's addresses.
serial: u64,

var next_serial: std.atomic.Value(u64) = .init(1);

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

    // After creation, which registers the window association itself, and
    // before the first `Present`: DXGI must neither watch the window for
    // Alt+Enter and size changes nor subclass it.
    try device.factory.asFactory().makeWindowAssociation(
        window,
        dxgi.MWA_NO_WINDOW_CHANGES | dxgi.MWA_NO_ALT_ENTER,
    );

    const chain = try com.queryInterface(chain1, dxgi.IDXGISwapChain2);
    errdefer com.release(chain);

    try chain.setMaximumFrameLatency(1);
    const waitable = chain.getFrameLatencyWaitableObject();
    errdefer if (waitable) |h| {
        _ = kernel32.CloseHandle(h);
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
        .serial = next_serial.fetchAdd(1, .monotonic),
    };
}

/// Releases the swap chain. The caller holds the context lock.
pub fn deinit(self: *Self) void {
    if (self.waitable) |h| _ = kernel32.CloseHandle(h);
    // The back buffers may still be queued on the context.
    self.device.context.flush();
    com.release(self.chain);
    self.* = undefined;
}

/// Waits until the swap chain can take another frame, for at most
/// `timeout_ms` (0 polls). Does nothing unless a present is waiting to be
/// matched, and never blocks after the chain sat idle (`Pacer.idle_ns`).
/// Returns whether a slot is free. A timed out wait leaves the present
/// pending (the next wait still has to consume it), so the waitable's count
/// does not drift. Does not touch the context: the caller may have released
/// the context lock for it.
pub fn waitForSlot(self: *Self, timeout_ms: u32) bool {
    const handle = self.waitable orelse {
        self.pacer.pending.store(0, .monotonic);
        return true;
    };
    const waiter: HandleWaiter = .{ .handle = handle, .owner = self };
    return self.pacer.wait(nowNs(), timeout_ms, waiter);
}

/// A wait that runs without the context lock, so the chain may be dropped
/// (and a new one created) meanwhile: it holds its own duplicate of the
/// waitable, and its result only counts for the chain it started on.
pub const UnlockedWait = struct {
    handle: foundation.HANDLE,
    serial: u64,

    /// Blocks for at most `timeout_ms` and closes the duplicate.
    pub fn wait(self: UnlockedWait, timeout_ms: u32) Pacer.WaitResult {
        defer _ = kernel32.CloseHandle(self.handle);
        return switch (kernel32.WaitForSingleObjectEx(self.handle, timeout_ms, 0)) {
            kernel32.WAIT_OBJECT_0 => .signaled,
            kernel32.WAIT_TIMEOUT => .timeout,
            else => .failed,
        };
    }
};

/// Starts an `UnlockedWait`; null without a waitable or when it cannot be
/// duplicated (the caller then skips the wait). The caller holds the lock.
pub fn beginUnlockedWait(self: *Self) ?UnlockedWait {
    self.device.assertContextLocked();
    const handle = self.waitable orelse return null;
    const process = kernel32.GetCurrentProcess();
    var dup: foundation.HANDLE = undefined;
    if (kernel32.DuplicateHandle(process, handle, process, &dup, 0, 0, kernel32.DUPLICATE_SAME_ACCESS) == 0) return null;
    return .{ .handle = dup, .serial = self.serial };
}

/// Books the result of `w` if this is still the chain it waited on. The
/// caller holds the lock again.
pub fn finishUnlockedWait(self: *Self, w: UnlockedWait, result: Pacer.WaitResult) void {
    self.device.assertContextLocked();
    if (self.serial != w.serial) return;
    if (result == .failed and !self.wait_failed_logged.swap(true, .monotonic)) {
        log.warn("d3d11 swap chain wait failed, frames are not paced", .{});
    }
    self.pacer.book(result);
}

/// Whether a present is waiting to be matched by a wait.
pub fn waitArmed(self: *const Self) bool {
    return self.pacer.pending.load(.monotonic) > 0;
}

/// Whether the chain has been idle long enough that no frame of it can
/// still be queued.
pub fn idle(self: *const Self) bool {
    return self.pacer.isIdle(nowNs());
}

fn nowNs() u64 {
    const io = @import("../../global.zig").io();
    return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).toNanoseconds()));
}

const HandleWaiter = struct {
    handle: foundation.HANDLE,
    owner: *Self,

    pub fn wait(self: HandleWaiter, timeout_ms: u32) Pacer.WaitResult {
        return switch (kernel32.WaitForSingleObjectEx(self.handle, timeout_ms, 0)) {
            kernel32.WAIT_OBJECT_0 => .signaled,
            kernel32.WAIT_TIMEOUT => .timeout,
            else => {
                // A broken handle would fail every frame: give up on pacing.
                if (!self.owner.wait_failed_logged.swap(true, .monotonic)) {
                    log.warn("d3d11 swap chain wait failed, frames are not paced", .{});
                }
                return .failed;
            },
        };
    }
};

/// Book-keeping for the frame latency waitable object: a slot is only
/// consumed by a present, so a wait without one would block for nothing.
/// Presents are counted, not flagged: two presents between waits leave one
/// pending after one wait.
pub const Pacer = struct {
    pub const WaitResult = enum { signaled, timeout, failed };

    /// A chain that presented nothing for this long has no frame queued;
    /// the vblank is 16.7 ms at 60 Hz and the compositor may add frames.
    pub const idle_ns: u64 = 50 * ns_per_ms;

    /// Presents that no wait consumed yet; never more than the back
    /// buffers, which bound the frames in flight. Atomic: a wait and a
    /// present (or two waits) may run on different threads at once.
    pending: std.atomic.Value(u32) = .init(0),

    /// When the last present returned.
    last_present_ns: std.atomic.Value(u64) = .init(0),

    pub fn presented(self: *Pacer, now: u64) void {
        self.last_present_ns.store(now, .release);
        var cur = self.pending.load(.monotonic);
        while (cur < buffer_count) {
            cur = self.pending.cmpxchgWeak(cur, cur + 1, .release, .monotonic) orelse return;
        }
    }

    pub fn isIdle(self: *const Pacer, now: u64) bool {
        return self.pending.load(.acquire) > 0 and
            now -| self.last_present_ns.load(.acquire) >= idle_ns;
    }

    /// `waiter.wait(timeout_ms)` returns a `WaitResult`. An idle chain is
    /// only polled: its frame is long gone, blocking would be for nothing.
    pub fn wait(self: *Pacer, now: u64, timeout_ms: u32, waiter: anytype) bool {
        if (self.pending.load(.monotonic) == 0) return true;
        const effective = if (self.isIdle(now)) 0 else timeout_ms;
        const result = waiter.wait(effective);
        self.book(result);
        return result != .timeout;
    }

    /// Accounts for one wait: a signal matches a present, a failure gives
    /// up on pacing, a timeout leaves the present pending.
    pub fn book(self: *Pacer, result: WaitResult) void {
        switch (result) {
            .signaled => self.consume(),
            .timeout => {},
            .failed => self.pending.store(0, .monotonic),
        }
    }

    /// One present matched by a wait; another wait may have matched it
    /// first, so this never goes below zero.
    fn consume(self: *Pacer) void {
        var cur = self.pending.load(.monotonic);
        while (cur > 0) {
            cur = self.pending.cmpxchgWeak(cur, cur - 1, .monotonic, .monotonic) orelse return;
        }
    }
};

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

    latency.markPresent(self.surface_id);

    // An occluded present queues nothing, so there is no slot to wait for.
    if (hr != dxgi.STATUS_OCCLUDED) self.pacer.presented(nowNs());
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
    try testing.expect(chain.waitForSlot(5000));
    try testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 1000);

    // A present arms the wait, and the wait disarms it.
    chain.pacer.presented(nowNs());
    const acquired = chain.waitForSlot(0);
    // Only a consumed slot disarms the wait; a timeout leaves it pending.
    try testing.expectEqual(@as(u32, if (acquired) 0 else 1), chain.pacer.pending.load(.monotonic));
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

/// A waitable that signals from a script, recording the timeouts it saw.
const FakeWaiter = struct {
    results: []const Pacer.WaitResult,
    calls: usize = 0,
    timeouts: [8]u32 = undefined,

    pub fn wait(self: *FakeWaiter, timeout_ms: u32) Pacer.WaitResult {
        self.timeouts[self.calls] = timeout_ms;
        defer self.calls += 1;
        return self.results[self.calls];
    }
};

const FakeRef = struct {
    inner: *FakeWaiter,

    pub fn wait(self: FakeRef, timeout_ms: u32) Pacer.WaitResult {
        return self.inner.wait(timeout_ms);
    }
};

test "d3d11 swapchain: pending presents are counted, not a bool" {
    var p: Pacer = .{};
    p.presented(0);
    p.presented(1);
    try testing.expectEqual(@as(u32, 2), p.pending.load(.monotonic));

    var w: FakeWaiter = .{ .results = &.{ .signaled, .timeout, .timeout, .signaled } };
    try testing.expect(p.wait(2, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(u32, 1), p.pending.load(.monotonic));

    // Timed out waits keep the present pending and never underflow.
    try testing.expect(!p.wait(3, 100, FakeRef{ .inner = &w }));
    try testing.expect(!p.wait(4, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(u32, 1), p.pending.load(.monotonic));
    try testing.expect(p.wait(5, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(u32, 0), p.pending.load(.monotonic));

    // Nothing pending: the waiter is not even asked.
    try testing.expect(p.wait(6, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(usize, 4), w.calls);

    // Capped at the back buffers.
    for (0..10) |i| p.presented(i);
    try testing.expectEqual(@as(u32, buffer_count), p.pending.load(.monotonic));
}

test "d3d11 frame slot: no wait after an idle interval" {
    var p: Pacer = .{};
    p.presented(1_000);

    // Just presented: the wait may block for its whole timeout.
    var busy: FakeWaiter = .{ .results = &.{.timeout} };
    try testing.expect(!p.wait(1_000 + ns_per_ms, 100, FakeRef{ .inner = &busy }));
    try testing.expectEqual(@as(u32, 100), busy.timeouts[0]);

    // Idle for longer than the threshold: only a poll, never a block.
    var idle_w: FakeWaiter = .{ .results = &.{ .timeout, .signaled } };
    const later = 1_000 + Pacer.idle_ns;
    try testing.expect(p.isIdle(later));
    try testing.expect(!p.wait(later, 100, FakeRef{ .inner = &idle_w }));
    try testing.expectEqual(@as(u32, 0), idle_w.timeouts[0]);
    try testing.expect(p.wait(later, 100, FakeRef{ .inner = &idle_w }));
    try testing.expectEqual(@as(u32, 0), idle_w.timeouts[1]);
    try testing.expect(!p.isIdle(later));
}

test "d3d11 frame slot: a failing waitable gives up on pacing" {
    var p: Pacer = .{};
    p.presented(0);
    var w: FakeWaiter = .{ .results = &.{.failed} };
    try testing.expect(p.wait(0, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(u32, 0), p.pending.load(.monotonic));
}

test "d3d11 frame slot: concurrent waits and presents keep pending in bounds" {
    // The render thread waits without the draw mutex, so a sync draw on the
    // UI thread may present and poll at the same time.
    const Signaled = struct {
        pub fn wait(_: @This(), _: u32) Pacer.WaitResult {
            return .signaled;
        }
    };
    const Worker = struct {
        p: *Pacer,
        out_of_bounds: *std.atomic.Value(bool),

        fn present(self: @This()) void {
            for (0..20_000) |i| {
                self.p.presented(i);
                self.check();
            }
        }

        fn wait(self: @This()) void {
            for (0..20_000) |i| {
                _ = self.p.wait(i, 100, Signaled{});
                self.check();
            }
        }

        fn check(self: @This()) void {
            if (self.p.pending.load(.monotonic) > buffer_count)
                self.out_of_bounds.store(true, .monotonic);
        }
    };

    var p: Pacer = .{};
    var out_of_bounds: std.atomic.Value(bool) = .init(false);
    const w: Worker = .{ .p = &p, .out_of_bounds = &out_of_bounds };
    var threads: [3]std.Thread = .{
        try std.Thread.spawn(.{}, Worker.present, .{w}),
        try std.Thread.spawn(.{}, Worker.wait, .{w}),
        try std.Thread.spawn(.{}, Worker.wait, .{w}),
    };
    for (&threads) |*t| t.join();
    try testing.expect(!out_of_bounds.load(.monotonic));
}

test "d3d11 frame slot: a second wait after a consumed slot does not block" {
    var p: Pacer = .{};
    p.presented(0);

    // The first wait takes the slot; the second finds nothing pending and
    // never reaches the waitable.
    var w: FakeWaiter = .{ .results = &.{.signaled} };
    try testing.expect(p.wait(ns_per_ms, 100, FakeRef{ .inner = &w }));
    try testing.expect(p.wait(2 * ns_per_ms, 100, FakeRef{ .inner = &w }));
    try testing.expectEqual(@as(u32, 0), p.pending.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), w.calls);
}
