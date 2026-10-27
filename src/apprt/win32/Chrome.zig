//! Painter of the title row and the tab row and the caption buttons: Direct2D
//! drawing and DirectWrite text into a buffered-paint DC (premultiplied
//! 32bpp DIB). The strip is painted in the terminal background, one colour
//! with the terminal below it; a palette colour with alpha 0 (a later
//! translucent window) leaves the DIB transparent.
//!
//! One D2D factory, one DirectWrite factory and one DC render target per
//! process, all used from the UI thread only. The target is drawn at 96 DPI
//! in pixels; text formats are cached per window DPI.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");
const input = @import("../../input.zig");
const CommandPalette = @import("CommandPalette.zig");

const com = win32.com;
const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;
const gdi32 = win32.gdi32;
const user32 = win32.user32;
const uxtheme = win32.uxtheme;
const HDC = user32.HDC;

const log = std.log.scoped(.win32_chrome);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Glyphs of Segoe Fluent Icons (Segoe MDL2 Assets has the same code points).
const glyph_minimize = L("\u{E921}");
const glyph_maximize = L("\u{E922}");
const glyph_restore = L("\u{E923}");
const glyph_close = L("\u{E8BB}");
const glyph_new_tab = L("\u{E710}");
const glyph_bell = L("\u{EA8F}");

/// How many DPIs keep their text formats; a window moves between few.
const format_slots = 4;

/// Point sizes of the tab title and of its key label.
const tab_pt = 11;
const key_pt = 10;

pub const Formats = struct {
    dpi: u32,
    /// Leading, vertically centred, no wrap, ellipsis trimming.
    title: *dwrite.IDWriteTextFormat,
    /// A tab title: centred, no wrap, ellipsis trimming.
    tab: *dwrite.IDWriteTextFormat,
    /// The key label of a tab: trailing.
    key: *dwrite.IDWriteTextFormat,
    /// Centred glyphs.
    icons: *dwrite.IDWriteTextFormat,
    /// Centred both ways, larger; the resize overlay.
    label: *dwrite.IDWriteTextFormat,
    sign: *dwrite.IDWriteInlineObject,
    tab_sign: *dwrite.IDWriteInlineObject,

    fn deinit(self: Formats) void {
        com.release(self.tab_sign);
        com.release(self.sign);
        com.release(self.key);
        com.release(self.tab);
        com.release(self.label);
        com.release(self.icons);
        com.release(self.title);
    }
};

pub const Shared = struct {
    d2d: *d2d1.ID2D1Factory,
    dwrite: *dwrite.IDWriteFactory,
    /// Null after the device was lost, until the next paint recreates it.
    target: ?*d2d1.ID2D1DCRenderTarget,
    title_family: [*:0]const u16,
    icon_family: [*:0]const u16,
    formats: [format_slots]?Formats = @splat(null),
    next_slot: usize = 0,

    fn renderTarget(self: *Shared) !*d2d1.ID2D1DCRenderTarget {
        if (self.target) |t| return t;
        const t = try self.d2d.createDCRenderTarget(.{
            .type = .SOFTWARE,
            .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
            .dpiX = 96,
            .dpiY = 96,
        });
        self.target = t;
        return t;
    }

    fn dropTarget(self: *Shared) void {
        com.release(self.target);
        self.target = null;
    }

    fn formatsFor(self: *Shared, dpi: u32) !*const Formats {
        for (&self.formats) |*slot| {
            if (slot.*) |*f| if (f.dpi == dpi) return f;
        }

        const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
        const title = try self.dwrite.createTextFormat(self.title_family, .NORMAL, .NORMAL, .NORMAL, 12 * scale, L("en-us"));
        errdefer com.release(title);
        try title.setWordWrapping(.NO_WRAP);
        try title.setTextAlignment(.LEADING);
        try title.setParagraphAlignment(.CENTER);
        const sign = try self.dwrite.createEllipsisTrimmingSign(title);
        errdefer com.release(sign);
        try title.setTrimming(.{ .granularity = .CHARACTER }, sign);

        const tab = try self.dwrite.createTextFormat(self.title_family, .NORMAL, .NORMAL, .NORMAL, tab_pt * scale, L("en-us"));
        errdefer com.release(tab);
        try tab.setWordWrapping(.NO_WRAP);
        try tab.setTextAlignment(.CENTER);
        try tab.setParagraphAlignment(.CENTER);
        const tab_sign = try self.dwrite.createEllipsisTrimmingSign(tab);
        errdefer com.release(tab_sign);
        try tab.setTrimming(.{ .granularity = .CHARACTER }, tab_sign);

        const key = try self.dwrite.createTextFormat(self.title_family, .NORMAL, .NORMAL, .NORMAL, key_pt * scale, L("en-us"));
        errdefer com.release(key);
        try key.setWordWrapping(.NO_WRAP);
        try key.setTextAlignment(.TRAILING);
        try key.setParagraphAlignment(.CENTER);

        const icons = try self.dwrite.createTextFormat(self.icon_family, .NORMAL, .NORMAL, .NORMAL, 10 * scale, L("en-us"));
        errdefer com.release(icons);
        try icons.setWordWrapping(.NO_WRAP);
        try icons.setTextAlignment(.CENTER);
        try icons.setParagraphAlignment(.CENTER);

        const label = try self.dwrite.createTextFormat(self.title_family, .NORMAL, .NORMAL, .NORMAL, 13 * scale, L("en-us"));
        errdefer com.release(label);
        try label.setWordWrapping(.NO_WRAP);
        try label.setTextAlignment(.CENTER);
        try label.setParagraphAlignment(.CENTER);

        const slot = &self.formats[self.next_slot];
        self.next_slot = (self.next_slot + 1) % format_slots;
        if (slot.*) |old| old.deinit();
        slot.* = .{ .dpi = dpi, .title = title, .tab = tab, .key = key, .icons = icons, .label = label, .sign = sign, .tab_sign = tab_sign };
        return &slot.*.?;
    }
};

var shared_state: ?Shared = null;

/// The process-wide painter resources, created on first use. UI thread only.
pub fn shared() !*Shared {
    if (shared_state) |*s| return s;

    const d2d = try d2d1.createFactory();
    errdefer com.release(d2d);
    const dw = try dwrite.createFactory();
    errdefer com.release(dw);

    shared_state = .{
        .d2d = d2d,
        .dwrite = dw,
        .target = null,
        .title_family = pickFamily(dw, L("Segoe UI Variable Text"), L("Segoe UI")),
        .icon_family = pickFamily(dw, L("Segoe Fluent Icons"), L("Segoe MDL2 Assets")),
    };
    return &shared_state.?;
}

