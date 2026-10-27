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
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const SECURITY_SQOS_PRESENT: DWORD = 0x00100000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x00010000;

pub const PIPE_ACCESS_DUPLEX: DWORD = 3;
pub const PIPE_TYPE_BYTE: DWORD = 0;
pub const PIPE_READMODE_BYTE: DWORD = 0;
pub const PIPE_WAIT: DWORD = 0;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 8;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_SEM_TIMEOUT: DWORD = 121;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;

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
