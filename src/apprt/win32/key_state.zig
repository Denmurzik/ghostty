//! Key sequence and key table indicator: one label at the bottom centre of
//! the surface, "<table> › <table> · ctrl+a › b", hidden when nothing is
//! pending. Driven by the core's `key_sequence` and `key_table` actions, so
//! the key path itself is never inspected.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const badges = @import("badges.zig");

/// Gap to the surface edge, as the 8 pt padding of the macOS indicator.
const margin_px = 8;

const chevron = " \u{203A} ";
const separator = " \u{00B7} ";

pub const State = struct {
    /// The key table stack, outermost first; the names are owned.
    tables: std.ArrayList([]u8) = .empty,
    /// The triggers of the pending key sequence.
    triggers: std.ArrayList(input.Binding.Trigger) = .empty,
    label: ?*badges.TextLabel = null,
};

pub fn surfaceDestroying(surface: *Surface) void {
    const alloc = surface.app.core_app.alloc;
    const state = &surface.key_state;
    if (state.label) |label| label.destroy(alloc);
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

    const text = try format(alloc, state.tables.items, state.triggers.items);
    defer alloc.free(text);

    const label = state.label orelse blk: {
        const l = try badges.TextLabel.create(alloc, surface, .surface_bottom_center, margin_px);
        state.label = l;
        break :blk l;
    };
    label.set(text);
    label.show();
}

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
