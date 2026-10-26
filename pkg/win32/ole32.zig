//! ole32 bindings: OLE apartment setup (needed for clipboard and drag/drop).
const foundation = @import("foundation.zig");
const HRESULT = foundation.HRESULT;

pub extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;

pub const CLSCTX_INPROC_SERVER = 0x1;

/// `out` receives a new reference to the interface `riid`.
pub extern "ole32" fn CoCreateInstance(
    clsid: *const foundation.GUID,
    outer: ?*anyopaque,
    context: u32,
    riid: *const foundation.GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
