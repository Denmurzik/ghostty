//! Layout maths of the Windows 11 (WinUI `ContentDialog`) style dialog. All
//! sizes are 96-DPI values scaled to the dialog's DPI, in pixels. The text
//! measurements come from DirectWrite in `Dialog.zig`; everything that can
//! be computed from them lives here.
const std = @import("std");
const geom = @import("../geom.zig");

pub const Rect = geom.Rect;

/// Padding of the content and of the button bar.
pub const pad = 24;
/// Space between the title and the body, and between the body and the list.
pub const gap = 12;
pub const button_h = 32;
/// Space between buttons.
pub const button_gap = 8;
/// Left and right padding inside a button.
pub const button_pad_x = 16;
/// The narrowest a button gets.
pub const button_min_w = 64;
pub const button_radius = 4;
pub const card_radius = 6;
pub const min_w = 320;
pub const max_w = 548;
/// Height of the button bar: the buttons between two paddings.
pub const footer_h = pad + button_h + pad;
/// Padding of the list inside its card.
pub const list_inset = 6;
/// Shortest list: lines.
pub const list_min_lines = 3;
pub const max_buttons = 4;

/// The tallest preview image (GTK clamps its preview to 200 px as well).
pub const image_max_h = 200;
/// The switch: box and gap to the label (DIP), and the row's height.
pub const check_box = 20;
pub const check_gap = 8;
pub const check_row_h = 32;
pub const check_radius = 4;

/// Title and body sizes (px at 96 DPI).
pub const title_px = 20;
pub const body_px = 14;
pub const list_px = 13;

pub fn px(v: i32, dpi: u32) i32 {
    return geom.scale(v, dpi);
}

/// The widest line the dialog wants (px): the text, the buttons at their
/// natural width, or the least width, but never more than the most.
pub fn dialogWidth(text_w: i32, buttons_w: i32, dpi: u32) i32 {
    const wanted = @max(text_w, buttons_w) + 2 * px(pad, dpi);
    return std.math.clamp(wanted, px(min_w, dpi), px(max_w, dpi));
}

/// Natural width of the button row: every button as wide as the widest
/// label needs (they are stretched equally), plus the gaps.
pub fn buttonsNaturalWidth(label_widths: []const i32, dpi: u32) i32 {
    if (label_widths.len == 0) return 0;
    var widest: i32 = 0;
    for (label_widths) |w| widest = @max(widest, w);
    const each = @max(widest + 2 * px(button_pad_x, dpi), px(button_min_w, dpi));
    const n: i32 = @intCast(label_widths.len);
    return n * each + (n - 1) * px(button_gap, dpi);
}

/// One button's horizontal slot in a row `row_w` wide with `n` buttons:
/// equal widths, the remainder spread over the first slots, so the row
/// fills `row_w` exactly.
pub fn buttonSlot(row_w: i32, n: usize, index: usize, dpi: u32) struct { x: i32, w: i32 } {
    std.debug.assert(n >= 1 and index < n);
    const g = px(button_gap, dpi);
    const count: i32 = @intCast(n);
    const usable = row_w - (count - 1) * g;
    const base = @divFloor(usable, count);
    const extra: usize = @intCast(usable - base * count);
    var x: i32 = 0;
    for (0..index) |i| x += base + @as(i32, @intFromBool(i < extra)) + g;
    return .{ .x = x, .w = base + @as(i32, @intFromBool(index < extra)) };
}

/// Lines `text` takes when wrapped at `cols` columns: a newline starts a
/// line, a longer line wraps (a character grid, as the monospace list is).
/// Empty text is no lines; a trailing newline does not add an empty line.
pub fn lineCount(text: []const u16, cols: usize) usize {
    if (text.len == 0) return 0;
    const width = @max(cols, 1);
    var lines: usize = 0;
    var run: usize = 0;
    var open = false;
    for (text) |c| {
        if (c == '\n') {
            lines += @max(1, (run + width - 1) / width);
            run = 0;
            open = false;
        } else {
            run += 1;
            open = true;
        }
    }
    if (open) lines += (run + width - 1) / width;
    return lines;
}

/// Height (px) of the list card for `lines` text lines of `line_h`, between
/// the least and `cap`.
pub fn listHeight(lines: usize, line_h: i32, cap: i32, dpi: u32) i32 {
    const inset = 2 * px(list_inset, dpi);
    const shown: i32 = @intCast(@max(lines, list_min_lines));
    return @min(shown * line_h + inset, @max(cap, list_min_lines * line_h + inset));
}

