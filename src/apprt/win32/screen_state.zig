//! Whether anything of the app can be seen: the session is locked, the
//! display is off or the session is disconnected (remote or console).
//! Pure decoders of the notifications App receives; App owns the state and
//! applies it to the windows.
const std = @import("std");
const win32 = @import("win32");

const user32 = win32.user32;
const wtsapi32 = win32.wtsapi32;

/// `GUID_CONSOLE_DISPLAY_STATE`: the data is a u32, 0 off, 1 on, 2 dimmed.
pub const GUID_CONSOLE_DISPLAY_STATE = win32.foundation.GUID.parse("6fe69556-704a-47a0-8f24-c28d936fda47");

pub const Screen = struct {
    locked: bool = false,
    display_off: bool = false,
    /// The session has no console or remote connection (RDP closed, fast
    /// user switch away).
    disconnected: bool = false,
};

/// Nothing can be seen.
pub fn off(s: Screen) bool {
    return s.locked or s.display_off or s.disconnected;
}

/// `WM_WTSSESSION_CHANGE` wparam: lock and connection state. Other codes
/// (logon, logoff, remote control) change nothing.
pub fn onSession(s: Screen, wparam: usize) Screen {
    var next = s;
    switch (wparam) {
        wtsapi32.WTS_SESSION_LOCK => next.locked = true,
        wtsapi32.WTS_SESSION_UNLOCK => next.locked = false,
        wtsapi32.WTS_CONSOLE_DISCONNECT, wtsapi32.WTS_REMOTE_DISCONNECT => next.disconnected = true,
        wtsapi32.WTS_CONSOLE_CONNECT, wtsapi32.WTS_REMOTE_CONNECT => next.disconnected = false,
        else => {},
    }
    return next;
}

/// `GUID_CONSOLE_DISPLAY_STATE` data: 0 off, 1 on, 2 dimmed (dimmed counts
/// as on).
pub fn onDisplayState(s: Screen, data: u32) Screen {
    var next = s;
    next.display_off = data == 0;
    return next;
}

/// The display state of a `PBT_POWERSETTINGCHANGE` payload; null for another
/// setting or a short payload.
pub fn displayStateOf(setting: *const user32.POWERBROADCAST_SETTING) ?u32 {
    if (!std.meta.eql(setting.PowerSetting, GUID_CONSOLE_DISPLAY_STATE)) return null;
    if (setting.DataLength < @sizeOf(u32)) return null;
    // `Data` is the start of DataLength bytes that may be unaligned.
    const data: [*]const u8 = @ptrCast(&setting.Data);
    return std.mem.readInt(u32, data[0..4], .little);
}

/// Whether a WinEvent is the cloak change of a window: true cloaked, false
/// uncloaked, null anything else (other event, or an object that is not the
/// window itself).
pub fn isCloakEvent(event: u32, id_object: i32, id_child: i32) ?bool {
    if (id_object != user32.OBJID_WINDOW or id_child != user32.CHILDID_SELF) return null;
    return switch (event) {
        user32.EVENT_OBJECT_CLOAKED => true,
        user32.EVENT_OBJECT_UNCLOAKED => false,
        else => null,
    };
}

test "win32 screen: lock and unlock" {
    var s: Screen = .{};
    try std.testing.expect(!off(s));
    s = onSession(s, wtsapi32.WTS_SESSION_LOCK);
    try std.testing.expect(s.locked);
    try std.testing.expect(off(s));
    s = onSession(s, wtsapi32.WTS_SESSION_UNLOCK);
    try std.testing.expect(!s.locked);
    try std.testing.expect(!off(s));
}

test "win32 screen: remote disconnect then connect" {
    var s: Screen = .{};
    s = onSession(s, wtsapi32.WTS_REMOTE_DISCONNECT);
    try std.testing.expect(s.disconnected);
    try std.testing.expect(off(s));
    s = onSession(s, wtsapi32.WTS_REMOTE_CONNECT);
    try std.testing.expect(!s.disconnected);
    try std.testing.expect(!off(s));
    // The console flavour behaves the same.
    s = onSession(s, wtsapi32.WTS_CONSOLE_DISCONNECT);
    try std.testing.expect(off(s));
    s = onSession(s, wtsapi32.WTS_CONSOLE_CONNECT);
    try std.testing.expect(!off(s));
}

