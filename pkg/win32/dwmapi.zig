//! dwmapi bindings for per-window DWM attributes.
const foundation = @import("foundation.zig");
const BOOL = foundation.BOOL;
const HRESULT = foundation.HRESULT;
const HWND = foundation.HWND;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) HRESULT;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
pub const DWMWA_BORDER_COLOR = 34;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
pub const DWMWA_EXTENDED_FRAME_BOUNDS = 9;

pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(HWND, *const MARGINS) callconv(.winapi) HRESULT;
/// Returns nonzero when DWM handled the message; `result` is then valid.
pub extern "dwmapi" fn DwmDefWindowProc(HWND, msg: u32, wparam: WPARAM, lparam: LPARAM, result: *LRESULT) callconv(.winapi) BOOL;
pub extern "dwmapi" fn DwmGetWindowAttribute(HWND, attribute: u32, value: *anyopaque, size: u32) callconv(.winapi) HRESULT;

/// `DWM_SYSTEMBACKDROP_TYPE` values for `DWMWA_SYSTEMBACKDROP_TYPE`.
pub const DWMSBT_AUTO = 0;
pub const DWMSBT_NONE = 1;
pub const DWMSBT_MAINWINDOW = 2;
pub const DWMSBT_TRANSIENTWINDOW = 3;
pub const DWMSBT_TABBEDWINDOW = 4;

/// `DWM_WINDOW_CORNER_PREFERENCE` values for `DWMWA_WINDOW_CORNER_PREFERENCE`.
pub const DWMWCP_DEFAULT = 0;
pub const DWMWCP_DONOTROUND = 1;
pub const DWMWCP_ROUND = 2;
pub const DWMWCP_ROUNDSMALL = 3;
