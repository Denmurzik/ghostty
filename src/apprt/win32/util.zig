//! Small Win32 helpers shared by the apprt: UTF-8/UTF-16 conversion,
//! window user-data lookup, class registration and system theme query.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");

const log = std.log.scoped(.win32_util);

/// Convert UTF-8 to a null-terminated UTF-16LE string. Caller owns the
/// result. Invalid UTF-8 returns `error.InvalidUtf8`.
pub fn utf16z(alloc: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

/// Convert UTF-16LE to UTF-8. Caller owns the result. Unpaired surrogates
/// return `error.UnexpectedSecondSurrogateHalf` or
/// `error.DanglingSurrogateHalf`.
pub fn utf8(alloc: Allocator, s: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, s);
}

/// The object pointer stored in a window's GWLP_USERDATA, or null if
/// none has been stored (yet, or any more).
pub fn fromUserData(comptime T: type, hwnd: win32.foundation.HWND) ?*T {
    const value = win32.user32.GetWindowLongPtrW(hwnd, win32.user32.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

pub fn setUserData(hwnd: win32.foundation.HWND, ptr: ?*anyopaque) void {
    _ = win32.user32.SetWindowLongPtrW(
        hwnd,
        win32.user32.GWLP_USERDATA,
        @bitCast(@intFromPtr(ptr)),
    );
}

/// Register a window class. A class that is already registered is fine:
/// classes live for the whole process, so a second registration (another
/// App instance, a test) just reuses it.
pub fn registerClass(class: *const win32.user32.WNDCLASSEXW) !void {
    if (win32.user32.RegisterClassExW(class) != 0) return;
    const err = win32.kernel32.GetLastError();
    if (err == ERROR_CLASS_ALREADY_EXISTS) return;
    log.err("RegisterClassExW failed err={}", .{err});
    return error.RegisterClassFailed;
}

const ERROR_CLASS_ALREADY_EXISTS = 1410;

/// Whether the user prefers dark app windows. Defaults to light when the
/// setting is absent (older builds) or unreadable.
pub fn systemUsesDarkTheme() bool {
    var data: u32 = 1;
    var size: u32 = @sizeOf(u32);
    const rc = RegGetValueW(
        HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme"),
        RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    return rc == 0 and data == 0;
}

const HKEY_CURRENT_USER: ?*anyopaque = @ptrFromInt(0x80000001);
const RRF_RT_REG_DWORD = 0x00000010;
extern "advapi32" fn RegGetValueW(
    hkey: ?*anyopaque,
    subkey: [*:0]const u16,
    value: [*:0]const u16,
    flags: u32,
    type_out: ?*u32,
    data: *u32,
    size: *u32,
) callconv(.winapi) i32;

test "win32 util: utf16 roundtrip with non-BMP" {
    const alloc = std.testing.allocator;
    const src = "a😀Ж";

    const wide = try utf16z(alloc, src);
    defer alloc.free(wide);
    // 'a' + surrogate pair + Cyrillic.
    try std.testing.expectEqual(@as(usize, 4), wide.len);
    try std.testing.expectEqual(@as(u16, 0), wide[wide.len]);

    const back = try utf8(alloc, wide);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(src, back);
}

test "win32 util: utf16 rejects unpaired surrogate" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.DanglingSurrogateHalf,
        utf8(alloc, &.{ 'a', 0xD83D }),
    );
}
