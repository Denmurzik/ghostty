//! Spawning panes for split-window and respawn-pane (owner: M4 task 10).
//!
//! `plan` decides what a pane runs (R-M4-5); the surface applies it
//! (`Surface.CreateOptions.tmux`). Pure apart from the `Probe`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const commands = @import("commands.zig");
const sh_command = @import("../../../tmux_shim/sh_command.zig");
const windows_shell = @import("../../../os/windows_shell.zig");

pub const Plan = struct {
    /// null: the configured command (as for a normal split).
    argv: ?[]const [:0]const u8,
    cwd: []const u8,
    client_env: []const []const u8,
    /// `-e` entries, then the `env` assignments of the one-liner parser.
    extra_env: []const []const u8,
};

pub const Probe = struct {
    exists: *const fn (path: []const u8) bool,
    /// Git Bash for the client environment ("K=V" entries), or null.
    git_bash: *const fn (arena: Allocator, env: []const []const u8) ?[]const u8,
};

/// Where `plan` reports why it failed.
pub const Diag = struct { dir: []const u8 = "" };

pub const git_bash_var = "CLAUDE_CODE_GIT_BASH_PATH";

/// What the pane at `s` runs.
///  * exactly `cat`: the idle placeholder `<exe dir>\tmux.exe __idle`;
///  * an empty command: the configured one;
///  * else `bash -c <string>` when Git Bash resolves (the client's
///    `CLAUDE_CODE_GIT_BASH_PATH` if that file exists, else the usual
///    search); else the one-liner parser (`Unsupported` if it refuses).
/// cwd: `-c`, else the `cd` target (parser path only), else the client cwd.
/// A `cd` target that does not exist fails with `NoDirectory` (`diag.dir`
/// names it), as `cd X && prog` would not run `prog`.
///
/// The `-c` string always reaches bash quoted: an argument without
/// whitespace or a quote is left bare by `writeCommandLine`, and Cygwin then
/// re-parses it (globbing, stripping quotes and backslashes, `@file`).
/// Path conversion is deliberately left as in a real MSYS tmux: bash converts
/// `/c/x` style arguments for a native child (no `MSYS_NO_PATHCONV`), which
/// the pane's Windows-path command strings do not trigger.
pub fn plan(
    arena: Allocator,
    s: commands.Spawn,
    exe_dir: []const u8,
    probe: Probe,
    diag: *Diag,
) error{ Unsupported, NoDirectory, OutOfMemory }!Plan {
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(arena, s.extra_env);
    var cwd: []const u8 = s.start_dir orelse s.cwd;

    const command = s.command orelse "";
    var argv: ?[]const [:0]const u8 = null;
    if (command.len == 0) {
        // The configured command.
    } else if (std.mem.eql(u8, command, "cat")) {
        const exe = try std.fs.path.join(arena, &.{ exe_dir, "tmux.exe" });
        argv = try dupeArgv(arena, &.{ exe, "__idle" });
    } else if (gitBash(arena, s.client_env, probe)) |bash| {
        argv = try dupeArgv(arena, &.{ bash, "-c", try quoteForCygwin(arena, command) });
    } else {
        const parsed = sh_command.parse(arena, command) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            error.OutOfMemory => return error.OutOfMemory,
        };
        argv = try dupeArgv(arena, parsed.argv);
        try extra.appendSlice(arena, parsed.env);
        if (s.start_dir == null) {
            if (parsed.cwd) |c| {
                if (!probe.exists(c)) {
                    diag.dir = c;
                    return error.NoDirectory;
                }
                cwd = c;
            }
        }
    }

    return .{
        .argv = argv,
        .cwd = cwd,
        .client_env = s.client_env,
        .extra_env = extra.items,
    };
}

/// `command` with a trailing blank when it has no whitespace or quote, so
/// that the command line quotes it (bash ignores the blank).
fn quoteForCygwin(arena: Allocator, command: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, command, " \t\n\"") != null) return command;
    return std.fmt.allocPrint(arena, "{s} ", .{command});
}

