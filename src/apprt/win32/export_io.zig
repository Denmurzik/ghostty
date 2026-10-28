//! Saves the terminal IO log of the inspector to a file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const app_toast = @import("app_toast.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");
const ops = @import("ipc/ops.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_export_io);

/// The wall-clock fields a default file name is made of.
pub const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// What the save dialog is about; the handler of `WM_GHOSTTY_POSTED_DIALOG`
/// (kind `export_io`) owns and frees it.
const Payload = struct {
    alloc: Allocator,
    bytes: []u8,

    fn destroy(self: *Payload) void {
        self.alloc.free(self.bytes);
        self.alloc.destroy(self);
    }
};

/// UI thread only; there is one app per process.
var saving = false;
var saved_total: u32 = 0;
var last_path: [520]u8 = undefined;
var last_path_len: usize = 0;
var last_bytes: usize = 0;

/// The inspector's export button: the contents are copied and the dialog is
/// shown from a posted message, not from inside the action. In test mode no
/// dialog is shown (the common dialogs keep a most-recently-used list in the
/// registry of the user): the request is only recorded.
pub fn save(app: *App, target: apprt.Target, value: apprt.Action.Value(.export_terminal_io)) bool {
    if (ops.testOpsEnabled()) {
        record("", value.contents.len);
        return true;
    }

    const window = app.windowForTarget(target) orelse app.last_active orelse app.lastNormalWindow() orelse return false;
    const alloc = app.core_app.alloc;
    const payload = alloc.create(Payload) catch return false;
    payload.* = .{ .alloc = alloc, .bytes = alloc.dupe(u8, value.contents) catch {
        alloc.destroy(payload);
        return false;
    } };
    if (win32.user32.PostMessageW(
        window.hwnd,
        messages.WM_GHOSTTY_POSTED_DIALOG,
        @backingInt(hooks.DialogKind.export_io),
        @bitCast(@intFromPtr(payload)),
    ) == 0) {
        log.warn("unable to post the export dialog", .{});
        payload.destroy();
        return false;
    }
    return true;
}

/// The test-mode entry (IPC op `export-io`): no dialog, the bytes go to `path`.
pub fn saveTest(app: *App, target: apprt.Target, value: apprt.Action.Value(.export_terminal_io), path: []const u8) bool {
    _ = target;
    if (!pathSafe(path)) return false;
    writeBytes(app.core_app.alloc, path, value.contents) catch |err| {
        log.warn("unable to write the export err={}", .{err});
        return false;
    };
    record(path, value.contents.len);
    return true;
}

/// The window the message was posted to is gone: free the payload.
pub fn discard(lparam: win32.foundation.LPARAM) void {
    payloadOf(lparam).destroy();
}

fn payloadOf(lparam: win32.foundation.LPARAM) *Payload {
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `export_io`.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    const payload = payloadOf(lparam);
    defer payload.destroy();
    // The dialog runs a message loop; a second one would stack.
    if (saving) return;
    saving = true;
    defer saving = false;

    var local: win32.kernel32.SYSTEMTIME = undefined;
    win32.kernel32.GetLocalTime(&local);
    var name_buf: [64]u8 = undefined;
    const name = defaultName(&name_buf, .{
        .year = local.wYear,
        .month = @intCast(local.wMonth),
        .day = @intCast(local.wDay),
        .hour = @intCast(local.wHour),
        .minute = @intCast(local.wMinute),
        .second = @intCast(local.wSecond),
    });

    const alloc = payload.alloc;
    var file: [2048]u16 = @splat(0);
    {
        const wide = util.utf16z(alloc, name) catch return;
        defer alloc.free(wide);
        @memcpy(file[0..wide.len], wide);
    }

    const w16 = std.unicode.utf8ToUtf16LeStringLiteral;
    var ofn: win32.comdlg32.OPENFILENAMEW = .{
        .hwndOwner = window.hwnd,
        .lpstrFilter = w16("Text (*.txt)\x00*.txt\x00All files (*.*)\x00*.*\x00"),
        .nFilterIndex = 1,
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrTitle = w16("Export Terminal IO"),
        .lpstrDefExt = w16("txt"),
        .Flags = win32.comdlg32.OFN_OVERWRITEPROMPT | win32.comdlg32.OFN_PATHMUSTEXIST |
            win32.comdlg32.OFN_NOCHANGEDIR | win32.comdlg32.OFN_EXPLORER,
    };
    if (win32.comdlg32.GetSaveFileNameW(&ofn) == 0) {
        const err = win32.comdlg32.CommDlgExtendedError();
        if (err != 0) log.warn("the save dialog failed err=0x{x}", .{err});
        return;
    }

    const len = std.mem.indexOfScalar(u16, &file, 0) orelse file.len;
    const path = util.utf8(alloc, file[0..len]) catch return;
    defer alloc.free(path);
    if (!pathSafe(path)) {
        log.warn("refusing to write the export to an unsafe path", .{});
        return;
    }
    // The write runs on a worker thread; the result comes back through a
    // posted message (`doneApp`). The job owns the bytes from here on.
    const bytes = payload.bytes;
    payload.bytes = &.{};
    startJob(window.app, path, bytes, postDone) catch |err| {
        log.warn("unable to start the export err={}", .{err});
        alloc.free(bytes);
        app_toast.exportResult(window.app, false);
    };
}

/// A write that is in flight (or finished and waiting to be reported).
/// Allocated by `startJob`, freed by whoever consumes the result.
const Job = struct {
    alloc: Allocator,
    path: []u8,
    bytes: []u8,
    msg_hwnd: win32.foundation.HWND,
    ok: bool = false,
    on_done: *const fn (*Job) void,

    fn destroy(self: *Job) void {
        self.alloc.free(self.path);
        self.alloc.free(self.bytes);
        self.alloc.destroy(self);
    }

    fn run(self: *Job) void {
        writeBytes(self.alloc, self.path, self.bytes) catch |err| {
            log.warn("unable to write the export err={}", .{err});
            self.ok = false;
            self.finish();
            return;
        };
        self.ok = true;
        self.finish();
    }

    fn finish(self: *Job) void {
        // After the decrement a bounded wait may return; the callback only
        // relies on `self`.
        const on_done = self.on_done;
        _ = in_flight.fetchSub(1, .release);
        on_done(self);
    }
};

/// Jobs started and not finished writing. The quit path waits for it to
/// reach zero (bounded).
var in_flight: std.atomic.Value(u32) = .init(0);
/// Set once the app is stopping: finished jobs free themselves.
var stopping: std.atomic.Value(bool) = .init(false);

/// How long quitting waits for a write in flight, milliseconds.
const quit_wait_ms = 3000;

/// Starts a worker that writes `bytes` to a copy of `path` and then calls
/// `on_done` on the worker thread. On success the job owns `bytes`; on an
/// error the caller keeps them.
fn startJob(app: *App, path: []const u8, bytes: []u8, on_done: *const fn (*Job) void) !void {
    const alloc = app.core_app.alloc;
    const job = try alloc.create(Job);
    errdefer alloc.destroy(job);
    const path_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(path_copy);
    job.* = .{
        .alloc = alloc,
        .path = path_copy,
        .bytes = bytes,
        .msg_hwnd = app.msg_hwnd,
        .on_done = on_done,
    };
    try spawn(job);
}

fn spawn(job: *Job) !void {
    _ = in_flight.fetchAdd(1, .acq_rel);
    errdefer _ = in_flight.fetchSub(1, .acq_rel);
    const thread = try std.Thread.spawn(.{}, Job.run, .{job});
    thread.detach();
}

/// On the worker: posts the finished job to the message window. A failed
/// post (the window is gone) or a stopping app frees the job here.
fn postDone(job: *Job) void {
    if (stopping.load(.acquire)) return job.destroy();
    if (win32.user32.PostMessageW(
        job.msg_hwnd,
        messages.WM_GHOSTTY_POSTED_DIALOG,
        @backingInt(hooks.DialogKind.export_done),
        @bitCast(@intFromPtr(job)),
    ) == 0) job.destroy();
}

fn jobOf(lparam: win32.foundation.LPARAM) *Job {
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `export_done` on the message window:
/// the write finished; record it and tell the user.
pub fn doneApp(app: *App, lparam: win32.foundation.LPARAM) void {
    const job = jobOf(lparam);
    defer job.destroy();
    if (job.ok) record(job.path, job.bytes.len);
    app_toast.exportResult(app, job.ok);
}

/// The message window is going away with a result in its queue.
pub fn discardDone(lparam: win32.foundation.LPARAM) void {
    jobOf(lparam).destroy();
}

/// The start of `App.terminate`: waits (bounded) for writes in flight so a
/// quit does not cut a file in half. A write that outlasts the wait frees
/// itself when it ends; the process exits anyway.
pub fn appStopping(app: *App) void {
    _ = app;
    stopping.store(true, .release);
    if (!waitIdle(quit_wait_ms)) log.warn("an export write is still running at quit", .{});
}

/// Whether every write in flight finished within `timeout_ms`.
fn waitIdle(timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (in_flight.load(.acquire) != 0) {
        if (waited >= timeout_ms) return false;
        std.Io.sleep(global.io(), .fromMilliseconds(5), .awake) catch {};
        waited += 5;
    }
    return true;
}

/// The bytes exactly as given: no BOM, no line-ending conversion. Written to
/// a temp file next to path and moved over it, so a failed write never
/// leaves a truncated file (macOS writes atomically too).
fn writeBytes(alloc: Allocator, path: []const u8, data: []const u8) !void {
    const io = global.io();
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const temp = try std.fmt.allocPrint(alloc, "{s}.{x}.tmp", .{ path, rnd });
    defer alloc.free(temp);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = temp, .data = data });
    errdefer cwd.deleteFile(io, temp) catch {};

    const wide_temp = try util.utf16z(alloc, temp);
    defer alloc.free(wide_temp);
    const wide_path = try util.utf16z(alloc, path);
    defer alloc.free(wide_path);
    if (win32.kernel32.MoveFileExW(wide_temp, wide_path, win32.kernel32.MOVEFILE_REPLACE_EXISTING | win32.kernel32.MOVEFILE_WRITE_THROUGH) == 0) return error.MoveFailed;
}

