//! Windows log sinks: a rotating file under `%LOCALAPPDATA%\ghostty\logs\`
//! and the debugger output stream (OutputDebugStringW).
//!
//! The GUI-subsystem `ghostty.exe` usually has no stderr, so the file is
//! the primary place to look after the fact. A line looks like
//!
//!     2026-10-26T12:00:00.000Z info(config): hello
//!
//! The file is opened for append-only writes, so a single `WriteFile` per
//! line is atomic and no lock is needed between threads. It is rotated
//! once at `init` (`ghostty.log` > 5 MiB becomes `ghostty.1.log`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = @import("windows.zig");

const log = std.log.scoped(.windows_log);

/// Size above which `ghostty.log` is rotated to `ghostty.1.log` at init.
const rotate_bytes: i64 = 5 * 1024 * 1024;

/// The open log file handle as an integer, 0 for none.
var file_handle: std.atomic.Value(usize) = .init(0);

pub const Sinks = struct {
    file: bool = true,
    debugger: bool = true,
};

/// Open `%LOCALAPPDATA%\ghostty\logs\ghostty.log` for appending, rotating
/// it first if it is over 5 MiB. Failures are logged (to the other sinks)
/// and leave the file sink disabled. Safe to call again; the previous file
/// is closed first.
pub fn init(alloc: Allocator, environ_map: *const std.process.Environ.Map) void {
    if (comptime builtin.os.tag != .windows) return;
    deinit();

    const base = environ_map.get("LOCALAPPDATA") orelse return;
    if (base.len == 0) return;

    openLog(alloc, base) catch |err| {
        log.warn("failed to open log file under LOCALAPPDATA err={}", .{err});
    };
}

/// Close the log file. Later writes only go to the other sinks.
pub fn deinit() void {
    if (comptime builtin.os.tag != .windows) return;
    const prev = file_handle.swap(0, .acq_rel);
    if (prev != 0) _ = windows.exp.kernel32.CloseHandle(@ptrFromInt(prev));
}

fn openLog(alloc: Allocator, base: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ base, "ghostty", "logs" });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir);

    const path = try std.fs.path.joinZ(alloc, &.{ dir, "ghostty.log" });
    defer alloc.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    var h = try openAppend(path_w);

    var size: windows.LARGE_INTEGER = 0;
    if (windows.GetFileSizeEx(h, &size).toBool() and size > rotate_bytes) {
        _ = windows.exp.kernel32.CloseHandle(h);
        const rotated = try std.fs.path.joinZ(alloc, &.{ dir, "ghostty.1.log" });
        defer alloc.free(rotated);
        const rotated_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, rotated);
        defer alloc.free(rotated_w);

        // On failure we keep appending to the old file rather than lose
        // the new session's log.
        if (!windows.MoveFileExW(path_w, rotated_w, windows.MOVEFILE_REPLACE_EXISTING).toBool()) {
            log.warn("failed to rotate log file err={}", .{windows.GetLastError()});
        }
        h = try openAppend(path_w);
    }

    file_handle.store(@intFromPtr(h), .release);
}

fn openAppend(path_w: [:0]const u16) !windows.HANDLE {
    const h = windows.exp.kernel32.CreateFileW(
        path_w.ptr,
        windows.FILE_APPEND_DATA,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == windows.INVALID_HANDLE_VALUE) return error.OpenLogFailed;
    return h;
}

/// Append `bytes` (already newline-terminated) to the log file.
fn writeRaw(bytes: []const u8) void {
    const prev = file_handle.load(.acquire);
    if (prev == 0) return;
    var rest = bytes;
    while (rest.len > 0) {
        const n: windows.DWORD = @intCast(@min(rest.len, 1 << 20));
        var written: windows.DWORD = 0;
        if (!windows.exp.kernel32.WriteFile(@ptrFromInt(prev), @ptrCast(rest.ptr), n, &written, null).toBool()) return;
        if (written == 0) return;
        rest = rest[written..];
    }
}

/// Write one line (without trailing newline) to the log file, if open.
pub fn write(line: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    if (file_handle.load(.acquire) == 0) return;

    // One WriteFile per line so concurrent writers never interleave.
    var buf: [4096]u8 = undefined;
    if (line.len < buf.len) {
        @memcpy(buf[0..line.len], line);
        buf[line.len] = '\n';
        writeRaw(buf[0 .. line.len + 1]);
    } else {
        writeRaw(line);
        writeRaw("\n");
    }
}

/// Format `<iso-8601 utc> <level>(<scope>): <msg>` into `buf` (no trailing
/// newline). The scope is omitted for the default scope. Output that does
/// not fit is truncated.
pub fn formatLine(
    buf: []u8,
    ts_ms: i64,
    level: std.log.Level,
    scope: []const u8,
    msg: []const u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeTimestamp(&w, ts_ms) catch return w.buffered();
    w.print(" {s}", .{switch (level) {
        inline else => |l| l.asText(),
    }}) catch return w.buffered();
    if (scope.len > 0 and !std.mem.eql(u8, scope, "default")) {
        w.print("({s})", .{scope}) catch return w.buffered();
    }
    w.print(": {s}", .{msg}) catch return w.buffered();
    return w.buffered();
}