fn dupeArgv(arena: Allocator, args: []const []const u8) Allocator.Error![]const [:0]const u8 {
    const out = try arena.alloc([:0]const u8, args.len);
    for (args, out) |a, *o| o.* = try arena.dupeSentinel(u8, a, 0);
    return out;
}

fn gitBash(arena: Allocator, client_env: []const []const u8, probe: Probe) ?[]const u8 {
    for (client_env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(e[0..eq], git_bash_var)) continue;
        const path = e[eq + 1 ..];
        if (path.len > 0 and probe.exists(path)) return path;
    }
    return probe.git_bash(arena, client_env);
}

/// The probe backed by the real filesystem, registry and environment.
pub fn systemProbe() Probe {
    return .{ .exists = systemExists, .git_bash = systemGitBash };
}

fn systemExists(path: []const u8) bool {
    return windows_shell.systemProbe().exists(null, path);
}

fn systemGitBash(arena: Allocator, client_env: []const []const u8) ?[]const u8 {
    var map = std.process.Environ.Map.init(arena);
    for (client_env) |e| {
        if (e.len == 0 or e[0] == '=') continue;
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        map.put(e[0..eq], e[eq + 1 ..]) catch return null;
    }
    const found = windows_shell.findGitBash(arena, &map, windows_shell.systemProbe()) catch return null;
    return found;
}

// ---- tests -----------------------------------------------------------

const t = std.testing;

const FakeProbe = struct {
    var existing: []const []const u8 = &.{};
    var bash: ?[]const u8 = null;

    fn fakeExists(path: []const u8) bool {
        for (existing) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
    fn fakeBash(_: Allocator, _: []const []const u8) ?[]const u8 {
        return bash;
    }
    const probe: Probe = .{ .exists = fakeExists, .git_bash = fakeBash };
};

fn spawnOf(command: ?[]const u8) commands.Spawn {
    return .{ .command = command, .cwd = "C:\\work", .client_env = &.{}, .extra_env = &.{}, .start_dir = null };
}

fn planT(arena: Allocator, s: commands.Spawn, exe_dir: []const u8, probe: Probe) !Plan {
    var diag: Diag = .{};
    return plan(arena, s, exe_dir, probe, &diag);
}

fn expectArgv(want: []const []const u8, got: ?[]const [:0]const u8) !void {
    try t.expectEqual(want.len, got.?.len);
    for (want, got.?) |w, g| try t.expectEqualStrings(w, g);
}

test "win32 tmux spawn: cat is the idle placeholder" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    const p = try planT(arena.allocator(), spawnOf("cat"), "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "C:\\g\\tmux.exe", "__idle" }, p.argv);
    try t.expectEqualStrings("C:\\work", p.cwd);
}

test "win32 tmux spawn: CLAUDE_CODE_GIT_BASH_PATH wins" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    FakeProbe.existing = &.{"D:\\mine\\bash.exe"};
    defer FakeProbe.existing = &.{};
    var s = spawnOf("echo hi");
    s.client_env = &.{ "A=1", "claude_code_git_bash_path=D:\\mine\\bash.exe" };
    const p = try planT(arena.allocator(), s, "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "D:\\mine\\bash.exe", "-c", "echo hi" }, p.argv);

    // A path that does not exist falls back to the search.
    s.client_env = &.{"CLAUDE_CODE_GIT_BASH_PATH=D:\\gone\\bash.exe"};
    const q = try planT(arena.allocator(), s, "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "C:\\Git\\bin\\bash.exe", "-c", "echo hi" }, q.argv);
}

test "win32 tmux spawn: Git Bash -c" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    const p = try planT(arena.allocator(), spawnOf("cd '/c/x y' && ls"), "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "C:\\Git\\bin\\bash.exe", "-c", "cd '/c/x y' && ls" }, p.argv);
    // The string runs in bash: no cd target is lifted out.
    try t.expectEqualStrings("C:\\work", p.cwd);
}

const recon_command =
    \\cd 'C:\D\den4ik\Ghostty' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_ATTRIBUTION_PROJECT='' 'C:\Users\user\.local\bin\claude.exe' --agent-id researcher@my-team --model claude-sonnet-5-5
;

test "win32 tmux spawn: no Git Bash uses the parser" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = null;
    FakeProbe.existing = &.{"C:\\D\\den4ik\\Ghostty"};
    defer FakeProbe.existing = &.{};
    var s = spawnOf(recon_command);
    s.extra_env = &.{"E=1"};
    const p = try planT(arena.allocator(), s, "C:\\g", FakeProbe.probe);
    try t.expectEqualStrings("C:\\Users\\user\\.local\\bin\\claude.exe", p.argv.?[0]);
    try t.expectEqualStrings("--agent-id", p.argv.?[1]);
    try t.expectEqualStrings("C:\\D\\den4ik\\Ghostty", p.cwd);
    try t.expectEqual(@as(usize, 4), p.extra_env.len);
    try t.expectEqualStrings("E=1", p.extra_env[0]);
    try t.expectEqualStrings("CLAUDECODE=1", p.extra_env[1]);
    try t.expectEqualStrings("CLAUDE_CODE_ATTRIBUTION_PROJECT=", p.extra_env[3]);
}

test "win32 tmux spawn: -c start dir beats client cwd" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = null;
    var s = spawnOf("'C:\\p\\x.exe'");
    s.start_dir = "C:\\start";
    const p = try planT(arena.allocator(), s, "C:\\g", FakeProbe.probe);
    try t.expectEqualStrings("C:\\start", p.cwd);

    // ... and beats the cd target of the parser path.
    var s2 = spawnOf("cd 'C:\\cd' && 'C:\\p\\x.exe'");
    s2.start_dir = "C:\\start";
    const p2 = try planT(arena.allocator(), s2, "C:\\g", FakeProbe.probe);
    try t.expectEqualStrings("C:\\start", p2.cwd);

    FakeProbe.existing = &.{"C:\\cd"};
    defer FakeProbe.existing = &.{};
    // Without -c the cd target beats the client cwd.
    const p3 = try planT(arena.allocator(), spawnOf("cd 'C:\\cd' && 'C:\\p\\x.exe'"), "C:\\g", FakeProbe.probe);
    try t.expectEqualStrings("C:\\cd", p3.cwd);
}

