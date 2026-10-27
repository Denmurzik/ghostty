//! shlwapi bindings. `AssocIsDangerous` is resolved on first use like
//! `comctl32.taskDialogIndirect`, so the test executables and lib-vt
//! consumers do not link shlwapi.

const std = @import("std");
const foundation = @import("foundation.zig");
const kernel32 = @import("kernel32.zig");

const BOOL = foundation.BOOL;

const AssocIsDangerousFn = *const fn ([*:0]const u16) callconv(.winapi) BOOL;

/// The cached entry point is unsynchronized: call from the UI thread only.
fn assocIsDangerousProc() ?AssocIsDangerousFn {
    const S = struct {
        var proc: ?AssocIsDangerousFn = null;
        var resolved = false;
    };
    if (!S.resolved) {
        S.resolved = true;
        const lib = std.unicode.utf8ToUtf16LeStringLiteral("shlwapi.dll");
        // LOAD_LIBRARY_SEARCH_SYSTEM32.
        const module = kernel32.LoadLibraryExW(lib, null, 0x00000800) orelse return null;
        const addr = kernel32.GetProcAddress(module, "AssocIsDangerous") orelse return null;
        S.proc = @ptrCast(@alignCast(addr));
    }
    return S.proc;
}

/// Whether Windows treats files with this extension (".exe", with the dot)
/// as executable content. Null when the entry point is unavailable.
pub fn assocIsDangerous(extension: [*:0]const u16) ?bool {
    const proc = assocIsDangerousProc() orelse return null;
    return proc(extension) != 0;
}
