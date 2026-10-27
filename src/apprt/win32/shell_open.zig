//! Decides what a link may do and hands it to the shell off the UI thread.
//!
//! Links come from terminal output, which any program controls. `validate`
//! turns the text into a verdict without touching the machine (everything
//! it needs to know about files comes in through `Env`); the worker thread
//! asks the real file system, then acts on the verdict. Nothing here runs
//! a program: local files that Windows would execute are only selected in
//! Explorer, web and mail URLs are opened, other schemes need the user's
//! consent first.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const hooks = @import("hooks.zig");
const ops = @import("ipc/ops.zig");
const link_policy = @import("link_policy.zig");
const messages = @import("messages.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_shell_open);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const max_queue = 8;
const max_recorded = 8;
const max_record_url = 256;

/// `GetDriveTypeW` results that are local to the machine.
const drive_removable = 2;
const drive_fixed = 3;

/// `GetLastError` after `ShellExecuteExW` found no program for the file.
const error_no_association = 1155;

pub const Verdict = union(enum) {
    /// Hand this URL or local path to the shell's "open" verb.
    open: []const u8,
    /// Select this local path in Explorer.
    reveal: []const u8,
    /// Ask the user first; the string is the URL.
    confirm: []const u8,
    /// Do nothing; the string says why (a literal).
    refuse: []const u8,

    /// Frees what `validate` allocated.
    pub fn deinit(self: Verdict, alloc: Allocator) void {
        switch (self) {
            .open, .reveal, .confirm => |s| alloc.free(s),
            .refuse => {},
        }
    }
};

/// What `validate` needs to know about the machine. Injected so that it
/// stays pure and table-testable. Paths are UTF-16 without a terminator.
pub const Env = struct {
    /// The working directory the surface reported (a drive path or `/c/x`).
    pwd: ?[]const u8,
    userprofile: []const u8,
    exists: *const fn ([]const u16) bool,
    /// Given the root (`C:\`); `GetDriveTypeW`.
    drive_type: *const fn ([]const u16) u32,
    /// `GetFullPathNameW`: resolves `.` and `..`.
    full_path: *const fn (Allocator, []const u16) anyerror![]u16,
    /// Given an extension with its dot; `AssocIsDangerous`.
    is_dangerous: *const fn ([]const u16) bool,
    /// `GetLongPathNameW`: expands 8.3 names; fails for a file that is not there.
    long_path: *const fn (Allocator, []const u16) anyerror![]u16,
    /// The final path of an existing file after links, junctions and
    /// subst drives (`GetFinalPathNameByHandleW`); fails when it cannot say.
    final_path: *const fn (Allocator, []const u16) anyerror![]u16,
};

/// Extensions that run code, or are handled by something that does, when
/// the shell opens them. Compared case-insensitively. `Env.is_dangerous`
/// covers what Windows adds to its own list.
const dangerous_extensions = [_][]const u8{
    ".exe",             ".com",                ".scr",               ".pif",        ".bat",        ".cmd",
    ".ps1",             ".psm1",               ".psd1",              ".ps1xml",     ".vbs",        ".vbe",
    ".js",              ".jse",                ".wsf",               ".wsh",        ".wsc",        ".hta",
    ".msi",             ".msp",                ".mst",               ".dll",        ".sys",        ".cpl",
    ".reg",             ".lnk",                ".url",               ".jar",        ".msc",        ".gadget",
    ".application",     ".appx",               ".msix",              ".appxbundle", ".msixbundle", ".cab",
    ".chm",             ".inf",                ".scf",               ".sct",        ".xll",        ".docm",
    ".dotm",            ".xlsm",               ".xltm",              ".pptm",       ".potm",       ".ppam",
    ".library-ms",      ".searchconnector-ms", ".settingcontent-ms", ".diagcab",    ".appref-ms",  ".website",
    ".theme",           ".themepack",          ".iso",               ".img",        ".vhd",        ".vhdx",
    ".py",              ".pyw",                ".pyz",               ".pyzw",       ".sh",         ".bash",
    ".rb",              ".pl",                 ".jnlp",              ".rdp",        ".wsb",        ".appinstaller",
    ".ms-appinstaller", ".mht",                ".mhtml",             ".vb",         ".ws",         ".shb",
    ".shs",             ".hlp",                ".cer",               ".crt",        ".ppkg",
};

pub fn isDangerousExtension(ext: []const u8) bool {
    // Monad shell scripts: .msh, .msh1, .msh2, .mshxml, ...
    if (ext.len >= 4 and std.ascii.eqlIgnoreCase(ext[0..4], ".msh")) return true;
    for (dangerous_extensions) |d| {
        if (std.ascii.eqlIgnoreCase(ext, d)) return true;
    }
    return false;
}

/// Pure (apart from `env`). Verdict slices are allocated with `alloc`;
/// free them with `Verdict.deinit`.
pub fn validate(alloc: Allocator, kind: apprt.action.OpenUrl.Kind, url: []const u8, env: Env) !Verdict {
    if (url.len == 0) return .{ .refuse = "empty" };

    // Paths Ghostty wrote itself (screen and scrollback files): nothing to
    // check but the network.
    if (link_policy.isTrusted(kind)) {
        if (url.len >= 2 and link_policy.isSlash(url[0]) and link_policy.isSlash(url[1])) {
            return .{ .refuse = "UNC or device path" };
        }
        return .{ .open = try alloc.dupe(u8, url) };
    }

    if (url.len > link_policy.max_len) return .{ .refuse = "too long" };
    if (hasForbidden(url)) return .{ .refuse = "control, quote or bidi character" };

    if (link_policy.isDriveAbsolute(url)) return pathVerdict(alloc, url, env);

    // `main.zig:12` is a path with a position, not a scheme.
    if (link_policy.schemeEnd(url)) |colon| if (std.mem.indexOfScalar(u8, url[0..colon], '.') == null) {
        const scheme = url[0..colon];
        const rest = url[colon + 1 ..];

        if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
            if (!std.mem.startsWith(u8, rest, "//") or rest.len == 2 or rest[2] == '/') {
                return .{ .refuse = "web URL without host" };
            }
            if (!link_policy.isPlainUrl(url)) return .{ .refuse = "character not allowed in URL" };
            return .{ .open = try alloc.dupe(u8, url) };
        }
        if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
            if (rest.len == 0) return .{ .refuse = "empty mailto" };
            if (!link_policy.isPlainUrl(url)) return .{ .refuse = "character not allowed in URL" };
            var buf: [link_policy.max_len]u8 = undefined;
            if (link_policy.hasAttachment(&buf, rest)) return .{ .refuse = "mailto attachment" };
            return .{ .open = try alloc.dupe(u8, url) };
        }
        if (std.ascii.eqlIgnoreCase(scheme, "file")) return fileVerdict(alloc, rest, env);
        // Known exploit vectors: no question is worth asking.
        if (std.ascii.eqlIgnoreCase(scheme, "ms-msdt") or std.ascii.eqlIgnoreCase(scheme, "search-ms")) {
            return .{ .refuse = "scheme is an exploit vector" };
        }
        return .{ .confirm = try alloc.dupe(u8, url) };
    };

    return pathVerdict(alloc, url, env);
}

