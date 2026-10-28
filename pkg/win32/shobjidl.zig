//! shobjidl bindings for the taskbar jump list: ICustomDestinationList, the
//! shell link and the collections that carry the tasks (shobjidl_core.h,
//! propsys.h, propkey.h).
const std = @import("std");
const foundation = @import("foundation.zig");
const com = @import("com.zig");

const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;

pub const CLSID_DestinationList = GUID.parse("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
pub const CLSID_ShellLink = GUID.parse("00021401-0000-0000-c000-000000000046");
pub const CLSID_EnumerableObjectCollection = GUID.parse("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");

pub const IID_ICustomDestinationList = GUID.parse("6332debf-87b5-4670-90c0-5e57b408a49e");
pub const IID_IShellLinkW = GUID.parse("000214f9-0000-0000-c000-000000000046");
pub const IID_IObjectArray = GUID.parse("92ca9dcd-5622-4bba-a805-5e9f541bd8c9");
pub const IID_IObjectCollection = GUID.parse("5632b1a4-e38a-400a-928a-d4cd63230295");
pub const IID_IPropertyStore = GUID.parse("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");

pub const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: u32,
};

/// The separator marker of a jump list task (a link with this property set
/// to true draws a line).
pub const PKEY_AppUserModel_IsDestListSeparator: PROPERTYKEY = .{
    .fmtid = GUID.parse("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"),
    .pid = 6,
};

/// The title of a link in the list; a task without it shows no text.
pub const PKEY_Title: PROPERTYKEY = .{
    .fmtid = GUID.parse("f29f85e0-4ff9-1068-ab91-08002b27b3d9"),
    .pid = 2,
};

pub const VT_BOOL: u16 = 11;
pub const VT_LPWSTR: u16 = 31;
pub const VARIANT_TRUE: i16 = -1;

/// The two members the jump list uses; the rest of the union is padding so
/// that the size matches the SDK's.
pub const PROPVARIANT = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    data: extern union {
        boolVal: i16,
        pwszVal: ?[*:0]u16,
        pad: [2]usize,
    } = .{ .pad = .{ 0, 0 } },

    pub fn fromBool(value: bool) PROPVARIANT {
        return .{ .vt = VT_BOOL, .data = .{ .boolVal = if (value) VARIANT_TRUE else 0 } };
    }

    /// Copies `s` into CoTaskMem memory; `clear` frees it.
    pub fn fromString(s: [:0]const u16) error{OutOfMemory}!PROPVARIANT {
        const bytes = (s.len + 1) * @sizeOf(u16);
        const raw = CoTaskMemAlloc(bytes) orelse return error.OutOfMemory;
        const dst: [*]u16 = @ptrCast(@alignCast(raw));
        @memcpy(dst[0 .. s.len + 1], s.ptr[0 .. s.len + 1]);
        return .{ .vt = VT_LPWSTR, .data = .{ .pwszVal = @ptrCast(dst) } };
    }

    pub fn clear(self: *PROPVARIANT) void {
        _ = PropVariantClear(self);
    }
};

pub extern "ole32" fn CoTaskMemAlloc(size: usize) callconv(.winapi) ?*anyopaque;
pub extern "ole32" fn PropVariantClear(*PROPVARIANT) callconv(.winapi) HRESULT;

/// `IObjectArray`: IUnknown + 2 slots.
pub const IObjectArray = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IObjectArray;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        GetCount: *const fn (*IObjectArray, *u32) callconv(.winapi) HRESULT,
        GetAt: *const fn (*IObjectArray, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn getCount(self: *IObjectArray) foundation.Error!u32 {
        var n: u32 = 0;
        try foundation.check(self.vtable.GetCount(self, &n));
        return n;
    }
};

/// `IObjectCollection : IObjectArray`: 5 + 4 slots.
pub const IObjectCollection = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IObjectCollection;

    pub const VTable = extern struct {
        base: IObjectArray.VTable,
        AddObject: *const fn (*IObjectCollection, *com.IUnknown) callconv(.winapi) HRESULT,
        AddFromArray: *const anyopaque,
        RemoveObjectAt: *const anyopaque,
        Clear: *const anyopaque,
    };

    pub inline fn addObject(self: *IObjectCollection, obj: anytype) foundation.Error!void {
        try foundation.check(self.vtable.AddObject(self, @ptrCast(obj)));
    }
};

/// `IPropertyStore`: IUnknown + 5 slots.
pub const IPropertyStore = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IPropertyStore;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const anyopaque,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) HRESULT,
    };

    pub inline fn setValue(self: *IPropertyStore, key: *const PROPERTYKEY, value: *const PROPVARIANT) foundation.Error!void {
        try foundation.check(self.vtable.SetValue(self, key, value));
    }

    pub inline fn commit(self: *IPropertyStore) foundation.Error!void {
        try foundation.check(self.vtable.Commit(self));
    }
};

/// `IShellLinkW`: IUnknown + 18 slots.
pub const IShellLinkW = extern struct {
    vtable: *const VTable,

    pub const iid = IID_IShellLinkW;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        GetPath: *const anyopaque,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetArguments: *const anyopaque,
        SetArguments: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*IShellLinkW, [*:0]const u16, i32) callconv(.winapi) HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
    };

    pub inline fn setDescription(self: *IShellLinkW, s: [*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.SetDescription(self, s));
    }

    pub inline fn setWorkingDirectory(self: *IShellLinkW, s: [*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.SetWorkingDirectory(self, s));
    }

    pub inline fn setArguments(self: *IShellLinkW, s: [*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.SetArguments(self, s));
    }

    pub inline fn setIconLocation(self: *IShellLinkW, path: [*:0]const u16, index: i32) foundation.Error!void {
        try foundation.check(self.vtable.SetIconLocation(self, path, index));
    }

    pub inline fn setPath(self: *IShellLinkW, s: [*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.SetPath(self, s));
    }
};

