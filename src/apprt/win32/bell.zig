//! Bell feedback: tab and window title decoration, taskbar flash, system
//! beep and audio, and the border the renderer draws around the surface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");

const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const decor = @import("decor.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_bell);

/// The bell emoji and a space, put before the caption while a bell rings.
const caption_prefix = "\u{1F514} ";

/// Ring the bell of `surface` as the config's `bell-features` ask. The
/// audio plays asynchronously, so this never blocks the UI thread.
pub fn ring(surface: *Surface) bool {
    const window = surface.window;
    const features = window.app.config.@"bell-features";
    const foreground = win32.user32.GetForegroundWindow() == window.hwnd;

    if (features.title) {
        // A focused surface needs no reminder of what it just did.
        const focused = foreground and win32.user32.GetFocus() == surface.hwnd;
        if (!focused and !surface.bell_ringing) {
            surface.bell_ringing = true;
            if (window.activeTab() == surface.tab) window.refreshTitle();
            Chrome.invalidate(window);
        }
    }

    if (features.border) {
        const focused = foreground and win32.user32.GetFocus() == surface.hwnd;
        decor.showBellBorder(surface, focused);
    }

    if (features.attention and !foreground) {
        var info: win32.user32.FLASHWINFO = .{
            .hwnd = window.hwnd,
            .dwFlags = win32.user32.FLASHW_TRAY | win32.user32.FLASHW_TIMERNOFG,
        };
        _ = win32.user32.FlashWindowEx(&info);
    }

    if (features.system) _ = win32.user32.MessageBeep(win32.user32.MB_OK);

    if (features.audio) playAudio(window.app);

    return true;
}

/// WAV files only; `bell-audio-volume` has no Windows equivalent and is ignored.
fn playAudio(app: *App) void {
    const path = app.config.@"bell-audio-path" orelse return;
    const alloc = app.core_app.alloc;
    const wide = util.utf16z(alloc, switch (path) {
        inline else => |p| p,
    }) catch |err| {
        log.warn("unable to convert bell audio path err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    const flags = win32.winmm.SND_ASYNC | win32.winmm.SND_FILENAME | win32.winmm.SND_NODEFAULT;
    if (win32.winmm.PlaySoundW(wide, null, flags) == 0)
        log.warn("unable to play bell audio", .{});
}

/// `title` with the bell prefix when `ringing`.
pub fn bellTitle(alloc: Allocator, title: []const u8, ringing: bool) Allocator.Error![]u8 {
    if (!ringing) return alloc.dupe(u8, title);
    return std.mem.concat(alloc, u8, &.{ caption_prefix, title });
}

/// The caption for `tab`: its bell prefix when one of its surfaces rings
/// and `bell-features = title` is on.
pub fn decorateTitle(alloc: Allocator, title: []const u8, tab: *const Tab) ![:0]u8 {
    const ringing = tab.window.app.config.@"bell-features".title and tab.bellRinging();
    const decorated = try bellTitle(alloc, title, ringing);
    defer alloc.free(decorated);
    return alloc.dupeSentinel(u8, decorated, 0);
}

test "win32 bell: caption prefix" {
    const alloc = std.testing.allocator;

    const plain = try bellTitle(alloc, "shell", false);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("shell", plain);

    const ringing = try bellTitle(alloc, "shell", true);
    defer alloc.free(ringing);
    try std.testing.expectEqualStrings("\u{1F514} shell", ringing);
}
