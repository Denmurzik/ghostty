const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    elvish,
    fish,
    nushell,
    zsh,
    /// Windows only: PowerShell 7 and Windows PowerShell.
    pwsh,
    /// Windows only: cmd.exe.
    cmd,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: config.Command,
};

/// Set up the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse
        return null;

    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .pwsh => try setupPwsh(
            alloc_arena,
            command,
            resource_dir,
        ),

        .cmd => try setupCmd(alloc_arena, command, env),

        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },
    } orelse return null;

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".field_names) |field| {
        const shell = @field(Shell, field);

        var res: TmpResourcesDir = try .init(shell);
        defer res.deinit();

        const result = try setup(
            alloc,
            res.path,
            .{ .shell = "sh" },
            &env,
            shell,
        );
        try testing.expectEqual(shell, result.?.shell);
    }
}

test "shell integration failure" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );

    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}

/// The name of the executable `arg0` runs: its basename, without the
/// ".exe" suffix on Windows (case-insensitive there).
fn exeName(arg0: []const u8) []const u8 {
    const base = std.fs.path.basename(arg0);
    if (comptime builtin.target.os.tag != .windows) return base;
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) {
        return base[0 .. base.len - 4];
    }
    return base;
}

/// A drive path or UNC path, with either separator.
fn isWindowsAbsolute(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '\\' or path[2] == '/')) return true;
    return std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//");
}

/// Whether `path` lies in the Windows system directories (either separator).
fn isWindowsSystemDir(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len > buf.len) return false;
    for (path, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    const p = buf[0..path.len];
    return std.ascii.findIgnoreCase(p, "\\windows\\system32\\") != null or
        std.ascii.findIgnoreCase(p, "\\windows\\sysnative\\") != null or
        std.ascii.findIgnoreCase(p, "\\windows\\syswow64\\") != null;
}

fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    const arg0 = arg_iter.next() orelse return null;
    const exe = exeName(arg0);

    if (std.mem.eql(u8, "bash", exe)) {
        // A bare "bash" resolves through PATH, where System32 (the WSL
        // launcher, not a bash we can inject into) comes before Git: inject
        // only into an absolute path outside System32.
        if (comptime builtin.target.os.tag == .windows) {
            if (!isWindowsAbsolute(arg0) or isWindowsSystemDir(arg0)) return null;
        }
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }

    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;

    if (comptime builtin.target.os.tag == .windows) {
        if (std.ascii.eqlIgnoreCase(exe, "pwsh") or
            std.ascii.eqlIgnoreCase(exe, "powershell")) return .pwsh;
        if (std.ascii.eqlIgnoreCase(exe, "cmd")) return .cmd;
    }

    return null;
}

test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }

    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const field_names = @typeInfo(@TypeOf(features)).@"struct".field_names;
    const capacity: usize = capacity: {
        comptime var n: usize = field_names.len - 1; // commas
        inline for (field_names) |name| n += name.len;
        n += ":steady".len; // cursor value
        break :capacity n;
    };

    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Sort the fields so that the output is deterministic. This is
    // done at comptime so it has no runtime cost
    const fields_sorted: [field_names.len][]const u8 = comptime fields: {
        var fields_sorted: [field_names.len][]const u8 = field_names.*;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };

    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);

            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }

    if (writer.end > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buf[0..writer.end]);
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: blinking cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: steady cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Accumulates the arguments of an injected command: a `.direct` argv, or
/// a space-joined `.shell` string.
const ArgList = struct {
    alloc: Allocator,
    direct: bool,
    list: std.ArrayList([:0]const u8) = .empty,

    fn appendArg(self: *ArgList, arg: []const u8) Allocator.Error!void {
        if (arg.len == 0) return;
        try self.list.append(self.alloc, try self.alloc.dupeSentinel(u8, arg, 0));
    }

    fn finish(self: *ArgList) !config.Command {
        if (self.direct) return .{ .direct = try self.list.toOwnedSlice(self.alloc) };
        var joined: std.Io.Writer.Allocating = .init(self.alloc);
        for (self.list.items, 0..) |arg, i| {
            if (i > 0) try joined.writer.writeByte(' ');
            try joined.writer.writeAll(arg);
        }
        return .{ .shell = try joined.toOwnedSliceSentinel(0) };
    }
};

