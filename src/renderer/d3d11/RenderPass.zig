//! Wrapper for handling render passes.
//!
//! Every method uses the immediate context: the caller holds the device
//! context lock (the frame does, from begin to complete).
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const d3d11 = win32.d3d11;
const Device = @import("Device.zig");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const bufferpkg = @import("buffer.zig");
const slots = @import("slots.zig");
const Uniforms = @import("shaders.zig").Uniforms;

const log = std.log.scoped(.d3d11);

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.Handle = null,
    buffers: []const ?bufferpkg.Handle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };

    pub const Primitive = enum {
        triangle,
        triangle_strip,

        fn topology(self: Primitive) d3d11.PRIMITIVE_TOPOLOGY {
            return switch (self) {
                .triangle => .TRIANGLELIST,
                .triangle_strip => .TRIANGLESTRIP,
            };
        }
    };
};

attachments: []const Options.Attachment,

step_number: usize = 0,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
    };
}

/// The first attachment's view, size and device.
const Bound = struct {
    device: *Device,
    rtv: *d3d11.ID3D11RenderTargetView,
    /// The raw view `Pipeline.post` passes draw through, if the target has one.
    gamma_rtv: ?*d3d11.ID3D11RenderTargetView,
    width: usize,
    height: usize,
};

fn bound(self: *const Self) ?Bound {
    switch (self.attachments[0].target) {
        .target => |t| return .{
            .device = t.device,
            .rtv = t.rtv(),
            .gamma_rtv = t.texture.gamma_rtv,
            .width = t.width,
            .height = t.height,
        },
        .texture => |t| return .{
            .device = t.device,
            .rtv = t.rtv orelse {
                log.warn("render pass attachment texture has no render target view", .{});
                return null;
            },
            .gamma_rtv = t.gamma_rtv,
            .width = t.width,
            .height = t.height,
        },
    }
}

/// Add a step to this render pass.
///
/// Errors are not reported: the draw is skipped.
pub fn step(self: *Self, s: Step) void {
    const att = self.bound() orelse return;
    const device = att.device;
    device.assertContextLocked();
    const ctx = device.context;

    // Custom shader passes work in gamma space whatever the views encode.
    const rtv = if (s.pipeline.post) att.gamma_rtv orelse att.rtv else att.rtv;
    ctx.omSetRenderTargets(&.{rtv});

    // If we have a clear color and this is the
    // first step in the pass, go ahead and clear.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        ctx.clearRenderTargetView(rtv, c);
    };
    self.step_number += 1;

    if (s.draw.instance_count == 0) return;

    const pipeline = s.pipeline;

    ctx.rsSetViewports(&.{.{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(att.width),
        .Height = @floatFromInt(att.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    }});
    ctx.rsSetState(pipeline.rasterizer_state);
    ctx.omSetBlendState(pipeline.blend_state);

    ctx.iaSetInputLayout(pipeline.input_layout);
    ctx.iaSetPrimitiveTopology(s.draw.type.topology());
    ctx.vsSetShader(pipeline.vertex_shader);
    ctx.psSetShader(pipeline.pixel_shader);

    // The uniform buffer is bound at b1 to align with Metal.
    if (s.uniforms) |ubo| {
        ctx.vsSetConstantBuffers(slots.uniforms_cb, &.{ubo.resource});
        ctx.psSetConstantBuffers(slots.uniforms_cb, &.{ubo.resource});
    }

    // Texture i is bound at t(i), sampler i at s(i), pixel stage only.
    for (s.textures, 0..) |t, i| if (t) |tex| {
        if (i >= slots.max_textures) {
            log.warn("texture slot {d} exceeds the register map", .{i});
            return;
        }
        ctx.psSetShaderResources(@intCast(i), &.{tex.srv});
    };
    for (s.samplers, 0..) |s_, i| if (s_) |sampler| {
        ctx.psSetSamplers(@intCast(i), &.{sampler.sampler});
    };

    // Bind 0th buffer as the vertex buffer, and bind the rest as
    // structured buffers readable by both stages.
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| ctx.iaSetVertexBuffer(
            0,
            vbo.resource,
            @intCast(pipeline.stride),
            0,
        );

        for (s.buffers[1..], 1..) |b, i| if (b) |buf| {
            const srv = buf.srv orelse {
                log.warn("buffer {d} has no shader resource view", .{i});
                return;
            };
            ctx.vsSetShaderResources(slots.bufferSrv(i), &.{srv});
            ctx.psSetShaderResources(slots.bufferSrv(i), &.{srv});
        };
    }

    // Always an instanced draw from vertex 0, so SV_VertexID is the
    // corner index within the instance.
    ctx.drawInstanced(
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    const att = self.bound() orelse return;
    att.device.assertContextLocked();
    const ctx = att.device.context;

    // A pass without steps still clears, like a Metal load action.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        ctx.clearRenderTargetView(att.rtv, c);
    };

    // Release the target so it can be sampled or copied afterwards.
    ctx.omSetRenderTargets(&.{null});

    // And the resources the steps bound, so none stays bound as an input
    // when its resource is written next: pixel textures (t0..t2) and the
    // buffer SRVs (t4..t7) of both stages.
    const no_views: [slots.max_textures]?*d3d11.ID3D11ShaderResourceView = @splat(null);
    ctx.psSetShaderResources(0, &no_views);
    const no_buffer_views: [4]?*d3d11.ID3D11ShaderResourceView = @splat(null);
    ctx.vsSetShaderResources(slots.buffer_srv_base + 1, &no_buffer_views);
    ctx.psSetShaderResources(slots.buffer_srv_base + 1, &no_buffer_views);
}

