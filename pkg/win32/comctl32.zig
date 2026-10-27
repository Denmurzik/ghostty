//! comctl32 bindings (window subclassing, task dialogs). Filled by the tasks that first call them.

const std = @import("std");
const foundation = @import("foundation.zig");
const kernel32 = @import("kernel32.zig");

const HRESULT = foundation.HRESULT;
const HWND = foundation.HWND;
const HINSTANCE = foundation.HINSTANCE;
const BOOL = foundation.BOOL;

pub const IDOK = 1;
pub const IDCANCEL = 2;

pub const ICC_STANDARD_CLASSES = 0x00004000;
/// Includes the tooltip class (`TOOLTIPS_CLASSW`).
pub const ICC_WIN95_CLASSES = 0x000000FF;

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32,
    dwICC: u32,
};

pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;

pub const TDF_ENABLE_HYPERLINKS = 0x0001;
pub const TDF_ALLOW_DIALOG_CANCELLATION = 0x0008;
pub const TDF_USE_COMMAND_LINKS = 0x0010;
pub const TDF_POSITION_RELATIVE_TO_WINDOW = 0x1000;

pub const TDCBF_OK_BUTTON = 0x0001;
pub const TDCBF_YES_BUTTON = 0x0002;
pub const TDCBF_NO_BUTTON = 0x0004;
pub const TDCBF_CANCEL_BUTTON = 0x0008;
pub const TDCBF_CLOSE_BUTTON = 0x0020;

/// Predefined `TD_*_ICON` resource ids (MAKEINTRESOURCE of a negative number).
pub const TD_WARNING_ICON: usize = 0xFFFF;
pub const TD_ERROR_ICON: usize = 0xFFFE;
pub const TD_INFORMATION_ICON: usize = 0xFFFD;

// The SDK declares both structs between pshpack1.h and poppack.h: every
// field is byte-aligned.
pub const TASKDIALOG_BUTTON = extern struct {
    nButtonID: i32 align(1),
    pszButtonText: ?[*:0]const u16 align(1),
};

pub const PFTASKDIALOGCALLBACK = *const fn (HWND, u32, usize, isize, isize) callconv(.winapi) HRESULT;

pub const TASKDIALOGCONFIG = extern struct {
    cbSize: u32 align(1) = @sizeOf(TASKDIALOGCONFIG),
    hwndParent: ?HWND align(1) = null,
    hInstance: ?HINSTANCE align(1) = null,
    dwFlags: u32 align(1) = 0,
    dwCommonButtons: u32 align(1) = 0,
    pszWindowTitle: ?[*:0]const u16 align(1) = null,
    /// The `hMainIcon` / `pszMainIcon` union.
    pszMainIcon: ?*const anyopaque align(1) = null,
    pszMainInstruction: ?[*:0]const u16 align(1) = null,
    pszContent: ?[*:0]const u16 align(1) = null,
    cButtons: u32 align(1) = 0,
    pButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultButton: i32 align(1) = 0,
    cRadioButtons: u32 align(1) = 0,
    pRadioButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultRadioButton: i32 align(1) = 0,
    pszVerificationText: ?[*:0]const u16 align(1) = null,
    pszExpandedInformation: ?[*:0]const u16 align(1) = null,
    pszExpandedControlText: ?[*:0]const u16 align(1) = null,
    pszCollapsedControlText: ?[*:0]const u16 align(1) = null,
    /// The `hFooterIcon` / `pszFooterIcon` union.
    pszFooterIcon: ?*const anyopaque align(1) = null,
    pszFooter: ?[*:0]const u16 align(1) = null,
    pfCallback: ?PFTASKDIALOGCALLBACK align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: u32 align(1) = 0,
};

const TaskDialogIndirectFn = *const fn (
    *const TASKDIALOGCONFIG,
    ?*i32,
    ?*i32,
    ?*BOOL,
) callconv(.winapi) HRESULT;

