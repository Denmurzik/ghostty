//! Direct2D 1.0 bindings (d2d1.h of SDK 10.0.26100): the factory, the
//! render-target family and solid brushes behind the tab-strip chrome
//! painter. Full slot lists; slots become typed as consumers need them.
//! Struct-returning slots (GetSize, GetPixelFormat, GetColor, ...) stay
//! untyped: the C++ ABI passes a hidden return pointer there.
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const dwrite = @import("dwrite.zig");
const user32 = @import("user32.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const HWND = foundation.HWND;
const RECT = foundation.RECT;
const Error = foundation.Error;
const check = foundation.check;
const IUnknown = com.IUnknown;
const HDC = user32.HDC;

/// EndDraw result: the target (device) is gone and must be recreated.
pub const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

/// D2D1_FACTORY_TYPE
pub const FactoryType = enum(u32) {
    SINGLE_THREADED = 0,
    MULTI_THREADED = 1,
};

/// D2D1_ALPHA_MODE
pub const AlphaMode = enum(u32) {
    UNKNOWN = 0,
    PREMULTIPLIED = 1,
    STRAIGHT = 2,
    IGNORE = 3,
};

/// D2D1_RENDER_TARGET_TYPE
pub const RenderTargetType = enum(u32) {
    DEFAULT = 0,
    SOFTWARE = 1,
    HARDWARE = 2,
};

/// D2D1_RENDER_TARGET_USAGE flags.
pub const RENDER_TARGET_USAGE_NONE: u32 = 0;
pub const RENDER_TARGET_USAGE_GDI_COMPATIBLE: u32 = 2;

/// D2D1_FEATURE_LEVEL_DEFAULT
pub const FEATURE_LEVEL_DEFAULT: u32 = 0;

/// D2D1_PRESENT_OPTIONS flags.
pub const PRESENT_OPTIONS_NONE: u32 = 0;
pub const PRESENT_OPTIONS_IMMEDIATELY: u32 = 2;

/// D2D1_ANTIALIAS_MODE
pub const AntialiasMode = enum(u32) {
    PER_PRIMITIVE = 0,
    ALIASED = 1,
};

/// D2D1_TEXT_ANTIALIAS_MODE
pub const TextAntialiasMode = enum(u32) {
    DEFAULT = 0,
    CLEARTYPE = 1,
    GRAYSCALE = 2,
    ALIASED = 3,
};

/// D2D1_DRAW_TEXT_OPTIONS flags.
pub const DRAW_TEXT_OPTIONS_NONE: u32 = 0;
pub const DRAW_TEXT_OPTIONS_NO_SNAP: u32 = 1;
pub const DRAW_TEXT_OPTIONS_CLIP: u32 = 2;
pub const DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT: u32 = 4;

pub const D2D1_COLOR_F = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const D2D1_POINT_2F = extern struct {
    x: f32,
    y: f32,
};

pub const D2D1_SIZE_U = extern struct {
    width: u32,
    height: u32,
};

pub const D2D1_RECT_F = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

pub const D2D1_ROUNDED_RECT = extern struct {
    rect: D2D1_RECT_F,
    radiusX: f32,
    radiusY: f32,
};

pub const D2D1_MATRIX_3X2_F = extern struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx: f32,
    dy: f32,

    pub const identity: D2D1_MATRIX_3X2_F = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 };
};

pub const D2D1_PIXEL_FORMAT = extern struct {
    format: dxgi.Format,
    alphaMode: AlphaMode,
};

pub const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: RenderTargetType = .DEFAULT,
    pixelFormat: D2D1_PIXEL_FORMAT = .{ .format = .UNKNOWN, .alphaMode = .UNKNOWN },
    /// 0 selects the desktop DPI.
    dpiX: f32 = 0,
    dpiY: f32 = 0,
    usage: u32 = RENDER_TARGET_USAGE_NONE,
    minLevel: u32 = FEATURE_LEVEL_DEFAULT,
};

