//! Tests for the DirectComposition bindings and the composition swap chain
//! path (M3 Task 8): vtable layouts against dcomp.h / dxgi1_2.h of SDK
//! 10.0.26100 and headless WARP checks. The windowed checks (R10) live in
//! test/windows/composition-spike.
const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const dxgi = win32.dxgi;
const d3d11 = win32.d3d11;
const dcomp = win32.dcomp;

fn slots(comptime T: type) usize {
    return @sizeOf(T.VTable) / @sizeOf(usize);
}

fn slot(comptime T: type, comptime name: []const u8) usize {
    return @offsetOf(T.VTable, name) / @sizeOf(usize);
}

test "win32 dcomp: interface slot counts" {
    // Total slots including IUnknown, counted from um/dcomp.h.
    try std.testing.expectEqual(27, slots(dcomp.IDCompositionDevice));
    try std.testing.expectEqual(4, slots(dcomp.IDCompositionTarget));
    try std.testing.expectEqual(20, slots(dcomp.IDCompositionVisual));

    try std.testing.expectEqual(3, slot(dcomp.IDCompositionDevice, "Commit"));
    try std.testing.expectEqual(4, slot(dcomp.IDCompositionDevice, "WaitForCommitCompletion"));
    try std.testing.expectEqual(6, slot(dcomp.IDCompositionDevice, "CreateTargetForHwnd"));
    try std.testing.expectEqual(7, slot(dcomp.IDCompositionDevice, "CreateVisual"));
    try std.testing.expectEqual(26, slot(dcomp.IDCompositionDevice, "CheckDeviceState"));
    try std.testing.expectEqual(3, slot(dcomp.IDCompositionTarget, "SetRoot"));
    try std.testing.expectEqual(15, slot(dcomp.IDCompositionVisual, "SetContent"));
    try std.testing.expectEqual(16, slot(dcomp.IDCompositionVisual, "AddVisual"));
    try std.testing.expectEqual(17, slot(dcomp.IDCompositionVisual, "RemoveVisual"));
    try std.testing.expectEqual(18, slot(dcomp.IDCompositionVisual, "RemoveAllVisuals"));
    try std.testing.expectEqual(19, slot(dcomp.IDCompositionVisual, "SetCompositeMode"));
}

test "win32 dxgi: CreateSwapChainForComposition typed" {
    try std.testing.expectEqual(24, slot(dxgi.IDXGIFactory2, "CreateSwapChainForComposition"));

    const created = try d3d11.createDevice(.warp, .{ .bgra_support = true });
    defer com.release(created.context);
    defer com.release(created.device);
    const factory = try dxgi.createFactory(false);
    defer com.release(factory);

    const swap = try factory.createSwapChainForComposition(created.device, &.{
        .Width = 64,
        .Height = 64,
        .Format = .B8G8R8A8_UNORM,
        .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = .STRETCH,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .PREMULTIPLIED,
        .Flags = 0,
    });
    defer com.release(swap);
    const desc = try swap.getDesc1();
    try std.testing.expectEqual(dxgi.AlphaMode.PREMULTIPLIED, desc.AlphaMode);
    try std.testing.expectEqual(@as(u32, 64), desc.Width);
}

test "win32 dcomp: device without a rendering device takes a swap chain as visual content" {
    const created = try d3d11.createDevice(.warp, .{ .bgra_support = true });
    defer com.release(created.context);
    defer com.release(created.device);
    const factory = try dxgi.createFactory(false);
    defer com.release(factory);
    const swap = try factory.createSwapChainForComposition(created.device, &.{
        .Width = 64,
        .Height = 64,
        .Format = .B8G8R8A8_UNORM,
        .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = .STRETCH,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .PREMULTIPLIED,
        .Flags = 0,
    });
    defer com.release(swap);

    const device = try dcomp.createDevice(null);
    defer com.release(device);
    const visual = try device.createVisual();
    defer com.release(visual);
    const child = try device.createVisual();
    defer com.release(child);
    try visual.setContent(swap);
    try visual.addVisual(child, true, null);
    try visual.removeVisual(child);
    try visual.setContent(null);
    try device.commit();
    try device.waitForCommitCompletion();
    try std.testing.expect(try device.checkDeviceState());
}