fn record(path: []const u8, bytes: usize) void {
    saved_total += 1;
    last_path_len = @min(path.len, last_path.len);
    @memcpy(last_path[0..last_path_len], path[0..last_path_len]);
    last_bytes = bytes;
}

/// "ghostty-yyyymmdd-hhmmss.txt".
pub fn defaultName(buf: []u8, now: Timestamp) []const u8 {
    return std.fmt.bufPrint(buf, "ghostty-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.txt", .{
        now.year, now.month, now.day, now.hour, now.minute, now.second,
    }) catch "ghostty.txt";
}

/// Whether `path` may be written: no NUL, no `..` component, no
/// alternate data stream (a `:` anywhere but after the drive letter), no
/// device namespace prefix (`\\?\`, `\\.\`). Used for the path from the
/// save dialog and for the test op's path alike.
pub fn pathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.startsWith(u8, path, "\\??\\")) return false;
    if (path.len >= 4 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and
        (path[2] == '?' or path[2] == '.') and (path[3] == '\\' or path[3] == '/')) return false;
    for (path, 0..) |c, i| {
        if (c == ':' and i != 1) return false;
    }
    var parts = std.mem.tokenizeAny(u8, path, "\\/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.objectField("count");
    try jw.write(saved_total);
    try jw.objectField("path");
    try jw.write(last_path[0..last_path_len]);
    try jw.objectField("bytes");
    try jw.write(last_bytes);
    try jw.endObject();
}

