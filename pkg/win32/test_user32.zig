//! Tests for the user32/kernel32/imm32 bindings: struct layouts against the
//! Windows SDK 10.0.26100 headers (64-bit) and a real message-only window
//! roundtrip.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const user32 = win32.user32;
const kernel32 = win32.kernel32;
const imm32 = win32.imm32;
const advapi32 = win32.advapi32;
const dwmapi = win32.dwmapi;
const gdi32 = win32.gdi32;

test "win32 user32: message-only window roundtrip" {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32Test");
    const instance = kernel32.GetModuleHandleW(null);

    const class: user32.WNDCLASSEXW = .{
        .lpfnWndProc = user32.DefWindowProcW,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    try std.testing.expect(user32.RegisterClassExW(&class) != 0);
    defer _ = user32.UnregisterClassW(class_name, instance);

    const hwnd = user32.CreateWindowExW(
        0,
        class_name,
        null,
        0,
        0,
        0,
        0,
        0,
        user32.HWND_MESSAGE,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    defer _ = user32.DestroyWindow(hwnd);
    try std.testing.expect(user32.IsWindow(hwnd) != 0);

    try std.testing.expect(user32.PostMessageW(hwnd, user32.WM_APP + 7, 42, 0) != 0);

    var msg: user32.MSG = .{};
    try std.testing.expect(user32.PeekMessageW(&msg, hwnd, 0, 0, user32.PM_REMOVE) != 0);
    try std.testing.expectEqual(@as(u32, user32.WM_APP + 7), msg.message);
    try std.testing.expectEqual(@as(usize, 42), msg.wParam);
    try std.testing.expectEqual(@as(isize, 0), msg.lParam);
}

test "win32 user32: user data pointer roundtrip" {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32TestData");
    const instance = kernel32.GetModuleHandleW(null);
    const class: user32.WNDCLASSEXW = .{
        .lpfnWndProc = user32.DefWindowProcW,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    try std.testing.expect(user32.RegisterClassExW(&class) != 0);
    defer _ = user32.UnregisterClassW(class_name, instance);

    const hwnd = user32.CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, user32.HWND_MESSAGE, null, instance, null) orelse
        return error.CreateWindowFailed;
    defer _ = user32.DestroyWindow(hwnd);

    var value: u32 = 7;
    _ = user32.SetWindowLongPtrW(hwnd, user32.GWLP_USERDATA, @bitCast(@intFromPtr(&value)));
    const back: *u32 = @ptrFromInt(@as(usize, @bitCast(user32.GetWindowLongPtrW(hwnd, user32.GWLP_USERDATA))));
    try std.testing.expectEqual(&value, back);
}

test "win32 user32: struct layouts" {
    // x86_64 and aarch64 share the LLP64 layout the SDK sizes below assume.
    try std.testing.expectEqual(80, @sizeOf(user32.WNDCLASSEXW));
    try std.testing.expectEqual(48, @sizeOf(user32.MSG));
    try std.testing.expectEqual(80, @sizeOf(user32.CREATESTRUCTW));
    try std.testing.expectEqual(40, @sizeOf(user32.MINMAXINFO));
    try std.testing.expectEqual(24, @sizeOf(user32.TRACKMOUSEEVENT));
    try std.testing.expectEqual(24, @sizeOf(user32.KEYBDINPUT));
    try std.testing.expectEqual(32, @sizeOf(user32.MOUSEINPUT));
    try std.testing.expectEqual(40, @sizeOf(user32.INPUT));
    try std.testing.expectEqual(8, @offsetOf(user32.INPUT, "u"));
    try std.testing.expectEqual(72, @sizeOf(user32.PAINTSTRUCT));
    try std.testing.expectEqual(80, @sizeOf(kernel32.PROCESS_MEMORY_COUNTERS_EX));
    try std.testing.expectEqual(28, @sizeOf(imm32.COMPOSITIONFORM));
    try std.testing.expectEqual(32, @sizeOf(imm32.CANDIDATEFORM));
}

test "win32 user32: constants and message helpers" {
    try std.testing.expectEqual(std.math.maxInt(usize) - 2, @intFromPtr(user32.HWND_MESSAGE));
    try std.testing.expectEqual(0xE7, user32.VK_PACKET);
    try std.testing.expectEqual(0xE5, user32.VK_PROCESSKEY);
    try std.testing.expectEqual(std.math.minInt(i32), user32.CW_USEDEFAULT);

    // Negative coordinates (monitors left of / above the primary) must keep
    // their sign when unpacked from an LPARAM.
    const lp = user32.makeLparam(@bitCast(@as(i16, -5)), 12);
    try std.testing.expectEqual(@as(i32, -5), user32.getXLparam(lp));
    try std.testing.expectEqual(@as(i32, 12), user32.getYLparam(lp));

    const wp: usize = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    try std.testing.expectEqual(@as(i16, -user32.WHEEL_DELTA), user32.getWheelDelta(wp));
}

test "win32 kernel32: global memory roundtrip" {
    const mem = kernel32.GlobalAlloc(kernel32.GMEM_MOVEABLE, 16) orelse return error.OutOfMemory;
    defer _ = kernel32.GlobalFree(mem);
    try std.testing.expect(kernel32.GlobalSize(mem) >= 16);
    const ptr: [*]u8 = @ptrCast(kernel32.GlobalLock(mem) orelse return error.LockFailed);
    ptr[0] = 0xAB;
    _ = kernel32.GlobalUnlock(mem);
    const again: [*]u8 = @ptrCast(kernel32.GlobalLock(mem).?);
    defer _ = kernel32.GlobalUnlock(mem);
    try std.testing.expectEqual(@as(u8, 0xAB), again[0]);
}

test "win32 kernel32: process memory counters" {
    var counters: kernel32.PROCESS_MEMORY_COUNTERS_EX = .{};
    try std.testing.expect(kernel32.K32GetProcessMemoryInfo(
        kernel32.GetCurrentProcess(),
        &counters,
        @sizeOf(kernel32.PROCESS_MEMORY_COUNTERS_EX),
    ) != 0);
    try std.testing.expect(counters.WorkingSetSize > 0);
}

test "win32 advapi32: current user SID string starts with S-1-5-" {
    var token: win32.foundation.HANDLE = undefined;
    try std.testing.expect(advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), advapi32.TOKEN_QUERY, &token) != 0);
    defer _ = kernel32.CloseHandle(token);

    var buf: [256]u8 align(8) = undefined;
    var len: u32 = 0;
    try std.testing.expect(advapi32.GetTokenInformation(token, advapi32.TokenUser, &buf, buf.len, &len) != 0);
    const user: *const advapi32.TOKEN_USER = @ptrCast(&buf);
    const sid = user.User.Sid orelse return error.NoSid;

    var wide: ?[*:0]u16 = null;
    try std.testing.expect(advapi32.ConvertSidToStringSidW(sid, &wide) != 0);
    defer _ = kernel32.LocalFree(wide);
    var out: [128]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&out, std.mem.span(wide.?));
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "S-1-5-"));
    try std.testing.expect(advapi32.EqualSid(sid, sid) != 0);
}

