//! Runtime HLSL compilation through `d3dcompiler_47.dll` (R4). The DLL is
//! loaded dynamically from System32 so the executable has no import-time
//! dependency on it.
const std = @import("std");
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const HMODULE = foundation.HMODULE;
const IUnknown = com.IUnknown;

const log = std.log.scoped(.d3dcompiler);

/// ID3DBlob (an alias of ID3D10Blob).
pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("8ba5fb08-5195-40e2-ac58-0d989c3a0102");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) ?*anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };

    pub inline fn bytes(self: *ID3DBlob) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.vtable.GetBufferPointer(self) orelse return &.{});
        return ptr[0..self.vtable.GetBufferSize(self)];
    }
};

/// ID3DInclude is a plain C++ interface, NOT an IUnknown: its vtable is just
/// `{ Open, Close }`.
pub const ID3DInclude = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        Open: *const fn (*ID3DInclude, include_type: i32, file_name: [*:0]const u8, parent_data: ?*const anyopaque, data: *?*const anyopaque, bytes: *u32) callconv(.winapi) HRESULT,
        Close: *const fn (*ID3DInclude, data: ?*const anyopaque) callconv(.winapi) HRESULT,
    };
};

pub const CompileOptions = struct {
    source: []const u8,
    /// Name used in diagnostics.
    source_name: [:0]const u8,
    entry: [:0]const u8,
    /// Shader model target, e.g. "vs_5_0" or "ps_5_0".
    target: [:0]const u8,
    /// D3DCOMPILE_* flags.
    flags: u32 = 0,
    include: ?*ID3DInclude = null,
};

pub const CompileError = error{ CompileFailed, OutOfMemory };

const D3DCompileFn = *const fn (
    src_data: [*]const u8,
    src_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*ID3DInclude,
    entry: ?[*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*ID3DBlob,
    errors: *?*ID3DBlob,
) callconv(.winapi) HRESULT;

const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const fn () callconv(.winapi) isize;

pub const Compiler = struct {
    d3d_compile: D3DCompileFn,

    /// Loads `d3dcompiler_47.dll` from System32. The module stays loaded for
    /// the life of the process.
    pub fn load() error{CompilerUnavailable}!Compiler {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll");
        const module = LoadLibraryExW(name, null, LOAD_LIBRARY_SEARCH_SYSTEM32) orelse
            return error.CompilerUnavailable;
        const proc = GetProcAddress(module, "D3DCompile") orelse
            return error.CompilerUnavailable;
        return .{ .d3d_compile = @ptrCast(@alignCast(proc)) };
    }

    /// Compiles HLSL to bytecode. The result is owned by the caller. On
    /// failure the compiler's diagnostics are logged and `CompileFailed` is
    /// returned.
    pub fn compile(self: Compiler, alloc: std.mem.Allocator, opts: CompileOptions) CompileError![]u8 {
        var code: ?*ID3DBlob = null;
        var errors: ?*ID3DBlob = null;
        defer com.release(code);
        defer com.release(errors);

        const hr = self.d3d_compile(
            opts.source.ptr,
            opts.source.len,
            opts.source_name.ptr,
            null,
            opts.include,
            opts.entry.ptr,
            opts.target.ptr,
            opts.flags,
            0,
            &code,
            &errors,
        );
        if (!foundation.succeeded(hr)) {
            const text = if (errors) |e| std.mem.trimEnd(u8, e.bytes(), "\r\n\x00 ") else "";
            log.warn("D3DCompile of {s} ({s}) failed: HRESULT 0x{x:0>8}\n{s}", .{
                opts.source_name,
                opts.target,
                @as(u32, @bitCast(hr)),
                text,
            });
            return error.CompileFailed;
        }

        const blob = code orelse return error.CompileFailed;
        if (errors) |e| {
            // On success the error blob carries the compiler's warnings.
            const text = std.mem.trimEnd(u8, e.bytes(), "\r\n\x00 ");
            if (text.len > 0) log.debug("D3DCompile of {s} ({s}) warnings\n{s}", .{
                opts.source_name,
                opts.target,
                text,
            });
        }
        return alloc.dupe(u8, blob.bytes());
    }
};