/// Control characters (C0, DEL and C1), quotes and bidi controls.
pub fn hasForbidden(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f or c == '"') return true;
    }
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == 0xC2 and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) return true;
    }
    return link_policy.hasBidiControl(s);
}

/// `file:///C:/x`, `file://localhost/C:/x`. Decoded once.
fn fileVerdict(alloc: Allocator, rest: []const u8, env: Env) !Verdict {
    if (!std.mem.startsWith(u8, rest, "//")) return .{ .refuse = "file URL without authority" };
    const after = rest[2..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return .{ .refuse = "file URL without path" };
    const host = after[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) {
        return .{ .refuse = "file URL on a network host" };
    }
    const encoded = after[slash + 1 ..];

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        var c = encoded[i];
        if (c == '%') {
            if (i + 2 >= encoded.len) return .{ .refuse = "bad percent escape" };
            c = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return .{ .refuse = "bad percent escape" };
            i += 2;
        }
        try decoded.append(a, c);
    }
    // Decoding can produce what the raw check rejected.
    if (hasForbidden(decoded.items)) return .{ .refuse = "control, quote or bidi character" };
    if (!link_policy.isDriveAbsolute(decoded.items)) return .{ .refuse = "file URL is not a local drive path" };
    return pathVerdict(alloc, decoded.items, env);
}

const Abs = union(enum) {
    path: []u8,
    refuse: []const u8,
};

/// `C:\x`, `C:/x` or the Git Bash form `/c/x` as a backslash-free copy;
/// null for anything else.
fn anchor(alloc: Allocator, p: []const u8) !?[]u8 {
    if (link_policy.isDriveAbsolute(p)) return try alloc.dupe(u8, p);
    if (p.len >= 2 and p[0] == '/' and std.ascii.isAlphabetic(p[1]) and (p.len == 2 or p[2] == '/')) {
        const tail = if (p.len > 3) p[3..] else "";
        return try std.mem.concat(alloc, u8, &.{ &.{ std.ascii.toUpper(p[1]), ':', '\\' }, tail });
    }
    return null;
}

fn absolute(alloc: Allocator, raw: []const u8, env: Env) !Abs {
    if (raw[0] == '~' and (raw.len == 1 or link_policy.isSlash(raw[1]))) {
        if (env.userprofile.len == 0) return .{ .refuse = "no home directory" };
        return .{ .path = try std.mem.concat(alloc, u8, &.{ env.userprofile, raw[1..] }) };
    }
    if (try anchor(alloc, raw)) |p| return .{ .path = p };
    if (link_policy.isSlash(raw[0])) return .{ .refuse = "path without a drive" };
    if (raw.len >= 2 and raw[1] == ':') return .{ .refuse = "drive-relative path" };

    const pwd = env.pwd orelse return .{ .refuse = "relative path without a working directory" };
    const base = (try anchor(alloc, pwd)) orelse return .{ .refuse = "working directory is not a drive path" };
    const sep: []const u8 = if (base[base.len - 1] == '\\' or base[base.len - 1] == '/') "" else "\\";
    return .{ .path = try std.mem.concat(alloc, u8, &.{ base, sep, raw }) };
}

fn toWide(alloc: Allocator, s: []const u8) ?[]u16 {
    return std.unicode.utf8ToUtf16LeAlloc(alloc, s) catch null;
}

/// `path:12` and `path:12:5` (compiler and grep output) are the file at a
/// position; the position is dropped.
fn stripPosition(raw: []const u8) []const u8 {
    var p = raw;
    for (0..2) |_| {
        const colon = std.mem.lastIndexOfScalar(u8, p, ':') orelse return p;
        if (colon < 2 or colon + 1 == p.len) return p;
        for (p[colon + 1 ..]) |c| if (!std.ascii.isDigit(c)) return p;
        p = p[0..colon];
    }
    return p;
}