test "win32 export: default file name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ghostty-20261027-093005.txt",
        defaultName(&buf, .{ .year = 2026, .month = 10, .day = 27, .hour = 9, .minute = 30, .second = 5 }),
    );
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("ghostty.txt", defaultName(&tiny, .{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }));
}

test "win32 export: path safety refuses dot-dot, streams and device paths" {
    const t = std.testing;
    try t.expect(pathSafe("C:\\tmp\\out.txt"));
    try t.expect(pathSafe("d:/tmp/out.txt"));
    try t.expect(pathSafe("\\\\server\\share\\out.txt"));
    try t.expect(pathSafe("C:\\tmp\\a..b.txt"));
    try t.expect(!pathSafe(""));
    try t.expect(!pathSafe("C:\\tmp\\..\\out.txt"));
    try t.expect(!pathSafe("C:/tmp/../out.txt"));
    try t.expect(!pathSafe("C:\\tmp\\out.txt:stream"));
    try t.expect(!pathSafe("C:\\tmp\\out.txt::$DATA"));
    try t.expect(!pathSafe("\\\\?\\C:\\x"));
    try t.expect(!pathSafe("\\\\.\\C:\\x"));
    try t.expect(!pathSafe("\\??\\UNC\\s\\x"));
    try t.expect(!pathSafe("C:\\x\x00y"));
}

const TestDone = struct {
    var finished: std.atomic.Value(bool) = .init(false);
    var ok: bool = false;
    fn done(job: *Job) void {
        ok = job.ok;
        job.destroy();
        finished.store(true, .release);
    }
};

test "win32 export: the write runs on a worker and reports back" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(global.io(), ".", t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fmt.allocPrint(t.allocator, "{s}\\out.txt", .{dir});
    defer t.allocator.free(path);

    TestDone.finished.store(false, .release);
    const job = try t.allocator.create(Job);
    job.* = .{
        .alloc = t.allocator,
        .path = try t.allocator.dupe(u8, path),
        .bytes = try t.allocator.dupe(u8, "hello\r\nworld"),
        .msg_hwnd = undefined,
        .on_done = TestDone.done,
    };
    try spawn(job);
    try t.expect(waitIdle(5000));
    while (!TestDone.finished.load(.acquire)) std.Io.sleep(global.io(), .fromMilliseconds(1), .awake) catch {};
    try t.expect(TestDone.ok);

    const got = try tmp.dir.readFileAlloc(global.io(), "out.txt", t.allocator, .limited(64));
    defer t.allocator.free(got);
    try t.expectEqualStrings("hello\r\nworld", got);
}

test "win32 export: quit waits for a write in flight, bounded" {
    const t = std.testing;
    try t.expect(waitIdle(0));
    _ = in_flight.fetchAdd(1, .acq_rel);
    try t.expect(!waitIdle(20));
    _ = in_flight.fetchSub(1, .acq_rel);
    try t.expect(waitIdle(20));
}
