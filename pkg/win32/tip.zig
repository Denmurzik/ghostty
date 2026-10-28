//! Touch keyboard bindings (owner: M5 Task 16): ITipInvocation (inputsw.h
//! private shell interface, stable since Windows 8) and IFrameworkInputPane
//! (shobjidl_core.h).
const std = @import("std");
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const RECT = foundation.RECT;

pub const CLSID_UIHostNoLaunch = foundation.GUID.parse("4ce576fa-83dc-4f88-951c-9d0782b4e376");
pub const IID_ITipInvocation = foundation.GUID.parse("37c994e7-432b-4834-a2f7-dce1f13b834b");
pub const CLSID_FrameworkInputPane = foundation.GUID.parse("d5120aa3-46ba-44c5-822d-ca8092c1fc72");
pub const IID_IFrameworkInputPane = foundation.GUID.parse("5752238b-24f0-495a-82f1-2fd593056796");

pub const CLSCTX_LOCAL_SERVER = 0x4;

/// winerror.h: Class not registered.
pub const REGDB_E_CLASSNOTREG: HRESULT = @bitCast(@as(u32, 0x80040154));

pub extern "user32" fn GetDesktopWindow() callconv(.winapi) ?HWND;

pub const ITipInvocation = extern struct {
    vtable: *const VTable,

    pub const iid = IID_ITipInvocation;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        Toggle: *const fn (*ITipInvocation, ?HWND) callconv(.winapi) HRESULT,
    };

    pub fn toggle(self: *ITipInvocation, hwnd: ?HWND) HRESULT {
        return self.vtable.Toggle(self, hwnd);
    }
};

pub const IFrameworkInputPane = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IFrameworkInputPane;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        Advise: *const fn (*IFrameworkInputPane, ?*anyopaque, ?*anyopaque, *u32) callconv(.winapi) HRESULT,
        AdviseWithHWND: *const fn (*IFrameworkInputPane, HWND, ?*anyopaque, *u32) callconv(.winapi) HRESULT,
        Unadvise: *const fn (*IFrameworkInputPane, u32) callconv(.winapi) HRESULT,
        Location: *const fn (*IFrameworkInputPane, *RECT) callconv(.winapi) HRESULT,
    };

    pub fn location(self: *IFrameworkInputPane, out: *RECT) HRESULT {
        return self.vtable.Location(self, out);
    }
};

test "win32 osk: tip vtable slots" {
    const ptr = @sizeOf(usize);
    try std.testing.expectEqual(4, @sizeOf(ITipInvocation.VTable) / ptr);
    try std.testing.expectEqual(3 * ptr, @offsetOf(ITipInvocation.VTable, "Toggle"));
    try std.testing.expectEqual(7, @sizeOf(IFrameworkInputPane.VTable) / ptr);
    try std.testing.expectEqual(6 * ptr, @offsetOf(IFrameworkInputPane.VTable, "Location"));
}
