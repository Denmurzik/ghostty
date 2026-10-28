const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const DELETE = 0x00010000;
pub const ERROR_SUCCESS = 0;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const S_OK = 0;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const exp = struct {
    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: LPCWSTR,
            hFile: ?HANDLE,
            dwFlags: DWORD,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn GetProcAddress(
            hModule: HANDLE,
            lpProcName: [*:0]const u8,
        ) callconv(.winapi) ?*const anyopaque;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getcomputernameexa
        pub extern "kernel32" fn GetComputerNameExA(
            NameType: c_int,
            lpBuffer: ?LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn FreeLibrary(hLibModule: HANDLE) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventw
        pub extern "kernel32" fn CreateEventW(
            lpEventAttributes: ?*SECURITY_ATTRIBUTES,
            bManualReset: BOOL,
            bInitialState: BOOL,
            lpName: ?LPCWSTR,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WaitForMultipleObjects(
            nCount: DWORD,
            lpHandles: [*]const HANDLE,
            bWaitAll: BOOL,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetOverlappedResult(
            hFile: HANDLE,
            lpOverlapped: *OVERLAPPED,
            lpNumberOfBytesTransferred: *DWORD,
            bWait: BOOL,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: *const anyopaque,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributeJobList = 13,
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@backingInt(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

// --- events (Task 9)
// The event externs (CreateEventW, SetEvent, WaitForMultipleObjects,
// GetOverlappedResult) live in `exp.kernel32` above.

pub const ERROR_BROKEN_PIPE = 109;
pub const ERROR_IO_PENDING = 997;
pub const GENERIC_WRITE = 0x40000000;
pub const PIPE_ACCESS_INBOUND = 0x00000001;
pub const WAIT_OBJECT_0 = 0x00000000;
pub const WAIT_TIMEOUT = 0x00000102;

// --- font files (Task 12)
// CreateFileW and CloseHandle live in `exp.kernel32` above.

pub const FILE_MAP_READ = 0x0004;
pub const PAGE_READONLY = 0x02;

pub extern "kernel32" fn CreateFileMappingW(
    hFile: HANDLE,
    lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
    flProtect: DWORD,
    dwMaximumSizeHigh: DWORD,
    dwMaximumSizeLow: DWORD,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: HANDLE,
    dwDesiredAccess: DWORD,
    dwFileOffsetHigh: DWORD,
    dwFileOffsetLow: DWORD,
    dwNumberOfBytesToMap: SIZE_T,
) callconv(.winapi) ?LPVOID;
pub extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *const anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(
    hFile: HANDLE,
    lpFileSize: *LARGE_INTEGER,
) callconv(.winapi) BOOL;

// --- registry (Task 13)

pub const HKEY = *anyopaque;
pub const LSTATUS = i32;

/// The predefined root keys are sign-extended 32-bit values on 64-bit
/// Windows (`(HKEY)(ULONG_PTR)(LONG)0x80000002`).
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000002)))))));
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
pub const RRF_RT_REG_SZ = 0x00000002;
pub const INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY = 0x10;

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: LPCWSTR,
) callconv(.winapi) DWORD;
pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?LPCWSTR,
    lpValue: ?LPCWSTR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) LSTATUS;

// --- console (Task 16)
// CreateFileW, WriteFile, CloseHandle and GetFileSizeEx are declared above.

pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;
pub const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6; // (DWORD)-10
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // (DWORD)-11
pub const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4; // (DWORD)-12
pub const FILE_APPEND_DATA = 0x00000004;
pub const OPEN_ALWAYS = 4;
pub const MOVEFILE_REPLACE_EXISTING = 0x00000001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
/// Null when the process has no such handle, INVALID_HANDLE_VALUE on error.
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetStdHandle(nStdHandle: DWORD, hHandle: ?HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn OutputDebugStringW(lpOutputString: LPCWSTR) callconv(.winapi) void;
pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: LPCWSTR,
    lpNewFileName: LPCWSTR,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

// --- process access (tests)

pub const PROCESS_TERMINATE: DWORD = 0x0001;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

// --- elevation and diagnostic environment (final review B-I1)

const TOKEN_QUERY: DWORD = 0x0008;
const TokenElevation: DWORD = 20;
const TOKEN_ELEVATION = extern struct { TokenIsElevated: DWORD };
extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(
    token: HANDLE,
    class: DWORD,
    info: ?*anyopaque,
    length: DWORD,
    return_length: *DWORD,
) callconv(.winapi) BOOL;

var elevated_cache: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 no, 2 yes

/// TokenElevation of `token` (a handle opened with `TOKEN_QUERY`); null when
/// it cannot be read.
pub fn tokenIsElevated(token: HANDLE) ?bool {
    var elev: TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var len: DWORD = 0;
    if (GetTokenInformation(token, TokenElevation, &elev, @sizeOf(TOKEN_ELEVATION), &len) == FALSE) return null;
    return elev.TokenIsElevated != 0;
}

/// Whether the current process runs elevated (TokenElevation), cached.
/// An unreadable token counts as elevated: the stricter answer is the safe
/// side for every caller (IPC pipe names, diagnostic variables).
pub fn isElevated() bool {
    switch (elevated_cache.load(.acquire)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const result = blk: {
        var token: HANDLE = undefined;
        if (OpenProcessToken(exp.kernel32.GetCurrentProcess(), TOKEN_QUERY, &token) == FALSE) break :blk true;
        defer _ = exp.kernel32.CloseHandle(token);
        break :blk tokenIsElevated(token) orelse true;
    };
    elevated_cache.store(if (result) 2 else 1, .release);
    return result;
}

/// The value of a diagnostic environment variable (`GHOSTTY_WIN32_*`,
/// `GHOSTTY_LATENCY_*`, `GHOSTTY_D3D11_*`), or null when unset or when the
/// process is elevated. The user profile's environment is writable at medium
/// integrity and UAC copies it into the elevated process, so an elevated
/// Ghostty must not let it name files to create or DLLs to load. Caller owns
/// the result.
pub fn diagnosticEnv(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    return diagnosticEnvFor(isElevated(), alloc, name);
}

fn diagnosticEnvFor(elevated: bool, alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (elevated) return null;
    return @import("../global.zig").environ().getAlloc(alloc, name) catch null;
}

const diagnostic_prefixes = [_][]const u8{ "GHOSTTY_LATENCY_", "GHOSTTY_WIN32_", "GHOSTTY_D3D11_" };

/// Removes every diagnostic variable (see `diagnosticEnv`) from the
/// environment a child shell gets, so they do not leak into programs, or
/// into a Ghostty started from inside the terminal.
pub fn scrubDiagnosticEnv(env: *std.process.Environ.Map) void {
    var i: usize = 0;
    while (i < env.count()) {
        const key = env.keys()[i];
        const diagnostic = for (diagnostic_prefixes) |prefix| {
            if (std.ascii.startsWithIgnoreCase(key, prefix)) break true;
        } else false;
        if (diagnostic) _ = env.swapRemove(key) else i += 1;
    }
}

test "windows diag env: scrub removes only the diagnostic variables" {
    const testing = std.testing;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("GHOSTTY_D3D11_DUMP", "x");
    try env.put("GHOSTTY_D3D11_SIMULATE_DEVICE_LOST", "1");
    try env.put("GHOSTTY_LATENCY_TRACE", "x");
    try env.put("GHOSTTY_LATENCY_TAG", "x");
    try env.put("GHOSTTY_WIN32_CONPTY_DLL", "x");
    try env.put("GHOSTTY_WIN32_EXIT_IMMEDIATELY", "1");
    try env.put("ghostty_d3d11_debug", "1");
    try env.put("GHOSTTY_RESOURCES_DIR", "r");
    try env.put("PATH", "p");
    scrubDiagnosticEnv(&env);
    try testing.expectEqual(@as(usize, 2), env.count());
    try testing.expect(env.get("GHOSTTY_RESOURCES_DIR") != null);
    try testing.expect(env.get("PATH") != null);
}

test "windows diag env: ignored when elevated" {
    const testing = std.testing;
    // Any variable that is always set on Windows.
    const value = diagnosticEnvFor(false, testing.allocator, "SystemRoot") orelse
        return error.SkipZigTest;
    testing.allocator.free(value);
    try testing.expect(diagnosticEnvFor(true, testing.allocator, "SystemRoot") == null);
    try testing.expect(diagnosticEnvFor(false, testing.allocator, "GHOSTTY_NO_SUCH_VARIABLE_FOR_TEST") == null);
}

/// The ConPTY entry points a pty uses, plus the flags `CreatePseudoConsole`
/// gets. Two sources, picked by `windows-conpty` (`setConptyBundled`):
///
/// - inbox: kernel32, the system's conhost.
/// - bundled: `conpty.dll` next to `ghostty.exe`, which starts the
///   `OpenConsole.exe` next to it (the `Microsoft.Windows.Console.ConPTY`
///   package, the console Windows Terminal ships). It forwards what the inbox
///   console drops (Kitty graphics APC, SGR 58), see
///   test/windows/conpty-probe/RESULT.md. Missing or unloadable files fall
///   back to inbox with one log line.
///
/// Diagnostic overrides (latency measurements, not configuration):
/// `GHOSTTY_WIN32_CONPTY_FLAGS=<u32>` replaces the flags (0 otherwise) and
/// `GHOSTTY_WIN32_CONPTY_DLL=<path to conpty.dll>` (Debug builds only) loads the
/// three functions from that DLL (next to its `OpenConsole.exe`) instead of
/// kernel32, whatever `windows-conpty` says. Any failure falls back to
/// kernel32. Elevated processes ignore both.
pub const ConPty = struct {
    pub const CreateFn = *const fn (COORD, HANDLE, HANDLE, DWORD, *HPCON) callconv(.winapi) HRESULT;
    pub const ResizeFn = *const fn (HPCON, COORD) callconv(.winapi) HRESULT;
    pub const CloseFn = *const fn (HPCON) callconv(.winapi) void;

    create: CreateFn,
    resize: ResizeFn,
    close: CloseFn,
    flags: DWORD,

    pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
};

/// Which ConPTY a new pty gets.
pub const ConptySource = enum { inbox, bundled, dll_override };

pub fn conptySource(o: struct {
    /// `GHOSTTY_WIN32_CONPTY_DLL` was loaded (Debug builds).
    dll_override: bool,
    /// `windows-conpty = bundled`.
    bundled_wanted: bool,
    /// The bundled pair was found and loaded.
    bundled_loaded: bool,
}) ConptySource {
    if (o.dll_override) return .dll_override;
    if (o.bundled_wanted and o.bundled_loaded) return .bundled;
    return .inbox;
}

pub const BundledFiles = enum { present, no_dll, no_console };

/// Whether `dir` holds both files of the bundled ConPTY.
pub fn bundledFiles(alloc: std.mem.Allocator, dir: []const u8) BundledFiles {
    inline for (.{ .{ "conpty.dll", BundledFiles.no_dll }, .{ "OpenConsole.exe", BundledFiles.no_console } }) |f| {
        if (!isFile(alloc, dir, f[0])) return f[1];
    }
    return .present;
}

fn isFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(alloc, &.{ dir, name }) catch return false;
    defer alloc.free(path);
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(path_w);
    const attrs = GetFileAttributesW(path_w.ptr);
    return attrs != INVALID_FILE_ATTRIBUTES and attrs & FILE_ATTRIBUTE_DIRECTORY == 0;
}

var conpty_inbox: ConPty = undefined;
var conpty_bundled: ConPty = undefined;
var conpty_inbox_ready = false;
var conpty_dll_override = false;
var conpty_bundled_state: enum { untried, loaded, unavailable } = .untried;
var conpty_bundled_wanted: std.atomic.Value(bool) = .init(true);
var conpty_mutex: std.Io.Mutex = .init;

/// `windows-conpty`: the apprt sets it from the config. Takes effect for
/// ptys opened afterwards; the bundled DLL is loaded the first time a pty
/// wants it and stays loaded.
pub fn setConptyBundled(wanted: bool) void {
    conpty_bundled_wanted.store(wanted, .release);
}

/// The ConPTY for a new pty. The pty keeps the pointer: its resize and
/// close must go to the same DLL as its create.
pub fn conpty() *const ConPty {
    const global = @import("../global.zig");
    const io = global.io();
    conpty_mutex.lockUncancelable(io);
    defer conpty_mutex.unlock(io);

    if (!conpty_inbox_ready) {
        resolveInbox(&conpty_inbox);
        conpty_inbox_ready = true;
    }
    const wanted = conpty_bundled_wanted.load(.acquire);
    if (wanted and !conpty_dll_override and conpty_bundled_state == .untried) {
        conpty_bundled = conpty_inbox;
        conpty_bundled_state = if (loadBundled(&conpty_bundled)) .loaded else .unavailable;
    }
    return switch (conptySource(.{
        .dll_override = conpty_dll_override,
        .bundled_wanted = wanted,
        .bundled_loaded = conpty_bundled_state == .loaded,
    })) {
        .bundled => &conpty_bundled,
        .inbox, .dll_override => &conpty_inbox,
    };
}

fn resolveInbox(api: *ConPty) void {
    const log = std.log.scoped(.conpty);
    const alloc = @import("../global.zig").alloc();
    const k32 = exp.kernel32;
    api.* = .{
        .create = &k32.CreatePseudoConsole,
        .resize = &k32.ResizePseudoConsole,
        .close = &k32.ClosePseudoConsole,
        .flags = 0,
    };

    if (diagnosticEnv(alloc, "GHOSTTY_WIN32_CONPTY_FLAGS")) |text| {
        defer alloc.free(text);
        if (std.fmt.parseInt(DWORD, text, 0)) |flags| {
            api.flags = flags;
            log.info("conpty flags override flags={d}", .{flags});
        } else |_| log.warn("ignoring GHOSTTY_WIN32_CONPTY_FLAGS={s}", .{text});
    }

    // Debug builds only: a release build never loads a DLL named by the
    // environment (the elevated check in `diagnosticEnv` is the second lock).
    if (builtin.mode == .debug) {
        if (diagnosticEnv(alloc, "GHOSTTY_WIN32_CONPTY_DLL")) |path| {
            defer alloc.free(path);
            if (loadDll(path, api)) {
                conpty_dll_override = true;
            } else |err| log.warn("conpty dll {s} not used err={}, using kernel32", .{ path, err });
        }
    }
}

fn loadDll(path: []const u8, api: *ConPty) !void {
    const log = std.log.scoped(.conpty);
    const global = @import("../global.zig");
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(global.alloc(), path);
    defer global.alloc().free(path_w);

    // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: the DLL's own directory is searched
    // for its dependencies; it needs an absolute path.
    const module = exp.kernel32.LoadLibraryExW(
        path_w.ptr,
        null,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return unexpectedError(GetLastError());
    try bindConpty(module, api);
    log.info("conpty functions from {s}", .{path});
}

const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x100;
const LOAD_LIBRARY_SEARCH_APPLICATION_DIR = 0x200;
const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x800;

/// The bundled pair next to `ghostty.exe`; false (after one log line) when
/// it is missing or does not load.
fn loadBundled(api: *ConPty) bool {
    const log = std.log.scoped(.conpty);
    const global = @import("../global.zig");
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(global.io(), &dir_buf) catch |err| {
        log.info("windows-conpty = bundled, but the exe directory is unknown err={}; using the inbox ConPTY", .{err});
        return false;
    };
    const dir = dir_buf[0..n];
    switch (bundledFiles(global.alloc(), dir)) {
        .present => {},
        .no_dll, .no_console => |missing| {
            log.info("windows-conpty = bundled, but {s} is not next to ghostty.exe; using the inbox ConPTY", .{
                if (missing == .no_dll) "conpty.dll" else "OpenConsole.exe",
            });
            return false;
        },
    }

    // By name from the application directory only: no PATH, no current
    // directory (DLL planting). System32 serves its API-set dependencies.
    const module = exp.kernel32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
        null,
        LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse {
        log.warn("windows-conpty = bundled, but conpty.dll did not load err={d}; using the inbox ConPTY", .{@backingInt(GetLastError())});
        return false;
    };
    bindConpty(module, api) catch |err| {
        log.warn("windows-conpty = bundled, but conpty.dll is not usable err={}; using the inbox ConPTY", .{err});
        return false;
    };
    log.info("conpty: bundled OpenConsole from {s}", .{dir});
    return true;
}

/// Takes the three functions from `module`; a DLL that lacks one is not
/// kept loaded.
fn bindConpty(module: HANDLE, api: *ConPty) !void {
    errdefer _ = exp.kernel32.FreeLibrary(module);
    const create = exp.kernel32.GetProcAddress(module, "CreatePseudoConsole") orelse return error.MissingExport;
    const resize = exp.kernel32.GetProcAddress(module, "ResizePseudoConsole") orelse return error.MissingExport;
    const close = exp.kernel32.GetProcAddress(module, "ClosePseudoConsole") orelse return error.MissingExport;
    api.create = @ptrCast(@alignCast(create));
    api.resize = @ptrCast(@alignCast(resize));
    api.close = @ptrCast(@alignCast(close));
}

test "windows conpty: source" {
    const testing = std.testing;
    try testing.expectEqual(ConptySource.bundled, conptySource(.{ .dll_override = false, .bundled_wanted = true, .bundled_loaded = true }));
    // Missing or unloadable files: inbox.
    try testing.expectEqual(ConptySource.inbox, conptySource(.{ .dll_override = false, .bundled_wanted = true, .bundled_loaded = false }));
    // `windows-conpty = inbox` wins over a loaded pair.
    try testing.expectEqual(ConptySource.inbox, conptySource(.{ .dll_override = false, .bundled_wanted = false, .bundled_loaded = true }));
    // The diagnostic DLL wins over everything.
    try testing.expectEqual(ConptySource.dll_override, conptySource(.{ .dll_override = true, .bundled_wanted = true, .bundled_loaded = true }));
    try testing.expectEqual(ConptySource.dll_override, conptySource(.{ .dll_override = true, .bundled_wanted = false, .bundled_loaded = false }));
}

test "windows conpty: bundled files" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, ".", &dir_buf);
    const dir = dir_buf[0..n];

    try testing.expectEqual(BundledFiles.no_dll, bundledFiles(alloc, dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "conpty.dll", .data = "" });
    try testing.expectEqual(BundledFiles.no_console, bundledFiles(alloc, dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "OpenConsole.exe", .data = "" });
    try testing.expectEqual(BundledFiles.present, bundledFiles(alloc, dir));

    // A directory of that name is not the console.
    try tmp.dir.createDir(io, "d", .default_dir);
    try tmp.dir.createDir(io, "d/OpenConsole.exe", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "d/conpty.dll", .data = "" });
    const sub = try std.fs.path.join(alloc, &.{ dir, "d" });
    defer alloc.free(sub);
    try testing.expectEqual(BundledFiles.no_console, bundledFiles(alloc, sub));
}
