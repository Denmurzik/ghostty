//! The resize requests a Windows pseudo console makes on its own.
//!
//! Every resize of a ConPTY is answered with a `CSI 8 ; rows ; cols t` for
//! the new size, a moment later. Applications' own `CSI 8 t` never gets
//! through conhost, so every one that arrives is such an echo. Acting on it
//! as a window resize request drags the window back to a size it just left
//! (the fullscreen grid after fullscreen ended). Each size sent to the pty
//! is recorded and the first request for it is consumed.
const std = @import("std");

pub const ResizeEchoes = struct {
    /// More than a burst of resizes (a drag) can leave unanswered; the
    /// oldest is forgotten first.
    const capacity = 8;

    const Entry = struct { columns: u16, rows: u16 };

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// A size was sent to the pty.
    pub fn record(self: *ResizeEchoes, columns: u16, rows: u16) void {
        if (self.len == capacity) {
            std.mem.copyForwards(Entry, self.entries[0 .. capacity - 1], self.entries[1..capacity]);
            self.len -= 1;
        }
        self.entries[self.len] = .{ .columns = columns, .rows = rows };
        self.len += 1;
    }

    /// Whether a `CSI 8 t` for this size is the echo of a recorded one,
    /// which is then used up.
    pub fn consume(self: *ResizeEchoes, columns: u16, rows: u16) bool {
        for (self.entries[0..self.len], 0..) |e, i| {
            if (e.columns != columns or e.rows != rows) continue;
            std.mem.copyForwards(Entry, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
            self.len -= 1;
            return true;
        }
        return false;
    }
};

test "ResizeEchoes: one echo per recorded size" {
    var e: ResizeEchoes = .{};
    try std.testing.expect(!e.consume(100, 30));

    e.record(167, 51);
    e.record(95, 29);
    try std.testing.expect(e.consume(167, 51));
    // Used up: a second request for it is not an echo.
    try std.testing.expect(!e.consume(167, 51));
    try std.testing.expect(!e.consume(100, 30));
    try std.testing.expect(e.consume(95, 29));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "ResizeEchoes: the same size twice is two echoes" {
    var e: ResizeEchoes = .{};
    e.record(80, 24);
    e.record(100, 30);
    e.record(80, 24);
    try std.testing.expect(e.consume(80, 24));
    try std.testing.expect(e.consume(80, 24));
    try std.testing.expect(!e.consume(80, 24));
    try std.testing.expect(e.consume(100, 30));
}

test "ResizeEchoes: the oldest size is forgotten past capacity" {
    var e: ResizeEchoes = .{};
    for (0..ResizeEchoes.capacity + 1) |i| e.record(@intCast(10 + i), 24);
    try std.testing.expect(!e.consume(10, 24));
    try std.testing.expect(e.consume(11, 24));
    try std.testing.expect(e.consume(10 + ResizeEchoes.capacity, 24));
}
