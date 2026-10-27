//! Builtin HLSL shaders: embedded sources, a runtime `D3DCompile` wrapper
//! and a process-global bytecode cache.
//!
//! Every entry is compiled at most once per process. The cache is filled
//! lazily by `bytecode` or eagerly by `warmup`, and its memory lives for
//! the life of the process.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const com = win32.com;
const foundation = win32.foundation;
const d3dcompiler = win32.d3dcompiler;
const global = @import("../../global.zig");
const shadertoy = @import("../shadertoy.zig");

const log = std.log.scoped(.d3d11);

/// Every builtin shader entry point. Each tag is a distinct function in one
/// of the files under `shaders/hlsl`; the tag name is the HLSL function name.
pub const Entry = enum {
    full_screen_vs,
    bg_color_ps,
    cell_bg_ps,
    cell_text_vs,
    cell_text_ps,
    image_vs,
    image_ps,
    bg_image_vs,
    bg_image_ps,
    decor_ps,

    /// The shader model target for this entry, derived from its suffix.
    fn target(self: Entry) [:0]const u8 {
        return switch (self) {
            .full_screen_vs, .cell_text_vs, .image_vs, .bg_image_vs => "vs_5_0",
            .bg_color_ps, .cell_bg_ps, .cell_text_ps, .image_ps, .bg_image_ps, .decor_ps => "ps_5_0",
        };
    }

    fn fileName(self: Entry) [:0]const u8 {
        return switch (self) {
            .full_screen_vs => "full_screen.hlsl",
            .bg_color_ps => "bg_color.hlsl",
            .cell_bg_ps => "cell_bg.hlsl",
            .cell_text_vs, .cell_text_ps => "cell_text.hlsl",
            .image_vs, .image_ps => "image.hlsl",
            .bg_image_vs, .bg_image_ps => "bg_image.hlsl",
            .decor_ps => "decor.hlsl",
        };
    }
};

const common_name = "common.hlsli";
const common_source = @embedFile("../shaders/hlsl/common.hlsli");

/// The HLSL source of the file that defines `entry`.
pub fn source(entry: Entry) []const u8 {
    return switch (entry) {
        .full_screen_vs => @embedFile("../shaders/hlsl/full_screen.hlsl"),
        .bg_color_ps => @embedFile("../shaders/hlsl/bg_color.hlsl"),
        .cell_bg_ps => @embedFile("../shaders/hlsl/cell_bg.hlsl"),
        .cell_text_vs, .cell_text_ps => @embedFile("../shaders/hlsl/cell_text.hlsl"),
        .image_vs, .image_ps => @embedFile("../shaders/hlsl/image.hlsl"),
        .bg_image_vs, .bg_image_ps => @embedFile("../shaders/hlsl/bg_image.hlsl"),
        .decor_ps => @embedFile("../shaders/hlsl/decor.hlsl"),
    };
}

// D3DCOMPILE_* flags.
const D3DCOMPILE_DEBUG: u32 = 1 << 0;
const D3DCOMPILE_SKIP_OPTIMIZATION: u32 = 1 << 2;
const D3DCOMPILE_OPTIMIZATION_LEVEL3: u32 = 1 << 15;

const compile_flags: u32 = if (builtin.mode == .debug)
    D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION
else
    D3DCOMPILE_OPTIMIZATION_LEVEL3;

const entry_count = std.meta.tags(Entry).len;

/// Guards `compiler` and `cache`.
var mutex: std.Io.Mutex = .init;
var compiler: ?d3dcompiler.Compiler = null;
var cache: [entry_count]?[]const u8 = @splat(null);

/// Compiled bytecode for `entry`. The slice is owned by the cache and
/// stays valid for the life of the process; the same pointer is returned
/// on every call.
pub fn bytecode(entry: Entry) ![]const u8 {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const slot = &cache[@backingInt(entry)];
    if (slot.*) |code| return code;

    const c = compiler orelse load: {
        compiler = try d3dcompiler.Compiler.load();
        break :load compiler.?;
    };

    // Process-lifetime storage, intentionally never freed.
    const code = try compileEntry(c, std.heap.page_allocator, entry);
    slot.* = code;
    return code;
}

/// Bytecode of runtime sources (custom shaders) by SHA-256 of
/// source, entry and profile. A failed compile is cached as null so a
/// broken shader is compiled and reported once. Guarded by `mutex`.
/// Entries (and their page-allocator bytecode) are kept for the life of
/// the process, one per distinct source: a reloaded edited shader leaves
/// its old version behind, which is small next to the compiler itself.
var source_cache: std.AutoHashMapUnmanaged([32]u8, ?[]const u8) = .empty;