/// The path rules of the policy: no network, devices or streams, only
/// local drives, and programs are revealed, never run.
fn pathVerdict(alloc: Allocator, raw_with_position: []const u8, env: Env) !Verdict {
    const raw = stripPosition(raw_with_position);
    if (raw.len >= 2 and link_policy.isSlash(raw[0]) and link_policy.isSlash(raw[1])) {
        return .{ .refuse = "UNC or device path" };
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const path = switch (try absolute(a, raw, env)) {
        .path => |p| p,
        .refuse => |why| return .{ .refuse = why },
    };
    for (path) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    if (unsafeChars(path)) return .{ .refuse = "unsafe character in path" };

    // Windows resolves `.` and `..`; judge the result.
    const wide_in = toWide(a, path) orelse return .{ .refuse = "path is not valid text" };
    const wide_full = env.full_path(a, wide_in) catch return .{ .refuse = "path cannot be resolved" };
    const full = std.unicode.utf16LeToUtf8Alloc(a, wide_full) catch return .{ .refuse = "path is not valid text" };
    return judge(alloc, a, full, env, true);
}

/// A name with `~` and a digit may be an 8.3 short name, which the shell
/// judges by the long name behind it.
fn hasShortName(part: []const u8) bool {
    for (part, 0..) |c, i| {
        if (c == '~' and i + 1 < part.len and std.ascii.isDigit(part[i + 1])) return true;
    }
    return false;
}

/// Checks a resolved absolute path. With `resolve` links are followed once
/// and their target judged instead.
fn judge(alloc: Allocator, a: Allocator, path_in: []const u8, env: Env, resolve: bool) !Verdict {
    var path = path_in;
    if (!link_policy.isDriveAbsolute(path)) return .{ .refuse = "UNC or device path" };
    if (unsafeChars(path) or hasForbidden(path)) return .{ .refuse = "unsafe character in path" };

    // Trailing dots and spaces are dropped by Windows when it opens the
    // name; look at what it will see.
    path = trimName(path);

    // Windows judges a short name by the long one: expand it first.
    var long_failed = false;
    const wide_short = toWide(a, path) orelse return .{ .refuse = "path is not valid text" };
    if (env.long_path(a, wide_short)) |wide_long| {
        const long = std.unicode.utf16LeToUtf8Alloc(a, wide_long) catch return .{ .refuse = "path is not valid text" };
        if (!link_policy.isDriveAbsolute(long) or unsafeChars(long) or hasForbidden(long)) {
            return .{ .refuse = "unsafe character in path" };
        }
        path = trimName(long);
    } else |_| long_failed = true;

    var short_name = false;
    var parts = std.mem.splitScalar(u8, path[3..], '\\');
    var last: []const u8 = "";
    while (parts.next()) |part| {
        if (link_policy.isDeviceName(part)) return .{ .refuse = "reserved device name" };
        if (hasShortName(part)) short_name = true;
        last = part;
    }

    const root = [3]u16{ path[0], ':', '\\' };
    const drive = env.drive_type(&root);
    if (drive != drive_fixed and drive != drive_removable) return .{ .refuse = "drive is not local" };

    const ext = if (std.mem.lastIndexOfScalar(u8, last, '.')) |dot| last[dot..] else "";
    // `name.{CLSID}` is a shell namespace folder, not a directory.
    if (ext.len > 1 and ext[1] == '{') return .{ .refuse = "shell namespace folder" };

    var dangerous = short_name or isDangerousExtension(ext);
    if (!dangerous and ext.len > 0) {
        const wide_ext = toWide(a, ext) orelse return .{ .refuse = "path is not valid text" };
        dangerous = env.is_dangerous(wide_ext);
    }
    if (dangerous) return .{ .reveal = try alloc.dupe(u8, path) };

    const wide_path = toWide(a, path) orelse return .{ .refuse = "path is not valid text" };
    if (!env.exists(wide_path)) return .{ .refuse = "path does not exist" };
    // The file is there but its long name is not known: do not guess.
    if (long_failed) return .{ .reveal = try alloc.dupe(u8, path) };

    if (resolve) {
        if (env.final_path(a, wide_path)) |wide_final| {
            const final = std.unicode.utf16LeToUtf8Alloc(a, wide_final) catch return .{ .refuse = "path is not valid text" };
            if (!std.ascii.eqlIgnoreCase(final, path)) return judge(alloc, a, final, env, false);
        } else |_| {}
    }
    return .{ .open = try alloc.dupe(u8, path) };
}

fn trimName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 3 and (path[end - 1] == '\\' or path[end - 1] == '.' or path[end - 1] == ' ')) end -= 1;
    return path[0..end];
}

/// A colon past the drive (alternate stream, device syntax) or a wildcard.
fn unsafeChars(path: []const u8) bool {
    if (path.len < 2) return true;
    for (path[2..]) |c| {
        switch (c) {
            ':', '*', '?', '<', '>', '|', '"' => return true,
            else => {},
        }
    }
    return false;
}

// -- The real machine -----------------------------------------------------------------

fn toZ(buf: *[2100:0]u16, s: []const u16) ?[*:0]const u16 {
    if (s.len > 2099) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf;
}

fn realExists(path: []const u16) bool {
    var buf: [2100:0]u16 = undefined;
    const z = toZ(&buf, path) orelse return false;
    return win32.kernel32.GetFileAttributesW(z) != win32.kernel32.INVALID_FILE_ATTRIBUTES;
}

fn realDriveType(root: []const u16) u32 {
    var buf: [2100:0]u16 = undefined;
    const z = toZ(&buf, root) orelse return 0;
    return win32.kernel32.GetDriveTypeW(z);
}

fn realFullPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
    const z = try alloc.allocSentinel(u16, path.len, 0);
    @memcpy(z, path);
    defer alloc.free(z);
    const need = win32.kernel32.GetFullPathNameW(z.ptr, 0, null, null);
    if (need == 0) return error.FullPathFailed;
    const buf = try alloc.alloc(u16, need);
    defer alloc.free(buf);
    const got = win32.kernel32.GetFullPathNameW(z.ptr, need, buf.ptr, null);
    if (got == 0 or got >= need) return error.FullPathFailed;
    return try alloc.dupe(u16, buf[0..got]);
}

fn realLongPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
    const z = try alloc.allocSentinel(u16, path.len, 0);
    @memcpy(z, path);
    defer alloc.free(z);
    const need = win32.kernel32.GetLongPathNameW(z.ptr, null, 0);
    if (need == 0) return error.LongPathFailed;
    const buf = try alloc.alloc(u16, need);
    defer alloc.free(buf);
    const got = win32.kernel32.GetLongPathNameW(z.ptr, buf.ptr, need);
    if (got == 0 or got >= need) return error.LongPathFailed;
    return try alloc.dupe(u16, buf[0..got]);
}

