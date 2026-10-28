//! A small registry writer and reader for the CLI actions that install
//! per-user integration (`+install-explorer-integration`). The root is a
//! parameter: the real run passes `HKEY_CURRENT_USER`, tests pass the root of
//! a private application hive (`openTestHive`, `RegLoadAppKeyW`), which is a
//! file that no other process and no part of the real registry sees.
//!
//! Only values of type `REG_SZ`. The functions take UTF-8; the declarations
//! are local so that this file needs no `win32` import and no COM.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const Root = windows.HKEY;

pub const Error = error{
    RegistryFailed,
    InvalidUtf8,
    OutOfMemory,
};

const log = std.log.scoped(.windows_registry);

const LSTATUS = i32;
const ERROR_SUCCESS: LSTATUS = 0;
const ERROR_FILE_NOT_FOUND: LSTATUS = 2;
const ERROR_MORE_DATA: LSTATUS = 234;

const REG_SZ: u32 = 1;
const REG_EXPAND_SZ: u32 = 2;
const REG_OPTION_NON_VOLATILE: u32 = 0;
const KEY_QUERY_VALUE: u32 = 0x0001;
const KEY_SET_VALUE: u32 = 0x0002;
const KEY_ALL_ACCESS: u32 = 0xF003F;

/// `HKEY_CURRENT_USER`.
pub const hkcu: Root = @ptrFromInt(0x80000001);

