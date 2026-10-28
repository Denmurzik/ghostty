//! Command-line overrides (`-e`, `--working-directory`, `--title`, ...) of
//! the Win32 apprt that apply to one new window only. Mirrors the GTK
//! `class/Overrides.zig`.
const Overrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.win32_overrides);

command: ?configpkg.Command = null,
shell_integration: ?configpkg.Config.ShellIntegration = null,
working_directory: ?[:0]const u8 = null,
title: ?[:0]const u8 = null,

/// `--profile=<id>`: the id of a shell profile (see `profiles.zig`). Turned
/// into `command` by `resolve`.
profile: ?[:0]const u8 = null,

pub const ParseError = error{ InvalidArgument, OutOfMemory };

pub const none: Overrides = .{};

pub fn parse(arena: Allocator, args: []const []const u8) ParseError!Overrides {
    var rest: std.ArrayList([:0]const u8) = .empty;
    var result: Overrides = .none;
    var parsed_shell_integration: struct {
        @"shell-integration": ?configpkg.Config.ShellIntegration = null,
    } = .{};

    var e_seen = false;
    for (args) |str| {
        if (e_seen) {
            try rest.append(arena, try arena.dupeSentinel(u8, str, 0));
            continue;
        }

        if (std.mem.eql(u8, str, "-e")) {
            e_seen = true;
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--command=")) |v| {
            var cmd: configpkg.Command = undefined;
            cmd.parseCLI(arena, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            };
            result.command = cmd;
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--shell-integration=")) |v| {
            cli.args.parseIntoField(
                @TypeOf(parsed_shell_integration),
                arena,
                &parsed_shell_integration,
                "shell-integration",
                std.mem.trim(u8, v, &std.ascii.whitespace),
            ) catch |err| {
                log.warn("unable to parse shell integration {s}: {t}", .{ v, err });
            };
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--working-directory=")) |v| {
            result.working_directory = try arena.dupeSentinel(u8, normalizeWorkingDirectory(std.mem.trim(u8, v, &std.ascii.whitespace)), 0);
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--profile=")) |v| {
            result.profile = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--title=")) |v| {
            result.title = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
            continue;
        }
    }

    if (rest.items.len > 0) result.command = .{ .direct = rest.items };
    result.shell_integration = parsed_shell_integration.@"shell-integration";
    return result;
}

/// Explorer's "Open Ghostty here" passes `"%V\."` (a quoted directory with a
/// trailing backslash would escape the quote), which arrives as `C:\.` or
/// `D:\a b\.`. Drops the dot and the separator before it, keeping a drive root.
fn normalizeWorkingDirectory(path: []const u8) []const u8 {
    if (path.len < 2 or path[path.len - 1] != '.') return path;
    const sep = path[path.len - 2];
    if (sep != '\\' and sep != '/') return path;
    const dir = path[0 .. path.len - 2];
    // `C:` + separator is the drive root and keeps its separator.
    if (dir.len == 2 and dir[1] == ':') return path[0 .. path.len - 1];
    return dir;
}

pub const ProfileResolver = struct {
    ctx: *anyopaque,
    commandFor: *const fn (ctx: *anyopaque, id: []const u8) ?configpkg.Command,
};

/// Turns `--profile` into the command of that profile. `-e` / `--command`
/// win over the profile. An id nobody knows is an error, so a typo never
/// silently starts the default shell.
pub fn resolve(
    self: *Overrides,
    arena: Allocator,
    r: ProfileResolver,
) error{ UnknownProfile, OutOfMemory }!void {
    const id = self.profile orelse return;
    if (self.command != null) {
        log.info("-e beats --profile={s}", .{id});
        return;
    }
    const command = r.commandFor(r.ctx, id) orelse return error.UnknownProfile;
    self.command = try command.clone(arena);
}

fn isBashExe(path: []const u8) bool {
    const name = "bash.exe";
    if (!std.ascii.endsWithIgnoreCase(path, name)) return false;
    const before = path[0 .. path.len - name.len];
    return before.len > 0 and (before[before.len - 1] == '\\' or before[before.len - 1] == '/');
}

test "win32 overrides: bash.exe with either separator" {
    try std.testing.expect(isBashExe("C:\\Git\\bin\\bash.exe"));
    try std.testing.expect(isBashExe("C:/Program Files/Git/bin/bash.exe"));
    try std.testing.expect(isBashExe("C:/Git/bin\\BASH.EXE"));
    try std.testing.expect(!isBashExe("C:/Git/bin/notbash.exe"));
    try std.testing.expect(!isBashExe("bash.exe"));
}

test "win32 overrides: git bash keeps the cwd with forward slashes" {
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();
    const argv: []const [:0]const u8 = &.{ "C:/Program Files/Git/bin/bash.exe", "--login", "-i" };
    try keepGitBashCwd(&cfg, .{ .direct = argv });
    try std.testing.expectEqualStrings("1", cfg.env.map.get("CHERE_INVOKING").?);
}

/// A login msys bash changes to $HOME unless `CHERE_INVOKING` is set, which
/// would lose the working directory (the default-shell path does the same).
fn keepGitBashCwd(config: *configpkg.Config, command: configpkg.Command) !void {
    const argv = switch (command) {
        .direct => |a| a,
        .shell => return,
    };
    if (argv.len < 2 or !isBashExe(argv[0])) return;
    if (!std.mem.eql(u8, argv[1], "--login")) return;
    for (config.env.map.keys()) |key| {
        if (std.ascii.eqlIgnoreCase(key, "CHERE_INVOKING")) return;
    }
    try config.env.map.put(config.arenaAlloc(), "CHERE_INVOKING", "1");
}

