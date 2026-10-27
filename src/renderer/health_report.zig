//! The last renderer health the apprt was not told about yet. Reporting never
//! waits for room in the surface mailbox: the callers hold the draw mutex,
//! which the UI thread takes in its sweeps, so a blocking push could deadlock.
//! A full mailbox leaves the report pending for the next draw.
const std = @import("std");
const Health = @import("../renderer.zig").Health;

pub const HealthReport = struct {
    pending: ?Health = null,

    /// Latest wins: a newer health replaces one that was not delivered.
    pub fn set(self: *HealthReport, health: Health) void {
        self.pending = health;
    }

    /// Tries to queue the pending report without waiting.
    pub fn flush(self: *HealthReport, mailbox: anytype) void {
        const health = self.pending orelse return;
        if (mailbox.push(.{ .renderer_health = health }, .instant) > 0) self.pending = null;
    }
};

test "renderer health report: never blocks, retries, latest wins" {
    const Fake = struct {
        room: bool = false,
        pushed: usize = 0,
        last: ?Health = null,
        fn push(self: *@This(), msg: anytype, timeout: anytype) usize {
            // Never `.forever`: the caller holds the draw mutex.
            comptime std.debug.assert(@TypeOf(timeout) == @TypeOf(.instant));
            if (!self.room) return 0;
            self.pushed += 1;
            self.last = msg.renderer_health;
            return 1;
        }
    };
    const Mailbox = struct {
        fake: *Fake,
        fn push(self: @This(), msg: anytype, timeout: anytype) usize {
            return self.fake.push(msg, timeout);
        }
    };

    var fake: Fake = .{};
    const mb: Mailbox = .{ .fake = &fake };
    var report: HealthReport = .{};

    // Nothing pending: nothing sent.
    report.flush(mb);
    try std.testing.expectEqual(@as(usize, 0), fake.pushed);

    // Full mailbox: stays pending; a newer value replaces it.
    report.set(.unhealthy);
    report.flush(mb);
    try std.testing.expect(report.pending != null);
    report.set(.healthy);

    // Room again: the latest is sent once.
    fake.room = true;
    report.flush(mb);
    report.flush(mb);
    try std.testing.expectEqual(@as(usize, 1), fake.pushed);
    try std.testing.expectEqual(Health.healthy, fake.last.?);
    try std.testing.expect(report.pending == null);
}
