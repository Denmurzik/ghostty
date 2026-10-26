//! shell32 bindings (shell execute, notification icons, drag and drop). Filled by the tasks that first call them.

const foundation = @import("foundation.zig");

/// The result is an HINSTANCE-typed integer: a value above 32 is success, the rest are the `SE_ERR_*` codes.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?foundation.HWND,
    operation: ?[*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show: i32,
) callconv(.winapi) isize;

/// No application is associated with the file.
pub const SE_ERR_NOASSOC = 31;
