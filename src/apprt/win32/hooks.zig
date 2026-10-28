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
const jumplist = @import("jumplist.zig");
const key_state = @import("key_state.zig");
const link = @import("link.zig");
const messages = @import("messages.zig");
const notify = @import("notify.zig");
const osk = @import("osk.zig");
const overlay = @import("overlay.zig");
const profiles = @import("profiles.zig");
const recovery = @import("recovery.zig");
const scrollbar = @import("scrollbar.zig");
const secure_input = @import("secure_input.zig");
const shell_open = @import("shell_open.zig");
const step_resize = @import("step_resize.zig");
const tmux_Registry = @import("tmux/Registry.zig");
const tmux_Server = @import("tmux/Server.zig");
const tmux_pane_io = @import("tmux/pane_io.zig");
const tmux_labels = @import("tmux/labels.zig");
const undo_actions = @import("actions/undo_actions.zig");
const Updater = @import("update/Updater.zig");

const Config = configpkg.Config;

const log = std.log.scoped(.win32_hooks);
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

/// What `WM_GHOSTTY_POSTED_DIALOG` (wparam) asks for.
pub const DialogKind = enum(usize) { export_io, config_errors, url_confirm, export_done, secure_input };

/// Set by the crash handler (M5 Task 12): re-installs the unhandled-exception
/// filter if another module replaced it.
pub var crash_recheck: ?*const fn () void = null;

/// The end of `App.init`.
pub fn appStarted(app: *App) void {
    hotkeys.appStarted(app);
    composition.appStarted();
    notify.appStarted(app);
    config_errors.appStarted(app);
    jumplist.schedule(app);
    Updater.start(app);
    secure_input.appStarted(app);
    if (crash_recheck) |recheck| recheck();
}

