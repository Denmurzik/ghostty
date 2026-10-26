//! Bell feedback: tab and window title decoration, taskbar flash. Stub: Task 26.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Tab = @import("Tab.zig");

pub fn decorateTitle(alloc: Allocator, title: []const u8, tab: *const Tab) ![:0]u8 {
    _ = tab;
    return alloc.dupeSentinel(u8, title, 0);
}
