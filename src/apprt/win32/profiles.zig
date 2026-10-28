//! Shell profile cache (owner: M5 Task 2). Shell until then.
const std = @import("std");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");

/// Placeholder until Task 2 adds `windows_shell.Profile`; Task 2 swaps this
/// alias for `windows_shell.Profile`.
pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    argv: []const [:0]const u8 = &.{},
    icon: []const u8 = "",
};

pub const Cache = struct {
    list: ?[]const Profile = null,
    arena: std.heap.ArenaAllocator.State = .{},
};

/// Builds on first use.
pub fn get(app: *App) []const Profile {
    _ = app;
    return &.{};
}

/// Rebuilds (menu open).
pub fn refresh(app: *App) []const Profile {
    _ = app;
    return &.{};
}

/// Null = unknown id.
pub fn commandFor(app: *App, id: []const u8) ?configpkg.Command {
    _ = app;
    _ = id;
    return null;
}

test "win32 profiles: shell has no profiles" {
    var cache: Cache = .{};
    try std.testing.expect(cache.list == null);
    _ = &cache;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("loaded");
    try jw.write(app.profiles.list != null);
    try jw.endObject();
}
