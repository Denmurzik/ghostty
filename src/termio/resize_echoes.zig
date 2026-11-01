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
//! only by its size not being a recorded one, or by the recorded one being
//! older than `max_age_ms`: the console echoes within a moment, so an entry
//! that has outlived that never will be answered, and must not swallow the
//! application's own request for the same grid later on.
const std = @import("std");
const global = @import("../global.zig");

pub const ResizeEchoes = struct {
    /// More than a burst of resizes (a drag) can leave unanswered; the
    /// oldest is forgotten first.
    const capacity = 8;

    /// How long an echo is waited for. The console follows a resize with its
    /// `CSI 8 t` within a moment; past this the entry is forgotten.
    pub const max_age_ms: i64 = 1000;

    const Entry = struct { columns: u16, rows: u16, at_ms: i64 = 0 };

    entries: [capacity]Entry = undefined,
    len: usize = 0,
    /// The grid last sent.
    last: ?Entry = null,

    /// A size was sent to the pty. Whether it was recorded.
    pub fn record(self: *ResizeEchoes, columns: u16, rows: u16, now_ms: i64) bool {
        self.expire(now_ms);
        const e: Entry = .{ .columns = columns, .rows = rows, .at_ms = now_ms };
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

    /// The clock `record` and `consume` are given.
    pub fn nowMs() i64 {
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        return now.toMilliseconds();
    }

    /// Forget the entries whose echo is overdue.
    fn expire(self: *ResizeEchoes, now_ms: i64) void {
        var keep: usize = 0;
        for (self.entries[0..self.len]) |e| {
            if (now_ms - e.at_ms > max_age_ms) continue;
            self.entries[keep] = e;
            keep += 1;
        }
        self.len = keep;
    }

    /// Forget which grid was sent last, so the next `record` of the same grid
    /// is recorded: a re-sync resize sends the grid the pty already had on
    /// record, and the console still echoes it.
    pub fn rearm(self: *ResizeEchoes) void {
        self.last = null;
    }

    /// Whether an application's own `CSI 8 t` (not an echo) left the pseudo
    /// console on a grid other than ours: the console resizes its buffer on
    /// that request by itself, whatever the terminal does with it.
    pub fn needsResync(grid_columns: u16, grid_rows: u16, req_columns: u16, req_rows: u16) bool {
        return grid_columns != req_columns or grid_rows != req_rows;
    }

    /// Whether a `CSI 8 t` for this size is the echo of a recorded one;
    /// that entry and the older ones are used up.
    pub fn consume(self: *ResizeEchoes, columns: u16, rows: u16, now_ms: i64) bool {
        self.expire(now_ms);
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
    try std.testing.expect(!e.consume(100, 30, 0));

    _ = e.record(167, 51, 0);
    _ = e.record(95, 29, 0);
    try std.testing.expect(e.consume(167, 51, 0));
    // Used up: a second request for it is not an echo.
    try std.testing.expect(!e.consume(167, 51, 0));
    try std.testing.expect(!e.consume(100, 30, 0));
    try std.testing.expect(e.consume(95, 29, 0));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "ResizeEchoes: a pixel-only resize records nothing" {
    var e: ResizeEchoes = .{};
    _ = e.record(80, 24, 0);
    _ = e.record(80, 24, 0);
    _ = e.record(80, 24, 0);
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expect(e.consume(80, 24, 0));
    try std.testing.expect(!e.consume(80, 24, 0));
    // Going back to a grid after another one is a new resize.
    _ = e.record(100, 30, 0);
    _ = e.record(80, 24, 0);
    try std.testing.expectEqual(@as(usize, 2), e.len);
}

test "ResizeEchoes: an application's own size is not an echo" {
    var e: ResizeEchoes = .{};
    _ = e.record(167, 51, 0);
    try std.testing.expect(!e.consume(100, 30, 0));
    try std.testing.expect(e.consume(167, 51, 0));
}

test "ResizeEchoes: a stale entry does not eat a later request" {
    var e: ResizeEchoes = .{};
    // 95x29 never got its echo; 167x51 did, which also retires 95x29.
    _ = e.record(95, 29, 0);
    _ = e.record(167, 51, 0);
    try std.testing.expect(e.consume(167, 51, 0));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expect(!e.consume(95, 29, 0));
}

test "ResizeEchoes: the oldest size is forgotten past capacity" {
    var e: ResizeEchoes = .{};
    for (0..ResizeEchoes.capacity + 1) |i| _ = e.record(@intCast(10 + i), 24, 0);
    try std.testing.expect(!e.consume(10, 24, 0));
    try std.testing.expect(e.consume(10 + ResizeEchoes.capacity, 24, 0));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "windows resize echoes: a re-sync of the grid last sent is recorded again" {
    var e: ResizeEchoes = .{};
    try std.testing.expect(e.record(80, 25, 0));
    // The same grid again records nothing, so its echo would pass as a request.
    try std.testing.expect(!e.record(80, 25, 0));
    e.rearm();
    try std.testing.expect(e.record(80, 25, 0));
    try std.testing.expectEqual(@as(usize, 2), e.len);
    // Both echoes are used up by the first one.
    try std.testing.expect(e.consume(80, 25, 0));
    try std.testing.expectEqual(@as(usize, 1), e.len);
}

test "windows resize echoes: only a request for another grid needs a re-sync" {
    try std.testing.expect(ResizeEchoes.needsResync(80, 25, 120, 35));
    try std.testing.expect(ResizeEchoes.needsResync(80, 25, 80, 35));
    try std.testing.expect(!ResizeEchoes.needsResync(80, 25, 80, 25));
}

test "windows resize echoes: a real request after a maximize is not eaten by a stale entry" {
    var e: ResizeEchoes = .{};
    // The window was set to 100x30 by an application's request; its echo
    // never came (the console was already there).
    try std.testing.expect(e.record(100, 30, 0));
    // Ten seconds later a maximize sends 186x49 ...
    try std.testing.expect(e.record(186, 49, 10_000));
    try std.testing.expectEqual(@as(usize, 1), e.len);
    // ... and the application asks for 100x30 again: a request, not an echo.
    try std.testing.expect(!e.consume(100, 30, 10_500));
    // The maximize's own echo is still honoured.
    try std.testing.expect(e.consume(186, 49, 10_600));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "windows resize echoes: a genuine echo is still dropped" {
    var e: ResizeEchoes = .{};
    try std.testing.expect(e.record(186, 49, 5_000));
    try std.testing.expect(e.consume(186, 49, 5_000 + ResizeEchoes.max_age_ms));
    try std.testing.expect(!e.consume(186, 49, 5_001 + ResizeEchoes.max_age_ms));
}

test "windows resize echoes: an expired entry is not matched" {
    var e: ResizeEchoes = .{};
    try std.testing.expect(e.record(120, 40, 1_000));
    try std.testing.expect(!e.consume(120, 40, 1_001 + ResizeEchoes.max_age_ms));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    // A later resize records afresh.
    try std.testing.expect(e.record(80, 24, 5_000));
    try std.testing.expect(e.consume(80, 24, 5_100));
}
