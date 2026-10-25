//! Modal confirmation dialogs. Stub: filled in by a later task.
const std = @import("std");
const win32 = @import("win32");

const IDYES = 6;

/// Ask whether a surface with a running process may be closed.
pub fn confirmClose(owner: win32.foundation.HWND) bool {
    return confirm(
        owner,
        std.unicode.utf8ToUtf16LeStringLiteral("Close Terminal"),
        std.unicode.utf8ToUtf16LeStringLiteral("A process is still running in this terminal. Close it anyway?"),
    );
}

/// Show a yes/no question on top of `owner`. True for yes.
pub fn confirm(
    owner: ?win32.foundation.HWND,
    title: [*:0]const u16,
    text: [*:0]const u16,
) bool {
    const result = win32.user32.MessageBoxW(
        owner,
        text,
        title,
        win32.user32.MB_YESNO | win32.user32.MB_ICONQUESTION,
    );
    return result == IDYES;
}
