//! send-keys key name translation (owner: M4 task 11).
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../../config.zig");

const named = std.StaticStringMap([]const u8).initComptime(.{
    .{ "enter", "\r" },
    .{ "escape", "\x1b" },
    .{ "tab", "\t" },
    .{ "btab", "\x1b[Z" },
    .{ "bspace", "\x7f" },
    .{ "space", " " },
    .{ "up", "\x1b[A" },
    .{ "down", "\x1b[B" },
    .{ "right", "\x1b[C" },
    .{ "left", "\x1b[D" },
    .{ "home", "\x1b[H" },
    .{ "end", "\x1b[F" },
    .{ "pageup", "\x1b[5~" },
    .{ "ppage", "\x1b[5~" },
    .{ "pgup", "\x1b[5~" },
    .{ "pgdn", "\x1b[6~" },
    .{ "pagedown", "\x1b[6~" },
    .{ "npage", "\x1b[6~" },
    .{ "ic", "\x1b[2~" },
    .{ "dc", "\x1b[3~" },
    .{ "f1", "\x1bOP" },
    .{ "f2", "\x1bOQ" },
    .{ "f3", "\x1bOR" },
    .{ "f4", "\x1bOS" },
    .{ "f5", "\x1b[15~" },
    .{ "f6", "\x1b[17~" },
    .{ "f7", "\x1b[18~" },
    .{ "f8", "\x1b[19~" },
    .{ "f9", "\x1b[20~" },
    .{ "f10", "\x1b[21~" },
    .{ "f11", "\x1b[23~" },
    .{ "f12", "\x1b[24~" },
});

/// The bytes of one non-literal key token. An unknown token is the text itself.
fn token(arena: Allocator, tok: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (!try recognized(arena, tok, out)) try out.appendSlice(arena, tok);
}

fn lookup(tok: []const u8) ?[]const u8 {
    var buf: [16]u8 = undefined;
    if (tok.len > buf.len) return null;
    return named.get(std.ascii.lowerString(&buf, tok));
}

/// Appends the bytes of a known key and returns true; an unknown token
/// appends nothing and returns false.
fn recognized(arena: Allocator, tok: []const u8, out: *std.ArrayList(u8)) Allocator.Error!bool {
    if (lookup(tok)) |bytes| {
        try out.appendSlice(arena, bytes);
        return true;
    }
    if (try modified(arena, tok, out)) return true;
    if (tok.len > 2 and tok[0] == 'M' and tok[1] == '-') {
        // Only a known remainder; tmux sends `M-hello` as the text itself.
        var rest: std.ArrayList(u8) = .empty;
        if (tok.len == 3) {
            try rest.append(arena, tok[2]);
        } else if (!try recognized(arena, tok[2..], &rest)) return false;
        try out.append(arena, 0x1b);
        try out.appendSlice(arena, rest.items);
        return true;
    }
    if (tok.len == 3 and tok[0] == 'C' and tok[1] == '-') {
        if (ctrl(tok[2])) |b| {
            try out.append(arena, b);
            return true;
        }
    }
    if (tok.len == 2 and tok[0] == '^') {
        if (ctrl(tok[1])) |b| {
            try out.append(arena, b);
            return true;
        }
    }
    return false;
}

/// `C-Up`, `S-Left`, `C-S-PageUp`: xterm modifier encoding (`CSI 1;m A`,
/// `CSI n;m ~`), m = 1 + shift(1) + alt(2) + ctrl(4).
fn modified(arena: Allocator, tok: []const u8, out: *std.ArrayList(u8)) Allocator.Error!bool {
    var mods: u8 = 0;
    var rest = tok;
    while (rest.len > 2 and rest[1] == '-') {
        mods |= switch (rest[0]) {
            'S' => 1,
            'M' => 2,
            'C' => 4,
            else => return false,
        };
        rest = rest[2..];
    }
    if (mods == 0) return false;
    const base = lookup(rest) orelse return false;
    // Only the CSI keys: `ESC [ <final>` or `ESC [ n ~`.
    if (base.len < 3 or base[0] != 0x1b or base[1] != '[' or base[2] == 'Z') return false;
    if (base[base.len - 1] == '~') {
        try out.print(arena, "\x1b[{s};{d}~", .{ base[2 .. base.len - 1], 1 + mods });
    } else {
        try out.print(arena, "\x1b[1;{d}{c}", .{ 1 + mods, base[base.len - 1] });
    }
    return true;
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
    if (repeat == 0) return arena.alloc(u8, 0);
    if (repeat == 1) return once.items;
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

test "win32 tmux keys: case, aliases, modifiers, M- literal, -N 0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\r\x1b", try enc(a, &.{ "enter", "ESCAPE" }));
    try testing.expectEqualStrings("\x1b[5~\x1b[6~", try enc(a, &.{ "PgUp", "pgdn" }));
    try testing.expectEqualStrings("M-hello", try enc(a, &.{"M-hello"}));
    try testing.expectEqualStrings("\x1b\x03", try enc(a, &.{"M-C-c"}));
    try testing.expectEqualStrings("\x1b[1;5A\x1b[1;2D\x1b[5;6~", try enc(a, &.{ "C-Up", "S-Left", "C-S-PageUp" }));
    try testing.expectEqualStrings("", try encode(a, &.{"Enter"}, false, false, 0));
}
