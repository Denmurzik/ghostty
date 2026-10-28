//! Default shell resolution for Windows: Git Bash, then PowerShell 7, then
//! cmd. The result is a `.direct` argv so paths with spaces (for example
//! `C:\Program Files\Git\bin\bash.exe`) survive.
//!
//! A bare `bash` from PATH is never used: `C:\Windows\System32\bash.exe` is
//! the WSL launcher, not Git Bash.
//!
//! All filesystem and registry access goes through a `Probe` so the resolver
//! can be tested on any machine. Paths are UTF-8 (WTF-8) strings.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = @import("windows.zig");

const log = std.log.scoped(.windows_shell);

pub const Kind = enum { git_bash, pwsh, cmd };

pub const Resolved = struct {
    kind: Kind,

    /// Never empty; `argv[0]` is the absolute path of the executable.
    argv: []const [:0]const u8,

    pub fn deinit(self: Resolved, alloc: Allocator) void {
        for (self.argv) |arg| alloc.free(arg);
        alloc.free(self.argv);
    }
};

pub const Probe = struct {
    ctx: ?*anyopaque = null,

    /// True if `path` is an existing file (not a directory).
    exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,

    /// The Git for Windows install directory from the registry, allocated
    /// with `alloc`, or null if there is none.
    regGitInstallPath: *const fn (ctx: ?*anyopaque, alloc: Allocator) ?[]const u8,
};

/// Resolve the default shell. The returned argv is allocated with `alloc`
/// (free it with `Resolved.deinit` or use an arena); all other allocations
/// are freed before returning. Always succeeds with at least cmd, the
/// last resort, which is not checked for existence.
pub fn resolve(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    probe: Probe,
) !Resolved {
    if (try findGitBash(alloc, env, probe)) |bash| {
        defer alloc.free(bash);
        return try build(alloc, .git_bash, &.{ bash, "--login", "-i" });
    }

    if (try findPwsh(alloc, env, probe)) |pwsh| {
        defer alloc.free(pwsh);
        return try build(alloc, .pwsh, &.{ pwsh, "-NoLogo" });
    }

    const cmd = try findCmd(alloc, env);
    defer alloc.free(cmd);
    return try build(alloc, .cmd, &.{cmd});
}

fn build(alloc: Allocator, kind: Kind, args: []const []const u8) !Resolved {
    const argv = try alloc.alloc([:0]const u8, args.len);
    var n: usize = 0;
    errdefer {
        for (argv[0..n]) |arg| alloc.free(arg);
        alloc.free(argv);
    }
    for (args) |arg| {
        argv[n] = try alloc.dupeSentinel(u8, arg, 0);
        n += 1;
    }
    return .{ .kind = kind, .argv = argv };
}

pub fn findGitBash(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    probe: Probe,
) !?[]u8 {
    const rel = "Git\\bin\\bash.exe";

    // Well-known install locations.
    const bases = [_]struct { var_name: []const u8, rel: []const u8 }{
        .{ .var_name = "ProgramFiles", .rel = rel },
        .{ .var_name = "ProgramW6432", .rel = rel },
        .{ .var_name = "ProgramFiles(x86)", .rel = rel },
        .{ .var_name = "LOCALAPPDATA", .rel = "Programs\\" ++ rel },
    };
    for (bases) |base| {
        const dir = nonEmpty(env.get(base.var_name)) orelse continue;
        if (try acceptBash(alloc, probe, &.{ dir, base.rel })) |path| return path;
    }

    // Registry: HKLM then HKCU, value `InstallPath`.
    if (probe.regGitInstallPath(probe.ctx, alloc)) |install| {
        defer alloc.free(install);
        if (nonEmpty(install)) |dir| {
            if (try acceptBash(alloc, probe, &.{ dir, "bin\\bash.exe" })) |path| return path;
        }
    }

    // git.exe on PATH: Git\cmd\git.exe -> Git\bin\bash.exe, and
    // Git\mingw64\bin\git.exe -> Git\bin\bash.exe.
    const path_var = nonEmpty(env.get("PATH")) orelse return null;
    var it = std.mem.splitScalar(u8, path_var, ';');
    while (it.next()) |raw| {
        const dir = trimDir(raw);
        if (dir.len == 0) continue;

        const git = try std.mem.concat(alloc, u8, &.{ dir, "\\git.exe" });
        defer alloc.free(git);
        if (!probe.exists(probe.ctx, git)) continue;

        const parent = dirname(dir) orelse continue;
        if (try acceptBash(alloc, probe, &.{ parent, "bin\\bash.exe" })) |path| return path;
        const grandparent = dirname(parent) orelse continue;
        if (try acceptBash(alloc, probe, &.{ grandparent, "bin\\bash.exe" })) |path| return path;
    }

    return null;
}

