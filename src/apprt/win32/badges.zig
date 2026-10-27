//! Surface badges: read-only and renderer health, and `TextLabel`, the
//! label popup the status overlays (key state, toasts) share.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const renderer = @import("../../renderer.zig");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const geom = @import("geom.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.win32_badges);

/// The label shows at most this many UTF-16 units.
pub const label_units = 256;

/// Sizes at 96 DPI, from macOS `URLHoverBanner`: 5 pt padding all round, a
/// 26 px line. `char_w` is only the guess when the text cannot be measured.
const pad_x = 5;
const char_w = 8;
const height_px = 26;
/// Gap to the surface edge, as the 8 pt padding of the macOS badges.
const margin_px = 8;

/// The macOS `ReadonlyBadge`: 8 x 4 pt padding, 5 pt between icon and text,
/// 12 pt text, 6 pt corner, 1.5 pt orange border.
const badge_pad_x = 8;
const badge_pad_y = 4;
const badge_gap = 5;
const badge_icon_w = 14;
const badge_radius = 6;
const badge_line = 16;
const badge_font: Chrome.Font = .{ .size_pt = 12, .weight = .MEDIUM };
const badge_icon_font: Chrome.Font = .{ .icons = true, .size_pt = 12 };
const glyph_lock = std.unicode.utf8ToUtf16LeStringLiteral("\u{E72E}");
/// `Color(hue: 0.08, saturation: 0.5, brightness: 0.8)`.
const badge_ink: theme.Color = .{ .r = 204, .g = 151, .b = 102 };
/// `Color.orange`.
const orange: theme.Color = .{ .r = 255, .g = 149, .b = 0 };

/// The macOS `ChildExitedMessageBar`: full width, 8 x 4 pt padding, the
/// message in the primary colour on a half-opaque tint.
const bar_line = 16;
const bar_font: Chrome.Font = .{ .size_pt = 13 };

const health_text = "Rendering paused: the GPU was reset. Recovering\u{2026}";

pub const State = struct {
    readonly: ?*TextLabel = null,
    health: ?*TextLabel = null,
    /// The in-app toast of this surface (`app_toast`).
    toast: ?*TextLabel = null,
};

/// A label popup and the text it paints.
pub const TextLabel = struct {
    pub const Style = enum {
        /// Grey rounded rectangle, centred text (toasts).
        plain,
        /// The macOS read-only badge.
        readonly,
        /// The full-width warning bar.
        health,
    };

    popup: overlay.Popup,
    style: Style = .plain,
    text: [label_units]u16 = undefined,
    text_len: usize = 0,

    pub fn create(
        alloc: Allocator,
        surface: *Surface,
        anchor: overlay.Anchor,
        margin: i32,
        style: TextLabel.Style,
    ) !*TextLabel {
        const label = try alloc.create(TextLabel);
        label.* = .{ .style = style, .popup = .{
            .kind = .label,
            .anchor = anchor,
            .window = surface.window,
            .surface = surface,
            .size = .{ .w = 0, .h = height_px },
            .margin = margin,
            .paint = paint,
        } };
        label.popup.ctx = label;
        return label;
    }

    /// Takes the popup down and frees the label.
    pub fn destroy(label: *TextLabel, alloc: Allocator) void {
        label.popup.destroy();
        alloc.destroy(label);
    }

    /// Sets the text (cut to `label_units`) and the popup size to fit it.
    pub fn set(label: *TextLabel, utf8: []const u8) void {
        const n = convert(label, utf8);
        label.text_len = n;
        const dpi = label.popup.window.dpi;
        label.popup.size = switch (label.style) {
            .plain => .{ .w = width(label.text[0..n], dpi), .h = height_px },
            .readonly => .{ .w = logical(readonlyWidth(label.text[0..n], dpi), dpi), .h = 2 * badge_pad_y + badge_line },
            // The host stretches it to the surface.
            .health => .{ .w = 0, .h = 2 * badge_pad_y + bar_line },
        };
    }

    /// Shows the label with its current text.
    pub fn show(label: *TextLabel) void {
        label.popup.show() catch |err| log.warn("unable to show a label err={}", .{err});
    }

    pub fn text16(label: *const TextLabel) []const u16 {
        return label.text[0..label.text_len];
    }

    fn paint(p: *overlay.Popup, ctx: overlay.PaintContext) void {
        const label: *const TextLabel = @ptrCast(@alignCast(p.ctx orelse return));
        switch (label.style) {
            .plain => Chrome.paintLabel(ctx.hdc, ctx.rect, label.text16(), ctx.palette, ctx.dpi) catch |err| {
                log.warn("unable to paint a label err={}", .{err});
            },
            .readonly => paintReadonly(label, ctx),
            .health => paintBar(label, ctx),
        }
    }
};

/// Converts as much of `utf8` as fits (whole code points); returns the units written.
fn convert(label: *TextLabel, utf8: []const u8) usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(utf8) catch return 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const need: usize = if (cp >= 0x10000) 2 else 1;
        if (n + need > label.text.len) break;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            label.text[n] = @intCast(0xD800 + (v >> 10));
            label.text[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
        } else {
            label.text[n] = @intCast(cp);
        }
        n += need;
    }
    return n;
}

/// The colour of the material the badges sit on (macOS `.regularMaterial`,
/// which is translucent; here its resting colour).
pub fn materialFill(dark: bool) theme.Color {
    return if (dark) .{ .r = 0x32, .g = 0x32, .b = 0x32 } else .{ .r = 0xEC, .g = 0xEC, .b = 0xEC };
}

/// `.primary` of the system appearance.
pub fn primaryInk(dark: bool) theme.Color {
    return if (dark) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 0, .g = 0, .b = 0 };
}

