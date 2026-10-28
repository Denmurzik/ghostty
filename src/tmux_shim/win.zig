//! The Win32 surface of `tmux.exe`: its own `extern` declarations, so the
//! exe imports only kernel32 (and ntdll through std) and never pulls in
//! pkg/win32, user32, libc or the C runtime.
const std = @import("std");

pub const HANDLE = std.os.windows.HANDLE;
pub const DWORD = u32;
pub const BOOL = i32;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE = null,
};

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_APPEND_DATA: DWORD = 0x0004;
pub const FILE_SHARE_READ: DWORD = 1;
pub const FILE_SHARE_WRITE: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_TYPE_PIPE: DWORD = 3;
pub const SECURITY_SQOS_PRESENT: DWORD = 0x00100000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x00010000;

pub const PIPE_ACCESS_DUPLEX: DWORD = 3;
pub const PIPE_TYPE_BYTE: DWORD = 0;
pub const PIPE_READMODE_BYTE: DWORD = 0;
pub const PIPE_WAIT: DWORD = 0;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 8;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_IO_PENDING: DWORD = 997;

pub const WAIT_OBJECT_0: DWORD = 0;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: DWORD = @sizeOf(PROCESS_MEMORY_COUNTERS),
    PageFaultCount: DWORD = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};

pub extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteConsoleW(h: HANDLE, buf: [*]const u16, len: DWORD, written: ?*DWORD, reserved: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerProcessId(pipe: HANDLE, pid: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(sa: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ResetEvent(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW(block: [*:0]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentDirectoryW(len: DWORD, buf: ?[*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*anyopaque, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn K32GetProcessMemoryInfo(process: HANDLE, counters: *PROCESS_MEMORY_COUNTERS, cb: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: DWORD, pipe_mode: DWORD, max_instances: DWORD, out_size: DWORD, in_size: DWORD, default_timeout: DWORD, sa: ?*anyopaque) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *u64) callconv(.winapi) void;
pub extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTempPathW(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;

// ---- the current user, for the external-mode (user) pipe ---------------------

pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TokenUser: DWORD = 1;
pub const TokenElevation: DWORD = 20;
pub const TokenIntegrityLevel: DWORD = 25;

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: DWORD,
};

pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ProcessIdToSessionId(pid: DWORD, session: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(token: HANDLE, class: DWORD, info: ?*anyopaque, len: DWORD, ret_len: *DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, out: *?[*:0]u16) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetSidSubAuthorityCount(sid: *anyopaque) callconv(.winapi) *u8;
pub extern "advapi32" fn GetSidSubAuthority(sid: *anyopaque, n: DWORD) callconv(.winapi) *DWORD;

/// Who a process is, as far as the pipe check cares: the user SID as text
/// ("S-1-5-21-..."), whether the token is elevated and its integrity level.
pub const Identity = struct {
    sid_buf: [184]u8 = undefined,
    sid_len: usize = 0,
    elevated: bool = false,
    integrity: u32 = 0,

    pub fn sid(self: *const Identity) []const u8 {
        return self.sid_buf[0..self.sid_len];
    }

    /// Same user, same elevation, same integrity level.
    pub fn sameAs(self: *const Identity, other: *const Identity) bool {
        return self.sid_len > 0 and
            std.mem.eql(u8, self.sid(), other.sid()) and
            self.elevated == other.elevated and
            self.integrity == other.integrity;
    }
};

/// The identity of `process` (a handle with at least
/// `PROCESS_QUERY_LIMITED_INFORMATION`); null when its token cannot be read.
pub fn identityOf(process: HANDLE) ?Identity {
    var token: HANDLE = undefined;
    if (OpenProcessToken(process, TOKEN_QUERY, &token) == 0) return null;
    defer _ = CloseHandle(token);

    var id: Identity = .{};
    var buf: [256]u8 align(8) = undefined;
    var len: DWORD = 0;

    if (GetTokenInformation(token, TokenUser, &buf, buf.len, &len) == 0) return null;
    const user: *const SID_AND_ATTRIBUTES = @ptrCast(&buf);
    var wide: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(user.Sid orelse return null, &wide) == 0) return null;
    defer _ = LocalFree(wide);
    const text = std.mem.span(wide.?);
    if (text.len == 0 or text.len > id.sid_buf.len) return null;
    for (text, id.sid_buf[0..text.len]) |c, *out| {
        if (c > 0x7f) return null;
        out.* = @intCast(c);
    }
    id.sid_len = text.len;

    var elevation: DWORD = 0;
    if (GetTokenInformation(token, TokenElevation, &elevation, @sizeOf(DWORD), &len) == 0) return null;
    id.elevated = elevation != 0;

    // The label SID's last sub-authority is the integrity level.
    if (GetTokenInformation(token, TokenIntegrityLevel, &buf, buf.len, &len) == 0) return null;
    const label: *const SID_AND_ATTRIBUTES = @ptrCast(&buf);
    const label_sid = label.Sid orelse return null;
    const count = GetSidSubAuthorityCount(label_sid).*;
    if (count == 0) return null;
    id.integrity = GetSidSubAuthority(label_sid, count - 1).*;
    return id;
}

/// The identity of the pid; null when it cannot be opened or read.
pub fn identityOfPid(pid: DWORD) ?Identity {
    const proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = CloseHandle(proc);
    return identityOf(proc);
}

pub fn currentSession() ?DWORD {
    var session: DWORD = 0;
    if (ProcessIdToSessionId(GetCurrentProcessId(), &session) == 0) return null;
    return session;
}
