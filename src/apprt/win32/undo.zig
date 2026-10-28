//! Pure undo/redo model (owner: M5 Task 14). Mirrors macOS ExpiringUndoManager:
//! every entry carries an absolute expiry, an expired entry can no longer be
//! undone and is handed back to the caller (to be closed for real).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { close_tab, close_window, close_split, new_tab, new_window, new_split, group };

/// `Entry` must have an `expires_ms: u64` field (absolute, same clock as the
/// `now_ms` arguments). An entry is expired when `expires_ms <= now_ms`, so a
/// timeout of 0 yields an entry that is expired on arrival.
pub fn Stack(comptime Entry: type) type {
    return struct {
        const Self = @This();
        pub const Element = Entry;

        undo: std.ArrayList(Entry) = .empty,
        redo: std.ArrayList(Entry) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.undo.deinit(gpa);
            self.redo.deinit(gpa);
        }

        /// Records a new undoable action; a new action invalidates redo.
        /// Dropped redo entries are discarded without being returned.
        pub fn push(self: *Self, gpa: Allocator, e: Entry) !void {
            try self.undo.append(gpa, e);
            self.redo.clearRetainingCapacity();
        }

        pub fn pushRedo(self: *Self, gpa: Allocator, e: Entry) !void {
            try self.redo.append(gpa, e);
        }

        pub fn popUndo(self: *Self, now_ms: u64) ?Entry {
            return popLive(&self.undo, now_ms);
        }

        pub fn popRedo(self: *Self, now_ms: u64) ?Entry {
            return popLive(&self.redo, now_ms);
        }

        /// Topmost entry that is not expired; expired ones stay for takeExpired.
        fn popLive(list: *std.ArrayList(Entry), now_ms: u64) ?Entry {
            var i = list.items.len;
            while (i > 0) {
                i -= 1;
                if (list.items[i].expires_ms > now_ms) return list.orderedRemove(i);
            }
            return null;
        }

        /// Moves every expired entry (undo then redo, oldest first) to `out`.
        pub fn takeExpired(self: *Self, now_ms: u64, out: *std.ArrayList(Entry), gpa: Allocator) !void {
            try drain(&self.undo, now_ms, out, gpa);
            try drain(&self.redo, now_ms, out, gpa);
        }

        fn drain(list: *std.ArrayList(Entry), now_ms: u64, out: *std.ArrayList(Entry), gpa: Allocator) !void {
            var keep: usize = 0;
            for (list.items) |e| {
                if (e.expires_ms <= now_ms) {
                    try out.append(gpa, e);
                } else {
                    list.items[keep] = e;
                    keep += 1;
                }
            }
            list.shrinkRetainingCapacity(keep);
        }

        /// Quit: everything still parked, undo then redo, oldest first.
        pub fn takeAll(self: *Self, out: *std.ArrayList(Entry), gpa: Allocator) !void {
            try out.appendSlice(gpa, self.undo.items);
            try out.appendSlice(gpa, self.redo.items);
            self.undo.clearRetainingCapacity();
            self.redo.clearRetainingCapacity();
        }

        /// Moves entries matching `pred` (e.g. a parked child exited) to `out`.
        pub fn removeIf(
            self: *Self,
            ctx: anytype,
            pred: fn (@TypeOf(ctx), *const Entry) bool,
            out: *std.ArrayList(Entry),
            gpa: Allocator,
        ) !void {
            inline for (.{ &self.undo, &self.redo }) |list| {
                var keep: usize = 0;
                for (list.items) |e| {
                    if (pred(ctx, &e)) {
                        try out.append(gpa, e);
                    } else {
                        list.items[keep] = e;
                        keep += 1;
                    }
                }
                list.shrinkRetainingCapacity(keep);
            }
        }

        /// Earliest expiry across both stacks, for timer scheduling.
        pub fn nextExpiry(self: *const Self) ?u64 {
            var min: ?u64 = null;
            for (self.undo.items) |e| min = if (min) |m| @min(m, e.expires_ms) else e.expires_ms;
            for (self.redo.items) |e| min = if (min) |m| @min(m, e.expires_ms) else e.expires_ms;
            return min;
        }
    };
}

