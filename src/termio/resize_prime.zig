//! A key-up sent ahead of the first write after a pseudo console resize.
//!
//! After a ConPTY resize, Git Bash (the MSYS2/Cygwin console layer)
//! sometimes misses the window-size event. It handles the event later,
//! together with the next input record, and that record is lost. The user
//! sees the first key typed after a split or a window resize vanish
//! (`exit` runs as `xit`). The first write after a resize therefore starts
//! with a Shift key-up in win32-input-mode, which the pseudo console turns
//! into a key-up record: if that record is the one lost, nothing is lost,
//! and otherwise every reader ignores it (Cygwin drops key-ups, and
//! cooked-mode readers never see them).
//!
//! A write that comes very soon after the resize can reach the pseudo
//! console before the resize does, so the prefix goes on every write until
//! one comes `settle_ns` or more after the last resize.
const std = @import("std");

pub const ResizePrime = struct {
    /// win32-input-mode: Vk=VK_SHIFT (16), Sc=42, Uc=0, Kd=0 (up), Cs=0, Rc=1.
    pub const sequence = "\x1b[16;42;0;0;0;1_";

    /// Measured: the lost-input state forms within ~10 ms of a resize, and
    /// a prompt shell answers the resize within ~35 ms.
    pub const settle_ns: i96 = 50 * std.time.ns_per_ms;

    const Grid = struct { columns: u16, rows: u16 };

    grid: ?Grid = null,
    pending: bool = false,
    resized_ns: i96 = 0,

    /// The pseudo console was given this grid at `now_ns`. The first grid
    /// (the spawn size) and a pixel-only resize arm nothing.
    pub fn resized(self: *ResizePrime, columns: u16, rows: u16, now_ns: i96) void {
        const g: Grid = .{ .columns = columns, .rows = rows };
        const prev = self.grid;
        self.grid = g;
        const p = prev orelse return;
        if (p.columns == g.columns and p.rows == g.rows) return;
        self.pending = true;
        self.resized_ns = now_ns;
    }

    /// Whether a write at `now_ns` must start with `sequence`.
    pub fn take(self: *ResizePrime, now_ns: i96) bool {
        if (!self.pending) return false;
        if (now_ns - self.resized_ns >= settle_ns) self.pending = false;
        return true;
    }
};

const ms = std.time.ns_per_ms;

test "ResizePrime: nothing before the first resize" {
    var p: ResizePrime = .{};
    try std.testing.expect(!p.take(0));
    p.resized(80, 24, 0);
    try std.testing.expect(!p.take(100 * ms));
}

test "ResizePrime: one prefix for a write after the settle time" {
    var p: ResizePrime = .{};
    p.resized(80, 24, 0);
    p.resized(100, 30, 1000 * ms);
    try std.testing.expect(p.take(2500 * ms));
    try std.testing.expect(!p.take(2501 * ms));
}

test "ResizePrime: writes inside the settle time keep the prefix armed" {
    var p: ResizePrime = .{};
    p.resized(80, 24, 0);
    p.resized(100, 30, 1000 * ms);
    try std.testing.expect(p.take(1000 * ms));
    try std.testing.expect(p.take(1020 * ms));
    try std.testing.expect(p.take(1049 * ms));
    try std.testing.expect(p.take(1050 * ms));
    try std.testing.expect(!p.take(1051 * ms));
}

test "ResizePrime: a later resize re-arms and restarts the settle time" {
    var p: ResizePrime = .{};
    p.resized(80, 24, 0);
    p.resized(100, 30, 1000 * ms);
    try std.testing.expect(p.take(1040 * ms));
    p.resized(90, 30, 1045 * ms);
    try std.testing.expect(p.take(1080 * ms));
    try std.testing.expect(p.take(1095 * ms));
    try std.testing.expect(!p.take(1096 * ms));
}

test "ResizePrime: a pixel-only resize (same grid) arms nothing" {
    var p: ResizePrime = .{};
    p.resized(80, 24, 0);
    p.resized(80, 24, 1000 * ms);
    try std.testing.expect(!p.take(1100 * ms));
}
