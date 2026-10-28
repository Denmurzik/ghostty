//! Single-instance identity: the per-user, per-session, per-class and
//! per-elevation IPC pipe name, and the checks that decide whether a
//! process on the other end of the pipe is "us" (same user, same
//! elevation), and the single-instance decision: whether a launch hands
//! itself to the running instance, and the request that does it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const client = @import("ipc/client.zig");
const protocol = @import("ipc/protocol.zig");
const Overrides = @import("Overrides.zig");
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
    return internal_os.windows.tokenIsElevated(token);
}

/// The mandatory integrity level (the last sub-authority of the label SID)
/// of `token`; null when it cannot be read.
fn queryIntegrity(token: HANDLE) ?u32 {
    var buf: [256]u8 align(8) = undefined;
    var len: u32 = 0;
    if (advapi32.GetTokenInformation(token, advapi32.TokenIntegrityLevel, &buf, buf.len, &len) == 0) return null;
    const label: *const advapi32.TOKEN_MANDATORY_LABEL = @ptrCast(&buf);
    const sid = label.Label.Sid orelse return null;
    const count = advapi32.GetSidSubAuthorityCount(sid).*;
    if (count == 0) return null;
    return advapi32.GetSidSubAuthority(sid, count - 1).*;
}

/// Two processes of one user at different integrity levels are not peers: a
/// low-integrity process must not pass for the instance (and read launches).
fn sameIntegrity(a: ?u32, b: ?u32) bool {
    return a != null and b != null and a.? == b.?;
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

/// Whether the current process runs elevated (TokenElevation), cached; see
/// `os.windows.isElevated`.
pub const isElevated = internal_os.windows.isElevated;

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
    if (peer_elevated != own_elevated) return false;
    return sameIntegrity(queryIntegrity(peer_token), queryIntegrity(own_token));
}

/// `args` without `--class=`: the class selects the instance (it is part of
/// the pipe name), it is not something to forward or to count as an argument.
pub fn withoutClass(arena: Allocator, args: []const []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--class=")) continue;
        try list.append(arena, arg);
    }
    return list.items;
}

/// How long a forwarded launch waits for the running instance. The request
/// itself expires 250 ms earlier (see `client.request`), so a late server
/// never opens a window after this process has started its own.
const forward_timeout_ms = 1500;

/// Whether a launch hands itself to the running instance. A command is never
/// forwarded (nor any argument but `--working-directory=`): such a launch
/// runs its own process. `initial_command` is a command from the config.
pub fn shouldForward(
    mode: configpkg.Config.WindowsSingleInstance,
    args: []const []const u8,
    initial_command: bool,
) bool {
    return switch (mode) {
        .false => false,
        .true, .detect => !initial_command and Overrides.forwardable(args),
    };
}

/// Makes a relative `--working-directory=` absolute against `cwd`: the
/// running instance has another current directory. `home`, `inherit`,
/// `~/...` and absolute (drive or UNC) paths are kept. Other arguments are
/// copied as they are.
pub fn absolutizeWorkingDirectory(
    arena: Allocator,
    args: []const []const u8,
    cwd: []const u8,
) ![]const []const u8 {
    const result = try arena.alloc([]const u8, args.len);
    for (args, result) |arg, *out| {
        out.* = arg;
        const raw = std.mem.cutPrefix(u8, arg, "--working-directory=") orelse continue;
        const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (value.len == 0 or
            std.mem.eql(u8, value, "home") or
            std.mem.eql(u8, value, "inherit") or
            std.mem.startsWith(u8, value, "~") or
            std.fs.path.isAbsoluteWindows(value)) continue;
        const joined = try std.fs.path.join(arena, &.{ cwd, value });
        out.* = try std.fmt.allocPrint(arena, "--working-directory={s}", .{joined});
    }
    return result;
}

/// `refused`: the running instance rejected an unknown `--profile=`; the
/// message is in `Sent.message`, the launch must not start a window.
pub const ForwardResult = enum { forwarded, no_server, not_our_server, failed, refused };

pub const Sent = struct {
    result: ForwardResult,
    /// The server's stderr text for a refused request; owned by the caller.
    message: ?[]u8 = null,
};

/// Sends `req` to the instance behind `name` and waits for its answer.
pub fn send(alloc: Allocator, name: [:0]const u16, req: protocol.Request, timeout_ms: u32) Sent {
    const payload = protocol.encodeRequest(alloc, req) catch return .{ .result = .failed };
    defer alloc.free(payload);
    const bytes = client.request(alloc, name, payload, timeout_ms) catch |err| return .{
        .result = switch (err) {
            error.NoServer => .no_server,
            error.NotOurServer => .not_our_server,
            else => blk: {
                log.warn("IPC request failed err={}", .{err});
                break :blk .failed;
            },
        },
    };
    defer alloc.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const response = protocol.parseResponse(arena.allocator(), bytes) catch return .{ .result = .failed };
    if (response.code == .ok) return .{ .result = .forwarded };
    return .{
        .result = .failed,
        .message = alloc.dupe(u8, response.stderr) catch null,
    };
}

