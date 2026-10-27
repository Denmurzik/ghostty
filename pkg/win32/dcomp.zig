//! dcomp.dll bindings (DirectComposition): full slot lists of IDCompositionDevice,
//! IDCompositionTarget and IDCompositionVisual from dcomp.h of SDK 10.0.26100;
//! slots become typed as consumers need them.
//! `DCompositionCreateDevice2` is resolved lazily through `LoadLibraryExW(SYSTEM32)` +
//! `GetProcAddress`; dcomp is never imported or linked.
const std = @import("std");
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const kernel32 = @import("kernel32.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const BOOL = foundation.BOOL;
const HWND = foundation.HWND;
const Error = foundation.Error;
const check = foundation.check;
const IUnknown = com.IUnknown;

/// DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED: `CreateTargetForHwnd` on a window
/// that already has a target (or a flip-model hwnd swap chain).
pub const ERROR_WINDOW_ALREADY_COMPOSED: HRESULT = @bitCast(@as(u32, 0x88980800));

/// DCOMPOSITION_COMPOSITE_MODE
pub const CompositeMode = enum(u32) {
    SOURCE_OVER = 0,
    DESTINATION_INVERT = 1,
    MIN_BLEND = 2,
    _,
};

const CreateDevice2Fn = *const fn (?*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;

/// Resolved on first use; the module stays loaded for the life of the process.
/// Not synchronized: only called from the UI thread.
var create_device2: ?CreateDevice2Fn = null;

fn resolveCreateDevice2() error{DCompUnavailable}!CreateDevice2Fn {
    if (create_device2) |f| return f;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll");
    const module = kernel32.LoadLibraryExW(name, null, kernel32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse
        return error.DCompUnavailable;
    const proc = kernel32.GetProcAddress(module, "DCompositionCreateDevice2") orelse
        return error.DCompUnavailable;
    create_device2 = @ptrCast(proc);
    return create_device2.?;
}

/// Creates a DirectComposition device. `rendering` is the IDXGIDevice or ID2D1Device
/// the surfaces are created on, or null for a device that owns none (it then
/// only accepts swap chains and keeps working when the D3D device is recreated).
pub fn createDevice(rendering: anytype) (Error || error{DCompUnavailable})!*IDCompositionDevice {
    const f = try resolveCreateDevice2();
    var out: ?*anyopaque = null;
    const unknown: ?*IUnknown = if (@TypeOf(rendering) == @TypeOf(null)) null else @ptrCast(rendering);
    try check(f(unknown, &IDCompositionDevice.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

pub const IDCompositionDevice = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("c37ea93a-e7aa-450d-b16f-9746cb0407f3");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        Commit: *const fn (*IDCompositionDevice) callconv(.winapi) HRESULT,
        WaitForCommitCompletion: *const fn (*IDCompositionDevice) callconv(.winapi) HRESULT,
        GetFrameStatistics: *const anyopaque,
        CreateTargetForHwnd: *const fn (*IDCompositionDevice, HWND, BOOL, *?*IDCompositionTarget) callconv(.winapi) HRESULT,
        CreateVisual: *const fn (*IDCompositionDevice, *?*IDCompositionVisual) callconv(.winapi) HRESULT,
        CreateSurface: *const anyopaque,
        CreateVirtualSurface: *const anyopaque,
        CreateSurfaceFromHandle: *const anyopaque,
        CreateSurfaceFromHwnd: *const anyopaque,
        CreateTranslateTransform: *const anyopaque,
        CreateScaleTransform: *const anyopaque,
        CreateRotateTransform: *const anyopaque,
        CreateSkewTransform: *const anyopaque,
        CreateMatrixTransform: *const anyopaque,
        CreateTransformGroup: *const anyopaque,
        CreateTranslateTransform3D: *const anyopaque,
        CreateScaleTransform3D: *const anyopaque,
        CreateRotateTransform3D: *const anyopaque,
        CreateMatrixTransform3D: *const anyopaque,
        CreateTransform3DGroup: *const anyopaque,
        CreateEffectGroup: *const anyopaque,
        CreateRectangleClip: *const anyopaque,
        CreateAnimation: *const anyopaque,
        CheckDeviceState: *const fn (*IDCompositionDevice, *BOOL) callconv(.winapi) HRESULT,
    };

    pub inline fn commit(self: *IDCompositionDevice) Error!void {
        try check(self.vtable.Commit(self));
    }

    pub inline fn waitForCommitCompletion(self: *IDCompositionDevice) Error!void {
        try check(self.vtable.WaitForCommitCompletion(self));
    }

    /// `topmost` puts the visual tree above the window's own content (and its
    /// child windows' content are then composed below it).
    pub inline fn createTargetForHwnd(self: *IDCompositionDevice, hwnd: HWND, topmost: bool) Error!*IDCompositionTarget {
        var out: ?*IDCompositionTarget = null;
        try check(self.vtable.CreateTargetForHwnd(self, hwnd, @intFromBool(topmost), &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createVisual(self: *IDCompositionDevice) Error!*IDCompositionVisual {
        var out: ?*IDCompositionVisual = null;
        try check(self.vtable.CreateVisual(self, &out));
        return out orelse error.ComFailure;
    }

    /// False once the D3D device the surfaces live on, or DWM's, was lost.
    pub inline fn checkDeviceState(self: *IDCompositionDevice) Error!bool {
        var valid: BOOL = 0;
        try check(self.vtable.CheckDeviceState(self, &valid));
        return valid != 0;
    }
};

pub const IDCompositionTarget = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("eacdd04c-117e-4e17-88f4-d1b12b0e3d89");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetRoot: *const fn (*IDCompositionTarget, ?*IDCompositionVisual) callconv(.winapi) HRESULT,
    };

    pub inline fn setRoot(self: *IDCompositionTarget, visual: ?*IDCompositionVisual) Error!void {
        try check(self.vtable.SetRoot(self, visual));
    }
};

pub const IDCompositionVisual = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("4d93059d-097b-4651-9a60-f0f25116e2f3");

    /// SetOffsetX/SetOffsetY/SetTransform/SetClip are overloaded in dcomp.h
    /// (float/matrix/rect vs animation/transform/clip); the order MSVC gives
    /// the overloads in the vtable is unverified, so they stay untyped.
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetOffsetX_a: *const anyopaque,
        SetOffsetX_b: *const anyopaque,
        SetOffsetY_a: *const anyopaque,
        SetOffsetY_b: *const anyopaque,
        SetTransform_a: *const anyopaque,
        SetTransform_b: *const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClip_a: *const anyopaque,
        SetClip_b: *const anyopaque,
        SetContent: *const fn (*IDCompositionVisual, ?*IUnknown) callconv(.winapi) HRESULT,
        AddVisual: *const fn (*IDCompositionVisual, *IDCompositionVisual, BOOL, ?*IDCompositionVisual) callconv(.winapi) HRESULT,
        RemoveVisual: *const fn (*IDCompositionVisual, *IDCompositionVisual) callconv(.winapi) HRESULT,
        RemoveAllVisuals: *const fn (*IDCompositionVisual) callconv(.winapi) HRESULT,
        SetCompositeMode: *const fn (*IDCompositionVisual, CompositeMode) callconv(.winapi) HRESULT,
    };

    /// `content` is a composition swap chain (or surface) as any COM pointer,
    /// null to clear.
    pub inline fn setContent(self: *IDCompositionVisual, content: anytype) Error!void {
        const unknown: ?*IUnknown = if (@TypeOf(content) == @TypeOf(null)) null else @ptrCast(content);
        try check(self.vtable.SetContent(self, unknown));
    }

    pub inline fn addVisual(self: *IDCompositionVisual, visual: *IDCompositionVisual, insert_above: bool, reference: ?*IDCompositionVisual) Error!void {
        try check(self.vtable.AddVisual(self, visual, @intFromBool(insert_above), reference));
    }

    pub inline fn removeVisual(self: *IDCompositionVisual, visual: *IDCompositionVisual) Error!void {
        try check(self.vtable.RemoveVisual(self, visual));
    }

    pub inline fn removeAllVisuals(self: *IDCompositionVisual) Error!void {
        try check(self.vtable.RemoveAllVisuals(self));
    }
};