/// `TaskDialogIndirect` needs the version 6 common controls (the exe's
/// manifest); a plain import would stop a process without it (the test
/// executables) from loading. Resolved on first use instead: null when
/// the entry point is missing and callers fall back to a message box.
fn taskDialogProc() ?TaskDialogIndirectFn {
    const S = struct {
        var proc: ?TaskDialogIndirectFn = null;
        var resolved = false;
    };
    if (!S.resolved) {
        S.resolved = true;
        const lib = std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll");
        const module = kernel32.LoadLibraryExW(lib, null, 0x00000800) orelse return null;
        const addr = kernel32.GetProcAddress(module, "TaskDialogIndirect") orelse return null;
        S.proc = @ptrCast(@alignCast(addr));
    }
    return S.proc;
}

/// What showing a task dialog came to. A failed HRESULT may arrive after the
/// dialog was on screen, so only `unavailable` justifies a second prompt.
pub const TaskDialogOutcome = union(enum) {
    /// The entry point is missing: nothing was shown.
    unavailable,
    failed: HRESULT,
    pressed: i32,
};

pub fn taskDialogShow(config: *const TASKDIALOGCONFIG) TaskDialogOutcome {
    const proc = taskDialogProc() orelse return .unavailable;
    var button: i32 = 0;
    const hr = proc(config, &button, null, null);
    if (hr < 0) return .{ .failed = hr };
    return .{ .pressed = button };
}

/// Show a task dialog. The id of the pressed button, or null when the
/// dialog is unavailable or failed.
pub fn taskDialogIndirect(config: *const TASKDIALOGCONFIG) ?i32 {
    return switch (taskDialogShow(config)) {
        .pressed => |id| id,
        else => null,
    };
}

// -- Window subclassing ------------------------------------------------------

pub const SUBCLASSPROC = *const fn (
    hwnd: foundation.HWND,
    msg: u32,
    wparam: foundation.WPARAM,
    lparam: foundation.LPARAM,
    subclass_id: usize,
    ref_data: usize,
) callconv(.winapi) foundation.LRESULT;

pub extern "comctl32" fn SetWindowSubclass(
    hwnd: foundation.HWND,
    proc: SUBCLASSPROC,
    subclass_id: usize,
    ref_data: usize,
) callconv(.winapi) foundation.BOOL;
pub extern "comctl32" fn DefSubclassProc(
    hwnd: foundation.HWND,
    msg: u32,
    wparam: foundation.WPARAM,
    lparam: foundation.LPARAM,
) callconv(.winapi) foundation.LRESULT;
pub extern "comctl32" fn RemoveWindowSubclass(
    hwnd: foundation.HWND,
    proc: SUBCLASSPROC,
    subclass_id: usize,
) callconv(.winapi) foundation.BOOL;

// -- Tooltips ------------------------------------------------------------------

pub const TOOLTIPS_CLASSW = std.unicode.utf8ToUtf16LeStringLiteral("tooltips_class32");

pub const TTS_ALWAYSTIP = 0x01;
pub const TTS_NOPREFIX = 0x02;

pub const TTF_IDISHWND = 0x0001;
pub const TTF_TRACK = 0x0020;
pub const TTF_ABSOLUTE = 0x0080;

pub const TTM_TRACKACTIVATE = 0x0400 + 17;
pub const TTM_TRACKPOSITION = 0x0400 + 18;
pub const TTM_SETMAXTIPWIDTH = 0x0400 + 24;
pub const TTM_ADDTOOLW = 0x0400 + 50;
pub const TTM_UPDATETIPTEXTW = 0x0400 + 57;

pub const TOOLINFOW = extern struct {
    cbSize: u32 = @sizeOf(TOOLINFOW),
    uFlags: u32 = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    hinst: ?HINSTANCE = null,
    lpszText: ?[*:0]u16 = null,
    lParam: isize = 0,
    lpReserved: ?*anyopaque = null,
};
