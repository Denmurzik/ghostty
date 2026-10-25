//! Tests for the user32/kernel32/imm32 bindings: struct layouts against the
//! Windows SDK 10.0.26100 headers (64-bit) and a real message-only window
//! roundtrip.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const user32 = win32.user32;
const kernel32 = win32.kernel32;
const imm32 = win32.imm32;

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
