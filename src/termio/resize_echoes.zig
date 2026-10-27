//! The resize requests a Windows pseudo console makes on its own.
//!
//! When a ConPTY changes size it follows with a `CSI 8 ; rows ; cols t` for
//! the new size, a moment later. Acting on it as a window resize request
//! drags the window back to a size it just left (the fullscreen grid after
//! fullscreen ended). Each grid sent to the pty is recorded, a pixel-only
//! resize (same grid) is not, and the first request for a recorded grid is
//! consumed together with the older entries before it: the echoes come in
//! the order of the resizes, so an older entry whose echo never came must not
//! eat a later, real request. An application's own `CSI 8 t` is told apart
//! only by its size not being a recorded one.
const std = @import("std");

pub const ResizeEchoes = struct {
    /// More than a burst of resizes (a drag) can leave unanswered; the
    /// oldest is forgotten first.
    const capacity = 8;

    const Entry = struct { columns: u16, rows: u16 };

    entries: [capacity]Entry = undefined,
    len: usize = 0,
    /// The grid last sent.
    last: ?Entry = null,

    /// A size was sent to the pty. Whether it was recorded.
    pub fn record(self: *ResizeEchoes, columns: u16, rows: u16) bool {
        const e: Entry = .{ .columns = columns, .rows = rows };
        if (self.last) |l| {
            if (l.columns == columns and l.rows == rows) return false;
        }
        self.last = e;
        if (self.len == capacity) {
            std.mem.copyForwards(Entry, self.entries[0 .. capacity - 1], self.entries[1..capacity]);
            self.len -= 1;
        }
        self.entries[self.len] = e;
        self.len += 1;
        return true;
    }

    /// Whether a `CSI 8 t` for this size is the echo of a recorded one;
    /// that entry and the older ones are used up.
    pub fn consume(self: *ResizeEchoes, columns: u16, rows: u16) bool {
        for (self.entries[0..self.len], 0..) |e, i| {
            if (e.columns != columns or e.rows != rows) continue;
            std.mem.copyForwards(Entry, self.entries[0 .. self.len - i - 1], self.entries[i + 1 .. self.len]);
            self.len -= i + 1;
            return true;
        }
        return false;
    }
};

test "ResizeEchoes: one echo per recorded size" {
    var e: ResizeEchoes = .{};
    try std.testing.expect(!e.consume(100, 30));

    _ = e.record(167, 51);
    _ = e.record(95, 29);
    try std.testing.expect(e.consume(167, 51));
    // Used up: a second request for it is not an echo.
    try std.testing.expect(!e.consume(167, 51));
    try std.testing.expect(!e.consume(100, 30));
    try std.testing.expect(e.consume(95, 29));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "ResizeEchoes: a pixel-only resize records nothing" {
    var e: ResizeEchoes = .{};
    _ = e.record(80, 24);
    _ = e.record(80, 24);
    _ = e.record(80, 24);
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expect(e.consume(80, 24));
    try std.testing.expect(!e.consume(80, 24));
    // Going back to a grid after another one is a new resize.
    _ = e.record(100, 30);
    _ = e.record(80, 24);
    try std.testing.expectEqual(@as(usize, 2), e.len);
}

test "ResizeEchoes: an application's own size is not an echo" {
    var e: ResizeEchoes = .{};
    _ = e.record(167, 51);
    try std.testing.expect(!e.consume(100, 30));
    try std.testing.expect(e.consume(167, 51));
}

test "ResizeEchoes: a stale entry does not eat a later request" {
    var e: ResizeEchoes = .{};
    // 95x29 never got its echo; 167x51 did, which also retires 95x29.
    _ = e.record(95, 29);
    _ = e.record(167, 51);
    try std.testing.expect(e.consume(167, 51));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expect(!e.consume(95, 29));
}

test "ResizeEchoes: the oldest size is forgotten past capacity" {
    var e: ResizeEchoes = .{};
    for (0..ResizeEchoes.capacity + 1) |i| _ = e.record(@intCast(10 + i), 24);
    try std.testing.expect(!e.consume(10, 24));
    try std.testing.expect(e.consume(10 + ResizeEchoes.capacity, 24));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}