test "win32 screen: console disconnect keeps locked" {
    var s: Screen = .{};
    s = onSession(s, wtsapi32.WTS_SESSION_LOCK);
    s = onSession(s, wtsapi32.WTS_CONSOLE_DISCONNECT);
    s = onSession(s, wtsapi32.WTS_CONSOLE_CONNECT);
    try std.testing.expect(s.locked);
    try std.testing.expect(off(s));
    s = onSession(s, wtsapi32.WTS_SESSION_UNLOCK);
    try std.testing.expect(!off(s));
}

test "win32 screen: other session codes change nothing" {
    const locked: Screen = .{ .locked = true };
    for ([_]usize{ wtsapi32.WTS_SESSION_LOGON, wtsapi32.WTS_SESSION_LOGOFF, 9, 0xA, 0xB, 0, 99 }) |code| {
        try std.testing.expectEqual(locked, onSession(locked, code));
        try std.testing.expectEqual(Screen{}, onSession(.{}, code));
    }
}

test "win32 screen: display off, dimmed counts as on" {
    var s: Screen = .{};
    s = onDisplayState(s, 0);
    try std.testing.expect(s.display_off);
    try std.testing.expect(off(s));
    s = onDisplayState(s, 2);
    try std.testing.expect(!s.display_off);
    try std.testing.expect(!off(s));
    s = onDisplayState(s, 0);
    s = onDisplayState(s, 1);
    try std.testing.expect(!off(s));
    // The display coming back does not undo a lock.
    s = onSession(onDisplayState(s, 0), wtsapi32.WTS_SESSION_LOCK);
    s = onDisplayState(s, 1);
    try std.testing.expect(off(s));
}

test "win32 screen: power payload decoding" {
    var setting: user32.POWERBROADCAST_SETTING = .{
        .PowerSetting = GUID_CONSOLE_DISPLAY_STATE,
        .DataLength = 4,
        .Data = .{0},
    };
    // `Data` is the first byte of a u32 that follows the header in the real
    // message: build one in a buffer.
    var buf: [@sizeOf(user32.POWERBROADCAST_SETTING) + 4]u8 align(@alignOf(user32.POWERBROADCAST_SETTING)) = undefined;
    @memcpy(buf[0..@sizeOf(user32.POWERBROADCAST_SETTING)], std.mem.asBytes(&setting));
    const data_at = @offsetOf(user32.POWERBROADCAST_SETTING, "Data");
    std.mem.writeInt(u32, buf[data_at..][0..4], 2, .little);
    const msg: *const user32.POWERBROADCAST_SETTING = @ptrCast(&buf);
    try std.testing.expectEqual(@as(?u32, 2), displayStateOf(msg));

    // Another setting is ignored.
    setting.PowerSetting.Data1 +%= 1;
    @memcpy(buf[0..@sizeOf(user32.POWERBROADCAST_SETTING)], std.mem.asBytes(&setting));
    std.mem.writeInt(u32, buf[data_at..][0..4], 2, .little);
    try std.testing.expectEqual(@as(?u32, null), displayStateOf(msg));

    // A short payload is ignored.
    setting.PowerSetting = GUID_CONSOLE_DISPLAY_STATE;
    setting.DataLength = 2;
    @memcpy(buf[0..@sizeOf(user32.POWERBROADCAST_SETTING)], std.mem.asBytes(&setting));
    try std.testing.expectEqual(@as(?u32, null), displayStateOf(msg));
}

test "win32 screen: cloak events of windows only" {
    const id = user32.OBJID_WINDOW;
    const self_child = user32.CHILDID_SELF;
    try std.testing.expectEqual(@as(?bool, true), isCloakEvent(user32.EVENT_OBJECT_CLOAKED, id, self_child));
    try std.testing.expectEqual(@as(?bool, false), isCloakEvent(user32.EVENT_OBJECT_UNCLOAKED, id, self_child));
    // Other objects (OBJID_CLIENT = -4) and children are not the window.
    try std.testing.expectEqual(@as(?bool, null), isCloakEvent(user32.EVENT_OBJECT_CLOAKED, -4, self_child));
    try std.testing.expectEqual(@as(?bool, null), isCloakEvent(user32.EVENT_OBJECT_CLOAKED, id, 1));
    // EVENT_OBJECT_SHOW
    try std.testing.expectEqual(@as(?bool, null), isCloakEvent(0x8002, id, self_child));
}
