//! comdlg32 bindings (common file dialogs).

const std = @import("std");
const foundation = @import("foundation.zig");

const BOOL = foundation.BOOL;
const HWND = foundation.HWND;
const HINSTANCE = foundation.HINSTANCE;
const LPARAM = foundation.LPARAM;

pub const OFN_OVERWRITEPROMPT = 0x00000002;
pub const OFN_NOCHANGEDIR = 0x00000008;
pub const OFN_PATHMUSTEXIST = 0x00000800;
pub const OFN_EXPLORER = 0x00080000;

pub const LPOFNHOOKPROC = *const fn (HWND, u32, usize, LPARAM) callconv(.winapi) usize;

/// 152 bytes on x64 (commdlg.h, natural alignment; the 32-bit pack(1)-free
/// layout is 140).
pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    /// Pairs of "description\0pattern\0", ended by an extra NUL.
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*:0]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: ?[*]u16 = null,
    nMaxFile: u32 = 0,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?LPOFNHOOKPROC = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

/// False when the user cancelled (`CommDlgExtendedError` is then 0) or the
/// dialog failed.
pub extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) u32;
