//! WinRT activation bindings for the toast notifications (M3 Task 18). The
//! `Ro*` and `Windows*String` entry points are resolved lazily from
//! `combase.dll` (System32 only); runtimeobject is never linked. IIDs and
//! slot positions are from the Windows SDK 10.0.26100 headers
//! (`windows.ui.notifications.h`, `windows.data.xml.dom.h`).
const std = @import("std");
const foundation = @import("foundation.zig");
const kernel32 = @import("kernel32.zig");
const com = @import("com.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const BOOL = foundation.BOOL;

/// A WinRT string handle; null is the empty string.
pub const HSTRING = ?*opaque {};

/// `EventRegistrationToken`.
pub const EventRegistrationToken = extern struct { value: i64 = 0 };

pub const IAgileObject_iid = GUID.parse("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");

pub const IInspectable = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IInspectable, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IInspectable) callconv(.winapi) u32,
        Release: *const fn (*IInspectable) callconv(.winapi) u32,
        GetIids: *const fn (*IInspectable, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
        GetRuntimeClassName: *const fn (*IInspectable, *HSTRING) callconv(.winapi) HRESULT,
        GetTrustLevel: *const fn (*IInspectable, *i32) callconv(.winapi) HRESULT,
    };
};

/// `Windows.Data.Xml.Dom.IXmlDocumentIO`: reached by `QueryInterface` on the
/// `XmlDocument` instance.
pub const IXmlDocumentIO = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");

    pub const VTable = extern struct {
        base: IInspectable.VTable,
        LoadXml: *const fn (*IXmlDocumentIO, HSTRING) callconv(.winapi) HRESULT,
        LoadXmlWithSettings: *const anyopaque,
        SaveToFileAsync: *const anyopaque,
    };

    pub inline fn loadXml(self: *IXmlDocumentIO, xml: HSTRING) foundation.Error!void {
        try foundation.check(self.vtable.LoadXml(self, xml));
    }
};

/// The `IXmlDocument` of an `XmlDocument` is its default interface: the
/// `IInspectable` that `RoActivateInstance` returns is passed on as it is.
pub const IXmlDocument = IInspectable;

pub const IToastNotificationManagerStatics = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
    pub const class_name = "Windows.UI.Notifications.ToastNotificationManager";

    pub const VTable = extern struct {
        base: IInspectable.VTable,
        CreateToastNotifier: *const anyopaque,
        CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, HSTRING, *?*IToastNotifier) callconv(.winapi) HRESULT,
        GetTemplateContent: *const anyopaque,
    };

    pub inline fn createToastNotifierWithId(self: *IToastNotificationManagerStatics, app_id: HSTRING) foundation.Error!*IToastNotifier {
        var out: ?*IToastNotifier = null;
        try foundation.check(self.vtable.CreateToastNotifierWithId(self, app_id, &out));
        return out orelse error.ComFailure;
    }
};

pub const IToastNotifier = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("75927b93-03f3-41ec-91d3-6e5bac1b38e7");

    pub const VTable = extern struct {
        base: IInspectable.VTable,
        Show: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) HRESULT,
        Hide: *const anyopaque,
        get_Setting: *const anyopaque,
        AddToSchedule: *const anyopaque,
        RemoveFromSchedule: *const anyopaque,
        GetScheduledToastNotifications: *const anyopaque,
    };

    pub inline fn show(self: *IToastNotifier, toast: *IToastNotification) foundation.Error!void {
        try foundation.check(self.vtable.Show(self, toast));
    }
};

pub const IToastNotificationFactory = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("04124b20-82c6-4229-b109-fd9ed4662b53");
    pub const class_name = "Windows.UI.Notifications.ToastNotification";

    pub const VTable = extern struct {
        base: IInspectable.VTable,
        CreateToastNotification: *const fn (*IToastNotificationFactory, *IXmlDocument, *?*IToastNotification) callconv(.winapi) HRESULT,
    };

    pub inline fn createToastNotification(self: *IToastNotificationFactory, content: *IXmlDocument) foundation.Error!*IToastNotification {
        var out: ?*IToastNotification = null;
        try foundation.check(self.vtable.CreateToastNotification(self, content, &out));
        return out orelse error.ComFailure;
    }
};

pub const IToastNotification = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("997e2675-059e-4e60-8b06-1760917c8b80");

    pub const VTable = extern struct {
        base: IInspectable.VTable,
        get_Content: *const anyopaque,
        put_ExpirationTime: *const anyopaque,
        get_ExpirationTime: *const anyopaque,
        add_Dismissed: *const anyopaque,
        remove_Dismissed: *const anyopaque,
        add_Activated: *const fn (*IToastNotification, *ToastActivatedHandler, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_Activated: *const anyopaque,
        add_Failed: *const anyopaque,
        remove_Failed: *const anyopaque,
    };

    /// The notification takes its own reference on `handler`.
    pub inline fn addActivated(self: *IToastNotification, handler: *ToastActivatedHandler) foundation.Error!EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        try foundation.check(self.vtable.add_Activated(self, handler, &token));
        return token;
    }
};

