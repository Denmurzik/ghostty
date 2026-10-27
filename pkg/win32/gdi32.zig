//! gdi32 bindings: stock objects for window class setup and the memory-DC /
//! DIB section plumbing behind layered windows.
const foundation = @import("foundation.zig");
const user32 = @import("user32.zig");
const BOOL = foundation.BOOL;
const HANDLE = foundation.HANDLE;
const RECT = foundation.RECT;
const HDC = user32.HDC;
const HBRUSH = user32.HBRUSH;

pub const HBITMAP = *opaque {};
/// Any GDI object handle (bitmap, brush, ...); pass the typed handle through `@ptrCast`.
pub const HGDIOBJ = *anyopaque;

pub const RGBQUAD = extern struct {
    rgbBlue: u8 = 0,
    rgbGreen: u8 = 0,
    rgbRed: u8 = 0,
    rgbReserved: u8 = 0,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 0,
    biCompression: u32 = BI_RGB,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]RGBQUAD = .{.{}},
};

pub extern "gdi32" fn GetStockObject(index: i32) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
/// `bits` receives the pixel memory owned by the returned bitmap.
pub extern "gdi32" fn CreateDIBSection(
    ?HDC,
    *const BITMAPINFO,
    usage: u32,
    bits: *?*anyopaque,
    section: ?HANDLE,
    offset: u32,
) callconv(.winapi) ?HBITMAP;
/// Returns the previously selected object, null on failure.
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
/// `color` is a `COLORREF` (0x00BBGGRR).
pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?HBRUSH;
/// Exported by user32; grouped here with the other drawing calls.
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) i32;

pub const WHITE_BRUSH = 0;
pub const BLACK_BRUSH = 4;
pub const NULL_BRUSH = 5;

pub const DIB_RGB_COLORS = 0;
pub const BI_RGB = 0;

pub const HFONT = *opaque {};
pub extern "gdi32" fn CreateFontW(
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: u32,
    underline: u32,
    strike_out: u32,
    charset: u32,
    out_precision: u32,
    clip_precision: u32,
    quality: u32,
    pitch_and_family: u32,
    face: [*:0]const u16,
) callconv(.winapi) ?HFONT;
