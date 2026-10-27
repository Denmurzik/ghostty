//! Files dropped from Explorer, pasted as shell-quoted paths. An OLE
//! `IDropTarget` is registered per top-level window; its callbacks only copy
//! data and post `WM_GHOSTTY_DROP`, and the core paste runs from that
//! message so the core is never re-entered from inside OLE.
//!
//! An elevated Ghostty receives no drops from a non-elevated Explorer
//! (UIPI blocks the drag); that is not worked around. As on macOS there is
//! no highlight: the copy cursor is the only feedback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const messages = @import("messages.zig");

const ole32 = win32.ole32;
const user32 = win32.user32;
const kernel32 = win32.kernel32;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;
const HRESULT = win32.foundation.HRESULT;
const POINT = win32.foundation.POINT;

const log = std.log.scoped(.win32_drop);

pub const WM_GHOSTTY_DROP = messages.WM_GHOSTTY_DROP;

pub const ShellKind = enum { msys, cygwin, wsl, pwsh, cmd };

/// The kind of shell a command starts, from the basename of its program.
/// Unknown shells and the default (no command) use cmd-style quoting.
/// A surface with no command yet (unresolved default) is classified as cmd; the
/// finalized config always holds the resolved `.direct` default shell.
pub fn shellKindFor(command: ?configpkg.Command) ShellKind {
    const cmd = command orelse return .cmd;
    const program: []const u8 = switch (cmd) {
        .direct => |argv| if (argv.len > 0) argv[0] else return .cmd,
        .shell => |s| programOf(s),
    };
    return shellKindOfProgram(program);
}

/// The program of a shell command line: a quoted first word, or up to the
/// first `.exe` (an unquoted path may contain spaces), else the first word.
fn programOf(line: []const u8) []const u8 {
    const s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse s.len;
        return s[1..end];
    }
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(s[i..][0..4], ".exe")) continue;
        const end = i + 4;
        if (end == s.len or s[end] == ' ' or s[end] == '\t') return s[0..end];
    }
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return s[0..end];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn shellKindOfProgram(program: []const u8) ShellKind {
    const base_start = if (std.mem.lastIndexOfAny(u8, program, "/\\")) |i| i + 1 else 0;
    var base = program[base_start..];
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) base = base[0 .. base.len - 4];

    const msys_shells = [_][]const u8{ "bash", "sh", "zsh", "fish", "dash", "ksh", "busybox" };
    for (msys_shells) |name| if (std.ascii.eqlIgnoreCase(base, name)) {
        // System32\bash.exe is the WSL launcher, not Git Bash.
        if (containsIgnoreCase(program, "\\windows\\system32\\") or
            containsIgnoreCase(program, "\\windows\\sysnative\\")) return .wsl;
        if (containsIgnoreCase(program, "\\cygwin")) return .cygwin;
        return .msys;
    };
    if (std.ascii.eqlIgnoreCase(base, "wsl")) return .wsl;
    if (std.ascii.eqlIgnoreCase(base, "pwsh") or std.ascii.eqlIgnoreCase(base, "powershell")) return .pwsh;
    return .cmd;
}

// -- Path conversion and quoting -------------------------------------------

fn isDrive(s: []const u8) bool {
    return s.len >= 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':';
}

/// `C:\a\b` -> `/c/a/b`; `\\?\` is dropped; UNC paths become `//srv/share/x`.
pub fn msysPath(alloc: Allocator, win: []const u8) ![]u8 {
    return convert(alloc, win, "/");
}

/// `C:\a\b` -> `/mnt/c/a/b`; UNC paths stay in msys form.
pub fn wslPath(alloc: Allocator, win: []const u8) ![]u8 {
    return convert(alloc, win, "/mnt/");
}

