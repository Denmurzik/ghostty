const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d3d11 = win32.d3d11;
const Device = @import("Device.zig");

/// What a buffer is bound as.
pub const Role = enum {
    /// Per-instance vertex data (IA vertex slot 0).
    vertex,
    /// Structured buffer read through an SRV.
    structured,
    /// Constant buffer; the size is rounded up to 16 bytes.
    constant,
};

/// Options for initializing a buffer.
pub const Options = struct {
    device: *Device,
    role: Role,
};

/// The raw native handle of a buffer, as passed to a render pass step.
/// This is the `ID3D11Buffer` pointer.
pub const Handle = *anyopaque;

/// D3D11 data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc.
///
/// Buffers are `DYNAMIC` and written with `Map(WRITE_DISCARD)`, so a write
/// renames the buffer rather than stalling on in-flight draws. `sync` and
/// `syncFromArrayLists` use the immediate context: the caller holds the
/// device context lock (the frame does, between `drawFrameStart` and
/// `drawFrameEnd`). `init` and `deinit` are free-threaded.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying native buffer.
        buffer: *d3d11.ID3D11Buffer,

        /// Shader resource view of the whole buffer; only for the
        /// `structured` role.
        srv: ?*d3d11.ID3D11ShaderResourceView,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            return try create(opts, len, null);
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            return try create(opts, data.len, data);
        }

        pub fn deinit(self: Self) void {
            com.release(self.srv);
            com.release(self.buffer);
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        pub fn sync(self: *Self, data: []const T) !void {
            // Nothing to write, and mapping would discard the old contents.
            if (data.len == 0) return;

            try self.ensureCapacity(data.len);

            const dst = try self.mapDiscard();
            defer self.opts.device.context.unmap(self.buffer.asResource(), 0);
            @memcpy(dst[0..data.len], data);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;
            if (total_len == 0) return 0;

            try self.ensureCapacity(total_len);

            const dst = try self.mapDiscard();
            defer self.opts.device.context.unmap(self.buffer.asResource(), 0);

            var i: usize = 0;
            for (lists) |list| {
                @memcpy(dst[i..][0..list.items.len], list.items);
                i += list.items.len;
            }

            return total_len;
        }

        fn mapDiscard(self: *Self) ![*]T {
            const device = self.opts.device;
            device.assertContextLocked();
            const mapped = try device.context.map(self.buffer.asResource(), 0, .write_discard, 0);
            return @ptrCast(@alignCast(mapped.pData.?));
        }

        /// Grow the buffer (to twice the requested length) if `len` items
        /// don't fit. The new buffer starts empty; callers write all of it.
        fn ensureCapacity(self: *Self, len: usize) !void {
            if (len <= self.len) return;

            const new = try create(self.opts, len * 2, null);
            self.deinit();
            self.* = new;
        }

        fn create(opts: Options, len: usize, data: ?[]const T) !Self {
            const device = opts.device.device;

            const bytes = std.math.cast(u32, len * @sizeOf(T)) orelse return error.InvalidArgument;
            const byte_width = switch (opts.role) {
                // Constant buffers must be a multiple of 16 bytes.
                .constant => std.mem.alignForward(u32, bytes, 16),
                .vertex, .structured => bytes,
            };

            const desc: d3d11.BUFFER_DESC = .{
                .ByteWidth = byte_width,
                .Usage = .dynamic,
                .BindFlags = switch (opts.role) {
                    .vertex => .{ .vertex_buffer = true },
                    .structured => .{ .shader_resource = true },
                    .constant => .{ .constant_buffer = true },
                },
                .CPUAccessFlags = .{ .write = true },
                .MiscFlags = if (opts.role == .structured) d3d11.RESOURCE_MISC_BUFFER_STRUCTURED else 0,
                .StructureByteStride = if (opts.role == .structured) @sizeOf(T) else 0,
            };

            // Initial data must cover the whole (padded) buffer, so pad it
            // through a scratch copy when the role rounds the size up.
            var scratch: [256]u8 align(16) = undefined;
            var initial: d3d11.SUBRESOURCE_DATA = undefined;
            if (data) |d| {
                initial = .{
                    .pSysMem = d.ptr,
                    .SysMemPitch = 0,
                    .SysMemSlicePitch = 0,
                };
                if (byte_width != bytes) {
                    if (byte_width > scratch.len) return error.InvalidArgument;
                    @memset(&scratch, 0);
                    @memcpy(scratch[0..bytes], std.mem.sliceAsBytes(d));
                    initial.pSysMem = &scratch;
                }
            }

            const buffer = try device.createBuffer(&desc, if (data != null) &initial else null);
            errdefer com.release(buffer);

            const srv: ?*d3d11.ID3D11ShaderResourceView = if (opts.role == .structured)
                try device.createShaderResourceView(buffer.asResource(), &.{
                    .Format = .UNKNOWN,
                    .ViewDimension = .BUFFER,
                    .u = .{ .Buffer = .{
                        .FirstElement = 0,
                        .NumElements = @intCast(len),
                    } },
                })
            else
                null;

            return .{
                .buffer = buffer,
                .srv = srv,
                .opts = opts,
                .len = len,
            };
        }
    };
}

