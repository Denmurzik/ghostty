//! advapi32 bindings: registry reads and process token / SID / security
//! descriptor queries (single-instance and IPC pipe security).
const foundation = @import("foundation.zig");
const BOOL = foundation.BOOL;
const HANDLE = foundation.HANDLE;

pub const HKEY = *opaque {};

/// `LSTATUS`: 0 (`ERROR_SUCCESS`) or a Win32 error code.
pub const LSTATUS = i32;

/// The SDK defines it as `(HKEY)(ULONG_PTR)((LONG)0x80000001)`: sign-extended.
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, 0) -% 0x7FFFFFFF);

pub const RRF_RT_REG_DWORD = 0x00000010;

pub const TOKEN_QUERY = 0x0008;

/// `TOKEN_INFORMATION_CLASS` values.
pub const TokenUser = 1;
pub const TokenElevation = 20;

pub const SDDL_REVISION_1 = 1;

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: u32,
};

pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

pub const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: u32,
};

pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    subkey: ?[*:0]const u16,
    value: ?[*:0]const u16,
    flags: u32,
    type_out: ?*u32,
    data: ?*anyopaque,
    size: ?*u32,
) callconv(.winapi) LSTATUS;
pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: u32, token: *HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(
    token: HANDLE,
    class: u32,
    info: ?*anyopaque,
    length: u32,
    return_length: *u32,
) callconv(.winapi) BOOL;
/// The string is allocated by the system; release it with `kernel32.LocalFree`.
pub extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, string: *?[*:0]u16) callconv(.winapi) BOOL;
/// The descriptor is allocated by the system; release it with `kernel32.LocalFree`.
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    sddl: [*:0]const u16,
    revision: u32,
    descriptor: *?*anyopaque,
    size: ?*u32,
) callconv(.winapi) BOOL;
pub extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) BOOL;

/// `TOKEN_INFORMATION_CLASS`: the mandatory integrity level of a token.
pub const TokenIntegrityLevel = 25;

pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

pub extern "advapi32" fn GetSidSubAuthorityCount(sid: *anyopaque) callconv(.winapi) *u8;
pub extern "advapi32" fn GetSidSubAuthority(sid: *anyopaque, index: u32) callconv(.winapi) *u32;
