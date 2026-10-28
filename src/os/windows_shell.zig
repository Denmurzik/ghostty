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

    /// The installed WSL distributions (read-only registry), allocated with
    /// `alloc`. Defaulted so existing probes compile unchanged.
    wslDistros: *const fn (ctx: ?*anyopaque, alloc: Allocator) []const WslDistro = noDistros,
};

pub const WslDistro = struct { name: []const u8, default: bool };

fn noDistros(_: ?*anyopaque, _: Allocator) []const WslDistro {
    return &.{};
}

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
    const isSep = struct {
        fn f(c: u8) bool {
            return c == '\\' or c == '/';
        }
    }.f;
    const name = "bash.exe";
    if (!std.ascii.endsWithIgnoreCase(path, name)) return false;
    const before = path[0 .. path.len - name.len];
    if (before.len == 0 or !isSep(before[before.len - 1])) return false;
    const dir = before[0 .. before.len - 1];
    inline for (.{ "system32", "sysnative", "syswow64" }) |leaf| {
        if (std.ascii.endsWithIgnoreCase(dir, leaf) and
            dir.len > leaf.len and isSep(dir[dir.len - leaf.len - 1])) return true;
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

pub const Profile = struct {
    /// Stable id: `default`, `git-bash`, `pwsh`, `powershell`, `cmd`,
    /// `wsl:<distro>`.
    id: []const u8,
    name: []const u8,
    kind: enum { default, git_bash, pwsh, powershell, cmd, wsl },

    /// Empty for `default` without a resolved shell; else `argv[0]` is the
    /// absolute path of the executable.
    argv: []const [:0]const u8,

    /// The executable the icon is taken from; empty for `default`.
    icon: []const u8,
};

/// A distro name goes into a command line, so only a conservative set of
/// characters is accepted (the ones `wsl --install` produces).
fn validDistro(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    // Docker's internal distros are not shells.
    return !std.ascii.startsWithIgnoreCase(name, "docker-desktop");
}

/// The shells that can be started: `default` (the configured or resolved
/// default shell), Git Bash, PowerShell 7, Windows PowerShell, cmd and one
/// entry per WSL distro (the default distro first). Everything is allocated
/// with `alloc`; pass an arena.
pub fn profiles(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    probe: Probe,
    default_argv: ?[]const [:0]const u8,
) ![]Profile {
    var list: std.ArrayList(Profile) = .empty;

    try list.append(alloc, .{
        .id = "default",
        .name = "Default",
        .kind = .default,
        .argv = try dupeArgv(alloc, default_argv orelse &.{}),
        .icon = "",
    });

    if (try findGitBash(alloc, env, probe)) |bash| {
        try list.append(alloc, try entry(alloc, "git-bash", "Git Bash", .git_bash, &.{ bash, "--login", "-i" }));
    }
    if (try findPwsh(alloc, env, probe)) |pwsh| {
        try list.append(alloc, try entry(alloc, "pwsh", "PowerShell", .pwsh, &.{ pwsh, "-NoLogo" }));
    }

    const root = nonEmpty(env.get("SystemRoot")) orelse "C:\\Windows";
    const ps = try join(alloc, &.{ root, "System32\\WindowsPowerShell\\v1.0\\powershell.exe" });
    try list.append(alloc, try entry(alloc, "powershell", "Windows PowerShell", .powershell, &.{ ps, "-NoLogo" }));

    const cmd = try findCmd(alloc, env);
    try list.append(alloc, try entry(alloc, "cmd", "Command Prompt", .cmd, &.{cmd}));

    const distros = probe.wslDistros(probe.ctx, alloc);
    const wsl = try join(alloc, &.{ root, "System32\\wsl.exe" });
    for ([_]bool{ true, false }) |want_default| {
        for (distros) |d| {
            if (d.default != want_default or !validDistro(d.name)) continue;
            try list.append(alloc, try entry(
                alloc,
                try std.fmt.allocPrint(alloc, "wsl:{s}", .{d.name}),
                d.name,
                .wsl,
                &.{ wsl, "-d", d.name, "--cd", "~" },
            ));
        }
    }

    return try list.toOwnedSlice(alloc);
}

fn entry(
    alloc: Allocator,
    id: []const u8,
    name: []const u8,
    kind: @FieldType(Profile, "kind"),
    args: []const []const u8,
) !Profile {
    const argv = try alloc.alloc([:0]const u8, args.len);
    for (args, argv) |a, *out| out.* = try alloc.dupeSentinel(u8, a, 0);
    return .{ .id = id, .name = name, .kind = kind, .argv = argv, .icon = args[0] };
}

fn dupeArgv(alloc: Allocator, argv: []const [:0]const u8) ![]const [:0]const u8 {
    const out = try alloc.alloc([:0]const u8, argv.len);
    for (argv, out) |a, *o| o.* = try alloc.dupeSentinel(u8, a, 0);
    return out;
}

/// The probe backed by the real filesystem and registry.
pub fn systemProbe() Probe {
    return .{
        .exists = systemExists,
        .regGitInstallPath = systemRegGitInstallPath,
        .wslDistros = systemWslDistros,
    };
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

extern "advapi32" fn RegOpenKeyExW(
    hkey: windows.HKEY,
    sub_key: windows.LPCWSTR,
    options: windows.DWORD,
    sam: windows.DWORD,
    result: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;
extern "advapi32" fn RegEnumKeyExW(
    hkey: windows.HKEY,
    index: windows.DWORD,
    name: [*]u16,
    name_len: *windows.DWORD,
    reserved: ?*windows.DWORD,
    class: ?[*]u16,
    class_len: ?*windows.DWORD,
    last_write: ?*anyopaque,
) callconv(.winapi) windows.LSTATUS;
extern "advapi32" fn RegCloseKey(hkey: windows.HKEY) callconv(.winapi) windows.LSTATUS;

const KEY_READ: windows.DWORD = 0x20019;
const RRF_RT_REG_DWORD: windows.DWORD = 0x10;

/// Reads `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` (read-only).
fn systemWslDistros(_: ?*anyopaque, alloc: Allocator) []const WslDistro {
    if (comptime builtin.os.tag != .windows) return &.{};
    return readLxss(alloc) catch &.{};
}

/// A distro is usable when its `State` is 1 (installed; other values mean
/// being installed or removed, a missing one is a partial key) and its
/// `BasePath` directory still exists (an unregistered distro may leave a key
/// behind, a deleted directory leaves a profile that fails in wsl.exe).
fn distroInstalled(
    state: ?u32,
    base_path: ?[]const u16,
    existsFn: *const fn (path: []const u16) bool,
) bool {
    if ((state orelse return false) != 1) return false;
    var path = base_path orelse return false;
    // The long-path prefix: the registry keeps it for some distros.
    const long = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    if (std.mem.startsWith(u16, path, long)) path = path[long.len..];
    if (path.len == 0) return false;
    return existsFn(path);
}

fn dirExists(path: []const u16) bool {
    if (comptime builtin.os.tag != .windows) return false;
    var buf: [1024]u16 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const attrs = windows.GetFileAttributesW(@ptrCast(&buf));
    if (attrs == windows.INVALID_FILE_ATTRIBUTES) return false;
    return attrs & windows.FILE_ATTRIBUTE_DIRECTORY != 0;
}

/// Registry GUIDs compare without regard to case (`{ABC...}` vs `{abc...}`).
fn guidEql(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x > 0x7f or y > 0x7f) {
            if (x != y) return false;
            continue;
        }
        if (std.ascii.toLower(@intCast(x)) != std.ascii.toLower(@intCast(y))) return false;
    }
    return true;
}

fn readLxss(alloc: Allocator) ![]const WslDistro {
    const lxss = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
    var key: windows.HKEY = undefined;
    if (RegOpenKeyExW(windows.HKEY_CURRENT_USER, lxss, 0, KEY_READ, &key) != windows.ERROR_SUCCESS) return &.{};
    defer _ = RegCloseKey(key);

    var default_guid: [64]u16 = undefined;
    var default_len: usize = 0;
    {
        var size: windows.DWORD = @sizeOf(@TypeOf(default_guid));
        const status = windows.RegGetValueW(
            key,
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("DefaultDistribution"),
            windows.RRF_RT_REG_SZ,
            null,
            &default_guid,
            &size,
        );
        if (status == windows.ERROR_SUCCESS) default_len = std.mem.sliceTo(default_guid[0 .. size / 2], 0).len;
    }

    var list: std.ArrayList(WslDistro) = .empty;
    errdefer {
        for (list.items) |d| alloc.free(d.name);
        list.deinit(alloc);
    }

    var index: windows.DWORD = 0;
    while (index < 256) : (index += 1) {
        var sub: [256]u16 = undefined;
        var sub_len: windows.DWORD = sub.len;
        if (RegEnumKeyExW(key, index, &sub, &sub_len, null, null, null, null) != windows.ERROR_SUCCESS) break;
        sub[sub_len] = 0;
        const sub_z: [:0]const u16 = sub[0..sub_len :0];

        var name_buf: [256]u16 = undefined;
        var size: windows.DWORD = @sizeOf(@TypeOf(name_buf));
        if (windows.RegGetValueW(
            key,
            sub_z,
            std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"),
            windows.RRF_RT_REG_SZ,
            null,
            &name_buf,
            &size,
        ) != windows.ERROR_SUCCESS) continue;

        var state_value: windows.DWORD = 0;
        var state_size: windows.DWORD = @sizeOf(windows.DWORD);
        const state: ?windows.DWORD = if (windows.RegGetValueW(
            key,
            sub_z,
            std.unicode.utf8ToUtf16LeStringLiteral("State"),
            RRF_RT_REG_DWORD,
            null,
            &state_value,
            &state_size,
        ) == windows.ERROR_SUCCESS) state_value else null;

        var base_buf: [1024]u16 = undefined;
        var base_size: windows.DWORD = @sizeOf(@TypeOf(base_buf));
        const base: ?[]const u16 = if (windows.RegGetValueW(
            key,
            sub_z,
            std.unicode.utf8ToUtf16LeStringLiteral("BasePath"),
            windows.RRF_RT_REG_SZ,
            null,
            &base_buf,
            &base_size,
        ) == windows.ERROR_SUCCESS) std.mem.sliceTo(base_buf[0 .. base_size / 2], 0) else null;
        if (!distroInstalled(state, base, dirExists)) continue;

        const chars = std.mem.sliceTo(name_buf[0 .. size / 2], 0);
        if (chars.len == 0) continue;
        const name = std.unicode.wtf16LeToWtf8Alloc(alloc, chars) catch continue;
        errdefer alloc.free(name);
        try list.append(alloc, .{
            .name = name,
            .default = default_len > 0 and guidEql(sub[0..sub_len], default_guid[0..default_len]),
        });
    }
    return try list.toOwnedSlice(alloc);
}

const MockProbe = struct {
    existing: []const []const u8 = &.{},
    reg: ?[]const u8 = null,
    distros: []const WslDistro = &.{},

    fn probe(self: *MockProbe) Probe {
        return .{
            .ctx = self,
            .exists = exists,
            .regGitInstallPath = regGitInstallPath,
            .wslDistros = wslDistros,
        };
    }

    fn wslDistros(ctx: ?*anyopaque, _: Allocator) []const WslDistro {
        const self: *MockProbe = @ptrCast(@alignCast(ctx.?));
        return self.distros;
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

fn profileIds(alloc: Allocator, list: []const Profile) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (list, 0..) |p, i| {
        if (i > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, p.id);
    }
    return buf.items;
}

test "windows shell profiles: order and ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(&.{
        .{ "ProgramFiles", "C:\\Program Files" },
        .{ "PATH", "C:\\Program Files\\PowerShell\\7" },
        .{ "SystemRoot", "C:\\Windows" },
        .{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" },
    });
    defer env.deinit();
    var mock: MockProbe = .{
        .existing = &.{
            "C:\\Program Files\\Git\\bin\\bash.exe",
            "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        },
        .distros = &.{
            .{ .name = "Debian", .default = false },
            .{ .name = "docker-desktop", .default = false },
            .{ .name = "Ubuntu", .default = true },
        },
    };
    const list = try profiles(a, &env, mock.probe(), null);
    try std.testing.expectEqualStrings(
        "default git-bash pwsh powershell cmd wsl:Ubuntu wsl:Debian",
        try profileIds(a, list),
    );
    const ubuntu = list[5];
    try std.testing.expectEqual(@as(usize, 5), ubuntu.argv.len);
    try std.testing.expectEqualStrings("--cd", ubuntu.argv[3]);
    try std.testing.expectEqualStrings("~", ubuntu.argv[4]);
    try std.testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", ubuntu.argv[0]);
    try std.testing.expectEqual(@as(usize, 0), list[0].argv.len);
}

test "windows shell profiles: odd distro names skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(&.{.{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" }});
    defer env.deinit();
    const long: [65]u8 = @splat('x');
    var mock: MockProbe = .{ .distros = &.{
        .{ .name = "a b", .default = false },
        .{ .name = "Ü", .default = false },
        .{ .name = &long, .default = false },
        .{ .name = "", .default = false },
        .{ .name = "Arch", .default = false },
    } };
    const list = try profiles(a, &env, mock.probe(), null);
    try std.testing.expectEqualStrings("default powershell cmd wsl:Arch", try profileIds(a, list));
}

