//! Win32 clipboard access for a surface. Stub: filled in by a later task.
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const Surface = @import("Surface.zig");

/// Per-surface clipboard state.
pub const State = struct {};

/// Handle a window message for `surface`. Null means not handled, and the
/// default window procedure gets the message.
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

pub fn supports(clipboard_type: apprt.Clipboard) bool {
    _ = clipboard_type;
    return false;
}

pub fn request(
    surface: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    _ = surface;
    _ = clipboard_type;
    _ = state;
    return .unsupported;
}

pub fn write(
    surface: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = surface;
    _ = clipboard_type;
    _ = contents;
    _ = confirm;
    return error.Unsupported;
}

/// Deny every clipboard request still pending for `surface`. Called before
/// the core surface is torn down.
pub fn cancelPending(surface: *Surface) void {
    _ = surface;
}
