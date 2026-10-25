//! Wrapper for handling render pipelines.
//!
//! STUB: will hold the compiled HLSL shaders, input layout and blend state.
const Self = @This();

const std = @import("std");

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// HLSL source of the vertex function
    vertex_fn: [:0]const u8,
    /// HLSL source of the fragment function
    fragment_fn: [:0]const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

stride: usize,

blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = VertexAttributes;
    _ = opts;
    return error.Unimplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
