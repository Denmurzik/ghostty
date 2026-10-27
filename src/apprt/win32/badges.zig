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
const overlay = @import("overlay.zig");

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

const health_text = "Rendering paused: the GPU was reset. Recovering\u{2026}";

pub const State = struct {
    readonly: ?*TextLabel = null,
    health: ?*TextLabel = null,
    /// The in-app toast of this surface (`app_toast`).
    toast: ?*TextLabel = null,
};

/// A label popup and the text it paints.
pub const TextLabel = struct {
    popup: overlay.Popup,
    text: [label_units]u16 = undefined,
    text_len: usize = 0,

    pub fn create(
        alloc: Allocator,
        surface: *Surface,
        anchor: overlay.Anchor,
        margin: i32,
    ) !*TextLabel {
        const label = try alloc.create(TextLabel);
        label.* = .{ .popup = .{
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
        label.popup.size = .{ .w = width(label.text[0..n], label.popup.window.dpi), .h = height_px };
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
        Chrome.paintLabel(ctx.hdc, ctx.rect, label.text16(), ctx.palette, ctx.dpi) catch |err| {
            log.warn("unable to paint a label err={}", .{err});
        };
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
        const l = TextLabel.create(surface.app.core_app.alloc, surface, .surface_top_full, 0) catch |err| {
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
        const l = try TextLabel.create(app.core_app.alloc, surface, .surface_top_right, margin_px);
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
