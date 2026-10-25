//! Wrapper for handling render passes.
//!
//! STUB: steps are ignored until the D3D11 pipeline binding exists.
const Self = @This();

const std = @import("std");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const bufferpkg = @import("buffer.zig");

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

/// Add a step to this render pass.
pub fn step(self: *Self, s: Step) void {
    _ = s;
    self.step_number += 1;
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
}
