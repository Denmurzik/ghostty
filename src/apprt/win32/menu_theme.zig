//! Dark popup menus (the tab menu, the terminal context menu, the "+" profile
//! menu, the tray menu, the caption menu). There is no documented switch, so
//! the process-wide menu theme of uxtheme is used the way Windows Terminal and
//! Notepad++ use it: ordinal 135 `SetPreferredAppMode` (Windows 10 1903 and
//! later) and ordinal 136 `FlushMenuThemes`. The mode follows the app theme
//! (`theme.zig`); where the ordinals are missing, or the build is older than
//! 1903, menus simply stay light.
const std = @import("std");
const win32 = @import("win32");

const log = std.log.scoped(.win32_menu_theme);

/// `PreferredAppMode` of uxtheme.
pub const Mode = enum(i32) {
    default = 0,
    allow_dark = 1,
    force_dark = 2,
    force_light = 3,
};

/// Windows 10 1903, the first build whose ordinal 135 is `SetPreferredAppMode`
/// (on 1809 it is `AllowDarkModeForApp(bool)`).
pub const min_build: u32 = 18362;

/// The mode for the app theme; null leaves the menus alone (unknown or
/// too old a build). High contrast keeps the system's own menus.
pub fn modeFor(dark: bool, high_contrast: bool, build: u32) ?Mode {
    if (build < min_build) return null;
    if (high_contrast) return .default;
    return if (dark) .force_dark else .force_light;
}

const SetPreferredAppModeFn = *const fn (i32) callconv(.winapi) i32;
const FlushMenuThemesFn = *const fn () callconv(.winapi) void;

/// UI thread only.
var resolved = false;
var set_mode: ?SetPreferredAppModeFn = null;
var flush: ?FlushMenuThemesFn = null;
var current: ?Mode = null;

fn resolve() void {
    if (resolved) return;
    resolved = true;
    const lib = std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll");
    const module = win32.kernel32.LoadLibraryExW(lib, null, win32.kernel32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return;
    // GetProcAddress takes an ordinal as a pointer-sized integer.
    const a = win32.kernel32.GetProcAddress(module, @ptrFromInt(135)) orelse return;
    const b = win32.kernel32.GetProcAddress(module, @ptrFromInt(136)) orelse return;
    set_mode = @ptrCast(a);
    flush = @ptrCast(b);
}

fn buildNumber() u32 {
    var info: std.os.windows.RTL_OSVERSIONINFOW = std.mem.zeroes(std.os.windows.RTL_OSVERSIONINFOW);
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return 0;
    return info.dwBuildNumber;
}

/// Follows the app theme; cheap when nothing changed.
pub fn apply(dark: bool, high_contrast: bool) void {
    const mode = modeFor(dark, high_contrast, buildNumber()) orelse return;
    if (current == mode) return;
    resolve();
    const set = set_mode orelse return;
    const flush_fn = flush orelse return;
    _ = set(@backingInt(mode));
    flush_fn();
    current = mode;
    log.debug("menu theme {s}", .{@tagName(mode)});
}

test "win32 menu theme: mode decision" {
    const t = std.testing;
    try t.expectEqual(@as(?Mode, .force_dark), modeFor(true, false, 22631));
    try t.expectEqual(@as(?Mode, .force_light), modeFor(false, false, 22631));
    try t.expectEqual(@as(?Mode, .force_dark), modeFor(true, false, min_build));
    // High contrast: the system's own menus.
    try t.expectEqual(@as(?Mode, .default), modeFor(true, true, 22631));
    // Before 1903, ordinal 135 means something else: untouched.
    try t.expectEqual(@as(?Mode, null), modeFor(true, false, min_build - 1));
    try t.expectEqual(@as(?Mode, null), modeFor(false, false, 0));
}
