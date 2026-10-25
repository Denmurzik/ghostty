//! DXGI bindings: factory/adapter/device/swap-chain interfaces (full slot
//! lists from dxgi.h, dxgi1_2.h, dxgi1_3.h of SDK 10.0.26100; slots become
//! typed as consumers need them) and `createFactory`.
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
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
        MakeWindowAssociation: *const anyopaque,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
    };
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
        CreateSwapChainForHwnd: *const anyopaque,
        CreateSwapChainForCoreWindow: *const anyopaque,
        GetSharedResourceAdapterLuid: *const anyopaque,
        RegisterStereoStatusWindow: *const anyopaque,
        RegisterStereoStatusEvent: *const anyopaque,
        UnregisterStereoStatus: *const anyopaque,
        RegisterOcclusionStatusWindow: *const anyopaque,
        RegisterOcclusionStatusEvent: *const anyopaque,
        UnregisterOcclusionStatus: *const anyopaque,
        CreateSwapChainForComposition: *const anyopaque,
    };
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
        Present: *const anyopaque,
        GetBuffer: *const anyopaque,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const anyopaque,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
    };
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("790a45f7-0d42-4876-983a-0a55cfe6f4aa");

    pub const VTable = extern struct {
        base: IDXGISwapChain.VTable,
        GetDesc1: *const anyopaque,
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
};

pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("a8be2ac4-199f-4946-b331-79599fb98de7");

    pub const VTable = extern struct {
        base: IDXGISwapChain1.VTable,
        SetSourceSize: *const anyopaque,
        GetSourceSize: *const anyopaque,
        SetMaximumFrameLatency: *const anyopaque,
        GetMaximumFrameLatency: *const anyopaque,
        GetFrameLatencyWaitableObject: *const anyopaque,
        SetMatrixTransform: *const anyopaque,
        GetMatrixTransform: *const anyopaque,
    };
};
