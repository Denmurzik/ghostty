//! Reading PE (Windows executable) headers.
const std = @import("std");
const global = @import("../global.zig");

/// Whether the executable at `path` has the Windows GUI subsystem (reads
/// the Subsystem field of the PE optional header). False for anything that
/// is not a readable PE file.
pub fn isGui(path: []const u8) bool {
    const io = global.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);

    var dos: [0x40]u8 = undefined;
    if ((file.readPositionalAll(io, &dos, 0) catch return false) != dos.len) return false;
    if (dos[0] != 'M' or dos[1] != 'Z') return false;
    const pe_offset = std.mem.readInt(u32, dos[0x3c..][0..4], .little);

    // "PE\0\0", the COFF header (20 bytes), then the optional header, whose
    // Subsystem field is at offset 68 for both PE32 and PE32+.
    var hdr: [24 + 70]u8 = undefined;
    if ((file.readPositionalAll(io, &hdr, pe_offset) catch return false) != hdr.len) return false;
    if (!std.mem.eql(u8, hdr[0..4], "PE\x00\x00")) return false;
    const subsystem = std.mem.readInt(u16, hdr[24 + 68 ..][0..2], .little);
    return subsystem == 2; // IMAGE_SUBSYSTEM_WINDOWS_GUI
}
