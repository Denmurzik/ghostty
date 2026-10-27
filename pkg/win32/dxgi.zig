//! DXGI bindings: factory/adapter/device/swap-chain interfaces (full slot
//! lists from dxgi.h, dxgi1_2.h, dxgi1_3.h of SDK 10.0.26100; slots become
//! typed as consumers need them) and `createFactory`.
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const BOOL = foundation.BOOL;
const HWND = foundation.HWND;
const HANDLE = foundation.HANDLE;
const Error = foundation.Error;
const check = foundation.check;
const IUnknown = com.IUnknown;

/// DXGI_FORMAT (dxgiformat.h). Non-exhaustive; add members as needed.
pub const Format = enum(u32) {
    UNKNOWN = 0,
    R32G32B32A32_FLOAT = 2,
    R16G16B16A16_FLOAT = 10,
    R16G16B16A16_UNORM = 11,
    R32G32_FLOAT = 16,
    R32G32_UINT = 17,
    R10G10B10A2_UNORM = 24,
    R8G8B8A8_TYPELESS = 27,
    R8G8B8A8_UNORM = 28,
    R8G8B8A8_UNORM_SRGB = 29,
    R16G16_UINT = 36,
    R32_FLOAT = 41,
    R32_UINT = 42,
    R8G8_UNORM = 49,
    R16_UNORM = 56,
    R8_UNORM = 61,
    A8_UNORM = 65,
    B8G8R8A8_UNORM = 87,
    B8G8R8X8_UNORM = 88,
    B8G8R8A8_TYPELESS = 90,
    B8G8R8A8_UNORM_SRGB = 91,
    B8G8R8X8_UNORM_SRGB = 93,
    _,
};

/// DXGI_SAMPLE_DESC
pub const SAMPLE_DESC = extern struct {
    Count: u32,
    Quality: u32,
};

/// DXGI_STATUS_OCCLUDED: a success code from `Present` meaning the window
/// is not visible and nothing was presented.
pub const STATUS_OCCLUDED: HRESULT = 0x087A0001;

/// DXGI_USAGE_RENDER_TARGET_OUTPUT
pub const USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;

/// DXGI_SWAP_CHAIN_FLAG members used so far.
pub const SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 0x40;
pub const SWAP_CHAIN_FLAG_ALLOW_TEARING: u32 = 0x800;

/// DXGI_PRESENT_ALLOW_TEARING
pub const PRESENT_ALLOW_TEARING: u32 = 0x200;

/// DXGI_MWA_* flags of `MakeWindowAssociation`.
pub const MWA_NO_WINDOW_CHANGES: u32 = 1 << 0;
pub const MWA_NO_ALT_ENTER: u32 = 1 << 1;

/// DXGI_SCALING
pub const Scaling = enum(u32) {
    STRETCH = 0,
    NONE = 1,
    ASPECT_RATIO_STRETCH = 2,
};

/// DXGI_SWAP_EFFECT. Non-exhaustive; only the flip models are listed.
pub const SwapEffect = enum(u32) {
    FLIP_SEQUENTIAL = 3,
    FLIP_DISCARD = 4,
    _,
};

/// DXGI_ALPHA_MODE
pub const AlphaMode = enum(u32) {
    UNSPECIFIED = 0,
    PREMULTIPLIED = 1,
    STRAIGHT = 2,
    IGNORE = 3,
};

/// DXGI_SWAP_CHAIN_DESC1
pub const SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: Format,
    Stereo: BOOL = 0,
    SampleDesc: SAMPLE_DESC = .{ .Count = 1, .Quality = 0 },
    BufferUsage: u32,
    BufferCount: u32,
    Scaling: Scaling,
    SwapEffect: SwapEffect,
    AlphaMode: AlphaMode,
    Flags: u32,
};

/// DXGI_FEATURE
pub const Feature = enum(u32) {
    PRESENT_ALLOW_TEARING = 0,
};

const CREATE_FACTORY_DEBUG: u32 = 0x1;

extern "dxgi" fn CreateDXGIFactory2(flags: u32, riid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;

/// Creates a DXGI factory. `debug` enables the DXGI debug layer (needs the
/// "Graphics Tools" optional feature to have any effect).
pub fn createFactory(debug: bool) Error!*IDXGIFactory2 {
    var out: ?*anyopaque = null;
    try check(CreateDXGIFactory2(if (debug) CREATE_FACTORY_DEBUG else 0, &IDXGIFactory2.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

pub const IDXGIObject = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("aec22fb8-76f3-4639-9be0-28eb43a67a2e");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
    };
};

pub const IDXGIFactory = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("7b7166ec-21c7-44ae-b21a-c9ae321ae369");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const fn (*IDXGIFactory, HWND, u32) callconv(.winapi) HRESULT,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
    };

    /// `flags` are `MWA_*` bits.
    pub inline fn makeWindowAssociation(self: *IDXGIFactory, hwnd: HWND, flags: u32) Error!void {
        try check(self.vtable.MakeWindowAssociation(self, hwnd, flags));
    }
};