/// Setup the PowerShell integration (Windows): the shell starts with
/// `-NoExit -Command ". '<ghostty.ps1>'"`, which runs after the user's
/// profile and wraps `prompt` and the Enter key to emit OSC 2 titles (the
/// working directory at the prompt, the command while it runs). Nothing on
/// disk changes. Returns null for non-interactive invocations.
fn setupPwsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
) !?config.Command {
    var args: ArgList = .{ .alloc = alloc, .direct = true };

    var iter = try command.argIterator(alloc);
    defer iter.deinit();
    if (iter.next()) |exe| try args.appendArg(exe) else return null;
    var skip_value = false;
    while (iter.next()) |arg| {
        // A command, script or stdin script is not an interactive session.
        if (pwshRunsCode(arg)) return null;
        if (skip_value) {
            skip_value = false;
        } else if (arg.len > 0 and arg[0] != '-' and arg[0] != '/') {
            // The first bare argument is a script file.
            return null;
        } else {
            skip_value = pwshTakesValue(arg);
        }
        try args.appendArg(arg);
    }

    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.mem.print(
        &script_path_buf,
        "{s}\\shell-integration\\pwsh\\ghostty.ps1",
        .{std.mem.trimEnd(u8, resource_dir, "\\/")},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        return null;
    }

    // Single quotes inside the path double, as PowerShell requires.
    var quoted: std.Io.Writer.Allocating = .init(alloc);
    // The text is read and compiled, not dot-sourced as a file, so the
    // execution policy (Restricted, AllSigned, Mark-of-the-Web) does not apply.
    try quoted.writer.writeAll(". ([scriptblock]::Create([IO.File]::ReadAllText('");
    for (script_path) |c| {
        if (c == '\'') try quoted.writer.writeByte('\'');
        try quoted.writer.writeByte(c);
    }
    try quoted.writer.writeAll("')))");

    try args.appendArg("-NoExit");
    try args.appendArg("-Command");
    try args.appendArg(quoted.written());
    return try args.finish();
}

/// Whether a PowerShell parameter takes the next argument as its value.
fn pwshTakesValue(arg: []const u8) bool {
    if (arg.len < 2 or (arg[0] != '-' and arg[0] != '/')) return false;
    const name = arg[1..];
    const takes = [_][]const u8{
        "workingdirectory", "executionpolicy",   "configurationname", "custompipename",
        "inputformat",      "outputformat",      "settingsfile",      "windowstyle",
        "psconsolefile",    "configurationfile",
    };
    for (takes) |t| {
        if (std.mem.indexOfScalar(u8, name, ':') == null and
            name.len <= t.len and std.ascii.eqlIgnoreCase(name, t[0..name.len])) return true;
    }
    return false;
}

/// Whether a PowerShell argument asks to run code instead of a session.
fn pwshRunsCode(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "-")) return true;
    if (arg.len < 2 or (arg[0] != '-' and arg[0] != '/')) return false;
    const name = arg[1..];
    // PowerShell accepts any prefix of a parameter name.
    const runs = [_][]const u8{ "command", "file", "encodedcommand", "version", "help", "?", "stdin" };
    for (runs) |r| {
        if (name.len <= r.len and std.ascii.eqlIgnoreCase(name, r[0..name.len])) return true;
    }
    return false;
}

