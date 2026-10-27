//! Shader set and CPU-side vertex/uniform types for the D3D11 renderer.
//!
//! The extern structs below are the CPU/GPU ABI and must stay identical to
//! `opengl/shaders.zig`. Their layout is mirrored by `shaders/hlsl`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const hlsl = @import("hlsl.zig");

const log = std.log.scoped(.d3d11);

/// This contains the state for the shaders used by the D3D11 renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: struct {
        bg_color: Pipeline,
        cell_bg: Pipeline,
        cell_text: Pipeline,
        image: Pipeline,
        bg_image: Pipeline,
    },

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    ///
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    /// Initialize our shader set.
    ///
    /// "custom_shaders" is an optional list of postprocess shaders (HLSL
    /// from `shadertoy.hlslFromSpv`) to run against the final drawable
    /// texture. One that fails to compile is logged and skipped so Ghostty
    /// still renders.
    pub fn init(
        alloc: Allocator,
        device: *Device,
        custom_shaders: []const [:0]const u8,
    ) !Shaders {
        const bg_color: Pipeline = try .init(null, .{
            .device = device,
            .vertex = .full_screen_vs,
            .pixel = .bg_color_ps,
            .blending_enabled = false,
        });
        errdefer bg_color.deinit();

        const cell_bg: Pipeline = try .init(null, .{
            .device = device,
            .vertex = .full_screen_vs,
            .pixel = .cell_bg_ps,
            .blending_enabled = true,
        });
        errdefer cell_bg.deinit();

        const cell_text: Pipeline = try .init(CellText, .{
            .device = device,
            .vertex = .cell_text_vs,
            .pixel = .cell_text_ps,
            .step_fn = .per_instance,
            .blending_enabled = true,
        });
        errdefer cell_text.deinit();

        const image: Pipeline = try .init(Image, .{
            .device = device,
            .vertex = .image_vs,
            .pixel = .image_ps,
            .step_fn = .per_instance,
            .blending_enabled = true,
        });
        errdefer image.deinit();

        const bg_image: Pipeline = try .init(BgImage, .{
            .device = device,
            .vertex = .bg_image_vs,
            .pixel = .bg_image_ps,
            .step_fn = .per_instance,
            .blending_enabled = true,
        });
        errdefer bg_image.deinit();

        const post_pipelines = try initPostPipelines(alloc, device, custom_shaders);
        errdefer deinitPostPipelines(alloc, post_pipelines);

        return .{
            .pipelines = .{
                .bg_color = bg_color,
                .cell_bg = cell_bg,
                .cell_text = cell_text,
                .image = image,
                .bg_image = bg_image,
            },
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        deinitPostPipelines(alloc, self.post_pipelines);

        inline for (@typeInfo(@TypeOf(self.pipelines)).@"struct".field_names) |name| {
            @field(self.pipelines, name).deinit();
        }
    }
};

/// Entry point spirv-cross gives the HLSL pixel shader.
const custom_shader_entry = "main";

/// A post pipeline per custom shader: the full screen triangle with the
/// user's pixel shader. Like the Metal and OpenGL backends, one that fails
/// to compile or to create drops all custom shaders (logging which), so
/// the terminal renders without any rather than with a partial chain.
fn initPostPipelines(
    alloc: Allocator,
    device: *Device,
    custom_shaders: []const [:0]const u8,
) ![]const Pipeline {
    if (custom_shaders.len == 0) return &.{};

    var pipelines: std.ArrayListUnmanaged(Pipeline) = try .initCapacity(alloc, custom_shaders.len);
    errdefer {
        for (pipelines.items) |p| p.deinit();
        pipelines.deinit(alloc);
    }

    for (custom_shaders, 0..) |src, i| {
        const code = hlsl.compileSource(src, custom_shader_entry, "ps_5_0") catch |err| {
            log.warn("custom shader {d} failed to compile, custom shaders disabled: {}", .{ i, err });
            return dropPostPipelines(alloc, &pipelines);
        };
        const pipeline: Pipeline = Pipeline.init(null, .{
            .device = device,
            .vertex = .full_screen_vs,
            .pixel_bytecode = code,
            .blending_enabled = true,
        }) catch |err| {
            log.warn("custom shader {d} pipeline failed, custom shaders disabled: {}", .{ i, err });
            return dropPostPipelines(alloc, &pipelines);
        };
        pipelines.appendAssumeCapacity(pipeline);
    }

    return try pipelines.toOwnedSlice(alloc);
}

fn dropPostPipelines(alloc: Allocator, pipelines: *std.ArrayListUnmanaged(Pipeline)) []const Pipeline {
    for (pipelines.items) |p| p.deinit();
    pipelines.deinit(alloc);
    return &.{};
}