/// The tallest body or list (px): the dialog may take 80% of the work area,
/// less the title, the paddings and the button bar.
pub fn bodyCap(work_h: i32, title_h: i32, dpi: u32) i32 {
    const chrome = 2 * px(pad, dpi) + px(footer_h, dpi) - px(pad, dpi) + title_h + px(gap, dpi);
    return @max(@divFloor(work_h * 8, 10) - chrome, px(80, dpi));
}

pub const Input = struct {
    dpi: u32,
    /// Widest line of title and body (px, unwrapped).
    text_w: i32,
    /// Natural width of the button row (px).
    buttons_w: i32,
    button_count: usize,
    /// Height of the wrapped title; 0 for none.
    title_h: i32 = 0,
    /// Height of the wrapped body; 0 for none.
    body_h: i32 = 0,
    /// Height of the list card; 0 for none. A list makes the dialog as wide
    /// as it gets.
    list_h: i32 = 0,
    /// Height of an app icon above the text; 0 for none.
    icon_h: i32 = 0,
    /// Natural height (px) of the preview image between body and list; 0 for
    /// none. Like a list, an image makes the dialog as wide as it gets.
    image_h: i32 = 0,
    /// Height of the switch row above the button bar; 0 for none.
    check_h: i32 = 0,
};

pub const Plan = struct {
    width: i32,
    height: i32,
    icon: Rect = .{},
    title: Rect,
    body: Rect,
    /// The box the preview image is fitted into (see `fitImage`).
    image: Rect = .{},
    list: Rect,
    /// The row of the switch.
    check: Rect = .{},
    footer: Rect,
    buttons: [max_buttons]Rect,
    count: usize,
    /// The part above this y (the text) is the dialog's drag area.
    drag_h: i32,
};

pub fn plan(in: Input) Plan {
    const dpi = in.dpi;
    const p = px(pad, dpi);
    const g = px(gap, dpi);
    const wide = in.list_h > 0 or in.image_h > 0;
    const width = if (wide) px(max_w, dpi) else dialogWidth(in.text_w, in.buttons_w, dpi);
    const content_w = width - 2 * p;

    var out: Plan = .{
        .width = width,
        .height = 0,
        .title = .{},
        .body = .{},
        .list = .{},
        .footer = .{},
        .buttons = @splat(.{}),
        .count = @min(in.button_count, max_buttons),
        .drag_h = 0,
    };

    var y = p;
    if (in.icon_h > 0) {
        out.icon = .{ .x = @divFloor(width - in.icon_h, 2), .y = y, .w = in.icon_h, .h = in.icon_h };
        y += in.icon_h + g;
    }
    if (in.title_h > 0) {
        out.title = .{ .x = p, .y = y, .w = content_w, .h = in.title_h };
        y += in.title_h;
    }
    if (in.body_h > 0) {
        if (in.title_h > 0) y += g;
        out.body = .{ .x = p, .y = y, .w = content_w, .h = in.body_h };
        y += in.body_h;
    }
    out.drag_h = y;
    if (in.image_h > 0) {
        if (y > p) y += g;
        const h = @min(px(image_max_h, dpi), in.image_h);
        out.image = .{ .x = p, .y = y, .w = content_w, .h = h };
        y += h;
    }
    if (in.list_h > 0) {
        if (y > p) y += g;
        out.list = .{ .x = p, .y = y, .w = content_w, .h = in.list_h };
        y += in.list_h;
    }
    if (in.check_h > 0) {
        if (y > p) y += g;
        out.check = .{ .x = p, .y = y, .w = content_w, .h = in.check_h };
        y += in.check_h;
    }
    y += p;

    const footer_height = px(footer_h, dpi);
    out.footer = .{ .x = 0, .y = y, .w = width, .h = footer_height };
    out.height = y + footer_height;

    for (0..out.count) |i| {
        const slot = buttonSlot(content_w, out.count, i, dpi);
        out.buttons[i] = .{
            .x = p + slot.x,
            .y = y + p,
            .w = slot.w,
            .h = px(button_h, dpi),
        };
    }
    return out;
}

test "win32 dialog layout: width follows the text within the limits" {
    // Short text gets the least width, long text the most.
    try std.testing.expectEqual(@as(i32, 320), dialogWidth(100, 100, 96));
    try std.testing.expectEqual(@as(i32, 548), dialogWidth(900, 100, 96));
    try std.testing.expectEqual(@as(i32, 400 + 48), dialogWidth(400, 100, 96));
    // Buttons that need more room than the text widen the dialog.
    try std.testing.expectEqual(@as(i32, 420 + 48), dialogWidth(100, 420, 96));
}

