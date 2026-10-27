//! shell32 bindings (shell execute, notification icons, drag and drop). Filled by the tasks that first call them.

const std = @import("std");
const foundation = @import("foundation.zig");
const user32 = @import("user32.zig");
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
    try std.testing.expectEqual(20, @sizeOf(DROPFILES));
}

// Notification area (shellapi.h)

/// `Shell_NotifyIconW` message.
pub const NIM_ADD = 0x0;
pub const NIM_MODIFY = 0x1;
pub const NIM_DELETE = 0x2;
pub const NIM_SETFOCUS = 0x3;
pub const NIM_SETVERSION = 0x4;

/// `NOTIFYICONDATAW.uFlags`.
pub const NIF_MESSAGE = 0x1;
pub const NIF_ICON = 0x2;
pub const NIF_TIP = 0x4;
pub const NIF_STATE = 0x8;
pub const NIF_INFO = 0x10;
pub const NIF_GUID = 0x20;
pub const NIF_REALTIME = 0x40;
/// With version 4 the standard tooltip is only shown when this is set.
pub const NIF_SHOWTIP = 0x80;

/// `NOTIFYICONDATAW.uVersion`: the callback gets the event in `LOWORD(lParam)`,
/// the icon id in `HIWORD(lParam)` and the anchor point in `wParam`.
pub const NOTIFYICON_VERSION_4 = 4;

/// Version 4 events (`WM_USER + n`): selection by mouse or by keyboard.
pub const NIN_SELECT = 0x400;
pub const NINF_KEY = 0x1;
pub const NIN_KEYSELECT = NIN_SELECT | NINF_KEY;

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?foundation.HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: ?user32.HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    /// A union with `uTimeout` in the header.
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: foundation.GUID = std.mem.zeroes(foundation.GUID),
    hBalloonIcon: ?user32.HICON = null,
};

/// `message` is a `NIM_*` value. Returns TRUE on success.
pub extern "shell32" fn Shell_NotifyIconW(message: u32, data: *NOTIFYICONDATAW) callconv(.winapi) foundation.BOOL;

// Sizes from a throwaway `zig cc -target x86_64-windows-msvc` program against
// Windows SDK 10.0.26100 headers (sizeof and offsetof of NOTIFYICONDATAW).
test "win32 shell32: NOTIFYICONDATAW layout" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(976, @sizeOf(NOTIFYICONDATAW));
    try std.testing.expectEqual(8, @offsetOf(NOTIFYICONDATAW, "hWnd"));
    try std.testing.expectEqual(16, @offsetOf(NOTIFYICONDATAW, "uID"));
    try std.testing.expectEqual(24, @offsetOf(NOTIFYICONDATAW, "uCallbackMessage"));
    try std.testing.expectEqual(32, @offsetOf(NOTIFYICONDATAW, "hIcon"));
    try std.testing.expectEqual(40, @offsetOf(NOTIFYICONDATAW, "szTip"));
    try std.testing.expectEqual(296, @offsetOf(NOTIFYICONDATAW, "dwState"));
    try std.testing.expectEqual(304, @offsetOf(NOTIFYICONDATAW, "szInfo"));
    try std.testing.expectEqual(816, @offsetOf(NOTIFYICONDATAW, "uVersion"));
    try std.testing.expectEqual(820, @offsetOf(NOTIFYICONDATAW, "szInfoTitle"));
    try std.testing.expectEqual(948, @offsetOf(NOTIFYICONDATAW, "dwInfoFlags"));
    try std.testing.expectEqual(952, @offsetOf(NOTIFYICONDATAW, "guidItem"));
    try std.testing.expectEqual(968, @offsetOf(NOTIFYICONDATAW, "hBalloonIcon"));
}

// ShellExecuteEx, AppUserModelID, reveal in Explorer (shellapi.h, shlobj_core.h)

pub const SEE_MASK_NOCLOSEPROCESS = 0x00000040;
pub const SEE_MASK_NOASYNC = 0x00000100;
pub const SEE_MASK_FLAG_NO_UI = 0x00000400;

pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: ?foundation.HWND = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?*anyopaque = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?*anyopaque = null,
    dwHotKey: u32 = 0,
    /// A union with `hMonitor` in the header.
    hIcon: ?*anyopaque = null,
    hProcess: ?foundation.HANDLE = null,
};

/// Returns TRUE on success; on failure `GetLastError` has the reason.
pub extern "shell32" fn ShellExecuteExW(*SHELLEXECUTEINFOW) callconv(.winapi) foundation.BOOL;
pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(app_id: [*:0]const u16) callconv(.winapi) foundation.HRESULT;

/// The returned `ITEMIDLIST` is released with `ILFree`.
pub extern "shell32" fn ILCreateFromPathW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
pub extern "shell32" fn ILFree(pidl: ?*anyopaque) callconv(.winapi) void;
/// With `cidl = 0` the item `pidl_folder` names is opened in its parent folder, selected.
pub extern "shell32" fn SHOpenFolderAndSelectItems(
    pidl_folder: *anyopaque,
    cidl: u32,
    apidl: ?[*]const *anyopaque,
    flags: u32,
) callconv(.winapi) foundation.HRESULT;