fn writeTimestamp(w: *std.Io.Writer, ts_ms: i64) std.Io.Writer.Error!void {
    const ms: u64 = @intCast(@max(ts_ms, 0));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = ms / std.time.ms_per_s };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms % std.time.ms_per_s,
    });
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

/// The `std.log` back end for the Windows sinks.
pub fn logFmt(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
    sinks: Sinks,
) void {
    if (comptime builtin.os.tag != .windows) return;

    var msg_buf: [3072]u8 = undefined;
    var mw: std.Io.Writer = .fixed(&msg_buf);
    mw.print(format, args) catch {}; // truncated on overflow
    const msg = trimPartialUtf8(mw.buffered());

    // Keep one byte for the newline.
    var line_buf: [4096]u8 = undefined;
    const line = formatLine(line_buf[0 .. line_buf.len - 1], nowMs(), level, @tagName(scope), msg);
    line_buf[line.len] = '\n';
    const out = line_buf[0 .. line.len + 1];

    if (sinks.file) writeRaw(out);
    if (sinks.debugger) outputDebug(out);
}

/// Set once a panic is being recorded. The root panic hook runs outside
/// std's own panic-count protection, so without this a panic raised while
/// writing the trace would re-enter the hook until the stack overflows.
var in_panic: std.atomic.Value(bool) = .init(false);

/// Claim the right to record a panic. True for the first caller; every
/// later (nested or concurrent) panic gets false and must go straight to
/// the default handler.
pub fn beginPanic() bool {
    return in_panic.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

/// Reset the guard. Only for tests, a real panic never returns.
fn resetPanicGuard() void {
    in_panic.store(false, .release);
}

/// Record a panic: the message and a stack trace go to the log file and the
/// debugger. Called from the root panic handler (after `beginPanic`) before
/// the default panic (which prints to stderr, if there is one, and aborts).
/// Does nothing to the file if the sink was never initialized.
///
/// The message line is written before the trace is built, so a fault while
/// formatting the trace still leaves the message in the log.
pub fn writePanic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) void {
    if (comptime builtin.os.tag != .windows) return;

    var head_buf: [4096]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&head_buf);
    writeTimestamp(&hw, nowMs()) catch {};
    hw.print(" panic: {s}", .{msg}) catch {};
    var head_len = hw.buffered().len;
    if (head_len == head_buf.len) head_len -= 1; // room for the newline
    head_len = trimPartialUtf8(head_buf[0..head_len]).len;
    head_buf[head_len] = '\n';
    emit(head_buf[0 .. head_len + 1]);

    if (trace == null and ret_addr == null) return;

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const term: std.Io.Terminal = .{ .writer = &w, .mode = .no_color };
    if (trace) |t| {
        std.debug.writeErrorReturnTrace(t, term) catch {};
    } else if (ret_addr) |addr| {
        std.debug.writeCurrentStackTrace(.{ .first_address = addr }, term) catch {};
    }

    var len = w.buffered().len;
    if (len == 0) return;
    if (buf[len - 1] != '\n') {
        // Truncated by a full buffer; keep the line framing intact.
        if (len == buf.len) len -= 1;
        len = trimPartialUtf8(buf[0..len]).len;
        buf[len] = '\n';
        len += 1;
    }
    emit(buf[0..len]);
}

fn emit(text: []const u8) void {
    writeRaw(text);
    outputDebug(text);
}

/// Drop a trailing, incomplete UTF-8 sequence (what a truncating writer
/// leaves behind when it fills up mid-codepoint).
fn trimPartialUtf8(s: []const u8) []const u8 {
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        const c = s[i];
        if (c & 0xC0 == 0x80) continue; // continuation byte, keep looking
        const need: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else if (c >= 0xC0) 2 else 1;
        return if (s.len - i < need) s[0..i] else s;
    }
    return s;
}

/// Send `text` to the debugger in chunks small enough for a stack buffer.
fn outputDebug(text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        var n = @min(rest.len, 1000);
        // Don't split a UTF-8 sequence across chunks.
        while (n < rest.len and n > 0 and rest[n] & 0xC0 == 0x80) n -= 1;
        if (n == 0) n = @min(rest.len, 1000);
        var wide: [1001]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(wide[0..1000], rest[0..n]) catch len: {
            // Invalid UTF-8: replace the non-ASCII bytes.
            for (rest[0..n], 0..) |c, i| wide[i] = if (c < 0x80) c else '?';
            break :len n;
        };
        wide[len] = 0;
        windows.OutputDebugStringW(@ptrCast(&wide));
        rest = rest[n..];
    }
}

