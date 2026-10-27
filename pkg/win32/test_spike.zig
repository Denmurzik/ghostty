//! Spike tests for the hand-written COM/DXGI/D3D11/d3dcompiler bindings:
//! vtable layouts against the SDK 10.0.26100 headers, a real WARP device
//! clear + readback, and a real D3DCompile call.
const std = @import("std");
const win32 = @import("win32");
const foundation = win32.foundation;
const com = win32.com;
const dxgi = win32.dxgi;
const d3d11 = win32.d3d11;
const d3dcompiler = win32.d3dcompiler;

fn slots(comptime T: type) usize {
    return @sizeOf(T.VTable) / @sizeOf(usize);
}

test "win32 com: vtable slot counts" {
    // Total slots including inherited ones, counted from the Windows SDK
    // 10.0.26100 headers (um/d3d11.h, shared/dxgi.h, dxgi1_2.h, dxgi1_3.h).
    try std.testing.expectEqual(3, slots(com.IUnknown));

    // dxgi.h, dxgi1_2.h, dxgi1_3.h: IDXGIDevice 12, +SetMaximumFrameLatency/Get (14), +Offer/Reclaim/Enqueue (17), +Trim (18).
    try std.testing.expectEqual(12, slots(dxgi.IDXGIDevice));
    try std.testing.expectEqual(14, slots(dxgi.IDXGIDevice1));
    try std.testing.expectEqual(17, slots(dxgi.IDXGIDevice2));
    try std.testing.expectEqual(18, slots(dxgi.IDXGIDevice3));
    try std.testing.expectEqual(17 * @sizeOf(usize), @offsetOf(dxgi.IDXGIDevice3.VTable, "Trim"));

    try std.testing.expectEqual(43, slots(d3d11.ID3D11Device));
    try std.testing.expectEqual(7, slots(d3d11.ID3D11DeviceChild));
    try std.testing.expectEqual(115, slots(d3d11.ID3D11DeviceContext));
    try std.testing.expectEqual(10, slots(d3d11.ID3D11Resource));
    try std.testing.expectEqual(11, slots(d3d11.ID3D11Buffer));
    try std.testing.expectEqual(11, slots(d3d11.ID3D11Texture2D));
    try std.testing.expectEqual(8, slots(d3d11.ID3D11View));
    try std.testing.expectEqual(9, slots(d3d11.ID3D11RenderTargetView));
    try std.testing.expectEqual(9, slots(d3d11.ID3D11ShaderResourceView));
    try std.testing.expectEqual(8, slots(d3d11.ID3D11SamplerState));
    try std.testing.expectEqual(8, slots(d3d11.ID3D11BlendState));
    try std.testing.expectEqual(8, slots(d3d11.ID3D11RasterizerState));
    try std.testing.expectEqual(7, slots(d3d11.ID3D11InputLayout));
    try std.testing.expectEqual(7, slots(d3d11.ID3D11VertexShader));
    try std.testing.expectEqual(7, slots(d3d11.ID3D11PixelShader));

    try std.testing.expectEqual(7, slots(dxgi.IDXGIObject));
    try std.testing.expectEqual(12, slots(dxgi.IDXGIFactory));
    try std.testing.expectEqual(14, slots(dxgi.IDXGIFactory1));
    try std.testing.expectEqual(25, slots(dxgi.IDXGIFactory2));
    try std.testing.expectEqual(10, slots(dxgi.IDXGIAdapter));
    try std.testing.expectEqual(11, slots(dxgi.IDXGIAdapter1));
    try std.testing.expectEqual(12, slots(dxgi.IDXGIDevice));
    try std.testing.expectEqual(8, slots(dxgi.IDXGIDeviceSubObject));
    try std.testing.expectEqual(18, slots(dxgi.IDXGISwapChain));
    try std.testing.expectEqual(29, slots(dxgi.IDXGISwapChain1));
    try std.testing.expectEqual(36, slots(dxgi.IDXGISwapChain2));

    try std.testing.expectEqual(5, slots(d3dcompiler.ID3DBlob));
    // ID3DInclude is a plain C++ interface (no IUnknown): { Open, Close }.
    try std.testing.expectEqual(2, slots(d3dcompiler.ID3DInclude));
}

test "win32 com: typed slots sit at their header offsets" {
    // Header order (0-based): CreateTexture2D 5, CreateRenderTargetView 9,
    // GetImmediateContext 40; context: Map 14, Unmap 15, CopyResource 47,
    // ClearRenderTargetView 50.
    try std.testing.expectEqual(5 * @sizeOf(usize), @offsetOf(d3d11.ID3D11Device.VTable, "CreateTexture2D"));
    try std.testing.expectEqual(9 * @sizeOf(usize), @offsetOf(d3d11.ID3D11Device.VTable, "CreateRenderTargetView"));
    try std.testing.expectEqual(40 * @sizeOf(usize), @offsetOf(d3d11.ID3D11Device.VTable, "GetImmediateContext"));
    try std.testing.expectEqual(14 * @sizeOf(usize), @offsetOf(d3d11.ID3D11DeviceContext.VTable, "Map"));
    try std.testing.expectEqual(15 * @sizeOf(usize), @offsetOf(d3d11.ID3D11DeviceContext.VTable, "Unmap"));
    try std.testing.expectEqual(47 * @sizeOf(usize), @offsetOf(d3d11.ID3D11DeviceContext.VTable, "CopyResource"));
    try std.testing.expectEqual(50 * @sizeOf(usize), @offsetOf(d3d11.ID3D11DeviceContext.VTable, "ClearRenderTargetView"));
    // IDXGIFactory2::CreateSwapChainForHwnd is slot 15, Present is 8.
    try std.testing.expectEqual(15 * @sizeOf(usize), @offsetOf(dxgi.IDXGIFactory2.VTable, "CreateSwapChainForHwnd"));
    try std.testing.expectEqual(8 * @sizeOf(usize), @offsetOf(dxgi.IDXGISwapChain.VTable, "Present"));
}

