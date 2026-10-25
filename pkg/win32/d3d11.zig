//! Direct3D 11 bindings: full slot lists (SDK 10.0.26100 d3d11.h, header
//! order, inherited slots first via `base`) for the interfaces Ghostty's
//! renderer uses. Unused slots keep their header name typed
//! `*const anyopaque`; consumers replace a placeholder with its signature.
const std = @import("std");
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const HMODULE = foundation.HMODULE;
const Error = foundation.Error;
const check = foundation.check;
const IUnknown = com.IUnknown;

/// D3D_FEATURE_LEVEL (d3dcommon.h).
pub const FeatureLevel = enum(i32) {
    @"9_1" = 0x9100,
    @"9_2" = 0x9200,
    @"9_3" = 0x9300,
    @"10_0" = 0xa000,
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    @"12_0" = 0xc000,
    @"12_1" = 0xc100,
    @"12_2" = 0xc200,
    _,
};

/// D3D_DRIVER_TYPE (d3dcommon.h); only the values we create devices with.
pub const DriverType = enum(i32) {
    hardware = 1,
    warp = 5,
};

/// D3D11_CREATE_DEVICE_FLAG
pub const CreateDeviceFlags = packed struct(u32) {
    single_threaded: bool = false, // 0x1
    debug: bool = false, // 0x2
    switch_to_ref: bool = false, // 0x4
    prevent_internal_threading_optimizations: bool = false, // 0x8
    _reserved0: bool = false, // 0x10
    bgra_support: bool = false, // 0x20
    debuggable: bool = false, // 0x40
    prevent_altering_layer_settings_from_registry: bool = false, // 0x80
    disable_gpu_timeout: bool = false, // 0x100
    _reserved1: u2 = 0, // 0x200, 0x400
    video_support: bool = false, // 0x800
    _reserved2: u20 = 0,
};

/// D3D11_USAGE
pub const Usage = enum(i32) {
    default = 0,
    immutable = 1,
    dynamic = 2,
    staging = 3,
};

/// D3D11_BIND_FLAG
pub const BindFlags = packed struct(u32) {
    vertex_buffer: bool = false, // 0x1
    index_buffer: bool = false, // 0x2
    constant_buffer: bool = false, // 0x4
    shader_resource: bool = false, // 0x8
    stream_output: bool = false, // 0x10
    render_target: bool = false, // 0x20
    depth_stencil: bool = false, // 0x40
    unordered_access: bool = false, // 0x80
    _reserved0: u1 = 0, // 0x100
    video_decoder: bool = false, // 0x200
    video_encoder: bool = false, // 0x400
    _reserved1: u21 = 0,
};

/// D3D11_CPU_ACCESS_FLAG
pub const CpuAccessFlags = packed struct(u32) {
    _reserved0: u16 = 0,
    write: bool = false, // 0x10000
    read: bool = false, // 0x20000
    _reserved1: u14 = 0,
};

/// D3D11_MAP
pub const MAP = enum(i32) {
    read = 1,
    write = 2,
    read_write = 3,
    write_discard = 4,
    write_no_overwrite = 5,
};

/// D3D11_RTV_DIMENSION
pub const RTV_DIMENSION = enum(i32) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1DARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2DARRAY = 5,
    TEXTURE2DMS = 6,
    TEXTURE2DMSARRAY = 7,
    TEXTURE3D = 8,
};

/// D3D11_SRV_DIMENSION
pub const SRV_DIMENSION = enum(i32) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1DARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2DARRAY = 5,
    TEXTURE2DMS = 6,
    TEXTURE2DMSARRAY = 7,
    TEXTURE3D = 8,
    TEXTURECUBE = 9,
    TEXTURECUBEARRAY = 10,
    BUFFEREX = 11,
};

/// D3D11_FILTER; only the values we create samplers with.
pub const FILTER = enum(i32) {
    MIN_MAG_MIP_POINT = 0,
    MIN_MAG_MIP_LINEAR = 0x15,
};

/// D3D11_TEXTURE_ADDRESS_MODE
pub const TEXTURE_ADDRESS_MODE = enum(i32) {
    WRAP = 1,
    MIRROR = 2,
    CLAMP = 3,
    BORDER = 4,
    MIRROR_ONCE = 5,
};

