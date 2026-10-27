//! The proxy icon of the title row, after the macOS titlebar's
//! `representedURL` (`BaseTerminalController.pwdDidChange`): the shell's
//! folder icon of the working directory of the focused surface, left of the
//! window title, shown only while that directory is known and
//! `macos-titlebar-proxy-icon` is `visible`.
//!
//! A click opens the folder in Explorer, a right click shows the path menu
//! (the folder and its parents, "Copy path"), and dragging the icon out
//! drags the folder itself (an OLE drag source, so it can be dropped on
//! Explorer, another terminal, any file target).
//!
//! The directory comes from terminal output (OSC 7), so it is untrusted:
//! only local drive paths without control characters get an icon, and the
//! folders are opened through `shell_open`'s validation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const Window = @import("Window.zig");
const clipboard = @import("clipboard.zig");
const link_policy = @import("link_policy.zig");
const shell_open = @import("shell_open.zig");
const TabStrip = @import("TabStrip.zig");
const util = @import("util.zig");

const com = win32.com;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const ole32 = win32.ole32;
const shell32 = win32.shell32;
const user32 = win32.user32;
const HRESULT = win32.foundation.HRESULT;

const log = std.log.scoped(.win32_proxy_icon);

/// `GetDriveTypeW` results that are local to the machine.
const drive_removable = 2;
const drive_fixed = 3;

/// Longest directory the icon is made for.
const max_path = 1024;

/// Menu command of "Copy path"; the folders are 1..n.
const copy_command = 100;

/// Icons kept per window: a shell whose `cd` goes back and forth between a
/// few folders asks the shell for each one once (per DPI).
const cache_slots = 8;

const Entry = struct {
    /// The directory `bitmap` is of (also kept when no icon could be made,
    /// so that it is not tried again).
    path: [:0]u8,
    dpi: u32,
    size: i32,
    bitmap: ?gdi32.HBITMAP,
};

pub const State = struct {
    slots: [cache_slots]?Entry = @splat(null),
    /// The slot the title row shows; null for no icon.
    shown: ?usize = null,
    next: usize = 0,

    fn free(entry: Entry, alloc: Allocator) void {
        if (entry.bitmap) |b| _ = gdi32.DeleteObject(@ptrCast(b));
        alloc.free(entry.path);
    }

    /// The icon of the slot being shown.
    pub fn current(self: *const State) ?Entry {
        const i = self.shown orelse return null;
        return self.slots[i];
    }

    fn find(self: *const State, path: []const u8, dpi: u32) ?usize {
        for (self.slots, 0..) |slot, i| {
            const e = slot orelse continue;
            if (e.dpi == dpi and std.mem.eql(u8, e.path, path)) return i;
        }
        return null;
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.slots) |slot| if (slot) |e| free(e, alloc);
        self.* = .{};
    }
};

/// Whether `path` may get an icon: a local drive path (`C:\...` or `C:/...`;
/// not an msys `/c/...` one, the caller translates those) of sane length and
/// without control, quote or bidi characters.
pub fn usable(path: []const u8) bool {
    if (path.len > max_path or !link_policy.isDriveAbsolute(path)) return false;
    return !shell_open.hasForbidden(path);
}

/// The directory the title row shows the icon for, or null.
pub fn pwdOf(window: *const Window) ?[]const u8 {
    if (window.kind != .normal or window.strip.mode != .titlebar) return null;
    if (window.app.config.@"macos-titlebar-proxy-icon" != .visible) return null;
    const pwd = window.focusedPwd() orelse return null;
    return if (usable(pwd)) pwd else null;
}

