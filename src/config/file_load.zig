const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try defaultXdgPathEnv(global.io(), alloc, &environ_map);
}

fn defaultXdgPathEnv(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    return try xdgConfigFile(io, alloc, environ_map, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
///
/// Windows has no legacy config file name.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try legacyDefaultXdgPathEnv(global.io(), alloc, &environ_map);
}

fn legacyDefaultXdgPathEnv(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    return try xdgConfigFile(io, alloc, environ_map, "config");
}

fn xdgConfigFile(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    comptime name: []const u8,
) ![]const u8 {
    const dir = try internal_os.xdg.config(io, alloc, environ_map, .{ .subdir = "ghostty" });
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, name });
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try preferredXdgPathEnv(global.io(), alloc, &environ_map);
}

/// Same as `preferredXdgPath` but uses the given environment.
pub fn preferredXdgPathEnv(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPathEnv(io, alloc, environ_map);
    if (open(io, xdg_path)) |f| {
        f.close(io);
        return xdg_path;
    } else |_| {}

    // Windows has exactly one config path, no legacy fallback.
    if (comptime builtin.target.os.tag == .windows) return xdg_path;

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPathEnv(io, alloc, environ_map);
    if (open(io, legacy_xdg_path)) |f| {
        f.close(io);
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy path and XDG path both don't exist. Return the
    // new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    // If the app support path exists, use that.
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(global.io(), app_support_path)) |f| {
        f.close(global.io());
        return app_support_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(global.io(), legacy_app_support_path)) |f| {
        f.close(global.io());
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}

    // Legacy path and app support path both don't exist. Return the
    // new one.
    alloc.free(legacy_app_support_path);
    return app_support_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.target.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(global.io(), app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(global.io(), xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close(global.io());
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close(global.io());
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc),
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close(io);

    const stat = file.stat(io) catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

test "windows config: legacy config file is ignored" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ghostty");
    try tmp.dir.writeFile(io, .{ .sub_path = "ghostty/config", .data = "font-size = 20\n" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(base);

    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("USERPROFILE", "C:\\Users\\Анна Ли");
    try environ_map.put("XDG_CONFIG_HOME", base);

    // Only the legacy file exists: it must not be picked.
    {
        const path = try preferredXdgPathEnv(io, alloc, &environ_map);
        defer alloc.free(path);
        try testing.expect(std.mem.endsWith(u8, path, "\\ghostty\\config.ghostty"));
        try testing.expect(std.mem.startsWith(u8, path, base));
    }

    // Without XDG_CONFIG_HOME the base is %USERPROFILE%\.config.
    _ = environ_map.swapRemove("XDG_CONFIG_HOME");
    {
        const path = try preferredXdgPathEnv(io, alloc, &environ_map);
        defer alloc.free(path);
        try testing.expectEqualStrings(
            "C:\\Users\\Анна Ли\\.config\\ghostty\\config.ghostty",
            path,
        );
    }
}
