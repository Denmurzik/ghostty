//! Bell feedback: tab and window title decoration, taskbar flash. Stub: Task 26.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Placeholder until Task 6a adds the real tab type; only the pointer type
/// is part of the signature.
pub const Tab = opaque {};

pub fn decorateTitle(alloc: Allocator, title: []const u8, tab: *const Tab) ![:0]u8 {
    _ = tab;
    return alloc.dupeZ(u8, title);
}