pub fn deinitShared() void {
    const s = &(shared_state orelse return);
    for (s.formats) |slot| if (slot) |f| f.deinit();
    s.dropTarget();
    com.release(s.dwrite);
    com.release(s.d2d);
    shared_state = null;
}

/// `preferred` if the system has that family, else `fallback`.
fn pickFamily(dw: *dwrite.IDWriteFactory, preferred: [*:0]const u16, fallback: [*:0]const u16) [*:0]const u16 {
    const fonts = dwrite.getSystemFontCollection(dw) catch return fallback;
    defer com.release(fonts);
    const exists = fonts.hasFamily(preferred) catch return fallback;
    return if (exists) preferred else fallback;
}

// -- Pure helpers ---------------------------------------------------------------

pub fn colorF(c: theme.Color) d2d1.D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

fn rectF(r: geom.Rect) d2d1.D2D1_RECT_F {
    return .{
        .left = @floatFromInt(r.x),
        .top = @floatFromInt(r.y),
        .right = @floatFromInt(r.right()),
        .bottom = @floatFromInt(r.bottom()),
    };
}

fn sameTag(a: TabStrip.Part, b: TabStrip.Part) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

/// The caption button glyph of a part.
pub fn captionGlyph(part: TabStrip.Part, maximized: bool) []const u16 {
    return switch (part) {
        .minimize => glyph_minimize,
        .maximize => if (maximized) glyph_restore else glyph_maximize,
        else => glyph_close,
    };
}

/// The fill of a caption button, null when it is idle.
pub fn captionFill(pal: theme.Palette, part: TabStrip.Part, hover: TabStrip.Part, pressed: TabStrip.Part) ?theme.Color {
    const is_pressed = sameTag(pressed, part);
    const is_hover = sameTag(hover, part);
    if (!is_pressed and !is_hover) return null;
    if (part == .close) {
        var c = pal.close_hover_bg;
        if (is_pressed) c.a = 0xCC;
        return c;
    }
    return if (is_pressed) pal.button_pressed_bg else pal.button_hover_bg;
}

/// The glyph colour of a caption button.
pub fn captionInk(pal: theme.Palette, part: TabStrip.Part, hover: TabStrip.Part, pressed: TabStrip.Part, window_active: bool) theme.Color {
    if (part == .close and (sameTag(hover, part) or sameTag(pressed, part))) return pal.close_hover_text;
    return if (window_active) pal.text else pal.text_inactive;
}

/// Where the pieces of one tab go. The tab rect `r` is its slot in the
/// track, the full height of the track.
pub const TabParts = struct {
    /// The filled shape: a capsule inset from the slot, so that neighbours
    /// and the track's edge stay apart from it.
    chip: geom.Rect,
    bell: ?geom.Rect,
    /// The title, centred on the tab with room for the key label on both sides.
    title: geom.Rect,
    /// Where the key label goes (right aligned), absent on narrow tabs.
    key: ?geom.Rect,
    /// The close button, over the key label while the tab is hovered.
    close: ?geom.Rect,
};

pub fn tabParts(r: geom.Rect, dpi: u32, show_close: bool, bell: bool) TabParts {
    const m = TabStrip.Metrics.forDpi(dpi);
    const inset = m.pill_inset;
    const chip: geom.Rect = .{ .x = r.x + inset, .y = r.y + inset, .w = @max(r.w - 2 * inset, 0), .h = @max(r.h - 2 * inset, 0) };
    // As in `TabStrip.Layout.hitTest`: a close button needs a wide tab.
    const wide = r.w >= 2 * m.close_w;
    const close: ?geom.Rect = if (show_close and wide)
        .{ .x = r.right() - m.close_w, .y = r.y, .w = m.close_w, .h = r.h }
    else
        null;
    const side = if (wide) geom.scale(key_zone, dpi) else m.tab_pad;
    var left = r.x + side;
    var bell_rect: ?geom.Rect = null;
    if (bell) {
        const bw = geom.scale(16, dpi);
        bell_rect = .{ .x = left, .y = r.y, .w = bw, .h = r.h };
        left += bw + geom.scale(4, dpi);
    }
    const key_pad = geom.scale(10, dpi);
    return .{
        .chip = chip,
        .bell = bell_rect,
        .title = .{ .x = left, .y = r.y, .w = @max(r.right() - side - left, 0), .h = r.h },
        .key = if (wide) .{ .x = r.right() - geom.scale(key_zone, dpi), .y = r.y, .w = geom.scale(key_zone, dpi) - key_pad, .h = r.h } else null,
        .close = close,
    };
}

/// Width in DIP reserved at each side of a wide tab's title for the key
/// label ("Ctrl+1") and the close button.
const key_zone = 48;

/// The font of the window title.
pub const title_font: Font = .{ .size_pt = 12 };

/// Text of at most `buf.len` UTF-16 units; cuts the input at a code point.
pub fn toWide(buf: []u16, s: []const u8) []const u16 {
    return toUtf16(buf, s);
}

fn toUtf16(buf: []u16, s: []const u8) []const u16 {
    var len = @min(s.len, buf.len);
    while (true) : (len -= 1) {
        if (std.unicode.utf8ToUtf16Le(buf, s[0..len])) |n| return buf[0..n] else |_| {}
        if (len == 0) return buf[0..0];
    }
}

// -- Painter --------------------------------------------------------------------

/// The longest key label ("Ctrl+Shift+Alt+Page Down" is never a goto_tab).
pub const key_cap = 24;

pub const TabView = struct {
    title: []const u8,
    bell: bool = false,
    /// The label of the `goto_tab:N` key of this tab; empty when unbound.
    key: []const u8 = "",
};

/// A tab that is shrinking away after it was closed (`tab_anim.zig`).
pub const ClosingView = struct {
    rect: geom.Rect,
    title: []const u8,
};

pub const DragView = struct {
    index: usize,
    /// Left edge of the dragged tab, strip coordinates.
    x: i32,
};

pub const Inputs = struct {
    layout: *const TabStrip.Layout,
    palette: theme.Palette,
    dpi: u32,
    tabs: []const TabView = &.{},
    /// Where each tab is painted, when it is not where the layout put it
    /// (an animation under way); parallel to `tabs`.
    rects: ?[]const geom.Rect = null,
    closing: []const ClosingView = &.{},
    active: usize = 0,
    hover: TabStrip.Part = .nowhere,
    pressed: TabStrip.Part = .nowhere,
    maximized: bool = false,
    window_active: bool = true,
    /// The window title, shown in the `title_text` rect.
    title: []const u8 = "",
    drop_index: ?usize = null,
    drag: ?DragView = null,
    /// Offset of the tab row while it slides in or out (0 at rest, up to
    /// -`tab_h` when it is gone).
    row_dy: i32 = 0,
};