test "win32 tmux spawn: empty command is the configured one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    const p = try planT(arena.allocator(), spawnOf(""), "C:\\g", FakeProbe.probe);
    try t.expect(p.argv == null);
    const q = try planT(arena.allocator(), spawnOf(null), "C:\\g", FakeProbe.probe);
    try t.expect(q.argv == null);
}

test "win32 tmux spawn: unparsable without Git Bash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = null;
    try t.expectError(error.Unsupported, planT(arena.allocator(), spawnOf("a | b"), "C:\\g", FakeProbe.probe));
    try t.expectError(error.Unsupported, planT(arena.allocator(), spawnOf("echo $HOME"), "C:\\g", FakeProbe.probe));
}

test "win32 tmux spawn: -c string is always quoted for Cygwin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    const p = try planT(arena.allocator(), spawnOf("x*"), "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "C:\\Git\\bin\\bash.exe", "-c", "x* " }, p.argv);
    // Whitespace or a double quote makes the command line quote it already.
    const q = try planT(arena.allocator(), spawnOf("echo\"a\""), "C:\\g", FakeProbe.probe);
    try expectArgv(&.{ "C:\\Git\\bin\\bash.exe", "-c", "echo\"a\"" }, q.argv);
}

test "win32 tmux spawn: missing cd target fails on the parser path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    FakeProbe.bash = null;
    FakeProbe.existing = &.{};
    var diag: Diag = .{};
    try t.expectError(error.NoDirectory, plan(arena.allocator(), spawnOf("cd 'C:\\gone' && 'C:\\p\\x.exe'"), "C:\\g", FakeProbe.probe, &diag));
    try t.expectEqualStrings("C:\\gone", diag.dir);
    // With Git Bash the cd runs inside bash, which reports it itself.
    FakeProbe.bash = "C:\\Git\\bin\\bash.exe";
    _ = try planT(arena.allocator(), spawnOf("cd 'C:\\gone' && x"), "C:\\g", FakeProbe.probe);
}

