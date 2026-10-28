//! send-keys key name translation (owner: M4 task 11).
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../../config.zig");

const named = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Enter", "\r" },
    .{ "Escape", "\x1b" },
    .{ "Tab", "\t" },
    .{ "BTab", "\x1b[Z" },
    .{ "BSpace", "\x7f" },
    .{ "Space", " " },
    .{ "Up", "\x1b[A" },
    .{ "Down", "\x1b[B" },
    .{ "Right", "\x1b[C" },
    .{ "Left", "\x1b[D" },
    .{ "Home", "\x1b[H" },
    .{ "End", "\x1b[F" },
    .{ "PageUp", "\x1b[5~" },
    .{ "PPage", "\x1b[5~" },
    .{ "PageDown", "\x1b[6~" },
    .{ "NPage", "\x1b[6~" },
    .{ "IC", "\x1b[2~" },
    .{ "DC", "\x1b[3~" },
    .{ "F1", "\x1bOP" },
    .{ "F2", "\x1bOQ" },
    .{ "F3", "\x1bOR" },
    .{ "F4", "\x1bOS" },
    .{ "F5", "\x1b[15~" },
    .{ "F6", "\x1b[17~" },
    .{ "F7", "\x1b[18~" },
    .{ "F8", "\x1b[19~" },
    .{ "F9", "\x1b[20~" },
    .{ "F10", "\x1b[21~" },
    .{ "F11", "\x1b[23~" },
    .{ "F12", "\x1b[24~" },
});

/// The bytes of one non-literal key token. An unknown token is the text itself.
fn token(arena: Allocator, tok: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (named.get(tok)) |bytes| return out.appendSlice(arena, bytes);
    if (tok.len > 2 and tok[0] == 'M' and tok[1] == '-') {
        try out.append(arena, 0x1b);
        return token(arena, tok[2..], out);
    }
    if (tok.len == 3 and tok[0] == 'C' and tok[1] == '-') {
        if (ctrl(tok[2])) |b| return out.append(arena, b);
    }
    if (tok.len == 2 and tok[0] == '^') {
        if (ctrl(tok[1])) |b| return out.append(arena, b);
    }
    try out.appendSlice(arena, tok);
}

fn ctrl(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 'a' + 1,
        'A'...'Z' => c - 'A' + 1,
        '@', ' ' => 0,
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' => 0x1f,
        '?' => 0x7f,
        else => null,
    };
}

/// tmux key names to bytes. `literal` (-l) sends the text as is, `hex` (-H)
/// reads each argument as one hex byte, `repeat` (-N) repeats the result.
/// `UnknownKey` is only for a bad -H byte; an unknown name is sent as text.
pub fn encode(
    arena: Allocator,
    args: []const []const u8,
    literal: bool,
    hex: bool,
    repeat: u32,
) error{ UnknownKey, OutOfMemory }![]u8 {
    var once: std.ArrayList(u8) = .empty;
    for (args) |arg| {
        if (hex) {
            const b = std.fmt.parseInt(u8, arg, 16) catch return error.UnknownKey;
            try once.append(arena, b);
        } else if (literal) {
            try once.appendSlice(arena, arg);
        } else {
            try token(arena, arg, &once);
        }
    }
    if (repeat <= 1) return once.items;
    const total = std.math.mul(usize, once.items.len, repeat) catch return error.OutOfMemory;
    if (total > 16 * 1024 * 1024) return error.OutOfMemory;
    const out = try arena.alloc(u8, total);
    for (0..repeat) |i| @memcpy(out[i * once.items.len ..][0..once.items.len], once.items);
    return out;
}

/// The bytes as the Zig-string escapes `Binding.Action.text` parses.
pub fn toTextAction(arena: Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| switch (b) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        0x20...0x5b, 0x5d...0x7e => try out.append(arena, b),
        else => try out.print(arena, "\\x{x:0>2}", .{b}),
    };
    return out.items;
}

const testing = std.testing;

fn enc(arena: Allocator, args: []const []const u8) ![]u8 {
    return encode(arena, args, false, false, 1);
}

test "win32 tmux keys: names, C- and M-, unknown literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\r", try enc(a, &.{"Enter"}));
    try testing.expectEqualStrings("\x1b[Z\x7f \t", try enc(a, &.{ "BTab", "BSpace", "Space", "Tab" }));
    try testing.expectEqualStrings("\x1b[A\x1b[B\x1b[C\x1b[D\x1b[H\x1b[F", try enc(a, &.{ "Up", "Down", "Right", "Left", "Home", "End" }));
    try testing.expectEqualStrings("\x1b[5~\x1b[5~\x1b[6~\x1b[6~\x1b[2~\x1b[3~", try enc(a, &.{ "PageUp", "PPage", "PageDown", "NPage", "IC", "DC" }));
    try testing.expectEqualStrings("\x1bOP\x1b[24~", try enc(a, &.{ "F1", "F12" }));
    try testing.expectEqualStrings("\x03\x00\x1b", try enc(a, &.{ "C-c", "C-@", "C-[" }));
    try testing.expectEqualStrings("\x1bx\x1b\r", try enc(a, &.{ "M-x", "M-Enter" }));
    try testing.expectEqualStrings("echo hi", try enc(a, &.{"echo hi"}));
    try testing.expectEqualStrings("C-", try enc(a, &.{"C-"}));
}

test "win32 tmux keys: -l and -H and -N" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Enter", try encode(a, &.{"Enter"}, true, false, 1));
    try testing.expectEqualStrings("A\x1b\xff", try encode(a, &.{ "41", "1b", "ff" }, false, true, 1));
    try testing.expectError(error.UnknownKey, encode(a, &.{"zz"}, false, true, 1));
    try testing.expectError(error.UnknownKey, encode(a, &.{"100"}, false, true, 1));
    try testing.expectEqualStrings("\r\r\r", try encode(a, &.{"Enter"}, false, false, 3));
    try testing.expectEqualStrings("ababab", try encode(a, &.{"ab"}, true, false, 3));
}

test "win32 tmux keys: text action escapes round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    const inputs = [_][]const u8{ "", "echo 'a' \"b\" \\n \\x41\r", "h\xc3\xa9llo \xe2\x82\xac", &all };
    for (inputs) |bytes| {
        const esc = try toTextAction(a, bytes);
        const buf = try a.alloc(u8, esc.len);
        const back = try configpkg.string.parse(buf, esc);
        try testing.expectEqualSlices(u8, bytes, back);
    }
}
