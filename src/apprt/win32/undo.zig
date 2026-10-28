//! Pure undo/redo model (owner: M5 Task 14). Shell until then.
const std = @import("std");

pub const Kind = enum { close_tab, close_window, close_split, new_tab, new_window, new_split, group };

/// Methods arrive with Task 14.
pub fn Stack(comptime Entry: type) type {
    return struct {
        const Self = @This();
        pub const Element = Entry;
    };
}

test "win32 undo: shell" {
    const S = Stack(u8);
    _ = S{};
}
