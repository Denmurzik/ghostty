//! A read-only memory mapping of a font file, opened through a UTF-16
//! path. FreeType's own path-based loader uses the narrow C runtime
//! `fopen`, which cannot open fonts below non-ASCII profile or install
//! directories; mapping the file ourselves and handing the bytes to
//! FreeType as a memory face sidesteps that, and the mapped pages are
//! shared with the OS file cache instead of becoming private bytes.
const WindowsFontFile = @This();

const std = @import("std");
const windows = @import("../os/windows.zig");

const log = std.log.scoped(.font_windows_file);

/// Start of the mapped view. Valid until `close`.
view: [*]const u8,
len: usize,

/// Wide path buffer size: the 32767 code unit Windows path limit plus NUL.
const max_path_wide = 32768;

pub const OpenError = error{
    InvalidPath,
    OpenFailed,
    MapFailed,
    EmptyFile,
    FileTooLarge,
};

/// Map the file at `path_utf8` (WTF-8, as produced by directory
/// iteration) read-only.
pub fn open(path_utf8: []const u8) OpenError!WindowsFontFile {
    var path_w: [max_path_wide]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(path_w[0 .. max_path_wide - 1], path_utf8) catch
        return error.InvalidPath;
    path_w[len] = 0;
    const path_z: [*:0]const u16 = @ptrCast(&path_w);

    const file = windows.exp.kernel32.CreateFileW(
        path_z,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (file == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
    // The view keeps the underlying section (and file) alive, so both
    // handles can go as soon as the view exists.
    defer _ = windows.exp.kernel32.CloseHandle(file);

    var size: windows.LARGE_INTEGER = undefined;
    if (!windows.GetFileSizeEx(file, &size).toBool()) return error.OpenFailed;
    if (size <= 0) return error.EmptyFile;
    const len_bytes = std.math.cast(usize, size) orelse return error.FileTooLarge;

    const mapping = windows.CreateFileMappingW(
        file,
        null,
        windows.PAGE_READONLY,
        0,
        0,
        null,
    ) orelse return error.MapFailed;
    defer _ = windows.exp.kernel32.CloseHandle(mapping);

    const view = windows.MapViewOfFile(
        mapping,
        windows.FILE_MAP_READ,
        0,
        0,
        0,
    ) orelse return error.MapFailed;

    return .{ .view = @ptrCast(view), .len = len_bytes };
}

pub fn bytes(self: *const WindowsFontFile) []const u8 {
    return self.view[0..self.len];
}

pub fn close(self: *WindowsFontFile) void {
    if (!windows.UnmapViewOfFile(self.view).toBool()) {
        log.warn("UnmapViewOfFile failed err={}", .{windows.GetLastError()});
    }
    self.* = undefined;
}
