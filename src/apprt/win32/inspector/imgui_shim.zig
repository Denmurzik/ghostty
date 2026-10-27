//! What the imgui Direct3D 11 backend links against instead of
//! `d3dcompiler_47.dll`. The backend is built with `D3DCompile` renamed to
//! `ghostty_imgui_D3DCompile` (`pkg/dcimgui/build.zig`), so the executable
//! has no import of the DLL; it is loaded from System32 on the first call.
const std = @import("std");
const win32 = @import("win32");
const d3dcompiler = win32.d3dcompiler;

const log = std.log.scoped(.win32_inspector);

const E_FAIL: i32 = @bitCast(@as(u32, 0x80004005));

/// The loaded compiler; `null` until the first call, `unavailable` after a
/// failed load. UI thread only, like every user of the imgui backend.
var loaded: union(enum) { not_tried, unavailable, compiler: d3dcompiler.Compiler } = .not_tried;

fn compiler() ?d3dcompiler.Compiler {
    if (loaded == .not_tried) {
        loaded = if (d3dcompiler.Compiler.load()) |c| .{ .compiler = c } else |_| .unavailable;
        if (loaded == .unavailable) log.warn("d3dcompiler_47.dll is unavailable, the inspector cannot draw", .{});
    }
    return switch (loaded) {
        .compiler => |c| c,
        else => null,
    };
}

/// Same signature as `D3DCompile`. The backend passes no error blob.
pub export fn ghostty_imgui_D3DCompile(
    src_data: [*]const u8,
    src_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*d3dcompiler.ID3DInclude,
    entry: ?[*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*d3dcompiler.ID3DBlob,
    errors: ?*?*d3dcompiler.ID3DBlob,
) callconv(.winapi) i32 {
    const c = compiler() orelse return E_FAIL;
    var discarded: ?*d3dcompiler.ID3DBlob = null;
    const errors_out = errors orelse &discarded;
    defer if (errors == null) win32.com.release(discarded);
    return c.d3d_compile(src_data, src_size, source_name, defines, include, entry, target, flags1, flags2, code, errors_out);
}
