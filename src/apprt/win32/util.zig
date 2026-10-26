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

/// Answer what other threads have sent to this thread's windows (a
/// `WM_NULL` liveness probe, a settings broadcast, ...) without taking
/// anything off the posted queue. Called between the slices of a long
/// teardown on the UI thread, so that the other windows are not reported
/// as hung. Whatever is dispatched here runs with the teardown half done:
/// the caller guards the state it is taking apart.
pub fn serviceSentMessages() void {
    var msg: win32.user32.MSG = undefined;
    _ = win32.user32.PeekMessageW(&msg, null, 0, 0, win32.user32.PM_NOREMOVE | win32.user32.PM_QS_SENDMESSAGE);
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
    const rc = win32.advapi32.RegGetValueW(
        win32.advapi32.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme"),
        win32.advapi32.RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    return rc == 0 and data == 0;
}

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

test "win32 util: serviceSentMessages leaves the posted queue alone" {
    const user32 = win32.user32;
    // A posted thread message stays queued: only sent messages are handled.
    _ = user32.PostMessageW(null, user32.WM_APP + 1, 0, 0);
    serviceSentMessages();
    var msg: user32.MSG = undefined;
    try std.testing.expect(user32.PeekMessageW(&msg, null, 0, 0, user32.PM_REMOVE) != 0);
    try std.testing.expectEqual(@as(u32, user32.WM_APP + 1), msg.message);
}

test "win32 util: serviceSentMessages answers a message sent from another thread" {
    const user32 = win32.user32;
    const SendMessageTimeoutW = struct {
        extern "user32" fn SendMessageTimeoutW(
            win32.foundation.HWND,
            u32,
            win32.foundation.WPARAM,
            win32.foundation.LPARAM,
            flags: u32,
            timeout: u32,
            result: *usize,
        ) callconv(.winapi) isize;
    }.SendMessageTimeoutW;

    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const hwnd = user32.CreateWindowExW(0, class, null, 0, 0, 0, 0, 0, user32.HWND_MESSAGE, null, null, null) orelse
        return error.SkipZigTest;
    defer _ = user32.DestroyWindow(hwnd);

    const Probe = struct {
        hwnd: win32.foundation.HWND,
        answered: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var result: usize = 0;
            const ok = SendMessageTimeoutW(self.hwnd, user32.WM_NULL, 0, 0, 0, 5000, &result);
            self.answered.store(ok != 0, .release);
            self.done.store(true, .release);
        }
    };
    var probe: Probe = .{ .hwnd = hwnd };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    defer thread.join();

    // The probe is only delivered while this thread services its queue.
    var spins: usize = 0;
    while (!probe.done.load(.acquire) and spins < 5000) : (spins += 1) {
        serviceSentMessages();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(probe.done.load(.acquire));
    try std.testing.expect(probe.answered.load(.acquire));
}