fn pixelAt(pixels: []const u8, width: usize, x: usize, y: usize) [4]u8 {
    return pixels[(y * width + x) * 4 ..][0..4].*;
}

fn expectPixel(want: [4]u8, got: [4]u8) !void {
    for (want, got) |w, g| {
        const d = if (w > g) w - g else g - w;
        if (d > 1) {
            std.debug.print("pixel mismatch want={any} got={any}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "d3d11 renderpass: clear colour reaches the target" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var target = try Target.init(.{ .device = device, .width = 8, .height = 4, .srgb = false });
    defer target.deinit();

    device.lockContext();
    defer device.unlockContext();

    const attachments = [_]Options.Attachment{.{
        .target = .{ .target = target },
        .clear_color = .{ 0, 0.5, 1, 1 },
    }};
    var pass = begin(.{ .attachments = &attachments });
    // No steps: the clear happens on completion.
    pass.complete();

    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);
    try std.testing.expectEqual(@as(usize, 8 * 4 * 4), pixels.len);
    // BGRA of (r=0, g=0.5, b=1, a=1).
    try expectPixel(.{ 255, 128, 0, 255 }, pixelAt(pixels, 8, 0, 0));
    try expectPixel(.{ 255, 128, 0, 255 }, pixelAt(pixels, 8, 7, 3));
}

test "d3d11 renderpass: bg_color pipeline fills the target" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var target = try Target.init(.{ .device = device, .width = 8, .height = 4, .srgb = false });
    defer target.deinit();

    const pipeline = try Pipeline.init(null, .{
        .device = device,
        .vertex = .full_screen_vs,
        .pixel = .bg_color_ps,
        .blending_enabled = false,
    });
    defer pipeline.deinit();

    var uniforms = try bufferpkg.Buffer(Uniforms).init(
        .{ .device = device, .role = .constant },
        1,
    );
    defer uniforms.deinit();

    device.lockContext();
    defer device.unlockContext();

    var u = std.mem.zeroes(Uniforms);
    u.bg_color = .{ 10, 20, 30, 255 };
    // Display P3 without linear blending is the identity path: no colour
    // space conversion, so the stored bytes equal the input.
    u.bools = .{ .cursor_wide = false, .use_display_p3 = true, .use_linear_blending = false };
    try uniforms.sync(&.{u});

    const attachments = [_]Options.Attachment{.{
        .target = .{ .target = target },
        // Proves the draw, not the clear, wrote the pixels.
        .clear_color = .{ 1, 1, 1, 1 },
    }};
    var pass = begin(.{ .attachments = &attachments });
    pass.step(.{
        .pipeline = pipeline,
        .uniforms = uniforms.buffer,
        .draw = .{ .type = .triangle, .vertex_count = 3 },
    });
    pass.complete();

    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);
    // BGRA of rgb(10, 20, 30).
    try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 8, 0, 0));
    try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 8, 7, 0));
    try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 8, 0, 3));
    try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 8, 7, 3));
}

