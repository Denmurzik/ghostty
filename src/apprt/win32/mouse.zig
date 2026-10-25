//! Win32 mouse message handling. Stub: filled in by a later task.
const win32 = @import("win32");
const Surface = @import("Surface.zig");

/// Per-surface mouse state.
pub const State = struct {};

/// Handle a window message for `surface`. Null means not handled, and the
/// next handler (or the default window procedure) gets the message.
pub fn handle(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = surface;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}
