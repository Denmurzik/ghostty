//! The two additions of the clipboard prompt that the plain dialog does not
//! have: a preview image (drawn with Direct2D from pixels the caller already
//! scaled down) and the "remember" switch, a real `BUTTON` with
//! `BS_AUTOCHECKBOX` that keeps its checkbox role and state for screen
//! readers and is painted by the dialog on `NM_CUSTOMDRAW`.
//!
//! The painters take the dialog's `Pen` as `anytype` (it is private to
//! `Dialog.zig`): `rt`, `fill`, `fillRound`, `strokeRound` and `drawText`.
const std = @import("std");
const win32 = @import("win32");
const colors = @import("colors.zig");
const layout = @import("layout.zig");

const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;
const com = win32.com;
const HWND = win32.foundation.HWND;
const HDC = win32.user32.HDC;
const RECT = win32.foundation.RECT;

/// Premultiplied BGRA pixels, top row first, already downscaled by the
/// caller (`clipboard_image.preview`). Never larger than `max_side`.
pub const Image = struct {
    width: u32,
    height: u32,
    bgra: []const u8,
};

/// The most pixels of one side a dialog image may have.
pub const max_side: u32 = 16384;

/// Whether `img` can be drawn: sizes in range, the buffer exactly its size.
pub fn imageValid(img: Image) bool {
    if (img.width == 0 or img.height == 0) return false;
    if (img.width > max_side or img.height > max_side) return false;
    return img.bgra.len == @as(usize, img.width) * img.height * 4;
}

/// The "remember" switch. `state` is read when the dialog closes (with any
/// button), and its value at the start is the initial state.
pub const Check = struct {
    label: []const u16,
    state: *bool,
};

// -- Win32 odds and ends ------------------------------------------------------------

pub const WM_NOTIFY = 0x004E;
pub const BM_GETCHECK = 0x00F0;
pub const BM_SETCHECK = 0x00F1;
pub const BST_CHECKED = 1;
pub const BS_AUTOCHECKBOX = 0x00000003;

/// `NM_FIRST - 12`.
pub const NM_CUSTOMDRAW: u32 = 0xFFFFFFF4;
pub const CDDS_PREPAINT = 0x00000001;
pub const CDRF_DODEFAULT = 0x00000000;
pub const CDRF_SKIPDEFAULT = 0x00000004;
pub const CDIS_SELECTED = 0x0001;
pub const CDIS_DISABLED = 0x0004;
pub const CDIS_CHECKED = 0x0008;
pub const CDIS_FOCUS = 0x0010;
pub const CDIS_HOT = 0x0040;

pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: usize,
    code: u32,
};

pub const NMCUSTOMDRAW = extern struct {
    hdr: NMHDR,
    dwDrawStage: u32,
    hdc: ?HDC,
    rc: RECT,
    dwItemSpec: usize,
    uItemState: u32,
    lItemlParam: isize,
};

// -- Image ---------------------------------------------------------------------------

/// Draws `img` fitted and centred in `box`, on a card-coloured ground (an
/// image with transparency shows on it) with a 1 px card stroke. The
/// bitmap is made once per render target and kept in `slot`; the caller
/// releases it (`release`) when the target or the DPI changes.
pub fn drawImage(pen: anytype, slot: *?*d2d1.ID2D1Bitmap, img: Image, box: layout.Rect, pal: *const colors.Palette, radius: f32) void {
    if (!imageValid(img)) return;
    const at = layout.fitImage(box, img.width, img.height);
    if (at.w <= 0 or at.h <= 0) return;

    if (slot.* == null) {
        slot.* = pen.rt.createBitmap(img.width, img.height, img.bgra, img.width * 4, .{
            .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
            .dpiX = 96,
            .dpiY = 96,
        }) catch return;
    }
    const bitmap = slot.* orelse return;

    pen.fillRound(at, radius, pal.card);
    pen.rt.drawBitmap(bitmap, .{
        .left = @floatFromInt(at.x),
        .top = @floatFromInt(at.y),
        .right = @floatFromInt(at.right()),
        .bottom = @floatFromInt(at.bottom()),
    }, 1, .LINEAR);
    pen.strokeRound(at, radius, 1, 0, pal.card_border);
}

pub fn release(slot: *?*d2d1.ID2D1Bitmap) void {
    com.release(slot.*);
    slot.* = null;
}

// -- Switch --------------------------------------------------------------------------

