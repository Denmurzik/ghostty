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

// Drag and drop (oleidl.h, objidl.h, objbase.h)

const com = @import("com.zig");
const HWND = foundation.HWND;

pub extern "ole32" fn RegisterDragDrop(HWND, *IDropTarget) callconv(.winapi) HRESULT;
pub extern "ole32" fn RevokeDragDrop(HWND) callconv(.winapi) HRESULT;
pub extern "ole32" fn ReleaseStgMedium(*STGMEDIUM) callconv(.winapi) void;

pub const CF_HDROP = 15;
pub const TYMED_HGLOBAL = 1;
pub const DVASPECT_CONTENT = 1;
pub const DROPEFFECT_NONE = 0;
pub const DROPEFFECT_COPY = 1;

pub const DV_E_FORMATETC: HRESULT = @bitCast(@as(u32, 0x80040064));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const IID_IUnknown = com.IUnknown.iid;
pub const IID_IDropTarget = foundation.GUID.parse("00000122-0000-0000-c000-000000000046");
pub const IID_IDataObject = foundation.GUID.parse("0000010e-0000-0000-c000-000000000046");

pub const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque = null,
    dwAspect: u32 = DVASPECT_CONTENT,
    lindex: i32 = -1,
    tymed: u32 = TYMED_HGLOBAL,
};

/// The `u` union is only ever read as an `HGLOBAL` (`TYMED_HGLOBAL`).
pub const STGMEDIUM = extern struct {
    tymed: u32 = 0,
    hGlobal: ?*anyopaque = null,
    pUnkForRelease: ?*com.IUnknown = null,
};

/// 3 IUnknown slots + GetData, GetDataHere, QueryGetData,
/// GetCanonicalFormatEtc, SetData, EnumFormatEtc, DAdvise, DUnadvise and
/// EnumDAdvise = 12 slots.
pub const IDataObject = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IDataObject;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        GetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*IDataObject, *const FORMATETC) callconv(.winapi) HRESULT,
        GetCanonicalFormatEtc: *const anyopaque,
        SetData: *const anyopaque,
        EnumFormatEtc: *const anyopaque,
        DAdvise: *const anyopaque,
        DUnadvise: *const anyopaque,
        EnumDAdvise: *const anyopaque,
    };

    pub inline fn getData(self: *IDataObject, fmt: *const FORMATETC, medium: *STGMEDIUM) HRESULT {
        return self.vtable.GetData(self, fmt, medium);
    }

    pub inline fn queryGetData(self: *IDataObject, fmt: *const FORMATETC) HRESULT {
        return self.vtable.QueryGetData(self, fmt);
    }
};

/// 3 IUnknown slots + DragEnter, DragOver, DragLeave and Drop = 7 slots.
/// Implemented by the application (`apprt/win32/drop.zig`); `pt` is in
/// screen coordinates.
pub const IDropTarget = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IDropTarget;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        DragEnter: *const fn (*IDropTarget, ?*IDataObject, key_state: u32, pt: foundation.POINT, effect: *u32) callconv(.winapi) HRESULT,
        DragOver: *const fn (*IDropTarget, key_state: u32, pt: foundation.POINT, effect: *u32) callconv(.winapi) HRESULT,
        DragLeave: *const fn (*IDropTarget) callconv(.winapi) HRESULT,
        Drop: *const fn (*IDropTarget, ?*IDataObject, key_state: u32, pt: foundation.POINT, effect: *u32) callconv(.winapi) HRESULT,
    };
};

test "win32 ole32: IDropTarget and IDataObject slot counts" {
    const std = @import("std");
    try std.testing.expectEqual(7 * @sizeOf(usize), @sizeOf(IDropTarget.VTable));
    try std.testing.expectEqual(12 * @sizeOf(usize), @sizeOf(IDataObject.VTable));
    try std.testing.expectEqual(32, @sizeOf(FORMATETC));
}

// COM apartments (threads other than the UI thread)

pub const COINIT_APARTMENTTHREADED = 0x2;

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
/// Releases memory allocated by the shell or COM.
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;

// Drag source (oleidl.h)

pub const DROPEFFECT_MOVE = 2;
pub const DROPEFFECT_LINK = 4;

pub const DRAGDROP_S_DROP: HRESULT = 0x00040100;
pub const DRAGDROP_S_CANCEL: HRESULT = 0x00040101;
pub const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = 0x00040102;

pub const IID_IDropSource = foundation.GUID.parse("00000121-0000-0000-c000-000000000046");

/// Runs the modal drag loop of `data` until it is dropped or cancelled; the
/// result is `DRAGDROP_S_DROP` or `DRAGDROP_S_CANCEL`. `effect` receives
/// what the target did.
pub extern "ole32" fn DoDragDrop(
    data: *IDataObject,
    source: *IDropSource,
    ok_effects: u32,
    effect: *u32,
) callconv(.winapi) HRESULT;

/// 3 IUnknown slots + QueryContinueDrag and GiveFeedback = 5 slots.
/// Implemented by the application (`apprt/win32/proxy_icon.zig`).
pub const IDropSource = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IDropSource;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        QueryContinueDrag: *const fn (*IDropSource, escape_pressed: foundation.BOOL, key_state: u32) callconv(.winapi) HRESULT,
        GiveFeedback: *const fn (*IDropSource, effect: u32) callconv(.winapi) HRESULT,
    };
};

test "win32 ole32: IDropSource slot count" {
    const std = @import("std");
    try std.testing.expectEqual(5 * @sizeOf(usize), @sizeOf(IDropSource.VTable));
}
