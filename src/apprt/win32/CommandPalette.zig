//! The command palette overlay.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_palette);

/// Per top-level window: the open palette, if any.
pub const State = struct {};

/// Closes the palette when `surface` is its target.
pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

/// `WM_GHOSTTY_OVERLAY_CMD` on a top-level window; true when the command
/// was for the palette.
pub fn command(window: *Window, lparam: win32.foundation.LPARAM) bool {
    _ = window;
    _ = lparam;
    return false;
}

pub fn toggle(app: *App, target: apprt.Target) bool {
    _ = app;
    _ = target;
    log.debug("M3 stub action=toggle_command_palette", .{});
    return false;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