/// Setup the cmd.exe integration (Windows): the PROMPT gets a leading OSC 2
/// with the current directory (`$P`) and an OSC 7 with it. cmd cannot tell
/// us which command is running; conhost's own "<cmd.exe> - <command>" title
/// covers that.
fn setupCmd(
    alloc: Allocator,
    command: config.Command,
    env: *EnvMap,
) !?config.Command {
    const features = env.get("GHOSTTY_SHELL_FEATURES") orelse return null;
    if (std.mem.indexOf(u8, features, "title") == null) return null;

    var iter = try command.argIterator(alloc);
    defer iter.deinit();
    _ = iter.next() orelse return null;
    while (iter.next()) |arg| {
        // /c and /r run one command and exit.
        if (arg.len >= 2 and arg[0] == '/' and (arg[1] == 'c' or arg[1] == 'C' or arg[1] == 'r' or arg[1] == 'R')) return null;
    }
    // OSC 7 follows the title, as `kitty-shell-cwd://` with no host (this
    // machine): core keeps that path raw, so a name with spaces or a # needs
    // no encoding.
    const prefix = "$e]2;$P$e\\$e]7;kitty-shell-cwd:///$P$e\\";
    const current = env.get("PROMPT") orelse "$P$G";
    if (std.mem.startsWith(u8, current, prefix)) return try command.clone(alloc);
    try env.put("PROMPT", try std.mem.concat(alloc, u8, &.{ prefix, current }));
    return try command.clone(alloc);
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // On Windows a direct argv stays direct: a flattened string would split
    // the path of bash.exe at a space (it lives under "Program Files").
    var args: ArgList = .{
        .alloc = alloc,
        .direct = builtin.target.os.tag == .windows,
    };

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try args.appendArg(exe);
    } else return null;
    try args.appendArg("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try args.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try args.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try args.appendArg(remaining_arg);
            }
            break;
        } else {
            try args.appendArg(arg);
        }
    }

    // Preserve an existing ENV value. We're about to overwrite it.
    if (env.get("ENV")) |v| {
        try env.put("GHOSTTY_BASH_ENV", v);
    }

    // Set our new ENV to point to our integration script.
    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.mem.print(
        &script_path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        _ = env.swapRemove("GHOSTTY_BASH_ENV");
        return null;
    }

    try env.put("GHOSTTY_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(global.io(), &environ_map, &home_buf)) |home| {
            var histfile_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const histfile = try std.mem.print(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return try args.finish();
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", try flat(alloc, command.?));
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", try flat(alloc, command.?));
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", try flat(alloc, command.?));
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", try flat(alloc, command.?));
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", try flat(alloc, command.?));
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("ENV", "env.sh");

    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("GHOSTTY_BASH_ENV").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", try flat(alloc, command.?));
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", try flat(alloc, command.?));
    }
}

test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close(global.io());

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_path);

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state_buf: [4096]u8 = undefined;
    var stack_alloc_state: std.heap.BufferFirstAllocator = .init(&stack_alloc_state_buf, alloc);
    const stack_alloc = stack_alloc_state.allocator();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );

    return true;
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try alloc.print("{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}

/// Set up automatic Nushell shell integration. This works by adding our
/// shell resource directory to the `XDG_DATA_DIRS` environment variable,
/// which Nushell will use to load `nushell/vendor/autoload/ghostty.nu`.
///
/// We then add `--execute 'use ghostty ...'` to the nu command line to
/// automatically enable our shelll features.
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Add our XDG_DATA_DIRS entry (for nushell/vendor/autoload/). This
    // makes our 'ghostty' module automatically available, even if any
    // of the later checks abort the rest of our automatic integration.
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;

    var stack_fallback_buf: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buf, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.allocator());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;

    // Tell nu to immediately "use" all of the exported functions in our
    // 'ghostty' module.
    //
    // We can consider making this more specific based on the set of
    // enabled shell features (e.g. `use ghostty sudo`). At the moment,
    // shell features are all runtime-guarded in the nushell script.
    try cmd.appendArg("--execute 'use ghostty *'");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration module.
    //
    // Unsupported options:
    //  -c / --command      -c is always non-interactive
    //  --lsp               --lsp starts the language server
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeSentinel(u8, cmd.buffer.written(), 0) };
}