/// Join `parts` with backslashes and return the path if it exists and is
/// not the WSL launcher. Caller owns the result.
fn acceptBash(alloc: Allocator, probe: Probe, parts: []const []const u8) !?[]u8 {
    const path = try join(alloc, parts);
    errdefer alloc.free(path);
    if (isWslLauncher(path) or !probe.exists(probe.ctx, path)) {
        alloc.free(path);
        return null;
    }
    return path;
}

fn findPwsh(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    probe: Probe,
) !?[]u8 {
    if (nonEmpty(env.get("PATH"))) |path_var| {
        var it = std.mem.splitScalar(u8, path_var, ';');
        while (it.next()) |raw| {
            const dir = trimDir(raw);
            if (dir.len == 0) continue;
            const path = try join(alloc, &.{ dir, "pwsh.exe" });
            if (probe.exists(probe.ctx, path)) return path;
            alloc.free(path);
        }
    }

    const fallbacks = [_]struct { var_name: []const u8, rel: []const u8 }{
        .{ .var_name = "ProgramFiles", .rel = "PowerShell\\7\\pwsh.exe" },
        .{ .var_name = "LOCALAPPDATA", .rel = "Microsoft\\WindowsApps\\pwsh.exe" },
    };
    for (fallbacks) |fb| {
        const dir = nonEmpty(env.get(fb.var_name)) orelse continue;
        const path = try join(alloc, &.{ dir, fb.rel });
        if (probe.exists(probe.ctx, path)) return path;
        alloc.free(path);
    }

    return null;
}

fn findCmd(alloc: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (nonEmpty(env.get("COMSPEC"))) |comspec| return try alloc.dupe(u8, comspec);
    const root = nonEmpty(env.get("SystemRoot")) orelse "C:\\Windows";
    return try join(alloc, &.{ root, "System32\\cmd.exe" });
}

/// `C:\Windows\System32\bash.exe` (also under `Sysnative` / `SysWOW64`) is
/// the WSL launcher.
fn isWslLauncher(path: []const u8) bool {
    const name = "\\bash.exe";
    if (!std.ascii.endsWithIgnoreCase(path, name)) return false;
    const dir = path[0 .. path.len - name.len];
    inline for (.{ "\\system32", "\\sysnative", "\\syswow64" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(dir, suffix)) return true;
    }
    return false;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// PATH entries may be wrapped in quotes and end with a separator.
fn trimDir(raw: []const u8) []const u8 {
    const unquoted = std.mem.trim(u8, raw, " \t\"");
    return std.mem.trimEnd(u8, unquoted, "\\/");
}

fn dirname(path: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return null;
    return if (idx == 0) null else path[0..idx];
}

/// Join with `\`, collapsing a separator that is already present.
fn join(alloc: Allocator, parts: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (parts) |part| {
        if (buf.items.len > 0 and
            !std.mem.endsWith(u8, buf.items, "\\") and
            !std.mem.endsWith(u8, buf.items, "/"))
            try buf.append(alloc, '\\');
        try buf.appendSlice(alloc, part);
    }
    return try buf.toOwnedSlice(alloc);
}

/// The probe backed by the real filesystem and registry.
pub fn systemProbe() Probe {
    return .{ .exists = systemExists, .regGitInstallPath = systemRegGitInstallPath };
}

fn systemExists(_: ?*anyopaque, path: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;

    var buf: [2048]u16 = undefined;
    // UTF-16 units never outnumber UTF-8 bytes, so this bounds the conversion.
    if (path.len >= buf.len) return false;
    const len = std.unicode.wtf8ToWtf16Le(buf[0 .. buf.len - 1], path) catch return false;
    buf[len] = 0;
    const attrs = windows.GetFileAttributesW(@ptrCast(&buf));
    if (attrs == windows.INVALID_FILE_ATTRIBUTES) return false;
    return attrs & windows.FILE_ATTRIBUTE_DIRECTORY == 0;
}

fn systemRegGitInstallPath(_: ?*anyopaque, alloc: Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;

    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\GitForWindows");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("InstallPath");
    for ([_]windows.HKEY{ windows.HKEY_LOCAL_MACHINE, windows.HKEY_CURRENT_USER }) |root| {
        var buf: [1024]u16 = undefined;
        var size: windows.DWORD = @sizeOf(@TypeOf(buf));
        const status = windows.RegGetValueW(
            root,
            subkey,
            value,
            windows.RRF_RT_REG_SZ,
            null,
            &buf,
            &size,
        );
        if (status != windows.ERROR_SUCCESS) continue;

        // `size` is in bytes and includes the terminating NUL.
        const chars = std.mem.sliceTo(buf[0 .. size / 2], 0);
        if (chars.len == 0) continue;
        return std.unicode.wtf16LeToWtf8Alloc(alloc, chars) catch null;
    }
    return null;
}

const MockProbe = struct {
    existing: []const []const u8 = &.{},
    reg: ?[]const u8 = null,

    fn probe(self: *MockProbe) Probe {
        return .{ .ctx = self, .exists = exists, .regGitInstallPath = regGitInstallPath };
    }

    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *MockProbe = @ptrCast(@alignCast(ctx.?));
        for (self.existing) |e| if (std.ascii.eqlIgnoreCase(e, path)) return true;
        return false;
    }

    fn regGitInstallPath(ctx: ?*anyopaque, alloc: Allocator) ?[]const u8 {
        const self: *MockProbe = @ptrCast(@alignCast(ctx.?));
        const reg = self.reg orelse return null;
        return alloc.dupe(u8, reg) catch null;
    }
};

