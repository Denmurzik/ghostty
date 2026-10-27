//! In-app toasts: config reloaded, copied to the clipboard.
//! M3 skeleton: the hooks exist, the bodies come with the feature.
const App = @import("App.zig");
const Surface = @import("Surface.zig");

pub fn configReloaded(app: *App) void {
    _ = app;
}

pub fn clipboardWritten(surface: *Surface, cleared: bool) void {
    _ = surface;
    _ = cleared;
}
