//! Secure input: the Windows analog of macOS `SecureInput` (owner: M5
//! Task 13), app-wide like macOS and driven by `toggle_secure_input`.
//!
//! What it does while on:
//!  1. every top-level window of the UI thread is excluded from screen
//!     capture (`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`): the
//!     windows, overlay popups, dialogs, inspector windows and the tab drag
//!     ghost. A sweep runs on every toggle and each creation site calls
//!     `apply`;
//!  2. text copied from Ghostty carries `ExcludeClipboardContentFromMonitorProcessing`,
//!     `CanIncludeInClipboardHistory = 0` and `CanUploadToCloudClipboard = 0`
//!     (`clipboard.zig`);
//!  3. a lock badge sits on every surface (`macos-secure-input-indication`).
//!
//! What it cannot do, and the user is told so in the explainer dialog:
//!  - Windows has no API that hides keystrokes from other programs running
//!    as the same user. Low-level keyboard hooks, `GetAsyncKeyState`, raw
//!    input and reading this process's memory or its ConPTY pipes all keep
//!    working. macOS Secure Event Input has no counterpart here, so this is
//!    NOT protection against a keylogger or malware running as the user.
//!  - The clipboard markers are a convention honoured by Windows clipboard
//!    history, the cloud clipboard and well-behaved managers. Any program
//!    can still read the clipboard while it holds the text.
//!  - The capture exclusion covers capture APIs (screenshots, recording,
//!    screen sharing, remote-assistance tools built on them). It does not
//!    stop a camera pointed at the screen, a capture card, and may not apply
//!    to every remote-desktop stack. Windows that Ghostty does not own, and
//!    system-drawn menus created after a toggle, are outside the sweep.
//!    Taskbar and Alt+Tab thumbnails come from DWM; whether they honour the
//!    exclusion was not verified.
//!  - ConPTY has no termios, so there is no automatic secure input at
//!    password prompts (macOS `macos-auto-secure-input`). A documented gap.
//!  - Needs Windows 10 version 2004 or later; where the call fails it is
//!    logged and the windows stay capturable.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const badges = @import("badges.zig");
const dialogs = @import("dialogs.zig");
const geom = @import("geom.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");
const overlay = @import("overlay.zig");
const Config = @import("../../config.zig").Config;

const user32 = win32.user32;
const log = std.log.scoped(.win32_secure_input);

pub const State = struct { on: bool = false };

/// Mirror of `App.secure.on` for `apply`, which only has a window. UI
/// thread only; written in one place (`setOn`).
var active = false;

/// The explainer behind a badge click is modal: a second click while it is
/// up must not stack another.
var explaining = false;

/// The next state for `value`.
pub fn next(on: bool, value: apprt.action.SecureInput) bool {
    return switch (value) {
        .on => true,
        .off => false,
        .toggle => !on,
    };
}

pub fn perform(app: *App, target: apprt.Target, value: apprt.action.SecureInput) !bool {
    // App-wide like macOS: the target does not matter.
    _ = target;
    const want = next(app.secure.on, value);
    if (want == app.secure.on) return true;
    setOn(app, want);
    return true;
}

fn setOn(app: *App, on: bool) void {
    app.secure.on = on;
    active = on;
    sweep(on);
    syncBadges(app, on and app.config.@"macos-secure-input-indication");
}

pub fn appStarted(app: *App) void {
    app.secure = .{};
    active = false;
}

/// Gives a window the current affinity. No-op while off, so a creation site
/// costs one flag test.
pub fn apply(hwnd: win32.foundation.HWND) void {
    if (!active) return;
    setAffinity(hwnd, user32.WDA_EXCLUDEFROMCAPTURE);
}

/// `clipboard.zig` asks.
pub fn copying(app: *App) bool {
    return app.secure.on;
}

/// After every relayout of a tab: a surface that appeared while secure
/// input is on (new tab, split) gets its badge.
pub fn tabLayoutChanged(tab: *Tab) void {
    if (!active) return;
    if (!tab.window.app.config.@"macos-secure-input-indication") return;
    syncTab(tab, true);
}

