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
//!
//! Only a conhost that knows win32-input-mode parses the sequence (an older
//! one could show it as text), so nothing is armed until the pseudo console
//! has asked for the mode (`CSI ? 9001 h`, among its first output bytes).
const std = @import("std");

pub const ResizePrime = struct {
    /// win32-input-mode: Vk=VK_SHIFT (16), Sc=42, Uc=0, Kd=0 (up), Cs=0, Rc=1.
    pub const sequence = "\x1b[16;42;0;0;0;1_";

    /// Measured: the lost-input state forms within ~10 ms of a resize, and
    /// a prompt shell answers the resize within ~35 ms.
    pub const settle_ns: i96 = 50 * std.time.ns_per_ms;

    const Grid = struct { columns: u16, rows: u16 };

    /// The pseudo console's request for win32-input-mode.
    pub const request = "\x1b[?9001h";

    /// The output searched for `request`: it comes first, at startup.
    pub const scan_bytes = 4096;

    grid: ?Grid = null,
    pending: bool = false,
    resized_ns: i96 = 0,

    /// Set by the read thread once `request` was seen.
    win32_input: std.atomic.Value(bool) = .init(false),

    /// Read thread only: the end of the previous chunk, so a `request`
    /// split across two reads is still found.
    tail: [request.len - 1]u8 = undefined,
    tail_len: usize = 0,

    /// Pseudo console output, read thread.
    pub fn noteOutput(self: *ResizePrime, buf: []const u8) void {
        // The tail joined with the head of this chunk covers every split.
        var join: [2 * (request.len - 1)]u8 = undefined;
        const head = buf[0..@min(buf.len, request.len - 1)];
        @memcpy(join[0..self.tail_len], self.tail[0..self.tail_len]);
        @memcpy(join[self.tail_len..][0..head.len], head);
        if (std.mem.indexOf(u8, join[0 .. self.tail_len + head.len], request) != null or
            std.mem.indexOf(u8, buf, request) != null)
        {
            self.win32_input.store(true, .release);
        }

        // Keep the last bytes of tail + buf.
        if (buf.len >= self.tail.len) {
            @memcpy(&self.tail, buf[buf.len - self.tail.len ..]);
            self.tail_len = self.tail.len;
        } else {
            const keep = @min(self.tail_len, self.tail.len - buf.len);
            std.mem.copyForwards(u8, self.tail[0..keep], self.tail[self.tail_len - keep .. self.tail_len]);
            @memcpy(self.tail[keep..][0..buf.len], buf);
            self.tail_len = keep + buf.len;
        }
    }

    /// The pseudo console was given this grid at `now_ns`. The first grid
    /// (the spawn size) and a pixel-only resize arm nothing.
    pub fn resized(self: *ResizePrime, columns: u16, rows: u16, now_ns: i96) void {
        const g: Grid = .{ .columns = columns, .rows = rows };
        const prev = self.grid;
        self.grid = g;
        const p = prev orelse return;
        if (p.columns == g.columns and p.rows == g.rows) return;
        if (!self.win32_input.load(.acquire)) return;
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
    p.noteOutput(ResizePrime.request);
    try std.testing.expect(!p.take(0));
    p.resized(80, 24, 0);
    try std.testing.expect(!p.take(100 * ms));
}

test "ResizePrime: one prefix for a write after the settle time" {
    var p: ResizePrime = .{};
    p.noteOutput(ResizePrime.request);
    p.resized(80, 24, 0);
    p.resized(100, 30, 1000 * ms);
    try std.testing.expect(p.take(2500 * ms));
    try std.testing.expect(!p.take(2501 * ms));
}

test "ResizePrime: writes inside the settle time keep the prefix armed" {
    var p: ResizePrime = .{};
    p.noteOutput(ResizePrime.request);
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
    p.noteOutput(ResizePrime.request);
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
    p.noteOutput(ResizePrime.request);
    p.resized(80, 24, 0);
    p.resized(80, 24, 1000 * ms);
    try std.testing.expect(!p.take(1100 * ms));
}

test "ResizePrime: nothing armed until the pseudo console asks for win32-input-mode" {
    var p: ResizePrime = .{};
    p.resized(80, 24, 0);
    p.noteOutput("\x1b[?1004h");
    p.resized(100, 30, 1000 * ms);
    try std.testing.expect(!p.take(2000 * ms));
    p.noteOutput("\x1b[?25l\x1b[?9001h\x1b[?1004h");
    p.resized(90, 30, 3000 * ms);
    try std.testing.expect(p.take(4000 * ms));
}

test "ResizePrime: the request is found when a read splits it at any offset" {
    const out = "\x1b[?25l" ++ ResizePrime.request ++ "\x1b[?1004h";
    const start = "\x1b[?25l".len;
    for (start..start + ResizePrime.request.len + 1) |cut| {
        var p: ResizePrime = .{};
        p.noteOutput(out[0..cut]);
        p.noteOutput(out[cut..]);
        try std.testing.expect(p.win32_input.load(.acquire));
    }
}

test "ResizePrime: the request is found across many one-byte reads" {
    var p: ResizePrime = .{};
    for ("ab" ++ ResizePrime.request) |c| p.noteOutput(&.{c});
    try std.testing.expect(p.win32_input.load(.acquire));
}

test "ResizePrime: no request, no win32 input" {
    var p: ResizePrime = .{};
    p.noteOutput("\x1b[?9001");
    p.noteOutput("l\x1b[?1004h");
    p.noteOutput("\x1b[?900");
    p.noteOutput("2h");
    try std.testing.expect(!p.win32_input.load(.acquire));
}