/// Opens the file without touching its contents and asks where it really is.
fn realFinalPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
    var zbuf: [2100:0]u16 = undefined;
    const z = toZ(&zbuf, path) orelse return error.TooLong;
    const k = win32.kernel32;
    const file = k.CreateFileW(
        z,
        0,
        k.FILE_SHARE_READ | k.FILE_SHARE_WRITE | k.FILE_SHARE_DELETE,
        null,
        k.OPEN_EXISTING,
        k.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (file == k.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = k.CloseHandle(file);

    const flags = k.VOLUME_NAME_DOS | k.FILE_NAME_NORMALIZED;
    const need = k.GetFinalPathNameByHandleW(file, null, 0, flags);
    if (need == 0) return error.FinalPathFailed;
    const buf = try alloc.alloc(u16, need);
    defer alloc.free(buf);
    const got = k.GetFinalPathNameByHandleW(file, buf.ptr, need, flags);
    if (got == 0 or got >= need) return error.FinalPathFailed;
    // `\\?\C:\x` becomes `C:\x`; `\\?\UNC\...` stays and is refused.
    var out = buf[0..got];
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    if (out.len >= 6 and std.mem.eql(u16, out[0..4], prefix) and out[5] == ':') out = out[4..];
    return try alloc.dupe(u16, out);
}

fn realIsDangerous(ext: []const u16) bool {
    var buf: [2100:0]u16 = undefined;
    const z = toZ(&buf, ext) orelse return true;
    // Unavailable: the safe answer is to reveal.
    return win32.shlwapi.assocIsDangerous(z) orelse true;
}

fn realEnv(pwd: ?[]const u8, userprofile: []const u8) Env {
    return .{
        .pwd = pwd,
        .userprofile = userprofile,
        .exists = realExists,
        .drive_type = realDriveType,
        .full_path = realFullPath,
        .is_dangerous = realIsDangerous,
        .long_path = realLongPath,
        .final_path = realFinalPath,
    };
}

/// The shell calls; replaced by tests.
pub const Launcher = struct {
    /// URL or path, terminated.
    open: *const fn ([:0]const u16) bool,
    reveal: *const fn ([:0]const u16) bool,
};

const real_launcher: Launcher = .{ .open = realOpen, .reveal = realReveal };

fn realOpen(target: [:0]const u16) bool {
    var info: win32.shell32.SHELLEXECUTEINFOW = .{
        .fMask = win32.shell32.SEE_MASK_NOASYNC | win32.shell32.SEE_MASK_FLAG_NO_UI,
        .lpVerb = L("open"),
        .lpFile = target.ptr,
        .nShow = win32.user32.SW_SHOWNORMAL,
    };
    return win32.shell32.ShellExecuteExW(&info) != 0;
}

fn realReveal(path: [:0]const u16) bool {
    const pidl = win32.shell32.ILCreateFromPathW(path.ptr) orelse return false;
    defer win32.shell32.ILFree(pidl);
    return win32.shell32.SHOpenFolderAndSelectItems(pidl, 0, null, 0) >= 0;
}

// -- The worker -------------------------------------------------------------------------

pub const Outcome = enum { accepted, cancelled };
pub const Tag = enum { open, reveal, confirm, refuse };

fn tagOf(v: Verdict) Tag {
    return std.meta.stringToEnum(Tag, @tagName(v)).?;
}

pub const Recorded = struct {
    url: [max_record_url]u8 = undefined,
    url_len: u16 = 0,
    verdict: Tag,
    outcome: ?Outcome = null,

    fn make(url: []const u8, verdict: Tag, outcome: ?Outcome) Recorded {
        var r: Recorded = .{ .verdict = verdict, .outcome = outcome };
        const n = @min(url.len, max_record_url);
        @memcpy(r.url[0..n], url[0..n]);
        r.url_len = @intCast(n);
        return r;
    }
};

const Job = struct {
    alloc: Allocator,
    /// Where the confirmation goes; null when the surface was not found.
    window: ?win32.foundation.HWND,
    surface_id: u32,
    kind: apprt.action.OpenUrl.Kind,
    url: []u8,
    pwd: ?[]u8,
    /// The user already agreed: open `url` as it is.
    confirmed: bool,

    fn deinit(self: Job) void {
        self.alloc.free(self.url);
        if (self.pwd) |p| self.alloc.free(p);
    }
};

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    queue: [max_queue]Job = undefined,
    head: usize = 0,
    len: usize = 0,
    /// Ring of the last verdicts (test mode); `recorded_total` counts all.
    recorded: [max_recorded]?Recorded = @splat(null),
    recorded_total: usize = 0,
    launcher: Launcher = real_launcher,
    /// UI thread only: a confirmation dialog is up.
    confirming: bool = false,

    /// False when the queue is full.
    fn push(self: *State, job: Job) bool {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping or self.len == max_queue) return false;
        self.queue[(self.head + self.len) % max_queue] = job;
        self.len += 1;
        self.cond.signal(io);
        return true;
    }

    /// Null once the queue is empty and the worker should stop.
    fn pop(self: *State) ?Job {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.len == 0 and !self.stopping) self.cond.waitUncancelable(io, &self.mutex);
        if (self.len == 0) return null;
        const job = self.queue[self.head];
        self.head = (self.head + 1) % max_queue;
        self.len -= 1;
        return job;
    }

    fn record(self: *State, r: Recorded) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.recorded[self.recorded_total % max_recorded] = r;
        self.recorded_total += 1;
    }

    /// Drops what is still queued.
    fn clear(self: *State) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.len > 0) {
            self.queue[self.head].deinit();
            self.head = (self.head + 1) % max_queue;
            self.len -= 1;
        }
    }
};

/// What the worker posts for a `confirm` verdict; the handler of
/// `WM_GHOSTTY_POSTED_DIALOG` (kind `url_confirm`) owns and frees it.
pub const ConfirmPayload = struct {
    alloc: Allocator,
    surface_id: u32,
    url: []u8,

    pub fn destroy(self: *ConfirmPayload) void {
        self.alloc.free(self.url);
        self.alloc.destroy(self);
    }
};

fn findSurface(app: *App, id: u32) ?*@import("Surface.zig") {
    for (app.windows.items) |w| {
        if (w.findSurface(id)) |s| return s;
    }
    return null;
}

