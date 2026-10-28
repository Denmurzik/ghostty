//! The About dialog (macOS `AboutView`): the name, the one-line description,
//! the version, build channel and commit, and buttons for the project page
//! and the docs, which open through the link opener (`shell_open`). It is
//! the same WinUI-style dialog as the other prompts, so it follows the
//! light/dark theme; it has no icon (the dialog has no image slot). The
//! dialog runs a message loop, so it is only ever shown from a posted
//! message: `request` posts it.
const std = @import("std");
const win32 = @import("win32");
const build_config = @import("../../build_config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const dialogs = @import("dialogs.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");
const shell_open = @import("shell_open.zig");

const log = std.log.scoped(.win32_about);

pub const project_url = "https://github.com/Denmurzik/ghostty";
pub const docs_url = "https://ghostty.org/docs";

pub const description = "Fast, native, feature-rich terminal emulator pushing modern features.";

const button_docs = 100;
const button_project = 101;
const button_close = 102;

/// A dialog is up: a second request is dropped.
var showing = false;

/// Ask for the dialog: posted to the last active normal window, or to the
/// message window when there is none.
pub fn request(app: *App) void {
    const hwnd = if (app.last_active) |w| w.hwnd else if (app.lastNormalWindow()) |w| w.hwnd else app.msg_hwnd;
    if (win32.user32.PostMessageW(
        hwnd,
        messages.WM_GHOSTTY_POSTED_DIALOG,
        @backingInt(hooks.DialogKind.about),
        0,
    ) == 0) log.warn("unable to post the About dialog", .{});
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `about` on a window.
pub fn postedDialog(window: *Window) void {
    show(window.app, window.hwnd);
}

/// The same, for the message window (no window open).
pub fn postedApp(app: *App) void {
    show(app, null);
}

fn show(app: *App, owner: ?win32.foundation.HWND) void {
    if (showing) return;
    showing = true;
    defer showing = false;

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(description) catch {};
    w.writeAll("\n\n") catch {};
    writeRows(&w, build_config.version_string, build_config.version, build_config.release_channel) catch {};

    const buttons = [_]dialogs.ListButton{
        .{ .id = button_docs, .text = "&Docs" },
        .{ .id = button_project, .text = "&GitHub" },
        .{ .id = button_close, .text = "Close" },
    };
    const answer = dialogs.taskDialogList(owner, "About Ghostty", "Ghostty", w.buffered(), &buttons, button_close) orelse return;
    switch (answer) {
        button_docs => shell_open.submit(app, 0, .unknown, docs_url),
        button_project => shell_open.submit(app, 0, .unknown, project_url),
        else => {},
    }
}

/// The rows under the description, in the order of the macOS view: Version,
/// Channel, Commit (a `-<hash>` build tag of a pre-release version).
pub fn writeRows(
    w: *std.Io.Writer,
    version_string: []const u8,
    version: std.SemanticVersion,
    channel: build_config.ReleaseChannel,
) !void {
    try w.print("Version  {s}\n", .{version_string});
    try w.print("Channel  {s}\n", .{@tagName(channel)});
    if (version.build) |commit| {
        if (commit.len > 0) try w.print("Commit  {s}\n", .{commit});
    }
}

test "win32 about: rows" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRows(&w, "1.3.2-dev-win.5", .{ .major = 1, .minor = 3, .patch = 2, .pre = "dev", .build = "abc1234" }, .tip);
    try std.testing.expectEqualStrings("Version  1.3.2-dev-win.5\nChannel  tip\nCommit  abc1234\n", w.buffered());

    var w2: std.Io.Writer = .fixed(&buf);
    try writeRows(&w2, "1.3.0", .{ .major = 1, .minor = 3, .patch = 0 }, .stable);
    try std.testing.expectEqualStrings("Version  1.3.0\nChannel  stable\n", w2.buffered());
}

test "win32 about: links are https" {
    try std.testing.expect(std.mem.startsWith(u8, project_url, "https://"));
    try std.testing.expect(std.mem.startsWith(u8, docs_url, "https://"));
}
