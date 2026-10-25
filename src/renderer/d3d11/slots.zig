//! The fixed D3D11 register map shared by every builtin shader. Mirror of
//! the declarations in `shaders/hlsl/common.hlsli`; `RenderPass` binds
//! resources from these numbers per stage.
const std = @import("std");
const assert = std.debug.assert;

/// Uniforms constant buffer (`b1`), bound to both VS and PS.
pub const uniforms_cb: u32 = 1;

/// `buffers[i]` for `i >= 1` is a structured buffer SRV at `t(3 + i)`,
/// bound to both VS and PS. `buffers[0]` is the IA vertex buffer.
pub const buffer_srv_base: u32 = 3;

/// `textures[i]` is an SRV at `t(i)`, bound to PS only. Limited to
/// `t0..t2` so buffer SRVs (`t4` and up) never alias a texture.
pub const max_textures: u32 = 3;

/// The SRV register for `buffers[i]`.
pub fn bufferSrv(i: usize) u32 {
    assert(i >= 1);
    return buffer_srv_base + @as(u32, @intCast(i));
}

test "d3d11 slots: bg_cells register matches slots.zig and does not alias textures" {
    const common = @embedFile("../shaders/hlsl/common.hlsli");

    // bg_cells is buffers[1] and must be declared at exactly that register.
    try std.testing.expectEqual(@as(u32, 4), bufferSrv(1));
    try std.testing.expect(std.mem.indexOf(
        u8,
        common,
        "StructuredBuffer<uint> bg_cells : register(t4);",
    ) != null);

    // No buffer SRV can land on a texture register.
    try std.testing.expect(bufferSrv(1) >= max_textures);

    // The remaining registers of the map.
    try std.testing.expect(std.mem.indexOf(u8, common, "cbuffer Globals : register(b1)") != null);
    try std.testing.expectEqual(@as(u32, 1), uniforms_cb);
    const cell_text = @embedFile("../shaders/hlsl/cell_text.hlsl");
    try std.testing.expect(std.mem.indexOf(u8, cell_text, "atlas_grayscale : register(t0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, cell_text, "atlas_color : register(t1);") != null);
    const image = @embedFile("../shaders/hlsl/image.hlsl");
    try std.testing.expect(std.mem.indexOf(u8, image, "image : register(t0);") != null);
    const bg_image = @embedFile("../shaders/hlsl/bg_image.hlsl");
    try std.testing.expect(std.mem.indexOf(u8, bg_image, "image : register(t0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, common, "linear_clamp : register(s0);") != null);
}