test "win32 dialog layout: dpi scaling" {
    try std.testing.expectEqual(@as(i32, 480), dialogWidth(100, 100, 144));
    try std.testing.expectEqual(@as(i32, 822), dialogWidth(2000, 100, 144));
    try std.testing.expectEqual(@as(i32, 36), px(pad, 144));
    try std.testing.expectEqual(@as(i32, 60), px(pad, 240));
    try std.testing.expectEqual(@as(i32, 80), px(footer_h, 96));
    try std.testing.expectEqual(@as(i32, 160), px(footer_h, 192));
}

test "win32 dialog layout: buttons are equal and fill the row" {
    // 3 buttons over 500 px with 8 px gaps: 484 / 3 = 161 rem 1.
    var total: i32 = 0;
    var prev_end: i32 = -8;
    for (0..3) |i| {
        const s = buttonSlot(500, 3, i, 96);
        try std.testing.expectEqual(prev_end + 8, s.x);
        prev_end = s.x + s.w;
        total += s.w;
    }
    try std.testing.expectEqual(@as(i32, 500), prev_end);
    try std.testing.expectEqual(@as(i32, 484), total);
    // The widths differ by one pixel at most.
    try std.testing.expectEqual(@as(i32, 162), buttonSlot(500, 3, 0, 96).w);
    try std.testing.expectEqual(@as(i32, 161), buttonSlot(500, 3, 2, 96).w);
    // One button takes the whole row.
    try std.testing.expectEqual(@as(i32, 500), buttonSlot(500, 1, 0, 96).w);
    // Gaps scale.
    try std.testing.expectEqual(@as(i32, 12), buttonSlot(500, 2, 1, 144).x - buttonSlot(500, 2, 0, 144).w);
}

test "win32 dialog layout: natural button row" {
    // Two buttons with 40 and 60 px labels: 92 px each plus 8.
    try std.testing.expectEqual(@as(i32, 2 * 92 + 8), buttonsNaturalWidth(&.{ 40, 60 }, 96));
    // A tiny label still gets the minimum width.
    try std.testing.expectEqual(@as(i32, 64), buttonsNaturalWidth(&.{10}, 96));
    try std.testing.expectEqual(@as(i32, 0), buttonsNaturalWidth(&.{}, 96));
}

test "win32 dialog layout: line counting wraps like a character grid" {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqual(@as(usize, 0), lineCount(w(""), 10));
    try std.testing.expectEqual(@as(usize, 1), lineCount(w("abc"), 10));
    try std.testing.expectEqual(@as(usize, 2), lineCount(w("abc\ndef"), 10));
    // A trailing newline adds no line; a blank line counts.
    try std.testing.expectEqual(@as(usize, 1), lineCount(w("abc\n"), 10));
    try std.testing.expectEqual(@as(usize, 3), lineCount(w("abc\n\ndef"), 10));
    // 25 characters at 10 columns take 3 lines.
    try std.testing.expectEqual(@as(usize, 3), lineCount(w("aaaaaaaaaaaaaaaaaaaaaaaaa"), 10));
    try std.testing.expectEqual(@as(usize, 2), lineCount(w("aaaaaaaaaa\nb"), 10));
    // Zero columns do not divide by zero.
    try std.testing.expectEqual(@as(usize, 3), lineCount(w("abc"), 0));
}

test "win32 dialog layout: list height is clamped" {
    // 2 lines still show 3; 100 lines stop at the cap.
    try std.testing.expectEqual(@as(i32, 3 * 18 + 12), listHeight(2, 18, 400, 96));
    try std.testing.expectEqual(@as(i32, 5 * 18 + 12), listHeight(5, 18, 400, 96));
    try std.testing.expectEqual(@as(i32, 300), listHeight(100, 18, 300, 96));
    // A cap below the minimum still shows the minimum.
    try std.testing.expectEqual(@as(i32, 3 * 18 + 12), listHeight(100, 18, 10, 96));
}

test "win32 dialog layout: body cap leaves room for the chrome" {
    const cap = bodyCap(1000, 28, 96);
    // 800 less 24 + 24 + 56 (the bar without its top pad is 80 - 24)... see chrome.
    try std.testing.expectEqual(@as(i32, 800 - (2 * 24 + 80 - 24 + 28 + 12)), cap);
    // A tiny work area keeps a usable floor.
    try std.testing.expectEqual(@as(i32, 80), bodyCap(100, 28, 96));
}

