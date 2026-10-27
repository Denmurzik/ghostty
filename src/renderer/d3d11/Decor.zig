//! The decor pass: per-surface decorations the apprt asks for, drawn over
//! the finished frame target right before it is copied to the swap chain.
//! Unfocused-split dimming and the bell border (Ghostty for macOS draws
//! both as SwiftUI overlays above the surface).
//!
//! The apprt describes the decorations in one 64-bit `Word`; a zero word
//! draws nothing and costs nothing, and the pipeline is created by the
//! first non-zero word. Every method uses the immediate context: the
//! caller holds the device context lock (the frame does).
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const RenderPass = @import("RenderPass.zig");
const Target = @import("Target.zig");
const bufferpkg = @import("buffer.zig");

const log = std.log.scoped(.d3d11);

/// What to draw. Colours are sRGB bytes, `rgb = r | g << 8 | b << 16`.
pub const Word = packed struct(u64) {
    /// Opacity of the dim layer, 0 for none.
    dim_alpha: u8 = 0,
    dim_rgb: u24 = 0,
    border: bool = false,
    /// Width of the border, in pixels.
    border_px: u7 = 0,
    border_rgb: u24 = 0,

    pub fn isZero(self: Word) bool {
        return @as(u64, @bitCast(self)) == 0;
    }
};

/// Opacity of the border colour (macOS: 0.5).
pub const border_alpha: f32 = 0.5;

/// The `Decor` cbuffer (`b2`) of `decor.hlsl`.
const Constants = extern struct {
    dim: [4]f32 align(16),
    border: [4]f32,
    border_px: f32,
    is_linear: f32,
    size: [2]f32,
};

pipeline: Pipeline,
constants: bufferpkg.Buffer(Constants),

/// The number of draw calls issued. For tests.
draw_calls: usize = 0,

pub fn init(device: *Device) !Self {
    const pipeline: Pipeline = try .init(null, .{
        .device = device,
        .vertex = .full_screen_vs,
        .pixel = .decor_ps,
        .blending_enabled = true,
    });
    errdefer pipeline.deinit();

    const constants: bufferpkg.Buffer(Constants) = try .init(
        .{ .device = device, .role = .constant },
        1,
    );

    return .{ .pipeline = pipeline, .constants = constants };
}

pub fn deinit(self: *Self) void {
    self.constants.deinit();
    self.pipeline.deinit();
}

fn channel(rgb: u24, shift: u5) f32 {
    return @as(f32, @floatFromInt((rgb >> shift) & 0xff)) / 255.0;
}

/// A premultiplied colour of `rgb` at `alpha`.
fn premultiplied(rgb: u24, alpha: f32) [4]f32 {
    return .{
        channel(rgb, 0) * alpha,
        channel(rgb, 8) * alpha,
        channel(rgb, 16) * alpha,
        alpha,
    };
}

fn constantsFor(word: Word, width: usize, height: usize, is_linear: bool) Constants {
    return .{
        .dim = premultiplied(word.dim_rgb, @as(f32, @floatFromInt(word.dim_alpha)) / 255.0),
        .border = if (word.border) premultiplied(word.border_rgb, border_alpha) else @splat(0),
        .border_px = if (word.border) @floatFromInt(word.border_px) else 0,
        .is_linear = if (is_linear) 1 else 0,
        .size = .{ @floatFromInt(width), @floatFromInt(height) },
    };
}

/// Draws `word` over `target`. `is_linear` is whether the target's views
/// are sRGB (linear blending). Nothing happens for a zero word.
pub fn draw(self: *Self, target: *const Target, word: Word, is_linear: bool) void {
    if (word.isZero()) return;

    const device = target.device;
    device.assertContextLocked();

    self.constants.sync(&.{constantsFor(word, target.width, target.height, is_linear)}) catch |err| {
        log.warn("unable to upload the decor constants err={}", .{err});
        return;
    };

    const ctx = device.context;
    ctx.psSetConstantBuffers(2, &.{self.constants.buffer.resource});

    const attachments = [_]RenderPass.Options.Attachment{.{
        .target = .{ .target = target.* },
    }};
    var pass = RenderPass.begin(.{ .attachments = &attachments });
    pass.step(.{
        .pipeline = self.pipeline,
        .draw = .{ .type = .triangle, .vertex_count = 3 },
    });
    pass.complete();
    ctx.psSetConstantBuffers(2, &.{null});
    self.draw_calls += 1;
}