const Painter = struct {
    rt: *d2d1.ID2D1RenderTarget,
    brush: *d2d1.ID2D1SolidColorBrush,
    dw: *dwrite.IDWriteFactory,
    fm: *const Formats,
    pal: theme.Palette,
    dpi: u32,
    /// Added to every y: the tab row while it slides.
    dy: i32 = 0,

    fn shifted(self: *const Painter, r: geom.Rect) geom.Rect {
        var out = r;
        out.y += self.dy;
        return out;
    }

    fn fill(self: *Painter, r: geom.Rect, c: theme.Color) void {
        self.brush.setColor(colorF(c));
        self.rt.fillRectangle(rectF(self.shifted(r)), self.brush.asBrush());
    }

    fn fillRound(self: *Painter, r: geom.Rect, radius: i32, c: theme.Color) void {
        self.brush.setColor(colorF(c));
        const rad: f32 = @floatFromInt(radius);
        self.rt.fillRoundedRectangle(.{ .rect = rectF(self.shifted(r)), .radiusX = rad, .radiusY = rad }, self.brush.asBrush());
    }

    /// A full-height capsule (a circle for a square rect).
    fn fillCapsule(self: *Painter, r: geom.Rect, c: theme.Color) void {
        self.fillRound(r, @divTrunc(@min(r.w, r.h), 2), c);
    }

    /// The outline of a capsule, 1 px, drawn inside `r`.
    fn strokeCapsule(self: *Painter, rect: geom.Rect, c: theme.Color) void {
        const r = self.shifted(rect);
        self.brush.setColor(colorF(c));
        const rad: f32 = @as(f32, @floatFromInt(@min(r.w, r.h))) / 2 - 0.5;
        self.rt.drawRoundedRectangle(.{
            .rect = .{
                .left = @as(f32, @floatFromInt(r.x)) + 0.5,
                .top = @as(f32, @floatFromInt(r.y)) + 0.5,
                .right = @as(f32, @floatFromInt(r.right())) - 0.5,
                .bottom = @as(f32, @floatFromInt(r.bottom())) - 0.5,
            },
            .radiusX = rad,
            .radiusY = rad,
        }, self.brush.asBrush(), 1);
    }

    fn drawText(self: *Painter, rect: geom.Rect, text: []const u16, format: *dwrite.IDWriteTextFormat, c: theme.Color) void {
        const r = self.shifted(rect);
        if (r.w <= 0 or r.h <= 0 or text.len == 0) return;
        const layout = self.dw.createTextLayout(text, format, @floatFromInt(r.w), @floatFromInt(r.h)) catch return;
        defer com.release(layout);
        self.brush.setColor(colorF(c));
        self.rt.drawTextLayout(
            .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y) },
            layout,
            self.brush.asBrush(),
            d2d1.DRAW_TEXT_OPTIONS_CLIP,
        );
    }

    fn glyph(self: *Painter, r: geom.Rect, g: []const u16, c: theme.Color) void {
        self.drawText(r, g, self.fm.icons, c);
    }

    fn label(self: *Painter, r: geom.Rect, utf8: []const u8, format: *dwrite.IDWriteTextFormat, c: theme.Color) void {
        var buf: [256]u16 = undefined;
        self.drawText(r, toUtf16(&buf, utf8), format, c);
    }

    fn drawTab(
        self: *Painter,
        r: geom.Rect,
        view: TabView,
        active: bool,
        hovered: bool,
        close_hovered: bool,
        window_active: bool,
    ) void {
        const parts = tabParts(r, self.dpi, hovered, view.bell);
        if (parts.chip.w <= 0 or parts.chip.h <= 0) return;
        if (active) {
            self.fillCapsule(parts.chip, self.pal.pill_bg);
            // A light pill (the window over the grey track) needs an edge.
            if (self.pal.pill_bg.a >= 0x80) self.strokeCapsule(parts.chip, self.pal.outline);
        } else if (hovered) {
            self.fillCapsule(parts.chip, self.pal.tab_hover_bg);
        }
        // Like macOS the selected tab reads in the primary colour, the others
        // in the secondary one; an inactive window dims them all.
        const ink = if (active and window_active) self.pal.text else self.pal.text_inactive;
        if (parts.bell) |b| self.glyph(b, glyph_bell, ink);
        self.label(parts.title, view.title, self.fm.tab, ink);
        if (parts.close) |c| {
            const d = @min(c.w, c.h) - 2 * geom.scale(5, self.dpi);
            if (close_hovered) {
                self.fillCapsule(.{
                    .x = c.x + @divTrunc(c.w - d, 2),
                    .y = c.y + @divTrunc(c.h - d, 2),
                    .w = d,
                    .h = d,
                }, self.pal.button_hover_bg);
            }
            self.glyph(c, glyph_close, ink);
        } else if (view.key.len > 0) {
            if (parts.key) |k| self.label(k, view.key, self.fm.key, self.pal.text_dim);
        }
    }

    fn drawNewTab(self: *Painter, r: geom.Rect, hovered: bool, pressed: bool) void {
        self.fillCapsule(r, self.pal.track_bg);
        if (pressed) self.fillCapsule(r, self.pal.button_pressed_bg) else if (hovered) self.fillCapsule(r, self.pal.button_hover_bg);
        self.strokeCapsule(r, self.pal.outline);
        self.glyph(r, glyph_new_tab, self.pal.text);
    }

    fn drawButton(self: *Painter, r: geom.Rect, g: []const u16, fill_color: ?theme.Color, ink: theme.Color) void {
        if (fill_color) |c| self.fill(r, c);
        self.glyph(r, g, ink);
    }

    fn rectAt(in: Inputs, i: usize) geom.Rect {
        if (in.rects) |rs| if (i < rs.len) return rs[i];
        return in.layout.tabs.items[i];
    }

    fn tabCount(in: Inputs) usize {
        return if (in.rects) |rs| @min(rs.len, in.layout.tabs.items.len) else in.layout.tabs.items.len;
    }

    fn drawStrip(self: *Painter, in: Inputs) void {
        const lay = in.layout;

        if (lay.show_tabs) {
            // The row slides: everything in it moves, and is cut at its edge.
            const sliding = in.row_dy != 0;
            if (sliding) {
                self.rt.pushAxisAlignedClip(rectF(lay.tab_row), .ALIASED);
                self.dy = in.row_dy;
            }
            self.fillCapsule(lay.track, self.pal.track_bg);
            self.rt.pushAxisAlignedClip(rectF(self.shifted(lay.clip)), .ALIASED);
            const n = tabCount(in);

            // Thin lines between tabs, none next to the selected or a hovered one.
            const sep_w = @max(geom.scale(1, self.dpi), 1);
            const sep_inset = geom.scale(7, self.dpi);
            var i: usize = 0;
            while (i + 1 < n) : (i += 1) {
                if (i == in.active or i + 1 == in.active) continue;
                if (hoveredTab(in.hover, i) or hoveredTab(in.hover, i + 1)) continue;
                if (in.drag) |d| if (d.index == i or d.index == i + 1) continue;
                const a = rectAt(in, i);
                self.fill(.{ .x = a.right() - @divTrunc(sep_w, 2), .y = a.y + sep_inset, .w = sep_w, .h = @max(a.h - 2 * sep_inset, 0) }, self.pal.separator);
            }

            for (in.closing) |c| {
                self.drawTab(c.rect, .{ .title = c.title }, false, false, false, in.window_active);
            }
            i = 0;
            while (i < n) : (i += 1) {
                if (in.drag) |d| if (d.index == i) continue;
                self.drawTabAt(in, i, rectAt(in, i));
            }
            if (in.drag) |d| {
                if (d.index < n) {
                    var r = rectAt(in, d.index);
                    r.x = d.x;
                    self.drawTabAt(in, d.index, r);
                }
            }
            if (in.drop_index) |idx| self.drawDropMarker(lay, idx);
            self.rt.popAxisAlignedClip();

            if (lay.new_tab) |r| {
                self.drawNewTab(r, sameTag(in.hover, .new_tab), sameTag(in.pressed, .new_tab));
            }
            if (sliding) {
                self.rt.popAxisAlignedClip();
                self.dy = 0;
            }
        }

        if (lay.title_text.w > 0) {
            const ink = if (in.window_active) self.pal.text else self.pal.text_inactive;
            self.label(lay.title_text, in.title, self.fm.title, ink);
        }

        const parts = [_]struct { rect: ?geom.Rect, part: TabStrip.Part }{
            .{ .rect = lay.minimize, .part = .minimize },
            .{ .rect = lay.maximize, .part = .maximize },
            .{ .rect = lay.close, .part = .close },
        };
        for (parts) |p| {
            const r = p.rect orelse continue;
            self.drawButton(
                r,
                captionGlyph(p.part, in.maximized),
                captionFill(self.pal, p.part, in.hover, in.pressed),
                captionInk(self.pal, p.part, in.hover, in.pressed, in.window_active),
            );
        }
    }

    fn hoveredTab(hover: TabStrip.Part, i: usize) bool {
        return switch (hover) {
            .tab, .tab_close => |h| h == i,
            else => false,
        };
    }

    fn drawTabAt(self: *Painter, in: Inputs, i: usize, r: geom.Rect) void {
        const view: TabView = if (i < in.tabs.len) in.tabs[i] else .{ .title = "" };
        const close_hovered = switch (in.hover) {
            .tab_close => |h| h == i,
            else => false,
        };
        self.drawTab(r, view, i == in.active, hoveredTab(in.hover, i), close_hovered, in.window_active);
    }

    /// A 2 px bar at the insertion slot.
    fn drawDropMarker(self: *Painter, lay: *const TabStrip.Layout, idx: usize) void {
        const tabs = lay.tabs.items;
        const x = if (idx < tabs.len)
            tabs[idx].x
        else if (tabs.len > 0)
            tabs[tabs.len - 1].right()
        else
            lay.clip.x;
        const w = geom.scale(2, self.dpi);
        const inset = geom.scale(2, self.dpi);
        self.fill(.{ .x = x - @divTrunc(w, 2), .y = lay.track.y + inset, .w = w, .h = lay.track.h - 2 * inset }, self.pal.text);
    }
};