test "win32 advapi32: token elevation query succeeds" {
    var token: win32.foundation.HANDLE = undefined;
    try std.testing.expect(advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), advapi32.TOKEN_QUERY, &token) != 0);
    defer _ = kernel32.CloseHandle(token);

    // The value depends on how the test runner was started: recorded, not asserted.
    var elevation: advapi32.TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var len: u32 = 0;
    try std.testing.expect(advapi32.GetTokenInformation(token, advapi32.TokenElevation, &elevation, @sizeOf(advapi32.TOKEN_ELEVATION), &len) != 0);
    try std.testing.expectEqual(@sizeOf(advapi32.TOKEN_ELEVATION), len);
    std.log.info("token elevated: {}", .{elevation.TokenIsElevated});
}

test "win32 kernel32: named pipe loopback" {
    var name_buf: [64:0]u16 = undefined;
    const pid = kernel32.GetCurrentProcessId();
    var utf8: [64]u8 = undefined;
    const name8 = try std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\ghostty-test-{d}", .{pid});
    const name_len = try std.unicode.utf8ToUtf16Le(&name_buf, name8);
    name_buf[name_len] = 0;
    const name: [*:0]const u16 = &name_buf;

    const server = kernel32.CreateNamedPipeW(
        name,
        kernel32.PIPE_ACCESS_DUPLEX | kernel32.FILE_FLAG_OVERLAPPED | kernel32.FILE_FLAG_FIRST_PIPE_INSTANCE,
        kernel32.PIPE_TYPE_BYTE | kernel32.PIPE_READMODE_BYTE | kernel32.PIPE_WAIT | kernel32.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        256,
        256,
        0,
        null,
    );
    try std.testing.expect(server != kernel32.INVALID_HANDLE_VALUE);
    defer _ = kernel32.CloseHandle(server);

    // Overlapped accept: pending (or already connected) until the client opens.
    const event = kernel32.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = kernel32.CloseHandle(event);
    var overlapped: kernel32.OVERLAPPED = .{ .hEvent = event };
    if (kernel32.ConnectNamedPipe(server, &overlapped) == 0) {
        const err = kernel32.GetLastError();
        try std.testing.expect(err == kernel32.ERROR_IO_PENDING or err == kernel32.ERROR_PIPE_CONNECTED);
    }

    const client = kernel32.CreateFileW(
        name,
        kernel32.GENERIC_READ | kernel32.GENERIC_WRITE,
        0,
        null,
        kernel32.OPEN_EXISTING,
        kernel32.SECURITY_SQOS_PRESENT | kernel32.SECURITY_IDENTIFICATION,
        null,
    );
    try std.testing.expect(client != kernel32.INVALID_HANDLE_VALUE);
    defer _ = kernel32.CloseHandle(client);
    try std.testing.expectEqual(@as(u32, kernel32.WAIT_OBJECT_0), kernel32.WaitForSingleObjectEx(event, 5000, 0));

    var server_pid: u32 = 0;
    try std.testing.expect(kernel32.GetNamedPipeServerProcessId(client, &server_pid) != 0);
    try std.testing.expectEqual(pid, server_pid);

    var written: u32 = 0;
    try std.testing.expect(kernel32.WriteFile(client, "hello", 5, &written, null) != 0);
    try std.testing.expectEqual(@as(u32, 5), written);

    // The server end is overlapped, so its read completes through the event.
    var read_buf: [8]u8 = undefined;
    var read: u32 = 0;
    var read_ov: kernel32.OVERLAPPED = .{ .hEvent = event };
    _ = kernel32.ResetEvent(event);
    if (kernel32.ReadFile(server, &read_buf, read_buf.len, &read, &read_ov) == 0) {
        try std.testing.expectEqual(@as(u32, kernel32.ERROR_IO_PENDING), kernel32.GetLastError());
    }
    try std.testing.expect(kernel32.GetOverlappedResult(server, &read_ov, &read, 1) != 0);
    try std.testing.expectEqualStrings("hello", read_buf[0..read]);
}

