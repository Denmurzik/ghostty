//! winhttp bindings (the update check). `winhttp.dll` is never linked: `Api.load`
//! resolves the handful of entry points through `LoadLibraryExW(SYSTEM32)` +
//! `GetProcAddress`, and `Api.unload` gives the module back once WinHTTP says
//! (`WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT`) that nothing of it still runs.

const std = @import("std");
const foundation = @import("foundation.zig");
const kernel32 = @import("kernel32.zig");

const BOOL = foundation.BOOL;
const HANDLE = foundation.HANDLE;
const HMODULE = foundation.HMODULE;

/// A session, connection or request handle.
pub const HINTERNET = *anyopaque;

pub const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: u32 = 0;
pub const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: u32 = 4;
pub const WINHTTP_FLAG_SECURE: u32 = 0x00800000;
pub const WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT: u32 = 99;
pub const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
pub const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x20000000;
pub const INTERNET_DEFAULT_HTTP_PORT: u16 = 80;
pub const INTERNET_DEFAULT_HTTPS_PORT: u16 = 443;

pub const OpenFn = *const fn (agent: ?[*:0]const u16, access: u32, proxy: ?[*:0]const u16, bypass: ?[*:0]const u16, flags: u32) callconv(.winapi) ?HINTERNET;
pub const ConnectFn = *const fn (session: HINTERNET, server: [*:0]const u16, port: u16, reserved: u32) callconv(.winapi) ?HINTERNET;
pub const OpenRequestFn = *const fn (connect: HINTERNET, verb: ?[*:0]const u16, object: ?[*:0]const u16, version: ?[*:0]const u16, referrer: ?[*:0]const u16, accept: ?*const ?[*:0]const u16, flags: u32) callconv(.winapi) ?HINTERNET;
pub const SendRequestFn = *const fn (request: HINTERNET, headers: ?[*]const u16, headers_len: u32, optional: ?*const anyopaque, optional_len: u32, total_len: u32, context: usize) callconv(.winapi) BOOL;
pub const ReceiveResponseFn = *const fn (request: HINTERNET, reserved: ?*anyopaque) callconv(.winapi) BOOL;
pub const QueryHeadersFn = *const fn (request: HINTERNET, level: u32, name: ?[*:0]const u16, buffer: ?*anyopaque, len: *u32, index: ?*u32) callconv(.winapi) BOOL;
pub const ReadDataFn = *const fn (request: HINTERNET, buffer: *anyopaque, to_read: u32, read: *u32) callconv(.winapi) BOOL;
pub const CloseHandleFn = *const fn (handle: HINTERNET) callconv(.winapi) BOOL;
pub const SetTimeoutsFn = *const fn (handle: HINTERNET, resolve: i32, connect: i32, send: i32, receive: i32) callconv(.winapi) BOOL;
pub const SetOptionFn = *const fn (handle: ?HINTERNET, option: u32, buffer: ?*const anyopaque, len: u32) callconv(.winapi) BOOL;

/// The entry points of one loaded `winhttp.dll`.
pub const Api = struct {
    module: HMODULE,
    open: OpenFn,
    connect: ConnectFn,
    openRequest: OpenRequestFn,
    sendRequest: SendRequestFn,
    receiveResponse: ReceiveResponseFn,
    queryHeaders: QueryHeadersFn,
    readData: ReadDataFn,
    closeHandle: CloseHandleFn,
    setTimeouts: SetTimeoutsFn,
    setOption: SetOptionFn,

    /// Null when the DLL or one of its functions is missing.
    pub fn load() ?Api {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("winhttp.dll");
        const module = kernel32.LoadLibraryExW(name, null, kernel32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
        var api: Api = undefined;
        api.module = module;
        inline for (.{
            .{ "open", "WinHttpOpen" },
            .{ "connect", "WinHttpConnect" },
            .{ "openRequest", "WinHttpOpenRequest" },
            .{ "sendRequest", "WinHttpSendRequest" },
            .{ "receiveResponse", "WinHttpReceiveResponse" },
            .{ "queryHeaders", "WinHttpQueryHeaders" },
            .{ "readData", "WinHttpReadData" },
            .{ "closeHandle", "WinHttpCloseHandle" },
            .{ "setTimeouts", "WinHttpSetTimeouts" },
            .{ "setOption", "WinHttpSetOption" },
        }) |entry| {
            const addr = kernel32.GetProcAddress(module, entry[1]) orelse {
                _ = kernel32.FreeLibrary(module);
                return null;
            };
            @field(api, entry[0]) = @ptrCast(@alignCast(addr));
        }
        return api;
    }

    /// Frees the module. Callers close every handle first and wait for the
    /// unload notification (`WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT`).
    pub fn unload(self: Api) void {
        _ = kernel32.FreeLibrary(self.module);
    }
};

test "winhttp: the entry points resolve on this machine" {
    const api = Api.load() orelse return error.SkipZigTest;
    api.unload();
}
