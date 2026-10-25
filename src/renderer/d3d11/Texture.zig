//! Wrapper for handling textures.
//!
//! STUB: creation fails until the D3D11 device exists.
const Self = @This();

const std = @import("std");

/// Options for initializing a texture.
pub const Options = struct {
    format: Format,

    pub const Format = enum {
        r8_unorm,
        r8g8b8a8_unorm,
        r8g8b8a8_unorm_srgb,
        b8g8r8a8_unorm,
        b8g8r8a8_unorm_srgb,
    };
};

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

pub const Error = error{
    /// The D3D11 backend is not implemented yet.
    Unimplemented,
    /// A D3D11 API call failed.
    D3D11Failed,
};

/// Initialize a texture
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    _ = opts;
    _ = width;
    _ = height;
    _ = data;
    return error.Unimplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    _ = self;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = data;
    return error.Unimplemented;
}
