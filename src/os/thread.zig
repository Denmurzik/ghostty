const std = @import("std");
const builtin = @import("builtin");

/// The spawn config for Ghostty's own long-lived threads (renderer, IO,
/// pty reader, ...).
///
/// On Windows `std.Thread.spawn` passes `stack_size` to NtCreateThreadEx as
/// the *committed* stack size, so the default (16 MiB) charges 16 MiB of
/// private memory per thread up front, about 48 MiB per surface. The
/// reservation comes from the executable header instead (16 MiB for Zig
/// executables), and a stack grows into it on demand through its guard
/// page. So asking for the smallest commit keeps the same maximum stack
/// and only commits what the thread uses.
///
/// Elsewhere `stack_size` is the size of the stack mapping, whose pages
/// are only backed when touched, so the default is kept.
pub const spawn_config: std.Thread.SpawnConfig = if (builtin.os.tag == .windows)
    .{ .stack_size = 64 * 1024 }
else
    .{};

test "spawn_config commits little and keeps a large stack reserve" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const k32 = struct {
        const PROCESS_MEMORY_COUNTERS_EX = extern struct {
            cb: u32,
            PageFaultCount: u32,
            PeakWorkingSetSize: usize,
            WorkingSetSize: usize,
            QuotaPeakPagedPoolUsage: usize,
            QuotaPagedPoolUsage: usize,
            QuotaPeakNonPagedPoolUsage: usize,
            QuotaNonPagedPoolUsage: usize,
            PagefileUsage: usize,
            PeakPagefileUsage: usize,
            PrivateUsage: usize,
        };
        extern "kernel32" fn K32GetProcessMemoryInfo(
            process: std.os.windows.HANDLE,
            counters: *PROCESS_MEMORY_COUNTERS_EX,
            cb: u32,
        ) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn GetCurrentThreadStackLimits(
            low: *usize,
            high: *usize,
        ) callconv(.winapi) void;

        fn privateUsage() usize {
            var counters = std.mem.zeroes(PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS_EX);
            _ = K32GetProcessMemoryInfo(
                std.os.windows.GetCurrentProcess(),
                &counters,
                @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
            );
            return counters.PrivateUsage;
        }
    };

    const Probe = struct {
        reserve: usize = 0,
        go: std.atomic.Value(bool) = .init(false),
        exit: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var low: usize = 0;
            var high: usize = 0;
            k32.GetCurrentThreadStackLimits(&low, &high);
            self.reserve = high - low;
            self.go.store(true, .release);
            while (!self.exit.load(.acquire)) std.atomic.spinLoopHint();
        }
    };

    // Four threads alive at once: with the 16 MiB default they would
    // commit 64 MiB.
    var probes: [4]Probe = @splat(.{});
    var threads: [probes.len]std.Thread = undefined;
    const before = k32.privateUsage();
    for (&probes, &threads) |*p, *t| t.* = try std.Thread.spawn(spawn_config, Probe.run, .{p});
    for (&probes) |*p| while (!p.go.load(.acquire)) std.atomic.spinLoopHint();
    const after = k32.privateUsage();
    for (&probes, threads) |*p, t| {
        p.exit.store(true, .release);
        t.join();
    }

    try std.testing.expect(after -| before < 4 * 1024 * 1024);
    for (probes) |p| try std.testing.expect(p.reserve >= 8 * 1024 * 1024);
}