test "win32 dwmapi: MARGINS size" {
    try std.testing.expectEqual(16, @sizeOf(dwmapi.MARGINS));
    try std.testing.expectEqual(4, dwmapi.DWMSBT_TABBEDWINDOW);
}

// Sizes from a throwaway `zig cc -target x86_64-windows-msvc` program against
// Windows SDK 10.0.26100 headers (sizeof of the C types).
test "win32 user32: BLENDFUNCTION and NCCALCSIZE_PARAMS sizes" {
    try std.testing.expectEqual(4, @sizeOf(user32.BLENDFUNCTION));
    try std.testing.expectEqual(56, @sizeOf(user32.NCCALCSIZE_PARAMS));
    try std.testing.expectEqual(48, @offsetOf(user32.NCCALCSIZE_PARAMS, "lppos"));
    try std.testing.expectEqual(40, @sizeOf(user32.WINDOWPOS));
    try std.testing.expectEqual(44, @sizeOf(user32.WINDOWPLACEMENT));
    try std.testing.expectEqual(40, @sizeOf(user32.MONITORINFO));
    try std.testing.expectEqual(28, @sizeOf(user32.SCROLLINFO));
    try std.testing.expectEqual(32, @sizeOf(user32.FLASHWINFO));
    try std.testing.expectEqual(16, @sizeOf(user32.HIGHCONTRASTW));
    try std.testing.expectEqual(8, @sizeOf(user32.CHANGEFILTERSTRUCT));
    try std.testing.expectEqual(20, @sizeOf(user32.TPMPARAMS));
    try std.testing.expectEqual(8, @sizeOf(user32.SIZE));
}

test "win32 kernel32/advapi32/gdi32: struct layouts" {
    try std.testing.expectEqual(32, @sizeOf(kernel32.OVERLAPPED));
    try std.testing.expectEqual(24, @sizeOf(kernel32.SECURITY_ATTRIBUTES));
    try std.testing.expectEqual(64, @sizeOf(kernel32.MEMORYSTATUSEX));
    try std.testing.expectEqual(16, @sizeOf(advapi32.TOKEN_USER));
    try std.testing.expectEqual(4, @sizeOf(advapi32.TOKEN_ELEVATION));
    try std.testing.expectEqual(40, @sizeOf(gdi32.BITMAPINFOHEADER));
    try std.testing.expectEqual(44, @sizeOf(gdi32.BITMAPINFO));
}

test "win32 kernel32: global memory status" {
    var status: kernel32.MEMORYSTATUSEX = .{};
    try std.testing.expect(kernel32.GlobalMemoryStatusEx(&status) != 0);
    try std.testing.expect(status.ullTotalPhys > 0);
}
