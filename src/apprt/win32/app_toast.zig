//! In-app toasts: a label at the bottom centre of the window that hides
//! itself, for a config reload and a copy to the clipboard. Both can be
//! turned off with `app-notifications`.
const std = @import("std");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const badges = @import("badges.zig");

const log = std.log.scoped(.win32_app_toast);

/// How long a toast stays, milliseconds.
const duration_ms = 2000;
/// Gap to the window edge, as the 8 pt padding of the macOS overlays.
const margin_px = 8;
/// Room for the key state indicator below (its height and gap), logical px.
const stack_px = 40;

const Kind = enum { copied, cleared, reloaded, exported, export_failed };

fn textFor(kind: Kind) []const u8 {
    return switch (kind) {
        .copied => "Copied to clipboard",
        .cleared => "Cleared clipboard",
        .reloaded => "Reloaded the configuration",
        .exported => "Exported terminal IO",
        .export_failed => "Unable to export terminal IO",
    };
}

/// Whether `app-notifications` lets a toast of `kind` show.
fn enabled(notifications: configpkg.Config.AppNotifications, kind: Kind) bool {
    return switch (kind) {
        .copied, .cleared => notifications.@"clipboard-copy",
        .reloaded => notifications.@"config-reload",
        // The answer to an explicit save.
        .exported, .export_failed => true,
    };
}

pub fn configReloaded(app: *App) void {
    if (!enabled(app.config.@"app-notifications", .reloaded)) return;
    const window = app.last_active orelse app.lastNormalWindow() orelse return;
    const tab = window.activeTab() orelse return;
    const surface = tab.focusedSurface() orelse return;
    show(surface, .reloaded);
}

/// The export of the terminal IO finished (on a worker thread, reported here).
pub fn exportResult(app: *App, ok: bool) void {
    const window = app.last_active orelse app.lastNormalWindow() orelse return;
    const tab = window.activeTab() orelse return;
    const surface = tab.focusedSurface() orelse return;
    show(surface, if (ok) .exported else .export_failed);
}

/// After a successful write to the standard clipboard.
pub fn clipboardWritten(surface: *Surface, cleared: bool) void {
    const kind: Kind = if (cleared) .cleared else .copied;
    if (!enabled(surface.app.config.@"app-notifications", kind)) return;
    show(surface, kind);
}

fn show(surface: *Surface, kind: Kind) void {
    const state = &surface.badges;
    const label = state.toast orelse blk: {
        const l = badges.TextLabel.create(surface.app.core_app.alloc, surface, .window_bottom_center, margin_px, .plain) catch |err| {
            log.warn("unable to make a toast err={}", .{err});
            return;
        };
        state.toast = l;
        break :blk l;
    };
    // Above the key state indicator when that is shown.
    const indicator_shown = if (surface.key_state.label) |l| l.popup.visible else false;
    label.popup.margin = if (indicator_shown) margin_px + stack_px else margin_px;
    label.set(textFor(kind));
    label.show();
    label.popup.hideAfter(duration_ms);
}

test "win32 app_toast: gated by app-notifications" {
    const all: configpkg.Config.AppNotifications = .{};
    try std.testing.expect(enabled(all, .copied));
    try std.testing.expect(enabled(all, .cleared));
    try std.testing.expect(enabled(all, .reloaded));

    const no_clip: configpkg.Config.AppNotifications = .{ .@"clipboard-copy" = false };
    try std.testing.expect(!enabled(no_clip, .copied));
    try std.testing.expect(!enabled(no_clip, .cleared));
    try std.testing.expect(enabled(no_clip, .reloaded));

    const no_reload: configpkg.Config.AppNotifications = .{ .@"config-reload" = false };
    try std.testing.expect(enabled(no_reload, .copied));
    try std.testing.expect(!enabled(no_reload, .reloaded));

    try std.testing.expectEqualStrings("Copied to clipboard", textFor(.copied));
    try std.testing.expectEqualStrings("Cleared clipboard", textFor(.cleared));
    try std.testing.expectEqualStrings("Reloaded the configuration", textFor(.reloaded));
}
