//! gdi32 bindings (only what window class setup needs).
const foundation = @import("foundation.zig");
const HANDLE = foundation.HANDLE;

pub extern "gdi32" fn GetStockObject(index: i32) callconv(.winapi) ?HANDLE;

pub const WHITE_BRUSH = 0;
pub const BLACK_BRUSH = 4;
pub const NULL_BRUSH = 5;
