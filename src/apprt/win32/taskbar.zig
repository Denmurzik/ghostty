//! Taskbar progress and attention state. Stub: Task 26.
const win32 = @import("win32");
const terminal = @import("../../terminal/main.zig");
const Window = @import("Window.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const State = struct {
    progress: ?terminal.osc.Command.ProgressReport = null,
};

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}