/// Queues a link of terminal output (or a file Ghostty wrote) for the
/// worker. Never blocks; a full queue refuses the link. UI thread only.
pub fn submit(app: *App, surface_id: u32, kind: apprt.action.OpenUrl.Kind, url: []const u8) void {
    const alloc = app.core_app.alloc;
    const surface = findSurface(app, surface_id);

    const copy = alloc.dupe(u8, url) catch |err| {
        log.warn("unable to copy a link err={}", .{err});
        return;
    };
    const pwd: ?[]u8 = if (surface) |s| if (s.getPwd()) |p| alloc.dupe(u8, p) catch null else null else null;
    const job: Job = .{
        .alloc = alloc,
        .window = if (surface) |s| s.window.hwnd else null,
        .surface_id = surface_id,
        .kind = kind,
        .url = copy,
        .pwd = pwd,
        .confirmed = false,
    };
    enqueue(&app.shell_open, job);
}

fn enqueue(state: *State, job: Job) void {
    if (!state.push(job)) {
        log.warn("link queue is full, refusing the link", .{});
        job.deinit();
        return;
    }
    if (state.thread != null) return;
    state.thread = std.Thread.spawn(.{}, run, .{state}) catch |err| {
        log.warn("unable to start the link worker err={}", .{err});
        state.clear();
        return;
    };
}

/// Stops the worker; called at the start of `App.terminate`.
pub fn appStopping(app: *App) void {
    const state = &app.shell_open;
    const io = global.io();
    state.mutex.lockUncancelable(io);
    state.stopping = true;
    state.cond.broadcast(io);
    state.mutex.unlock(io);
    state.clear();
    if (state.thread) |t| t.join();
    state.thread = null;
}

fn run(state: *State) void {
    _ = win32.ole32.CoInitializeEx(null, win32.ole32.COINIT_APARTMENTTHREADED);
    defer win32.ole32.CoUninitialize();

    while (state.pop()) |job| {
        defer job.deinit();
        process(state, job);
    }
}

fn process(state: *State, job: Job) void {
    const alloc = job.alloc;
    if (job.confirmed) {
        act(state, job.url, .{ .open = job.url });
        return;
    }

    const profile = global.environ().getAlloc(alloc, "USERPROFILE") catch null;
    defer if (profile) |p| alloc.free(p);
    const env = realEnv(job.pwd, profile orelse "");
    const verdict = validate(alloc, job.kind, job.url, env) catch |err| {
        log.warn("unable to check a link err={}", .{err});
        return;
    };
    defer verdict.deinit(alloc);

    switch (verdict) {
        .confirm => postConfirm(state, job),
        else => act(state, job.url, verdict),
    }
}

/// Launches (or, in test mode, records) a verdict that needs no question.
fn act(state: *State, url: []const u8, verdict: Verdict) void {
    if (ops.testOpsEnabled()) {
        state.record(.make(url, tagOf(verdict), null));
        return;
    }

    switch (verdict) {
        .open, .reveal => |target| {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, target) catch |err| {
                log.warn("unable to convert a link err={}", .{err});
                return;
            };
            defer std.heap.page_allocator.free(wide);
            const ok = if (verdict == .open) state.launcher.open(wide) else state.launcher.reveal(wide);
            if (!ok) log.warn("unable to {t} a link", .{tagOf(verdict)});
        },
        .refuse => |why| log.warn("refusing to open a link why={s}", .{why}),
        .confirm => unreachable,
    }
}

fn postConfirm(state: *State, job: Job) void {
    _ = state;
    const hwnd = job.window orelse {
        log.warn("link needs a confirmation but its surface is gone", .{});
        return;
    };
    const payload = job.alloc.create(ConfirmPayload) catch return;
    payload.* = .{
        .alloc = job.alloc,
        .surface_id = job.surface_id,
        .url = job.alloc.dupe(u8, job.url) catch {
            job.alloc.destroy(payload);
            return;
        },
    };
    if (win32.user32.PostMessageW(
        hwnd,
        messages.WM_GHOSTTY_POSTED_DIALOG,
        @backingInt(hooks.DialogKind.url_confirm),
        @bitCast(@intFromPtr(payload)),
    ) == 0) {
        log.warn("unable to post a link confirmation", .{});
        payload.destroy();
    }
}

/// The user answered the confirmation of `url`. UI thread. In test mode
/// the answer is recorded and nothing is opened.
pub fn confirmed(app: *App, url: []const u8, accepted: bool) void {
    const state = &app.shell_open;
    if (ops.testOpsEnabled()) {
        state.record(.make(url, .confirm, if (accepted) .accepted else .cancelled));
        return;
    }
    if (!accepted) return;

    const alloc = app.core_app.alloc;
    const copy = alloc.dupe(u8, url) catch return;
    enqueue(state, .{
        .alloc = alloc,
        .window = null,
        .surface_id = 0,
        .kind = .unknown,
        .url = copy,
        .pwd = null,
        .confirmed = true,
    });
}