/// `TypedEventHandler<ToastNotification, IInspectable>`: the delegate that
/// `IToastNotification.add_Activated` takes. The object behind it is the
/// caller's (it implements `IUnknown` plus `Invoke`).
pub const ToastActivatedHandler = extern struct {
    vtable: *const VTable,

    /// The parametric IID `ab54de2d-97d9-5528-b6ad-105afe156530`. The header
    /// only declares it `EXTERN_C` (the value lives in the SDK libraries), so
    /// it is derived the way WinRT does: UUIDv5 over the WinRT namespace and
    /// the signature
    /// `pinterface({9de1c534-6ae1-11e0-84e1-18a905bcc53f};rc(Windows.UI.Notifications.ToastNotification;{997e2675-059e-4e60-8b06-1760917c8b80});cinterface(IInspectable))`.
    /// The same derivation gives `548cefbd-bc8a-5fa0-8df2-957440fc8bf4` for
    /// `IReference<Int32>`, the value Windows documents.
    pub const iid = GUID.parse("ab54de2d-97d9-5528-b6ad-105afe156530");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ToastActivatedHandler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ToastActivatedHandler) callconv(.winapi) u32,
        Release: *const fn (*ToastActivatedHandler) callconv(.winapi) u32,
        Invoke: *const fn (*ToastActivatedHandler, ?*IToastNotification, ?*IInspectable) callconv(.winapi) HRESULT,
    };
};

// -- Lazily resolved entry points -------------------------------------------

const RoGetActivationFactoryFn = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const RoActivateInstanceFn = *const fn (HSTRING, *?*IInspectable) callconv(.winapi) HRESULT;
const WindowsCreateStringFn = *const fn ([*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT;
const WindowsDeleteStringFn = *const fn (HSTRING) callconv(.winapi) HRESULT;
const WindowsGetStringRawBufferFn = *const fn (HSTRING, ?*u32) callconv(.winapi) ?[*]const u16;

pub const Api = struct {
    RoGetActivationFactory: RoGetActivationFactoryFn,
    RoActivateInstance: RoActivateInstanceFn,
    WindowsCreateString: WindowsCreateStringFn,
    WindowsDeleteString: WindowsDeleteStringFn,
    WindowsGetStringRawBuffer: WindowsGetStringRawBufferFn,
};

/// 0 not tried, 1 resolved, 2 unavailable. Written on the UI thread only.
var api_state: u8 = 0;
var api_value: Api = undefined;

/// The entry points, resolved on first use; null where WinRT is unavailable.
pub fn api() ?*const Api {
    switch (api_state) {
        1 => return &api_value,
        2 => return null,
        else => {},
    }
    api_state = 2;
    const module = kernel32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("combase.dll"),
        null,
        kernel32.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return null;
    const names = .{ "RoGetActivationFactory", "RoActivateInstance", "WindowsCreateString", "WindowsDeleteString", "WindowsGetStringRawBuffer" };
    inline for (names) |name| {
        const proc = kernel32.GetProcAddress(module, name) orelse return null;
        @field(api_value, name) = @ptrCast(proc);
    }
    api_state = 1;
    return &api_value;
}

pub const Error = foundation.Error || error{WinRtUnavailable};

/// An owned `HSTRING`.
pub const String = struct {
    handle: HSTRING = null,

    /// `text` need not be NUL terminated.
    pub fn init(text: []const u16) Error!String {
        const a = api() orelse return error.WinRtUnavailable;
        var handle: HSTRING = null;
        try foundation.check(a.WindowsCreateString(text.ptr, @intCast(text.len), &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *String) void {
        if (self.handle == null) return;
        if (api()) |a| _ = a.WindowsDeleteString(self.handle);
        self.handle = null;
    }

    pub fn slice(self: String) []const u16 {
        const a = api() orelse return &.{};
        var len: u32 = 0;
        const ptr = a.WindowsGetStringRawBuffer(self.handle, &len) orelse return &.{};
        return ptr[0..len];
    }
};

/// The activation factory of `class_name` as interface `T` (which carries
/// the IID). The caller releases it.
pub fn getActivationFactory(comptime T: type, comptime class_name: []const u8) Error!*T {
    const a = api() orelse return error.WinRtUnavailable;
    var name = try String.init(std.unicode.utf8ToUtf16LeStringLiteral(class_name));
    defer name.deinit();
    var out: ?*anyopaque = null;
    try foundation.check(a.RoGetActivationFactory(name.handle, &T.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

/// A new instance of `class_name`, as its default interface. The caller
/// releases it.
pub fn activateInstance(comptime class_name: []const u8) Error!*IInspectable {
    const a = api() orelse return error.WinRtUnavailable;
    var name = try String.init(std.unicode.utf8ToUtf16LeStringLiteral(class_name));
    defer name.deinit();
    var out: ?*IInspectable = null;
    try foundation.check(a.RoActivateInstance(name.handle, &out));
    return out orelse error.ComFailure;
}