/// D3D11_COMPARISON_FUNC
pub const COMPARISON_FUNC = enum(i32) {
    NEVER = 1,
    LESS = 2,
    EQUAL = 3,
    LESS_EQUAL = 4,
    GREATER = 5,
    NOT_EQUAL = 6,
    GREATER_EQUAL = 7,
    ALWAYS = 8,
};

/// D3D11_RESOURCE_MISC_BUFFER_STRUCTURED, for `BUFFER_DESC.MiscFlags`.
pub const RESOURCE_MISC_BUFFER_STRUCTURED: u32 = 0x40;

/// D3D11_FLOAT32_MAX, the "unbounded" `SAMPLER_DESC.MaxLOD`.
pub const FLOAT32_MAX: f32 = 3.402823466e+38;

/// D3D11_BUFFER_DESC
pub const BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: Usage,
    BindFlags: BindFlags,
    CPUAccessFlags: CpuAccessFlags,
    MiscFlags: u32,
    StructureByteStride: u32,
};

/// D3D11_BOX
pub const BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

/// D3D11_SHADER_RESOURCE_VIEW_DESC. The union is padded to the size of its
/// largest SDK member (four u32, e.g. `Texture2DArray`).
pub const SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: dxgi.Format,
    ViewDimension: SRV_DIMENSION,
    u: extern union {
        Buffer: extern struct { FirstElement: u32, NumElements: u32 },
        Texture2D: extern struct { MostDetailedMip: u32, MipLevels: u32 },
        _size: [4]u32,
    },
};

/// D3D11_SAMPLER_DESC
pub const SAMPLER_DESC = extern struct {
    Filter: FILTER,
    AddressU: TEXTURE_ADDRESS_MODE,
    AddressV: TEXTURE_ADDRESS_MODE,
    AddressW: TEXTURE_ADDRESS_MODE,
    MipLODBias: f32,
    MaxAnisotropy: u32,
    ComparisonFunc: COMPARISON_FUNC,
    BorderColor: [4]f32,
    MinLOD: f32,
    MaxLOD: f32,
};

/// D3D11_TEXTURE2D_DESC
pub const TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: dxgi.Format,
    SampleDesc: dxgi.SAMPLE_DESC,
    Usage: Usage,
    BindFlags: BindFlags,
    CPUAccessFlags: CpuAccessFlags,
    MiscFlags: u32,
};

/// D3D11_SUBRESOURCE_DATA
pub const SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

/// D3D11_MAPPED_SUBRESOURCE
pub const MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: u32,
    DepthPitch: u32,
};

