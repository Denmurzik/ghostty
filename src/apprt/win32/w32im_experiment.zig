//! Test-mode experiment: keys as win32-input-mode records.
//!
//! Windows Terminal sends every key to the pseudo console as a
//! `CSI Vk;Sc;Uc;Kd;Cs;Rc _` record (the mode conhost asks for with
//! `CSI ? 9001 h`), while Ghostty sends plain VT bytes. To learn whether
//! that difference is why Git Bash loses input after a resize on the
//! bundled console, with `GHOSTTY_WIN32_TEST_W32IM=1` (honoured only with
//! `GHOSTTY_WIN32_TEST_IPC=1`) keys from the keyboard messages, and the text
//! of the IPC `text:` action, are written as records instead of going
//! through core's key encoder. Without the env nothing here runs.
const std = @import("std");
const win32 = @import("win32");
const Allocator = std.mem.Allocator;
const termio = @import("../../termio.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_w32im);

const env_var = "GHOSTTY_WIN32_TEST_W32IM";

/// dwControlKeyState bits.
pub const cs_right_alt: u16 = 0x01;
pub const cs_left_alt: u16 = 0x02;
pub const cs_right_ctrl: u16 = 0x04;
pub const cs_left_ctrl: u16 = 0x08;
pub const cs_shift: u16 = 0x10;
pub const cs_enhanced: u16 = 0x100;

/// Test hook: replaces the answer of `enabled`.
pub var enabled_override: ?bool = null;

/// 0 not read yet, 1 off, 2 on.
var cache_state: std.atomic.Value(u8) = .init(0);

/// Reads the env once and removes it from the process environment. Called
/// at startup after `ipc.ops.cacheTestOps`, which has already read the
/// test-ops variable.
pub fn cache(alloc: Allocator, test_ops: bool) void {
    const on = test_ops and if (@import("../../os/main.zig").windows.diagnosticEnv(alloc, env_var)) |value| blk: {
        defer alloc.free(value);
        break :blk std.mem.eql(u8, value, "1");
    } else false;
    cache_state.store(if (on) 2 else 1, .release);
    _ = win32.kernel32.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(env_var), null);
}

pub fn enabled() bool {
    if (enabled_override) |o| return o;
    return cache_state.load(.acquire) == 2;
}

/// One record: `ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`.
pub fn record(
    buf: []u8,
    vk: u16,
    sc: u16,
    uc: u21,
    down: bool,
    cs: u16,
    rc: u16,
) []u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d};{d};{d};{d};{d}_", .{
        vk, sc, uc, @intFromBool(down), cs, rc,
    }) catch buf[0..0];
}

/// Writes `data` to the surface's pty.
pub fn write(surface: *Surface, data: []const u8) void {
    const core = surface.core();
    const msg = termio.Message.writeReq(core.alloc, data) catch |err| {
        log.warn("write failed err={}", .{err});
        return;
    };
    core.io.queueMessage(msg, .unlocked);
}

/// The IPC `text:` action: each character as a key-down and key-up record.
/// `\r` is Enter (VK_RETURN), `\x03` Ctrl+C; the rest are plain characters
/// with the virtual key of their ASCII letter or digit, or 0.
pub fn writeText(surface: *Surface, text: []const u8) void {
    var out: [96]u8 = undefined;
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const k = textKey(cp);
        for ([_]bool{ true, false }) |down| {
            write(surface, record(&out, k.vk, k.sc, cp, down, k.cs, 1));
        }
    }
}

const TextKey = struct { vk: u16, sc: u16, cs: u16 };

fn textKey(cp: u21) TextKey {
    return switch (cp) {
        '\r' => .{ .vk = 0x0D, .sc = 0x1C, .cs = 0 },
        '\x03' => .{ .vk = 0x43, .sc = 0x2E, .cs = cs_left_ctrl },
        'a'...'z' => .{ .vk = @intCast(cp - 'a' + 'A'), .sc = 0, .cs = 0 },
        'A'...'Z' => .{ .vk = @intCast(cp), .sc = 0, .cs = cs_shift },
        '0'...'9' => .{ .vk = @intCast(cp), .sc = 0, .cs = 0 },
        ' ' => .{ .vk = 0x20, .sc = 0x39, .cs = 0 },
        else => .{ .vk = 0, .sc = 0, .cs = 0 },
    };
}

test "win32 w32im experiment: record for a key" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[65;30;97;1;0;1_", record(&buf, 0x41, 0x1E, 'a', true, 0, 1));
    try std.testing.expectEqualStrings("\x1b[65;30;97;0;0;1_", record(&buf, 0x41, 0x1E, 'a', false, 0, 1));
    // Shift held.
    try std.testing.expectEqualStrings("\x1b[65;30;65;1;16;1_", record(&buf, 0x41, 0x1E, 'A', true, cs_shift, 1));
    // Repeat count 3.
    try std.testing.expectEqualStrings("\x1b[65;30;97;1;0;3_", record(&buf, 0x41, 0x1E, 'a', true, 0, 3));
}

test "win32 w32im experiment: off without the env" {
    enabled_override = null;
    cache_state.store(0, .release);
    try std.testing.expect(!enabled());
    cache_state.store(1, .release);
    try std.testing.expect(!enabled());
}