test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use ghostty *'", command.?.shell);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}

test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}

test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Preserve an existing ZDOTDIR value. We're about to overwrite it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR to point to our shell resource directory.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close(global.io());
    try env.put("ZDOTDIR", integ_path);

    return try command.clone(alloc);
}

test "zsh" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("GHOSTTY_ZSH_ZDOTDIR") == null);
}

test "zsh: ZDOTDIR" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("ZDOTDIR", "$HOME/.config/zsh");

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("GHOSTTY_ZSH_ZDOTDIR").?);
}

test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

test "windows: shells are detected by image name" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const git: config.Command = .{ .direct = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" } };
    const pwsh: config.Command = .{ .direct = &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" } };
    const ps5: config.Command = .{ .direct = &.{"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"} };
    const cmd: config.Command = .{ .direct = &.{"C:\\WINDOWS\\system32\\CMD.EXE"} };
    const wsl: config.Command = .{ .direct = &.{"C:\\Windows\\System32\\bash.exe"} };
    try testing.expectEqual(.bash, try detectShell(alloc, git));
    try testing.expect(try detectShell(alloc, .{ .shell = "bash" }) == null);
    try testing.expect(try detectShell(alloc, .{ .shell = "C:/Windows/System32/bash.exe" }) == null);
    try testing.expect(try detectShell(alloc, .{ .shell = "c:\\windows\\SysNative\\bash.exe" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"C:/Program Files/Git/bin/bash.exe\" --login" }));
    try testing.expectEqual(.pwsh, try detectShell(alloc, pwsh));
    try testing.expectEqual(.pwsh, try detectShell(alloc, ps5));
    try testing.expectEqual(.cmd, try detectShell(alloc, cmd));
    try testing.expect(try detectShell(alloc, wsl) == null);
}

/// Test helper: the arguments of `command` joined by spaces.
fn flat(alloc: Allocator, command: config.Command) ![]const u8 {
    switch (command) {
        .shell => |s| return s,
        .direct => |args| return try std.mem.join(alloc, " ", args),
    }
}

test "windows: bash from a quoted shell string stays direct" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();

    const quoted: config.Command = .{ .shell = "\"C:/Program Files/Git/bin/bash.exe\" --login" };
    const command = (try setupBash(alloc, quoted, res.path, &env)).?;
    try testing.expectEqual(@as(usize, 3), command.direct.len);
    try testing.expectEqualStrings("C:/Program Files/Git/bin/bash.exe", command.direct[0]);
    try testing.expectEqualStrings("--posix", command.direct[1]);
    try testing.expectEqualStrings("--login", command.direct[2]);
}