/// A config change may switch the indication on or off.
pub fn configChanged(app: *App, config: *const Config) void {
    if (!active) return;
    syncBadges(app, config.@"macos-secure-input-indication");
}

fn setAffinity(hwnd: win32.foundation.HWND, want: u32) void {
    var current: u32 = undefined;
    if (user32.GetWindowDisplayAffinity(hwnd, &current) != 0 and current == want) return;
    if (user32.SetWindowDisplayAffinity(hwnd, want) == 0) {
        log.warn("unable to set the display affinity affinity={x} err={}", .{ want, win32.kernel32.GetLastError() });
    }
}

fn sweepProc(hwnd: win32.foundation.HWND, lparam: win32.foundation.LPARAM) callconv(.winapi) win32.foundation.BOOL {
    setAffinity(hwnd, @intCast(lparam));
    return 1;
}

/// Sets the affinity of every top-level window of this thread.
fn sweep(on: bool) void {
    const want: u32 = if (on) user32.WDA_EXCLUDEFROMCAPTURE else user32.WDA_NONE;
    _ = user32.EnumThreadWindows(win32.kernel32.GetCurrentThreadId(), sweepProc, @intCast(want));
}

fn syncTab(tab: *Tab, shown: bool) void {
    var it = tab.tree.iterator();
    while (it.next()) |entry| badges.secureBadge(entry.view, shown);
}

fn syncBadges(app: *App, shown: bool) void {
    var it = app.forEachWindow(true);
    while (it.next()) |window| {
        for (window.tabs.items) |tab| syncTab(tab, shown);
    }
}

// -- Badge -------------------------------------------------------------------

/// Window procedure hook of the badge popup: it takes the click and shows a
/// hand cursor. The dialog itself is posted: it runs a message loop.
pub fn badgeMessage(
    p: *overlay.Popup,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = wparam;
    _ = lparam;
    switch (msg) {
        user32.WM_NCHITTEST => return user32.HTCLIENT,
        user32.WM_SETCURSOR => {
            _ = user32.SetCursor(user32.LoadCursorW(null, user32.IDC_HAND));
            return 1;
        },
        user32.WM_LBUTTONUP => {
            if (user32.PostMessageW(
                p.window.hwnd,
                messages.WM_GHOSTTY_POSTED_DIALOG,
                @backingInt(hooks.DialogKind.secure_input),
                0,
            ) == 0) log.warn("unable to post the secure input explainer", .{});
            return 0;
        },
        else => return null,
    }
}

const explainer =
    "While Secure Input is on, Ghostty's windows are hidden from screen capture " ++
    "and screen sharing, and text you copy in Ghostty is kept out of Windows " ++
    "clipboard history and the cloud clipboard.\n\n" ++
    "Windows cannot hide your keystrokes from other programs running as you, " ++
    "so this does not protect against keyloggers or malware. Ghostty also " ++
    "cannot detect password prompts on Windows: Secure Input is on only when " ++
    "you turn it on with the toggle_secure_input action.";

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `secure_input`.
pub fn postedDialog(window: *Window) void {
    if (explaining) return;
    explaining = true;
    defer explaining = false;
    dialogs.inform(window.hwnd, "Secure Input", "Secure Input is active.", explainer);
}

// -- Test state --------------------------------------------------------------

const TestCtx = struct {
    jw: *std.json.Stringify,
    err: ?anyerror = null,
};

fn hexOf(buf: []u8, hwnd: win32.foundation.HWND) ![]const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{@intFromPtr(hwnd)});
}

fn windowEntry(jw: *std.json.Stringify, hwnd: win32.foundation.HWND) !void {
    var hex: [32]u8 = undefined;
    var class16: [64]u16 = undefined;
    var class8: [128]u8 = undefined;
    const n: usize = @intCast(@max(user32.GetClassNameW(hwnd, &class16, class16.len), 0));
    const class_len = std.unicode.utf16LeToUtf8(&class8, class16[0..n]) catch 0;
    var affinity: u32 = 0xFFFF;
    _ = user32.GetWindowDisplayAffinity(hwnd, &affinity);

    try jw.beginObject();
    try jw.objectField("hwnd");
    try jw.write(try hexOf(&hex, hwnd));
    try jw.objectField("class");
    try jw.write(class8[0..class_len]);
    try jw.objectField("affinity");
    try jw.write(affinity);
    try jw.objectField("visible");
    try jw.write(user32.IsWindowVisible(hwnd) != 0);
    try jw.endObject();
}