/// `open_config`: the shell's "open" verb; no association goes to Notepad.
/// Opens a window, so tests only record it.
pub fn openPath(app: *App, path: []const u8) void {
    const state = &app.shell_open;
    if (ops.testOpsEnabled()) {
        state.record(.make(path, .open, null));
        return;
    }

    const alloc = app.core_app.alloc;
    const wide = util.utf16z(alloc, path) catch |err| {
        log.warn("unable to convert path err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    if (state.launcher.open(wide)) return;
    if (win32.kernel32.GetLastError() != error_no_association) {
        log.warn("unable to open the file", .{});
        return;
    }

    const quoted = std.fmt.allocPrint(alloc, "\"{s}\"", .{path}) catch return;
    defer alloc.free(quoted);
    const params = util.utf16z(alloc, quoted) catch return;
    defer alloc.free(params);
    var info: win32.shell32.SHELLEXECUTEINFOW = .{
        .fMask = win32.shell32.SEE_MASK_NOASYNC | win32.shell32.SEE_MASK_FLAG_NO_UI,
        .lpVerb = L("open"),
        .lpFile = L("notepad.exe"),
        .lpParameters = params.ptr,
        .nShow = win32.user32.SW_SHOWNORMAL,
    };
    if (win32.shell32.ShellExecuteExW(&info) == 0) log.warn("unable to open the file in notepad", .{});
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    const state = &app.shell_open;
    const io = global.io();
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);

    try jw.beginArray();
    const first = state.recorded_total -| max_recorded;
    var i = first;
    while (i < state.recorded_total) : (i += 1) {
        const r = state.recorded[i % max_recorded] orelse continue;
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(r.url[0..r.url_len]);
        try jw.objectField("verdict");
        try jw.write(@tagName(r.verdict));
        try jw.objectField("outcome");
        if (r.outcome) |o| try jw.write(@tagName(o)) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
}

// -- Tests ------------------------------------------------------------------------------

const fake = struct {
    var exists_result = true;
    var dangerous_ext: []const u8 = ".dangerous";

    fn exists(_: []const u16) bool {
        return exists_result;
    }

    fn driveType(root: []const u16) u32 {
        return switch (root[0]) {
            'Z' => 4, // DRIVE_REMOTE
            'E' => 5, // DRIVE_CDROM
            'R' => drive_removable,
            else => drive_fixed,
        };
    }

    fn fullPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
        return alloc.dupe(u16, path);
    }

    fn isDangerous(ext: []const u16) bool {
        var buf: [32]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&buf, ext) catch return false;
        return std.ascii.eqlIgnoreCase(buf[0..n], dangerous_ext);
    }

    fn contains(path: []const u16, needle: []const u8) bool {
        var buf: [256]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&buf, path) catch return false;
        return std.mem.indexOf(u8, buf[0..n], needle) != null;
    }

    fn wide(alloc: Allocator, s: []const u8) ![]u16 {
        return std.unicode.utf8ToUtf16LeAlloc(alloc, s);
    }

    /// Knows the long name of one short name; fails for names with "nolong".
    fn longPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
        if (contains(path, "nolong")) return error.NoLongName;
        if (contains(path, "REPORT~1.DOC")) return wide(alloc, "C:\\x\\report.docm");
        if (contains(path, "PICT~1.TXT")) return wide(alloc, "C:\\x\\picture.txt");
        return alloc.dupe(u16, path);
    }

    /// Two links: one to a share, one to a program.
    fn finalPath(alloc: Allocator, path: []const u16) anyerror![]u16 {
        if (contains(path, "remote-link")) return wide(alloc, "\\\\?\\UNC\\srv\\s\\a.txt");
        if (contains(path, "exe-link")) return wide(alloc, "C:\\x\\evil.exe");
        return error.NotALink;
    }

    fn env(pwd: ?[]const u8) Env {
        return .{
            .pwd = pwd,
            .userprofile = "C:\\Users\\u",
            .exists = exists,
            .drive_type = driveType,
            .full_path = fullPath,
            .is_dangerous = isDangerous,
            .long_path = longPath,
            .final_path = finalPath,
        };
    }
};

fn check(kind: apprt.action.OpenUrl.Kind, url: []const u8, tag: Tag, path: ?[]const u8) !void {
    const v = try validate(std.testing.allocator, kind, url, fake.env("/c/repo"));
    defer v.deinit(std.testing.allocator);
    errdefer std.debug.print("url={s} verdict={any}\n", .{ url, v });
    try std.testing.expectEqual(tag, tagOf(v));
    if (path) |p| switch (v) {
        .open, .reveal, .confirm => |s| try std.testing.expectEqualStrings(p, s),
        .refuse => {},
    };
}

test "win32 shell_open: web, mail and other schemes" {
    fake.exists_result = true;
    try check(.osc8, "https://a.b/c", .open, "https://a.b/c");
    try check(.osc8, "HtTpS://a.b/c", .open, null);
    try check(.unknown, "mailto:a@b.c?subject=x", .open, null);
    try check(.osc8, "javascript:alert(1)", .confirm, "javascript:alert(1)");
    try check(.osc8, "ms-msdt:/id x", .refuse, null);
    try check(.osc8, "MS-MSDT:/id x", .refuse, null);
    try check(.osc8, "search-ms:query=x", .refuse, null);
    try check(.osc8, "localhost:3000", .confirm, null);
    try check(.osc8, "ftp://host/a.exe", .confirm, null);
    try check(.osc8, "ms-settings:", .confirm, null);
    try check(.osc8, "https:///x", .refuse, null);
    try check(.osc8, "mailto:a@b.c?attach=C:\\x", .refuse, null);
}

