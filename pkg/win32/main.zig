pub const foundation = @import("foundation.zig");
pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3dcompiler = @import("d3dcompiler.zig");
pub const user32 = @import("user32.zig");
pub const kernel32 = @import("kernel32.zig");
pub const imm32 = @import("imm32.zig");
pub const dwmapi = @import("dwmapi.zig");
pub const gdi32 = @import("gdi32.zig");
pub const ole32 = @import("ole32.zig");
pub const advapi32 = @import("advapi32.zig");
pub const shell32 = @import("shell32.zig");
pub const comctl32 = @import("comctl32.zig");
pub const uxtheme = @import("uxtheme.zig");
pub const winmm = @import("winmm.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
