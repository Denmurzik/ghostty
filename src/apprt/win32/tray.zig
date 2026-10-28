//! The notification-area icon. Without `quit-after-last-window-closed` Ghostty
//! outlives its last window and the icon is the way back in: click for a
//! window, right click for New Window / Quit. Only the process that owns the
//! IPC pipe has one. The icon belongs to a hidden top-level tool window (a
//! message-only window gets no `TaskbarCreated` broadcast).
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const about = @import("about.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Window = @import("Window.zig");
const dpi_mod = @import("dpi.zig");
const profiles_menu = @import("profiles_menu.zig");
const messages = @import("messages.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_tray);

const HWND = win32.foundation.HWND;
const HICON = win32.user32.HICON;
const shell32 = win32.shell32;
const user32 = win32.user32;

pub const WM_GHOSTTY_TRAY = messages.WM_GHOSTTY_TRAY;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTray");
const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

/// The icon of the exe (`dist/windows/ghostty.rc`, `ID_ICON_GHOSTTY`).
const icon_resource_id = 1;

/// The only icon of the process.
const icon_id: u32 = 1;

pub const menu_new_window: u32 = 1;
pub const menu_quit: u32 = 2;
pub const menu_about: u32 = 3;

pub const State = struct {
    hwnd: ?HWND = null,
    /// The icon is in the notification area.
    visible: bool = false,
    /// `RegisterWindowMessage("TaskbarCreated")`: Explorer restarted.
    taskbar_created: u32 = 0,
    icon: ?HICON = null,
};

/// What a left click on the icon does.
pub const ClickAction = enum { present_last, new_window };

pub fn clickAction(windows: usize) ClickAction {
    return if (windows == 0) .new_window else .present_last;
}

/// Creates the hidden window and the icon, and puts the icon in the
/// notification area when the config wants it. Call once, with a pipe owner.
pub fn init(app: *App) !void {
    std.debug.assert(app.tray.hwnd == null);

    try util.registerClass(&.{
        .lpfnWndProc = wndProc,
        .hInstance = app.hinstance,
        .lpszClassName = class_name,
    });

    const hwnd = user32.CreateWindowExW(
        user32.WS_EX_TOOLWINDOW,
        class_name,
        tip,
        user32.WS_POPUP,
        0,
        0,
        0,
        0,
        null,
        null,
        app.hinstance,
        app,
    ) orelse {
        log.err("tray window creation failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    app.tray.hwnd = hwnd;

    app.tray.taskbar_created = user32.RegisterWindowMessageW(
        std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"),
    );

    // An elevated process only hears these from Explorer when allowed.
    allowMessage(hwnd, app.tray.taskbar_created);
    allowMessage(hwnd, user32.RegisterWindowMessageW(
        std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"),
    ));

    app.tray.icon = loadIcon(app.hinstance, hwnd);
    syncTo(app, app.config.@"quit-after-last-window-closed");
}

/// Shows or hides the icon to match `quit_after_last`: visible exactly when
/// the process outlives its last window.
pub fn syncTo(app: *App, quit_after_last: bool) void {
    if (app.tray.hwnd == null) return;
    const want = !quit_after_last;
    if (want == app.tray.visible) return;
    if (want) add(app) else remove(app);
}

pub fn deinit(app: *App) void {
    remove(app);
    if (app.tray.icon) |icon| _ = user32.DestroyIcon(icon);
    app.tray.icon = null;
    if (app.tray.hwnd) |hwnd| _ = user32.DestroyWindow(hwnd);
    app.tray.hwnd = null;
}

fn add(app: *App) void {
    var nid: shell32.NOTIFYICONDATAW = .{
        .hWnd = app.tray.hwnd,
        .uID = icon_id,
        .uFlags = shell32.NIF_MESSAGE | shell32.NIF_ICON | shell32.NIF_TIP | shell32.NIF_SHOWTIP,
        .uCallbackMessage = WM_GHOSTTY_TRAY,
        .hIcon = app.tray.icon,
    };
    @memcpy(nid.szTip[0..tip.len], tip);

    // Explorer may not be up yet (a login autostart): `visible` still
    // records the wish, and `TaskbarCreated` adds the icon once it is.
    app.tray.visible = true;
    if (shell32.Shell_NotifyIconW(shell32.NIM_ADD, &nid) == 0) {
        log.warn("unable to add the notification icon", .{});
        return;
    }
    nid.uVersion = shell32.NOTIFYICON_VERSION_4;
    _ = shell32.Shell_NotifyIconW(shell32.NIM_SETVERSION, &nid);
}

/// Explorer restarted: its icons are gone, and the size of the small icon
/// may have changed. Delete first so that a stale icon is never duplicated.
fn readd(app: *App) void {
    const hwnd = app.tray.hwnd orelse return;
    var nid: shell32.NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = icon_id };
    _ = shell32.Shell_NotifyIconW(shell32.NIM_DELETE, &nid);
    if (app.tray.icon) |icon| _ = user32.DestroyIcon(icon);
    app.tray.icon = loadIcon(app.hinstance, hwnd);
    add(app);
}

fn remove(app: *App) void {
    if (!app.tray.visible) return;
    app.tray.visible = false;
    var nid: shell32.NOTIFYICONDATAW = .{
        .hWnd = app.tray.hwnd,
        .uID = icon_id,
    };
    _ = shell32.Shell_NotifyIconW(shell32.NIM_DELETE, &nid);
}

fn allowMessage(hwnd: HWND, msg: u32) void {
    if (msg == 0) return;
    _ = user32.ChangeWindowMessageFilterEx(hwnd, msg, user32.MSGFLT_ALLOW, null);
}

/// The small icon at the DPI of the tray window; null when the binary
/// carries no resources (tests), which leaves the icon blank.
fn loadIcon(hinstance: win32.foundation.HINSTANCE, hwnd: HWND) ?HICON {
    const dpi = user32.GetDpiForWindow(hwnd);
    const size = user32.GetSystemMetricsForDpi(user32.SM_CXSMICON, if (dpi == 0) dpi_mod.default_dpi else dpi);
    const id: *const anyopaque = @ptrFromInt(icon_resource_id);
    const handle = user32.LoadImageW(hinstance, id, user32.IMAGE_ICON, size, size, user32.LR_DEFAULTCOLOR) orelse return null;
    return @ptrCast(handle);
}

fn wndProc(
    hwnd: HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    if (msg == user32.WM_NCCREATE) {
        const cs: *const user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        util.setUserData(hwnd, cs.lpCreateParams);
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const app = util.fromUserData(App, hwnd) orelse
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (app.tray.taskbar_created != 0 and msg == app.tray.taskbar_created) {
        // Explorer restarted: its icons are gone.
        if (app.tray.visible) readd(app);
        return 0;
    }

    switch (msg) {
        WM_GHOSTTY_TRAY => {
            const event: u16 = @truncate(@as(usize, @bitCast(lparam)));
            switch (event) {
                shell32.NIN_SELECT, shell32.NIN_KEYSELECT => click(app),
                user32.WM_CONTEXTMENU => {
                    // Version 4: the anchor point is packed into wparam.
                    var pt: win32.foundation.POINT = .{
                        .x = @as(i16, @bitCast(@as(u16, @truncate(wparam)))),
                        .y = @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16)))),
                    };
                    if (wparam == 0) _ = user32.GetCursorPos(&pt);
                    showMenu(app, pt.x, pt.y);
                },
                else => {},
            }
            return 0;
        },

        user32.WM_COMMAND => {
            runCommand(app, @as(u16, @truncate(wparam)));
            return 0;
        },

        // A light/dark switch with no window open reaches nobody else.
        user32.WM_SETTINGCHANGE => {
            theme.settingChangedMsg(app, wparam, lparam);
            return 0;
        },

        // Nothing to ask: the session is ending either way.
        user32.WM_QUERYENDSESSION => return 1,
        user32.WM_ENDSESSION => {
            if (wparam != 0) {
                // The process may be killed once this returns: take the
                // icon out now.
                deinit(app);
                user32.PostQuitMessage(0);
            }
            return 0;
        },

        user32.WM_NCDESTROY => util.setUserData(hwnd, null),

        else => {},
    }

    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn click(app: *App) void {
    switch (clickAction(QuickTerminal.countOpen(app.windows.items, false))) {
        .new_window => newWindow(app),
        .present_last => {
            const window = app.last_active orelse lastNormal(app) orelse return;
            window.activate();
        },
    }
}

fn lastNormal(app: *App) ?*Window {
    var i = app.windows.items.len;
    while (i > 0) {
        i -= 1;
        if (app.windows.items[i].kind == .normal) return app.windows.items[i];
    }
    return null;
}

fn newWindow(app: *App) void {
    const window = Window.create(app, .{}) catch |err| {
        log.warn("unable to create a window err={}", .{err});
        return;
    };
    window.show();
    window.activate();
}

fn showMenu(app: *App, x: i32, y: i32) void {
    const hwnd = app.tray.hwnd orelse return;
    const menu = user32.CreatePopupMenu() orelse {
        log.warn("unable to build the tray menu err={}", .{win32.kernel32.GetLastError()});
        return;
    };
    defer _ = user32.DestroyMenu(menu);
    _ = user32.AppendMenuW(menu, user32.MF_STRING, menu_new_window, std.unicode.utf8ToUtf16LeStringLiteral("&New Window"));
    _ = profiles_menu.appendTrayItems(app, menu, profiles_menu.tray_first_id);
    _ = user32.AppendMenuW(menu, user32.MF_SEPARATOR, 0, null);
    _ = user32.AppendMenuW(menu, user32.MF_STRING, menu_about, std.unicode.utf8ToUtf16LeStringLiteral("&About Ghostty"));
    _ = user32.AppendMenuW(menu, user32.MF_STRING, menu_quit, std.unicode.utf8ToUtf16LeStringLiteral("&Quit"));

    // The menu belongs to the foreground window, or it will not close
    // when the user clicks elsewhere.
    _ = user32.SetForegroundWindow(hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON | user32.TPM_BOTTOMALIGN,
        x,
        y,
        hwnd,
        null,
    );
    // Lets the loop of the menu finish before the next message.
    _ = user32.PostMessageW(hwnd, user32.WM_NULL, 0, 0);
    if (cmd > 0) {
        runCommand(app, @intCast(cmd));
    } else {
        // Keyboard users come back to the icon after a dismissed menu.
        var nid: shell32.NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = icon_id };
        _ = shell32.Shell_NotifyIconW(shell32.NIM_SETFOCUS, &nid);
    }
}