/// D3D11_RENDER_TARGET_VIEW_DESC
pub const RENDER_TARGET_VIEW_DESC = extern struct {
    Format: dxgi.Format,
    ViewDimension: RTV_DIMENSION,
    u: extern union {
        Buffer: extern struct { FirstElement: u32, NumElements: u32 },
        Texture2D: extern struct { MipSlice: u32 },
        Texture2DArray: extern struct { MipSlice: u32, FirstArraySlice: u32, ArraySize: u32 },
        Texture3D: extern struct { MipSlice: u32, FirstWSlice: u32, WSize: u32 },
    },
};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("db6f6ddb-ac77-4e88-8253-819df9bbf140");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        CreateBuffer: *const fn (*ID3D11Device, *const BUFFER_DESC, ?*const SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (*ID3D11Device, *const TEXTURE2D_DESC, ?*const SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const fn (*ID3D11Device, *ID3D11Resource, ?*const SHADER_RESOURCE_VIEW_DESC, *?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (*ID3D11Device, *ID3D11Resource, ?*const RENDER_TARGET_VIEW_DESC, *?*ID3D11RenderTargetView) callconv(.winapi) HRESULT,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const anyopaque,
        CreateVertexShader: *const anyopaque,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const anyopaque,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const anyopaque,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const fn (*ID3D11Device, *const SAMPLER_DESC, *?*ID3D11SamplerState) callconv(.winapi) HRESULT,
        CreateQuery: *const anyopaque,
        CreatePredicate: *const anyopaque,
        CreateCounter: *const anyopaque,
        CreateDeferredContext: *const anyopaque,
        OpenSharedResource: *const anyopaque,
        CheckFormatSupport: *const anyopaque,
        CheckMultisampleQualityLevels: *const anyopaque,
        CheckCounterInfo: *const anyopaque,
        CheckCounter: *const anyopaque,
        CheckFeatureSupport: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetFeatureLevel: *const anyopaque,
        GetCreationFlags: *const anyopaque,
        GetDeviceRemovedReason: *const anyopaque,
        GetImmediateContext: *const fn (*ID3D11Device, *?*ID3D11DeviceContext) callconv(.winapi) void,
        SetExceptionMode: *const anyopaque,
        GetExceptionMode: *const anyopaque,
    };

    pub inline fn createBuffer(self: *ID3D11Device, desc: *const BUFFER_DESC, initial: ?*const SUBRESOURCE_DATA) Error!*ID3D11Buffer {
        var out: ?*ID3D11Buffer = null;
        try check(self.vtable.CreateBuffer(self, desc, initial, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createShaderResourceView(self: *ID3D11Device, resource: *ID3D11Resource, desc: ?*const SHADER_RESOURCE_VIEW_DESC) Error!*ID3D11ShaderResourceView {
        var out: ?*ID3D11ShaderResourceView = null;
        try check(self.vtable.CreateShaderResourceView(self, resource, desc, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createSamplerState(self: *ID3D11Device, desc: *const SAMPLER_DESC) Error!*ID3D11SamplerState {
        var out: ?*ID3D11SamplerState = null;
        try check(self.vtable.CreateSamplerState(self, desc, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createTexture2D(self: *ID3D11Device, desc: *const TEXTURE2D_DESC, initial: ?*const SUBRESOURCE_DATA) Error!*ID3D11Texture2D {
        var out: ?*ID3D11Texture2D = null;
        try check(self.vtable.CreateTexture2D(self, desc, initial, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createRenderTargetView(self: *ID3D11Device, resource: *ID3D11Resource, desc: ?*const RENDER_TARGET_VIEW_DESC) Error!*ID3D11RenderTargetView {
        var out: ?*ID3D11RenderTargetView = null;
        try check(self.vtable.CreateRenderTargetView(self, resource, desc, &out));
        return out orelse error.ComFailure;
    }

    /// Returns a new reference to the immediate context; the caller releases it.
    pub inline fn getImmediateContext(self: *ID3D11Device) *ID3D11DeviceContext {
        var out: ?*ID3D11DeviceContext = null;
        self.vtable.GetImmediateContext(self, &out);
        return out.?;
    }
};

pub const ID3D11DeviceChild = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("1841e5c8-16b0-489b-bcc8-44cfb0d5deae");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
    };
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("c0bfa96c-e089-44fb-8eaf-26f8796190da");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const fn (*ID3D11DeviceContext, *ID3D11Resource, u32, MAP, u32, *MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT,
        Unmap: *const fn (*ID3D11DeviceContext, *ID3D11Resource, u32) callconv(.winapi) void,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const anyopaque,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const anyopaque,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, *ID3D11Resource) callconv(.winapi) void,
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, u32, ?*const BOX, *const anyopaque, u32, u32) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, *ID3D11RenderTargetView, *const [4]f32) callconv(.winapi) void,
        ClearUnorderedAccessViewUint: *const anyopaque,
        ClearUnorderedAccessViewFloat: *const anyopaque,
        ClearDepthStencilView: *const anyopaque,
        GenerateMips: *const anyopaque,
        SetResourceMinLOD: *const anyopaque,
        GetResourceMinLOD: *const anyopaque,
        ResolveSubresource: *const anyopaque,
        ExecuteCommandList: *const anyopaque,
        HSSetShaderResources: *const anyopaque,
        HSSetShader: *const anyopaque,
        HSSetSamplers: *const anyopaque,
        HSSetConstantBuffers: *const anyopaque,
        DSSetShaderResources: *const anyopaque,
        DSSetShader: *const anyopaque,
        DSSetSamplers: *const anyopaque,
        DSSetConstantBuffers: *const anyopaque,
        CSSetShaderResources: *const anyopaque,
        CSSetUnorderedAccessViews: *const anyopaque,
        CSSetShader: *const anyopaque,
        CSSetSamplers: *const anyopaque,
        CSSetConstantBuffers: *const anyopaque,
        VSGetConstantBuffers: *const anyopaque,
        PSGetShaderResources: *const anyopaque,
        PSGetShader: *const anyopaque,
        PSGetSamplers: *const anyopaque,
        VSGetShader: *const anyopaque,
        PSGetConstantBuffers: *const anyopaque,
        IAGetInputLayout: *const anyopaque,
        IAGetVertexBuffers: *const anyopaque,
        IAGetIndexBuffer: *const anyopaque,
        GSGetConstantBuffers: *const anyopaque,
        GSGetShader: *const anyopaque,
        IAGetPrimitiveTopology: *const anyopaque,
        VSGetShaderResources: *const anyopaque,
        VSGetSamplers: *const anyopaque,
        GetPredication: *const anyopaque,
        GSGetShaderResources: *const anyopaque,
        GSGetSamplers: *const anyopaque,
        OMGetRenderTargets: *const anyopaque,
        OMGetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMGetBlendState: *const anyopaque,
        OMGetDepthStencilState: *const anyopaque,
        SOGetTargets: *const anyopaque,
        RSGetState: *const anyopaque,
        RSGetViewports: *const anyopaque,
        RSGetScissorRects: *const anyopaque,
        HSGetShaderResources: *const anyopaque,
        HSGetShader: *const anyopaque,
        HSGetSamplers: *const anyopaque,
        HSGetConstantBuffers: *const anyopaque,
        DSGetShaderResources: *const anyopaque,
        DSGetShader: *const anyopaque,
        DSGetSamplers: *const anyopaque,
        DSGetConstantBuffers: *const anyopaque,
        CSGetShaderResources: *const anyopaque,
        CSGetUnorderedAccessViews: *const anyopaque,
        CSGetShader: *const anyopaque,
        CSGetSamplers: *const anyopaque,
        CSGetConstantBuffers: *const anyopaque,
        ClearState: *const anyopaque,
        Flush: *const anyopaque,
        GetType: *const anyopaque,
        GetContextFlags: *const anyopaque,
        FinishCommandList: *const anyopaque,
    };

    pub inline fn clearRenderTargetView(self: *ID3D11DeviceContext, rtv: *ID3D11RenderTargetView, color: [4]f32) void {
        self.vtable.ClearRenderTargetView(self, rtv, &color);
    }

    pub inline fn copyResource(self: *ID3D11DeviceContext, dst: *ID3D11Resource, src: *ID3D11Resource) void {
        self.vtable.CopyResource(self, dst, src);
    }

    pub inline fn updateSubresource(self: *ID3D11DeviceContext, dst: *ID3D11Resource, subresource: u32, box: ?*const BOX, src: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
        self.vtable.UpdateSubresource(self, dst, subresource, box, src, row_pitch, depth_pitch);
    }

    pub inline fn map(self: *ID3D11DeviceContext, resource: *ID3D11Resource, subresource: u32, map_type: MAP, flags: u32) Error!MAPPED_SUBRESOURCE {
        var out: MAPPED_SUBRESOURCE = undefined;
        try check(self.vtable.Map(self, resource, subresource, map_type, flags, &out));
        return out;
    }

    pub inline fn unmap(self: *ID3D11DeviceContext, resource: *ID3D11Resource, subresource: u32) void {
        self.vtable.Unmap(self, resource, subresource);
    }
};

pub const ID3D11Resource = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("dc8e63f3-d12b-4952-b47b-5e45026a862d");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetType: *const anyopaque,
        SetEvictionPriority: *const anyopaque,
        GetEvictionPriority: *const anyopaque,
    };
};

pub const ID3D11Buffer = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("48570b85-d1ee-4fcd-a250-eb350722b037");

    pub const VTable = extern struct {
        base: ID3D11Resource.VTable,
        GetDesc: *const fn (*ID3D11Buffer, *BUFFER_DESC) callconv(.winapi) void,
    };

    pub inline fn asResource(self: *ID3D11Buffer) *ID3D11Resource {
        return @ptrCast(self);
    }

    pub inline fn getDesc(self: *ID3D11Buffer) BUFFER_DESC {
        var out: BUFFER_DESC = undefined;
        self.vtable.GetDesc(self, &out);
        return out;
    }
};

pub const ID3D11Texture2D = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    pub const VTable = extern struct {
        base: ID3D11Resource.VTable,
        GetDesc: *const anyopaque,
    };

    pub inline fn asResource(self: *ID3D11Texture2D) *ID3D11Resource {
        return @ptrCast(self);
    }
};

pub const ID3D11View = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("839d1216-bb2e-412b-b7f4-a9dbebe08ed1");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetResource: *const anyopaque,
    };
};

pub const ID3D11RenderTargetView = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("dfdba067-0b8d-4865-875b-d7b4516cc164");

    pub const VTable = extern struct {
        base: ID3D11View.VTable,
        GetDesc: *const anyopaque,
    };
};

pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("b0e06fe0-8192-4e1a-b1ca-36d7414710b2");

    pub const VTable = extern struct {
        base: ID3D11View.VTable,
        GetDesc: *const anyopaque,
    };
};

