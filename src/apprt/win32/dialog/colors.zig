//! Colours of the Windows 11 style dialog: the Fluent (WinUI 3) tokens of a
//! `ContentDialog`, dark and light, the accent button derived from the
//! system accent colour, and the system colours of high contrast.
const std = @import("std");

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u24) Rgba {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    /// `hex` with an alpha in percent.
    pub fn alpha(hex: u24, percent: f32) Rgba {
        var c = rgb(hex);
        c.a = @intFromFloat(@round(percent * 255.0 / 100.0));
        return c;
    }
};

pub const Palette = struct {
    dark: bool,
    /// The body when there is no Mica behind it.
    body_solid: Rgba,
    /// The button bar.
    footer: Rgba,
    /// The line between body and button bar.
    divider: Rgba,
    text: Rgba,
    text_secondary: Rgba,
    /// A standard button, resting, under the pointer, pressed.
    button: Rgba,
    button_hover: Rgba,
    button_pressed: Rgba,
    button_border: Rgba,
    button_text: Rgba,
    button_text_pressed: Rgba,
    /// The accent (default) button.
    accent: Rgba,
    accent_hover: Rgba,
    accent_pressed: Rgba,
    accent_text: Rgba,
    accent_text_pressed: Rgba,
    /// The two strokes of the keyboard focus rectangle.
    focus_outer: Rgba,
    focus_inner: Rgba,
    /// The card the list sits in.
    card: Rgba,
    card_border: Rgba,
};

/// The accent used when the system does not say: `#0067C0` on light, `#4CC2FF`
/// on dark.
pub const fallback_accent_light = Rgba.rgb(0x0067C0);
pub const fallback_accent_dark = Rgba.rgb(0x4CC2FF);

fn mix(a: Rgba, b: Rgba, t: f32) Rgba {
    const f = struct {
        fn ch(x: u8, y: u8, k: f32) u8 {
            const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
            return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        }
    };
    return .{ .r = f.ch(a.r, b.r, t), .g = f.ch(a.g, b.g, t), .b = f.ch(a.b, b.b, t) };
}

