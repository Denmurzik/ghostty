//! Shows the errors of the config (at start-up and after a reload), like the
//! GTK dialog and the macOS ConfigurationErrors view: what is wrong, and
//! "Reload configuration" / "Open configuration" / "Ignore".
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Diagnostic = @import("../../cli/diagnostics.zig").Diagnostic;
const App = @import("App.zig");
const Window = @import("Window.zig");
const app_actions = @import("actions/app_actions.zig");
const dialogs = @import("dialogs.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");

const log = std.log.scoped(.win32_config_errors);

/// Diagnostics listed in the dialog; the rest is summarised.
const max_listed = 20;

const button_reload = 100;
const button_open = 101;
const button_ignore = win32.comctl32.IDCANCEL;

/// UI thread only; there is one app per process.
var showing = false;
var pending = false;
var shown_total: u32 = 0;
var last_count: usize = 0;
var last_text: [2048]u8 = undefined;
var last_text_len: usize = 0;
var last_choice: []const u8 = "";

/// The text the dialog lists, built when the errors were found: the config
/// they came from may be gone by the time the dialog is up.
const Payload = struct {
    alloc: Allocator,
    count: usize,
    text: []u8,

    fn destroy(self: *Payload) void {
        self.alloc.free(self.text);
        self.alloc.destroy(self);
    }
};

pub fn appStarted(app: *App) void {
    post(app, &app.config);
}

pub fn configChanged(app: *App, config: *const configpkg.Config, reloaded: bool) void {
    // A soft apply does not read the files again: nothing new to report.
    if (reloaded) post(app, config);
}

/// One diagnostic per line (the way the CLI prints them), at most `max`
/// lines, then "and N more".
pub fn formatDiagnostics(alloc: Allocator, diags: []const Diagnostic, max: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    for (diags[0..@min(diags.len, max)], 0..) |*diag, i| {
        if (i > 0) try w.writeByte('\n');
        try diag.format(w);
    }
    if (diags.len > max) try w.print("\nand {d} more", .{diags.len - max});
    return aw.toOwnedSlice();
}

fn post(app: *App, config: *const configpkg.Config) void {
    const diags = config._diagnostics.list.items;
    if (diags.len == 0) return;
    // The dialog runs a message loop, and a request for another one while it
    // is up (or queued) would stack.
    if (showing or pending) return;

    const alloc = app.core_app.alloc;
    const text = formatDiagnostics(alloc, diags, max_listed) catch |err| {
        log.warn("unable to format the config errors err={}", .{err});
        return;
    };
    const payload = alloc.create(Payload) catch |err| {
        log.warn("unable to allocate the config errors dialog err={}", .{err});
        alloc.free(text);
        return;
    };
    payload.* = .{ .alloc = alloc, .count = diags.len, .text = text };

    // No window at start-up yet: the message window takes it, and the
    // handler finds the owner when it runs.
    const target = if (app.last_active orelse app.lastNormalWindow()) |w| w.hwnd else app.msg_hwnd;
    if (win32.user32.PostMessageW(
        target,
        messages.WM_GHOSTTY_POSTED_DIALOG,
        @backingInt(hooks.DialogKind.config_errors),
        @bitCast(@intFromPtr(payload)),
    ) == 0) {
        log.warn("unable to post the config errors dialog", .{});
        payload.destroy();
        return;
    }
    pending = true;
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `config_errors`, sent to a window.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    show(window.app, window.hwnd, lparam);
}

/// The same, sent to the message window (posted before any window existed).
pub fn postedApp(app: *App, lparam: win32.foundation.LPARAM) void {
    const owner = if (app.last_active orelse app.lastNormalWindow()) |w| w.hwnd else null;
    show(app, owner, lparam);
}

/// Frees the payload of a message that will never be delivered.
pub fn discard(lparam: win32.foundation.LPARAM) void {
    pending = false;
    payloadOf(lparam).destroy();
}

fn payloadOf(lparam: win32.foundation.LPARAM) *Payload {
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

fn show(app: *App, owner: ?win32.foundation.HWND, lparam: win32.foundation.LPARAM) void {
    const payload = payloadOf(lparam);
    defer payload.destroy();
    pending = false;
    if (showing) return;
    showing = true;
    defer showing = false;

    shown_total += 1;
    last_count = payload.count;
    last_text_len = @min(payload.text.len, last_text.len);
    // Never end in the middle of a UTF-8 sequence.
    while (last_text_len > 0 and last_text_len < payload.text.len and (payload.text[last_text_len] & 0xC0) == 0x80) last_text_len -= 1;
    @memcpy(last_text[0..last_text_len], payload.text[0..last_text_len]);
    last_choice = "";

    const alloc = app.core_app.alloc;
    const instruction = std.fmt.allocPrint(
        alloc,
        "{d} {s} found while loading the configuration.",
        .{ payload.count, if (payload.count == 1) "error was" else "errors were" },
    ) catch |err| {
        log.warn("unable to build the config errors dialog err={}", .{err});
        return;
    };
    defer alloc.free(instruction);
    const body = std.fmt.allocPrint(
        alloc,
        "Please review the errors below and reload your configuration or ignore the erroneous lines.\n\n{s}",
        .{payload.text},
    ) catch |err| {
        log.warn("unable to build the config errors dialog err={}", .{err});
        return;
    };
    defer alloc.free(body);

    const buttons = [_]dialogs.ListButton{
        .{ .id = button_reload, .text = "Reload configuration" },
        .{ .id = button_open, .text = "Open configuration" },
        .{ .id = button_ignore, .text = "Ignore" },
    };
    const chosen = dialogs.taskDialogList(owner, "Configuration errors", instruction, body, &buttons, button_reload);
    // The dialog is gone: a reload that still finds errors (it runs
    // synchronously) posts and shows a new one.
    showing = false;
    switch (chosen orelse button_ignore) {
        button_reload => {
            last_choice = "reload";
            _ = app_actions.reload_config(app, .app, .{ .soft = false }) catch |err| {
                log.warn("unable to reload the config err={}", .{err});
            };
        },
        button_open => {
            last_choice = "open";
            _ = app_actions.open_config(app, .app, .os_open) catch |err| {
                log.warn("unable to open the config err={}", .{err});
            };
        },
        else => last_choice = "ignore",
    }
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.objectField("shown");
    try jw.write(shown_total);
    try jw.objectField("open");
    try jw.write(showing);
    try jw.objectField("count");
    try jw.write(last_count);
    try jw.objectField("text");
    try jw.write(last_text[0..last_text_len]);
    try jw.objectField("choice");
    try jw.write(last_choice);
    try jw.endObject();
}

test "win32 config errors: format caps the list" {
    const alloc = std.testing.allocator;
    var diags: [25]Diagnostic = undefined;
    for (&diags, 0..) |*d, i| d.* = .{
        .key = "font-sise",
        .message = if (i == 0) "unknown field" else "invalid value",
    };

    const out = try formatDiagnostics(alloc, &diags, 20);
    defer alloc.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var n: usize = 0;
    var last: []const u8 = "";
    while (lines.next()) |l| : (n += 1) last = l;
    try std.testing.expectEqual(@as(usize, 21), n);
    try std.testing.expectEqualStrings("and 5 more", last);
    try std.testing.expect(std.mem.startsWith(u8, out, "font-sise: unknown field\n"));

    // Within the cap there is no summary line.
    const few = try formatDiagnostics(alloc, diags[0..2], 20);
    defer alloc.free(few);
    try std.testing.expectEqualStrings("font-sise: unknown field\nfont-sise: invalid value", few);

    const none = try formatDiagnostics(alloc, &.{}, 20);
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