/// How many runtime compiles actually ran. Guarded by `mutex`.
var source_compiles: usize = 0;

/// Compiles `source` for `profile` (e.g. "ps_5_0"). Like `bytecode`, the
/// result is owned by the cache and valid for the life of the process,
/// and a repeated call with the same arguments does not compile again.
/// Nothing is compiled here until a custom shader is configured (the
/// builtin shaders already load the compiler at startup).
pub fn compileSource(
    source_: [:0]const u8,
    entry: [:0]const u8,
    profile: [:0]const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_);
    hasher.update("\x00");
    hasher.update(entry);
    hasher.update("\x00");
    hasher.update(profile);
    var key: [32]u8 = undefined;
    hasher.final(&key);

    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const alloc = std.heap.page_allocator;
    if (source_cache.get(key)) |cached| return cached orelse error.CompileFailed;

    const c = compiler orelse load: {
        compiler = try d3dcompiler.Compiler.load();
        break :load compiler.?;
    };

    source_compiles += 1;
    const code = c.compile(alloc, .{
        .source = source_,
        .source_name = "custom-shader.hlsl",
        .entry = entry,
        .target = profile,
        .flags = compile_flags,
    }) catch |err| {
        try source_cache.put(alloc, key, null);
        return err;
    };
    try source_cache.put(alloc, key, code);
    return code;
}

/// The number of runtime compiles `compileSource` has run. Test helper.
pub fn sourceCompileCount() usize {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return source_compiles;
}

/// Compiles every entry so the first frame does not pay for it. Failures
/// are logged; `bytecode` reports them again to whoever needs the entry.
pub fn warmup() void {
    inline for (comptime std.meta.tags(Entry)) |entry| {
        _ = bytecode(entry) catch |err| {
            log.warn("HLSL warmup of {s} failed: {}", .{ @tagName(entry), err });
        };
    }
}

fn compileEntry(c: d3dcompiler.Compiler, alloc: Allocator, entry: Entry) ![]u8 {
    var include: Include = .{};
    return c.compile(alloc, .{
        .source = source(entry),
        .source_name = entry.fileName(),
        .entry = @tagName(entry),
        .target = entry.target(),
        .flags = compile_flags,
        .include = &include.base,
    });
}

/// `ID3DInclude` that serves the embedded `common.hlsli`.
const Include = struct {
    base: d3dcompiler.ID3DInclude = .{ .vtable = &vtable },

    const vtable: d3dcompiler.ID3DInclude.VTable = .{
        .Open = open,
        .Close = close,
    };

    fn open(
        _: *d3dcompiler.ID3DInclude,
        _: i32,
        file_name: [*:0]const u8,
        _: ?*const anyopaque,
        data: *?*const anyopaque,
        bytes: *u32,
    ) callconv(.winapi) foundation.HRESULT {
        const name = std.mem.span(file_name);
        if (!std.mem.eql(u8, std.fs.path.basename(name), common_name)) {
            return foundation.E_FAIL;
        }

        data.* = common_source.ptr;
        bytes.* = common_source.len;
        return foundation.S_OK;
    }

    // The source is static, so there is nothing to release.
    fn close(_: *d3dcompiler.ID3DInclude, _: ?*const anyopaque) callconv(.winapi) foundation.HRESULT {
        return foundation.S_OK;
    }
};

test "d3d11 hlsl: every entry compiles" {
    inline for (comptime std.meta.tags(Entry)) |e| {
        try std.testing.expect((try bytecode(e)).len > 0);
    }
}

test "d3d11 hlsl: bytecode is DXBC" {
    inline for (comptime std.meta.tags(Entry)) |e| {
        try std.testing.expectEqualStrings("DXBC", (try bytecode(e))[0..4]);
    }
}

test "d3d11 hlsl: bytecode is cached" {
    const a = try bytecode(.cell_bg_ps);
    const b = try bytecode(.cell_bg_ps);
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(a.len, b.len);
}

test "d3d11 hlsl: warmup fills the cache" {
    warmup();
    inline for (comptime std.meta.tags(Entry)) |e| {
        const first = try bytecode(e);
        const second = try bytecode(e);
        try std.testing.expectEqual(first.ptr, second.ptr);
    }
}

