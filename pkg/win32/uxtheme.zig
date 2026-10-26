//! uxtheme bindings (window themes, buffered paint). Filled by the tasks that first call them.

const foundation = @import("foundation.zig");

/// Select a visual style for a window ("DarkMode_Explorer" for dark scrollbars); null, null restores the default.
pub extern "uxtheme" fn SetWindowTheme(foundation.HWND, sub_app_name: ?[*:0]const u16, sub_id_list: ?[*:0]const u16) callconv(.winapi) foundation.HRESULT;

const user32 = @import("user32.zig");

pub const HPAINTBUFFER = *opaque {};

/// BP_BUFFERFORMAT: a top-down 32bpp DIB.
pub const BPBF_TOPDOWNDIB: u32 = 2;

/// BP_PAINTPARAMS dwFlags: clear the buffer to transparent black first.
pub const BPPF_ERASE: u32 = 1;

pub const BP_PAINTPARAMS = extern struct {
    cbSize: u32 = @sizeOf(BP_PAINTPARAMS),
    dwFlags: u32 = 0,
    prcExclude: ?*const foundation.RECT = null,
    pBlendFunction: ?*const user32.BLENDFUNCTION = null,
};

/// Paired per thread; the buffered-paint cache lives between the two.
pub extern "uxtheme" fn BufferedPaintInit() callconv(.winapi) foundation.HRESULT;
pub extern "uxtheme" fn BufferedPaintUnInit() callconv(.winapi) foundation.HRESULT;
/// Returns null on failure. `hdc_out` receives the DC to draw into.
pub extern "uxtheme" fn BeginBufferedPaint(
    target: user32.HDC,
    rect: *const foundation.RECT,
    format: u32,
    params: ?*const BP_PAINTPARAMS,
    hdc_out: *?user32.HDC,
) callconv(.winapi) ?HPAINTBUFFER;
pub extern "uxtheme" fn EndBufferedPaint(HPAINTBUFFER, update_target: foundation.BOOL) callconv(.winapi) foundation.HRESULT;
/// Sets every pixel of `rect` (null: the whole buffer) to transparent black.
pub extern "uxtheme" fn BufferedPaintClear(HPAINTBUFFER, rect: ?*const foundation.RECT) callconv(.winapi) foundation.HRESULT;
