//! Wrapper for handling render pipelines.
//!
//! A pipeline is a vertex shader, a pixel shader, an input layout reflected
//! from the vertex attribute struct, and the blend and rasterizer state
//! every step of the pipeline draws with.
const Self = @This();

const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const Device = @import("Device.zig");
const hlsl = @import("hlsl.zig");
const shaders = @import("shaders.zig");

/// Options for initializing a render pipeline.
pub const Options = struct {
    device: *Device,

    /// The builtin vertex function.
    vertex: hlsl.Entry,
    /// The builtin pixel function.
    pixel: hlsl.Entry = .bg_color_ps,
    /// Compiled pixel shader bytecode that replaces `pixel`, for custom
    /// shaders. The bytes must outlive the call only.
    pixel_bytecode: ?[]const u8 = null,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    /// A custom shader pass: reads and writes raw (gamma space) values
    /// like on macOS, so `RenderPass` binds the gamma view of its target.
    post: bool = false,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

/// The device the pipeline was created on.
device: *Device,

vertex_shader: *d3d11.ID3D11VertexShader,
pixel_shader: *d3d11.ID3D11PixelShader,

/// Null when the vertex shader reads no attributes (`VertexAttributes`
/// was null), e.g. the full screen triangle.
input_layout: ?*d3d11.ID3D11InputLayout,

blend_state: *d3d11.ID3D11BlendState,
rasterizer_state: *d3d11.ID3D11RasterizerState,

/// Size in bytes of one vertex/instance, or 0 without attributes.
stride: usize,

blending_enabled: bool,

/// See `Options.post`.
post: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    const device = opts.device.device;

    const vs_code = try hlsl.bytecode(opts.vertex);
    const ps_code = opts.pixel_bytecode orelse try hlsl.bytecode(opts.pixel);

    const vertex_shader = try device.createVertexShader(vs_code);
    errdefer com.release(vertex_shader);

    const pixel_shader = try device.createPixelShader(ps_code);
    errdefer com.release(pixel_shader);

    const input_layout: ?*d3d11.ID3D11InputLayout = if (VertexAttributes) |VA| layout: {
        const elements = inputElements(VA, opts.step_fn);
        break :layout try device.createInputLayout(&elements, vs_code);
    } else null;
    errdefer com.release(input_layout);

    const blend_state = try device.createBlendState(&blendDesc(opts.blending_enabled));
    errdefer com.release(blend_state);

    const rasterizer_state = try device.createRasterizerState(&.{
        .FillMode = .SOLID,
        // Fan-out quads and the full screen triangle have no winding
        // guarantee we care about.
        .CullMode = .NONE,
        .FrontCounterClockwise = 0,
        .DepthBias = 0,
        .DepthBiasClamp = 0,
        .SlopeScaledDepthBias = 0,
        .DepthClipEnable = 1,
        .ScissorEnable = 0,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
    });
    errdefer com.release(rasterizer_state);

    return .{
        .device = opts.device,
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .input_layout = input_layout,
        .blend_state = blend_state,
        .rasterizer_state = rasterizer_state,
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .blending_enabled = opts.blending_enabled,
        .post = opts.post,
    };
}

pub fn deinit(self: *const Self) void {
    com.release(self.rasterizer_state);
    com.release(self.blend_state);
    com.release(self.input_layout);
    com.release(self.pixel_shader);
    com.release(self.vertex_shader);
}

/// Premultiplied alpha, the same as `glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA)`
/// on both the colour and alpha channels.
fn blendDesc(enabled: bool) d3d11.BLEND_DESC {
    const target: d3d11.RENDER_TARGET_BLEND_DESC = .{
        .BlendEnable = @intFromBool(enabled),
        .SrcBlend = .ONE,
        .DestBlend = .INV_SRC_ALPHA,
        .BlendOp = .ADD,
        .SrcBlendAlpha = .ONE,
        .DestBlendAlpha = .INV_SRC_ALPHA,
        .BlendOpAlpha = .ADD,
        .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE_ALL,
    };
    return .{
        .AlphaToCoverageEnable = 0,
        .IndependentBlendEnable = 0,
        .RenderTarget = @splat(target),
    };
}

/// The input layout of `T`: field `i` is semantic `TEXCOORD<i>` in input
/// slot 0, at the field's offset. Integer fields use `*_UINT`/`*_SINT`
/// formats, so the HLSL side declares them as `uint`/`int` vectors.
pub fn inputElements(
    comptime T: type,
    step_fn: Options.StepFunction,
) [@typeInfo(T).@"struct".field_names.len]d3d11.INPUT_ELEMENT_DESC {
    const info = @typeInfo(T).@"struct";
    var result: [info.field_names.len]d3d11.INPUT_ELEMENT_DESC = undefined;

    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        const FT = switch (@typeInfo(field_type)) {
            .@"struct" => |s| s.backing_integer.?,
            .@"enum" => |e| e.tag_type,
            else => field_type,
        };

        const size, const IT = switch (@typeInfo(FT)) {
            .array => |a| .{ a.len, a.child },
            else => .{ 1, FT },
        };

        result[i] = .{
            .SemanticName = "TEXCOORD",
            .SemanticIndex = i,
            .Format = attributeFormat(IT, size),
            .InputSlot = 0,
            .AlignedByteOffset = @offsetOf(T, field_name),
            .InputSlotClass = switch (step_fn) {
                .per_vertex => .PER_VERTEX_DATA,
                .per_instance, .constant => .PER_INSTANCE_DATA,
            },
            // Step rate 0 keeps the first element for every instance.
            .InstanceDataStepRate = switch (step_fn) {
                .per_vertex => 0,
                .per_instance => 1,
                .constant => 0,
            },
        };
    }

    return result;
}