test "win32 dialog layout: plan stacks title, body and the button bar" {
    const p = plan(.{
        .dpi = 96,
        .text_w = 300,
        .buttons_w = 200,
        .button_count = 2,
        .title_h = 28,
        .body_h = 40,
    });
    try std.testing.expectEqual(@as(i32, 348), p.width);
    try std.testing.expectEqual(Rect{ .x = 24, .y = 24, .w = 300, .h = 28 }, p.title);
    try std.testing.expectEqual(Rect{ .x = 24, .y = 24 + 28 + 12, .w = 300, .h = 40 }, p.body);
    // 24 + 28 + 12 + 40 + 24 puts the bar at 128.
    try std.testing.expectEqual(Rect{ .x = 0, .y = 128, .w = 348, .h = 80 }, p.footer);
    try std.testing.expectEqual(@as(i32, 208), p.height);
    try std.testing.expectEqual(@as(usize, 2), p.count);
    try std.testing.expectEqual(@as(i32, 128 + 24), p.buttons[0].y);
    try std.testing.expectEqual(@as(i32, 32), p.buttons[0].h);
    try std.testing.expectEqual(@as(i32, 24), p.buttons[0].x);
    try std.testing.expectEqual(p.buttons[0].right() + 8, p.buttons[1].x);
    try std.testing.expectEqual(@as(i32, 348 - 24), p.buttons[1].right());
    try std.testing.expectEqual(@as(i32, 104), p.drag_h);
}

test "win32 dialog layout: a list makes the dialog wide and sits under the body" {
    const p = plan(.{
        .dpi = 96,
        .text_w = 100,
        .buttons_w = 100,
        .button_count = 3,
        .title_h = 28,
        .body_h = 36,
        .list_h = 200,
    });
    try std.testing.expectEqual(@as(i32, 548), p.width);
    try std.testing.expectEqual(@as(i32, 24 + 28 + 12 + 36 + 12), p.list.y);
    try std.testing.expectEqual(@as(i32, 548 - 48), p.list.w);
    try std.testing.expectEqual(p.list.bottom() + 24, p.footer.y);
    // Three buttons fill the content width.
    try std.testing.expectEqual(@as(i32, 548 - 24), p.buttons[2].right());
}

/// Where an `iw` x `ih` px image is drawn inside `box`: as large as fits
/// with its aspect ratio kept, never larger than itself, centred.
pub fn fitImage(box: Rect, iw: u32, ih: u32) Rect {
    if (iw == 0 or ih == 0 or box.w <= 0 or box.h <= 0) return .{ .x = box.x, .y = box.y };
    const w: i64 = iw;
    const h: i64 = ih;
    var ow = w;
    var oh = h;
    if (w > box.w or h > box.h) {
        if (w * box.h >= h * box.w) {
            ow = box.w;
            oh = @max(1, @divFloor(h * box.w, w));
        } else {
            oh = box.h;
            ow = @max(1, @divFloor(w * box.h, h));
        }
    }
    const out_w: i32 = @intCast(ow);
    const out_h: i32 = @intCast(oh);
    return .{
        .x = box.x + @divFloor(box.w - out_w, 2),
        .y = box.y + @divFloor(box.h - out_h, 2),
        .w = out_w,
        .h = out_h,
    };
}

test "win32 dialog layout: image is clamped and fitted" {
    for ([_]u32{ 96, 144 }) |dpi| {
        const p = plan(.{
            .dpi = dpi,
            .text_w = 100,
            .buttons_w = 100,
            .button_count = 2,
            .title_h = 28,
            .body_h = 40,
            .image_h = 6000,
            .list_h = 100,
        });
        try std.testing.expectEqual(px(200, dpi), p.image.h);
        try std.testing.expectEqual(p.width - 2 * px(pad, dpi), p.image.w);
        // Between the body and the list, one gap each side.
        try std.testing.expectEqual(p.body.bottom() + px(gap, dpi), p.image.y);
        try std.testing.expectEqual(p.image.bottom() + px(gap, dpi), p.list.y);
        // 800 x 6000: the height is the tight side, the aspect is kept.
        const fit = fitImage(p.image, 800, 6000);
        try std.testing.expectEqual(px(200, dpi), fit.h);
        try std.testing.expect(fit.w <= p.image.w and fit.w > 0);
        try std.testing.expect(@abs(@as(i64, fit.w) * 6000 - @as(i64, fit.h) * 800) <= 6000);
        // Centred in the box.
        try std.testing.expectEqual(p.image.x + @divFloor(p.image.w - fit.w, 2), fit.x);
    }

    // 10 x 10 keeps its size and sits in the middle.
    const small = plan(.{ .dpi = 96, .text_w = 100, .buttons_w = 100, .button_count = 1, .body_h = 20, .image_h = 10, .list_h = 60 });
    try std.testing.expectEqual(@as(i32, 10), small.image.h);
    const fit = fitImage(small.image, 10, 10);
    try std.testing.expectEqual(@as(i32, 10), fit.w);
    try std.testing.expectEqual(@as(i32, 10), fit.h);
    try std.testing.expectEqual(small.image.x + @divFloor(small.image.w - 10, 2), fit.x);
    try std.testing.expectEqual(small.image.y, fit.y);

    // A wide image is limited by the width.
    const wide = fitImage(.{ .x = 0, .y = 0, .w = 500, .h = 200 }, 2000, 400);
    try std.testing.expectEqual(@as(i32, 500), wide.w);
    try std.testing.expectEqual(@as(i32, 100), wide.h);
    try std.testing.expectEqual(@as(i32, 50), wide.y);
}