fn testBase(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

fn readLog(tmp: *std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(std.testing.io, sub_path, std.testing.allocator, .limited(64 * 1024 * 1024));
}

test "windows log: line format" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z info(config): hello",
        formatLine(&buf, 0, .info, "config", "hello"),
    );
    try std.testing.expectEqualStrings(
        "2026-10-26T13:45:07.089Z error: boom",
        formatLine(&buf, 1793022307089, .err, "default", "boom"),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z warning: x",
        formatLine(&buf, -5, .warn, "", "x"),
    );

    // Truncates instead of failing when the buffer is too small.
    var tiny: [30]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z info(",
        formatLine(&tiny, 0, .info, "config", "hello"),
    );
}

test "windows log: rotation over 5 MiB" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try testBase(&tmp);
    defer alloc.free(base);

    try tmp.dir.createDirPath(std.testing.io, "ghostty/logs");
    {
        const big = try alloc.alloc(u8, @intCast(rotate_bytes + 1));
        defer alloc.free(big);
        @memset(big, 'x');
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ghostty/logs/ghostty.log", .data = big });
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("LOCALAPPDATA", base);

    init(alloc, &env);
    defer deinit();
    write("after rotation");

    const rotated = try readLog(&tmp, "ghostty/logs/ghostty.1.log");
    defer alloc.free(rotated);
    try std.testing.expectEqual(@as(usize, @intCast(rotate_bytes + 1)), rotated.len);

    const current = try readLog(&tmp, "ghostty/logs/ghostty.log");
    defer alloc.free(current);
    try std.testing.expectEqualStrings("after rotation\n", current);

    // A second init under the limit appends and does not rotate again.
    init(alloc, &env);
    write("again");
    const appended = try readLog(&tmp, "ghostty/logs/ghostty.log");
    defer alloc.free(appended);
    try std.testing.expectEqualStrings("after rotation\nagain\n", appended);
}

test "windows log: panic text reaches the file sink" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try testBase(&tmp);
    defer alloc.free(base);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("LOCALAPPDATA", base);

    init(alloc, &env);
    defer deinit();
    writePanic("boom", null, null);

    const text = try readLog(&tmp, "ghostty/logs/ghostty.log");
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "panic: boom\n") != null);
}

test "windows log: formatted entries reach the file sink" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try testBase(&tmp);
    defer alloc.free(base);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("LOCALAPPDATA", base);

    init(alloc, &env);
    defer deinit();
    logFmt(.warn, .config, "value={d} name={s}", .{ 42, "Анна" }, .{ .file = true, .debugger = false });
    logFmt(.info, .default, "skipped", .{}, .{ .file = false, .debugger = false });

    const text = try readLog(&tmp, "ghostty/logs/ghostty.log");
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " warning(config): value=42 name=Анна\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skipped") == null);
}

test "windows log: panic guard admits only the first panic" {
    resetPanicGuard();
    defer resetPanicGuard();
    try std.testing.expect(beginPanic());
    try std.testing.expect(!beginPanic());
    try std.testing.expect(!beginPanic());
    resetPanicGuard();
    try std.testing.expect(beginPanic());
}

test "windows log: truncation never leaves a partial UTF-8 sequence" {
    try std.testing.expectEqualStrings("ab", trimPartialUtf8("ab"));
    try std.testing.expectEqualStrings("", trimPartialUtf8(""));
    // Complete 2/3/4-byte sequences stay.
    try std.testing.expectEqualStrings("aя", trimPartialUtf8("aя"));
    try std.testing.expectEqualStrings("a€", trimPartialUtf8("a€"));
    try std.testing.expectEqualStrings("a😀", trimPartialUtf8("a😀"));
    // Cut sequences go.
    try std.testing.expectEqualStrings("a", trimPartialUtf8("aя"[0..2]));
    try std.testing.expectEqualStrings("a", trimPartialUtf8("a€"[0..2]));
    try std.testing.expectEqualStrings("a", trimPartialUtf8("a€"[0..3]));
    try std.testing.expectEqualStrings("a", trimPartialUtf8("a😀"[0..4]));
    try std.testing.expectEqualStrings("a", trimPartialUtf8("a😀"[0..2]));
}

test "windows log: long messages are cut on a codepoint boundary" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try testBase(&tmp);
    defer alloc.free(base);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("LOCALAPPDATA", base);

    init(alloc, &env);
    defer deinit();
    // 3-byte codepoints: 3072 is divisible by 3, so use an odd prefix to
    // force a cut in the middle of one.
    const filler = try alloc.alloc(u8, 3300);
    defer alloc.free(filler);
    for (0..1100) |i| @memcpy(filler[i * 3 ..][0..3], "€");
    logFmt(.info, .default, "x{s}", .{filler}, .{ .file = true, .debugger = false });

    const text = try readLog(&tmp, "ghostty/logs/ghostty.log");
    defer alloc.free(text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(text[text.len - 1] == '\n');
}