const advapi32 = struct {
    extern "advapi32" fn RegCreateKeyExW(
        hKey: Root,
        lpSubKey: [*:0]const u16,
        Reserved: u32,
        lpClass: ?[*:0]const u16,
        dwOptions: u32,
        samDesired: u32,
        lpSecurityAttributes: ?*anyopaque,
        phkResult: *Root,
        lpdwDisposition: ?*u32,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegOpenKeyExW(
        hKey: Root,
        lpSubKey: [*:0]const u16,
        ulOptions: u32,
        samDesired: u32,
        phkResult: *Root,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegSetValueExW(
        hKey: Root,
        lpValueName: ?[*:0]const u16,
        Reserved: u32,
        dwType: u32,
        lpData: [*]const u8,
        cbData: u32,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegQueryValueExW(
        hKey: Root,
        lpValueName: ?[*:0]const u16,
        lpReserved: ?*u32,
        lpType: ?*u32,
        lpData: ?[*]u8,
        lpcbData: ?*u32,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegDeleteTreeW(hKey: Root, lpSubKey: ?[*:0]const u16) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegCloseKey(hKey: Root) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegLoadAppKeyW(
        lpFile: [*:0]const u16,
        phkResult: *Root,
        samDesired: u32,
        dwOptions: u32,
        reserved: u32,
    ) callconv(.winapi) LSTATUS;
};

fn wide(alloc: Allocator, s: []const u8) Error![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
    };
}

fn check(what: []const u8, status: LSTATUS) Error!void {
    if (status == ERROR_SUCCESS) return;
    log.warn("{s} failed status={d}", .{ what, status });
    return error.RegistryFailed;
}

/// Closes a root from `openTestHive`. Never call it on `hkcu`.
pub fn close(root: Root) void {
    _ = advapi32.RegCloseKey(root);
}

/// Sets a `REG_SZ` value, creating the key (and its parents) as needed.
/// `name` null is the `(default)` value.
pub fn setString(root: Root, subkey: []const u8, name: ?[]const u8, value: []const u8) Error!void {
    return setTyped(root, subkey, name, value, REG_SZ);
}

fn setTyped(root: Root, subkey: []const u8, name: ?[]const u8, value: []const u8, kind: u32) Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const subkey_w = try wide(alloc, subkey);
    const name_w: ?[:0]u16 = if (name) |n| try wide(alloc, n) else null;
    const value_w = try wide(alloc, value);

    var key: Root = undefined;
    try check("RegCreateKeyExW", advapi32.RegCreateKeyExW(
        root,
        subkey_w.ptr,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        null,
        &key,
        null,
    ));
    defer _ = advapi32.RegCloseKey(key);

    try check("RegSetValueExW", advapi32.RegSetValueExW(
        key,
        if (name_w) |n| n.ptr else null,
        0,
        kind,
        @ptrCast(value_w.ptr),
        @intCast((value_w.len + 1) * @sizeOf(u16)),
    ));
}

/// The `REG_SZ` value, or null when the key or the value does not exist.
/// Caller owns the result.
pub fn getString(alloc: Allocator, root: Root, subkey: []const u8, name: ?[]const u8) Error!?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const subkey_w = try wide(scratch, subkey);
    const name_w: ?[:0]u16 = if (name) |n| try wide(scratch, n) else null;

    var key: Root = undefined;
    const open = advapi32.RegOpenKeyExW(root, subkey_w.ptr, 0, KEY_QUERY_VALUE, &key);
    if (open == ERROR_FILE_NOT_FOUND) return null;
    try check("RegOpenKeyExW", open);
    defer _ = advapi32.RegCloseKey(key);

    const name_ptr: ?[*:0]const u16 = if (name_w) |n| n.ptr else null;
    var size: u32 = 0;
    var kind: u32 = 0;
    const probe = advapi32.RegQueryValueExW(key, name_ptr, null, &kind, null, &size);
    if (probe == ERROR_FILE_NOT_FOUND) return null;
    try check("RegQueryValueExW", probe);
    // A `REG_EXPAND_SZ` (a hand edit or a script wrote it) reads as its
    // text, unexpanded.
    if (kind != REG_SZ and kind != REG_EXPAND_SZ) return null;

    // +1 unit: the stored data need not carry its terminator.
    const units = size / @sizeOf(u16);
    const buf = try scratch.alloc(u16, units + 1);
    var got: u32 = size;
    try check("RegQueryValueExW", advapi32.RegQueryValueExW(key, name_ptr, null, null, @ptrCast(buf.ptr), &got));
    const got_units = got / @sizeOf(u16);
    const text = std.mem.sliceTo(buf[0..got_units], 0);
    return std.unicode.utf16LeToUtf8Alloc(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

/// Deletes the key and everything under it. A key that does not exist is not
/// an error.
pub fn deleteTree(root: Root, subkey: []const u8) Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const subkey_w = try wide(arena.allocator(), subkey);

    const status = advapi32.RegDeleteTreeW(root, subkey_w.ptr);
    if (status == ERROR_FILE_NOT_FOUND) return;
    try check("RegDeleteTreeW", status);
}

/// Loads (creating it when absent) a private application hive from `path`
/// and returns its root. Nothing written through it reaches the real
/// registry. Release with `close`; Windows then still keeps the file and its
/// `.LOG1`/`.LOG2` for a moment, the caller deletes them.
pub fn openTestHive(path: []const u8) Error!Root {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const path_w = try wide(arena.allocator(), path);

    var root: Root = undefined;
    try check("RegLoadAppKeyW", advapi32.RegLoadAppKeyW(path_w.ptr, &root, KEY_ALL_ACCESS, 0, 0));
    return root;
}

test "windows registry: app hive round trip" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const explorer = @import("windows_explorer.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    const hive = try std.fmt.allocPrint(alloc, "{s}\\t.hive", .{base});
    defer alloc.free(hive);

    const root = try openTestHive(hive);
    var closed = false;
    defer if (!closed) close(root);

    const writes = try explorer.installWrites(alloc, "C:\\Program Files\\Ghostty\\ghostty.exe");
    defer explorer.freeWrites(alloc, writes);
    for (writes) |w| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, w.subkey });
        defer alloc.free(full);
        try setString(root, full, w.name, w.value);
    }
    for (writes) |w| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, w.subkey });
        defer alloc.free(full);
        const got = (try getString(alloc, root, full, w.name)).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(w.value, got);
    }

    // REG_EXPAND_SZ reads as its unexpanded text.
    try setTyped(root, "Software\\Classes\\Probe", "exp", "%SystemRoot%\\x", REG_EXPAND_SZ);
    const exp = (try getString(alloc, root, "Software\\Classes\\Probe", "exp")).?;
    defer alloc.free(exp);
    try std.testing.expectEqualStrings("%SystemRoot%\\x", exp);

    // Unicode survives; a missing value or key reads as null.
    try setString(root, "Software\\Classes\\Probe", "Имя", "Анна \u{1F600}");
    const uni = (try getString(alloc, root, "Software\\Classes\\Probe", "Имя")).?;
    defer alloc.free(uni);
    try std.testing.expectEqualStrings("Анна \u{1F600}", uni);
    try std.testing.expect((try getString(alloc, root, "Software\\Classes\\Probe", "nope")) == null);
    try std.testing.expect((try getString(alloc, root, "Software\\Nope", null)) == null);

    for (explorer.key_names) |key| {
        const full = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ explorer.verbs_root, key });
        defer alloc.free(full);
        try deleteTree(root, full);
        try deleteTree(root, full); // already gone: fine
        try std.testing.expect((try getString(alloc, root, full, null)) == null);
    }
    try deleteTree(root, "Software\\Classes\\Probe");

    close(root);
    closed = true;

    // The hive is released a moment after the last handle closes.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        var all_gone = true;
        for ([_][]const u8{ "t.hive", "t.hive.LOG1", "t.hive.LOG2" }) |name| {
            tmp.dir.deleteFile(std.testing.io, name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    all_gone = false;
                    continue;
                },
            };
        }
        if (all_gone) break;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    for ([_][]const u8{ "t.hive", "t.hive.LOG1", "t.hive.LOG2" }) |name| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, name, .{}));
    }
}