/// Brings the icon in line with the focused surface's directory and the
/// window's DPI; true when there is an icon to show. The shell is asked once
/// per folder and DPI (a few are kept), not at every `cd`.
pub fn refresh(window: *Window) bool {
    const alloc = window.app.core_app.alloc;
    const state = &window.proxy;
    const path = pwdOf(window) orelse {
        state.shown = null;
        return false;
    };
    const slot = state.find(path, window.dpi) orelse blk: {
        const copy = alloc.dupeSentinel(u8, path, 0) catch {
            state.shown = null;
            return false;
        };
        const size = TabStrip.Metrics.forDpi(window.dpi).icon_size;
        const i = state.next;
        state.next = (i + 1) % cache_slots;
        if (state.slots[i]) |old| State.free(old, alloc);
        state.slots[i] = .{ .path = copy, .dpi = window.dpi, .size = size, .bitmap = folderIcon(alloc, path, size) };
        break :blk i;
    };
    state.shown = slot;
    return state.slots[slot].?.bitmap != null;
}

/// The path as a wide, backslash-separated string.
fn widePath(alloc: Allocator, path: []const u8) ?[:0]u16 {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    for (wide) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return wide;
}

fn onLocalDrive(wide: []const u16) bool {
    const root = [4:0]u16{ wide[0], ':', '\\', 0 };
    const kind = kernel32.GetDriveTypeW(&root);
    return kind == drive_fixed or kind == drive_removable;
}

/// The shell's icon of the folder at `path`, `px` square, as a bitmap with
/// premultiplied alpha; null when there is no such folder or it is not on a
/// local drive (a network path may stall the UI thread).
fn folderIcon(alloc: Allocator, path: []const u8, px: i32) ?gdi32.HBITMAP {
    const wide = widePath(alloc, path) orelse return null;
    defer alloc.free(wide);
    if (wide.len < 3 or !onLocalDrive(wide)) return null;

    var out: ?*anyopaque = null;
    const hr = shell32.SHCreateItemFromParsingName(wide.ptr, null, &shell32.IID_IShellItemImageFactory, &out);
    if (hr < 0) return null;
    const factory: *shell32.IShellItemImageFactory = @ptrCast(@alignCast(out orelse return null));
    defer com.release(factory);
    const bitmap = factory.getImage(.{ .cx = px, .cy = px }, shell32.SIIGBF_ICONONLY) catch return null;
    const hbitmap: gdi32.HBITMAP = @ptrCast(@alignCast(bitmap));
    premultiplyBitmap(hbitmap);
    return hbitmap;
}

/// The shell hands icons out with straight (not premultiplied) alpha, while
/// `GdiAlphaBlend` with `AC_SRC_ALPHA` wants premultiplied pixels: the
/// half-transparent edge would add a colour brighter than its coverage and
/// overflow into a fringe (green around a yellow folder). Premultiplies the
/// 32-bit DIB in place unless it already is.
fn premultiplyBitmap(bitmap: gdi32.HBITMAP) void {
    var info: gdi32.BITMAP = .{};
    if (gdi32.GetObjectW(@ptrCast(bitmap), @sizeOf(gdi32.BITMAP), &info) == 0) return;
    if (info.bmBitsPixel != 32 or info.bmWidth <= 0) return;
    const bits = info.bmBits orelse return;
    const rows: usize = @abs(info.bmHeight);
    const len = rows * @as(usize, @intCast(info.bmWidthBytes));
    premultiply(@as([*]u8, @ptrCast(bits))[0..len]);
}

/// Premultiplies BGRA pixels when some colour channel exceeds its alpha
/// (which a premultiplied image never has); leaves them alone otherwise.
fn premultiply(pixels: []u8) void {
    var straight = false;
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a = pixels[i + 3];
        if (pixels[i] > a or pixels[i + 1] > a or pixels[i + 2] > a) {
            straight = true;
            break;
        }
    }
    if (!straight) return;
    i = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a: u16 = pixels[i + 3];
        for (pixels[i .. i + 3]) |*c| c.* = @intCast((@as(u16, c.*) * a + 127) / 255);
    }
}

test "win32 proxy_icon: straight alpha is premultiplied, premultiplied is kept" {
    var straight = [_]u8{ 0, 200, 255, 128, 10, 20, 30, 255 };
    premultiply(&straight);
    try std.testing.expectEqualSlices(u8, &.{ 0, 100, 128, 128, 10, 20, 30, 255 }, &straight);

    var pre = [_]u8{ 0, 100, 128, 128, 0, 0, 0, 0 };
    premultiply(&pre);
    try std.testing.expectEqualSlices(u8, &.{ 0, 100, 128, 128, 0, 0, 0, 0 }, &pre);
}

