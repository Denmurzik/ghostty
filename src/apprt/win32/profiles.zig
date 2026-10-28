//! The shell profiles offered by the new-tab menu and `--profile=<id>`. The
//! list is built from the shells found on this machine (see
//! `windows_shell.profiles`) on first use and rebuilt when the menu opens.
const std = @import("std");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const windows_shell = @import("../../os/windows_shell.zig");
const App = @import("App.zig");
const Overrides = @import("Overrides.zig");
const jumplist = @import("jumplist.zig");

const log = std.log.scoped(.win32_profiles);

pub const Profile = windows_shell.Profile;

pub const Cache = struct {
    list: ?[]const Profile = null,
    arena: std.heap.ArenaAllocator.State = .{},
};

/// Builds on first use.
pub fn get(app: *App) []const Profile {
    return app.profiles.list orelse refresh(app);
}

/// Rebuilds (menu open).
pub fn refresh(app: *App) []const Profile {
    const alloc = app.core_app.alloc;
    deinit(app);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    const list = build(app, arena.allocator()) catch |err| {
        log.warn("unable to list the shell profiles err={}", .{err});
        arena.deinit();
        return &.{};
    };
    app.profiles = .{ .list = list, .arena = arena.state };
    jumplist.profilesChanged(app);
    return list;
}

pub fn deinit(app: *App) void {
    var arena = app.profiles.arena.promote(app.core_app.alloc);
    arena.deinit();
    app.profiles = .{};
}

fn build(app: *App, arena: std.mem.Allocator) ![]Profile {
    var env = try global.environMap();
    defer env.deinit();

    // The default profile is the shell the config resolved to.
    const default_argv: ?[]const [:0]const u8 = if (app.config.command) |c| switch (c) {
        .direct => |argv| argv,
        .shell => null,
    } else null;
    return try windows_shell.profiles(arena, &env, windows_shell.systemProbe(), default_argv);
}

/// Null = unknown id. The command points into the cache or the config;
/// `Overrides.resolve` clones it.
pub fn commandFor(app: *App, id: []const u8) ?configpkg.Command {
    for (get(app)) |p| {
        if (!std.mem.eql(u8, p.id, id)) continue;
        if (p.kind == .default) {
            if (app.config.command) |c| return c;
            return if (p.argv.len > 0) .{ .direct = p.argv } else null;
        }
        return .{ .direct = p.argv };
    }
    return null;
}

pub fn resolver(app: *App) Overrides.ProfileResolver {
    return .{ .ctx = app, .commandFor = resolverCommandFor };
}

fn resolverCommandFor(ctx: *anyopaque, id: []const u8) ?configpkg.Command {
    const app: *App = @ptrCast(@alignCast(ctx));
    return commandFor(app, id);
}

test "win32 profiles: cache starts empty" {
    var cache: Cache = .{};
    try std.testing.expect(cache.list == null);
    _ = &cache;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("loaded");
    try jw.write(app.profiles.list != null);
    try jw.objectField("ids");
    try jw.beginArray();
    for (app.profiles.list orelse &.{}) |p| try jw.write(p.id);
    try jw.endArray();
    try jw.endObject();
}