/// Runs `body` over a DC render target bound to `hdc`: clear, draw, end.
/// A lost device drops the target (the next paint recreates it).
fn withPainter(hdc: HDC, w: i32, h: i32, pal: theme.Palette, dpi: u32, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Painter) void) !void {
    const sh = try shared();
    const target = try sh.renderTarget();
    try target.bindDC(hdc, .{ .left = 0, .top = 0, .right = w, .bottom = h });
    const rt = target.asRenderTarget();
    const brush = try rt.createSolidColorBrush(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer com.release(brush);

    var painter: Painter = .{
        .rt = rt,
        .brush = brush,
        .dw = sh.dwrite,
        .fm = try sh.formatsFor(dpi),
        .pal = pal,
        .dpi = dpi,
    };

    rt.beginDraw();
    rt.setTextAntialiasMode(.GRAYSCALE);
    // Transparent black rather than a transparent colour: the target is
    // premultiplied.
    rt.clear(if (pal.strip_bg.a == 0) null else colorF(pal.strip_bg));
    body(ctx, &painter);
    rt.endDraw() catch |err| {
        if (err == error.DeviceLost) sh.dropTarget();
        return err;
    };
    if (builtin.is_test) if (test_end_draw_hr) |hr| {
        test_end_draw_hr = null;
        d2d1.checkEndDraw(hr) catch |err| {
            if (err == error.DeviceLost) sh.dropTarget();
            return err;
        };
    };
}

/// Test hook: the HRESULT the next `EndDraw` is taken to have returned.
var test_end_draw_hr: ?win32.foundation.HRESULT = null;

fn drawStripBody(in: Inputs, p: *Painter) void {
    p.drawStrip(in);
}

/// Draws the strip of `in` into `hdc`, whose origin is the strip's.
fn paintInto(hdc: HDC, size: geom.Rect, in: Inputs) !void {
    try withPainter(hdc, size.w, size.h, in.palette, in.dpi, in, drawStripBody);
}

const ChipArgs = struct { size: geom.Rect, title: []const u8, bg: theme.Color };

/// The ghost is opaque: the pill over the track over the strip's colour.
fn drawChipBody(args: ChipArgs, p: *Painter) void {
    p.pal.pill_bg = blend(p.pal.pill_bg, blend(p.pal.track_bg, args.bg));
    p.drawTab(.{ .x = 0, .y = 0, .w = args.size.w, .h = args.size.h }, .{ .title = args.title }, true, false, false, true);
}

/// One active-style tab into a premultiplied DIB (the drag ghost). False
/// when nothing was painted.
pub fn paintTabChip(hdc: HDC, size: geom.Rect, title: []const u8, palette: theme.Palette, dpi: u32) bool {
    var pal = palette;
    const bg = pal.strip_bg;
    pal.strip_bg.a = 0;
    withPainter(hdc, size.w, size.h, pal, dpi, ChipArgs{ .size = size, .title = title, .bg = .{ .r = bg.r, .g = bg.g, .b = bg.b } }, drawChipBody) catch |err| {
        logOnce(err);
        return false;
    };
    return true;
}

const LabelArgs = struct { size: geom.Rect, text: []const u16, fill: theme.Color, radius: i32 };

fn drawLabelBody(args: LabelArgs, p: *Painter) void {
    const r: geom.Rect = .{ .x = 0, .y = 0, .w = args.size.w, .h = args.size.h };
    p.fillRound(r, args.radius, args.fill);
    p.drawText(r, args.text, p.fm.label, p.pal.text);
}

/// The width of the title area of the tab at `r` when it is hovered (its
/// close button is shown), from `tabParts`.
pub fn titleAreaWidth(r: geom.Rect, dpi: u32, bell: bool) i32 {
    return tabParts(r, dpi, true, bell).title.w;
}

/// The measure of tab titles for `TabStrip.Layout.tabTrimmed`: the width
/// the strip's title font gives them and the title area `tabParts` leaves,
/// for the tabs of `window`.
pub fn titleMeasure(window: *Window) TabStrip.Measure {
    return .{ .ctx = window, .width_fn = measureTitle, .area_fn = measureArea };
}

fn measureTitle(ctx: ?*anyopaque, title: []const u8) i32 {
    const window: *const Window = @ptrCast(@alignCast(ctx.?));
    var buf: [256]u16 = undefined;
    // A title cut at the buffer is still wider than any title area.
    return measureText(toUtf16(&buf, title), .{ .size_pt = tab_pt }, window.dpi) catch 0;
}

fn measureArea(ctx: ?*anyopaque, tab: geom.Rect, index: usize) i32 {
    const window: *const Window = @ptrCast(@alignCast(ctx.?));
    const bell = index < window.tabs.items.len and
        window.app.config.@"bell-features".title and window.tabs.items[index].bellRinging();
    return titleAreaWidth(tab, window.dpi, bell);
}

/// Width in px of `text` set in the label font at `dpi`.
pub fn measureLabel(text: []const u16, dpi: u32) !i32 {
    const sh = try shared();
    const formats = try sh.formatsFor(dpi);
    const layout = try sh.dwrite.createTextLayout(text, formats.label, 4096, 256);
    defer com.release(layout);
    const metrics = try layout.getMetrics();
    return @intFromFloat(@ceil(metrics.widthIncludingTrailingWhitespace));
}

/// A centred text label on an opaque rounded fill (the resize overlay). As
/// on macOS (`RoundedRectangle(cornerRadius: 4)`) the fill is the system
/// window background (`.background`), not the terminal's; high contrast
/// keeps the system window colour. The corners stay transparent, for a
/// layered window. A lost device is retried once, a failure is logged once.
pub fn paintLabel(hdc: HDC, size: geom.Rect, text: []const u16, palette: theme.Palette, dpi: u32) !void {
    var pal = palette;
    if (theme.highContrast()) {
        pal.strip_bg = palette.tab_active_bg;
    } else {
        pal.strip_bg = if (pal.dark) .{ .r = 0x32, .g = 0x32, .b = 0x32 } else .{ .r = 0xEC, .g = 0xEC, .b = 0xEC };
        pal.text = if (pal.dark) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } else .{ .r = 0, .g = 0, .b = 0 };
    }
    var fill = pal.strip_bg;
    fill.a = 255;
    // The target is cleared to transparent, the fill is drawn on top.
    pal.strip_bg.a = 0;
    const args: LabelArgs = .{ .size = size, .text = text, .fill = fill, .radius = geom.scale(4, dpi) };
    withPainter(hdc, size.w, size.h, pal, dpi, args, drawLabelBody) catch |err| {
        if (err != error.DeviceLost) {
            logOnce(err);
            return err;
        }
        // The target was dropped: a second try builds a new one.
        withPainter(hdc, size.w, size.h, pal, dpi, args, drawLabelBody) catch |err2| {
            logOnce(err2);
            return err2;
        };
    };
}