fn deinitPostPipelines(alloc: Allocator, pipelines: []const Pipeline) void {
    if (pipelines.len == 0) return;
    for (pipelines) |p| p.deinit();
    alloc.free(pipelines);
}

/// Byte offset of every `Uniforms` field in the HLSL `Globals` cbuffer, as
/// given by the `packoffset`s in `shaders/hlsl/common.hlsli` (register
/// `c<n>` starts at byte 16 * n, `.x/.y/.z/.w` add 0/4/8/12).
pub const hlsl_uniform_offsets = [_]struct { []const u8, usize }{
    .{ "projection_matrix", 0 }, // c0
    .{ "screen_size", 64 }, // c4.x
    .{ "cell_size", 72 }, // c4.z
    .{ "grid_size", 80 }, // c5.x
    .{ "grid_padding", 96 }, // c6
    .{ "padding_extend", 112 }, // c7.x
    .{ "min_contrast", 116 }, // c7.y
    .{ "cursor_pos", 120 }, // c7.z
    .{ "cursor_color", 124 }, // c7.w
    .{ "bg_color", 128 }, // c8.x
    .{ "bools", 132 }, // c8.y
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: [4][4]f32 align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    // test {
    //     // Minimizing the size of this struct is important,
    //     // so we test it in order to be aware of any changes.
    //     try std.testing.expectEqual(32, @sizeOf(CellText));
    // }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

test "d3d11 shaders: Uniforms offsets match the HLSL cbuffer" {
    const fields = @typeInfo(Uniforms).@"struct".field_names;
    try std.testing.expectEqual(fields.len, hlsl_uniform_offsets.len);

    inline for (fields) |name| {
        const found = for (hlsl_uniform_offsets) |entry| {
            if (std.mem.eql(u8, entry[0], name)) break entry[1];
        } else return error.MissingHlslOffset;
        try std.testing.expectEqual(@offsetOf(Uniforms, name), found);
    }

    // The cbuffer is 9 registers.
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Uniforms));
}

test "d3d11 shaders: vertex layouts match the HLSL inputs" {
    const dxgi = @import("win32").dxgi;
    const Expected = struct { fmt: dxgi.Format, offset: u32 };

    const image = comptime Pipeline.inputElements(Image, .per_instance);
    const image_want = [_]Expected{
        .{ .fmt = .R32G32_FLOAT, .offset = 0 },
        .{ .fmt = .R32G32_FLOAT, .offset = 8 },
        .{ .fmt = .R32G32B32A32_FLOAT, .offset = 16 },
        .{ .fmt = .R32G32_FLOAT, .offset = 32 },
    };
    try std.testing.expectEqual(image_want.len, image.len);
    for (image, image_want, 0..) |e, want, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), e.SemanticIndex);
        try std.testing.expectEqual(want.fmt, e.Format);
        try std.testing.expectEqual(want.offset, e.AlignedByteOffset);
    }
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Image));

    // `info` is a packed u8 and must reflect as R8_UINT (DXGI_FORMAT 62).
    const bg_image = comptime Pipeline.inputElements(BgImage, .per_instance);
    try std.testing.expectEqual(@as(usize, 2), bg_image.len);
    try std.testing.expectEqual(dxgi.Format.R32_FLOAT, bg_image[0].Format);
    try std.testing.expectEqual(@as(u32, 0), bg_image[0].AlignedByteOffset);
    try std.testing.expectEqual(@as(u32, 62), @backingInt(bg_image[1].Format));
    try std.testing.expectEqual(@as(u32, 4), bg_image[1].AlignedByteOffset);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BgImage));
}

test "d3d11 shaders: all builtin pipelines initialise on WARP" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var shaders: Shaders = try .init(alloc, device, &.{});
    defer shaders.deinit(alloc);

    try std.testing.expect(shaders.pipelines.bg_color.input_layout == null);
    try std.testing.expect(!shaders.pipelines.bg_color.blending_enabled);
    try std.testing.expect(shaders.pipelines.cell_bg.input_layout == null);
    try std.testing.expect(shaders.pipelines.cell_bg.blending_enabled);
    try std.testing.expectEqual(@as(usize, 32), shaders.pipelines.cell_text.stride);
    try std.testing.expectEqual(@as(usize, 48), shaders.pipelines.image.stride);
    try std.testing.expectEqual(@as(usize, 8), shaders.pipelines.bg_image.stride);
    try std.testing.expectEqual(@as(usize, 0), shaders.post_pipelines.len);
}

test "d3d11 custom shader: one failing shader drops all custom shaders" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    const good = "float4 main() : SV_Target0 { return 0; } // drop-all-good";
    var shaders: Shaders = try .init(alloc, device, &.{ good, "not hlsl {" });
    defer shaders.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), shaders.post_pipelines.len);
}
