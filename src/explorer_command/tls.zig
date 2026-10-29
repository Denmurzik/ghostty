//! The TLS directory of the DLL. The DLL has no entry point (`/NOENTRY`), so
//! std's own startup, which would provide these symbols, is not linked. Debug
//! builds still reference `_tls_index` (std keeps thread-local panic state),
//! and the loader needs the directory to give the DLL its thread-local slot.
//! Same layout as `std/os/windows/tls.zig`, but hidden so that none of it
//! reaches the DLL's export table, and without `single_threaded`, which would
//! turn the module's atomic counts into single-thread atomics.
const std = @import("std");
const windows = std.os.windows;

var tls_index: u32 = windows.TLS_OUT_OF_INDEXES;
var tls_start: ?*anyopaque linksection(".tls") = null;
var tls_end: ?*anyopaque linksection(".tls$ZZZ") = null;
var xl_a: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLA") = null;
var xl_z: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLZ") = null;

const ImageTlsDirectory = extern struct {
    StartAddressOfRawData: *?*anyopaque,
    EndAddressOfRawData: *?*anyopaque,
    AddressOfIndex: *u32,
    AddressOfCallBacks: [*:null]windows.PIMAGE_TLS_CALLBACK,
    SizeOfZeroFill: u32,
    Characteristics: u32,
};

const tls_used: ImageTlsDirectory linksection(".rdata$T") = .{
    .StartAddressOfRawData = &tls_start,
    .EndAddressOfRawData = &tls_end,
    .AddressOfIndex = &tls_index,
    // `xl_a` itself is the null before the callback list; skip it.
    .AddressOfCallBacks = @as([*:null]windows.PIMAGE_TLS_CALLBACK, @ptrCast(&xl_a)) + 1,
    .SizeOfZeroFill = 0,
    .Characteristics = 0,
};

comptime {
    @export(&tls_index, .{ .name = "_tls_index", .visibility = .hidden });
    @export(&tls_start, .{ .name = "_tls_start", .visibility = .hidden });
    @export(&tls_end, .{ .name = "_tls_end", .visibility = .hidden });
    @export(&xl_a, .{ .name = "__xl_a", .visibility = .hidden });
    @export(&xl_z, .{ .name = "__xl_z", .visibility = .hidden });
    @export(&tls_used, .{ .name = "_tls_used", .visibility = .hidden });
}
