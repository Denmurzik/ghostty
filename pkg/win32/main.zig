pub const foundation = @import("foundation.zig");
pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3dcompiler = @import("d3dcompiler.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