fn listProc(hwnd: win32.foundation.HWND, lparam: win32.foundation.LPARAM) callconv(.winapi) win32.foundation.BOOL {
    const ctx: *TestCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    windowEntry(ctx.jw, hwnd) catch |err| {
        ctx.err = err;
        return 0;
    };
    return 1;
}

/// `windows`: every top-level window of the UI thread with its affinity.
/// `badges`: one entry per surface badge (visible, screen rect, affinity).
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("on");
    try jw.write(app.secure.on);

    try jw.objectField("windows");
    try jw.beginArray();
    var ctx: TestCtx = .{ .jw = jw };
    _ = user32.EnumThreadWindows(win32.kernel32.GetCurrentThreadId(), listProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.err) |err| return err;
    try jw.endArray();

    try jw.objectField("badges");
    try jw.beginArray();
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var tree = tab.tree.iterator();
            while (tree.next()) |entry| {
                const label = entry.view.badges.secure orelse continue;
                const hwnd = label.popup.hwnd orelse continue;
                var rc: win32.foundation.RECT = undefined;
                _ = user32.GetWindowRect(hwnd, &rc);
                var hex: [32]u8 = undefined;
                var affinity: u32 = 0xFFFF;
                _ = user32.GetWindowDisplayAffinity(hwnd, &affinity);
                try jw.beginObject();
                try jw.objectField("hwnd");
                try jw.write(try hexOf(&hex, hwnd));
                try jw.objectField("surface");
                try jw.write(entry.view.id);
                try jw.objectField("visible");
                try jw.write(user32.IsWindowVisible(hwnd) != 0);
                try jw.objectField("rect");
                try jw.write([4]i32{ rc.left, rc.top, rc.right, rc.bottom });
                try jw.objectField("affinity");
                try jw.write(affinity);
                try jw.endObject();
            }
        }
    }
    try jw.endArray();
    try jw.endObject();
}

// -- Tests -------------------------------------------------------------------

test "win32 secure input: toggle state machine" {
    const A = apprt.action.SecureInput;
    for ([_]bool{ false, true }) |start| {
        try std.testing.expect(next(start, A.on));
        try std.testing.expect(!next(start, A.off));
        try std.testing.expectEqual(!start, next(start, A.toggle));
    }
}

test "win32 secure input: badge geometry" {
    try std.testing.expectEqual(35, badges.secure_side);
    try std.testing.expectEqual(25, badges.secure_glyph);
    try std.testing.expectEqual(5, badges.secure_pad);
    try std.testing.expectEqual(10, badges.secure_inset);

    const surface: geom.Rect = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    const window: geom.Rect = .{ .x = 80, .y = 20, .w = 900, .h = 700 };
    const cases = [_]struct { dpi: u32, side: i32, inset: i32 }{
        .{ .dpi = 96, .side = 35, .inset = 10 },
        .{ .dpi = 144, .side = 53, .inset = 15 },
        .{ .dpi = 192, .side = 70, .inset = 20 },
    };
    for (cases) |c| {
        const side = geom.scale(badges.secure_side, c.dpi);
        const inset = geom.scale(badges.secure_inset, c.dpi);
        try std.testing.expectEqual(c.side, side);
        try std.testing.expectEqual(c.inset, inset);
        const r = overlay.rectFor(.surface_top_right, surface, window, .{ .w = side, .h = side }, inset, null);
        try std.testing.expectEqual(surface.right() - side - c.inset, r.x);
        try std.testing.expectEqual(surface.y + c.inset, r.y);
        try std.testing.expectEqual(side, r.w);
        try std.testing.expectEqual(side, r.h);
    }
}
