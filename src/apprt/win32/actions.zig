//! Action dispatch for the Win32 runtime. Every `apprt.Action.Key` is
//! classified in `status`; implemented actions go to one handler in an area
//! file under `actions/`, everything else logs and returns false.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32_actions);

const handlers = struct {
    const app_actions = @import("actions/app_actions.zig");
    const window_actions = @import("actions/window_actions.zig");
    const tab_actions = @import("actions/tab_actions.zig");
    const split_actions = @import("actions/split_actions.zig");
    const surface_actions = @import("actions/surface_actions.zig");
};

pub const Status = union(enum) {
    implemented,
    deferred: struct { milestone: []const u8, reason: []const u8 },
    unsupported: []const u8,
};

/// Coverage classification of every action. The switch is exhaustive, so a
/// new `Action.Key` does not compile until it is classified here.
pub fn status(comptime key: apprt.Action.Key) Status {
    return switch (key) {
        .quit, .new_window, .close_all_windows, .goto_window, .present_terminal, .reload_config, .config_change, .open_config, .color_change, .quit_timer, .open_url => .implemented,
        .close_window, .initial_size, .size_limit, .cell_size, .set_window_title, .toggle_maximize, .toggle_fullscreen, .toggle_window_decorations, .float_window, .reset_window_size, .resize_window, .prompt_title, .ring_bell, .progress_report => .implemented,
        .new_tab, .close_tab, .goto_tab, .move_tab, .set_tab_title, .set_title, .copy_title_to_clipboard, .pwd, .move_tab_to_new_window => .implemented,
        .new_split, .goto_split, .resize_split, .equalize_splits, .toggle_split_zoom => .implemented,
        .mouse_shape, .mouse_visibility, .render, .show_child_exited, .scrollbar => .implemented,
        .toggle_quick_terminal, .toggle_command_palette, .inspector, .render_inspector, .export_terminal_io, .desktop_notification, .command_finished, .mouse_over_link, .start_search, .end_search, .search_total, .search_selected, .key_sequence, .key_table, .renderer_health, .readonly, .toggle_background_opacity, .toggle_visibility => .{ .deferred = .{
            .milestone = "M3",
            .reason = "SPEC section 17 M3 list",
        } },
        .check_for_updates, .show_on_screen_keyboard, .secure_input, .undo, .redo => .{ .deferred = .{
            .milestone = "M5",
            .reason = "Windows extras, analog of a macOS-only feature",
        } },
        .selection_changed => .{ .deferred = .{
            .milestone = "post-v1",
            .reason = "needs UI Automation",
        } },
        .toggle_tab_overview => .{ .unsupported = "no tab overview on Windows; not required by DECISIONS" },
        .show_gtk_inspector => .{ .unsupported = "GTK only" },
    };
}

