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
            result.working_directory = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
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

/// Applies the overrides to a new surface's config copy.
pub fn apply(self: Overrides, config: *configpkg.Config) !void {
    const alloc = config.arenaAlloc();

    if (self.command) |value| {
        config.command = try value.clone(alloc);

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
/// `--working-directory=` (Explorer's "Open Ghostty here"). A command is
/// never forwarded, so no pipe request makes another process run a program.
pub fn forwardable(args: []const []const u8) bool {
    for (args) |a| {
        if (!std.mem.startsWith(u8, a, "--working-directory=")) return false;
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