fn convert(alloc: Allocator, win: []const u8, drive_root: []const u8) ![]u8 {
    var s = win;
    var unc = false;
    if (std.mem.startsWith(u8, s, "\\\\?\\UNC\\")) {
        s = s[8..];
        unc = true;
    } else if (std.mem.startsWith(u8, s, "\\\\?\\")) {
        s = s[4..];
    } else if (std.mem.startsWith(u8, s, "\\\\")) {
        s = s[2..];
        unc = true;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (unc) {
        try out.appendSlice(alloc, "//");
    } else if (isDrive(s)) {
        try out.appendSlice(alloc, drive_root);
        try out.append(alloc, std.ascii.toLower(s[0]));
        s = s[2..];
    }
    for (s) |c| try out.append(alloc, if (c == '\\') '/' else c);
    return out.toOwnedSlice(alloc);
}

fn inSet(c: u8, comptime set: []const u8) bool {
    return std.mem.indexOfScalar(u8, set, c) != null;
}

fn plain(s: []const u8, comptime set: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or inSet(c, set))) return false;
    return true;
}

/// Space-joined paths quoted for `kind`, without a trailing space.
pub fn quote(alloc: Allocator, kind: ShellKind, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (paths, 0..) |path, i| {
        if (i > 0) try out.append(alloc, ' ');
        switch (kind) {
            .msys, .cygwin, .wsl => {
                const conv = switch (kind) {
                    .msys => try msysPath(alloc, path),
                    .cygwin => try convert(alloc, path, "/cygdrive/"),
                    else => try wslPath(alloc, path),
                };
                defer alloc.free(conv);
                if (plain(conv, "_./:@%+=,-")) {
                    try out.appendSlice(alloc, conv);
                } else {
                    try out.append(alloc, '\'');
                    for (conv) |c| {
                        if (c == '\'') try out.appendSlice(alloc, "'\\''") else try out.append(alloc, c);
                    }
                    try out.append(alloc, '\'');
                }
            },
            .pwsh => {
                if (plain(path, "_.\\:/-")) {
                    try out.appendSlice(alloc, path);
                } else {
                    try out.append(alloc, '\'');
                    var j: usize = 0;
                    while (j < path.len) {
                        // ' and the typographic quotes U+2018..U+201B (E2 80 98..9B).
                        const curly = path.len - j >= 3 and path[j] == 0xE2 and path[j + 1] == 0x80 and
                            path[j + 2] >= 0x98 and path[j + 2] <= 0x9B;
                        const n: usize = if (curly) 3 else 1;
                        const quoted = curly or path[j] == '\'';
                        try out.appendSlice(alloc, path[j .. j + n]);
                        if (quoted) try out.appendSlice(alloc, path[j .. j + n]);
                        j += n;
                    }
                    try out.append(alloc, '\'');
                }
            },
            .cmd => {
                var needs = path.len == 0;
                for (path) |c| {
                    if (c == ' ' or c >= 0x80 or inSet(c, "&()[]{}^=;!'+,`~")) needs = true;
                }
                if (needs) try out.append(alloc, '"');
                try out.appendSlice(alloc, path);
                if (needs) try out.append(alloc, '"');
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

// -- DROPFILES --------------------------------------------------------------

pub const ParseError = error{ InvalidDropFiles, NotWide } || Allocator.Error;

pub fn freePaths(alloc: Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

/// Parses a `DROPFILES` block into UTF-8 paths, whatever their length.
/// Unpaired surrogates become U+FFFD.
pub fn pathsFromDropFiles(alloc: Allocator, hdrop_bytes: []const u8) ParseError![][]u8 {
    const header = @sizeOf(win32.shell32.DROPFILES);
    if (hdrop_bytes.len < header) return error.InvalidDropFiles;
    const offset = std.mem.readInt(u32, hdrop_bytes[0..4], .little);
    const wide = std.mem.readInt(u32, hdrop_bytes[16..20], .little);
    if (offset < header or offset > hdrop_bytes.len) return error.InvalidDropFiles;
    if (wide == 0) return error.NotWide;

    const list = hdrop_bytes[offset..];
    const units = list.len / 2;

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    var i: usize = 0;
    while (i < units) {
        var end = i;
        while (end < units and unit(list, end) != 0) end += 1;
        if (end == i) break; // the empty entry that ends the list
        const path = try utf16ToUtf8Lossy(alloc, list[i * 2 .. end * 2]);
        errdefer alloc.free(path);
        try paths.append(alloc, path);
        i = end + 1;
    }
    return paths.toOwnedSlice(alloc);
}

fn unit(bytes: []const u8, index: usize) u16 {
    return std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little);
}

/// UTF-16LE bytes (possibly unaligned) to UTF-8.
fn utf16ToUtf8Lossy(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const n = bytes.len / 2;
    var i: usize = 0;
    var warned = false;
    while (i < n) {
        const u = unit(bytes, i);
        i += 1;
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF and i < n and unit(bytes, i) >= 0xDC00 and unit(bytes, i) <= 0xDFFF) {
            cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (unit(bytes, i) - 0xDC00);
            i += 1;
        } else if (u >= 0xD800 and u <= 0xDFFF) {
            cp = 0xFFFD;
            if (!warned) log.warn("unpaired surrogate in a dropped path", .{});
            warned = true;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..len]);
    }
    return out.toOwnedSlice(alloc);
}

/// Whether a dropped path is a plausible Windows path. The text is pasted
/// without the unsafe-paste prompt and a drag source can send any string, so
/// a path with a control character (CR runs a command) or one of `"<>|*?`
/// (breaks quoting, redirects) is refused. A `\\?\` prefix may carry `?`.
pub fn pathIsSafe(path: []const u8) bool {
    var rest = path;
    if (std.mem.startsWith(u8, rest, "\\\\?\\")) rest = rest[4..];
    for (rest) |c| {
        if (c < 0x20 or c == 0x7F) return false;
        if (std.mem.indexOfScalar(u8, "\"<>|*?", c) != null) return false;
    }
    return true;
}

// -- The drop target ----------------------------------------------------------

const gpa = std.heap.smp_allocator;

/// Posted by `Drop`; owned by the message handler.
const Payload = struct {
    id: u32,
    window: *Window,
    surface_id: u32,
    text: []u8,
};

/// Drops waiting for their `WM_GHOSTTY_DROP` (UI thread only). The message
/// carries just an id: any process of the same integrity level can post
/// `WM_APP + 10`, so an unknown id is ignored and no pointer is trusted.
var pending: std.ArrayList(Payload) = .empty;
var next_payload_id: u32 = 1;

const Target = struct {
    /// First, as COM requires.
    iface: ole32.IDropTarget,
    refs: std.atomic.Value(u32) = .init(1),
    /// Null once the window revoked the registration.
    window: ?*Window,
    /// Whether the data object being dragged offers `CF_HDROP`.
    has_files: bool = false,

    const vtable: ole32.IDropTarget.VTable = .{
        .base = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .DragEnter = dragEnter,
        .DragOver = dragOver,
        .DragLeave = dragLeave,
        .Drop = onDrop,
    };

    fn from(this: *ole32.IDropTarget) *Target {
        return @fieldParentPtr("iface", this);
    }

    fn queryInterface(this: *win32.com.IUnknown, riid: *const win32.foundation.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(riid.*, ole32.IID_IUnknown) or std.meta.eql(riid.*, ole32.IID_IDropTarget)) {
            out.* = this;
            _ = addRef(this);
            return win32.foundation.S_OK;
        }
        out.* = null;
        return ole32.E_NOINTERFACE;
    }

    fn addRef(this: *win32.com.IUnknown) callconv(.winapi) u32 {
        const self = from(@ptrCast(this));
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(this: *win32.com.IUnknown) callconv(.winapi) u32 {
        const self = from(@ptrCast(this));
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) gpa.destroy(self);
        return left;
    }

    fn effectFor(self: *Target, pt: POINT, allowed: u32) u32 {
        const window = self.window orelse return ole32.DROPEFFECT_NONE;
        if (!self.has_files or allowed & ole32.DROPEFFECT_COPY == 0) return ole32.DROPEFFECT_NONE;
        if (surfaceAt(window, pt) == null) return ole32.DROPEFFECT_NONE;
        return ole32.DROPEFFECT_COPY;
    }

    fn dragEnter(this: *ole32.IDropTarget, data: ?*ole32.IDataObject, _: u32, pt: POINT, effect: *u32) callconv(.winapi) HRESULT {
        const self = from(this);
        self.has_files = if (data) |d| d.queryGetData(&hdropFormat()) == win32.foundation.S_OK else false;
        effect.* = self.effectFor(pt, effect.*);
        return win32.foundation.S_OK;
    }

    fn dragOver(this: *ole32.IDropTarget, _: u32, pt: POINT, effect: *u32) callconv(.winapi) HRESULT {
        const self = from(this);
        effect.* = self.effectFor(pt, effect.*);
        return win32.foundation.S_OK;
    }

    fn dragLeave(this: *ole32.IDropTarget) callconv(.winapi) HRESULT {
        from(this).has_files = false;
        return win32.foundation.S_OK;
    }

    fn onDrop(this: *ole32.IDropTarget, data: ?*ole32.IDataObject, _: u32, pt: POINT, effect: *u32) callconv(.winapi) HRESULT {
        const self = from(this);
        self.has_files = false;
        effect.* = ole32.DROPEFFECT_NONE;

        const window = self.window orelse return win32.foundation.S_OK;
        const surface = surfaceAt(window, pt) orelse return win32.foundation.S_OK;
        const obj = data orelse return win32.foundation.S_OK;

        const text = textFromData(obj, surface.shell_kind) catch |err| {
            log.warn("unable to read the dropped files err={}", .{err});
            return win32.foundation.S_OK;
        };
        const id = next_payload_id;
        next_payload_id +%= 1;
        if (next_payload_id == 0) next_payload_id = 1;
        pending.append(gpa, .{ .id = id, .window = window, .surface_id = surface.id, .text = text }) catch {
            gpa.free(text);
            return win32.foundation.S_OK;
        };
        if (user32.PostMessageW(window.hwnd, WM_GHOSTTY_DROP, 0, @intCast(id)) == 0) {
            log.warn("unable to post the drop err={}", .{kernel32.GetLastError()});
            const dropped = pending.pop().?;
            gpa.free(dropped.text);
            return win32.foundation.S_OK;
        }
        effect.* = ole32.DROPEFFECT_COPY;
        return win32.foundation.S_OK;
    }
};

fn hdropFormat() ole32.FORMATETC {
    return .{ .cfFormat = ole32.CF_HDROP };
}

/// Copies the `CF_HDROP` paths out of `data` and quotes them for `kind`.
fn textFromData(data: *ole32.IDataObject, kind: ShellKind) ![]u8 {
    var medium: ole32.STGMEDIUM = .{};
    try win32.foundation.check(data.getData(&hdropFormat(), &medium));
    defer ole32.ReleaseStgMedium(&medium);
    if (medium.tymed != ole32.TYMED_HGLOBAL) return error.UnexpectedMedium;
    const hglobal = medium.hGlobal orelse return error.UnexpectedMedium;

    const size = kernel32.GlobalSize(hglobal);
    const ptr: [*]const u8 = @ptrCast(kernel32.GlobalLock(hglobal) orelse return error.LockFailed);
    defer _ = kernel32.GlobalUnlock(hglobal);

    const paths = try pathsFromDropFiles(gpa, ptr[0..size]);
    defer freePaths(gpa, paths);
    for (paths) |p| if (!pathIsSafe(p)) {
        log.warn("refusing a drop with a path that has control or shell characters", .{});
        return error.UnsafePath;
    };
    const views: []const []const u8 = @ptrCast(paths);
    return quote(gpa, kind, views);
}

/// The visible surface of `window` under the screen point.
fn surfaceAt(window: *Window, pt: POINT) ?*Surface {
    for (window.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            const s = entry.view;
            if (user32.IsWindowVisible(s.hwnd) == 0) continue;
            var rc: win32.foundation.RECT = undefined;
            if (user32.GetWindowRect(s.hwnd, &rc) == 0) continue;
            if (pt.x >= rc.left and pt.x < rc.right and pt.y >= rc.top and pt.y < rc.bottom) return s;
        }
    }
    return null;
}