test "d3d11 renderpass: structured buffers bind at t4 for the pixel stage" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var target = try Target.init(.{ .device = device, .width = 8, .height = 4, .srgb = false });
    defer target.deinit();

    const pipeline = try Pipeline.init(null, .{
        .device = device,
        .vertex = .full_screen_vs,
        .pixel = .cell_bg_ps,
        .blending_enabled = true,
    });
    defer pipeline.deinit();

    var uniforms = try bufferpkg.Buffer(Uniforms).init(
        .{ .device = device, .role = .constant },
        1,
    );
    defer uniforms.deinit();

    // Two 4x4 cells side by side: red, then blue.
    var bg_cells = try bufferpkg.Buffer([4]u8).initFill(
        .{ .device = device, .role = .structured },
        &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 } },
    );
    defer bg_cells.deinit();

    device.lockContext();
    defer device.unlockContext();

    var u = std.mem.zeroes(Uniforms);
    u.cell_size = .{ 4, 4 };
    u.grid_size = .{ 2, 1 };
    u.bools = .{ .cursor_wide = false, .use_display_p3 = true, .use_linear_blending = false };
    try uniforms.sync(&.{u});

    const attachments = [_]Options.Attachment{.{
        .target = .{ .target = target },
        .clear_color = .{ 0, 0, 0, 0 },
    }};
    var pass = begin(.{ .attachments = &attachments });
    pass.step(.{
        .pipeline = pipeline,
        .uniforms = uniforms.buffer,
        // buffers[0] is the (absent) vertex buffer; buffers[1] is bg_cells.
        .buffers = &.{ null, bg_cells.buffer },
        .draw = .{ .type = .triangle, .vertex_count = 3 },
    });
    pass.complete();

    const pixels = try target.readPixelsAlloc(alloc);
    defer alloc.free(pixels);
    // BGRA.
    try expectPixel(.{ 0, 0, 255, 255 }, pixelAt(pixels, 8, 1, 1));
    try expectPixel(.{ 255, 0, 0, 255 }, pixelAt(pixels, 8, 6, 2));
}

test "d3d11 renderpass: a post pipeline writes raw values to an sRGB target" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var target = try Target.init(.{ .device = device, .width = 4, .height = 2, .srgb = true });
    defer target.deinit();
    try std.testing.expect(target.texture.gamma_rtv != null);

    var uniforms = try bufferpkg.Buffer(Uniforms).init(
        .{ .device = device, .role = .constant },
        1,
    );
    defer uniforms.deinit();

    device.lockContext();
    defer device.unlockContext();

    var u = std.mem.zeroes(Uniforms);
    u.bg_color = .{ 10, 20, 30, 255 };
    u.bools = .{ .cursor_wide = false, .use_display_p3 = true, .use_linear_blending = false };
    try uniforms.sync(&.{u});

    for ([_]bool{ true, false }) |post| {
        const pipeline = try Pipeline.init(null, .{
            .device = device,
            .vertex = .full_screen_vs,
            .pixel = .bg_color_ps,
            .blending_enabled = false,
            .post = post,
        });
        defer pipeline.deinit();

        const attachments = [_]Options.Attachment{.{
            .target = .{ .target = target },
            .clear_color = .{ 1, 1, 1, 1 },
        }};
        var pass = begin(.{ .attachments = &attachments });
        pass.step(.{
            .pipeline = pipeline,
            .uniforms = uniforms.buffer,
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
        pass.complete();

        const pixels = try target.readPixelsAlloc(alloc);
        defer alloc.free(pixels);
        if (post) {
            // Stored as given, not encoded a second time.
            try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 4, 1, 1));
        } else {
            // The sRGB view encodes what the shader wrote (BGR of 10, 20, 30).
            try expectPixel(.{ 96, 79, 56, 255 }, pixelAt(pixels, 4, 1, 1));
        }
    }
}