var logged: bool = false;
/// Whether the paint after the last device loss was already re-queued.
var lost_retried: bool = false;

fn logOnce(err: anyerror) void {
    if (logged) return;
    logged = true;
    log.warn("unable to paint the chrome err={}", .{err});
}

/// GDI fill for when Direct2D failed. The buffered DIB is premultiplied and
/// GDI leaves its alpha at 0, so over Mica the fill would not show:
/// `buffer` (when `hdc` is its DC) gets its alpha set opaque.
fn fillFallback(hdc: HDC, r: geom.Rect, c: theme.Color, buffer: ?uxtheme.HPAINTBUFFER) void {
    const ref: u32 = @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
    const brush = gdi32.CreateSolidBrush(ref) orelse return;
    defer _ = gdi32.DeleteObject(@ptrCast(brush));
    const rc = r.toRECT();
    _ = gdi32.FillRect(hdc, &rc, brush);
    if (buffer) |b| _ = uxtheme.BufferedPaintSetAlpha(b, &rc, 255);
}

fn partOfHover(window: *const Window) TabStrip.Part {
    return switch (window.strip_input.hover) {
        .nowhere => window.frame.hover,
        else => |p| p,
    };
}

/// The label of the `goto_tab` key of tab `index` (0-based) in `set`, like
/// the palette writes it; empty when the tab has none.
pub fn keyLabel(set: *const input.Binding.Set, index: usize, buf: *[key_cap]u8) []const u8 {
    const trigger = set.getTrigger(.{ .goto_tab = index + 1 }) orelse return "";
    return CommandPalette.shortcutText(buf, trigger);
}

/// The tab row's offset while it slides in or out: 0 at rest, `-tab_h`
/// when it is gone.
fn rowOffset(row: f64, dpi: u32) i32 {
    const h = TabStrip.Metrics.forDpi(dpi).tab_h;
    return -@as(i32, @intFromFloat(@round((1 - std.math.clamp(row, 0, 1)) * @as(f64, @floatFromInt(h)))));
}

