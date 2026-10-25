//! COM core: IUnknown and generic helpers over any interface struct that
//! follows the SPEC section 4 pattern (`vtable` first field, `iid` decl).
const foundation = @import("foundation.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const Error = foundation.Error;

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("00000000-0000-0000-c000-000000000046");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

/// Drops one reference. Accepts `*T` or `?*T` for any COM interface `T`;
/// null is a no-op.
pub fn release(obj: anytype) void {
    switch (@typeInfo(@TypeOf(obj))) {
        .optional => if (obj) |o| release(o),
        .pointer => {
            const unknown: *IUnknown = @ptrCast(obj);
            _ = unknown.vtable.Release(unknown);
        },
        else => @compileError("com.release expects a COM interface pointer"),
    }
}

/// Queries `obj` for interface `T`. The returned pointer is a new reference
/// that the caller releases.
pub fn queryInterface(obj: anytype, comptime T: type) Error!*T {
    const unknown: *IUnknown = @ptrCast(obj);
    var out: ?*anyopaque = null;
    try foundation.check(unknown.vtable.QueryInterface(unknown, &T.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}