/// Draws the icon into `hdc` (the strip's DC); dimmed while the window is
/// inactive, like the title.
pub fn draw(window: *const Window, hdc: user32.HDC, window_active: bool) void {
    const rect = window.strip.proxy_icon orelse return;
    const icon = window.proxy.current() orelse return;
    const bitmap = icon.bitmap orelse return;
    const mem = gdi32.CreateCompatibleDC(hdc) orelse return;
    defer _ = gdi32.DeleteDC(mem);
    const old = gdi32.SelectObject(mem, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(mem, o);
    };
    const size = icon.size;
    _ = gdi32.GdiAlphaBlend(hdc, rect.x, rect.y, rect.w, rect.h, mem, 0, 0, size, size, .{
        .SourceConstantAlpha = if (window_active) 255 else 128,
        .AlphaFormat = user32.AC_SRC_ALPHA,
    });
}

// -- Actions ------------------------------------------------------------------------

fn focusedSurfaceId(window: *const Window) ?u32 {
    const tab = window.activeTab() orelse return null;
    const surface = tab.focusedSurface() orelse return null;
    return surface.id;
}

/// Opens `path` in Explorer, through the validation of links.
fn openFolder(window: *Window, path: []const u8) void {
    const id = focusedSurfaceId(window) orelse return;
    shell_open.submit(window.app, id, .osc8, path);
}

/// Click: open the folder.
pub fn click(window: *Window) void {
    const path = pwdOf(window) orelse return;
    openFolder(window, path);
}

/// The folders of `path` from itself up to the drive root, as slices of it.
pub fn ancestors(path: []const u8, buf: *[32][]const u8) []const []const u8 {
    var n: usize = 0;
    var end = path.len;
    while (end > 3 and link_policy.isSlash(path[end - 1])) end -= 1;
    while (end > 3 and n < buf.len - 1) {
        buf[n] = path[0..end];
        n += 1;
        // The parent ends before the separator that precedes the last name.
        var i = end;
        while (i > 3 and !link_policy.isSlash(path[i - 1])) i -= 1;
        end = i - 1;
        while (end > 3 and link_policy.isSlash(path[end - 1])) end -= 1;
    }
    buf[n] = path[0..3];
    n += 1;
    return buf[0..n];
}

/// The name a menu item shows for the folder `path`: its last component, or
/// the drive root.
pub fn folderName(path: []const u8) []const u8 {
    if (path.len <= 3) return path;
    var i = path.len;
    while (i > 3 and !link_policy.isSlash(path[i - 1])) i -= 1;
    return path[i..];
}

/// Right click: the folders menu and "Copy path".
pub fn showMenu(window: *Window, screen_x: i32, screen_y: i32) void {
    const alloc = window.app.core_app.alloc;
    // The directory may change while the menu is up: work on a copy.
    const path = alloc.dupe(u8, pwdOf(window) orelse return) catch return;
    defer alloc.free(path);

    const menu = user32.CreatePopupMenu() orelse {
        log.warn("unable to create the path menu err={}", .{kernel32.GetLastError()});
        return;
    };
    defer _ = user32.DestroyMenu(menu);

    var buf: [32][]const u8 = undefined;
    const folders = ancestors(path, &buf);
    for (folders, 1..) |folder, id| {
        var label: [260]u8 = undefined;
        const text = menuLabel(&label, folderName(folder));
        const wide = util.utf16z(alloc, text) catch continue;
        defer alloc.free(wide);
        _ = user32.AppendMenuW(menu, user32.MF_STRING, id, wide.ptr);
    }
    _ = user32.AppendMenuW(menu, user32.MF_SEPARATOR, 0, null);
    _ = user32.AppendMenuW(menu, user32.MF_STRING, copy_command, std.unicode.utf8ToUtf16LeStringLiteral("Copy path"));

    const hwnd = window.hwnd;
    _ = user32.SetForegroundWindow(hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON,
        screen_x,
        screen_y,
        hwnd,
        null,
    );
    _ = user32.PostMessageW(hwnd, user32.WM_NULL, 0, 0);
    // The menu ran a loop of its own: the window may be gone.
    if (cmd <= 0 or util.fromUserData(Window, hwnd) != window) return;
    const chosen: usize = @intCast(cmd);
    if (chosen == copy_command) {
        clipboard.write(window.hwnd, path) catch |err| {
            log.warn("unable to copy the path err={}", .{err});
        };
    } else if (chosen <= folders.len) {
        openFolder(window, folders[chosen - 1]);
    }
}