/// Paints the strip. Never fails visibly: on error the strip is filled with
/// the palette's colour and the error is logged once.
pub fn paint(window: *Window, hdc: HDC, dirty: geom.Rect) void {
    const lay = &window.strip;
    const bounds = lay.bounds;
    if (lay.mode == .hidden or bounds.w <= 0 or bounds.h <= 0) return;
    // The strip is bound to the buffered DC at the origin.
    std.debug.assert(bounds.x == 0 and bounds.y == 0);
    if (dirty.w > 0 and dirty.h > 0 and dirty.y >= bounds.bottom()) return;

    const pal = theme.palette(window);
    const alloc = window.app.core_app.alloc;
    const bell_title = window.app.config.@"bell-features".title;
    const n = window.tabs.items.len;

    const views = alloc.alloc(TabView, n) catch |err| {
        logOnce(err);
        fillFallback(hdc, bounds, pal.strip_bg, null);
        return;
    };
    defer alloc.free(views);
    const keys = alloc.alloc([key_cap]u8, n) catch |err| {
        logOnce(err);
        fillFallback(hdc, bounds, pal.strip_bg, null);
        return;
    };
    defer alloc.free(keys);
    for (window.tabs.items, views, keys, 0..) |tab, *view, *key, i| {
        view.* = .{
            .title = tab.title(),
            .bell = bell_title and tab.bellRinging(),
            .key = keyLabel(&window.app.config.keybind.set, i, key),
        };
    }

    // Tabs that slide are painted where the animation has them.
    const now = Window.nowNs();
    const anim = &window.tab_anim;
    const sliding = anim.running and anim.tabs.items.len == n and lay.tabs.items.len == n;
    var rects: []geom.Rect = &.{};
    var closing: []ClosingView = &.{};
    defer if (sliding) {
        alloc.free(rects);
        alloc.free(closing);
    };
    if (sliding) {
        rects = alloc.alloc(geom.Rect, n) catch &.{};
        closing = alloc.alloc(ClosingView, anim.closing.items.len) catch &.{};
        for (rects, 0..) |*r, i| r.* = anim.rectAt(i, now);
        for (closing, 0..) |*c, i| {
            const v = anim.closingAt(i, now);
            c.* = .{ .rect = v.rect, .title = v.title };
        }
    }

    var drag: ?DragView = null;
    if (window.strip_input.drag) |*d| {
        if (d.active) {
            drag = .{ .index = d.current, .x = TabStrip.dragOffset(d, lay, window.strip_input.pointer_x) };
        }
    }

    const in: Inputs = .{
        .layout = lay,
        .palette = pal,
        .dpi = window.dpi,
        .tabs = views,
        .rects = if (sliding and rects.len == n) rects else null,
        .closing = closing,
        .active = window.active_tab,
        .hover = partOfHover(window),
        .pressed = window.frame.pressed,
        .maximized = user32.IsZoomed(window.hwnd) != 0,
        .window_active = theme.windowActive(window),
        .title = window.chrome_title orelse "",
        .drop_index = window.strip_input.drop_index,
        .drag = drag,
        .row_dy = if (anim.running) rowOffset(anim.rowAt(now), window.dpi) else 0,
    };

    const rc = bounds.toRECT();
    const params: uxtheme.BP_PAINTPARAMS = .{ .dwFlags = uxtheme.BPPF_ERASE };
    var mem: ?HDC = null;
    const hbp = uxtheme.BeginBufferedPaint(hdc, &rc, uxtheme.BPBF_TOPDOWNDIB, &params, &mem);
    const target_dc = mem orelse hdc;
    if (paintInto(target_dc, bounds, in)) {
        lost_retried = false;
    } else |err| {
        logOnce(err);
        fillFallback(target_dc, bounds, pal.strip_bg, hbp);
        // A lost device is recreated by the next paint; retry once per loss,
        // a persistent failure must not re-queue paints forever.
        if (err == error.DeviceLost and !lost_retried) {
            lost_retried = true;
            invalidate(window);
        }
    }
    if (hbp) |h| _ = uxtheme.EndBufferedPaint(h, 1);
}

pub fn invalidate(window: *Window) void {
    _ = user32.InvalidateRect(window.hwnd, null, 0);
}

/// Repaints the strip only (an animation frame).
pub fn invalidateStrip(window: *Window) void {
    const rc = window.strip.bounds.toRECT();
    _ = user32.InvalidateRect(window.hwnd, &rc, 0);
}

// -- General painter ------------------------------------------------------------

/// A font for `Item.text`. `icons` selects Segoe Fluent Icons (MDL2) for
/// glyph code points, else the UI font.
pub const Font = struct {
    icons: bool = false,
    size_pt: f32 = 13,
    weight: dwrite.FontWeight = .NORMAL,
};

pub const HAlign = enum { leading, center };

/// One thing to draw, in px with the origin at the top-left of the popup.
pub const Item = union(enum) {
    /// An antialiased filled rounded rectangle (radius 0: a rectangle).
    box: struct { rect: geom.Rect, radius: i32, fill: theme.Color },
    /// The outline of a rounded rectangle, `width` px wide, drawn inside
    /// `rect`; the colour may be translucent.
    stroke: struct { rect: geom.Rect, radius: i32, width: f32, color: theme.Color },
    /// Text vertically centred in `rect`, clipped to it; with `trim` the
    /// text that does not fit ends in an ellipsis.
    text: struct {
        rect: geom.Rect,
        text: []const u16,
        font: Font = .{},
        color: theme.Color,
        halign: HAlign = .center,
        trim: bool = false,
    },
};

/// `top` composited over the opaque `bottom` (the result is opaque).
pub fn blend(top: theme.Color, bottom: theme.Color) theme.Color {
    const a: u32 = top.a;
    const inv = 255 - a;
    return .{
        .r = @intCast((@as(u32, top.r) * a + @as(u32, bottom.r) * inv + 127) / 255),
        .g = @intCast((@as(u32, top.g) * a + @as(u32, bottom.g) * inv + 127) / 255),
        .b = @intCast((@as(u32, top.b) * a + @as(u32, bottom.b) * inv + 127) / 255),
    };
}

fn makeFormat(sh: *Shared, font: Font, halign: HAlign, trim: bool, dpi: u32) !*dwrite.IDWriteTextFormat {
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    const family = if (font.icons) sh.icon_family else sh.title_family;
    const format = try sh.dwrite.createTextFormat(family, font.weight, .NORMAL, .NORMAL, font.size_pt * scale, L("en-us"));
    errdefer com.release(format);
    try format.setWordWrapping(.NO_WRAP);
    try format.setTextAlignment(if (halign == .center) .CENTER else .LEADING);
    try format.setParagraphAlignment(.CENTER);
    if (trim) {
        // The format keeps its own reference to the sign.
        const sign = try sh.dwrite.createEllipsisTrimmingSign(format);
        defer com.release(sign);
        try format.setTrimming(.{ .granularity = .CHARACTER }, sign);
    }
    return format;
}

const measure_slots = 32;
const measure_chars = 48;
const Measured = struct {
    dpi: u32 = 0,
    font: Font = .{},
    len: usize = 0,
    text: [measure_chars]u16 = undefined,
    width: i32 = 0,
};
var measured: [measure_slots]Measured = @splat(.{});
var measured_next: usize = 0;

