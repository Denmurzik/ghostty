//! Key sequence and key table indicator, the macOS `KeyStateIndicator`: a
//! capsule at the bottom centre of the surface with the key table stack and
//! the keycaps of the pending key sequence, hidden when nothing is pending.
//! Driven by the core's `key_sequence` and `key_table` actions, so the key
//! path itself is never inspected.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const badges = @import("badges.zig");
const Chrome = @import("Chrome.zig");
const geom = @import("geom.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.win32_key_state);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const glyph_keyboard = L("\u{E765}");
const glyph_chevron = L("\u{E76C}");

/// Gap to the surface edge, as the 8 pt padding of the macOS indicator.
const margin_px = 8;

/// Sizes in pt (96 dpi px) from the macOS indicator: a capsule with 12 pt
/// side padding and 8 between the table and the sequence part; the table
/// part has a 13 pt icon, 13 pt medium names and 10 pt chevrons, 5 apart;
/// the sequence part has keycaps (12 pt medium, 5 pt side padding, 4 pt
/// corner, 4 apart) and three 4 pt pending dots.
const pad_x = 12;
const height_pt = 32;
const group_gap = 8;
const table_gap = 5;
const icon_w = 16;
const chevron_w = 8;
const keycap_pad_x = 5;
const keycap_h = 20;
const keycap_radius = 4;
const keycap_gap = 4;
const dot = 4;
const dot_gap = 2;
const divider_h = 14;
const table_font: Chrome.Font = .{ .size_pt = 13, .weight = .MEDIUM };
const table_icon_font: Chrome.Font = .{ .icons = true, .size_pt = 13 };
const chevron_font: Chrome.Font = .{ .icons = true, .size_pt = 10, .weight = .SEMI_BOLD };
const keycap_font: Chrome.Font = .{ .size_pt = 12, .weight = .MEDIUM };

const chevron = " \u{203A} ";
const separator = " \u{00B7} ";

pub const State = struct {
    /// The key table stack, outermost first; the names are owned.
    tables: std.ArrayList([]u8) = .empty,
    /// The triggers of the pending key sequence.
    triggers: std.ArrayList(input.Binding.Trigger) = .empty,
    label: ?*Indicator = null,
};

/// The popup; what it paints is read from the surface's state.
const Indicator = struct {
    popup: overlay.Popup,
};

pub fn surfaceDestroying(surface: *Surface) void {
    const alloc = surface.app.core_app.alloc;
    const state = &surface.key_state;
    if (state.label) |label| {
        label.popup.destroy();
        alloc.destroy(label);
    }
    state.label = null;
    clearTables(alloc, state);
    state.tables.deinit(alloc);
    state.triggers.deinit(alloc);
    state.* = .{};
}

pub fn sequence(app: *App, target: apprt.Target, value: apprt.Action.Value(.key_sequence)) !bool {
    const surface = surfaceOf(app, target) orelse return true;
    const alloc = app.core_app.alloc;
    const state = &surface.key_state;
    switch (value) {
        .trigger => |t| try state.triggers.append(alloc, t),
        .end => state.triggers.clearRetainingCapacity(),
    }
    try update(surface);
    return true;
}

pub fn table(app: *App, target: apprt.Target, value: apprt.Action.Value(.key_table)) !bool {
    const surface = surfaceOf(app, target) orelse return true;
    const alloc = app.core_app.alloc;
    const state = &surface.key_state;
    switch (value) {
        .activate => |name| {
            const owned = try alloc.dupe(u8, name);
            errdefer alloc.free(owned);
            try state.tables.append(alloc, owned);
        },
        .deactivate => if (state.tables.pop()) |name| alloc.free(name),
        .deactivate_all => clearTables(alloc, state),
    }
    try update(surface);
    return true;
}

fn surfaceOf(app: *App, target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core| app.surfaceFor(core),
    };
}

fn clearTables(alloc: Allocator, state: *State) void {
    for (state.tables.items) |name| alloc.free(name);
    state.tables.clearRetainingCapacity();
}

/// Shows the label for the current state, or hides it when it is empty.
fn update(surface: *Surface) !void {
    const alloc = surface.app.core_app.alloc;
    const state = &surface.key_state;
    if (state.tables.items.len == 0 and state.triggers.items.len == 0) {
        if (state.label) |label| label.popup.hide();
        return;
    }

    const label = state.label orelse blk: {
        const l = try alloc.create(Indicator);
        l.* = .{ .popup = .{
            .kind = .label,
            .anchor = .surface_bottom_center,
            .window = surface.window,
            .surface = surface,
            .size = .{ .w = 0, .h = height_pt },
            .margin = margin_px,
            .paint = paint,
        } };
        l.popup.ctx = surface;
        state.label = l;
        break :blk l;
    };

    const dpi = surface.window.dpi;
    var scene: Scene = .{};
    scene.build(state, dpi, false);
    label.popup.size = .{ .w = badges.logical(scene.width, dpi), .h = height_pt };
    label.popup.show() catch |err| log.warn("unable to show the key state err={}", .{err});
}