fn testEnv(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

fn expectArgv(resolved: Resolved, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, resolved.argv.len);
    for (expected, resolved.argv) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "windows shell: Git Bash preferred, argv has --login -i" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{
        .{ "ProgramFiles", "C:\\Program Files" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();

    // pwsh exists too, but Git Bash wins.
    var mock: MockProbe = .{ .existing = &.{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
    } };
    const resolved = try resolve(alloc, &env, mock.probe());
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Kind.git_bash, resolved.kind);
    try expectArgv(resolved, &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" });
}

test "windows shell: System32 bash.exe (WSL) is never chosen" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{
        .{ "SystemRoot", "C:\\Windows" },
        .{ "PATH", "C:\\Windows\\System32;C:\\Windows" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();

    var mock: MockProbe = .{ .existing = &.{
        "C:\\Windows\\System32\\bash.exe",
        "C:\\Windows\\System32\\git.exe",
    } };
    // bash.exe is never looked up on PATH, and git.exe in System32 would
    // map to C:\Windows\bin\bash.exe, which does not exist.
    const resolved = try resolve(alloc, &env, mock.probe());
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(Kind.cmd, resolved.kind);

    // The guard itself.
    try std.testing.expect(isWslLauncher("C:\\Windows\\System32\\bash.exe"));
    try std.testing.expect(isWslLauncher("c:\\windows\\SYSNATIVE\\BASH.EXE"));
    try std.testing.expect(!isWslLauncher("C:\\Program Files\\Git\\bin\\bash.exe"));
    try std.testing.expect(!isWslLauncher("C:\\Program Files\\Git\\usr\\bin\\bash.exe"));
}

test "windows shell: registry InstallPath used" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{
        .{ "ProgramFiles", "C:\\Program Files" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();

    var mock: MockProbe = .{
        .existing = &.{"D:\\Tools\\Git\\bin\\bash.exe"},
        .reg = "D:\\Tools\\Git",
    };
    const resolved = try resolve(alloc, &env, mock.probe());
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Kind.git_bash, resolved.kind);
    try std.testing.expectEqualStrings("D:\\Tools\\Git\\bin\\bash.exe", resolved.argv[0]);
}

test "windows shell: git.exe on PATH locates bash" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{
        .{ "PATH", "C:\\Windows\\System32;\"E:\\Dev Tools\\Git\\cmd\";C:\\Other" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();

    var mock: MockProbe = .{ .existing = &.{
        "E:\\Dev Tools\\Git\\cmd\\git.exe",
        "E:\\Dev Tools\\Git\\bin\\bash.exe",
    } };
    {
        const resolved = try resolve(alloc, &env, mock.probe());
        defer resolved.deinit(alloc);
        try std.testing.expectEqual(Kind.git_bash, resolved.kind);
        try std.testing.expectEqualStrings("E:\\Dev Tools\\Git\\bin\\bash.exe", resolved.argv[0]);
    }

    // git.exe under mingw64\bin.
    var env2 = try testEnv(&.{
        .{ "PATH", "E:\\Git\\mingw64\\bin" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env2.deinit();
    var mock2: MockProbe = .{ .existing = &.{
        "E:\\Git\\mingw64\\bin\\git.exe",
        "E:\\Git\\bin\\bash.exe",
    } };
    const resolved2 = try resolve(alloc, &env2, mock2.probe());
    defer resolved2.deinit(alloc);
    try std.testing.expectEqualStrings("E:\\Git\\bin\\bash.exe", resolved2.argv[0]);
}

test "windows shell: pwsh when no Git Bash" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{
        .{ "ProgramFiles", "C:\\Program Files" },
        .{ "PATH", "C:\\Windows\\System32;C:\\Program Files\\PowerShell\\7" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();

    var mock: MockProbe = .{ .existing = &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"} };
    {
        const resolved = try resolve(alloc, &env, mock.probe());
        defer resolved.deinit(alloc);
        try std.testing.expectEqual(Kind.pwsh, resolved.kind);
        try expectArgv(resolved, &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" });
    }

    // Not on PATH: the well-known install dir and the WindowsApps alias.
    var env2 = try testEnv(&.{
        .{ "LOCALAPPDATA", "C:\\Users\\Анна Ли\\AppData\\Local" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env2.deinit();
    var mock2: MockProbe = .{ .existing = &.{"C:\\Users\\Анна Ли\\AppData\\Local\\Microsoft\\WindowsApps\\pwsh.exe"} };
    const resolved2 = try resolve(alloc, &env2, mock2.probe());
    defer resolved2.deinit(alloc);
    try std.testing.expectEqual(Kind.pwsh, resolved2.kind);
    try std.testing.expectEqualStrings(
        "C:\\Users\\Анна Ли\\AppData\\Local\\Microsoft\\WindowsApps\\pwsh.exe",
        resolved2.argv[0],
    );
}

test "windows shell: cmd from COMSPEC as last resort" {
    const alloc = std.testing.allocator;
    {
        var env = try testEnv(&.{.{ "COMSPEC", "D:\\Win\\System32\\cmd.exe" }});
        defer env.deinit();
        var mock: MockProbe = .{};
        const resolved = try resolve(alloc, &env, mock.probe());
        defer resolved.deinit(alloc);
        try std.testing.expectEqual(Kind.cmd, resolved.kind);
        try expectArgv(resolved, &.{"D:\\Win\\System32\\cmd.exe"});
    }

    // No COMSPEC: SystemRoot, then the C:\Windows default.
    var env = try testEnv(&.{.{ "SystemRoot", "D:\\Win" }});
    defer env.deinit();
    var mock: MockProbe = .{};
    const resolved = try resolve(alloc, &env, mock.probe());
    defer resolved.deinit(alloc);
    try expectArgv(resolved, &.{"D:\\Win\\System32\\cmd.exe"});

    var empty = try testEnv(&.{});
    defer empty.deinit();
    const resolved2 = try resolve(alloc, &empty, mock.probe());
    defer resolved2.deinit(alloc);
    try expectArgv(resolved2, &.{"C:\\Windows\\System32\\cmd.exe"});
}

test "windows shell: non-ASCII ProgramFiles path survives" {
    const alloc = std.testing.allocator;
    var env = try testEnv(&.{.{ "ProgramFiles", "C:\\Программы" }});
    defer env.deinit();

    var mock: MockProbe = .{ .existing = &.{"C:\\Программы\\Git\\bin\\bash.exe"} };
    const resolved = try resolve(alloc, &env, mock.probe());
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Kind.git_bash, resolved.kind);
    try std.testing.expectEqualStrings("C:\\Программы\\Git\\bin\\bash.exe", resolved.argv[0]);
}

test "windows shell: systemProbe sees real files and directories" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const probe = systemProbe();
    try std.testing.expect(probe.exists(probe.ctx, "C:\\Windows\\System32\\cmd.exe"));
    try std.testing.expect(!probe.exists(probe.ctx, "C:\\Windows\\System32"));
    try std.testing.expect(!probe.exists(probe.ctx, "C:\\Windows\\System32\\no-such-file.exe"));

    // Whatever the registry says must be a plausible absolute path.
    if (probe.regGitInstallPath(probe.ctx, std.testing.allocator)) |path| {
        defer std.testing.allocator.free(path);
        try std.testing.expect(path.len > 2);
        try std.testing.expect(path[1] == ':');
    }
}

test "windows shell: systemProbe rejects a path too long for its buffer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // A PATH entry of 3000 bytes must be reported missing, not overflow.
    var long: [3000]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..3], "C:\\");
    const probe = systemProbe();
    try std.testing.expect(!probe.exists(probe.ctx, &long));
}
