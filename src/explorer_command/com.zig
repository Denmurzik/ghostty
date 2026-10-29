//! The minimal COM surface of `ghostty-explorer.dll`: just the interfaces,
//! HRESULTs and constants the Explorer command needs, declared by hand so the
//! DLL imports only kernel32 and ole32 and links no libc.
const std = @import("std");

pub const HRESULT = i32;
pub const BOOL = i32;
pub const DWORD = u32;
pub const LPWSTR = [*:0]u16;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));
pub const CLASS_E_CLASSNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040111));

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// `HRESULT_FROM_WIN32`.
pub fn hresultFromWin32(err: u32) HRESULT {
    if (err == 0) return S_OK;
    return @bitCast(0x80070000 | (err & 0xFFFF));
}

pub const SIGDN_FILESYSPATH: u32 = 0x80058000;
pub const SFGAO_FILESYSTEM: u32 = 0x40000000;

/// `EXPCMDSTATE`.
pub const ECS_ENABLED: u32 = 0;
pub const ECS_DISABLED: u32 = 1;
pub const ECS_HIDDEN: u32 = 2;

/// `EXPCMDFLAGS`.
pub const ECF_DEFAULT: u32 = 0;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }

    /// `{8-4-4-4-12}` hex text, at comptime.
    pub fn parse(comptime text: []const u8) GUID {
        comptime {
            if (text.len != 38 or text[0] != '{' or text[37] != '}') @compileError("bad GUID text");
            const d = std.fmt.parseUnsigned;
            return .{
                .Data1 = d(u32, text[1..9], 16) catch @compileError("bad GUID"),
                .Data2 = d(u16, text[10..14], 16) catch @compileError("bad GUID"),
                .Data3 = d(u16, text[15..19], 16) catch @compileError("bad GUID"),
                .Data4 = .{
                    d(u8, text[20..22], 16) catch @compileError("bad GUID"),
                    d(u8, text[22..24], 16) catch @compileError("bad GUID"),
                    d(u8, text[25..27], 16) catch @compileError("bad GUID"),
                    d(u8, text[27..29], 16) catch @compileError("bad GUID"),
                    d(u8, text[29..31], 16) catch @compileError("bad GUID"),
                    d(u8, text[31..33], 16) catch @compileError("bad GUID"),
                    d(u8, text[33..35], 16) catch @compileError("bad GUID"),
                    d(u8, text[35..37], 16) catch @compileError("bad GUID"),
                },
            };
        }
    }
};

pub const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const IID_IClassFactory = GUID.parse("{00000001-0000-0000-C000-000000000046}");
pub const IID_IExplorerCommand = GUID.parse("{A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9}");

/// The three leading slots of every COM vtable.
pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

pub const IClassFactoryVtbl = extern struct {
    unk: IUnknownVtbl,
    CreateInstance: *const fn (*anyopaque, ?*anyopaque, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    LockServer: *const fn (*anyopaque, BOOL) callconv(.winapi) HRESULT,
};

pub const IExplorerCommandVtbl = extern struct {
    unk: IUnknownVtbl,
    GetTitle: *const fn (*anyopaque, ?*IShellItemArray, ?*?LPWSTR) callconv(.winapi) HRESULT,
    GetIcon: *const fn (*anyopaque, ?*IShellItemArray, ?*?LPWSTR) callconv(.winapi) HRESULT,
    GetToolTip: *const fn (*anyopaque, ?*IShellItemArray, ?*?LPWSTR) callconv(.winapi) HRESULT,
    GetCanonicalName: *const fn (*anyopaque, ?*GUID) callconv(.winapi) HRESULT,
    GetState: *const fn (*anyopaque, ?*IShellItemArray, BOOL, ?*u32) callconv(.winapi) HRESULT,
    Invoke: *const fn (*anyopaque, ?*IShellItemArray, ?*anyopaque) callconv(.winapi) HRESULT,
    GetFlags: *const fn (*anyopaque, ?*u32) callconv(.winapi) HRESULT,
    EnumSubCommands: *const fn (*anyopaque, ?*?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IShellItemVtbl = extern struct {
    unk: IUnknownVtbl,
    BindToHandler: *const fn (*anyopaque, ?*anyopaque, *const GUID, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    GetParent: *const fn (*anyopaque, *?*IShellItem) callconv(.winapi) HRESULT,
    GetDisplayName: *const fn (*anyopaque, u32, *?LPWSTR) callconv(.winapi) HRESULT,
    GetAttributes: *const fn (*anyopaque, u32, *u32) callconv(.winapi) HRESULT,
    Compare: *const fn (*anyopaque, *IShellItem, u32, *i32) callconv(.winapi) HRESULT,
};

pub const IShellItemArrayVtbl = extern struct {
    unk: IUnknownVtbl,
    BindToHandler: *const fn (*anyopaque, ?*anyopaque, *const GUID, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyStore: *const fn (*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyDescriptionList: *const fn (*anyopaque, *const anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    GetAttributes: *const fn (*anyopaque, u32, u32, *u32) callconv(.winapi) HRESULT,
    GetCount: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    GetItemAt: *const fn (*anyopaque, u32, *?*IShellItem) callconv(.winapi) HRESULT,
    EnumItems: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IShellItem = extern struct {
    vtbl: *const IShellItemVtbl,

    pub fn release(self: *IShellItem) void {
        _ = self.vtbl.unk.Release(self);
    }
};

pub const IShellItemArray = extern struct {
    vtbl: *const IShellItemArrayVtbl,
};

pub extern "ole32" fn CoTaskMemAlloc(size: usize) callconv(.winapi) ?*anyopaque;
pub extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(.winapi) void;

test "com: guid parse and compare" {
    const g = GUID.parse("{A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9}");
    try std.testing.expectEqual(@as(u32, 0xA08CE4D0), g.Data1);
    try std.testing.expectEqual(@as(u8, 0xB5), g.Data4[0]);
    try std.testing.expectEqual(@as(u8, 0xB9), g.Data4[7]);
    try std.testing.expect(g.eql(&IID_IExplorerCommand));
    try std.testing.expect(!g.eql(&IID_IUnknown));
}