test "win32 shell_open: control characters and length" {
    try check(.osc8, "https://a/\nb", .refuse, null);
    try check(.osc8, "https://a/\xc2\x85b", .refuse, null);
    try check(.osc8, "https://a/\"b", .refuse, null);
    try check(.osc8, "", .refuse, null);
    const long = try std.testing.allocator.alloc(u8, link_policy.max_len + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    @memcpy(long[0..8], "https://");
    try check(.osc8, long, .refuse, null);
    try check(.osc8, long[0..link_policy.max_len], .open, null);
}

test "win32 shell_open: file URLs and drive paths" {
    fake.exists_result = true;
    try check(.osc8, "file:///C:/x/a.txt", .open, "C:\\x\\a.txt");
    try check(.osc8, "file://localhost/C:/x/a.txt", .open, null);
    fake.exists_result = false;
    try check(.osc8, "file:///C:/x/a.txt", .refuse, null);
    // Executables are revealed whether they exist or not.
    try check(.osc8, "file:///C:/x/run.exe", .reveal, "C:\\x\\run.exe");
    try check(.osc8, "C:\\x\\a.ps1", .reveal, "C:\\x\\a.ps1");
    try check(.unknown, "C:\\x\\file.TXT.exe", .reveal, null);
    try check(.osc8, "file:///C:/x/a.%65xe", .reveal, "C:\\x\\a.exe");
    fake.exists_result = true;
    try check(.osc8, "C:\\x\\a.txt", .open, "C:\\x\\a.txt");
}

test "win32 shell_open: network and device paths are refused" {
    try check(.unknown, "\\\\srv\\share\\a.txt", .refuse, null);
    try check(.unknown, "//srv/share/a.txt", .refuse, null);
    try check(.osc8, "file://srv/share/a", .refuse, null);
    try check(.osc8, "file:////srv/share/a", .refuse, null);
    try check(.osc8, "\\\\?\\UNC\\srv\\s\\a", .refuse, null);
    try check(.osc8, "\\\\.\\C:\\x", .refuse, null);
    try check(.osc8, "\\\\?\\GLOBALROOT\\x", .refuse, null);
    try check(.osc8, "\\\\?\\C:\\x\\a.txt", .refuse, null);
    try check(.osc8, "file:///%5C%5Csrv/s/a", .refuse, null);
    try check(.osc8, "Z:\\a.txt", .refuse, null);
    try check(.osc8, "E:\\a.txt", .refuse, null);
    try check(.osc8, "R:\\a.txt", .open, null);
}

test "win32 shell_open: names Windows reads differently" {
    fake.exists_result = true;
    try check(.osc8, "C:\\x\\a.exe.", .reveal, "C:\\x\\a.exe");
    try check(.osc8, "C:\\x\\a.exe ", .reveal, "C:\\x\\a.exe");
    try check(.osc8, "C:\\x\\a.txt:evil.exe", .refuse, null);
    try check(.osc8, "C:\\x\\CON", .refuse, null);
    try check(.osc8, "C:\\x\\nul.txt", .refuse, null);
    try check(.osc8, "C:\\PROGRA~1\\x\\a.exe", .reveal, null);
    try check(.osc8, "C:\\x\\a?.txt", .refuse, null);
}

test "win32 shell_open: dangerous extensions are revealed" {
    fake.exists_result = true;
    const exts = [_][]const u8{
        ".settingcontent-ms", ".library-ms", ".searchConnector-ms", ".diagcab", ".appref-ms",
        ".website",           ".theme",      ".themepack",          ".iso",     ".img",
        ".vhd",               ".vhdx",       ".xll",                ".inf",     ".scf",
        ".sct",               ".wsc",        ".msp",                ".docm",    ".dangerous",
    };
    for (exts) |ext| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "C:\\x\\a{s}", .{ext});
        defer std.testing.allocator.free(path);
        try check(.osc8, path, .reveal, path);
    }
}

test "win32 shell_open: short names are judged by the long name" {
    fake.exists_result = true;
    // report.docm behind REPORT~1.DOC.
    try check(.osc8, "C:\\x\\REPORT~1.DOC", .reveal, "C:\\x\\report.docm");
    try check(.osc8, "file:///C:/x/REPORT~1.DOC", .reveal, null);
    // A harmless long name that still looks short is not trusted.
    try check(.osc8, "C:\\x\\PICT~1.TXT", .open, "C:\\x\\picture.txt");
    try check(.osc8, "C:\\x\\OTHER~1.TXT", .reveal, null);
    try check(.osc8, "C:\\PROGRA~1\\x\\a.txt", .reveal, null);
    // The long name cannot be had: an existing file is revealed, a missing one is not there.
    try check(.osc8, "C:\\x\\nolong.txt", .reveal, null);
    fake.exists_result = false;
    try check(.osc8, "C:\\x\\nolong.txt", .refuse, null);
    fake.exists_result = true;
}

test "win32 shell_open: code-running extensions are revealed" {
    fake.exists_result = true;
    const exts = [_][]const u8{
        ".pyw",             ".py",  ".pyz", ".pyzw", ".sh",  ".bash", ".rb",  ".pl",  ".jnlp", ".rdp",  ".wsb", ".appinstaller",
        ".ms-appinstaller", ".mht", ".vb",  ".ws",   ".shb", ".shs",  ".hlp", ".cer", ".crt",  ".ppkg", ".msh", ".msh2",
        ".mshxml",
    };
    for (exts) |ext| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "C:\\x\\a{s}", .{ext});
        defer std.testing.allocator.free(path);
        try check(.osc8, path, .reveal, path);
    }
    try check(.unknown, "~/x.sh", .reveal, null);
}

test "win32 shell_open: positions, shell folders and links" {
    fake.exists_result = true;
    try check(.unknown, "src/main.zig:12", .open, "C:\\repo\\src\\main.zig");
    try check(.unknown, "src/main.zig:12:5", .open, "C:\\repo\\src\\main.zig");
    try check(.unknown, "main.zig:12", .open, "C:\\repo\\main.zig");
    try check(.unknown, "C:\\x\\a.txt:3", .open, "C:\\x\\a.txt");
    try check(.unknown, "C:\\x\\a.txt:evil", .refuse, null);
    try check(.unknown, "C:\\x\\a.txt:1:2:3", .refuse, null);

    try check(.osc8, "C:\\x\\folder.{20D04FE0-3AEA-1069-A2D8-08002B30309D}", .refuse, null);

    // A link is judged by its target.
    try check(.osc8, "C:\\x\\remote-link.txt", .refuse, null);
    try check(.osc8, "C:\\x\\exe-link.txt", .reveal, "C:\\x\\evil.exe");
}

