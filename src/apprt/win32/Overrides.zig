//! Command-line overrides (`-e`, `--working-directory`, `--title`, ...) of
//! the Win32 apprt that apply to one new window only. Stub: Task 5.
const Overrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

command: ?configpkg.Command = null,
shell_integration: ?configpkg.Config.ShellIntegration = null,
working_directory: ?[:0]const u8 = null,
title: ?[:0]const u8 = null,

pub const ParseError = error{ InvalidArgument, OutOfMemory };

pub const none: Overrides = .{};

pub fn parse(arena: Allocator, args: []const []const u8) ParseError!Overrides {
    _ = arena;
    _ = args;
    return .none;
}

pub fn apply(self: Overrides, config: *configpkg.Config) !void {
    _ = self;
    _ = config;
}

pub fn forwardable(args: []const []const u8) bool {
    _ = args;
    return false;
}
