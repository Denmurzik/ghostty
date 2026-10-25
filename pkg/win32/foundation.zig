//! Basic Win32 types shared by every binding file, plus the HRESULT to
//! Zig error mapping (SPEC section 4).
const std = @import("std");

const log = std.log.scoped(.win32);

pub const HRESULT = i32;
pub const BOOL = i32;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = HINSTANCE;
pub const HANDLE = *anyopaque;

pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    /// Parses the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form at
    /// comptime so IIDs can be copied verbatim from the SDK headers.
    pub fn parse(comptime s: *const [36]u8) GUID {
        return comptime parseImpl(s);
    }

    fn parseImpl(comptime s: *const [36]u8) GUID {
        if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-')
            @compileError("malformed GUID: " ++ s);
        var guid: GUID = undefined;
        guid.Data1 = hex(u32, s[0..8]);
        guid.Data2 = hex(u16, s[9..13]);
        guid.Data3 = hex(u16, s[14..18]);
        guid.Data4[0] = hex(u8, s[19..21]);
        guid.Data4[1] = hex(u8, s[21..23]);
        for (0..6) |i| guid.Data4[2 + i] = hex(u8, s[24 + i * 2 ..][0..2]);
        return guid;
    }

    fn hex(comptime T: type, comptime digits: []const u8) T {
        return std.fmt.parseInt(T, digits, 16) catch @compileError("malformed GUID digits: " ++ digits);
    }
};

pub const LUID = extern struct {
    LowPart: u32,
    HighPart: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

// HRESULT values that get dedicated errors. Bit patterns from winerror.h
// and winerror/dxgi error headers, reinterpreted as signed.
pub const S_OK: HRESULT = 0;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
pub const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
pub const DXGI_ERROR_WAS_STILL_DRAWING: HRESULT = @bitCast(@as(u32, 0x887A000A));

pub const Error = error{
    DeviceLost,
    OutOfMemory,
    WouldBlock,
    InvalidArgument,
    ComFailure,
};

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// Maps a failure HRESULT to its `Error`. Does not log.
pub fn mapHresult(hr: HRESULT) Error {
    return switch (hr) {
        DXGI_ERROR_DEVICE_REMOVED,
        DXGI_ERROR_DEVICE_RESET,
        DXGI_ERROR_DEVICE_HUNG,
        => error.DeviceLost,
        E_OUTOFMEMORY => error.OutOfMemory,
        DXGI_ERROR_WAS_STILL_DRAWING => error.WouldBlock,
        E_INVALIDARG => error.InvalidArgument,
        else => error.ComFailure,
    };
}

/// Returns normally for any success HRESULT (including `S_FALSE`), else
/// the mapped error. Unmapped failures are logged with their hex value.
pub fn check(hr: HRESULT) Error!void {
    if (succeeded(hr)) return;
    const err = mapHresult(hr);
    if (err == error.ComFailure) log.err("COM call failed: HRESULT 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
    return err;
}