/// `ICustomDestinationList`: IUnknown + 9 slots.
pub const ICustomDestinationList = extern struct {
    vtable: *const VTable,

    pub const iid = IID_ICustomDestinationList;

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        SetAppID: *const fn (*ICustomDestinationList, [*:0]const u16) callconv(.winapi) HRESULT,
        BeginList: *const fn (*ICustomDestinationList, *u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AppendCategory: *const anyopaque,
        AppendKnownCategory: *const anyopaque,
        AddUserTasks: *const fn (*ICustomDestinationList, *IObjectArray) callconv(.winapi) HRESULT,
        CommitList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
        GetRemovedDestinations: *const anyopaque,
        DeleteList: *const fn (*ICustomDestinationList, ?[*:0]const u16) callconv(.winapi) HRESULT,
        AbortList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
    };

    pub inline fn setAppId(self: *ICustomDestinationList, id: [*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.SetAppID(self, id));
    }

    /// The removed-destinations array that `BeginList` hands back is
    /// released at once: the list has tasks only.
    pub fn beginList(self: *ICustomDestinationList) foundation.Error!void {
        var min_slots: u32 = 0;
        var removed: ?*anyopaque = null;
        try foundation.check(self.vtable.BeginList(self, &min_slots, &IID_IObjectArray, &removed));
        if (removed) |r| com.release(@as(*IObjectArray, @ptrCast(@alignCast(r))));
    }

    pub inline fn addUserTasks(self: *ICustomDestinationList, tasks: *IObjectArray) foundation.Error!void {
        try foundation.check(self.vtable.AddUserTasks(self, tasks));
    }

    pub inline fn commitList(self: *ICustomDestinationList) foundation.Error!void {
        try foundation.check(self.vtable.CommitList(self));
    }

    pub inline fn deleteList(self: *ICustomDestinationList, id: ?[*:0]const u16) foundation.Error!void {
        try foundation.check(self.vtable.DeleteList(self, id));
    }

    pub inline fn abortList(self: *ICustomDestinationList) void {
        _ = self.vtable.AbortList(self);
    }
};

const ptr = @sizeOf(usize);

test "win32 shobjidl: vtable slot counts" {
    try std.testing.expectEqual(12 * ptr, @sizeOf(ICustomDestinationList.VTable));
    try std.testing.expectEqual(21 * ptr, @sizeOf(IShellLinkW.VTable));
    try std.testing.expectEqual(5 * ptr, @sizeOf(IObjectArray.VTable));
    try std.testing.expectEqual(9 * ptr, @sizeOf(IObjectCollection.VTable));
    try std.testing.expectEqual(8 * ptr, @sizeOf(IPropertyStore.VTable));
}

test "win32 shobjidl: slot offsets of the called methods" {
    try std.testing.expectEqual(3 * ptr, @offsetOf(ICustomDestinationList.VTable, "SetAppID"));
    try std.testing.expectEqual(4 * ptr, @offsetOf(ICustomDestinationList.VTable, "BeginList"));
    try std.testing.expectEqual(7 * ptr, @offsetOf(ICustomDestinationList.VTable, "AddUserTasks"));
    try std.testing.expectEqual(8 * ptr, @offsetOf(ICustomDestinationList.VTable, "CommitList"));
    try std.testing.expectEqual(10 * ptr, @offsetOf(ICustomDestinationList.VTable, "DeleteList"));
    try std.testing.expectEqual(11 * ptr, @offsetOf(ICustomDestinationList.VTable, "AbortList"));
    try std.testing.expectEqual(7 * ptr, @offsetOf(IShellLinkW.VTable, "SetDescription"));
    try std.testing.expectEqual(9 * ptr, @offsetOf(IShellLinkW.VTable, "SetWorkingDirectory"));
    try std.testing.expectEqual(11 * ptr, @offsetOf(IShellLinkW.VTable, "SetArguments"));
    try std.testing.expectEqual(17 * ptr, @offsetOf(IShellLinkW.VTable, "SetIconLocation"));
    try std.testing.expectEqual(20 * ptr, @offsetOf(IShellLinkW.VTable, "SetPath"));
    try std.testing.expectEqual(5 * ptr, @offsetOf(IObjectCollection.VTable, "AddObject"));
    try std.testing.expectEqual(6 * ptr, @offsetOf(IPropertyStore.VTable, "SetValue"));
    try std.testing.expectEqual(7 * ptr, @offsetOf(IPropertyStore.VTable, "Commit"));
}

test "win32 shobjidl: PROPVARIANT size" {
    try std.testing.expectEqual(8 + 2 * ptr, @sizeOf(PROPVARIANT));
}

test "win32 shobjidl: property keys" {
    try std.testing.expectEqual(@as(u32, 6), PKEY_AppUserModel_IsDestListSeparator.pid);
    try std.testing.expectEqual(@as(u32, 2), PKEY_Title.pid);
    try std.testing.expectEqual(@as(u32, 0x9f4c2855), PKEY_AppUserModel_IsDestListSeparator.fmtid.Data1);
}
