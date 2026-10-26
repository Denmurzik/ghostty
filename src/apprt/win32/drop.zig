//! Files dropped from Explorer, pasted as shell-quoted paths. Stub: Task 38.
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Window = @import("Window.zig");

const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

pub const ShellKind = enum { msys, wsl, pwsh, cmd };

pub fn shellKindFor(command: ?configpkg.Command) ShellKind {
    _ = command;
    return .cmd;
}

pub fn register(window: *Window) void {
    _ = window;
}

pub fn revoke(window: *Window) void {
    _ = window;
}

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = window;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}
