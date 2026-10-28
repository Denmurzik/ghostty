//! Throwaway tmux answerer for the Claude Code tmux contract capture
//! (docs/windows/recon/tmux.md, "Re-check"). std only, built by run.ps1 into
//! the run's sandbox as tmux.exe; not part of `zig build`.
//!
//! Every call appends `{"argv":[...],"stdin_len":null|N}` to the file named
//! by GHOSTTY_TMUX_TRACE (one WriteFile per line) and answers with the ids
//! Claude Code expects: leader %1, window @1, new panes %2, %3, ...
const std = @import("std");

const Handle = ?*anyopaque;
const invalid: Handle = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: Handle) callconv(.winapi) Handle;
extern "kernel32" fn WriteFile(h: Handle, buf: [*]const u8, n: u32, written: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: Handle, buf: [*]u8, n: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(id: u32) callconv(.winapi) Handle;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, n: u32) callconv(.winapi) u32;

const FILE_APPEND_DATA: u32 = 0x4;
const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_ALL: u32 = 0x7;
const OPEN_ALWAYS: u32 = 4;
const OPEN_EXISTING: u32 = 3;

fn tracePath(buf: *[1024]u16) ?[:0]const u16 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_TMUX_TRACE");
    const n = GetEnvironmentVariableW(name, buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

fn countSplits(path: [:0]const u16, alloc: std.mem.Allocator) usize {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, 0, null);
    if (h == invalid) return 0;
    defer _ = CloseHandle(h);
    var data: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (ReadFile(h, &chunk, chunk.len, &got, null) == 0 or got == 0) break;
        data.appendSlice(alloc, chunk[0..got]) catch break;
    }
    return std.mem.count(u8, data.items, "\"split-window\"");
}

fn jsonString(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    const bs = "\x5c";
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(alloc, bs ++ "\""),
        0x5c => try list.appendSlice(alloc, bs ++ bs),
        0x0a => try list.appendSlice(alloc, bs ++ "n"),
        0x0d => try list.appendSlice(alloc, bs ++ "r"),
        0x09 => try list.appendSlice(alloc, bs ++ "t"),
        0...8, 11, 12, 14...31 => {
            var tmp: [6]u8 = undefined;
            try list.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{s}u{x:0>4}", .{ bs, c }));
        },
        else => try list.append(alloc, c),
    };
    try list.append(alloc, '"');
}

fn out(text: []const u8) void {
    const h = GetStdHandle(@as(u32, @bitCast(@as(i32, -11))));
    var w: u32 = 0;
    _ = WriteFile(h, text.ptr, @intCast(text.len), &w, null);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    const args = argv[1..];

    // Skip the global prefix (-S <sock> | -L <name>).
    var i: usize = 0;
    while (i + 1 < args.len and (std.mem.eql(u8, args[i], "-S") or std.mem.eql(u8, args[i], "-L"))) i += 2;
    const rest = args[i..];
    const cmd: []const u8 = if (rest.len > 0) rest[0] else "";
    const last: []const u8 = if (rest.len > 0) rest[rest.len - 1] else "";

    // stdin only for `load-buffer ... -`.
    var stdin_len: ?usize = null;
    if (std.mem.eql(u8, cmd, "load-buffer") and std.mem.eql(u8, last, "-")) {
        const h = GetStdHandle(@as(u32, @bitCast(@as(i32, -10))));
        var n: usize = 0;
        var chunk: [4096]u8 = undefined;
        while (true) {
            var got: u32 = 0;
            if (ReadFile(h, &chunk, chunk.len, &got, null) == 0 or got == 0) break;
            n += got;
        }
        stdin_len = n;
    }

    var pbuf: [1024]u16 = undefined;
    const path = tracePath(&pbuf);
    var splits: usize = 0;
    if (path) |p| splits = countSplits(p, alloc);

    // The trace line: one WriteFile.
    if (path) |p| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(alloc, "{\"argv\":[");
        for (args, 0..) |a, k| {
            if (k != 0) try line.append(alloc, ',');
            try jsonString(&line, alloc, a);
        }
        try line.appendSlice(alloc, "],\"stdin_len\":");
        if (stdin_len) |n| {
            var tmp: [24]u8 = undefined;
            try line.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
        } else try line.appendSlice(alloc, "null");
        try line.appendSlice(alloc, "}\n");
        const h = CreateFileW(p, FILE_APPEND_DATA, FILE_SHARE_ALL, null, OPEN_ALWAYS, 0, null);
        if (h != invalid) {
            var w: u32 = 0;
            _ = WriteFile(h, line.items.ptr, @intCast(line.items.len), &w, null);
            _ = CloseHandle(h);
        }
    }

    if (std.mem.eql(u8, cmd, "-V")) {
        out("tmux 3.5a\n");
    } else if (std.mem.eql(u8, cmd, "display-message")) {
        if (std.mem.eql(u8, last, "#{pane_id}")) {
            out("%1\n");
        } else if (std.mem.eql(u8, last, "#{window_id}")) {
            out("@1\n");
        } else if (std.mem.indexOf(u8, last, "client_termtype") != null) {
            out("xterm-ghostty\toff\t0\t0\t0\ton\tbottom\t0\n");
        } else if (std.mem.eql(u8, last, "#{session_name}:#{window_id}.#{pane_id}")) {
            out("0:@1.%1\n");
        }
    } else if (std.mem.eql(u8, cmd, "list-panes")) {
        var buf: [32]u8 = undefined;
        var k: usize = 0;
        while (k <= splits) : (k += 1) out(try std.fmt.bufPrint(&buf, "%{d}\n", .{k + 1}));
    } else if (std.mem.eql(u8, cmd, "split-window")) {
        var print = false;
        for (rest) |a| {
            if (std.mem.eql(u8, a, "-P")) print = true;
        }
        if (print) {
            var buf: [32]u8 = undefined;
            out(try std.fmt.bufPrint(&buf, "%{d}\n", .{splits + 2}));
        }
    }
}
