//! kernel32 bindings used by the GUI side: module handles, global memory
//! (clipboard payloads), dynamic loading and process memory counters.
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