fn paint(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const surface: *Surface = @ptrCast(@alignCast(p.ctx orelse return));
    var scene: Scene = .{};
    scene.build(&surface.key_state, ctx.dpi, ctx.palette.dark);
    Chrome.paintItems(ctx.hdc, ctx.rect, scene.items[0..scene.n], ctx.palette, ctx.dpi, null) catch |err| {
        log.warn("unable to paint the key state err={}", .{err});
    };
}

fn alpha(c: theme.Color, a: u8) theme.Color {
    var out = c;
    out.a = a;
    return out;
}

fn px(v: i32, dpi: u32) i32 {
    return geom.scale(v, dpi);
}

/// The items of the indicator at `dpi` and its width in px.
const Scene = struct {
    items: [96]Chrome.Item = undefined,
    n: usize = 0,
    chars: [1024]u16 = undefined,
    used: usize = 0,
    width: i32 = 0,

    fn push(self: *Scene, item: Chrome.Item) void {
        if (self.n == self.items.len) return;
        self.items[self.n] = item;
        self.n += 1;
    }

    /// `utf8` as UTF-16 in the scene's own storage (cut when it is full).
    fn wide(self: *Scene, utf8: []const u8) []const u16 {
        const rest = self.chars[self.used..];
        var n: usize = 0;
        var view = std.unicode.Utf8View.init(utf8) catch return &.{};
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const need: usize = if (cp >= 0x10000) 2 else 1;
            if (n + need > rest.len) break;
            if (need == 2) {
                const v = cp - 0x10000;
                rest[n] = @intCast(0xD800 + (v >> 10));
                rest[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            } else {
                rest[n] = @intCast(cp);
            }
            n += need;
        }
        self.used += n;
        return rest[0..n];
    }

    fn textWidth(text: []const u16, font: Chrome.Font, dpi: u32) i32 {
        return Chrome.measureText(text, font, dpi) catch @divTrunc(@as(i32, @intCast(text.len)) * 7 * @as(i32, @intCast(dpi)), 96);
    }

    fn build(self: *Scene, state: *const State, dpi: u32, dark: bool) void {
        const fill = badges.materialFill(dark);
        const primary = badges.primaryInk(dark);
        const border = Chrome.blend(alpha(primary, 38), fill);
        const secondary = Chrome.blend(alpha(primary, 140), fill);
        const tertiary = Chrome.blend(alpha(primary, 64), fill);
        const h = px(height_pt, dpi);

        // The capsule goes first; its width is known at the end.
        self.push(undefined);
        self.push(undefined);
        var x = px(pad_x, dpi);

        if (state.tables.items.len > 0) {
            self.push(.{ .text = .{ .rect = .{ .x = x, .y = 0, .w = px(icon_w, dpi), .h = h }, .text = glyph_keyboard, .font = table_icon_font, .color = secondary } });
            x += px(icon_w, dpi) + px(table_gap, dpi);
            for (state.tables.items, 0..) |name, i| {
                if (i > 0) {
                    self.push(.{ .text = .{ .rect = .{ .x = x, .y = 0, .w = px(chevron_w, dpi), .h = h }, .text = glyph_chevron, .font = chevron_font, .color = tertiary } });
                    x += px(chevron_w, dpi) + px(table_gap, dpi);
                }
                const text = self.wide(name);
                const w = textWidth(text, table_font, dpi);
                self.push(.{ .text = .{ .rect = .{ .x = x, .y = 0, .w = w, .h = h }, .text = text, .font = table_font, .color = primary, .halign = .leading } });
                x += w + px(table_gap, dpi);
            }
            x -= px(table_gap, dpi);
        }

        if (state.tables.items.len > 0 and state.triggers.items.len > 0) {
            x += px(group_gap, dpi);
            const dh = px(divider_h, dpi);
            self.push(.{ .box = .{ .rect = .{ .x = x, .y = @divTrunc(h - dh, 2), .w = 1, .h = dh }, .radius = 0, .fill = border } });
            x += 1 + px(group_gap, dpi);
        }

        if (state.triggers.items.len > 0) {
            const cap_fill: theme.Color = if (dark) .{ .r = 0x1E, .g = 0x1E, .b = 0x1E } else .{ .r = 255, .g = 255, .b = 255 };
            const cap_border = Chrome.blend(alpha(primary, 38), cap_fill);
            const ch = px(keycap_h, dpi);
            for (state.triggers.items) |trigger| {
                var buf: [64]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                writeTrigger(&w, trigger) catch {};
                const text = self.wide(w.buffered());
                const cw = textWidth(text, keycap_font, dpi) + 2 * px(keycap_pad_x, dpi);
                const cap: geom.Rect = .{ .x = x, .y = @divTrunc(h - ch, 2), .w = cw, .h = ch };
                self.push(.{ .box = .{ .rect = cap, .radius = px(keycap_radius, dpi), .fill = cap_fill } });
                self.push(.{ .stroke = .{ .rect = cap, .radius = px(keycap_radius, dpi), .width = 1, .color = cap_border } });
                self.push(.{ .text = .{ .rect = .{ .x = x, .y = 0, .w = cw, .h = h }, .text = text, .font = keycap_font, .color = primary } });
                x += cw + px(keycap_gap, dpi);
            }
            // Static stand-ins for the animated pending dots of macOS.
            const d = px(dot, dpi);
            const opacity = [3]u8{ 77, 166, 255 };
            for (opacity, 0..) |o, i| {
                const c = Chrome.blend(alpha(secondary, o), fill);
                const dx = x + @as(i32, @intCast(i)) * (d + px(dot_gap, dpi));
                self.push(.{ .box = .{ .rect = .{ .x = dx, .y = @divTrunc(h - d, 2), .w = d, .h = d }, .radius = @divTrunc(d, 2), .fill = c } });
            }
            x += 3 * d + 2 * px(dot_gap, dpi);
        }

        x += px(pad_x, dpi);
        self.width = x;
        const body: geom.Rect = .{ .x = 0, .y = 0, .w = x, .h = h };
        self.items[0] = .{ .box = .{ .rect = body, .radius = @divTrunc(h, 2), .fill = fill } };
        self.items[1] = .{ .stroke = .{ .rect = body, .radius = @divTrunc(h, 2), .width = 1, .color = border } };
    }
};