/// The start of `App.terminate`.
pub fn appStopping(app: *App) void {
    hotkeys.appStopping(app);
    app.visibility.deinit(app.core_app.alloc);
    shell_open.appStopping(app);
    Inspector.appStopping(app);
    composition.appStopping(app);
    notify.deinit(app);
    tmux_Registry.appStopping(app);
    tmux_pane_io.appStopping(app);
    undo_actions.flushAll(app);
    Updater.stop(app);
    jumplist.stop(app);
    export_io.appStopping(app);
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
    tmux_labels.configChanged(app);
    decor.configChanged(app, config);
    overlay.configChanged(app, config);
    hotkeys.configChanged(app, config);
    QuickTerminal.configChanged(app, config);
    composition.configChanged(app, config);
    notify.configChanged(app, config);
    config_errors.configChanged(app, config, reloaded);
    jumplist.configChanged(app, config);
    Updater.configChanged(app, config);
    secure_input.configChanged(app, config);
    tmux_Server.configChanged(app, config);
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
        win32.user32.WM_TIMER => {
            if (recovery.timer(app, wparam)) |r| return r;
            if (wparam == messages.timers.msg_window.tmux_keys) {
                tmux_pane_io.onTimer(app);
                return 0;
            }
            if (wparam == messages.timers.msg_window.update) {
                Updater.onTimer(app);
                return 0;
            }
            if (wparam == messages.timers.msg_window.undo_expire) {
                undo_actions.onTimer(app);
                return 0;
            }
            if (wparam == messages.timers.msg_window.jumplist_delay) {
                jumplist.onTimer(app);
                return 0;
            }
            return null;
        },
        messages.WM_GHOSTTY_UPDATE_RESULT => {
            Updater.onResult(app, lparam);
            return 0;
        },
        messages.WM_GHOSTTY_POSTED_DIALOG => {
            // Posted before any window existed (start-up config errors).
            switch (std.enums.fromInt(DialogKind, wparam) orelse .export_io) {
                .config_errors => config_errors.postedApp(app, lparam),
                .url_confirm => link.postedApp(app, lparam),
                .secure_input => {},
                .export_io => discardDialog(wparam, lparam),
                .export_done => export_io.doneApp(app, lparam),
            }
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
        .export_done => export_io.discardDone(lparam),
        .config_errors => config_errors.discard(lparam),
        .url_confirm => link.discard(lparam),
        .secure_input => {},
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
        win32.user32.WM_NCACTIVATE => return overlay.windowMessage(window, msg, wparam, lparam) orelse composition.windowMessage(window, msg, wparam),
        win32.user32.WM_SHOWWINDOW => return composition.windowMessage(window, msg, wparam),
        win32.user32.WM_TIMER => return QuickTerminal.windowMessage(window, msg, wparam, lparam),
        win32.user32.WM_SIZING => return step_resize.sizing(window, wparam, lparam),
        messages.WM_GHOSTTY_POSTED_DIALOG => {
            const kind = std.enums.fromInt(DialogKind, wparam) orelse {
                log.warn("unknown dialog kind={}", .{wparam});
                return 0;
            };
            switch (kind) {
                .export_io => export_io.postedDialog(window, lparam),
                .export_done => export_io.discardDone(lparam),
                .config_errors => config_errors.postedDialog(window, lparam),
                .url_confirm => link.postedDialog(window, lparam),
                .secure_input => secure_input.postedDialog(window),
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
    tmux_labels.windowChanged(window, change);
}

/// The tab became the window's visible one (or stopped being it).
pub fn tabShown(tab: *Tab, shown: bool) void {
    overlay.tabShown(tab, shown);
    scrollbar.tabShown(tab, shown);
    tmux_labels.tabShown(tab, shown);
}

/// Called at the point where `Tab.setWindow` has moved the tab.
pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    overlay.tabReparented(tab, from, to);
    composition.tabReparented(tab, from, to);
    tmux_labels.tabReparented(tab, from, to);
}

/// The title of the surface changed (the program's or the user's).
pub fn surfaceTitleChanged(surface: *Surface) void {
    tmux_labels.refreshPane(surface);
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
    tmux_pane_io.surfaceDestroying(surface);
    tmux_labels.surfaceDestroying(surface);
    tmux_Registry.surfaceDestroying(surface);
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
    secure_input.tabLayoutChanged(tab);
    tmux_pane_io.layoutChanged(tab);
    tmux_labels.tabLayoutChanged(tab);
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
    badges.rendererHealth(surface, health, recovery.reasonFor(surface.badges.health_reason, surface.app.recovery.warp));
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
    try jw.objectField("config_errors");
    try config_errors.testState(app, jw);
    try jw.endObject();
    try jw.objectField("m5");
    try jw.beginObject();
    try jw.objectField("profiles");
    try profiles.testState(app, jw);
    try jw.objectField("jumplist");
    try jumplist.testState(app, jw);
    try jw.objectField("update");
    try Updater.testState(app, jw);
    try jw.objectField("secure_input");
    try secure_input.testState(app, jw);
    try jw.objectField("undo");
    try undo_actions.testState(app, jw);
    try jw.objectField("osk");
    try osk.testState(app, jw);
    try jw.endObject();
    try tmux_Server.testState(app, jw);
}

test "win32 hooks: testState writes an m3 object" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    // Only the windows are looked at.
    var app: App = undefined;
    app.windows = .empty;
    app.parked_windows = .empty;
    app.quick = .{};
    app.shell_open = .{};
    app.tmux_server = .{};
    app.tmux_labels = .{};
    app.profiles = .{};
    app.undo = .{};
    app.update = .{};
    app.secure = .{};
    try testState(&app, &jw);
    try jw.endObject();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const m3 = parsed.value.object.get("m3") orelse return error.TestUnexpectedResult;
    try std.testing.expect(m3 == .object);
    const tmux = parsed.value.object.get("tmux") orelse return error.TestUnexpectedResult;
    try std.testing.expect(tmux.object.get("panes") != null);
    const m5 = parsed.value.object.get("m5") orelse return error.TestUnexpectedResult;
    inline for (.{ "profiles", "jumplist", "update", "secure_input", "undo", "osk" }) |key| {
        try std.testing.expect(m5.object.get(key) != null);
    }
    inline for (.{ "overlay", "decor", "notify", "quick", "search", "palette", "composition", "hotkeys", "health", "opened", "inspector", "export_io", "config_errors" }) |key| {
        try std.testing.expect(m3.object.get(key) != null);
    }
}