pub const ID3D11SamplerState = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("da6fea51-564c-4487-9810-f0d0f9b4e3a5");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: *const anyopaque,
    };
};

pub const ID3D11BlendState = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("75b68faa-347d-4159-8f45-a0640f01cd9a");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: *const anyopaque,
    };
};

pub const ID3D11RasterizerState = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("9bb4ab81-ab1a-4d8f-b506-fc04200b6ee7");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: *const anyopaque,
    };
};

pub const ID3D11InputLayout = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("e4819ddc-4cf0-4025-bd26-5de82a3e07b7");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

pub const ID3D11VertexShader = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("3b301d64-d678-4289-8897-22f8928b72f3");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("ea82e40d-51dc-4f33-93d4-db7c9125ae8c");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

const SDK_VERSION: u32 = 7; // D3D11_SDK_VERSION

extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*dxgi.IDXGIAdapter,
    driver_type: DriverType,
    software: ?HMODULE,
    flags: CreateDeviceFlags,
    feature_levels: ?[*]const FeatureLevel,
    feature_level_count: u32,
    sdk_version: u32,
    device: *?*ID3D11Device,
    feature_level: *FeatureLevel,
    context: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

pub const CreatedDevice = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    level: FeatureLevel,
};

/// Feature levels we ask for, best first. 11_0 is the minimum Ghostty supports.
const requested_levels = [_]FeatureLevel{ .@"11_1", .@"11_0" };