pub const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: HWND,
    pixelSize: D2D1_SIZE_U,
    presentOptions: u32 = PRESENT_OPTIONS_NONE,
};

extern "d2d1" fn D2D1CreateFactory(
    factoryType: FactoryType,
    riid: *const GUID,
    options: ?*const anyopaque,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Creates a single-threaded Direct2D factory (no debug layer). The factory
/// and every target it makes must stay on one thread.
pub fn createFactory() Error!*ID2D1Factory {
    var out: ?*anyopaque = null;
    try check(D2D1CreateFactory(.SINGLE_THREADED, &ID2D1Factory.iid, null, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

/// Maps an `EndDraw` HRESULT: a lost target is `error.DeviceLost`, anything
/// else goes through `check`.
pub fn checkEndDraw(hr: HRESULT) Error!void {
    if (hr == D2DERR_RECREATE_TARGET) return error.DeviceLost;
    try check(hr);
}

pub const ID2D1Resource = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2cd90691-12e2-11dc-9fed-001143a055f9");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFactory: *const anyopaque,
    };
};

pub const ID2D1Brush = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2cd906a8-12e2-11dc-9fed-001143a055f9");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        SetOpacity: *const anyopaque,
        SetTransform: *const anyopaque,
        GetOpacity: *const anyopaque,
        GetTransform: *const anyopaque,
    };
};

pub const ID2D1SolidColorBrush = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2cd906a9-12e2-11dc-9fed-001143a055f9");

    pub const VTable = extern struct {
        base: ID2D1Brush.VTable,
        SetColor: *const fn (*ID2D1SolidColorBrush, *const D2D1_COLOR_F) callconv(.winapi) void,
        GetColor: *const anyopaque,
    };

    pub inline fn asBrush(self: *ID2D1SolidColorBrush) *ID2D1Brush {
        return @ptrCast(self);
    }

    pub inline fn setColor(self: *ID2D1SolidColorBrush, color: D2D1_COLOR_F) void {
        self.vtable.SetColor(self, &color);
    }
};