pub const CheckPaint = struct {
    /// The state flags of the `NMCUSTOMDRAW` (`CDIS_*`).
    state: u32,
    checked: bool,
    /// The keyboard focus is shown (after a key, not after a click).
    show_focus: bool,
    dpi: u32,
    label: []const u16,
    label_format: *dwrite.IDWriteTextFormat,
    glyph_format: *dwrite.IDWriteTextFormat,
};

/// The check mark glyph of Segoe Fluent Icons (`CheckMark`), as the WinUI
/// check box uses.
pub const check_glyph = std.unicode.utf8ToUtf16LeStringLiteral("\u{E73E}");

/// Paints the switch into a `w` x `h` px area: a 20 DIP rounded box (an
/// outline when off; the accent with a check mark when on) and the label.
pub fn drawCheck(pen: anytype, pal: *const colors.Palette, w: i32, h: i32, cp: CheckPaint) void {
    const box = layout.px(layout.check_box, cp.dpi);
    const gap = layout.px(layout.check_gap, cp.dpi);
    const radius: f32 = @floatFromInt(layout.px(layout.check_radius, cp.dpi));
    const pressed = cp.state & CDIS_SELECTED != 0;
    const hot = cp.state & CDIS_HOT != 0;
    const row: layout.Rect = .{ .w = w, .h = h };
    const square: layout.Rect = .{ .x = 0, .y = @divFloor(h - box, 2), .w = box, .h = box };

    if (cp.checked) {
        const fill = if (pressed) pal.accent_pressed else if (hot) pal.accent_hover else pal.accent;
        pen.fillRound(square, radius, fill);
        const ink = if (pressed) pal.accent_text_pressed else pal.accent_text;
        pen.drawText(square, check_glyph, cp.glyph_format, ink);
    } else {
        if (pressed or hot) pen.fillRound(square, radius, if (pressed) pal.button_pressed else pal.button_hover);
        // ControlStrongStroke: the text colour, softened.
        const edge: colors.Rgba = .{ .r = pal.text.r, .g = pal.text.g, .b = pal.text.b, .a = 0xB4 };
        pen.strokeRound(square, radius, 1, 0, edge);
    }

    const label_at: layout.Rect = .{ .x = box + gap, .y = 0, .w = @max(w - box - gap, 0), .h = h };
    pen.drawText(label_at, cp.label, cp.label_format, pal.text);

    if (cp.state & CDIS_FOCUS != 0 and cp.show_focus) {
        const ring: f32 = @floatFromInt(layout.px(layout.button_radius, cp.dpi));
        pen.strokeRound(row, ring, 2, 0, pal.focus_outer);
        pen.strokeRound(row, ring, 1, 2, pal.focus_inner);
    }
}

test "win32 dialog extras: image validity" {
    const px4: [16]u8 = @splat(0);
    try std.testing.expect(imageValid(.{ .width = 2, .height = 2, .bgra = &px4 }));
    try std.testing.expect(!imageValid(.{ .width = 2, .height = 3, .bgra = &px4 }));
    try std.testing.expect(!imageValid(.{ .width = 0, .height = 2, .bgra = &px4 }));
    try std.testing.expect(!imageValid(.{ .width = 1, .height = 1, .bgra = &px4 }));
    try std.testing.expect(!imageValid(.{ .width = max_side + 1, .height = 1, .bgra = &.{} }));
}

test "win32 dialog extras: NMCUSTOMDRAW has the C layout" {
    // commctrl.h on x64: NMHDR 24, NMCUSTOMDRAW 80.
    try std.testing.expectEqual(24, @sizeOf(NMHDR));
    try std.testing.expectEqual(80, @sizeOf(NMCUSTOMDRAW));
    try std.testing.expectEqual(24, @offsetOf(NMCUSTOMDRAW, "dwDrawStage"));
    try std.testing.expectEqual(32, @offsetOf(NMCUSTOMDRAW, "hdc"));
    try std.testing.expectEqual(40, @offsetOf(NMCUSTOMDRAW, "rc"));
    try std.testing.expectEqual(56, @offsetOf(NMCUSTOMDRAW, "dwItemSpec"));
    try std.testing.expectEqual(64, @offsetOf(NMCUSTOMDRAW, "uItemState"));
    try std.testing.expectEqual(72, @offsetOf(NMCUSTOMDRAW, "lItemlParam"));
}
