//! The "cols x rows" overlay shown while resizing. Stub: Task 24.
const win32 = @import("win32");
const Surface = @import("Surface.zig");

pub const State = struct {
    hwnd: ?win32.foundation.HWND = null,
    armed: bool = false,
};

pub fn notify(surface: *Surface, cols: u32, rows: u32) void {
    _ = surface;
    _ = cols;
    _ = rows;
}

pub fn deinit(state: *State) void {
    _ = state;
}