test "windows shell profiles: no git, no pwsh" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(&.{.{ "COMSPEC", "C:\\Windows\\System32\\cmd.exe" }});
    defer env.deinit();
    var mock: MockProbe = .{};
    const default_argv: []const [:0]const u8 = &.{ "C:\\x\\sh.exe", "-l" };
    const list = try profiles(a, &env, mock.probe(), default_argv);
    try std.testing.expectEqualStrings("default powershell cmd", try profileIds(a, list));
    try std.testing.expectEqual(@as(usize, 2), list[0].argv.len);
    try std.testing.expectEqualStrings(
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        list[1].argv[0],
    );
}

test "windows shell profiles: default probe has no distros" {
    // A probe that does not set `wslDistros` (like every pre-profile caller).
    const probe: Probe = .{ .exists = MockProbe.exists, .regGitInstallPath = MockProbe.regGitInstallPath };
    try std.testing.expectEqual(@as(usize, 0), probe.wslDistros(null, std.testing.allocator).len);
    _ = systemProbe();
}

fn fakeDirExists(path: []const u16) bool {
    return std.mem.eql(u16, path, std.unicode.utf8ToUtf16LeStringLiteral("C:\\wsl\\Ubuntu"));
}

test "windows shell profiles: lxss entry needs State 1 and an existing BasePath" {
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(distroInstalled(1, u("C:\\wsl\\Ubuntu"), fakeDirExists));
    try std.testing.expect(distroInstalled(1, u("\\\\?\\C:\\wsl\\Ubuntu"), fakeDirExists));
    // Partial keys and half-installed distros.
    try std.testing.expect(!distroInstalled(null, u("C:\\wsl\\Ubuntu"), fakeDirExists));
    try std.testing.expect(!distroInstalled(3, u("C:\\wsl\\Ubuntu"), fakeDirExists));
    try std.testing.expect(!distroInstalled(1, null, fakeDirExists));
    try std.testing.expect(!distroInstalled(1, u(""), fakeDirExists));
    // The directory was deleted.
    try std.testing.expect(!distroInstalled(1, u("C:\\wsl\\Gone"), fakeDirExists));
}

test "windows shell profiles: default distro GUID ignores case" {
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(guidEql(u("{AB12-cd}"), u("{ab12-CD}")));
    try std.testing.expect(!guidEql(u("{AB12}"), u("{AB13}")));
    try std.testing.expect(!guidEql(u("{AB12}"), u("{AB12}x")));
}

test "windows shell profiles: WSL launcher with forward slashes" {
    try std.testing.expect(isWslLauncher("C:/Windows/System32/bash.exe"));
    try std.testing.expect(isWslLauncher("C:\\Windows\\Sysnative\\bash.exe"));
    try std.testing.expect(!isWslLauncher("C:/Program Files/Git/bin/bash.exe"));
    try std.testing.expect(!isWslLauncher("C:/Tools/mysystem32/bash.exe"));
}
