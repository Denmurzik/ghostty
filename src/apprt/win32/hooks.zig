//! Fan-out of the lifecycle events to the M3 feature modules. The apprt core
//! files (`App`, `Window`, `Tab`, `Surface`, `clipboard`) call only this
//! file, so a feature never needs another edit in them. Each function calls
//! its listed features in the order given; the order matters (a feature that
//! reads state another one writes comes after it).
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const CommandPalette = @import("CommandPalette.zig");
const Inspector = @import("inspector/Inspector.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const SearchBar = @import("SearchBar.zig");
const app_toast = @import("app_toast.zig");
const badges = @import("badges.zig");
const composition = @import("composition.zig");
const config_errors = @import("config_errors.zig");
const decor = @import("decor.zig");
const export_io = @import("export_io.zig");
const hotkeys = @import("hotkeys.zig");
const key_state = @import("key_state.zig");
const link = @import("link.zig");
const messages = @import("messages.zig");
const notify = @import("notify.zig");
const overlay = @import("overlay.zig");
const recovery = @import("recovery.zig");
const shell_open = @import("shell_open.zig");

const Config = configpkg.Config;

const log = std.log.scoped(.win32_hooks);
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

/// What `WM_GHOSTTY_POSTED_DIALOG` (wparam) asks for.
pub const DialogKind = enum(usize) { export_io, config_errors, url_confirm };

/// The end of `App.init`.
pub fn appStarted(app: *App) void {
    hotkeys.appStarted(app);
    notify.appStarted(app);
    config_errors.appStarted(app);
}

/// The start of `App.terminate`.
pub fn appStopping(app: *App) void {
    hotkeys.appStopping(app);
    app.visibility.deinit(app.core_app.alloc);
    shell_open.appStopping(app);
    Inspector.appStopping(app);
    notify.deinit(app);
    drainDialogs(app.msg_hwnd);
}

/// Dialogs posted to the message window that nobody will pump any more.
fn drainDialogs(hwnd: win32.foundation.HWND) void {
    var msg: win32.user32.MSG = undefined;
    const m = messages.WM_GHOSTTY_POSTED_DIALOG;
    while (win32.user32.PeekMessageW(&msg, hwnd, m, m, win32.user32.PM_REMOVE) != 0) {
        discardDialog(msg.wParam, msg.lParam);
    }
}

/// The app-level config changed; `reloaded` when the files were read again.
pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void {
    decor.configChanged(app, config);
    overlay.configChanged(app, config);
    hotkeys.configChanged(app, config);
    QuickTerminal.configChanged(app, config);
    composition.configChanged(app, config);
    notify.configChanged(app, config);
    config_errors.configChanged(app, config, reloaded);
    if (reloaded) app_toast.configReloaded(app);
}

/// A message of the message window, before its default arm. A non-null
/// result ends the message's processing.
pub fn appMessage(app: *App, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        win32.user32.WM_HOTKEY => return hotkeys.message(app, msg, wparam, lparam),
        messages.WM_GHOSTTY_NOTIFY_CLICK => {
            notify.clicked(app, wparam);
            return 0;
        },
        messages.WM_GHOSTTY_WAKEUP => {
            Inspector.wakeup(app);
            return null;
        },
        win32.user32.WM_TIMER => return recovery.timer(app, wparam),
        messages.WM_GHOSTTY_POSTED_DIALOG => {
            // Posted before any window existed (start-up config errors).
            if (std.enums.fromInt(DialogKind, wparam) == .config_errors) {
                config_errors.postedApp(app, lparam);
            } else discardDialog(wparam, lparam);
            return 0;
        },
        else => return null,
    }
}

/// A `WM_GHOSTTY_POSTED_DIALOG` that will never be delivered (its window is
/// going away): frees what its lparam owns.
pub fn discardDialog(wparam: WPARAM, lparam: LPARAM) void {
    const kind = std.enums.fromInt(DialogKind, wparam) orelse return;
    switch (kind) {
        .export_io => export_io.discard(lparam),
        .config_errors => config_errors.discard(lparam),
        .url_confirm => link.discard(lparam),
    }
}

/// A message of a top-level window. Runs first in the window's chain
/// (before `frame.handle`), so a feature can keep the window drawn as
/// active or swallow a message the frame would act on.
pub fn windowMessage(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        win32.user32.WM_ACTIVATE => {
            // Both features see the activation; the overlays' answer wins.
            const overlays = overlay.windowMessage(window, msg, wparam, lparam);
            const quick = QuickTerminal.windowMessage(window, msg, wparam, lparam);
            return overlays orelse quick;
        },
        win32.user32.WM_NCACTIVATE => return overlay.windowMessage(window, msg, wparam, lparam),
        win32.user32.WM_TIMER => return QuickTerminal.windowMessage(window, msg, wparam, lparam),
        messages.WM_GHOSTTY_POSTED_DIALOG => {
            const kind = std.enums.fromInt(DialogKind, wparam) orelse {
                log.warn("unknown dialog kind={}", .{wparam});
                return 0;
            };
            switch (kind) {
                .export_io => export_io.postedDialog(window, lparam),
                .config_errors => config_errors.postedDialog(window, lparam),
                .url_confirm => link.postedDialog(window, lparam),
            }
            return 0;
        },
        messages.WM_GHOSTTY_OVERLAY_CMD => {
            // The handler owns the heap command: nobody claiming it frees it here.
            if (!CommandPalette.command(window, lparam) and !SearchBar.command(window, lparam)) {
                overlay.freeCommand(lparam);
            }
            return 0;
        },
        else => return null,
    }
}

