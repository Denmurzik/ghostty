//! Split drag session: a press on a pane's grab handle starts a drag of the
//! pane, which can end in the same tab, another tab, another window or a new
//! window. This file is the entry point the grab handle (`grab_overlay.zig`)
//! and the window's hook list use; the session itself is filled in by the
//! drag-session task.
const win32 = @import("win32");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

/// A left press on the grab handle of `s` at the client point `(x, y)`; the
/// press has been eaten (the terminal does not see it). Starts the drag
/// session.
pub fn press(s: *Surface, x: i32, y: i32) void {
    _ = s;
    _ = x;
    _ = y;
}

/// A message of a top-level window while a drag session runs (capture,
/// motion, release, cancel). Null: not handled, the next hook gets it.
pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}