test "win32 shell_open: policy rows of the first link hotfix" {
    fake.exists_result = true;
    const refused = [_][]const u8{
        "\\\\host\\s\\a.exe",      "//host/s/a.exe",            "\\\\?\\C:\\a",                           "\\\\.\\C:\\a",
        "file://host/share/a.exe", "file:////host/share/a.exe", "file:///%5C%5Chost%5Cshare%5Ca.exe",     "file:///C:/a%00b",
        "file:///C:/a%22b",        "file:///C:/a%2",            "file:///C:/a%zz",                        "file:///etc/passwd",
        "file:relative",           "C:\\x\\y.txt:stream",       "C:\\x\\*.exe",                           "C:foo.exe",
        "javascript:alert(1)x\n",  "http:",                     "https:///x",                             "mailto:",
        "https://a/\x00",          "https://a/\"b",             "https://a b",                            "mailto:a@b c",
        "https://a/\xe2\x80\xae",  "https://a/caf\xc3\xa9",     "https://a/<b>",                          "https://a/{b}",
        "https://a/b\\c",          "https://a/b^c",             "mailto:a@b.c?attach=C:\\x",              "mailto:a@b.c?subject=x&Attachment=y",
        "mailto:a@b.c?%61ttach=y", "mailto:a@b.c?%20attach=y",  "mailto:a@b.c?subject=x&attachment%09=y", "mailto:a@b.c?subject=x&ATTACH=y",
        "C:\\a\xe2\x80\xaeb.exe",  "C:\\a\xe2\x81\xa6b",        "C:\\a\xe2\x80\xa8b",                     "C:\\x\\CON",
        "C:\\x\\nul.txt",          "C:\\x\\com1.tar.gz",        "C:\\lpt9\\a",                            "C:\\a\xe2\x80\x8eb",
        "C:\\a\xe2\x80\x8fb",      "C:\\a\xd8\x9cb",            "C:\\a\xc2\x85b",                         "C:\\x\\CONIN$",
        "C:\\x\\conout$.txt",      "C:\\x\\CLOCK$",
    };
    for (refused) |url| try check(.osc8, url, .refuse, null);
    // These were refused as odd schemes before; now they ask or are paths.
    try check(.osc8, "ms-settings:", .confirm, null);
    try check(.osc8, "https://example.com/%2e%2e/%41", .open, null);
    try check(.osc8, "https://a/caf%C3%A9", .open, null);
    try check(.osc8, "mailto:a@b.c?subject=attach%20me&body=attachment", .open, null);
    try check(.osc8, "FILE:///c:/My%20Dir/a.txt", .open, "c:\\My Dir\\a.txt");
    try check(.osc8, "file://localhost/C:/x/y.exe", .reveal, "C:\\x\\y.exe");
    try check(.osc8, "D:/x/y.lnk", .reveal, "D:\\x\\y.lnk");
    try check(.osc8, "C:\\x\\y\\", .open, "C:\\x\\y");
    try check(.osc8, "C:\\", .open, "C:\\");
    try check(.osc8, "C:\\x\\com10", .open, null);
    try check(.osc8, "C:\\a\xc3\xa9\\b", .open, "C:\\a\xc3\xa9\\b");
}

test "win32 shell_open: paths are resolved against the surface" {
    fake.exists_result = true;
    try check(.unknown, "src/main.zig", .open, "C:\\repo\\src\\main.zig");
    try check(.unknown, "~/a.txt", .open, "C:\\Users\\u\\a.txt");
    try check(.unknown, "/c/x/a.txt", .open, "C:\\x\\a.txt");
    try check(.unknown, "/d", .open, "D:\\");
    try check(.unknown, "/etc/passwd", .refuse, null);
    try check(.unknown, "C:foo.txt", .refuse, null);

    const no_pwd = try validate(std.testing.allocator, .unknown, "src/main.zig", fake.env(null));
    defer no_pwd.deinit(std.testing.allocator);
    try std.testing.expect(no_pwd == .refuse);
    const bad_pwd = try validate(std.testing.allocator, .unknown, "a.txt", fake.env("\\\\srv\\x"));
    defer bad_pwd.deinit(std.testing.allocator);
    try std.testing.expect(bad_pwd == .refuse);
}

test "win32 shell_open: files Ghostty wrote open without the checks" {
    fake.exists_result = false;
    try check(.text, "C:\\x\\a.txt", .open, "C:\\x\\a.txt");
    try check(.html, "C:\\x\\a.exe", .open, null);
    try check(.text, "\\\\srv\\x", .refuse, null);
}

var launched: usize = 0;
var revealed: usize = 0;

fn fakeOpen(_: [:0]const u16) bool {
    launched += 1;
    return true;
}

fn fakeReveal(_: [:0]const u16) bool {
    revealed += 1;
    return true;
}

test "win32 shell_open: act launches, and in test mode only records" {
    var state: State = .{ .launcher = .{ .open = fakeOpen, .reveal = fakeReveal } };
    launched = 0;
    revealed = 0;
    act(&state, "x", .{ .open = "C:\\a.txt" });
    act(&state, "x", .{ .reveal = "C:\\a.exe" });
    act(&state, "x", .{ .refuse = "why" });
    try std.testing.expectEqual(@as(usize, 1), launched);
    try std.testing.expectEqual(@as(usize, 1), revealed);
    try std.testing.expectEqual(@as(usize, 0), state.recorded_total);

    ops.test_ops_override = true;
    defer ops.test_ops_override = null;
    act(&state, "https://a", .{ .open = "https://a" });
    act(&state, "javascript:x", .{ .refuse = "why" });
    try std.testing.expectEqual(@as(usize, 1), launched);
    try std.testing.expectEqual(@as(usize, 2), state.recorded_total);
    try std.testing.expectEqual(Tag.open, state.recorded[0].?.verdict);
    try std.testing.expectEqual(Tag.refuse, state.recorded[1].?.verdict);
}

test "win32 shell_open: the queue holds eight jobs" {
    var state: State = .{};
    const alloc = std.testing.allocator;
    for (0..max_queue) |_| {
        const url = try alloc.dupe(u8, "https://a");
        const job: Job = .{ .alloc = alloc, .window = null, .surface_id = 0, .kind = .osc8, .url = url, .pwd = null, .confirmed = false };
        try std.testing.expect(state.push(job));
    }
    const url = try alloc.dupe(u8, "https://a");
    const job: Job = .{ .alloc = alloc, .window = null, .surface_id = 0, .kind = .osc8, .url = url, .pwd = null, .confirmed = false };
    try std.testing.expect(!state.push(job));
    job.deinit();
    state.clear();
    try std.testing.expectEqual(@as(usize, 0), state.len);
}

/// For tests of other modules: a queue with no room left.
pub fn fillQueueForTest(state: *State, alloc: Allocator) !void {
    for (0..max_queue) |_| {
        const url = try alloc.dupe(u8, "https://a");
        const job: Job = .{ .alloc = alloc, .window = null, .surface_id = 0, .kind = .osc8, .url = url, .pwd = null, .confirmed = false };
        if (!state.push(job)) {
            job.deinit();
            return error.QueueFull;
        }
    }
}

pub fn clearForTest(state: *State) void {
    state.clear();
}
