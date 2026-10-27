//! The "cols x rows" overlay shown while resizing: a label popup of the
//! overlay host (owned, never focused), painted with Direct2D and hidden by
//! the host's timer.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Surface = @import("Surface.zig");
const Chrome = @import("Chrome.zig");
const geom = @import("geom.zig");
const overlay = @import("overlay.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_resize_overlay);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const class_name = L("GhosttyResizeOverlay");

/// Sizes at 96 DPI, from macOS `SurfaceResizeOverlay`: 5 pt padding, 13 pt text, no margin to the edge.
const margin_px = 0;
const pad_x = 5;
const char_w = 8;
const height_px = 26;

pub const State = struct {
    /// The host popup; `popup_made` once it was set up.
    popup: overlay.Popup = undefined,
    popup_made: bool = false,
    /// Whether a size was already reported; `after-first` skips the first.
    armed: bool = false,
    /// The surface and grid of the last report, to ignore repeats.
    last_surface: ?*const Surface = null,
    last_cols: u32 = 0,
    last_rows: u32 = 0,
    /// What the popup paints, set when it is shown.
    text: [32]u16 = undefined,
    text_len: usize = 0,
};

pub const Size = geom.Size;

/// The popup rectangle of `size` inside `surface`, `margin` away from the
/// edges it is attached to. Never starts left of or above the surface.
pub fn placement(
    pos: configpkg.Config.ResizeOverlayPosition,
    surface: geom.Rect,
    size: Size,
    margin: i32,
) geom.Rect {
    const left = surface.x + margin;
    const right = surface.right() - size.w - margin;
    const center_x = surface.x + @divTrunc(surface.w - size.w, 2);
    const top = surface.y + margin;
    const bottom = surface.bottom() - size.h - margin;
    const center_y = surface.y + @divTrunc(surface.h - size.h, 2);

    const x: i32, const y: i32 = switch (pos) {
        .center => .{ center_x, center_y },
        .@"top-left" => .{ left, top },
        .@"top-center" => .{ center_x, top },
        .@"top-right" => .{ right, top },
        .@"bottom-left" => .{ left, bottom },
        .@"bottom-center" => .{ center_x, bottom },
        .@"bottom-right" => .{ right, bottom },
    };
    return .{
        .x = @max(x, surface.x),
        .y = @max(y, surface.y),
        .w = size.w,
        .h = size.h,
    };
}

/// Core applied a new size to `surface`. Shows the popup with the grid size
/// as configured by `resize-overlay`.
pub fn notify(surface: *Surface, cols: u32, rows: u32) void {
    const window = surface.window;
    const state = &window.overlay;
    const config = &window.app.config;

    const was_armed = state.armed;
    state.armed = true;
    switch (config.@"resize-overlay") {
        .never => return,
        .always => {},
        .@"after-first" => if (!was_armed) return,
    }

    // Layout passes report the grid they already have; only a change shows.
    if (state.last_surface == surface and state.last_cols == cols and state.last_rows == rows) return;
    state.last_surface = surface;
    state.last_cols = cols;
    state.last_rows = rows;

    show(surface, state, config, cols, rows) catch |err| {
        log.warn("unable to show the resize overlay err={}", .{err});
    };
}

fn show(surface: *Surface, state: *State, config: *const configpkg.Config, cols: u32, rows: u32) !void {
    const window = surface.window;
    if (user32.IsIconic(window.hwnd) != 0 or user32.IsWindowVisible(surface.hwnd) == 0) return;

    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d} \u{2A2F} {d}", .{ cols, rows });
    var wide: [32]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&wide, text);
    @memcpy(state.text[0..n], wide[0..n]);
    state.text_len = n;

    if (!state.popup_made) {
        state.popup = .{
            .kind = .label,
            .anchor = .surface_top_right,
            .window = window,
            .surface = surface,
            .size = .{ .w = 0, .h = height_px },
            .margin = margin_px,
            .paint = paintPopup,
            .place = placePopup,
            .ctx = state,
            .class = class_name,
        };
        state.popup_made = true;
    }
    const p = &state.popup;
    // The surface may differ between reports (splits).
    p.surface = surface;
    p.size = .{ .w = 2 * pad_x + char_w * @as(i32, @intCast(n)), .h = height_px };
    try p.show();

    const ms: u64 = @max(1, config.@"resize-overlay-duration".duration / std.time.ns_per_ms);
    p.hideAfter(@intCast(@min(ms, std.math.maxInt(u32))));
}

fn placePopup(p: *overlay.Popup, surface: geom.Rect, size_px: overlay.Size) geom.Rect {
    const config = &p.window.app.config;
    return placement(
        config.@"resize-overlay-position",
        surface,
        .{ .w = size_px.w, .h = size_px.h },
        geom.scale(margin_px, p.window.dpi),
    );
}

fn paintPopup(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const state: *const State = @ptrCast(@alignCast(p.ctx orelse return));
    Chrome.paintLabel(ctx.hdc, ctx.rect, state.text[0..state.text_len], ctx.palette, ctx.dpi) catch |err| {
        log.warn("unable to paint the resize overlay err={}", .{err});
    };
}

pub fn deinit(state: *State) void {
    // Owned popups die with their owner; this is for an explicit teardown.
    if (state.popup_made) state.popup.destroy();
    state.popup_made = false;
}

test "win32 overlay: placement for each position" {
    const surface: geom.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const size: Size = .{ .w = 100, .h = 40 };
    const P = configpkg.Config.ResizeOverlayPosition;
    const cases = [_]struct { pos: P, x: i32, y: i32 }{
        .{ .pos = .center, .x = 350, .y = 280 },
        .{ .pos = .@"top-left", .x = 8, .y = 8 },
        .{ .pos = .@"top-center", .x = 350, .y = 8 },
        .{ .pos = .@"top-right", .x = 692, .y = 8 },
        .{ .pos = .@"bottom-left", .x = 8, .y = 552 },
        .{ .pos = .@"bottom-center", .x = 350, .y = 552 },
        .{ .pos = .@"bottom-right", .x = 692, .y = 552 },
    };
    for (cases) |c| {
        const r = placement(c.pos, surface, size, 8);
        try std.testing.expectEqual(c.x, r.x);
        try std.testing.expectEqual(c.y, r.y);
        try std.testing.expectEqual(@as(i32, 100), r.w);
        try std.testing.expectEqual(@as(i32, 40), r.h);
    }

    // The surface origin offsets the result; a tiny surface never pushes
    // the popup up or left of it.
    const off = placement(.@"bottom-right", .{ .x = 100, .y = 50, .w = 800, .h = 600 }, size, 8);
    try std.testing.expectEqual(@as(i32, 792), off.x);
    try std.testing.expectEqual(@as(i32, 602), off.y);
    const tiny = placement(.center, .{ .x = 10, .y = 10, .w = 50, .h = 20 }, size, 8);
    try std.testing.expectEqual(@as(i32, 10), tiny.x);
    try std.testing.expectEqual(@as(i32, 10), tiny.y);
}
