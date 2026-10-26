//! shell32 bindings (shell execute, notification icons, drag and drop). Filled by the tasks that first call them.

const foundation = @import("foundation.zig");
const com = @import("com.zig");

/// The result is an HINSTANCE-typed integer: a value above 32 is success, the rest are the `SE_ERR_*` codes.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?foundation.HWND,
    operation: ?[*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show: i32,
) callconv(.winapi) isize;

/// No application is associated with the file.
pub const SE_ERR_NOASSOC = 31;

// ITaskbarList3 (shobjidl_core.h)

pub const CLSID_TaskbarList = foundation.GUID.parse("56fdf344-fd6d-11d0-958a-006097c9a090");
pub const IID_ITaskbarList3 = foundation.GUID.parse("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf");

/// `TBPFLAG`.
pub const TBPF_NOPROGRESS = 0x0;
pub const TBPF_INDETERMINATE = 0x1;
pub const TBPF_NORMAL = 0x2;
pub const TBPF_ERROR = 0x4;
pub const TBPF_PAUSED = 0x8;

/// The inherited ITaskbarList and ITaskbarList2 slots come first, then
/// ITaskbarList3's own: 3 + 5 + 1 + 12 = 21 slots in all.
pub const ITaskbarList3 = extern struct {
    vtable: *const VTable,

    pub const iid = IID_ITaskbarList3;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        HrInit: *const fn (*ITaskbarList3) callconv(.winapi) foundation.HRESULT,
        AddTab: *const anyopaque,
        DeleteTab: *const anyopaque,
        ActivateTab: *const anyopaque,
        SetActiveAlt: *const anyopaque,
        MarkFullscreenWindow: *const anyopaque,
        SetProgressValue: *const fn (*ITaskbarList3, foundation.HWND, u64, u64) callconv(.winapi) foundation.HRESULT,
        SetProgressState: *const fn (*ITaskbarList3, foundation.HWND, u32) callconv(.winapi) foundation.HRESULT,
        RegisterTab: *const anyopaque,
        UnregisterTab: *const anyopaque,
        SetTabOrder: *const anyopaque,
        SetTabActive: *const anyopaque,
        ThumbBarAddButtons: *const anyopaque,
        ThumbBarUpdateButtons: *const anyopaque,
        ThumbBarSetImageList: *const anyopaque,
        SetOverlayIcon: *const anyopaque,
        SetThumbnailTooltip: *const anyopaque,
        SetThumbnailClip: *const anyopaque,
    };

    pub inline fn hrInit(self: *ITaskbarList3) foundation.Error!void {
        try foundation.check(self.vtable.HrInit(self));
    }

    pub inline fn setProgressValue(self: *ITaskbarList3, hwnd: foundation.HWND, completed: u64, total: u64) foundation.Error!void {
        try foundation.check(self.vtable.SetProgressValue(self, hwnd, completed, total));
    }

    /// `flags` is a `TBPF_*` value.
    pub inline fn setProgressState(self: *ITaskbarList3, hwnd: foundation.HWND, flags: u32) foundation.Error!void {
        try foundation.check(self.vtable.SetProgressState(self, hwnd, flags));
    }
};

test "win32 shell32: ITaskbarList3 slot count" {
    const std = @import("std");
    try std.testing.expectEqual(21 * @sizeOf(usize), @sizeOf(ITaskbarList3.VTable));
}

// Drag and drop (shellapi.h, shlobj_core.h)

/// Query the number of files with `index = 0xFFFFFFFF` and a null buffer;
/// otherwise the length (without the NUL) copied or, with a null buffer, needed.
pub extern "shell32" fn DragQueryFileW(drop: foundation.HANDLE, index: u32, file: ?[*]u16, cch: u32) callconv(.winapi) u32;

/// Header of the `CF_HDROP` data; the file list follows at `pFiles`.
pub const DROPFILES = extern struct {
    pFiles: u32,
    pt: foundation.POINT,
    fNC: foundation.BOOL,
    fWide: foundation.BOOL,
};

test "win32 shell32: DROPFILES size" {
    const std = @import("std");
    try std.testing.expectEqual(20, @sizeOf(DROPFILES));
}