fn withAlpha(c: theme.Color, a: u8) theme.Color {
    var out = c;
    out.a = a;
    return out;
}

/// Logical (96 dpi) size covering `px` pixels at `dpi`; one more absorbs the rounding.
pub fn logical(px: i32, dpi: u32) i32 {
    return @divTrunc(px * 96 + @as(i32, @intCast(dpi)) - 1, @as(i32, @intCast(dpi))) + 1;
}

fn readonlyWidth(text: []const u16, dpi: u32) i32 {
    const text_w = Chrome.measureText(text, badge_font, dpi) catch @divTrunc(@as(i32, @intCast(text.len)) * 7 * @as(i32, @intCast(dpi)), 96);
    return 2 * geom.scale(badge_pad_x, dpi) + geom.scale(badge_icon_w, dpi) + geom.scale(badge_gap, dpi) + text_w;
}

fn paintReadonly(label: *const TextLabel, ctx: overlay.PaintContext) void {
    const dpi = ctx.dpi;
    const fill = materialFill(ctx.palette.dark);
    const r = ctx.rect;
    const stroke_w = @max(1, @divTrunc(geom.scale(3, dpi) + 1, 2));
    const x0 = geom.scale(badge_pad_x, dpi);
    const icon_w = geom.scale(badge_icon_w, dpi);
    const text_x = x0 + icon_w + geom.scale(badge_gap, dpi);
    const items = [_]Chrome.Item{
        .{ .box = .{
            .rect = r,
            .radius = geom.scale(badge_radius, dpi),
            .fill = fill,
            .stroke = Chrome.blend(withAlpha(orange, 153), fill),
            .stroke_w = stroke_w,
        } },
        .{ .text = .{ .rect = .{ .x = x0, .y = 0, .w = icon_w, .h = r.h }, .text = glyph_lock, .font = badge_icon_font, .color = badge_ink } },
        .{ .text = .{ .rect = .{ .x = text_x, .y = 0, .w = r.w - text_x, .h = r.h }, .text = label.text16(), .font = badge_font, .color = badge_ink, .halign = .leading } },
    };
    Chrome.paintItems(ctx.hdc, r, &items, ctx.palette, dpi) catch |err| {
        log.warn("unable to paint the read-only badge err={}", .{err});
    };
}

fn paintBar(label: *const TextLabel, ctx: overlay.PaintContext) void {
    // The tint of the warning: orange at half opacity over the window colour.
    const base = materialFill(ctx.palette.dark);
    const items = [_]Chrome.Item{
        .{ .box = .{ .rect = ctx.rect, .radius = 0, .fill = Chrome.blend(withAlpha(orange, 128), base) } },
        .{ .text = .{ .rect = ctx.rect, .text = label.text16(), .font = bar_font, .color = primaryInk(ctx.palette.dark) } },
    };
    Chrome.paintItems(ctx.hdc, ctx.rect, &items, ctx.palette, ctx.dpi) catch |err| {
        log.warn("unable to paint the health bar err={}", .{err});
    };
}

/// Logical width of a label with `text`: the measured text and the padding.
fn width(text: []const u16, dpi: u32) i32 {
    const px = Chrome.measureLabel(text, dpi) catch |err| blk: {
        log.warn("unable to measure a label err={}", .{err});
        break :blk @divTrunc(@as(i32, @intCast(text.len)) * char_w * @as(i32, @intCast(dpi)), 96);
    };
    // Back to 96 dpi; one more pixel absorbs the rounding.
    return @divTrunc(px * 96 + @as(i32, @intCast(dpi)) - 1, @as(i32, @intCast(dpi))) + 2 * pad_x + 1;
}

pub fn surfaceDestroying(surface: *Surface) void {
    const alloc = surface.app.core_app.alloc;
    const state = &surface.badges;
    inline for (.{ &state.readonly, &state.health, &state.toast }) |slot| {
        if (slot.*) |label| label.destroy(alloc);
        slot.* = null;
    }
}

/// The text of the health bar for `health`; null hides it.
pub fn healthText(health: renderer.Health) ?[]const u8 {
    return switch (health) {
        .healthy => null,
        .unhealthy => health_text,
    };
}

pub fn rendererHealth(surface: *Surface, health: renderer.Health) void {
    const text = healthText(health) orelse {
        if (surface.badges.health) |label| label.popup.hide();
        return;
    };
    setHealthText(surface, text);
}

/// Shows the health bar with `text` (recovery switches it to the message
/// of the final failure).
pub fn setHealthText(surface: *Surface, text: []const u8) void {
    const label = surface.badges.health orelse blk: {
        const l = TextLabel.create(surface.app.core_app.alloc, surface, .surface_top_full, 0, .health) catch |err| {
            log.warn("unable to make the health bar err={}", .{err});
            return;
        };
        surface.badges.health = l;
        break :blk l;
    };
    label.set(text);
    label.show();
}

pub fn readonly(app: *App, target: apprt.Target, value: apprt.Action.Value(.readonly)) !bool {
    const core = switch (target) {
        .app => return true,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return true;
    const state = &surface.badges;

    if (value == .off) {
        if (state.readonly) |label| label.popup.hide();
        return true;
    }

    const label = state.readonly orelse blk: {
        const l = try TextLabel.create(app.core_app.alloc, surface, .surface_top_right, margin_px, .readonly);
        state.readonly = l;
        break :blk l;
    };
    label.set("Read-only");
    label.show();
    return true;
}

test "win32 badges: health text by state" {
    try std.testing.expect(healthText(.healthy) == null);
    const text = healthText(.unhealthy).?;
    try std.testing.expect(std.mem.startsWith(u8, text, "Rendering paused: the GPU was reset."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}