fn pixelAt(pixels: []const u8, width: usize, x: usize, y: usize) [4]u8 {
    return pixels[(y * width + x) * 4 ..][0..4].*;
}

fn expectPixel(want: [4]u8, got: [4]u8, tolerance: u8) !void {
    for (want, got) |w, g| {
        const d = if (w > g) w - g else g - w;
        if (d > tolerance) {
            std.debug.print("pixel mismatch want={any} got={any}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

/// A target cleared to `clear` (premultiplied RGBA).
fn testTarget(device: *Device, width: usize, height: usize, clear: [4]f32) !Target {
    const target = try Target.init(.{ .device = device, .width = width, .height = height, .srgb = false });
    device.lockContext();
    defer device.unlockContext();
    const attachments = [_]RenderPass.Options.Attachment{.{
        .target = .{ .target = target },
        .clear_color = clear,
    }};
    RenderPass.begin(.{ .attachments = &attachments }).complete();
    return target;
}

test "d3d11 decor: dim blends the fill colour" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);
    var target = try testTarget(device, 16, 16, .{ 0, 0, 0, 1 });
    defer target.deinit();
    var decor: Self = try .init(device);
    defer decor.deinit();

    device.lockContext();
    defer device.unlockContext();
    decor.draw(&target, .{ .dim_alpha = 0x4D, .dim_rgb = 0xffffff }, false);

    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);
    try expectPixel(.{ 0x4D, 0x4D, 0x4D, 255 }, pixelAt(pixels, 16, 8, 8), 1);
    try expectPixel(.{ 0x4D, 0x4D, 0x4D, 255 }, pixelAt(pixels, 16, 0, 0), 1);
    try std.testing.expectEqual(@as(usize, 1), decor.draw_calls);
}

test "d3d11 decor: border touches only edge pixels" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);
    var target = try testTarget(device, 64, 32, .{ 0, 0, 0, 1 });
    defer target.deinit();
    var decor: Self = try .init(device);
    defer decor.deinit();

    device.lockContext();
    defer device.unlockContext();
    // Red, at half opacity over black.
    decor.draw(&target, .{ .border = true, .border_px = 2, .border_rgb = 0x0000ff }, false);

    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);
    // BGRA.
    try expectPixel(.{ 0, 0, 128, 255 }, pixelAt(pixels, 64, 0, 0), 1);
    try expectPixel(.{ 0, 0, 128, 255 }, pixelAt(pixels, 64, 1, 1), 1);
    try expectPixel(.{ 0, 0, 128, 255 }, pixelAt(pixels, 64, 63, 31), 1);
    try expectPixel(.{ 0, 0, 0, 255 }, pixelAt(pixels, 64, 2, 2), 0);
    try expectPixel(.{ 0, 0, 0, 255 }, pixelAt(pixels, 64, 61, 29), 0);
    try expectPixel(.{ 0, 0, 0, 255 }, pixelAt(pixels, 64, 32, 16), 0);
}

test "d3d11 decor: zero word draws nothing" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);
    var target = try testTarget(device, 8, 8, .{ 0, 0, 0, 1 });
    defer target.deinit();
    var decor: Self = try .init(device);
    defer decor.deinit();

    device.lockContext();
    defer device.unlockContext();
    decor.draw(&target, .{}, false);
    try std.testing.expectEqual(@as(usize, 0), decor.draw_calls);
}

test "d3d11 decor: word is 64 bits and zero by default" {
    try std.testing.expect((Word{}).isZero());
    try std.testing.expect(!(Word{ .border = true }).isZero());
    try std.testing.expectEqual(@as(u64, 0x4D), @as(u64, @bitCast(Word{ .dim_alpha = 0x4D })));
}