var targets: std.ArrayList(*Target) = .empty;

/// Registers `window` as a drop target (UI thread, OLE initialised).
pub fn register(window: *Window) void {
    const target = gpa.create(Target) catch return;
    target.* = .{ .iface = .{ .vtable = &Target.vtable }, .window = window };
    targets.append(gpa, target) catch {
        gpa.destroy(target);
        return;
    };
    const hr = ole32.RegisterDragDrop(window.hwnd, &target.iface);
    if (hr < 0) {
        log.warn("RegisterDragDrop failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        _ = targets.pop();
        gpa.destroy(target);
    }
}

pub fn revoke(window: *Window) void {
    // Drops posted to this window will never be delivered.
    var i: usize = 0;
    while (i < pending.items.len) {
        if (pending.items[i].window == window) {
            gpa.free(pending.items[i].text);
            _ = pending.swapRemove(i);
        } else i += 1;
    }
    for (targets.items, 0..) |target, ti| {
        if (target.window != window) continue;
        target.window = null;
        _ = ole32.RevokeDragDrop(window.hwnd);
        _ = targets.swapRemove(ti);
        // The registration's reference; OLE may still hold its own.
        _ = Target.release(@ptrCast(&target.iface));
        return;
    }
}

/// `WM_GHOSTTY_DROP`: lparam is the id of a pending drop.
pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    _ = wparam;
    if (msg != WM_GHOSTTY_DROP) return null;
    const id = std.math.cast(u32, lparam) orelse return 0;
    const index = for (pending.items, 0..) |p, i| {
        if (p.id == id and p.window == window) break i;
    } else return 0; // not ours (a foreign post) or already gone
    const payload = pending.swapRemove(index);
    defer gpa.free(payload.text);

    // The surface may be gone by now: drop silently.
    const surface = window.findSurface(payload.surface_id) orelse return 0;
    _ = user32.SetForegroundWindow(window.hwnd);
    _ = user32.SetFocus(surface.hwnd);
    surface.core_surface.textCallback(payload.text) catch |err|
        log.warn("unable to paste the dropped paths err={}", .{err});
    return 0;
}