pub const WindowChange = enum { moved, sized, dpi, minimized, restored, activated, deactivated, destroying };

pub fn windowChanged(window: *Window, change: WindowChange) void {
    overlay.windowChanged(window, change);
    if (change == .destroying) link.windowDestroying(window);
    if (change == .destroying) CommandPalette.windowDestroying(window);
    QuickTerminal.windowChanged(window, change);
}

/// The tab became the window's visible one (or stopped being it).
pub fn tabShown(tab: *Tab, shown: bool) void {
    overlay.tabShown(tab, shown);
}

/// Called at the point where `Tab.setWindow` has moved the tab.
pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    overlay.tabReparented(tab, from, to);
    composition.tabReparented(tab, from, to);
}

pub fn surfaceCreated(surface: *Surface) void {
    decor.surfaceCreated(surface);
    composition.surfaceCreated(surface);
}

/// Before core tears the surface down.
pub fn surfaceDestroying(surface: *Surface) void {
    overlay.surfaceDestroying(surface);
    SearchBar.surfaceDestroying(surface);
    CommandPalette.surfaceDestroying(surface);
    link.surfaceDestroying(surface);
    badges.surfaceDestroying(surface);
    key_state.surfaceDestroying(surface);
    Inspector.surfaceDestroying(surface);
    composition.surfaceDestroying(surface);
}

/// WM_SETFOCUS / WM_KILLFOCUS of the surface child.
pub fn surfaceFocus(surface: *Surface, focused: bool) void {
    decor.surfaceFocus(surface, focused);
    overlay.surfaceFocus(surface, focused);
}

/// After every relayout of the tab's split tree and every change of its
/// active surface.
pub fn tabLayoutChanged(tab: *Tab) void {
    decor.tabLayoutChanged(tab);
}

/// WM_WINDOWPOSCHANGED of the surface child.
pub fn surfaceRectChanged(surface: *Surface) void {
    overlay.surfaceRectChanged(surface);
}

/// A message of a surface window, before the default chain.
pub fn surfaceMessage(surface: *Surface, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = lparam;
    switch (msg) {
        messages.WM_GHOSTTY_SET_CONTENT => return composition.setContent(surface, wparam),
        // A key press ends the bell border: one flag test.
        win32.user32.WM_KEYDOWN => {
            decor.keyDown(surface);
            return null;
        },
        else => return null,
    }
}

/// After a successful write to the standard clipboard; `cleared` when the
/// text was empty.
pub fn clipboardWritten(surface: *Surface, cleared: bool) void {
    app_toast.clipboardWritten(surface, cleared);
}

pub fn rendererHealth(surface: *Surface, health: apprt.Action.Value(.renderer_health)) void {
    badges.rendererHealth(surface, health);
    recovery.rendererHealth(surface, health);
}

/// The `m3` object of the IPC `state` op. Only called with
/// `GHOSTTY_WIN32_TEST_IPC=1`.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.objectField("m3");
    try jw.beginObject();
    try jw.objectField("overlay");
    try overlay.testState(app, jw);
    try jw.objectField("decor");
    try decor.testState(app, jw);
    try jw.objectField("notify");
    try notify.testState(app, jw);
    try jw.objectField("quick");
    try QuickTerminal.testState(app, jw);
    try jw.objectField("search");
    try SearchBar.testState(app, jw);
    try jw.objectField("palette");
    try CommandPalette.testState(app, jw);
    try jw.objectField("composition");
    try composition.testState(app, jw);
    try jw.objectField("hotkeys");
    try hotkeys.testState(app, jw);
    try jw.objectField("health");
    try recovery.testState(app, jw);
    try jw.objectField("opened");
    try shell_open.testState(app, jw);
    try jw.objectField("inspector");
    try Inspector.testState(app, jw);
    try jw.objectField("export_io");
    try export_io.testState(app, jw);
    try jw.endObject();
}

test "win32 hooks: testState writes an m3 object" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    // Only the windows are looked at.
    var app: App = undefined;
    app.windows = .empty;
    app.quick = .{};
    app.shell_open = .{};
    try testState(&app, &jw);
    try jw.endObject();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const m3 = parsed.value.object.get("m3") orelse return error.TestUnexpectedResult;
    try std.testing.expect(m3 == .object);
    inline for (.{ "overlay", "decor", "notify", "quick", "search", "palette", "composition", "hotkeys", "health", "opened", "inspector", "export_io" }) |key| {
        try std.testing.expect(m3.object.get(key) != null);
    }
}
