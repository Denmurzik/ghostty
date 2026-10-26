//! Single-instance identity: the per-user, per-session, per-class and
//! per-elevation IPC pipe name, and the checks that decide whether a
//! process on the other end of the pipe is "us" (same user, same
//! elevation). Task 20 adds the single-instance decision on top.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const win32 = @import("win32");
const protocol = @import("ipc/protocol.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_instance);

const kernel32 = win32.kernel32;
const advapi32 = win32.advapi32;
const HANDLE = win32.foundation.HANDLE;

/// The window class of the default instance; Debug builds get their own
/// so a debug build never forwards to (or hijacks) a release instance.
pub fn defaultClass() []const u8 {
    return if (builtin.mode == .debug)
        "com.mitchellh.ghostty-debug"
    else
        "com.mitchellh.ghostty";
}

/// Opens the token of `process` (a handle with at least
/// `PROCESS_QUERY_LIMITED_INFORMATION`) for querying.
fn openToken(process: HANDLE) ?HANDLE {
    var token: HANDLE = undefined;
    if (advapi32.OpenProcessToken(process, advapi32.TOKEN_QUERY, &token) == 0) return null;
    return token;
}

/// Backing store for a `TOKEN_USER` (header plus the largest SID, 68 bytes).
const UserBuf = struct {
    bytes: [256]u8 align(8) = undefined,

    fn sid(self: *const UserBuf) *anyopaque {
        const tu: *const advapi32.TOKEN_USER = @ptrCast(&self.bytes);
        return tu.User.Sid.?;
    }
};

fn queryUser(token: HANDLE, buf: *UserBuf) bool {
    var len: u32 = 0;
    return advapi32.GetTokenInformation(token, advapi32.TokenUser, &buf.bytes, buf.bytes.len, &len) != 0;
}

fn queryElevated(token: HANDLE) ?bool {
    var elev: advapi32.TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var len: u32 = 0;
    if (advapi32.GetTokenInformation(token, advapi32.TokenElevation, &elev, @sizeOf(advapi32.TOKEN_ELEVATION), &len) == 0) return null;
    return elev.TokenIsElevated != 0;
}

/// The SID of the current user as "S-1-5-…". Caller owns the result.
pub fn currentUserSid(alloc: Allocator) ![]u8 {
    const token = openToken(kernel32.GetCurrentProcess()) orelse return error.TokenQueryFailed;
    defer _ = kernel32.CloseHandle(token);
    var buf: UserBuf = .{};
    if (!queryUser(token, &buf)) return error.TokenQueryFailed;

    var wide: ?[*:0]u16 = null;
    if (advapi32.ConvertSidToStringSidW(buf.sid(), &wide) == 0) return error.TokenQueryFailed;
    defer _ = kernel32.LocalFree(wide);
    return util.utf8(alloc, std.mem.span(wide.?));
}

var elevated_cache: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 no, 2 yes

/// Whether the current process runs elevated (TokenElevation), cached.
/// An unreadable token counts as elevated: the stricter pipe name and
/// security descriptor are the safe side.
pub fn isElevated() bool {
    switch (elevated_cache.load(.acquire)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const result = blk: {
        const token = openToken(kernel32.GetCurrentProcess()) orelse break :blk true;
        defer _ = kernel32.CloseHandle(token);
        break :blk queryElevated(token) orelse true;
    };
    elevated_cache.store(if (result) 2 else 1, .release);
    return result;
}

/// `\\.\pipe\ghostty-<sid>-<session>-<u|a>-<class>` as a null-terminated
/// UTF-16 string for the Win32 pipe APIs. Caller owns the result.
pub fn pipeNameFor(alloc: Allocator, class: ?[]const u8) ![:0]u16 {
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    var session: u32 = 0;
    if (kernel32.ProcessIdToSessionId(kernel32.GetCurrentProcessId(), &session) == 0) {
        log.warn("ProcessIdToSessionId failed err={}", .{kernel32.GetLastError()});
    }
    var buf: [512]u8 = undefined;
    const name = try protocol.pipeName(&buf, sid, session, class orelse defaultClass(), isElevated());
    return util.utf16z(alloc, name);
}

/// Whether `pid` runs as the current user at the same elevation as us.
pub fn peerMatches(pid: u32) bool {
    return peerMatchesAs(pid, isElevated());
}

/// `peerMatches` against an explicit own elevation (the server keeps its
/// own copy, which tests flip to provoke a mismatch).
pub fn peerMatchesAs(pid: u32, own_elevated: bool) bool {
    const proc = kernel32.OpenProcess(kernel32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = kernel32.CloseHandle(proc);
    const peer_token = openToken(proc) orelse return false;
    defer _ = kernel32.CloseHandle(peer_token);
    const own_token = openToken(kernel32.GetCurrentProcess()) orelse return false;
    defer _ = kernel32.CloseHandle(own_token);

    var peer_user: UserBuf = .{};
    var own_user: UserBuf = .{};
    if (!queryUser(peer_token, &peer_user) or !queryUser(own_token, &own_user)) return false;
    if (advapi32.EqualSid(peer_user.sid(), own_user.sid()) == 0) return false;

    const peer_elevated = queryElevated(peer_token) orelse return false;
    return peer_elevated == own_elevated;
}

test "win32 instance: pipe name has sid, session, class and elevation marker" {
    const alloc = std.testing.allocator;
    const name = try pipeNameFor(alloc, null);
    defer alloc.free(name);
    const utf8 = try util.utf8(alloc, name);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "\\\\.\\pipe\\ghostty-S-1-5-"));
    var session: u32 = 0;
    try std.testing.expect(kernel32.ProcessIdToSessionId(kernel32.GetCurrentProcessId(), &session) != 0);
    var want_buf: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "-{d}-{c}-com.mitchellh.ghostty", .{
        session,
        @as(u8, if (isElevated()) 'a' else 'u'),
    });
    try std.testing.expect(std.mem.indexOf(u8, utf8, want) != null);
}

test "win32 instance: peerMatches own pid" {
    try std.testing.expect(peerMatches(kernel32.GetCurrentProcessId()));
    try std.testing.expect(!peerMatches(4));
}