pub const ID2D1RenderTarget = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2cd90694-12e2-11dc-9fed-001143a055f9");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        CreateBitmap: *const anyopaque,
        CreateBitmapFromWicBitmap: *const anyopaque,
        CreateSharedBitmap: *const anyopaque,
        CreateBitmapBrush: *const anyopaque,
        CreateSolidColorBrush: *const fn (*ID2D1RenderTarget, *const D2D1_COLOR_F, ?*const anyopaque, *?*ID2D1SolidColorBrush) callconv(.winapi) HRESULT,
        CreateGradientStopCollection: *const anyopaque,
        CreateLinearGradientBrush: *const anyopaque,
        CreateRadialGradientBrush: *const anyopaque,
        CreateCompatibleRenderTarget: *const anyopaque,
        CreateLayer: *const anyopaque,
        CreateMesh: *const anyopaque,
        DrawLine: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, D2D1_POINT_2F, *ID2D1Brush, f32, ?*anyopaque) callconv(.winapi) void,
        DrawRectangle: *const anyopaque,
        FillRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1Brush) callconv(.winapi) void,
        DrawRoundedRectangle: *const anyopaque,
        FillRoundedRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_ROUNDED_RECT, *ID2D1Brush) callconv(.winapi) void,
        DrawEllipse: *const anyopaque,
        FillEllipse: *const anyopaque,
        DrawGeometry: *const anyopaque,
        FillGeometry: *const anyopaque,
        FillMesh: *const anyopaque,
        FillOpacityMask: *const anyopaque,
        DrawBitmap: *const anyopaque,
        DrawText: *const anyopaque,
        DrawTextLayout: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, *dwrite.IDWriteTextLayout, *ID2D1Brush, u32) callconv(.winapi) void,
        DrawGlyphRun: *const anyopaque,
        SetTransform: *const fn (*ID2D1RenderTarget, *const D2D1_MATRIX_3X2_F) callconv(.winapi) void,
        GetTransform: *const anyopaque,
        SetAntialiasMode: *const anyopaque,
        GetAntialiasMode: *const anyopaque,
        SetTextAntialiasMode: *const fn (*ID2D1RenderTarget, TextAntialiasMode) callconv(.winapi) void,
        GetTextAntialiasMode: *const anyopaque,
        SetTextRenderingParams: *const anyopaque,
        GetTextRenderingParams: *const anyopaque,
        SetTags: *const anyopaque,
        GetTags: *const anyopaque,
        PushLayer: *const anyopaque,
        PopLayer: *const anyopaque,
        Flush: *const anyopaque,
        SaveDrawingState: *const anyopaque,
        RestoreDrawingState: *const anyopaque,
        PushAxisAlignedClip: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, AntialiasMode) callconv(.winapi) void,
        PopAxisAlignedClip: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        Clear: *const fn (*ID2D1RenderTarget, ?*const D2D1_COLOR_F) callconv(.winapi) void,
        BeginDraw: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        EndDraw: *const fn (*ID2D1RenderTarget, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        GetPixelFormat: *const anyopaque,
        SetDpi: *const anyopaque,
        GetDpi: *const anyopaque,
        GetSize: *const anyopaque,
        GetPixelSize: *const anyopaque,
        GetMaximumBitmapSize: *const anyopaque,
        IsSupported: *const anyopaque,
    };

    pub inline fn createSolidColorBrush(self: *ID2D1RenderTarget, color: D2D1_COLOR_F) Error!*ID2D1SolidColorBrush {
        var out: ?*ID2D1SolidColorBrush = null;
        try check(self.vtable.CreateSolidColorBrush(self, &color, null, &out));
        return out orelse error.ComFailure;
    }

    /// A null `color` clears to transparent black.
    pub inline fn clear(self: *ID2D1RenderTarget, color: ?D2D1_COLOR_F) void {
        if (color) |c| self.vtable.Clear(self, &c) else self.vtable.Clear(self, null);
    }

    pub inline fn fillRectangle(self: *ID2D1RenderTarget, rect: D2D1_RECT_F, brush: *ID2D1Brush) void {
        self.vtable.FillRectangle(self, &rect, brush);
    }

    pub inline fn fillRoundedRectangle(self: *ID2D1RenderTarget, rect: D2D1_ROUNDED_RECT, brush: *ID2D1Brush) void {
        self.vtable.FillRoundedRectangle(self, &rect, brush);
    }

    pub inline fn drawLine(
        self: *ID2D1RenderTarget,
        p0: D2D1_POINT_2F,
        p1: D2D1_POINT_2F,
        brush: *ID2D1Brush,
        stroke_width: f32,
    ) void {
        self.vtable.DrawLine(self, p0, p1, brush, stroke_width, null);
    }

    /// `options` are `DRAW_TEXT_OPTIONS_*` bits.
    pub inline fn drawTextLayout(
        self: *ID2D1RenderTarget,
        origin: D2D1_POINT_2F,
        layout: *dwrite.IDWriteTextLayout,
        brush: *ID2D1Brush,
        options: u32,
    ) void {
        self.vtable.DrawTextLayout(self, origin, layout, brush, options);
    }

    pub inline fn pushAxisAlignedClip(self: *ID2D1RenderTarget, rect: D2D1_RECT_F, mode: AntialiasMode) void {
        self.vtable.PushAxisAlignedClip(self, &rect, mode);
    }

    pub inline fn popAxisAlignedClip(self: *ID2D1RenderTarget) void {
        self.vtable.PopAxisAlignedClip(self);
    }

    pub inline fn setTextAntialiasMode(self: *ID2D1RenderTarget, mode: TextAntialiasMode) void {
        self.vtable.SetTextAntialiasMode(self, mode);
    }

    pub inline fn setTransform(self: *ID2D1RenderTarget, transform: D2D1_MATRIX_3X2_F) void {
        self.vtable.SetTransform(self, &transform);
    }

    pub inline fn beginDraw(self: *ID2D1RenderTarget) void {
        self.vtable.BeginDraw(self);
    }

    /// `D2DERR_RECREATE_TARGET` surfaces as `error.DeviceLost` (not logged).
    pub inline fn endDraw(self: *ID2D1RenderTarget) Error!void {
        try checkEndDraw(self.vtable.EndDraw(self, null, null));
    }
};