/// Width in px of `text` in `font` at `dpi`. Short texts are remembered, so
/// a label that is painted again and again measures once.
pub fn measureText(text: []const u16, font: Font, dpi: u32) !i32 {
    const cacheable = text.len > 0 and text.len <= measure_chars;
    if (cacheable) for (&measured) |*m| {
        if (m.dpi == dpi and m.len == text.len and std.meta.eql(m.font, font) and
            std.mem.eql(u16, m.text[0..m.len], text)) return m.width;
    };

    const sh = try shared();
    const format = try makeFormat(sh, font, .leading, false, dpi);
    defer com.release(format);
    const layout = try sh.dwrite.createTextLayout(text, format, 4096, 256);
    defer com.release(layout);
    const metrics = try layout.getMetrics();
    const width: i32 = @intFromFloat(@ceil(metrics.widthIncludingTrailingWhitespace));

    if (cacheable) {
        const slot = &measured[measured_next];
        measured_next = (measured_next + 1) % measure_slots;
        slot.* = .{ .dpi = dpi, .font = font, .len = text.len, .width = width };
        @memcpy(slot.text[0..text.len], text);
    }
    return width;
}

fn drawItemsBody(items: []const Item, p: *Painter) void {
    const sh = shared() catch |err| {
        logOnce(err);
        return;
    };
    for (items) |item| switch (item) {
        .box => |b| p.fillRound(b.rect, b.radius, b.fill),
        .stroke => |s| {
            const half = s.width / 2;
            p.brush.setColor(colorF(s.color));
            p.rt.drawRoundedRectangle(.{
                .rect = .{
                    .left = @as(f32, @floatFromInt(s.rect.x)) + half,
                    .top = @as(f32, @floatFromInt(s.rect.y)) + half,
                    .right = @as(f32, @floatFromInt(s.rect.right())) - half,
                    .bottom = @as(f32, @floatFromInt(s.rect.bottom())) - half,
                },
                .radiusX = @max(@as(f32, @floatFromInt(s.radius)) - half, 0),
                .radiusY = @max(@as(f32, @floatFromInt(s.radius)) - half, 0),
            }, p.brush.asBrush(), s.width);
        },
        .text => |t| {
            const format = makeFormat(sh, t.font, t.halign, t.trim, p.dpi) catch continue;
            defer com.release(format);
            p.drawText(t.rect, t.text, format, t.color);
        },
    };
}

/// Paints `items` into `hdc` (origin at the popup's) over `background`;
/// null clears to transparent, for a label's premultiplied DIB. A lost
/// device is retried once, a failure is logged once.
pub fn paintItems(hdc: HDC, size: geom.Rect, items: []const Item, palette: theme.Palette, dpi: u32, background: ?theme.Color) !void {
    var pal = palette;
    pal.strip_bg = if (background) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 } else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    withPainter(hdc, size.w, size.h, pal, dpi, items, drawItemsBody) catch |err| {
        if (err != error.DeviceLost) {
            logOnce(err);
            return err;
        }
        withPainter(hdc, size.w, size.h, pal, dpi, items, drawItemsBody) catch |err2| {
            logOnce(err2);
            return err2;
        };
    };
}

// -- Tests ----------------------------------------------------------------------

const test_palette: theme.Palette = .{
    .dark = true,
    .mica = true,
    .strip_bg = .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0 },
    .tab_active_bg = .{ .r = 0x30, .g = 0x60, .b = 0x90 },
    .tab_hover_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x10 },
    .text = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
    .text_inactive = .{ .r = 0x9E, .g = 0x9E, .b = 0x9E },
    .button_hover_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x15 },
    .button_pressed_bg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0x0B },
    .divider = .{ .r = 0x3C, .g = 0x3C, .b = 0x3C },
};

test "win32 chrome: caption glyphs and fills" {
    try std.testing.expectEqualSlices(u16, glyph_restore, captionGlyph(.maximize, true));
    try std.testing.expectEqualSlices(u16, glyph_maximize, captionGlyph(.maximize, false));
    try std.testing.expectEqualSlices(u16, glyph_minimize, captionGlyph(.minimize, true));
    try std.testing.expectEqualSlices(u16, glyph_close, captionGlyph(.close, false));

    const pal = test_palette;
    try std.testing.expectEqual(@as(?theme.Color, null), captionFill(pal, .close, .nowhere, .nowhere));
    try std.testing.expectEqual(@as(?theme.Color, pal.close_hover_bg), captionFill(pal, .close, .close, .nowhere));
    try std.testing.expectEqual(@as(?theme.Color, pal.button_hover_bg), captionFill(pal, .minimize, .minimize, .nowhere));
    try std.testing.expectEqual(@as(?theme.Color, pal.button_pressed_bg), captionFill(pal, .maximize, .maximize, .maximize));
    try std.testing.expectEqual(pal.close_hover_text, captionInk(pal, .close, .close, .nowhere, true));
    try std.testing.expectEqual(pal.text_inactive, captionInk(pal, .minimize, .nowhere, .nowhere, false));
}

test "win32 chrome: tab parts" {
    // A slot of the track: 200 x 28 at 96 dpi.
    const r: geom.Rect = .{ .x = 100, .y = 34, .w = 200, .h = 28 };
    const plain = tabParts(r, 96, false, false);
    try std.testing.expect(plain.close == null);
    try std.testing.expect(plain.bell == null);
    // The title is centred with 48 px kept free at each side for the key
    // label and the close button.
    try std.testing.expectEqual(@as(i32, 148), plain.title.x);
    try std.testing.expectEqual(@as(i32, 104), plain.title.w);
    try std.testing.expectEqual(@as(i32, 252), plain.key.?.x);
    try std.testing.expectEqual(@as(i32, 38), plain.key.?.w);

    const full = tabParts(r, 96, true, true);
    try std.testing.expectEqual(@as(i32, 272), full.close.?.x);
    try std.testing.expectEqual(@as(i32, 148), full.bell.?.x);
    try std.testing.expectEqual(@as(i32, 168), full.title.x);
    try std.testing.expectEqual(@as(i32, 84), full.title.w);
    // The pill is the slot less 2 px all round.
    try std.testing.expectEqual(@as(i32, 102), full.chip.x);
    try std.testing.expectEqual(@as(i32, 36), full.chip.y);
    try std.testing.expectEqual(@as(i32, 24), full.chip.h);

    // Too narrow for a close button or a key label, as in `TabStrip.Layout.hitTest`.
    const narrow = tabParts(.{ .x = 0, .y = 0, .w = 55, .h = 28 }, 96, true, false);
    try std.testing.expect(narrow.close == null);
    try std.testing.expect(narrow.key == null);
    try std.testing.expectEqual(@as(i32, 10), narrow.title.x);
}

test "win32 chrome: title area for the tooltip follows tabParts" {
    const r: geom.Rect = .{ .x = 100, .y = 34, .w = 200, .h = 28 };
    try std.testing.expectEqual(tabParts(r, 96, true, false).title.w, titleAreaWidth(r, 96, false));
    try std.testing.expectEqual(@as(i32, 84), titleAreaWidth(r, 96, true));
    try std.testing.expect(titleAreaWidth(r, 96, true) < titleAreaWidth(r, 96, false));
}