/// Applies the overrides to a new surface's config copy.
pub fn apply(self: Overrides, config: *configpkg.Config) !void {
    const alloc = config.arenaAlloc();

    if (self.command) |value| {
        config.command = try value.clone(alloc);
        try keepGitBashCwd(config, value);

        if (self.shell_integration) |integration| {
            config.@"shell-integration" = integration;
        } else if (config.@"shell-integration" != .none) {
            config.@"shell-integration" = .detect;
        }
    } else if (self.shell_integration) |value| {
        config.@"shell-integration" = value;
    }

    if (self.working_directory) |wd| {
        var wd_val: configpkg.WorkingDirectory = .{ .path = try alloc.dupe(u8, wd) };
        try wd_val.finalize(alloc);
        config.@"working-directory" = wd_val;
    }
}

/// A launch with arguments starts a separate process, except for a bare
/// `--working-directory=` (Explorer's "Open Ghostty here") and `--profile=`
/// (a profile id, which the receiver looks up among its own profiles). A
/// command is never forwarded, so no pipe request makes another process run a
/// program of its choosing.
pub fn forwardable(args: []const []const u8) bool {
    for (args) |a| {
        if (!std.mem.startsWith(u8, a, "--working-directory=") and
            !std.mem.startsWith(u8, a, "--profile=")) return false;
    }
    return true;
}

test "win32 overrides: working directory with spaces and Cyrillic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o = try parse(arena.allocator(), &.{"--working-directory=C:\\Users\\Анна Ли\\x y"});
    try std.testing.expectEqualStrings("C:\\Users\\Анна Ли\\x y", o.working_directory.?);
}

test "win32 overrides: -e collects the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o = try parse(arena.allocator(), &.{ "-e", "vim", "a b" });
    const direct = o.command.?.direct;
    try std.testing.expectEqual(@as(usize, 2), direct.len);
    try std.testing.expectEqualStrings("vim", direct[0]);
    try std.testing.expectEqualStrings("a b", direct[1]);
}

test "win32 overrides: forwardable" {
    const t = std.testing;
    try t.expect(forwardable(&.{"--working-directory=C:\\a b"}));
    try t.expect(forwardable(&.{}));
    try t.expect(!forwardable(&.{"--title=x"}));
    try t.expect(!forwardable(&.{"--command=x"}));
    try t.expect(!forwardable(&.{"--font-size=20"}));
    try t.expect(!forwardable(&.{ "-e", "x" }));
}

test "win32 overrides: --profile is forwardable" {
    const t = std.testing;
    try t.expect(forwardable(&.{ "--profile=pwsh", "--working-directory=C:\\x" }));
    try t.expect(!forwardable(&.{ "--profile=pwsh", "-e", "x" }));
}

const TestResolver = struct {
    fn commandFor(_: *anyopaque, id: []const u8) ?configpkg.Command {
        if (std.mem.eql(u8, id, "pwsh")) return .{ .direct = &.{"pwsh.exe"} };
        return null;
    }
    fn resolver() ProfileResolver {
        return .{ .ctx = undefined, .commandFor = commandFor };
    }
};

test "win32 overrides: unknown profile" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var o = try parse(arena.allocator(), &.{"--profile=nope"});
    try std.testing.expectError(error.UnknownProfile, o.resolve(arena.allocator(), TestResolver.resolver()));

    var known = try parse(arena.allocator(), &.{"--profile=pwsh"});
    try known.resolve(arena.allocator(), TestResolver.resolver());
    try std.testing.expectEqualStrings("pwsh.exe", known.command.?.direct[0]);

    // No profile: nothing to do.
    var plain = try parse(arena.allocator(), &.{});
    try plain.resolve(arena.allocator(), TestResolver.resolver());
    try std.testing.expect(plain.command == null);
}

test "win32 overrides: -e beats --profile" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Even an unknown profile is not an error when -e is given.
    var o = try parse(arena.allocator(), &.{ "--profile=nope", "-e", "vim" });
    try o.resolve(arena.allocator(), TestResolver.resolver());
    try std.testing.expectEqualStrings("vim", o.command.?.direct[0]);

    var p = try parse(arena.allocator(), &.{ "--profile=pwsh", "-e", "vim" });
    try p.resolve(arena.allocator(), TestResolver.resolver());
    try std.testing.expectEqualStrings("vim", p.command.?.direct[0]);
}

test "win32 overrides: working directory from Explorer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][2][]const u8{
        .{ "--working-directory=C:\\.", "C:\\" },
        .{ "--working-directory=D:\\a b\\.", "D:\\a b" },
        .{ "--working-directory=C:\\Users\\Анна\\#x\\.", "C:\\Users\\Анна\\#x" },
        .{ "--working-directory=C:\\a.b", "C:\\a.b" },
        .{ "--working-directory=C:\\a\\..", "C:\\a\\.." },
    };
    for (cases) |c| {
        const o = try parse(arena.allocator(), &.{c[0]});
        try std.testing.expectEqualStrings(c[1], o.working_directory.?);
    }
}
