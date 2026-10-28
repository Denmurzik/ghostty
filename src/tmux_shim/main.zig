//! `tmux.exe`: a thin console shim that forwards a tmux command line to the
//! Ghostty tmux pipe. This file is entry and process glue only; the logic
//! is in run.zig and the transport in pipe.zig.
//!
//! Startup budget: no window, no libc, no allocator beyond one arena, and
//! only kernel32 (plus ntdll through std) imported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const run_mod = @import("run.zig");
const pipe = @import("pipe.zig");
const win = @import("win.zig");

const Transport = struct {
    pub fn nowMs(_: Transport) u64 {
        return win.GetTickCount64();
    }

    pub fn request(_: Transport, alloc: Allocator, name: []const u8, expected_pid: u32, payload: []const u8, deadline_ms: u64) run_mod.TransportError![]u8 {
        return pipe.request(alloc, name, expected_pid, payload, deadline_ms);
    }
};

/// Synchronous reads from the process stdin.
const Stdin = struct {
    pub fn read(_: Stdin, arena: Allocator, limit: usize) error{ TooLarge, ReadFailed, OutOfMemory }![]u8 {
        const h = win.GetStdHandle(win.STD_INPUT_HANDLE) orelse return error.ReadFailed;
        if (h == win.INVALID_HANDLE_VALUE) return error.ReadFailed;
        var list: std.ArrayList(u8) = .empty;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var n: u32 = 0;
            if (win.ReadFile(h, &chunk, chunk.len, &n, null) == 0) {
                // A closed write end of a pipe is end of input.
                if (win.GetLastError() == win.ERROR_BROKEN_PIPE) break;
                return error.ReadFailed;
            }
            if (n == 0) break;
            if (list.items.len + n > limit) return error.TooLarge;
            try list.appendSlice(arena, chunk[0..n]);
        }
        return list.items;
    }
};

pub fn main(init: std.process.Init.Minimal) u8 {
    const start = win.GetTickCount64();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    const args = init.args.toSlice(arena) catch return fatal("out of memory\n");
    if (args.len == 2 and std.mem.eql(u8, args[1], "__idle")) idle();

    const argv = arena.alloc([]const u8, if (args.len > 0) args.len - 1 else 0) catch return fatal("out of memory\n");
    for (argv, args[1..]) |*a, s| a.* = s;

    var dropped: usize = 0;
    const env = readEnv(arena, &dropped) catch return fatal("out of memory\n");
    const cwd = readCwd(arena) catch "";

    const outcome = run_mod.run(arena, argv, env, cwd, Transport{}, Stdin{}) catch
        return fatal("out of memory\n");

    writeOut(win.STD_OUTPUT_HANDLE, arena, outcome.stdout);
    writeOut(win.STD_ERROR_HANDLE, arena, outcome.stderr);

    const wall_ms = win.GetTickCount64() - start;
    if (env.trace) |path| trace(arena, path, argv, cwd, env, outcome, wall_ms, dropped) catch {};
    if (env.stats) stats(arena, wall_ms);
    return outcome.code;
}

fn fatal(msg: []const u8) u8 {
    writeOut(win.STD_ERROR_HANDLE, std.heap.page_allocator, msg);
    return 1;
}

/// Parks until the process is killed. Used as a placeholder pane command;
/// ignores Ctrl+C and reads nothing.
fn idle() noreturn {
    _ = win.SetConsoleCtrlHandler(null, 1);
    _ = win.WaitForSingleObject(win.GetCurrentProcess(), win.INFINITE);
    unreachable;
}

fn utf16Entries(arena: Allocator, block: [*:0]const u16, list: *std.ArrayList([]const u8)) !void {
    var p = block;
    while (p[0] != 0) {
        const entry = std.mem.span(p);
        try list.append(arena, try std.unicode.wtf16LeToWtf8Alloc(arena, entry));
        p += entry.len + 1;
    }
}