/// Creates a device on the default adapter. The caller releases `device`
/// and `context` (each holds its own reference).
pub fn createDevice(driver: DriverType, flags: CreateDeviceFlags) Error!CreatedDevice {
    var device: ?*ID3D11Device = null;
    var context: ?*ID3D11DeviceContext = null;
    var level: FeatureLevel = undefined;
    try check(D3D11CreateDevice(
        null,
        driver,
        null,
        flags,
        &requested_levels,
        requested_levels.len,
        SDK_VERSION,
        &device,
        &level,
        &context,
    ));
    // Success always fills both out-pointers.
    return .{ .device = device.?, .context = context.?, .level = level };
}

// A reordered or mistyped slot silently calls the wrong method; pin the ones
// this file types to their SDK header positions (0-based, inherited first).
comptime {
    const ptr = @sizeOf(usize);
    const dev = ID3D11Device.VTable;
    const ctx = ID3D11DeviceContext.VTable;
    if (@offsetOf(dev, "CreateBuffer") != 3 * ptr) @compileError("CreateBuffer slot");
    if (@offsetOf(dev, "CreateShaderResourceView") != 7 * ptr) @compileError("CreateShaderResourceView slot");
    if (@offsetOf(dev, "CreateSamplerState") != 23 * ptr) @compileError("CreateSamplerState slot");
    if (@offsetOf(ctx, "UpdateSubresource") != 48 * ptr) @compileError("UpdateSubresource slot");
    if (@sizeOf(BUFFER_DESC) != 24) @compileError("BUFFER_DESC size");
    if (@sizeOf(BOX) != 24) @compileError("BOX size");
    if (@sizeOf(SHADER_RESOURCE_VIEW_DESC) != 24) @compileError("SHADER_RESOURCE_VIEW_DESC size");
    if (@sizeOf(SAMPLER_DESC) != 52) @compileError("SAMPLER_DESC size");
}
