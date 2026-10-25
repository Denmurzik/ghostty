//! dwmapi bindings for per-window DWM attributes.
const foundation = @import("foundation.zig");
const HRESULT = foundation.HRESULT;
const HWND = foundation.HWND;

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) HRESULT;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
pub const DWMWA_BORDER_COLOR = 34;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