// DXGI_FORMAT values the shared `dxgi.Format` enum does not name.
fn fmt(comptime v: u32) dxgi.Format {
    return @fromBackingInt(@intCast(v));
}

fn attributeFormat(comptime T: type, comptime size: usize) dxgi.Format {
    return switch (T) {
        u8 => switch (size) {
            1 => fmt(62), // R8_UINT
            2 => fmt(50), // R8G8_UINT
            4 => fmt(30), // R8G8B8A8_UINT
            else => unsupported(T, size),
        },
        i8 => switch (size) {
            1 => fmt(64), // R8_SINT
            2 => fmt(52), // R8G8_SINT
            4 => fmt(32), // R8G8B8A8_SINT
            else => unsupported(T, size),
        },
        u16 => switch (size) {
            1 => fmt(57), // R16_UINT
            2 => .R16G16_UINT,
            4 => fmt(12), // R16G16B16A16_UINT
            else => unsupported(T, size),
        },
        i16 => switch (size) {
            1 => fmt(59), // R16_SINT
            2 => fmt(38), // R16G16_SINT
            4 => fmt(14), // R16G16B16A16_SINT
            else => unsupported(T, size),
        },
        u32 => switch (size) {
            1 => .R32_UINT,
            2 => .R32G32_UINT,
            3 => fmt(7), // R32G32B32_UINT
            4 => fmt(3), // R32G32B32A32_UINT
            else => unsupported(T, size),
        },
        i32 => switch (size) {
            1 => fmt(43), // R32_SINT
            2 => fmt(18), // R32G32_SINT
            3 => fmt(8), // R32G32B32_SINT
            4 => fmt(4), // R32G32B32A32_SINT
            else => unsupported(T, size),
        },
        f16 => switch (size) {
            1 => fmt(54), // R16_FLOAT
            2 => fmt(34), // R16G16_FLOAT
            4 => .R16G16B16A16_FLOAT,
            else => unsupported(T, size),
        },
        f32 => switch (size) {
            1 => .R32_FLOAT,
            2 => .R32G32_FLOAT,
            3 => fmt(6), // R32G32B32_FLOAT
            4 => .R32G32B32A32_FLOAT,
            else => unsupported(T, size),
        },
        else => unsupported(T, size),
    };
}

fn unsupported(comptime T: type, comptime size: usize) noreturn {
    @compileError("unsupported vertex attribute " ++ @typeName(T) ++ " x" ++ std.fmt.comptimePrint("{d}", .{size}));
}

test "d3d11 pipeline: input layout reflects CellText" {
    const elements = comptime inputElements(shaders.CellText, .per_instance);
    try std.testing.expectEqual(@as(usize, 7), elements.len);

    const expected = [_]struct { fmt: dxgi.Format, offset: u32 }{
        .{ .fmt = .R32G32_UINT, .offset = 0 },
        .{ .fmt = .R32G32_UINT, .offset = 8 },
        .{ .fmt = fmt(38), .offset = 16 }, // R16G16_SINT
        .{ .fmt = .R16G16_UINT, .offset = 20 },
        .{ .fmt = fmt(30), .offset = 24 }, // R8G8B8A8_UINT
        .{ .fmt = fmt(62), .offset = 28 }, // R8_UINT
        .{ .fmt = fmt(62), .offset = 29 }, // R8_UINT
    };
    for (elements, expected, 0..) |e, want, i| {
        try std.testing.expectEqualStrings("TEXCOORD", std.mem.span(e.SemanticName));
        try std.testing.expectEqual(@as(u32, @intCast(i)), e.SemanticIndex);
        try std.testing.expectEqual(want.fmt, e.Format);
        try std.testing.expectEqual(want.offset, e.AlignedByteOffset);
        try std.testing.expectEqual(@as(u32, 0), e.InputSlot);
        try std.testing.expectEqual(d3d11.INPUT_CLASSIFICATION.PER_INSTANCE_DATA, e.InputSlotClass);
        try std.testing.expectEqual(@as(u32, 1), e.InstanceDataStepRate);
    }
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(shaders.CellText));

    // The reflected layout is accepted against the real vertex shader.
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    const pipeline = try init(shaders.CellText, .{
        .device = device,
        .vertex = .cell_text_vs,
        .pixel = .cell_text_ps,
        .step_fn = .per_instance,
    });
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 32), pipeline.stride);
    try std.testing.expect(pipeline.input_layout != null);
}

test "d3d11 pipeline: per-vertex and constant step classes" {
    const Probe = extern struct { pos: [2]f32 };
    const per_vertex = comptime inputElements(Probe, .per_vertex);
    try std.testing.expectEqual(d3d11.INPUT_CLASSIFICATION.PER_VERTEX_DATA, per_vertex[0].InputSlotClass);
    try std.testing.expectEqual(@as(u32, 0), per_vertex[0].InstanceDataStepRate);
    try std.testing.expectEqual(dxgi.Format.R32G32_FLOAT, per_vertex[0].Format);

    const constant = comptime inputElements(Probe, .constant);
    try std.testing.expectEqual(d3d11.INPUT_CLASSIFICATION.PER_INSTANCE_DATA, constant[0].InputSlotClass);
    try std.testing.expectEqual(@as(u32, 0), constant[0].InstanceDataStepRate);
}

test "d3d11 pipeline: no attributes means no input layout" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    const pipeline = try init(null, .{
        .device = device,
        .vertex = .full_screen_vs,
        .pixel = .bg_color_ps,
        .blending_enabled = false,
    });
    defer pipeline.deinit();
    try std.testing.expect(pipeline.input_layout == null);
    try std.testing.expectEqual(@as(usize, 0), pipeline.stride);
}