// -- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn expectQuoted(kind: ShellKind, paths: []const []const u8, expected: []const u8) !void {
    const got = try quote(testing.allocator, kind, paths);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "win32 drop: shell kind from the command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ShellKind }{
        .{ "C:\\Program Files\\Git\\bin\\bash.exe --login -i", .msys },
        .{ "pwsh.exe -NoLogo", .pwsh },
        .{ "C:\\WINDOWS\\system32\\cmd.exe", .cmd },
        .{ "direct:wsl.exe ~", .wsl },
        .{ "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo", .pwsh },
        .{ "/usr/bin/ZSH", .msys },
        .{ "foo.exe", .cmd },
    };
    for (cases) |case| {
        var cmd: configpkg.Command = undefined;
        try cmd.parseCLI(a, case[0]);
        try testing.expectEqual(case[1], shellKindFor(cmd));
    }
    try testing.expectEqual(ShellKind.cmd, shellKindFor(null));
}

test "win32 drop: shell kind of the resolved default shell" {
    // The default shell is resolved to a `.direct` argv with an absolute path.
    const git: configpkg.Command = .{ .direct = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" } };
    const git_user: configpkg.Command = .{ .direct = &.{ "C:\\Users\\a b\\AppData\\Local\\Programs\\Git\\bin\\bash.exe", "--login", "-i" } };
    const pwsh: configpkg.Command = .{ .direct = &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" } };
    const cmd: configpkg.Command = .{ .direct = &.{"C:\\Windows\\System32\\cmd.exe"} };
    const wsl: configpkg.Command = .{ .direct = &.{ "C:\\Windows\\System32\\wsl.exe", "~" } };
    try testing.expectEqual(ShellKind.msys, shellKindFor(git));
    try testing.expectEqual(ShellKind.msys, shellKindFor(git_user));
    try testing.expectEqual(ShellKind.pwsh, shellKindFor(pwsh));
    try testing.expectEqual(ShellKind.cmd, shellKindFor(cmd));
    try testing.expectEqual(ShellKind.wsl, shellKindFor(wsl));
}

test "win32 drop: msys and wsl paths and quoting" {
    try expectQuoted(.msys, &.{"C:\\a b\\c.txt"}, "'/c/a b/c.txt'");
    try expectQuoted(.msys, &.{"D:\\x\\y.txt"}, "/d/x/y.txt");
    try expectQuoted(.msys, &.{"\\\\?\\C:\\long"}, "/c/long");
    try expectQuoted(.msys, &.{"\\\\srv\\share\\f"}, "//srv/share/f");
    try expectQuoted(.msys, &.{"\\\\?\\UNC\\srv\\share\\x"}, "//srv/share/x");
    try expectQuoted(.msys, &.{"C:\\it's.txt"}, "'/c/it'\\''s.txt'");
    try expectQuoted(.wsl, &.{"C:\\a b"}, "'/mnt/c/a b'");
    try expectQuoted(.wsl, &.{"C:\\x\\y"}, "/mnt/c/x/y");
    try expectQuoted(.wsl, &.{"\\\\srv\\share\\x"}, "//srv/share/x");
    try expectQuoted(.msys, &.{ "C:\\a", "C:\\b c" }, "/c/a '/c/b c'");
    try expectQuoted(.msys, &.{"C:\\Рабочая\\ф.txt"}, "'/c/Рабочая/ф.txt'");
    try expectQuoted(.msys, &.{"C:\\a&b %x !y"}, "'/c/a&b %x !y'");
}

test "win32 drop: pwsh quoting" {
    try expectQuoted(.pwsh, &.{"C:\\a b"}, "'C:\\a b'");
    try expectQuoted(.pwsh, &.{"O'Brien"}, "'O''Brien'");
    try expectQuoted(.pwsh, &.{"a\u{2019}b"}, "'a\u{2019}\u{2019}b'");
    try expectQuoted(.pwsh, &.{"C:\\plain\\x.txt"}, "C:\\plain\\x.txt");
    try expectQuoted(.pwsh, &.{"$x"}, "'$x'");
    try expectQuoted(.pwsh, &.{ "C:\\a", "C:\\b c" }, "C:\\a 'C:\\b c'");
}

test "win32 drop: cmd quoting" {
    try expectQuoted(.cmd, &.{"C:\\a b"}, "\"C:\\a b\"");
    try expectQuoted(.cmd, &.{"a&b"}, "\"a&b\"");
    try expectQuoted(.cmd, &.{"C:\\plain\\x.txt"}, "C:\\plain\\x.txt");
    try expectQuoted(.cmd, &.{"Рабочая\\ф.txt"}, "\"Рабочая\\ф.txt\"");
    try expectQuoted(.cmd, &.{"100%"}, "100%");
}

fn buildDropFiles(a: Allocator, wide: u32, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var header: [20]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 20, .little);
    std.mem.writeInt(u32, header[16..20], wide, .little);
    try out.appendSlice(a, &header);
    for (paths) |p| {
        const w = try std.unicode.utf8ToUtf16LeAlloc(a, p);
        defer a.free(w);
        for (w) |u| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
        try out.appendSlice(a, &.{ 0, 0 });
    }
    try out.appendSlice(a, &.{ 0, 0 });
    return out.toOwnedSlice(a);
}

test "win32 drop: DROPFILES parse" {
    const a = testing.allocator;
    const filler: [296]u8 = @splat('d');
    const long = "C:\\" ++ filler ++ ".t";
    const want = [_][]const u8{ "C:\\Рабочая папка\\файл.txt", long, "\\\\?\\C:\\long", "\\\\srv\\share\\x y", "C:\\emoji \u{1F600}.txt" };
    const block = try buildDropFiles(a, 1, &want);
    defer a.free(block);
    const paths = try pathsFromDropFiles(a, block);
    defer freePaths(a, paths);
    try testing.expectEqual(want.len, paths.len);
    for (want, paths) |w, p| try testing.expectEqualStrings(w, p);

    const ansi = try buildDropFiles(a, 0, &.{"C:\\a"});
    defer a.free(ansi);
    try testing.expectError(error.NotWide, pathsFromDropFiles(a, ansi));
    try testing.expectError(error.InvalidDropFiles, pathsFromDropFiles(a, "short"));
}

test "win32 drop: unpaired surrogate becomes U+FFFD" {
    const a = testing.allocator;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(a);
    var header: [20]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 20, .little);
    std.mem.writeInt(u32, header[16..20], 1, .little);
    try block.appendSlice(a, &header);
    // "a", lone high surrogate, "b", lone low surrogate, NUL, end of list.
    for ([_]u16{ 'a', 0xD800, 'b', 0xDC00, 0, 0 }) |u| try block.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
    const paths = try pathsFromDropFiles(a, block.items);
    defer freePaths(a, paths);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", paths[0]);
}

