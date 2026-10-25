//! ole32 bindings: OLE apartment setup (needed for clipboard and drag/drop).
const foundation = @import("foundation.zig");
const HRESULT = foundation.HRESULT;

pub extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;