/// Asks the running instance behind `name` for a new window. `args` are
/// already forwardable (`shouldForward`) and absolutized.
pub fn forwardNewWindow(alloc: Allocator, name: [:0]const u16, args: []const []const u8) Sent {
    var sent = send(alloc, name, .{
        .v = protocol.version,
        .op = "new-window",
        .args = args,
    }, forward_timeout_ms);
    if (sent.message) |m| {
        log.warn("running instance refused the new window: {s}", .{m});
        if (isProfileRefusal(m)) sent.result = .refused;
    }
    return sent;
}

/// The server's answer to an unknown `--profile=` (see `ipc/ops.zig`).
fn isProfileRefusal(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "unknown profile");
}

test "win32 instance: profile refusal" {
    try std.testing.expect(isProfileRefusal("unknown profile: typo"));
    try std.testing.expect(!isProfileRefusal("unable to create a window"));
}

test "win32 instance: forward decision" {
    const W = configpkg.Config.WindowsSingleInstance;
    const none: []const []const u8 = &.{};
    try std.testing.expect(shouldForward(W.detect, none, false));
    try std.testing.expect(shouldForward(W.detect, &.{"--working-directory=C:\\x"}, false));
    try std.testing.expect(!shouldForward(W.detect, &.{"--title=x"}, false));
    try std.testing.expect(!shouldForward(W.detect, &.{"--font-size=20"}, false));
    try std.testing.expect(!shouldForward(W.true, &.{"--command=x"}, false));
    try std.testing.expect(!shouldForward(W.true, &.{ "-e", "vim" }, false));
    try std.testing.expect(shouldForward(W.true, none, false));
    try std.testing.expect(!shouldForward(W.detect, none, true));
    try std.testing.expect(!shouldForward(W.true, none, true));
    try std.testing.expect(!shouldForward(W.false, none, false));
}

test "win32 instance: working directory is absolutized" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rel = try absolutizeWorkingDirectory(a, &.{"--working-directory=sub dir"}, "C:\\a");
    try std.testing.expectEqualStrings("--working-directory=C:\\a\\sub dir", rel[0]);
    const cyr = try absolutizeWorkingDirectory(a, &.{"--working-directory=Рабочая папка"}, "C:\\a");
    try std.testing.expectEqualStrings("--working-directory=C:\\a\\Рабочая папка", cyr[0]);
    const abs = try absolutizeWorkingDirectory(a, &.{"--working-directory=D:\\x y"}, "C:\\a");
    try std.testing.expectEqualStrings("--working-directory=D:\\x y", abs[0]);
    const unc = try absolutizeWorkingDirectory(a, &.{"--working-directory=\\\\srv\\share"}, "C:\\a");
    try std.testing.expectEqualStrings("--working-directory=\\\\srv\\share", unc[0]);
    const keep = try absolutizeWorkingDirectory(a, &.{ "--working-directory=home", "--title=t" }, "C:\\a");
    try std.testing.expectEqualStrings("--working-directory=home", keep[0]);
    try std.testing.expectEqualStrings("--title=t", keep[1]);
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

test "win32 instance: integrity levels must be equal" {
    try std.testing.expect(sameIntegrity(0x2000, 0x2000));
    try std.testing.expect(!sameIntegrity(0x1000, 0x2000));
    try std.testing.expect(!sameIntegrity(0x3000, 0x2000));
    try std.testing.expect(!sameIntegrity(null, 0x2000));
    try std.testing.expect(!sameIntegrity(0x2000, null));
    try std.testing.expect(!sameIntegrity(null, null));

    const own = openToken(kernel32.GetCurrentProcess()).?;
    defer _ = kernel32.CloseHandle(own);
    const level = queryIntegrity(own);
    try std.testing.expect(level != null);
    try std.testing.expect(level.? >= 0x1000);
}

test "win32 instance: the class is not an argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = try withoutClass(arena.allocator(), &.{ "--class=x", "--working-directory=C:\\a", "--class=y" });
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("--working-directory=C:\\a", out[0]);
    try std.testing.expect(shouldForward(.detect, try withoutClass(arena.allocator(), &.{"--class=x"}), false));
}

test "win32 instance: peerMatches own pid" {
    try std.testing.expect(peerMatches(kernel32.GetCurrentProcessId()));
    try std.testing.expect(!peerMatches(4));
}

test "win32 instance: the pipe name carries the --class" {
    const alloc = std.testing.allocator;
    const custom = try pipeNameFor(alloc, "ghostty-e2e-1");
    defer alloc.free(custom);
    const default = try pipeNameFor(alloc, null);
    defer alloc.free(default);
    const utf8 = try util.utf8(alloc, custom);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.endsWith(u8, utf8, "-ghostty-e2e-1"));
    try std.testing.expect(!std.mem.eql(u16, custom, default));
}