fn readEnv(arena: Allocator, dropped: *usize) !run_mod.Env {
    var entries: std.ArrayList([]const u8) = .empty;
    if (win.GetEnvironmentStringsW()) |block| {
        defer _ = win.FreeEnvironmentStringsW(block);
        try utf16Entries(arena, block, &entries);
    }
    var env: run_mod.Env = .{ .tmux = null, .tmux_pane = null, .trace = null, .stats = false, .block = &.{} };
    for (entries.items) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        if (eq == 0) continue;
        const name = e[0..eq];
        const value = e[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(name, "TMUX")) {
            env.tmux = value;
        } else if (std.ascii.eqlIgnoreCase(name, "TMUX_PANE")) {
            env.tmux_pane = value;
        } else if (std.ascii.eqlIgnoreCase(name, "GHOSTTY_TMUX_TRACE")) {
            if (value.len > 0) env.trace = value;
        } else if (std.ascii.eqlIgnoreCase(name, "GHOSTTY_TMUX_STATS")) {
            env.stats = std.mem.eql(u8, value, "1");
        }
    }
    env.block = try run_mod.buildBlock(arena, entries.items, dropped);
    return env;
}

fn readCwd(arena: Allocator) ![]const u8 {
    var buf: [32768]u16 = undefined;
    const n = win.GetCurrentDirectoryW(buf.len, &buf);
    if (n == 0 or n >= buf.len) return "";
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..n]);
}

/// A console gets UTF-16 through WriteConsoleW; a pipe or file gets the raw
/// UTF-8 bytes.
fn writeOut(which: u32, alloc: Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const h = win.GetStdHandle(which) orelse return;
    if (h == win.INVALID_HANDLE_VALUE) return;
    var mode: u32 = 0;
    if (win.GetConsoleMode(h, &mode) != 0) {
        if (std.unicode.wtf8ToWtf16LeAlloc(alloc, bytes)) |wide| {
            var off: usize = 0;
            while (off < wide.len) {
                var chunk: u32 = @intCast(@min(wide.len - off, 16 * 1024));
                // Do not split a surrogate pair across two writes.
                if (off + chunk < wide.len and std.unicode.utf16IsHighSurrogate(wide[off + chunk - 1])) chunk -= 1;
                var written: u32 = 0;
                if (win.WriteConsoleW(h, wide[off..].ptr, chunk, &written, null) == 0 or written == 0) return;
                off += written;
            }
            return;
        } else |_| {}
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk: u32 = @intCast(@min(bytes.len - off, 1 << 20));
        var written: u32 = 0;
        if (win.WriteFile(h, bytes[off..].ptr, chunk, &written, null) == 0 or written == 0) return;
        off += written;
    }
}

/// One JSON line per invocation, opened append-only and written with a
/// single WriteFile so parallel invocations never interleave. Stdin content
/// is never traced.
fn trace(
    arena: Allocator,
    path: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: run_mod.Env,
    outcome: run_mod.Outcome,
    wall_ms: u64,
    dropped: usize,
) !void {
    var ft: u64 = 0;
    win.GetSystemTimeAsFileTime(&ft);
    // FILETIME is 100 ns ticks since 1601; Unix epoch offset in ms.
    const unix_ms: u64 = ft / 10_000 - 11_644_473_600_000;

    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("t");
    try jw.write(unix_ms);
    try jw.objectField("argv");
    try jw.write(argv);
    try jw.objectField("cwd");
    try jw.write(cwd);
    try jw.objectField("pane");
    try jw.write(env.tmux_pane orelse "");
    try jw.objectField("code");
    try jw.write(outcome.code);
    try jw.objectField("ms");
    try jw.write(wall_ms);
    try jw.objectField("stdout_len");
    try jw.write(outcome.stdout.len);
    try jw.objectField("stdin_len");
    try jw.write(outcome.stdin_len);
    if (dropped > 0) {
        try jw.objectField("env_dropped");
        try jw.write(dropped);
    }
    try jw.endObject();
    try aw.writer.writeByte('\n');

    const wpath = try std.unicode.wtf8ToWtf16LeAllocZ(arena, path);
    const h = win.CreateFileW(wpath.ptr, win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return;
    defer _ = win.CloseHandle(h);
    const line = aw.written();
    var written: u32 = 0;
    _ = win.WriteFile(h, line.ptr, @intCast(line.len), &written, null);
}

fn stats(arena: Allocator, wall_ms: u64) void {
    var counters: win.PROCESS_MEMORY_COUNTERS = .{};
    _ = win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, @sizeOf(win.PROCESS_MEMORY_COUNTERS));
    const line = std.fmt.allocPrint(arena, "tmux-stats peak_private_kb={d} wall_ms={d} build={s}\n", .{
        counters.PeakPagefileUsage / 1024,
        wall_ms,
        @tagName(@import("builtin").mode),
    }) catch return;
    writeOut(win.STD_ERROR_HANDLE, arena, line);
}

test {
    _ = @import("run.zig");
    _ = @import("pipe.zig");
}
