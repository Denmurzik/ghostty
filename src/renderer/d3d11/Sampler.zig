//! Wrapper for handling samplers.
//!
//! STUB: creation fails until the D3D11 device exists.
const Self = @This();

const std = @import("std");

/// Options for initializing a sampler.
pub const Options = struct {
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,

    pub const Filter = enum { nearest, linear };
    pub const Wrap = enum { clamp_to_edge, repeat };
};

pub const Error = error{
    /// The D3D11 backend is not implemented yet.
    Unimplemented,
    /// A D3D11 API call failed.
    D3D11Failed,
};

/// Initialize a sampler
pub fn init(
    opts: Options,
) Error!Self {
    _ = opts;
    return error.Unimplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