test "win32 drop: IDropTarget and IDataObject slot counts" {
    try testing.expectEqual(7 * @sizeOf(usize), @sizeOf(ole32.IDropTarget.VTable));
    try testing.expectEqual(12 * @sizeOf(usize), @sizeOf(ole32.IDataObject.VTable));
}

test "win32 drop: unsafe paths are refused" {
    try testing.expect(!pathIsSafe("x\r calc\r"));
    try testing.expect(!pathIsSafe("a\nb"));
    try testing.expect(!pathIsSafe("a\x00b"));
    try testing.expect(!pathIsSafe("a\x7Fb"));
    try testing.expect(!pathIsSafe("C:\\a\"&calc&\"b"));
    try testing.expect(!pathIsSafe("C:\\a|b"));
    try testing.expect(!pathIsSafe("C:\\a<b"));
    try testing.expect(!pathIsSafe("C:\\a>b"));
    try testing.expect(!pathIsSafe("C:\\a*b"));
    try testing.expect(!pathIsSafe("C:\\a?b"));
    try testing.expect(!pathIsSafe("\\\\?\\C:\\a?b"));
}

test "win32 drop: ordinary paths are accepted" {
    try testing.expect(pathIsSafe("C:\\Рабочая папка\\файл.txt"));
    try testing.expect(pathIsSafe("C:\\it's & (x) 100% !.txt"));
    try testing.expect(pathIsSafe("\\\\?\\C:\\long\\path"));
    try testing.expect(pathIsSafe("\\\\?\\UNC\\srv\\share\\x"));
    try testing.expect(pathIsSafe("\\\\srv\\share\\a b"));
}

test "win32 drop: System32 bash is WSL, Cygwin bash has /cygdrive" {
    const wsl_bash: configpkg.Command = .{ .direct = &.{"C:\\Windows\\System32\\bash.exe"} };
    const cyg: configpkg.Command = .{ .direct = &.{"C:\\cygwin64\\bin\\bash.exe"} };
    try testing.expectEqual(ShellKind.wsl, shellKindFor(wsl_bash));
    try testing.expectEqual(ShellKind.cygwin, shellKindFor(cyg));
    try expectQuoted(.cygwin, &.{"C:\\a b"}, "'/cygdrive/c/a b'");
}