/// `name` with its `&` doubled (menu mnemonics), cut to `buf`.
fn menuLabel(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        const need: usize = if (c == '&') 2 else 1;
        if (n + need > buf.len) break;
        if (c == '&') {
            buf[n] = '&';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    // A cut inside a code point would leave an invalid tail.
    while (n > 0 and !std.unicode.utf8ValidateSlice(buf[0..n])) n -= 1;
    return buf[0..n];
}

// -- Drag source --------------------------------------------------------------------

/// The drag source: one static object, nothing to free.
const DropSource = struct {
    var object: ole32.IDropSource = .{ .vtable = &vtable };

    const vtable: ole32.IDropSource.VTable = .{
        .base = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .QueryContinueDrag = queryContinueDrag,
        .GiveFeedback = giveFeedback,
    };

    fn queryInterface(this: *com.IUnknown, riid: *const win32.foundation.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(riid.*, ole32.IID_IUnknown) or std.meta.eql(riid.*, ole32.IID_IDropSource)) {
            out.* = this;
            return win32.foundation.S_OK;
        }
        out.* = null;
        return ole32.E_NOINTERFACE;
    }

    fn addRef(_: *com.IUnknown) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *com.IUnknown) callconv(.winapi) u32 {
        return 1;
    }

    fn queryContinueDrag(_: *ole32.IDropSource, escape: win32.foundation.BOOL, key_state: u32) callconv(.winapi) HRESULT {
        return continueDrag(escape != 0, key_state);
    }

    fn giveFeedback(_: *ole32.IDropSource, _: u32) callconv(.winapi) HRESULT {
        return ole32.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

/// Escape cancels the drag, letting go of the left button drops.
pub fn continueDrag(escape: bool, key_state: u32) HRESULT {
    if (escape) return ole32.DRAGDROP_S_CANCEL;
    if (key_state & user32.MK_LBUTTON == 0) return ole32.DRAGDROP_S_DROP;
    return win32.foundation.S_OK;
}

/// Drags the folder out of the icon: runs the OLE drag loop until the button
/// is released. The data is the folder as the shell makes it (`CF_HDROP`
/// and the shell id list), so every file target accepts it.
pub fn startDrag(window: *Window) void {
    const alloc = window.app.core_app.alloc;
    const path = pwdOf(window) orelse return;
    const wide = widePath(alloc, path) orelse return;
    defer alloc.free(wide);

    const pidl = shell32.ILCreateFromPathW(wide.ptr) orelse return;
    defer shell32.ILFree(pidl);
    const parent = shell32.ILClone(pidl) orelse return;
    defer shell32.ILFree(parent);
    _ = shell32.ILRemoveLastID(parent);
    const children = [_]*anyopaque{shell32.ILFindLastID(pidl)};

    var out: ?*anyopaque = null;
    const hr = shell32.SHCreateDataObject(parent, 1, &children, null, &ole32.IID_IDataObject, &out);
    if (hr < 0) return;
    const data: *ole32.IDataObject = @ptrCast(@alignCast(out orelse return));
    defer com.release(data);

    var effect: u32 = 0;
    _ = ole32.DoDragDrop(data, &DropSource.object, ole32.DROPEFFECT_COPY | ole32.DROPEFFECT_LINK, &effect);
}

test "win32 proxy icon: only local drive paths without control characters" {
    try std.testing.expect(usable("C:\\Users\\me"));
    try std.testing.expect(usable("d:/work"));
    try std.testing.expect(!usable("\\\\server\\share"));
    try std.testing.expect(!usable("/c/Users/me"));
    try std.testing.expect(!usable("relative\\dir"));
    try std.testing.expect(!usable("C:"));
    try std.testing.expect(!usable("C:\\bad\x1b[0m"));
    try std.testing.expect(!usable("C:\\say \"hi\""));
    var long: [max_path + 3]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..3], "C:\\");
    try std.testing.expect(!usable(&long));
}