test "win32 dialog layout: check row sits above the footer" {
    const base: Input = .{
        .dpi = 96,
        .text_w = 100,
        .buttons_w = 100,
        .button_count = 2,
        .title_h = 28,
        .body_h = 40,
        .image_h = 80,
        .list_h = 120,
    };
    var with = base;
    with.check_h = px(check_row_h, 96);
    const a = plan(base);
    const b = plan(with);

    try std.testing.expectEqual(Rect{}, a.check);
    // Below the list, above the bar, no overlap.
    try std.testing.expectEqual(b.list.bottom() + px(gap, 96), b.check.y);
    try std.testing.expectEqual(b.check.bottom() + px(pad, 96), b.footer.y);
    try std.testing.expect(b.check.y >= b.list.bottom());
    try std.testing.expectEqual(b.list.w, b.check.w);
    // The dialog grows by the row and the gap above it.
    try std.testing.expectEqual(a.height + b.check.h + px(gap, 96), b.height);
    // Without an image or a list the row follows the body.
    const only = plan(.{ .dpi = 96, .text_w = 100, .buttons_w = 100, .button_count = 1, .body_h = 40, .check_h = 32 });
    try std.testing.expectEqual(only.body.bottom() + px(gap, 96), only.check.y);
    try std.testing.expectEqual(Rect{}, only.image);
}

test "win32 dialog layout: body only, no title" {
    const p = plan(.{ .dpi = 192, .text_w = 100, .buttons_w = 100, .button_count = 1, .body_h = 60 });
    try std.testing.expectEqual(@as(i32, 640), p.width);
    try std.testing.expectEqual(@as(i32, 48), p.body.y);
    try std.testing.expectEqual(@as(i32, 48 + 60 + 48), p.footer.y);
    try std.testing.expectEqual(@as(i32, 640 - 96), p.buttons[0].w);
}

/// Where a `size` window goes to be centred on `anchor` and still lie
/// inside `work` (the work area of the monitor). A window larger than the
/// work area is put at its top-left corner.
pub fn centerIn(anchor: Rect, size: geom.Size, work: Rect) geom.Point {
    var x = anchor.x + @divFloor(anchor.w - size.w, 2);
    var y = anchor.y + @divFloor(anchor.h - size.h, 2);
    x = @min(x, work.right() - size.w);
    y = @min(y, work.bottom() - size.h);
    x = @max(x, work.x);
    y = @max(y, work.y);
    return .{ .x = x, .y = y };
}

test "win32 dialog layout: centring stays inside the work area" {
    const work: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };
    // Centred on a window.
    const p = centerIn(.{ .x = 100, .y = 100, .w = 800, .h = 600 }, .{ .w = 400, .h = 200 }, work);
    try std.testing.expectEqual(geom.Point{ .x = 300, .y = 300 }, p);
    // Pushed back in when the owner sticks out at the right and bottom.
    const q = centerIn(.{ .x = 1800, .y = 1000, .w = 800, .h = 600 }, .{ .w = 400, .h = 200 }, work);
    try std.testing.expectEqual(geom.Point{ .x = 1520, .y = 840 }, q);
    // And at the left and top (a second monitor to the left is a different work area).
    const r = centerIn(.{ .x = -300, .y = -300, .w = 200, .h = 200 }, .{ .w = 400, .h = 200 }, work);
    try std.testing.expectEqual(geom.Point{ .x = 0, .y = 0 }, r);
    // Too big: top-left.
    const s = centerIn(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ .w = 3000, .h = 2000 }, work);
    try std.testing.expectEqual(geom.Point{ .x = 0, .y = 0 }, s);
}
