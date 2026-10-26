//! Mouse input on the tab strip: hover, click, tab drag. Stub: Task 19.
const win32 = @import("win32");
const Window = @import("Window.zig");
const TabStrip = @import("TabStrip.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const State = struct {
    drag: ?TabStrip.Drag = null,
    hover: TabStrip.Part = .nowhere,
    tracking: bool = false,
    /// Insertion marker drawn while another window's tab is dragged over
    /// this strip (Task 32).
    drop_index: ?usize = null,
};

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}