/// Copies a buffer into a CPU-readable staging copy and returns the mapped
/// bytes through `ReadBack`. Test helper.
const ReadBack = struct {
    staging: *d3d11.ID3D11Buffer,
    device: *Device,
    data: []const u8,

    fn begin(device: *Device, buffer: *d3d11.ID3D11Buffer, byte_width: u32) !ReadBack {
        const staging = try device.device.createBuffer(&.{
            .ByteWidth = byte_width,
            .Usage = .staging,
            .BindFlags = .{},
            .CPUAccessFlags = .{ .read = true },
            .MiscFlags = 0,
            .StructureByteStride = 0,
        }, null);
        errdefer com.release(staging);

        device.context.copyResource(staging.asResource(), buffer.asResource());
        const mapped = try device.context.map(staging.asResource(), 0, .read, 0);
        const ptr: [*]const u8 = @ptrCast(mapped.pData.?);
        return .{ .staging = staging, .device = device, .data = ptr[0..byte_width] };
    }

    fn end(self: ReadBack) void {
        self.device.context.unmap(self.staging.asResource(), 0);
        com.release(self.staging);
    }
};

test "d3d11 buffer: sync grows and preserves contents" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var buf = try Buffer(u32).init(.{ .device = device, .role = .structured }, 4);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 4), buf.len);
    try std.testing.expect(buf.srv != null);

    const input = [_]u32{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 };

    device.lockContext();
    defer device.unlockContext();

    try buf.sync(&input);
    try std.testing.expect(buf.len >= input.len);
    try std.testing.expect(buf.srv != null);

    const rb = try ReadBack.begin(device, buf.buffer, @intCast(buf.len * @sizeOf(u32)));
    defer rb.end();
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&input), rb.data[0 .. input.len * @sizeOf(u32)]);
}

test "d3d11 buffer: syncFromArrayLists concatenates the lists" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    var buf = try Buffer(u32).init(.{ .device = device, .role = .vertex }, 2);
    defer buf.deinit();
    try std.testing.expect(buf.srv == null);

    var a: std.ArrayListUnmanaged(u32) = .empty;
    defer a.deinit(alloc);
    var empty: std.ArrayListUnmanaged(u32) = .empty;
    defer empty.deinit(alloc);
    var b: std.ArrayListUnmanaged(u32) = .empty;
    defer b.deinit(alloc);
    try a.appendSlice(alloc, &.{ 1, 2, 3 });
    try b.appendSlice(alloc, &.{ 4, 5 });

    device.lockContext();
    defer device.unlockContext();

    const n = try buf.syncFromArrayLists(&.{ a, empty, b });
    try std.testing.expectEqual(@as(usize, 5), n);

    const rb = try ReadBack.begin(device, buf.buffer, @intCast(buf.len * @sizeOf(u32)));
    defer rb.end();
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]u32{ 1, 2, 3, 4, 5 }), rb.data[0 .. 5 * @sizeOf(u32)]);
}

test "d3d11 buffer: constant role rounds size to 16" {
    const alloc = std.testing.allocator;
    const device = try Device.init(alloc, .{ .driver = .warp });
    defer device.deinit(alloc);

    // 4 bytes of payload become a 16 byte constant buffer.
    var buf = try Buffer(u32).initFill(.{ .device = device, .role = .constant }, &.{0xAABBCCDD});
    defer buf.deinit();
    try std.testing.expect(buf.srv == null);

    const desc = buf.buffer.getDesc();
    try std.testing.expectEqual(@as(u32, 16), desc.ByteWidth);
    try std.testing.expect(desc.BindFlags.constant_buffer);

    device.lockContext();
    defer device.unlockContext();

    const rb = try ReadBack.begin(device, buf.buffer, 16);
    defer rb.end();
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, rb.data[0..4], .little));
    // The padding is zeroed.
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), rb.data[4..16]);
}
