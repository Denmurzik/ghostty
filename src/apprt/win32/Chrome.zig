//! Painter of the tab strip and the caption buttons: Direct2D drawing and
//! DirectWrite text into a buffered-paint DC (premultiplied 32bpp DIB), so
//! that the Mica backdrop shows through the transparent parts of the strip.
//!
//! One D2D factory, one DirectWrite factory and one DC render target per
//! process, all used from the UI thread only. The target is drawn at 96 DPI
//! in pixels; text formats are cached per window DPI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");
const geom = @import("geom.zig");
const theme = @import("theme.zig");

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

pub const Formats = struct {
    dpi: u32,
    /// Leading, vertically centred, no wrap, ellipsis trimming.
    title: *dwrite.IDWriteTextFormat,
    /// Centred glyphs.
    icons: *dwrite.IDWriteTextFormat,
    /// Centred both ways, larger; the resize overlay.
    label: *dwrite.IDWriteTextFormat,
    sign: *dwrite.IDWriteInlineObject,

    fn deinit(self: Formats) void {
        com.release(self.sign);
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
        slot.* = .{ .dpi = dpi, .title = title, .icons = icons, .label = label, .sign = sign };
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

/// Where the pieces of one tab go.
pub const TabParts = struct {
    /// The filled shape; the active tab's reaches below the strip so only
    /// its top corners are rounded.
    chip: geom.Rect,
    bell: ?geom.Rect,
    title: geom.Rect,
    close: ?geom.Rect,
};

pub fn tabParts(r: geom.Rect, dpi: u32, active: bool, show_close: bool, bell: bool) TabParts {
    const m = TabStrip.Metrics.forDpi(dpi);
    const top = geom.scale(if (active) 6 else 4, dpi);
    const chip: geom.Rect = .{
        .x = r.x,
        .y = top,
        .w = r.w,
        .h = if (active) r.h - top else r.h - 2 * top,
    };
    const close: ?geom.Rect = if (show_close and r.w >= 2 * m.close_w)
        .{ .x = r.right() - m.close_w, .y = 0, .w = m.close_w, .h = r.h }
    else
        null;
    const right = if (close) |c| c.x else r.right() - m.tab_pad;
    var left = r.x + m.tab_pad;
    var bell_rect: ?geom.Rect = null;
    if (bell) {
        const bw = geom.scale(16, dpi);
        bell_rect = .{ .x = left, .y = 0, .w = bw, .h = r.h };
        left += bw + geom.scale(4, dpi);
    }
    return .{
        .chip = chip,
        .bell = bell_rect,
        .title = .{ .x = left, .y = 0, .w = @max(right - left, 0), .h = r.h },
        .close = close,
    };
}

/// Text of at most `buf.len` UTF-16 units; cuts the input at a code point.
fn toUtf16(buf: []u16, s: []const u8) []const u16 {
    var len = @min(s.len, buf.len);
    while (true) : (len -= 1) {
        if (std.unicode.utf8ToUtf16Le(buf, s[0..len])) |n| return buf[0..n] else |_| {}
        if (len == 0) return buf[0..0];
    }
}

// -- Painter --------------------------------------------------------------------

pub const TabView = struct {
    title: []const u8,
    bell: bool = false,
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
    active: usize = 0,
    hover: TabStrip.Part = .nowhere,
    pressed: TabStrip.Part = .nowhere,
    maximized: bool = false,
    window_active: bool = true,
    /// Shown in the `title` rect (tabs hidden).
    title: []const u8 = "",
    drop_index: ?usize = null,
    drag: ?DragView = null,
};

const Painter = struct {
    rt: *d2d1.ID2D1RenderTarget,
    brush: *d2d1.ID2D1SolidColorBrush,
    dw: *dwrite.IDWriteFactory,
    fm: *const Formats,
    pal: theme.Palette,
    dpi: u32,

    fn fill(self: *Painter, r: geom.Rect, c: theme.Color) void {
        self.brush.setColor(colorF(c));
        self.rt.fillRectangle(rectF(r), self.brush.asBrush());
    }

    fn fillRound(self: *Painter, r: geom.Rect, radius: i32, c: theme.Color) void {
        self.brush.setColor(colorF(c));
        const rad: f32 = @floatFromInt(radius);
        self.rt.fillRoundedRectangle(.{ .rect = rectF(r), .radiusX = rad, .radiusY = rad }, self.brush.asBrush());
    }

    fn drawText(self: *Painter, r: geom.Rect, text: []const u16, format: *dwrite.IDWriteTextFormat, c: theme.Color) void {
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

    fn title(self: *Painter, r: geom.Rect, utf8: []const u8, c: theme.Color) void {
        var buf: [256]u16 = undefined;
        self.drawText(r, toUtf16(&buf, utf8), self.fm.title, c);
    }

    fn drawTab(
        self: *Painter,
        r: geom.Rect,
        view: TabView,
        active: bool,
        hovered: bool,
        close_hovered: bool,
        show_close: bool,
    ) void {
        const parts = tabParts(r, self.dpi, active, show_close, view.bell);
        const radius = geom.scale(6, self.dpi);
        if (active) {
            self.fillRound(parts.chip, radius, self.pal.tab_active_bg);
        } else if (hovered) {
            self.fillRound(parts.chip, radius, self.pal.tab_hover_bg);
        }
        const ink = if (active or hovered) self.pal.text else self.pal.text_inactive;
        if (parts.bell) |b| self.glyph(b, glyph_bell, ink);
        self.title(parts.title, view.title, ink);
        if (parts.close) |c| {
            if (close_hovered) {
                const inset = geom.scale(4, self.dpi);
                self.fillRound(.{ .x = c.x + inset, .y = geom.scale(8, self.dpi), .w = c.w - 2 * inset, .h = c.h - 2 * geom.scale(8, self.dpi) }, radius, self.pal.button_hover_bg);
            }
            self.glyph(c, glyph_close, ink);
        }
    }

    fn drawButton(self: *Painter, r: geom.Rect, g: []const u16, fill_color: ?theme.Color, ink: theme.Color, chip: bool) void {
        if (fill_color) |c| {
            if (chip) {
                const inset = geom.scale(4, self.dpi);
                self.fillRound(.{ .x = r.x + inset, .y = r.y + inset, .w = r.w - 2 * inset, .h = r.h - 2 * inset }, geom.scale(6, self.dpi), c);
            } else {
                self.fill(r, c);
            }
        }
        self.glyph(r, g, ink);
    }

    fn drawStrip(self: *Painter, in: Inputs) void {
        const lay = in.layout;

        if (lay.show_tabs) {
            self.rt.pushAxisAlignedClip(rectF(lay.clip), .ALIASED);
            for (lay.tabs.items, 0..) |r, i| {
                if (in.drag) |d| if (d.index == i) continue;
                self.drawTabAt(in, i, r);
            }
            if (in.drag) |d| {
                if (d.index < lay.tabs.items.len) {
                    var r = lay.tabs.items[d.index];
                    r.x = d.x;
                    self.drawTabAt(in, d.index, r);
                }
            }
            if (in.drop_index) |idx| self.drawDropMarker(lay, idx);
            self.rt.popAxisAlignedClip();
        }

        if (lay.new_tab) |r| {
            const hovered = sameTag(in.hover, .new_tab);
            const pressed = sameTag(in.pressed, .new_tab);
            const fill_color: ?theme.Color = if (pressed) self.pal.button_pressed_bg else if (hovered) self.pal.button_hover_bg else null;
            self.drawButton(r, glyph_new_tab, fill_color, self.pal.text, true);
        }

        if (lay.title) |r| {
            const ink = if (in.window_active) self.pal.text else self.pal.text_inactive;
            self.title(r, in.title, ink);
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
                false,
            );
        }
    }

    fn drawTabAt(self: *Painter, in: Inputs, i: usize, r: geom.Rect) void {
        const view: TabView = if (i < in.tabs.len) in.tabs[i] else .{ .title = "" };
        const active = i == in.active;
        const hovered = switch (in.hover) {
            .tab, .tab_close => |h| h == i,
            else => false,
        };
        const close_hovered = switch (in.hover) {
            .tab_close => |h| h == i,
            else => false,
        };
        self.drawTab(r, view, active, hovered, close_hovered, active or hovered);
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
        const inset = geom.scale(6, self.dpi);
        self.fill(.{ .x = x - @divTrunc(w, 2), .y = inset, .w = w, .h = lay.bounds.h - 2 * inset }, self.pal.text);
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
}

fn drawStripBody(in: Inputs, p: *Painter) void {
    p.drawStrip(in);
}

/// Draws the strip of `in` into `hdc`, whose origin is the strip's.
fn paintInto(hdc: HDC, size: geom.Rect, in: Inputs) !void {
    try withPainter(hdc, size.w, size.h, in.palette, in.dpi, in, drawStripBody);
}

const ChipArgs = struct { size: geom.Rect, title: []const u8 };

fn drawChipBody(args: ChipArgs, p: *Painter) void {
    p.drawTab(.{ .x = 0, .y = 0, .w = args.size.w, .h = args.size.h }, .{ .title = args.title }, true, false, false, false);
}

/// One active-style tab into a premultiplied DIB (the drag ghost). False
/// when nothing was painted.
pub fn paintTabChip(hdc: HDC, size: geom.Rect, title: []const u8, palette: theme.Palette, dpi: u32) bool {
    withPainter(hdc, size.w, size.h, palette, dpi, ChipArgs{ .size = size, .title = title }, drawChipBody) catch |err| {
        logOnce(err);
        return false;
    };
    return true;
}

const LabelArgs = struct { size: geom.Rect, text: []const u16, pal: theme.Palette };

fn drawLabelBody(args: LabelArgs, p: *Painter) void {
    p.drawText(.{ .x = 0, .y = 0, .w = args.size.w, .h = args.size.h }, args.text, p.fm.label, args.pal.text);
}

/// A centred text label on an opaque fill (the resize overlay). As on macOS
/// the fill is the system window background (`.background`), not the
/// terminal's; high contrast keeps the system window colour.
pub fn paintLabel(hdc: HDC, size: geom.Rect, text: []const u16, palette: theme.Palette, dpi: u32) !void {
    var pal = palette;
    if (theme.highContrast()) {
        pal.strip_bg = palette.tab_active_bg;
    } else {
        pal.strip_bg = if (pal.dark) .{ .r = 0x32, .g = 0x32, .b = 0x32 } else .{ .r = 0xEC, .g = 0xEC, .b = 0xEC };
        pal.text = if (pal.dark) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } else .{ .r = 0, .g = 0, .b = 0 };
    }
    pal.strip_bg.a = 255;
    try withPainter(hdc, size.w, size.h, pal, dpi, LabelArgs{ .size = size, .text = text, .pal = pal }, drawLabelBody);
}

var logged: bool = false;
/// Whether the paint after the last device loss was already re-queued.
var lost_retried: bool = false;

fn logOnce(err: anyerror) void {
    if (logged) return;
    logged = true;
    log.warn("unable to paint the chrome err={}", .{err});
}

fn fillFallback(hdc: HDC, r: geom.Rect, c: theme.Color) void {
    const ref: u32 = @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
    const brush = gdi32.CreateSolidBrush(ref) orelse return;
    defer _ = gdi32.DeleteObject(@ptrCast(brush));
    const rc = r.toRECT();
    _ = gdi32.FillRect(hdc, &rc, brush);
}

fn partOfHover(window: *const Window) TabStrip.Part {
    return switch (window.strip_input.hover) {
        .nowhere => window.frame.hover,
        else => |p| p,
    };
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

    const views = alloc.alloc(TabView, window.tabs.items.len) catch |err| {
        logOnce(err);
        fillFallback(hdc, bounds, pal.strip_bg);
        return;
    };
    defer alloc.free(views);
    for (window.tabs.items, views) |tab, *view| {
        view.* = .{ .title = tab.title(), .bell = bell_title and tab.bellRinging() };
    }

    var drag: ?DragView = null;
    if (window.strip_input.drag) |*d| {
        if (d.active) {
            drag = .{ .index = d.current, .x = TabStrip.dragOffset(d, lay, window.strip_input.pointer_x) };
        }
    }

    const title: []const u8 = if (window.title_override) |t|
        t
    else if (window.activeTab()) |tab|
        tab.title()
    else
        "";

    const in: Inputs = .{
        .layout = lay,
        .palette = pal,
        .dpi = window.dpi,
        .tabs = views,
        .active = window.active_tab,
        .hover = partOfHover(window),
        .pressed = window.frame.pressed,
        .maximized = user32.IsZoomed(window.hwnd) != 0,
        .window_active = if (user32.GetForegroundWindow()) |fg| fg == window.hwnd else false,
        .title = title,
        .drop_index = window.strip_input.drop_index,
        .drag = drag,
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
        fillFallback(target_dc, bounds, pal.strip_bg);
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
    const r: geom.Rect = .{ .x = 100, .y = 0, .w = 200, .h = 40 };
    const plain = tabParts(r, 96, false, false, false);
    try std.testing.expect(plain.close == null);
    try std.testing.expect(plain.bell == null);
    try std.testing.expectEqual(@as(i32, 110), plain.title.x);
    try std.testing.expectEqual(@as(i32, 180), plain.title.w);

    const full = tabParts(r, 96, true, true, true);
    try std.testing.expectEqual(@as(i32, 272), full.close.?.x);
    try std.testing.expectEqual(@as(i32, 110), full.bell.?.x);
    try std.testing.expectEqual(@as(i32, 130), full.title.x);
    try std.testing.expectEqual(@as(i32, 142), full.title.w);
    // The active chip reaches the strip's bottom edge.
    try std.testing.expectEqual(@as(i32, 40), full.chip.bottom());

    // Too narrow for a close button, as in `TabStrip.Layout.hitTest`.
    const narrow = tabParts(.{ .x = 0, .y = 0, .w = 55, .h = 40 }, 96, true, true, false);
    try std.testing.expect(narrow.close == null);
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
    const height = 40;

    var layout: TabStrip.Layout = .{};
    defer layout.deinit(alloc);
    try layout.compute(alloc, TabStrip.Metrics.forDpi(96), width, .titlebar, true, 2, 0);
    const tab0 = layout.tabs.items[0];
    const close_rect = tabParts(tab0, 96, true, true, false).close.?;

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

    const views = [_]TabView{ .{ .title = "one" }, .{ .title = "two" } };
    try paintInto(dc, .{ .x = 0, .y = 0, .w = width, .h = height }, .{
        .layout = &layout,
        .palette = test_palette,
        .dpi = 96,
        .tabs = &views,
        .active = 0,
    });

    // Active tab body: opaque tab_active_bg (BGRA).
    const mid_x: usize = @intCast(tab0.x + @divTrunc(tab0.w, 2));
    try std.testing.expectEqual([4]u8{ 0x90, 0x60, 0x30, 0xFF }, pixels[8 * width + mid_x]);
    // Left of the first tab the Mica shows through.
    try std.testing.expectEqual(@as(u8, 0), pixels[20 * width + 2][3]);
    // The close glyph left ink on the active tab.
    var inked = false;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = @intCast(close_rect.x);
        while (x < close_rect.right()) : (x += 1) {
            if (!std.mem.eql(u8, &pixels[y * width + x], &.{ 0x90, 0x60, 0x30, 0xFF })) inked = true;
        }
    }
    try std.testing.expect(inked);
}