test "windows: bash keeps a direct argv" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();

    const git: config.Command = .{ .direct = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" } };
    const command = (try setupBash(alloc, git, res.path, &env)).?;
    try testing.expectEqual(@as(usize, 4), command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", command.direct[0]);
    try testing.expectEqualStrings("--posix", command.direct[1]);
    try testing.expectEqualStrings("--login", command.direct[2]);
    try testing.expectEqualStrings("-i", command.direct[3]);
}

test "windows: pwsh" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.pwsh);
    defer res.deinit();

    const pwsh: config.Command = .{ .direct = &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" } };
    const command = (try setupPwsh(alloc, pwsh, res.path)).?;
    try testing.expectEqual(@as(usize, 5), command.direct.len);
    try testing.expectEqualStrings("-NoLogo", command.direct[1]);
    try testing.expectEqualStrings("-NoExit", command.direct[2]);
    try testing.expectEqualStrings("-Command", command.direct[3]);
    try testing.expect(std.mem.startsWith(u8, command.direct[4], ". ([scriptblock]::Create([IO.File]::ReadAllText('"));
    try testing.expect(std.mem.endsWith(u8, command.direct[4], "\\shell-integration\\pwsh\\ghostty.ps1')))"));

    // A positional script (and the value of a parameter before it) is code to run.
    const script: config.Command = .{ .direct = &.{ "pwsh.exe", "-NoLogo", "-WorkingDirectory", "C:\\x", "run.ps1" } };
    try testing.expect(try setupPwsh(alloc, script, res.path) == null);
    const with_value: config.Command = .{ .direct = &.{ "pwsh.exe", "-WorkingDirectory", "C:\\x" } };
    try testing.expect(try setupPwsh(alloc, with_value, res.path) != null);

    // Code to run is not a session.
    inline for (.{ "-Command", "-c", "-File", "-f", "-EncodedCommand", "-", "-Version" }) |arg| {
        const code: config.Command = .{ .direct = &.{ "pwsh.exe", arg, "x" } };
        try testing.expect(try setupPwsh(alloc, code, res.path) == null);
    }
    const norc: config.Command = .{ .direct = &.{ "pwsh.exe", "-NoProfile", "-NoLogo" } };
    try testing.expect(try setupPwsh(alloc, norc, res.path) != null);
}

test "windows: pwsh: missing resources" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pwsh: config.Command = .{ .direct = &.{"pwsh.exe"} };
    try testing.expect(try setupPwsh(alloc, pwsh, "C:\\no\\such\\dir") == null);
}

test "windows: cmd prompt" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();
    const cmd: config.Command = .{ .direct = &.{"C:\\Windows\\System32\\cmd.exe"} };

    // The title feature is off (the variable is absent or lacks it): untouched.
    try testing.expect(try setupCmd(alloc, cmd, &env) == null);
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor:blink");
    try testing.expect(try setupCmd(alloc, cmd, &env) == null);
    try testing.expect(env.get("PROMPT") == null);
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor:blink,title");
    try testing.expect(try setupCmd(alloc, cmd, &env) != null);
    // The title, then OSC 7 with no host (raw `kitty-shell-cwd` path).
    const prefix = "$e]2;$P$e\\$e]7;kitty-shell-cwd:///$P$e\\";
    try testing.expectEqualStrings(prefix ++ "$P$G", env.get("PROMPT").?);

    // Set up again, or with a prompt of the user's: prefixed once.
    try testing.expect(try setupCmd(alloc, cmd, &env) != null);
    try testing.expectEqualStrings(prefix ++ "$P$G", env.get("PROMPT").?);
    try env.put("PROMPT", "$T $P$G");
    try testing.expect(try setupCmd(alloc, cmd, &env) != null);
    try testing.expectEqualStrings(prefix ++ "$T $P$G", env.get("PROMPT").?);

    // /c runs one command: no prompt shows.
    var other = EnvMap.init(alloc);
    defer other.deinit();
    try other.put("GHOSTTY_SHELL_FEATURES", "title");
    const run: config.Command = .{ .direct = &.{ "cmd.exe", "/c", "dir" } };
    try testing.expect(try setupCmd(alloc, run, &other) == null);
    try testing.expect(other.get("PROMPT") == null);
}

/// Test helper that creates a temporary resources directory with shell integration paths.
const TmpResourcesDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,
    shell_path: []const u8,

    fn init(shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.mem.print(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.createDirPath(std.testing.io, relative_shell_path);

        const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);

        const shell_path = try std.testing.allocator.print(
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer std.testing.allocator.free(shell_path);

        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/bash/ghostty.bash",
                .data = "",
            }),
            .pwsh => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/pwsh/ghostty.ps1",
                .data = "",
            }),
            else => {},
        }

        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }

    fn deinit(self: *TmpResourcesDir) void {
        std.testing.allocator.free(self.shell_path);
        std.testing.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
