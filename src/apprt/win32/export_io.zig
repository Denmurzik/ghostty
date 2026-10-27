//! Saves the terminal IO log of the inspector to a file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
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

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;

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
    _ = app;
    _ = target;
    if (!pathSafe(path)) return false;
    writeBytes(path, value.contents) catch |err| {
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

    var local: SYSTEMTIME = undefined;
    GetLocalTime(&local);
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
    writeBytes(path, payload.bytes) catch |err| {
        log.warn("unable to write the export err={}", .{err});
        return;
    };
    record(path, payload.bytes.len);
}

/// The bytes exactly as given: no BOM, no line-ending conversion.
fn writeBytes(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = path, .data = data });
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
    try t.expect(!pathSafe("C:\\x\x00y"));
}