const T = struct { id: u8, expires_ms: u64 };
const TS = Stack(T);
const alloc = std.testing.allocator;

test "win32 undo stack: LIFO order" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .id = 1, .expires_ms = 100 });
    try s.push(alloc, .{ .id = 2, .expires_ms = 100 });
    try std.testing.expectEqual(@as(u8, 2), s.popUndo(0).?.id);
    try std.testing.expectEqual(@as(u8, 1), s.popUndo(0).?.id);
    try std.testing.expect(s.popUndo(0) == null);
}

test "win32 undo stack: push clears redo, redo round trip" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try s.pushRedo(alloc, .{ .id = 7, .expires_ms = 100 });
    try std.testing.expectEqual(@as(u8, 7), s.popRedo(0).?.id);
    try s.pushRedo(alloc, .{ .id = 8, .expires_ms = 100 });
    try s.push(alloc, .{ .id = 1, .expires_ms = 100 });
    try std.testing.expect(s.popRedo(0) == null);
}

test "win32 undo stack: expired entry never returned, lands in takeExpired" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .id = 1, .expires_ms = 50 });
    try s.push(alloc, .{ .id = 2, .expires_ms = 200 });
    try s.pushRedo(alloc, .{ .id = 3, .expires_ms = 60 });
    try std.testing.expect(s.popRedo(60) == null);
    try std.testing.expectEqual(@as(u8, 2), s.popUndo(100).?.id);
    try std.testing.expect(s.popUndo(100) == null);
    var out: std.ArrayList(T) = .empty;
    defer out.deinit(alloc);
    try s.takeExpired(100, &out, alloc);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(s.nextExpiry() == null);
}

test "win32 undo stack: nextExpiry is the minimum" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try std.testing.expect(s.nextExpiry() == null);
    try s.push(alloc, .{ .id = 1, .expires_ms = 300 });
    try s.push(alloc, .{ .id = 2, .expires_ms = 120 });
    try s.pushRedo(alloc, .{ .id = 3, .expires_ms = 500 });
    try std.testing.expectEqual(@as(u64, 120), s.nextExpiry().?);
}

test "win32 undo stack: takeAll empties both stacks" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .id = 1, .expires_ms = 300 });
    try s.pushRedo(alloc, .{ .id = 3, .expires_ms = 500 });
    var out: std.ArrayList(T) = .empty;
    defer out.deinit(alloc);
    try s.takeAll(&out, alloc);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(s.popUndo(0) == null and s.popRedo(0) == null);
    try std.testing.expect(s.nextExpiry() == null);
}

test "win32 undo stack: removeIf takes only matching entries" {
    var s: TS = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .id = 1, .expires_ms = 300 });
    try s.push(alloc, .{ .id = 2, .expires_ms = 300 });
    try s.push(alloc, .{ .id = 3, .expires_ms = 300 });
    var out: std.ArrayList(T) = .empty;
    defer out.deinit(alloc);
    const P = struct {
        fn odd(_: u8, e: *const T) bool {
            return e.id % 2 == 1;
        }
    };
    try s.removeIf(@as(u8, 0), P.odd, &out, alloc);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u8, 2), s.popUndo(0).?.id);
    try std.testing.expect(s.popUndo(0) == null);
}

test "win32 undo stack: timeout 0 is already expired" {
    var s: TS = .{};
    defer s.deinit(alloc);
    const now: u64 = 1000;
    try s.push(alloc, .{ .id = 1, .expires_ms = now });
    try std.testing.expect(s.popUndo(now) == null);
    var out: std.ArrayList(T) = .empty;
    defer out.deinit(alloc);
    try s.takeExpired(now, &out, alloc);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}