pub const IDXGIFactory1 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("770aae78-f26f-4dba-a829-253c83d1b387");

    pub const VTable = extern struct {
        base: IDXGIFactory.VTable,
        EnumAdapters1: *const anyopaque,
        IsCurrent: *const anyopaque,
    };
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("50c83a1c-e072-4c48-87b0-3630fa36a6d0");

    pub const VTable = extern struct {
        base: IDXGIFactory1.VTable,
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const fn (*IDXGIFactory2, *IUnknown, HWND, *const SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, *?*IDXGISwapChain1) callconv(.winapi) HRESULT,
        CreateSwapChainForCoreWindow: *const anyopaque,
        GetSharedResourceAdapterLuid: *const anyopaque,
        RegisterStereoStatusWindow: *const anyopaque,
        RegisterStereoStatusEvent: *const anyopaque,
        UnregisterStereoStatus: *const anyopaque,
        RegisterOcclusionStatusWindow: *const anyopaque,
        RegisterOcclusionStatusEvent: *const anyopaque,
        UnregisterOcclusionStatus: *const anyopaque,
        CreateSwapChainForComposition: *const fn (*IDXGIFactory2, *IUnknown, *const SWAP_CHAIN_DESC1, ?*anyopaque, *?*IDXGISwapChain1) callconv(.winapi) HRESULT,
    };

    pub inline fn asFactory(self: *IDXGIFactory2) *IDXGIFactory {
        return @ptrCast(self);
    }

    /// `device` is the D3D11 device as any COM interface pointer. Windowed,
    /// not restricted to an output.
    pub inline fn createSwapChainForHwnd(
        self: *IDXGIFactory2,
        device: anytype,
        hwnd: HWND,
        desc: *const SWAP_CHAIN_DESC1,
    ) Error!*IDXGISwapChain1 {
        var out: ?*IDXGISwapChain1 = null;
        try check(self.vtable.CreateSwapChainForHwnd(self, @ptrCast(device), hwnd, desc, null, null, &out));
        return out orelse error.ComFailure;
    }

    /// A swap chain without a window, for `IDCompositionVisual::SetContent`.
    /// Needs a flip swap effect, `Scaling.STRETCH` and a BGRA format; use
    /// `AlphaMode.PREMULTIPLIED` for per-pixel transparency. `device` is the
    /// D3D11 device as any COM interface pointer.
    pub inline fn createSwapChainForComposition(
        self: *IDXGIFactory2,
        device: anytype,
        desc: *const SWAP_CHAIN_DESC1,
    ) Error!*IDXGISwapChain1 {
        var out: ?*IDXGISwapChain1 = null;
        try check(self.vtable.CreateSwapChainForComposition(self, @ptrCast(device), desc, null, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDXGIFactory3 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("25483823-cd46-4c7d-86ca-47aa95b837bd");

    pub const VTable = extern struct {
        base: IDXGIFactory2.VTable,
        GetCreationFlags: *const anyopaque,
    };
};

pub const IDXGIFactory4 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("1bc6ea02-ef36-464f-bf0c-21ca39e5168a");

    pub const VTable = extern struct {
        base: IDXGIFactory3.VTable,
        EnumAdapterByLuid: *const anyopaque,
        EnumWarpAdapter: *const anyopaque,
    };
};

pub const IDXGIFactory5 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("7632e1f5-ee65-4dca-87fd-84cd75f8838d");

    pub const VTable = extern struct {
        base: IDXGIFactory4.VTable,
        CheckFeatureSupport: *const fn (*IDXGIFactory5, Feature, *anyopaque, u32) callconv(.winapi) HRESULT,
    };

    /// Whether `Present` may use `PRESENT_ALLOW_TEARING` (variable refresh
    /// rate displays).
    pub fn supportsTearing(self: *IDXGIFactory5) bool {
        var allowed: BOOL = 0;
        const hr = self.vtable.CheckFeatureSupport(self, .PRESENT_ALLOW_TEARING, &allowed, @sizeOf(BOOL));
        return foundation.succeeded(hr) and allowed != 0;
    }
};

pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("2411e7e1-12ac-4ccf-bd14-9798e8534dc0");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumOutputs: *const anyopaque,
        GetDesc: *const anyopaque,
        CheckInterfaceSupport: *const anyopaque,
    };
};