/// Relative luminance (0..1) of the sRGB colour, for picking readable text.
pub fn luminance(c: Rgba) f32 {
    const f = struct {
        fn lin(v: u8) f32 {
            const s = @as(f32, @floatFromInt(v)) / 255.0;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * f.lin(c.r) + 0.7152 * f.lin(c.g) + 0.0722 * f.lin(c.b);
}

pub const Accent = struct { fill: Rgba, text: Rgba };

/// The accent button fill and its text for the system accent `sys`
/// (null: the fallbacks). WinUI takes a lighter shade of the accent on dark
/// and a darker one on light; the text is black or white, whichever reads
/// better.
pub fn accentFor(dark: bool, sys: ?Rgba) Accent {
    const white = Rgba.rgb(0xFFFFFF);
    const black = Rgba.rgb(0x000000);
    const fill: Rgba = if (sys) |s|
        (if (dark) mix(s, white, 0.45) else mix(s, black, 0.13))
    else if (dark) fallback_accent_dark else fallback_accent_light;
    // Contrast ratios of black and white text against the fill.
    const l = luminance(fill);
    const with_white = 1.05 / (l + 0.05);
    const with_black = (l + 0.05) / 0.05;
    return .{ .fill = fill, .text = if (with_black >= with_white) black else white };
}

/// Fluent tokens. `accent` is the result of `accentFor`.
pub fn forTheme(dark: bool, accent: Accent) Palette {
    if (dark) return .{
        .dark = true,
        .body_solid = Rgba.rgb(0x2B2B2B),
        .footer = Rgba.rgb(0x202020),
        .divider = Rgba.alpha(0xFFFFFF, 5.8),
        .text = Rgba.rgb(0xFFFFFF),
        .text_secondary = Rgba.alpha(0xFFFFFF, 78.6),
        .button = Rgba.alpha(0xFFFFFF, 6.05),
        .button_hover = Rgba.alpha(0xFFFFFF, 8.37),
        .button_pressed = Rgba.alpha(0xFFFFFF, 3.26),
        .button_border = Rgba.alpha(0xFFFFFF, 9.3),
        .button_text = Rgba.rgb(0xFFFFFF),
        .button_text_pressed = Rgba.alpha(0xFFFFFF, 78.6),
        .accent = accent.fill,
        .accent_hover = withAlpha(accent.fill, 90),
        .accent_pressed = withAlpha(accent.fill, 80),
        .accent_text = accent.text,
        .accent_text_pressed = withAlpha(accent.text, 78.6),
        .focus_outer = Rgba.rgb(0xFFFFFF),
        .focus_inner = Rgba.rgb(0x000000),
        .card = Rgba.rgb(0x2B2B2B),
        .card_border = Rgba.alpha(0xFFFFFF, 8.0),
    };
    return .{
        .dark = false,
        .body_solid = Rgba.rgb(0xFAFAFA),
        .footer = Rgba.rgb(0xF3F3F3),
        .divider = Rgba.alpha(0x000000, 5.78),
        .text = Rgba.alpha(0x000000, 89.56),
        .text_secondary = Rgba.alpha(0x000000, 60.96),
        .button = Rgba.alpha(0xFFFFFF, 70),
        .button_hover = Rgba.alpha(0xF9F9F9, 50),
        .button_pressed = Rgba.alpha(0xF9F9F9, 30),
        .button_border = Rgba.alpha(0x000000, 16.0),
        .button_text = Rgba.alpha(0x000000, 89.56),
        .button_text_pressed = Rgba.alpha(0x000000, 60.6),
        .accent = accent.fill,
        .accent_hover = withAlpha(accent.fill, 90),
        .accent_pressed = withAlpha(accent.fill, 80),
        .accent_text = accent.text,
        .accent_text_pressed = withAlpha(accent.text, 70),
        .focus_outer = Rgba.rgb(0x000000),
        .focus_inner = Rgba.rgb(0xFFFFFF),
        .card = Rgba.rgb(0xFBFBFB),
        .card_border = Rgba.alpha(0x000000, 5.78),
    };
}

fn withAlpha(c: Rgba, percent: f32) Rgba {
    var out = c;
    out.a = @intFromFloat(@round(percent * 255.0 / 100.0));
    return out;
}

pub const SystemColors = struct {
    window: Rgba,
    window_text: Rgba,
    highlight: Rgba,
    highlight_text: Rgba,
    gray_text: Rgba,
};

/// High contrast: the system colours only, every fill opaque and every
/// border drawn.
pub fn forHighContrast(sys: SystemColors) Palette {
    const text = sys.window_text;
    return .{
        .dark = luminance(sys.window) < 0.5,
        .body_solid = sys.window,
        .footer = sys.window,
        .divider = text,
        .text = text,
        .text_secondary = text,
        .button = sys.window,
        .button_hover = sys.highlight,
        .button_pressed = sys.highlight,
        .button_border = text,
        .button_text = text,
        .button_text_pressed = sys.highlight_text,
        .accent = sys.window,
        .accent_hover = sys.highlight,
        .accent_pressed = sys.highlight,
        .accent_text = text,
        .accent_text_pressed = sys.highlight_text,
        .focus_outer = text,
        .focus_inner = sys.window,
        .card = sys.window,
        .card_border = text,
    };
}

test "win32 dialog colors: footer and fallback accent follow the brief" {
    const dark = forTheme(true, accentFor(true, null));
    try std.testing.expectEqual(Rgba.rgb(0x202020), dark.footer);
    try std.testing.expectEqual(Rgba.rgb(0x4CC2FF), dark.accent);
    // Dark text on the light accent.
    try std.testing.expectEqual(Rgba.rgb(0x000000), dark.accent_text);

    const light = forTheme(false, accentFor(false, null));
    try std.testing.expectEqual(Rgba.rgb(0xF3F3F3), light.footer);
    try std.testing.expectEqual(Rgba.rgb(0x0067C0), light.accent);
    try std.testing.expectEqual(Rgba.rgb(0xFFFFFF), light.accent_text);
}

test "win32 dialog colors: system accent is shaded for the theme" {
    const sys = Rgba.rgb(0x0078D4);
    const dark = accentFor(true, sys);
    const light = accentFor(false, sys);
    try std.testing.expect(luminance(dark.fill) > luminance(sys));
    try std.testing.expect(luminance(light.fill) < luminance(sys));
    // Readable either way.
    try std.testing.expectEqual(Rgba.rgb(0x000000), dark.text);
    try std.testing.expectEqual(Rgba.rgb(0xFFFFFF), light.text);
}

test "win32 dialog colors: text is picked for contrast" {
    // A very light accent takes black text, a very dark one white.
    try std.testing.expectEqual(Rgba.rgb(0x000000), accentFor(false, Rgba.rgb(0xFFFF00)).text);
    try std.testing.expectEqual(Rgba.rgb(0xFFFFFF), accentFor(true, Rgba.rgb(0x000000)).text);
}

test "win32 dialog colors: high contrast uses system colours only" {
    const hc = forHighContrast(.{
        .window = Rgba.rgb(0x000000),
        .window_text = Rgba.rgb(0xFFFFFF),
        .highlight = Rgba.rgb(0x1AEBFF),
        .highlight_text = Rgba.rgb(0x000000),
        .gray_text = Rgba.rgb(0x3FF23F),
    });
    try std.testing.expect(hc.dark);
    try std.testing.expectEqual(@as(u8, 255), hc.button_border.a);
    try std.testing.expectEqual(@as(u8, 255), hc.footer.a);
    try std.testing.expectEqual(Rgba.rgb(0xFFFFFF), hc.text);
}