fn runCommand(app: *App, id: u32) void {
    switch (id) {
        menu_new_window => newWindow(app),
        menu_about => about.request(app),
        // Confirms if a process is running; with no window it quits at once.
        menu_quit => if (user32.PostMessageW(app.msg_hwnd, App.WM_GHOSTTY_QUIT, 0, 0) == 0) {
            log.warn("unable to post quit request", .{});
        },
        else => _ = profiles_menu.trayCommand(app, id),
    }
}

test "win32 tray: click action" {
    try std.testing.expectEqual(ClickAction.new_window, clickAction(0));
    try std.testing.expectEqual(ClickAction.present_last, clickAction(1));
    try std.testing.expectEqual(ClickAction.present_last, clickAction(2));
}

test "win32 tray: menu ids and message" {
    try std.testing.expect(menu_new_window != menu_quit and menu_about != menu_quit and menu_about != menu_new_window);
    try std.testing.expectEqual(user32.WM_APP + 9, WM_GHOSTTY_TRAY);
}

test "win32 tray: profile submenu ids do not collide" {
    const pm = profiles_menu;
    try std.testing.expect(menu_new_window < pm.tray_first_id and menu_quit < pm.tray_first_id and menu_about < pm.tray_first_id);
    // The strip menu range ends before the tray range starts.
    try std.testing.expect(pm.first_id + 2 * pm.max_profiles <= pm.tray_first_id);
    try std.testing.expect(pm.tray_first_id + pm.max_profiles < 0x10000);
    try std.testing.expect(!pm.isTrayId(menu_quit));
}