test "win32 proxy icon: folders from the directory up to the root" {
    var buf: [32][]const u8 = undefined;

    const deep = ancestors("C:\\Users\\me\\proj", &buf);
    try std.testing.expectEqual(@as(usize, 4), deep.len);
    try std.testing.expectEqualStrings("C:\\Users\\me\\proj", deep[0]);
    try std.testing.expectEqualStrings("C:\\Users\\me", deep[1]);
    try std.testing.expectEqualStrings("C:\\Users", deep[2]);
    try std.testing.expectEqualStrings("C:\\", deep[3]);

    // Mixed and trailing separators.
    const mixed = ancestors("d:/work//x/", &buf);
    try std.testing.expectEqual(@as(usize, 3), mixed.len);
    try std.testing.expectEqualStrings("d:/work//x", mixed[0]);
    try std.testing.expectEqualStrings("d:/work", mixed[1]);
    try std.testing.expectEqualStrings("d:/", mixed[2]);

    const root = ancestors("C:\\", &buf);
    try std.testing.expectEqual(@as(usize, 1), root.len);
    try std.testing.expectEqualStrings("C:\\", root[0]);

    const one = ancestors("C:\\a", &buf);
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings("C:\\a", one[0]);
}

test "win32 proxy icon: menu names" {
    try std.testing.expectEqualStrings("proj", folderName("C:\\Users\\me\\proj"));
    try std.testing.expectEqualStrings("C:\\", folderName("C:\\"));
    try std.testing.expectEqualStrings("me", folderName("C:/Users/me"));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("R&&D", menuLabel(&buf, "R&D"));
    // Cut inside a code point: the tail is dropped.
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqualStrings("a", menuLabel(&tiny, "a\u{0436}\u{0436}"));
}

test "win32 proxy icon: the drag ends on release or escape" {
    try std.testing.expectEqual(win32.foundation.S_OK, continueDrag(false, user32.MK_LBUTTON));
    try std.testing.expectEqual(ole32.DRAGDROP_S_DROP, continueDrag(false, 0));
    try std.testing.expectEqual(ole32.DRAGDROP_S_CANCEL, continueDrag(true, user32.MK_LBUTTON));
    try std.testing.expectEqual(ole32.DRAGDROP_S_CANCEL, continueDrag(true, 0));
}

test "win32 proxy icon: the static drag source answers IUnknown and IDropSource" {
    var out: ?*anyopaque = null;
    const unknown: *com.IUnknown = @ptrCast(&DropSource.object);
    try std.testing.expectEqual(win32.foundation.S_OK, DropSource.vtable.base.QueryInterface(unknown, &ole32.IID_IDropSource, &out));
    try std.testing.expect(out != null);
    try std.testing.expectEqual(ole32.E_NOINTERFACE, DropSource.vtable.base.QueryInterface(unknown, &ole32.IID_IDropTarget, &out));
    try std.testing.expect(out == null);
}

test "win32 proxy icon: icons are found by folder and dpi" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    state.slots[0] = .{ .path = try alloc.dupeSentinel(u8, "C:\\a", 0), .dpi = 96, .size = 16, .bitmap = null };
    state.slots[1] = .{ .path = try alloc.dupeSentinel(u8, "C:\\a", 0), .dpi = 144, .size = 24, .bitmap = null };
    try std.testing.expectEqual(@as(?usize, 0), state.find("C:\\a", 96));
    try std.testing.expectEqual(@as(?usize, 1), state.find("C:\\a", 144));
    try std.testing.expectEqual(@as(?usize, null), state.find("C:\\b", 96));
    try std.testing.expect(state.current() == null);
    state.shown = 1;
    try std.testing.expectEqual(@as(i32, 24), state.current().?.size);
}