// ---- real Git Bash -----------------------------------------------------

const Command = @import("../../../Command.zig");
const internal_os = @import("../../../os/main.zig");
const global = @import("../../../global.zig");
const windows = internal_os.windows;
const file_mod = @import("../../../os/file.zig");

/// Runs `command` as the pane would (plan -> Command.direct ->
/// writeCommandLine -> CreateProcessW) in the directory `<tmp>\<td>\тест m4`
/// and returns what it wrote (stdout and stderr) and its exit code. The
/// directory holds a file `xa`, a file `foo` and `args.bat` (echoes its
/// arguments). Caller frees `out`.
const Run = struct { out: []u8, code: u32 };

fn runPane(alloc: Allocator, command: []const u8, git_dir: []const u8) !Run {
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    const io = global.io();
    try td.dir.createDir(io, "\xd1\x82\xd0\xb5\xd1\x81\xd1\x82 m4", .default_dir);
    const files = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "xa", .data = "" },
        .{ .name = "foo", .data = "echo AT-FILE-EXPANDED" },
        .{ .name = "args.bat", .data = "@echo ARGS: %*\r\n" },
    };
    for (files) |file| {
        const path = try std.fmt.allocPrint(alloc, "\xd1\x82\xd0\xb5\xd1\x81\xd1\x82 m4/{s}", .{file.name});
        defer alloc.free(path);
        const fh = try td.dir.createFile(io, path, .{});
        defer fh.close(io);
        try fh.writePositionalAll(io, file.data, 0);
    }

    const tmp = try file_mod.allocTmpDir(alloc, global.environ());
    defer file_mod.freeTmpDir(alloc, tmp);
    const dir = try std.fs.path.join(alloc, &.{ tmp, td.name(), "\xd1\x82\xd0\xb5\xd1\x81\xd1\x82 m4" });
    defer alloc.free(dir);
    // The command names the directory (a) and the git root.
    const full = try std.mem.replaceOwned(u8, alloc, command, "<dir>", dir);
    defer alloc.free(full);
    const printf_path = try std.fs.path.join(alloc, &.{ git_dir, "usr", "bin", "printf.exe" });
    defer alloc.free(printf_path);
    const printenv_path = try std.fs.path.join(alloc, &.{ git_dir, "usr", "bin", "printenv.exe" });
    defer alloc.free(printenv_path);
    const full1 = try std.mem.replaceOwned(u8, alloc, full, "<printf>", printf_path);
    defer alloc.free(full1);
    const full2 = try std.mem.replaceOwned(u8, alloc, full1, "<printenv>", printenv_path);
    defer alloc.free(full2);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // The client's environment: ours.
    var env_map = try global.environMap();
    defer env_map.deinit();
    var env_list: std.ArrayList([]const u8) = .empty;
    for (env_map.keys(), env_map.values()) |k, v| {
        try env_list.append(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{s}={s}", .{ k, v }));
    }
    var s = spawnOf(full2);
    s.client_env = env_list.items;
    const p = try planT(arena.allocator(), s, "C:\\g", systemProbe());
    const argv = p.argv orelse return error.TestUnexpectedResult;
    std.debug.print("bash -c argv: {s} | {s} | [{s}]\n", .{ argv[0], argv[1], argv[2] });

    const out_file = try td.dir.createFile(io, "out.txt", .{ .read = true });
    defer out_file.close(io);
    if (windows.exp.kernel32.SetHandleInformation(out_file.handle, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) == windows.FALSE)
        return error.SetHandleFailed;

    var cmd: Command = .{
        .path = argv[0],
        .args = argv,
        .cwd = try arena.allocator().dupeSentinel(u8, dir, 0),
        .stdout = out_file,
        .stderr = out_file,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.start(alloc);
    // Bounded: a case that hangs must not hold the test lock.
    const waited = windows.exp.kernel32.WaitForSingleObject(cmd.pid.?, 20_000);
    if (waited == windows.WAIT_TIMEOUT) {
        cmd.killChild() catch {};
        cmd.closeProcess();
        return error.TestTimeout;
    }
    const exit = try cmd.wait(true);
    cmd.closeProcess();

    const size = (try out_file.stat(io)).size;
    const data = try alloc.alloc(u8, size);
    errdefer alloc.free(data);
    if (try out_file.readPositionalAll(io, data, 0) != size) return error.TestUnexpectedResult;
    return .{ .out = data, .code = exit.Exited };
}

test "win32 tmux spawn: bash -c receives Claude's command line verbatim" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const bash = systemGitBashFromProcess(arena.allocator()) orelse return error.SkipZigTest;
    // <git>\bin\bash.exe -> <git>
    const git_dir = std.fs.path.dirname(std.fs.path.dirname(bash).?).?;

    const cases = [_]struct { cmd: []const u8, want: []const u8 }{
        .{
            // "$A" is expanded by the outer bash before `env` runs.
            .cmd = "cd '<dir>' && env GHOSTTY_T10_A='x y' GHOSTTY_T10_B='it'\"'\"'s' '<printf>' '%s|' 'a b' 'C:\\p q' \"$GHOSTTY_T10_A\" \"$GHOSTTY_T10_B\"",
            .want = "a b|C:\\p q|||",
        },
        .{
            // Claude's pattern: `env K=v prog`, the child sees quoted values.
            .cmd = "cd '<dir>' && env GHOSTTY_T10_A='x y' GHOSTTY_T10_B='it'\"'\"'s' '<printenv>' GHOSTTY_T10_A GHOSTTY_T10_B",
            .want = "x y\nit's\n",
        },
        .{
            // Quoting of assignments through the shell itself.
            .cmd = "cd '<dir>' && GHOSTTY_T10_A='x y' GHOSTTY_T10_B='it'\"'\"'s' && '<printf>' '%s|' \"$GHOSTTY_T10_A\" \"$GHOSTTY_T10_B\"",
            .want = "x y|it's|",
        },
        .{ .cmd = "'<printf>' '%s|' 'C:\\a\\'\"'\"'b'", .want = "C:\\a\\'b|" },
        .{ .cmd = "'<printf>' '%s|' '*'", .want = "*|" },
        // No whitespace and no double quote: the command line would leave
        // the -c string bare, and Cygwin would re-parse it.
        .{ .cmd = "echo${IFS}'C:\\x\\y'", .want = "C:\\x\\y\n" },
        .{ .cmd = "echo${IFS}'x*'", .want = "x*\n" }, // the cwd holds `xa`
        .{ .cmd = "echo${IFS}'a\\'", .want = "a\\\n" },
    };
    for (cases) |c| {
        const got = try runPane(t.allocator, c.cmd, git_dir);
        defer t.allocator.free(got.out);
        try t.expectEqual(@as(u32, 0), got.code);
        try t.expectEqualStrings(c.want, got.out);
    }

    // `@name` must not be replaced by the contents of the file `name`:
    // bash gets the text and fails to find a command of that name.
    {
        const got = try runPane(t.allocator, "@foo", git_dir);
        defer t.allocator.free(got.out);
        try t.expectEqual(@as(u32, 127), got.code);
        try t.expect(std.mem.indexOf(u8, got.out, "@foo") != null);
    }

    // Intended difference from a pane whose program is MSYS itself: as in a
    // real MSYS tmux, bash converts MSYS-style arguments for a NATIVE child
    // (`MSYS_NO_PATHCONV` is not set). The teammate's own command string uses
    // Windows paths, which conversion leaves alone.
    {
        const got = try runPane(t.allocator, "'<dir>\\args.bat' '/c/x' '--opt=/c/y'", git_dir);
        defer t.allocator.free(got.out);
        try t.expectEqual(@as(u32, 0), got.code);
        try t.expectEqualStrings("ARGS: C:/x --opt=C:/y\r\n", got.out);
    }
}

fn systemGitBashFromProcess(arena: Allocator) ?[]const u8 {
    var map = global.environMap() catch return null;
    defer map.deinit();
    const found = windows_shell.findGitBash(arena, &map, windows_shell.systemProbe()) catch return null;
    return found;
}
