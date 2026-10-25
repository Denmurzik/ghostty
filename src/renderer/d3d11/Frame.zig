//! Wrapper for handling frames.
//!
//! STUB: will submit the frame and present the target.
const Self = @This();

const std = @import("std");

const Renderer = @import("../generic.zig").Renderer(D3D11);
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;
    _ = renderer;
    _ = target;
    return error.Unimplemented;
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    self.renderer.frameCompleted(.unhealthy);
}