test "win32 foundation: HRESULT mapping" {
    try foundation.check(0);
    try foundation.check(1); // S_FALSE is still a success
    try std.testing.expect(foundation.succeeded(0));
    try std.testing.expect(!foundation.succeeded(foundation.E_FAIL));

    try std.testing.expectEqual(error.DeviceLost, foundation.mapHresult(foundation.DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expectEqual(error.DeviceLost, foundation.mapHresult(foundation.DXGI_ERROR_DEVICE_RESET));
    try std.testing.expectEqual(error.DeviceLost, foundation.mapHresult(foundation.DXGI_ERROR_DEVICE_HUNG));
    try std.testing.expectEqual(error.OutOfMemory, foundation.mapHresult(foundation.E_OUTOFMEMORY));
    try std.testing.expectEqual(error.WouldBlock, foundation.mapHresult(foundation.DXGI_ERROR_WAS_STILL_DRAWING));
    try std.testing.expectEqual(error.InvalidArgument, foundation.mapHresult(foundation.E_INVALIDARG));
    try std.testing.expectEqual(error.ComFailure, foundation.mapHresult(foundation.E_FAIL));
    try std.testing.expectError(error.DeviceLost, foundation.check(foundation.DXGI_ERROR_DEVICE_REMOVED));
}

test "win32 foundation: GUID parse" {
    const g = foundation.GUID.parse("db6f6ddb-ac77-4e88-8253-819df9bbf140");
    try std.testing.expectEqual(@as(u32, 0xdb6f6ddb), g.Data1);
    try std.testing.expectEqual(@as(u16, 0xac77), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x4e88), g.Data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 }, &g.Data4);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(foundation.GUID));
}

test "win32 spike: WARP clear and readback" {
    const created = try d3d11.createDevice(.warp, .{ .bgra_support = true });
    defer com.release(created.context);
    defer com.release(created.device);
    try std.testing.expect(@backingInt(created.level) >= @backingInt(d3d11.FeatureLevel.@"11_0"));

    const rt = try created.device.createTexture2D(&.{
        .Width = 4,
        .Height = 4,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .default,
        .BindFlags = .{ .render_target = true },
        .CPUAccessFlags = .{},
        .MiscFlags = 0,
    }, null);
    defer com.release(rt);

    const staging = try created.device.createTexture2D(&.{
        .Width = 4,
        .Height = 4,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .staging,
        .BindFlags = .{},
        .CPUAccessFlags = .{ .read = true },
        .MiscFlags = 0,
    }, null);
    defer com.release(staging);

    const rtv = try created.device.createRenderTargetView(rt.asResource(), null);
    defer com.release(rtv);

    created.context.clearRenderTargetView(rtv, .{ 1, 0, 0, 1 });
    created.context.copyResource(staging.asResource(), rt.asResource());

    const mapped = try created.context.map(staging.asResource(), 0, .read, 0);
    defer created.context.unmap(staging.asResource(), 0);
    const bytes: [*]const u8 = @ptrCast(mapped.pData.?);
    // B8G8R8A8: opaque red is B=0 G=0 R=255 A=255.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bytes[0..4]);
}

test "win32 spike: DXGI factory and queryInterface" {
    const factory = try dxgi.createFactory(false);
    defer com.release(factory);
    const base = try com.queryInterface(factory, dxgi.IDXGIFactory);
    defer com.release(base);
}

test "win32 spike: D3DCompile trivial pixel shader" {
    const compiler = try d3dcompiler.Compiler.load();
    const code = try compiler.compile(std.testing.allocator, .{
        .source = "float4 main() : SV_Target { return 1; }",
        .source_name = "trivial.hlsl",
        .entry = "main",
        .target = "ps_5_0",
    });
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 0);
    // DXBC container magic.
    try std.testing.expectEqualSlices(u8, "DXBC", code[0..4]);
}

test "win32 spike: D3DCompile reports errors" {
    // The compiler diagnostics are logged at warn; this failure is expected.
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;

    const compiler = try d3dcompiler.Compiler.load();
    try std.testing.expectError(error.CompileFailed, compiler.compile(std.testing.allocator, .{
        .source = "nonsense",
        .source_name = "bad.hlsl",
        .entry = "main",
        .target = "ps_5_0",
    }));
}
