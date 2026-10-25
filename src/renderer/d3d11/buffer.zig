const std = @import("std");
const Allocator = std.mem.Allocator;

/// Options for initializing a buffer.
pub const Options = struct {
    /// What the buffer is bound as.
    kind: Kind = .vertex,

    pub const Kind = enum {
        /// Per-instance vertex data (IA vertex slot 0).
        vertex,
        /// Structured buffer read through an SRV.
        structured,
        /// Constant buffer.
        uniform,
    };
};

/// The raw native handle of a buffer, as passed to a render pass step.
/// This will be the `ID3D11Buffer` pointer.
pub const Handle = *anyopaque;

/// D3D11 data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc.
///
/// STUB: creation fails until the D3D11 device exists.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying native buffer.
        buffer: Handle,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            _ = opts;
            _ = len;
            return error.Unimplemented;
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            _ = opts;
            _ = data;
            return error.Unimplemented;
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        pub fn sync(self: *Self, data: []const T) !void {
            _ = self;
            _ = data;
            return error.Unimplemented;
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            _ = self;
            _ = lists;
            return error.Unimplemented;
        }
    };
}