pub const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2cd90698-12e2-11dc-9fed-001143a055f9");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        CheckWindowState: *const anyopaque,
        Resize: *const fn (*ID2D1HwndRenderTarget, *const D2D1_SIZE_U) callconv(.winapi) HRESULT,
        GetHwnd: *const anyopaque,
    };

    pub inline fn asRenderTarget(self: *ID2D1HwndRenderTarget) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    pub inline fn resize(self: *ID2D1HwndRenderTarget, width: u32, height: u32) Error!void {
        try check(self.vtable.Resize(self, &.{ .width = width, .height = height }));
    }
};

pub const ID2D1DCRenderTarget = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("1c51bc64-de61-46fd-9899-63a5d8f03950");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        BindDC: *const fn (*ID2D1DCRenderTarget, HDC, *const RECT) callconv(.winapi) HRESULT,
    };

    pub inline fn asRenderTarget(self: *ID2D1DCRenderTarget) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    /// Binds the target to the `rect` area of `hdc`; call it again whenever
    /// the DC or the drawn area changes.
    pub inline fn bindDC(self: *ID2D1DCRenderTarget, hdc: HDC, rect: RECT) Error!void {
        try check(self.vtable.BindDC(self, hdc, &rect));
    }
};

pub const ID2D1Factory = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("06152247-6f50-465a-9245-118bfd3b6007");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        ReloadSystemMetrics: *const anyopaque,
        GetDesktopDpi: *const anyopaque,
        CreateRectangleGeometry: *const anyopaque,
        CreateRoundedRectangleGeometry: *const anyopaque,
        CreateEllipseGeometry: *const anyopaque,
        CreateGeometryGroup: *const anyopaque,
        CreateTransformedGeometry: *const anyopaque,
        CreatePathGeometry: *const anyopaque,
        CreateStrokeStyle: *const anyopaque,
        CreateDrawingStateBlock: *const anyopaque,
        CreateWicBitmapRenderTarget: *const anyopaque,
        CreateHwndRenderTarget: *const fn (*ID2D1Factory, *const D2D1_RENDER_TARGET_PROPERTIES, *const D2D1_HWND_RENDER_TARGET_PROPERTIES, *?*ID2D1HwndRenderTarget) callconv(.winapi) HRESULT,
        CreateDxgiSurfaceRenderTarget: *const anyopaque,
        CreateDCRenderTarget: *const fn (*ID2D1Factory, *const D2D1_RENDER_TARGET_PROPERTIES, *?*ID2D1DCRenderTarget) callconv(.winapi) HRESULT,
    };

    pub inline fn createDCRenderTarget(self: *ID2D1Factory, props: D2D1_RENDER_TARGET_PROPERTIES) Error!*ID2D1DCRenderTarget {
        var out: ?*ID2D1DCRenderTarget = null;
        try check(self.vtable.CreateDCRenderTarget(self, &props, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createHwndRenderTarget(
        self: *ID2D1Factory,
        props: D2D1_RENDER_TARGET_PROPERTIES,
        hwnd_props: D2D1_HWND_RENDER_TARGET_PROPERTIES,
    ) Error!*ID2D1HwndRenderTarget {
        var out: ?*ID2D1HwndRenderTarget = null;
        try check(self.vtable.CreateHwndRenderTarget(self, &props, &hwnd_props, &out));
        return out orelse error.ComFailure;
    }
};