/// "<table> › <table> · ctrl+a › b"; empty when there is neither.
pub fn format(
    alloc: Allocator,
    tables: []const []const u8,
    triggers: []const input.Binding.Trigger,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    for (tables, 0..) |name, i| {
        if (i > 0) try w.writeAll(chevron);
        try w.writeAll(name);
    }
    if (tables.len > 0 and triggers.len > 0) try w.writeAll(separator);
    for (triggers, 0..) |t, i| {
        if (i > 0) try w.writeAll(chevron);
        try writeTrigger(w, t);
    }
    return out.toOwnedSlice();
}

/// The trigger as the user wrote it: modifiers, then the key without the
/// `key_` / `digit_` prefix of the physical key names.
fn writeTrigger(w: *std.Io.Writer, t: input.Binding.Trigger) !void {
    if (t.mods.super) try w.writeAll("super+");
    if (t.mods.ctrl) try w.writeAll("ctrl+");
    if (t.mods.alt) try w.writeAll("alt+");
    if (t.mods.shift) try w.writeAll("shift+");
    switch (t.key) {
        .physical => |k| {
            const name = @tagName(k);
            const stripped = for ([_][]const u8{ "key_", "digit_" }) |prefix| {
                if (std.mem.startsWith(u8, name, prefix)) break name[prefix.len..];
            } else name;
            try w.writeAll(stripped);
        },
        .unicode => |c| try w.print("{u}", .{c}),
        .catch_all => try w.writeAll("catch_all"),
    }
}

test "win32 key_state: format" {
    const alloc = std.testing.allocator;

    const empty = try format(alloc, &.{}, &.{});
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const triggers = [_]input.Binding.Trigger{
        .{ .key = .{ .physical = .key_a }, .mods = .{ .ctrl = true } },
        .{ .key = .{ .unicode = 'b' } },
        .{ .key = .{ .physical = .digit_1 }, .mods = .{ .alt = true, .shift = true } },
    };

    const both = try format(alloc, &.{ "vim", "nav" }, &triggers);
    defer alloc.free(both);
    try std.testing.expectEqualStrings(
        "vim \u{203A} nav \u{00B7} ctrl+a \u{203A} b \u{203A} alt+shift+1",
        both,
    );

    const only_table = try format(alloc, &.{"vim"}, &.{});
    defer alloc.free(only_table);
    try std.testing.expectEqualStrings("vim", only_table);

    const only_seq = try format(alloc, &.{}, triggers[0..2]);
    defer alloc.free(only_seq);
    try std.testing.expectEqualStrings("ctrl+a \u{203A} b", only_seq);
}