pub const IDXGIAdapter1 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("29038f61-3839-4626-91fd-086879011a05");

    pub const VTable = extern struct {
        base: IDXGIAdapter.VTable,
        GetDesc1: *const anyopaque,
    };
};

pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("54ec77fa-1377-44e6-8c32-88fd5f44c84c");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        GetAdapter: *const anyopaque,
        CreateSurface: *const anyopaque,
        QueryResourceResidency: *const anyopaque,
        SetGPUThreadPriority: *const anyopaque,
        GetGPUThreadPriority: *const anyopaque,
    };
};

pub const IDXGIDeviceSubObject = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("3d3e0379-f9de-4d58-bb6c-18d62992f1a6");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        GetDevice: *const anyopaque,
    };
};

pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("310d36a0-d2e7-4c0a-aa04-6a9d23b8886a");

    pub const VTable = extern struct {
        base: IDXGIDeviceSubObject.VTable,
        Present: *const fn (*IDXGISwapChain, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (*IDXGISwapChain, u32, u32, u32, Format, u32) callconv(.winapi) HRESULT,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
    };

    /// Returns the raw HRESULT of a successful call, so callers can tell
    /// `STATUS_OCCLUDED` from `S_OK`. Failures are mapped to errors.
    pub inline fn present(self: *IDXGISwapChain, sync_interval: u32, flags: u32) Error!HRESULT {
        const hr = self.vtable.Present(self, sync_interval, flags);
        try check(hr);
        return hr;
    }

    /// Buffer `index` as interface `T`; the caller releases it.
    pub inline fn getBuffer(self: *IDXGISwapChain, index: u32, comptime T: type) Error!*T {
        var out: ?*anyopaque = null;
        try check(self.vtable.GetBuffer(self, index, &T.iid, &out));
        return @ptrCast(@alignCast(out orelse return error.ComFailure));
    }

    /// `buffer_count` 0 and `format` UNKNOWN keep the current values.
    pub inline fn resizeBuffers(self: *IDXGISwapChain, buffer_count: u32, width: u32, height: u32, format: Format, flags: u32) Error!void {
        try check(self.vtable.ResizeBuffers(self, buffer_count, width, height, format, flags));
    }
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("790a45f7-0d42-4876-983a-0a55cfe6f4aa");

    pub const VTable = extern struct {
        base: IDXGISwapChain.VTable,
        GetDesc1: *const fn (*IDXGISwapChain1, *SWAP_CHAIN_DESC1) callconv(.winapi) HRESULT,
        GetFullscreenDesc: *const anyopaque,
        GetHwnd: *const anyopaque,
        GetCoreWindow: *const anyopaque,
        Present1: *const anyopaque,
        IsTemporaryMonoSupported: *const anyopaque,
        GetRestrictToOutput: *const anyopaque,
        SetBackgroundColor: *const anyopaque,
        GetBackgroundColor: *const anyopaque,
        SetRotation: *const anyopaque,
        GetRotation: *const anyopaque,
    };

    pub inline fn asSwapChain(self: *IDXGISwapChain1) *IDXGISwapChain {
        return @ptrCast(self);
    }

    pub inline fn getDesc1(self: *IDXGISwapChain1) Error!SWAP_CHAIN_DESC1 {
        var desc: SWAP_CHAIN_DESC1 = undefined;
        try check(self.vtable.GetDesc1(self, &desc));
        return desc;
    }
};

pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("a8be2ac4-199f-4946-b331-79599fb98de7");

    pub const VTable = extern struct {
        base: IDXGISwapChain1.VTable,
        SetSourceSize: *const anyopaque,
        GetSourceSize: *const anyopaque,
        SetMaximumFrameLatency: *const fn (*IDXGISwapChain2, u32) callconv(.winapi) HRESULT,
        GetMaximumFrameLatency: *const anyopaque,
        GetFrameLatencyWaitableObject: *const fn (*IDXGISwapChain2) callconv(.winapi) ?HANDLE,
        SetMatrixTransform: *const anyopaque,
        GetMatrixTransform: *const anyopaque,
    };

    pub inline fn asSwapChain1(self: *IDXGISwapChain2) *IDXGISwapChain1 {
        return @ptrCast(self);
    }

    pub inline fn setMaximumFrameLatency(self: *IDXGISwapChain2, max_latency: u32) Error!void {
        try check(self.vtable.SetMaximumFrameLatency(self, max_latency));
    }

    /// The waitable object of a swap chain created with
    /// `SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`. Each call returns a
    /// new handle the caller closes with `CloseHandle`.
    pub inline fn getFrameLatencyWaitableObject(self: *IDXGISwapChain2) ?HANDLE {
        return self.vtable.GetFrameLatencyWaitableObject(self);
    }
};
