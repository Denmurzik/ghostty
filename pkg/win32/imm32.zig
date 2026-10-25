//! imm32 bindings for IME composition and candidate window placement.
const foundation = @import("foundation.zig");
const BOOL = foundation.BOOL;
const HWND = foundation.HWND;
const POINT = foundation.POINT;
const RECT = foundation.RECT;

pub const HIMC = *opaque {};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: u32,
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
/// Returns the byte length (or a negative IMM_ERROR_*); with a null `buf`
/// it only reports the size.
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, index: u32, buf: ?*anyopaque, buf_len: u32) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmNotifyIME(HIMC, action: u32, index: u32, value: u32) callconv(.winapi) BOOL;

// WM_IME_COMPOSITION lParam / ImmGetCompositionStringW index
pub const GCS_COMPREADSTR = 0x0001;
pub const GCS_COMPREADATTR = 0x0002;
pub const GCS_COMPREADCLAUSE = 0x0004;
pub const GCS_COMPSTR = 0x0008;
pub const GCS_COMPATTR = 0x0010;
pub const GCS_COMPCLAUSE = 0x0020;
pub const GCS_CURSORPOS = 0x0080;
pub const GCS_DELTASTART = 0x0100;
pub const GCS_RESULTREADSTR = 0x0200;
pub const GCS_RESULTREADCLAUSE = 0x0400;
pub const GCS_RESULTSTR = 0x0800;
pub const GCS_RESULTCLAUSE = 0x1000;

// COMPOSITIONFORM / CANDIDATEFORM dwStyle
pub const CFS_DEFAULT = 0x0000;
pub const CFS_RECT = 0x0001;
pub const CFS_POINT = 0x0002;
pub const CFS_FORCE_POSITION = 0x0020;
pub const CFS_CANDIDATEPOS = 0x0040;
pub const CFS_EXCLUDE = 0x0080;

// WM_IME_SETCONTEXT lParam display flags
pub const ISC_SHOWUICANDIDATEWINDOW = 0x00000001;
pub const ISC_SHOWUICOMPOSITIONWINDOW = 0x80000000;
pub const ISC_SHOWUIALL = 0xC000000F;

// WM_IME_NOTIFY wParam
pub const IMN_CHANGECANDIDATE = 0x0003;
pub const IMN_CLOSECANDIDATE = 0x0004;
pub const IMN_OPENCANDIDATE = 0x0005;

// ImmNotifyIME
pub const NI_COMPOSITIONSTR = 0x0015;
pub const CPS_COMPLETE = 0x0001;
pub const CPS_CONVERT = 0x0002;
pub const CPS_REVERT = 0x0003;
pub const CPS_CANCEL = 0x0004;
