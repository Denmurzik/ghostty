//! Represents a render target.
//!
//! STUB: will be a `B8G8R8A8_TYPELESS` texture with render target and
//! shader resource views.
const Self = @This();

const std = @import("std");

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
};

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    _ = opts;
    return error.Unimplemented;
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}