test "d3d11 hlsl: entries of one file share the source" {
    try std.testing.expectEqual(source(.cell_text_vs).ptr, source(.cell_text_ps).ptr);
    for (std.meta.tags(Entry)) |e| {
        try std.testing.expect(std.mem.indexOf(u8, source(e), "#include \"common.hlsli\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, source(e), @tagName(e)) != null);
    }
}

test "d3d11 hlsl: cbuffer packoffsets match Uniforms" {
    const Uniforms = @import("shaders.zig").Uniforms;
    const common = common_source;

    // HLSL member -> CPU field. Register c<n> starts at byte 16 * n and
    // component .x/.y/.z/.w adds 0/4/8/12.
    const members = .{
        .{ "projection_matrix", "projection_matrix", "c0" },
        .{ "screen_size", "screen_size", "c4.x" },
        .{ "cell_size", "cell_size", "c4.z" },
        .{ "grid_size_packed", "grid_size", "c5.x" },
        .{ "grid_padding", "grid_padding", "c6" },
        .{ "padding_extend", "padding_extend", "c7.x" },
        .{ "min_contrast", "min_contrast", "c7.y" },
        .{ "cursor_pos_packed", "cursor_pos", "c7.z" },
        .{ "cursor_color_packed", "cursor_color", "c7.w" },
        .{ "bg_color_packed", "bg_color", "c8.x" },
        .{ "bools_packed", "bools", "c8.y" },
    };

    inline for (members) |m| {
        const reg = m[2];
        const comp_offset: usize = if (reg.len > 3) switch (reg[3]) {
            'x' => 0,
            'y' => 4,
            'z' => 8,
            'w' => 12,
            else => unreachable,
        } else 0;
        const reg_num = try std.fmt.parseInt(usize, reg[1..2], 10);
        try std.testing.expectEqual(@offsetOf(Uniforms, m[1]), reg_num * 16 + comp_offset);

        var buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "{s} : packoffset({s})", .{ m[0], reg });
        try std.testing.expect(std.mem.indexOf(u8, common, needle) != null);
    }

    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Uniforms));
}

/// Test helper: ShaderToy source to the HLSL the renderer compiles.
pub fn toyToHlslForTest(alloc: Allocator, toy: []const u8) ![:0]const u8 {
    comptime std.debug.assert(builtin.is_test);

    var glsl: std.Io.Writer.Allocating = .init(alloc);
    defer glsl.deinit();
    try shadertoy.glslFromShader(&glsl.writer, toy);
    const glsl_z = try glsl.toOwnedSliceSentinel(0);
    defer alloc.free(glsl_z);

    var spv: std.Io.Writer.Allocating = .init(alloc);
    defer spv.deinit();
    try shadertoy.spirvFromGlsl(&spv.writer, null, glsl_z);

    // SPIR-V is read as words, so the copy must be 4-byte aligned.
    var words: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer words.deinit(alloc);
    try words.appendSlice(alloc, spv.written());
    return try shadertoy.hlslFromSpv(alloc, words.items);
}

test "d3d11 custom shader: crt test shader compiles to ps_5_0" {
    const alloc = std.testing.allocator;
    const hlsl_src = try toyToHlslForTest(alloc, @embedFile("../shaders/test_shadertoy_crt.glsl"));
    defer alloc.free(hlsl_src);

    const code = try compileSource(hlsl_src, "main", "ps_5_0");
    try std.testing.expectEqualStrings("DXBC", code[0..4]);
}

test "d3d11 custom shader: same source compiles once" {
    // The comment makes the source unique to this test.
    const src = "float4 main() : SV_Target0 { return 0; } // same-source-compiles-once";
    const before = sourceCompileCount();
    const a = try compileSource(src, "main", "ps_5_0");
    const b = try compileSource(src, "main", "ps_5_0");
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(before + 1, sourceCompileCount());

    // A different profile is a different entry.
    _ = try compileSource(src, "main", "ps_4_0");
    try std.testing.expectEqual(before + 2, sourceCompileCount());
}

test "d3d11 custom shader: failed compile is cached and logged once" {
    const src = "this is not hlsl {";
    const before = sourceCompileCount();
    try std.testing.expectError(error.CompileFailed, compileSource(src, "main", "ps_5_0"));
    try std.testing.expectError(error.CompileFailed, compileSource(src, "main", "ps_5_0"));
    // The compiler (which logs the diagnostics) ran once.
    try std.testing.expectEqual(before + 1, sourceCompileCount());
}
