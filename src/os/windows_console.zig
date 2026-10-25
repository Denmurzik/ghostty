//! Console access for the GUI-subsystem `ghostty.exe`.
//!
//! The Windows exe is linked for the GUI subsystem so that launching it
//! never flashes a console window. The price is that a process started
//! from cmd or Git Bash has no usable stdin/stdout/stderr, so CLI actions
//! (`ghostty.exe +version`, `+list-fonts`, ...) would print into the void.
//! `ensureConsoleForCli` attaches to the parent's console and points the
//! standard handles at it. Handles that were redirected (`| cat`, `> f`)
//! are valid already and are left alone.
//!
//! Limitation: cmd does not wait for a GUI-subsystem process, so without a
//! pipe the prompt can reappear before the output (`... | more` waits).

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");

/// True if the standard handle `which` (a `windows.STD_*_HANDLE`) can be
/// used for I/O: neither missing (null) nor invalid.
fn stdHandleValid(which: windows.DWORD) bool {
    const h = windows.GetStdHandle(which) orelse return false;
    return h != windows.INVALID_HANDLE_VALUE;
}

/// True if there is somewhere for stderr output to go. The stderr log sink
/// checks this because a GUI-subsystem process starts without one.
pub fn stderrValid() bool {
    if (comptime builtin.os.tag != .windows) return true;
    return stdHandleValid(windows.STD_ERROR_HANDLE);
}

/// Opens CONIN$/CONOUT$ of the attached console and installs it as the
/// standard handle `which`.
/// Output handles also get VT processing so escape sequences that CLI
/// actions emit on a tty (e.g. the OSC 8 links in `+version`) render
/// instead of printing as text.
fn setFromConsole(which: windows.DWORD, name: [*:0]const u16, vt: bool) void {
    const h = windows.exp.kernel32.CreateFileW(
        name,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == windows.INVALID_HANDLE_VALUE) return;
    if (vt) {
        var mode: windows.DWORD = 0;
        if (windows.GetConsoleMode(h, &mode).toBool()) {
            _ = windows.SetConsoleMode(h, mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
    _ = windows.SetStdHandle(which, h);
}

/// Attach to the parent process's console, if there is one, and give any
/// missing standard handle the console as its target. Safe to call more
/// than once and a no-op when all three handles are already valid. When
/// there is no parent console (started from Explorer) nothing changes.
pub fn ensureConsoleForCli() void {
    if (comptime builtin.os.tag != .windows) return;

    const in_ok = stdHandleValid(windows.STD_INPUT_HANDLE);
    const out_ok = stdHandleValid(windows.STD_OUTPUT_HANDLE);
    const err_ok = stdHandleValid(windows.STD_ERROR_HANDLE);
    if (in_ok and out_ok and err_ok) return;

    // Fails with ERROR_ACCESS_DENIED if we are already attached, which is
    // fine: the CONIN$/CONOUT$ opens below then still work.
    _ = windows.AttachConsole(windows.ATTACH_PARENT_PROCESS);

    const conin = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
    const conout = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
    if (!in_ok) setFromConsole(windows.STD_INPUT_HANDLE, conin, false);
    if (!out_ok) setFromConsole(windows.STD_OUTPUT_HANDLE, conout, true);
    if (!err_ok) setFromConsole(windows.STD_ERROR_HANDLE, conout, true);
}

test "windows log: console helpers are safe to call" {
    // A test process may or may not have a console; this only checks that
    // the calls do not crash and are idempotent.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const before = stderrValid();
    ensureConsoleForCli();
    ensureConsoleForCli();
    // Attaching can only make a missing handle valid, never the reverse.
    if (before) try std.testing.expect(stderrValid());
}