test "win32 chrome: key label of goto_tab like the palette" {
    var set: input.Binding.Set = .{};
    defer set.deinit(std.testing.allocator);
    try set.put(std.testing.allocator, .{ .key = .{ .unicode = '2' }, .mods = .{ .ctrl = true } }, .{ .goto_tab = 2 });

    var buf: [key_cap]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+2", keyLabel(&set, 1, &buf));
    // Unbound: nothing.
    try std.testing.expectEqualStrings("", keyLabel(&set, 0, &buf));
}

test "win32 chrome: the tab row slides by the missing fraction" {
    try std.testing.expectEqual(@as(i32, 0), rowOffset(1, 96));
    try std.testing.expectEqual(@as(i32, -36), rowOffset(0, 96));
    try std.testing.expectEqual(@as(i32, -18), rowOffset(0.5, 96));
    try std.testing.expectEqual(@as(i32, -54), rowOffset(0, 144));
    try std.testing.expectEqual(@as(i32, 0), rowOffset(7, 96));
}

test "win32 chrome: colours and utf16 titles" {
    const c = colorF(.{ .r = 255, .g = 0, .b = 51, .a = 0 });
    try std.testing.expectEqual(@as(f32, 1.0), c.r);
    try std.testing.expectEqual(@as(f32, 0.2), c.b);
    try std.testing.expectEqual(@as(f32, 0.0), c.a);

    var buf: [4]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 4), toUtf16(&buf, "abcdef").len);
    // The cut must not split the two-byte code point.
    try std.testing.expectEqual(@as(usize, 3), toUtf16(&buf, "abc\u{0436}\u{0436}").len);
}

test "win32 chrome: paints a strip into a DIB" {
    const alloc = std.testing.allocator;
    const width = 600;
    const height = 66;

    var layout: TabStrip.Layout = .{};
    defer layout.deinit(alloc);
    try layout.compute(alloc, TabStrip.Metrics.forDpi(96), width, .titlebar, true, 2, 0);
    const tab0 = layout.tabs.items[0];
    const close_rect = tabParts(tab0, 96, true, false).close.?;

    const dc = gdi32.CreateCompatibleDC(null) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteDC(dc);
    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = width,
        .biHeight = -height,
        .biBitCount = 32,
    } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };
    const pixels: [*]const [4]u8 = @ptrCast(bits.?);
    defer deinitShared();

    var pal = test_palette;
    pal.strip_bg = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    pal.pill_bg = .{ .r = 0x30, .g = 0x60, .b = 0x90 };
    const views = [_]TabView{ .{ .title = "one" }, .{ .title = "two" } };
    const size: geom.Rect = .{ .x = 0, .y = 0, .w = width, .h = height };
    var in: Inputs = .{
        .layout = &layout,
        .palette = pal,
        .dpi = 96,
        .tabs = &views,
        .active = 0,
        .hover = .{ .tab = 0 },
    };
    try paintInto(dc, size, in);

    // One background everywhere the chrome does not draw: the title row, the
    // margin of the tab row.
    try std.testing.expectEqual([4]u8{ 0x30, 0x20, 0x10, 0xFF }, pixels[10 * width + 200]);
    try std.testing.expectEqual([4]u8{ 0x30, 0x20, 0x10, 0xFF }, pixels[48 * width + 2]);
    // Active tab body: the opaque pill (BGRA), on the tab row.
    const mid_x: usize = @intCast(tab0.x + @divTrunc(tab0.w, 2));
    try std.testing.expectEqual([4]u8{ 0x90, 0x60, 0x30, 0xFF }, pixels[40 * width + mid_x]);
    // The track shows between the pill and the row's edge as a lighter strip.
    const track_px = pixels[35 * width + mid_x];
    try std.testing.expect(track_px[0] > 0x30 and track_px[3] == 0xFF);
    // The close glyph left ink on the hovered tab.
    var inked = false;
    var y: usize = 34;
    while (y < 62) : (y += 1) {
        var x: usize = @intCast(close_rect.x);
        while (x < close_rect.right()) : (x += 1) {
            if (!std.mem.eql(u8, &pixels[y * width + x], &.{ 0x90, 0x60, 0x30, 0xFF })) inked = true;
        }
    }
    try std.testing.expect(inked);

    // Sliding out by the full row: the tab row's area is the plain background.
    in.row_dy = -36;
    try paintInto(dc, size, in);
    try std.testing.expectEqual([4]u8{ 0x30, 0x20, 0x10, 0xFF }, pixels[40 * width + mid_x]);
}

test "win32 chrome: shared target recreated after RECREATE_TARGET" {
    const width = 120;
    const height = 40;
    const dc = gdi32.CreateCompatibleDC(null) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteDC(dc);
    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height, .biBitCount = 32 } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };
    defer deinitShared();

    const text = L("80 x 24");
    const size: geom.Rect = .{ .x = 0, .y = 0, .w = width, .h = height };
    try paintLabel(dc, size, text, test_palette, 96);
    try std.testing.expect((try shared()).target != null);

    // EndDraw reports D2DERR_RECREATE_TARGET: the target is dropped, and
    // `paintLabel` retries once with a new one.
    test_end_draw_hr = d2d1.D2DERR_RECREATE_TARGET;
    try paintLabel(dc, size, text, test_palette, 96);
    try std.testing.expect(test_end_draw_hr == null);
    try std.testing.expect((try shared()).target != null);

    // The strip painter has no retry of its own: the first paint fails with
    // DeviceLost and the target is gone, the second one succeeds.
    var layout: TabStrip.Layout = .{};
    defer layout.deinit(std.testing.allocator);
    try layout.compute(std.testing.allocator, TabStrip.Metrics.forDpi(96), width, .titlebar, true, 1, 0);
    const in: Inputs = .{ .layout = &layout, .palette = test_palette, .dpi = 96 };
    test_end_draw_hr = d2d1.D2DERR_RECREATE_TARGET;
    try std.testing.expectError(error.DeviceLost, paintInto(dc, size, in));
    try std.testing.expect((try shared()).target == null);
    try paintInto(dc, size, in);
    try std.testing.expect((try shared()).target != null);
}

test "win32 chrome: blend over an opaque colour" {
    const white: theme.Color = .{ .r = 255, .g = 255, .b = 255 };
    const black: theme.Color = .{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqual(white, blend(.{ .r = 255, .g = 255, .b = 255, .a = 255 }, black));
    try std.testing.expectEqual(black, blend(.{ .r = 255, .g = 255, .b = 255, .a = 0 }, black));
    const half = blend(.{ .r = 255, .g = 255, .b = 255, .a = 128 }, black);
    try std.testing.expectEqual(@as(u8, 128), half.r);
}