pub fn perform(
    app: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (comptime status(action)) {
        .implemented => {},
        .deferred => |d| {
            log.debug("deferred action={} milestone={s} ({s})", .{ action, d.milestone, d.reason });
            return false;
        },
        .unsupported => |reason| {
            log.debug("unsupported action={} ({s})", .{ action, reason });
            return false;
        },
    }

    return switch (action) {
        .quit => handlers.app_actions.quit(app, target, value),
        .new_window => handlers.app_actions.new_window(app, target, value),
        .close_all_windows => handlers.app_actions.close_all_windows(app, target, value),
        .goto_window => handlers.app_actions.goto_window(app, target, value),
        .present_terminal => handlers.app_actions.present_terminal(app, target, value),
        .reload_config => handlers.app_actions.reload_config(app, target, value),
        .config_change => handlers.app_actions.config_change(app, target, value),
        .open_config => handlers.app_actions.open_config(app, target, value),
        .color_change => handlers.app_actions.color_change(app, target, value),
        .quit_timer => handlers.app_actions.quit_timer(app, target, value),
        .open_url => handlers.app_actions.open_url(app, target, value),
        .close_window => handlers.window_actions.close_window(app, target, value),
        .initial_size => handlers.window_actions.initial_size(app, target, value),
        .size_limit => handlers.window_actions.size_limit(app, target, value),
        .cell_size => handlers.window_actions.cell_size(app, target, value),
        .set_window_title => handlers.window_actions.set_window_title(app, target, value),
        .toggle_maximize => handlers.window_actions.toggle_maximize(app, target, value),
        .toggle_fullscreen => handlers.window_actions.toggle_fullscreen(app, target, value),
        .toggle_window_decorations => handlers.window_actions.toggle_window_decorations(app, target, value),
        .float_window => handlers.window_actions.float_window(app, target, value),
        .reset_window_size => handlers.window_actions.reset_window_size(app, target, value),
        .resize_window => handlers.window_actions.resize_window(app, target, value),
        .prompt_title => handlers.window_actions.prompt_title(app, target, value),
        .ring_bell => handlers.window_actions.ring_bell(app, target, value),
        .progress_report => handlers.window_actions.progress_report(app, target, value),
        .new_tab => handlers.tab_actions.new_tab(app, target, value),
        .close_tab => handlers.tab_actions.close_tab(app, target, value),
        .goto_tab => handlers.tab_actions.goto_tab(app, target, value),
        .move_tab => handlers.tab_actions.move_tab(app, target, value),
        .set_tab_title => handlers.tab_actions.set_tab_title(app, target, value),
        .set_title => handlers.tab_actions.set_title(app, target, value),
        .copy_title_to_clipboard => handlers.tab_actions.copy_title_to_clipboard(app, target, value),
        .pwd => handlers.tab_actions.pwd(app, target, value),
        .move_tab_to_new_window => handlers.tab_actions.move_tab_to_new_window(app, target, value),
        .new_split => handlers.split_actions.new_split(app, target, value),
        .goto_split => handlers.split_actions.goto_split(app, target, value),
        .resize_split => handlers.split_actions.resize_split(app, target, value),
        .equalize_splits => handlers.split_actions.equalize_splits(app, target, value),
        .toggle_split_zoom => handlers.split_actions.toggle_split_zoom(app, target, value),
        .mouse_shape => handlers.surface_actions.mouse_shape(app, target, value),
        .mouse_visibility => handlers.surface_actions.mouse_visibility(app, target, value),
        .render => handlers.surface_actions.render(app, target, value),
        .show_child_exited => handlers.surface_actions.show_child_exited(app, target, value),
        .scrollbar => handlers.surface_actions.scrollbar(app, target, value),
        else => comptime unreachable,
    };
}

test "win32 actions: every Action.Key is classified" {
    const keys = @typeInfo(apprt.Action.Key).@"enum".field_names;
    try std.testing.expectEqual(70, keys.len);
    inline for (keys) |name| {
        _ = comptime status(@field(apprt.Action.Key, name));
    }
}

test "win32 actions: M2 scope list matches the plan" {
    const keys = @typeInfo(apprt.Action.Key).@"enum".field_names;
    var implemented: usize = 0;
    var deferred: usize = 0;
    var unsupported: usize = 0;
    inline for (keys) |name| {
        switch (comptime status(@field(apprt.Action.Key, name))) {
            .implemented => implemented += 1,
            .deferred => deferred += 1,
            .unsupported => unsupported += 1,
        }
    }
    try std.testing.expectEqual(44, implemented);
    try std.testing.expectEqual(24, deferred);
    try std.testing.expectEqual(2, unsupported);

    const m3 = comptime status(.start_search).deferred;
    try std.testing.expectEqualStrings("M3", m3.milestone);
    try std.testing.expectEqualStrings("M5", comptime status(.undo).deferred.milestone);
    try std.testing.expectEqualStrings("post-v1", comptime status(.selection_changed).deferred.milestone);
    try std.testing.expect(comptime status(.quit) == .implemented);
    try std.testing.expect(comptime status(.show_gtk_inspector) == .unsupported);
}
