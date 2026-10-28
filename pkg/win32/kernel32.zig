//! kernel32 bindings used by the GUI side: module handles, global memory
//! (clipboard payloads), dynamic loading and process memory counters.
const std = @import("std");
const foundation = @import("foundation.zig");
const BOOL = foundation.BOOL;
const HANDLE = foundation.HANDLE;
const HMODULE = foundation.HMODULE;

pub const HGLOBAL = HANDLE;

pub const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: u32 = @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
    PrivateUsage: usize = 0,
};

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(.winapi) BOOL;
/// Returns null on success, the handle on failure.
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn OutputDebugStringW([*:0]const u16) callconv(.winapi) void;
pub extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?HANDLE, flags: u32) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn FreeLibrary(HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn K32GetProcessMemoryInfo(process: HANDLE, counters: *PROCESS_MEMORY_COUNTERS_EX, cb: u32) callconv(.winapi) BOOL;

pub const GMEM_FIXED = 0x0000;
pub const GMEM_MOVEABLE = 0x0002;
pub const GMEM_ZEROINIT = 0x0040;
pub const GHND = GMEM_MOVEABLE | GMEM_ZEROINIT;

pub const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;

// -- Named pipes, overlapped I/O, events and process queries -----------------

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    /// Union with `Pointer` in the SDK; the offset pair is all pipes use.
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE = null,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32 = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

pub const MEMORYSTATUSEX = extern struct {
    dwLength: u32 = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: u32 = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

/// Returns `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn CreateNamedPipeW(
    name: [*:0]const u16,
    open_mode: u32,
    pipe_mode: u32,
    max_instances: u32,
    out_buffer_size: u32,
    in_buffer_size: u32,
    default_timeout_ms: u32,
    security: ?*SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
/// Returns `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share_mode: u32,
    security: ?*SECURITY_ATTRIBUTES,
    disposition: u32,
    flags: u32,
    template: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout_ms: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(file: HANDLE, buf: ?[*]u8, len: u32, read: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(file: HANDLE, buf: ?[*]const u8, len: u32, written: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(file: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *OVERLAPPED, transferred: *u32, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(security: ?*SECURITY_ATTRIBUTES, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObjectEx(HANDLE, timeout_ms: u32, alertable: BOOL) callconv(.winapi) u32;
pub extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const HANDLE, wait_all: BOOL, timeout_ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn DuplicateHandle(source_process: HANDLE, source: HANDLE, target_process: HANDLE, target: *HANDLE, access: u32, inherit: BOOL, options: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn ProcessIdToSessionId(process_id: u32, session_id: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerProcessId(pipe: HANDLE, process_id: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeClientProcessId(pipe: HANDLE, process_id: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, process_id: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
/// Returns null on success, the handle on failure.
pub extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalMemoryStatusEx(*MEMORYSTATUSEX) callconv(.winapi) BOOL;

pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PIPE_READMODE_BYTE = 0x00000000;
pub const PIPE_WAIT = 0x00000000;
pub const PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;
pub const PIPE_UNLIMITED_INSTANCES = 255;

/// `CreateFileW` flags that cap how far the pipe server may impersonate the client.
pub const SECURITY_SQOS_PRESENT = 0x00100000;
pub const SECURITY_IDENTIFICATION = 0x00010000;

pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

pub const GENERIC_READ = 0x80000000;
pub const GENERIC_WRITE = 0x40000000;
pub const OPEN_EXISTING = 3;

pub const ERROR_FILE_NOT_FOUND = 2;
pub const ERROR_ACCESS_DENIED = 5;
pub const ERROR_BROKEN_PIPE = 109;
pub const ERROR_SEM_TIMEOUT = 121;
pub const ERROR_PIPE_BUSY = 231;
pub const ERROR_NO_DATA = 232;
pub const ERROR_PIPE_CONNECTED = 535;
pub const ERROR_IO_PENDING = 997;

pub const WAIT_OBJECT_0 = 0;
pub const WAIT_TIMEOUT = 258;
pub const INFINITE = 0xFFFFFFFF;
pub const DUPLICATE_SAME_ACCESS = 2;

// Paths and drives (fileapi.h)

pub const INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
pub const FILE_SHARE_READ = 0x1;
pub const FILE_SHARE_WRITE = 0x2;
pub const FILE_SHARE_DELETE = 0x4;
/// Lets `CreateFileW` open a directory.
pub const FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
/// `GetFinalPathNameByHandleW` flags: the DOS path (`\?\C:\...`), normalized.
pub const VOLUME_NAME_DOS = 0x0;
pub const FILE_NAME_NORMALIZED = 0x0;

/// `INVALID_FILE_ATTRIBUTES` when the path does not exist.
pub extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
pub const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    /// The reparse tag when `dwFileAttributes` has `FILE_ATTRIBUTE_REPARSE_POINT`.
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
/// `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn FindFirstFileW(name: [*:0]const u16, data: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindClose(HANDLE) callconv(.winapi) BOOL;
pub const SEM_FAILCRITICALERRORS = 0x0001;
/// Per thread: with `SEM_FAILCRITICALERRORS` an empty drive fails instead of
/// raising the system "No disk" dialog.
pub extern "kernel32" fn SetThreadErrorMode(mode: u32, old: ?*u32) callconv(.winapi) i32;
/// `DRIVE_*` of the root (`C:\`).
pub extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
/// Returns the length without the NUL; with a too small buffer the length needed, with the NUL.
pub extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, len: u32, buf: ?[*]u16, file_part: ?*?[*]u16) callconv(.winapi) u32;
/// Expands 8.3 short names. Same length convention; 0 when the file does not exist.
pub extern "kernel32" fn GetLongPathNameW(short: [*:0]const u16, buf: ?[*]u16, len: u32) callconv(.winapi) u32;
/// Same length convention; 0 on failure.
pub extern "kernel32" fn GetFinalPathNameByHandleW(file: HANDLE, buf: ?[*]u16, len: u32, flags: u32) callconv(.winapi) u32;

pub extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn HeapCompact(heap: HANDLE, flags: u32) callconv(.winapi) usize;

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
pub extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;

pub const MOVEFILE_REPLACE_EXISTING = 0x1;
pub const MOVEFILE_WRITE_THROUGH = 0x8;
pub extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: ?[*:0]const u16, flags: u32) callconv(.winapi) BOOL;
/// Writes the name (with NUL) into `buf`; returns its length with the NUL, 0 on failure.
pub extern "kernel32" fn GetUserDefaultLocaleName(buf: [*]u16, len: i32) callconv(.winapi) i32;
