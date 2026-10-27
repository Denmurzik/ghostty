//! Saves the terminal IO log of the inspector to a file.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_export_io);

/// In test mode the destination is a fixed path and no dialog is shown (the
/// IPC op `export-io` supplies it).
pub fn save(app: *App, target: apprt.Target, value: apprt.Action.Value(.export_terminal_io)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=export_terminal_io", .{});
    return false;
}

/// The test-mode entry (IPC op `export-io`): no dialog, the bytes go to `path`.
pub fn saveTest(app: *App, target: apprt.Target, value: apprt.Action.Value(.export_terminal_io), path: []const u8) bool {
    _ = app;
    _ = target;
    _ = value;
    _ = path;
    return false;
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `export_io`.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    _ = window;
    _ = lparam;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.endObject();
}
