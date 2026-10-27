//! Input latency tracer (diagnostic, Windows port). With
//! `GHOSTTY_LATENCY_TRACE=<csv path>` every input (key or wheel) is followed
//! through the pipeline and one CSV line per finished sample is appended:
//!
//!   UI thread input -> pty write -> pty output -> parsed -> render start
//!   -> present
//!
//! Output that arrives with no input open (a command printing on its own)
//! becomes an `output` sample that starts at the pty read. When the variable
//! is unset every mark is one relaxed atomic load.
//!
//! The marks come from the UI, IO, read and render threads; a mutex guards
//! the one open sample. The state machine (`Tracer`) takes its times as
//! arguments so tests drive it with a fake clock.

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const windows = @import("windows.zig");

const log = std.log.scoped(.windows_latency);

pub const InputKind = enum { key, wheel };
pub const SampleKind = enum { key, wheel, output };

/// Counters that only accumulate (cumulative columns of every CSV line).
pub const Counter = enum { wheel_message, scroll_call };

/// An input without a write (a modifier press) is dropped after this long.
const no_write_timeout_ns: u64 = 500 * std.time.ns_per_ms;

/// A sample that never reached a present (nothing changed on screen).
const stale_timeout_ns: u64 = 2000 * std.time.ns_per_ms;

pub const Sample = struct {
    kind: SampleKind,
    /// False: replaced by the next input before it closed. Counted, written
    /// to the CSV, left out of percentiles.
    complete: bool = true,
    t0_ns: u64,
    input_to_write_ns: u64 = 0,
    write_to_output_ns: u64 = 0,
    output_to_parsed_ns: u64 = 0,
    parsed_to_render_ns: u64 = 0,
    slot_wait_ns: u64 = 0,
    render_to_present_ns: u64 = 0,
    total_ns: u64 = 0,
    writes: u32 = 0,
    write_bytes: u64 = 0,
    output_bytes: u64 = 0,
    slices: u32 = 0,
    yields: u32 = 0,
    presents_between: u32 = 0,
    surface: u32 = 0,
    /// Every mark while the sample was open, for reading a surprising row
    /// ("kind@offset" in microseconds, see `Tracer.event`).
    events: Events = .{},
};

/// A short log of the marks of one sample.
pub const Events = struct {
    const max = 16;
    const Entry = struct { tag: u8, offset_us: u32 };

    items: [max]Entry = undefined,
    len: u8 = 0,

    fn add(self: *Events, tag: u8, offset_ns: u64) void {
        if (self.len == max) return;
        self.items[self.len] = .{ .tag = tag, .offset_us = @intCast(@min(offset_ns / std.time.ns_per_us, std.math.maxInt(u32))) };
        self.len += 1;
    }

    pub fn format(self: Events, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.items[0..self.len], 0..) |e, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.print("{c}{d}", .{ e.tag, e.offset_us });
        }
    }
};

/// The open sample and the rules that close it. Pure bookkeeping.
pub const Tracer = struct {
    open: bool = false,
    kind: SampleKind = .key,
    t0: u64 = 0,
    t_write: ?u64 = null,
    t_out: ?u64 = null,
    t_parsed: ?u64 = null,
    t_render: ?u64 = null,
    slot_wait: u64 = 0,
    writes: u32 = 0,
    write_bytes: u64 = 0,
    output_bytes: u64 = 0,
    slices: u32 = 0,
    yields: u32 = 0,
    presents_between: u32 = 0,
    events: Events = .{},

    /// Inputs replaced before they closed.
    incomplete: u64 = 0,

    /// Opens a sample. Returns the previous one when it was still open and
    /// had been written (an incomplete sample).
    pub fn input(self: *Tracer, now: u64, kind: InputKind) ?Sample {
        const old = self.expire(now) orelse self.abandon();
        self.* = .{ .open = true, .kind = switch (kind) {
            .key => .key,
            .wheel => .wheel,
        }, .t0 = now, .incomplete = self.incomplete };
        self.events.add('I', 0);
        return old;
    }

    pub fn write(self: *Tracer, now: u64, bytes: usize) void {
        if (!self.open or self.kind == .output) return;
        if (self.t_out != null) return;
        if (self.t_write == null) self.t_write = now;
        self.writes += 1;
        self.write_bytes += bytes;
        self.events.add('W', sub(now, self.t0));
    }

    pub fn output(self: *Tracer, now: u64, bytes: usize) ?Sample {
        const old = self.expire(now);
        if (!self.open) {
            self.* = .{
                .open = true,
                .kind = .output,
                .t0 = now,
                .t_write = now,
                .t_out = now,
                .output_bytes = bytes,
                .incomplete = self.incomplete,
            };
            self.events.add('O', 0);
            return old;
        }
        // Output before the write belongs to something else.
        if (self.t_write == null) return old;
        if (self.t_out == null) self.t_out = now;
        self.output_bytes += bytes;
        self.events.add('O', sub(now, self.t0));
        return old;
    }

    pub fn parsed(self: *Tracer, now: u64, slices: u32, yields: u32) void {
        if (!self.open or self.t_out == null) return;
        self.slices += slices;
        self.yields += yields;
        if (self.t_render == null) self.t_parsed = now;
        self.events.add('P', sub(now, self.t0));
    }

    /// The read loop handed the renderer state mutex off after a slice.
    pub fn yielded(self: *Tracer) void {
        if (self.open and self.t_out != null) self.yields += 1;
    }

    pub fn renderStart(self: *Tracer, now: u64) void {
        if (!self.open) return;
        self.events.add('R', sub(now, self.t0));
        if (self.t_parsed == null or self.t_render != null) return;
        self.t_render = now;
    }

    pub fn note(self: *Tracer, now: u64, tag: u8) void {
        if (self.open) self.events.add(tag, sub(now, self.t0));
    }

    pub fn slotWait(self: *Tracer, ns: u64) void {
        if (!self.open or self.t_render == null) return;
        self.slot_wait += ns;
        self.events.add('S', ns);
    }

    /// The first present of a frame that started after the output was
    /// parsed closes the sample. Earlier presents (the keypress repaint)
    /// are only counted.
    pub fn present(self: *Tracer, now: u64, surface: u32) ?Sample {
        if (!self.open) return null;
        self.events.add('V', sub(now, self.t0));
        const t_render = self.t_render orelse {
            self.presents_between += 1;
            return self.expire(now);
        };
        const s = self.sample(true);
        var out = s;
        out.render_to_present_ns = sub(now, t_render);
        out.total_ns = sub(now, self.t0);
        out.surface = surface;
        self.open = false;
        return out;
    }

    fn sample(self: *const Tracer, complete: bool) Sample {
        const t_write = self.t_write orelse self.t0;
        const t_out = self.t_out orelse t_write;
        const t_parsed = self.t_parsed orelse t_out;
        const t_render = self.t_render orelse t_parsed;
        return .{
            .kind = self.kind,
            .complete = complete,
            .t0_ns = self.t0,
            .input_to_write_ns = sub(t_write, self.t0),
            .write_to_output_ns = sub(t_out, t_write),
            .output_to_parsed_ns = sub(t_parsed, t_out),
            .parsed_to_render_ns = sub(t_render, t_parsed),
            .slot_wait_ns = self.slot_wait,
            .writes = self.writes,
            .write_bytes = self.write_bytes,
            .output_bytes = self.output_bytes,
            .slices = self.slices,
            .yields = self.yields,
            .presents_between = self.presents_between,
            .events = self.events,
        };
    }

    /// Drops an open sample that cannot close any more.
    fn expire(self: *Tracer, now: u64) ?Sample {
        if (!self.open) return null;
        const age = sub(now, self.t0);
        const limit = if (self.t_write == null) no_write_timeout_ns else stale_timeout_ns;
        if (age <= limit) return null;
        return self.abandon();
    }

    /// Closes the open sample as incomplete; null when it had no write.
    fn abandon(self: *Tracer) ?Sample {
        if (!self.open) return null;
        self.open = false;
        if (self.t_write == null) return null;
        self.incomplete += 1;
        return self.sample(false);
    }
};

fn sub(a: u64, b: u64) u64 {
    return if (a > b) a - b else 0;
}

/// Percentiles (nearest rank) of `values`, sorted ascending.
pub fn stats(values: []const u64) struct { n: usize, p50: u64, p95: u64, max: u64 } {
    if (values.len == 0) return .{ .n = 0, .p50 = 0, .p95 = 0, .max = 0 };
    return .{
        .n = values.len,
        .p50 = values[rank(values.len, 50)],
        .p95 = values[rank(values.len, 95)],
        .max = values[values.len - 1],
    };
}

fn rank(n: usize, pct: usize) usize {
    return (n * pct + 99) / 100 - 1;
}

// Global tracer ------------------------------------------------------------

const State = enum(u8) { unknown, off, on };

var state: std.atomic.Value(State) = .init(.unknown);
var mutex: std.Io.Mutex = .init;
var tracer: Tracer = .{};
var path_buf: [1024]u8 = undefined;
var file: ?std.Io.File = null;
var file_offset: u64 = 0;
var tag_buf: [64]u8 = undefined;
var tag_len: usize = 0;
var wheel_messages: std.atomic.Value(u64) = .init(0);
var scroll_calls: std.atomic.Value(u64) = .init(0);

/// True when `GHOSTTY_LATENCY_TRACE` names a CSV path. Read once.
pub fn enabled() bool {
    return switch (state.load(.monotonic)) {
        .on => true,
        .off => false,
        .unknown => init(),
    };
}

fn init() bool {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (state.load(.monotonic) != .unknown) return state.load(.monotonic) == .on;

    const on = open: {
        const path = windows.diagnosticEnv(global.alloc(), "GHOSTTY_LATENCY_TRACE") orelse break :open false;
        defer global.alloc().free(path);
        if (path.len == 0 or path.len > path_buf.len) break :open false;

        if (windows.diagnosticEnv(global.alloc(), "GHOSTTY_LATENCY_TAG")) |tag| {
            defer global.alloc().free(tag);
            tag_len = @min(tag.len, tag_buf.len);
            @memcpy(tag_buf[0..tag_len], tag[0..tag_len]);
        }

        const f = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |err| {
            log.warn("cannot open latency trace path={s} err={}", .{ path, err });
            break :open false;
        };
        file = f;
        file_offset = 0;
        writeAll(io, header);
        log.info("latency trace path={s}", .{path});
        break :open true;
    };
    state.store(if (on) .on else .off, .release);
    return on;
}

const header = "build,tag,kind,complete,surface,t0_ns,input_to_write_ms,write_to_output_ms," ++
    "output_to_parsed_ms,parsed_to_render_ms,slot_wait_ms,render_to_present_ms,total_ms," ++
    "writes,write_bytes,output_bytes,slices,yields,presents_between,wheel_messages,scroll_calls,events\n";

fn nowNs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toNanoseconds()));
}

fn writeAll(io: std.Io, bytes: []const u8) void {
    const f = file orelse return;
    f.writePositionalAll(io, bytes, file_offset) catch return;
    file_offset += bytes.len;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

/// Appends one CSV line. Called with the mutex held.
fn emit(io: std.Io, s: Sample) void {
    var buf: [768]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{s},{s},{s},{d},{d},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d},{d},{d},{d},{f}\n",
        .{
            @tagName(builtin.mode),
            tag_buf[0..tag_len],
            @tagName(s.kind),
            @intFromBool(s.complete),
            s.surface,
            s.t0_ns,
            ms(s.input_to_write_ns),
            ms(s.write_to_output_ns),
            ms(s.output_to_parsed_ns),
            ms(s.parsed_to_render_ns),
            ms(s.slot_wait_ns),
            ms(s.render_to_present_ns),
            ms(s.total_ns),
            s.writes,
            s.write_bytes,
            s.output_bytes,
            s.slices,
            s.yields,
            s.presents_between,
            wheel_messages.load(.monotonic),
            scroll_calls.load(.monotonic),
            s.events,
        },
    ) catch return;
    writeAll(io, line);
}

/// UI thread: an input message arrived. Opens a sample.
pub fn markInput(kind: InputKind) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (tracer.input(now, kind)) |old| emit(io, old);
}

/// IO side: bytes were written to the pty.
pub fn markWrite(bytes: usize) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.write(now, bytes);
}

/// Read loop: bytes came back from the pty.
pub fn markOutput(bytes: usize) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (tracer.output(now, bytes)) |old| emit(io, old);
}

/// Read loop: one `yieldToDemand` ran.
pub fn markYield() void {
    if (!enabled()) return;
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.yielded();
}

/// `processOutput` of one slice finished, with the renderer state mutex
/// still held: the renderer's snapshot cannot predate the mark.
pub fn markParsed(slices: u32, yields: u32) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.parsed(now, slices, yields);
}

/// Render thread: a frame begins.
pub fn markRenderStart() void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.renderStart(now);
}

/// A one-letter note in the events of the open sample (diagnostic).
pub fn markNote(tag: u8) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.note(now, tag);
}

/// Render thread: the frame-slot wait of this frame took `ns`.
pub fn markSlotWait(ns: u64) void {
    if (!enabled()) return;
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    tracer.slotWait(ns);
}

/// Render thread: `Present` returned.
pub fn markPresent(surface_id: u32) void {
    if (!enabled()) return;
    const now = nowNs();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (tracer.present(now, surface_id)) |s| emit(io, s);
}

pub fn count(counter: Counter) void {
    if (!enabled()) return;
    switch (counter) {
        .wheel_message => _ = wheel_messages.fetchAdd(1, .monotonic),
        .scroll_call => _ = scroll_calls.fetchAdd(1, .monotonic),
    }
}

// Tests ----------------------------------------------------------------------

const ms_ns = std.time.ns_per_ms;

test "windows latency: a complete key sample has ordered stages" {
    var t: Tracer = .{};
    try std.testing.expect(t.input(0, .key) == null);
    t.write(1 * ms_ns, 1);
    try std.testing.expect(t.output(4 * ms_ns, 3) == null);
    t.parsed(5 * ms_ns, 1, 1);
    t.renderStart(6 * ms_ns);
    t.slotWait(2 * ms_ns);
    const s = t.present(9 * ms_ns, 7).?;

    try std.testing.expectEqual(SampleKind.key, s.kind);
    try std.testing.expect(s.complete);
    try std.testing.expectEqual(@as(u64, 1 * ms_ns), s.input_to_write_ns);
    try std.testing.expectEqual(@as(u64, 3 * ms_ns), s.write_to_output_ns);
    try std.testing.expectEqual(@as(u64, 1 * ms_ns), s.output_to_parsed_ns);
    try std.testing.expectEqual(@as(u64, 1 * ms_ns), s.parsed_to_render_ns);
    try std.testing.expectEqual(@as(u64, 2 * ms_ns), s.slot_wait_ns);
    try std.testing.expectEqual(@as(u64, 3 * ms_ns), s.render_to_present_ns);
    try std.testing.expectEqual(@as(u64, 9 * ms_ns), s.total_ns);
    try std.testing.expectEqual(@as(u32, 7), s.surface);
    try std.testing.expectEqual(@as(u64, 3), s.output_bytes);
    try std.testing.expect(!t.open);
}

test "windows latency: present before output does not close the sample" {
    var t: Tracer = .{};
    _ = t.input(0, .key);
    t.write(1 * ms_ns, 1);
    // The keypress repaint.
    try std.testing.expect(t.present(3 * ms_ns, 0) == null);
    try std.testing.expect(t.open);
    _ = t.output(5 * ms_ns, 1);
    t.parsed(6 * ms_ns, 1, 1);
    t.renderStart(7 * ms_ns);
    const s = t.present(10 * ms_ns, 0).?;
    try std.testing.expectEqual(@as(u32, 1), s.presents_between);
    try std.testing.expectEqual(@as(u64, 10 * ms_ns), s.total_ns);
}

test "windows latency: wheel input counts writes" {
    var t: Tracer = .{};
    _ = t.input(0, .wheel);
    t.write(1 * ms_ns, 3);
    t.write(1 * ms_ns, 3);
    t.write(2 * ms_ns, 3);
    _ = t.output(4 * ms_ns, 100);
    t.parsed(5 * ms_ns, 1, 1);
    t.renderStart(5 * ms_ns);
    const s = t.present(8 * ms_ns, 0).?;
    try std.testing.expectEqual(SampleKind.wheel, s.kind);
    try std.testing.expectEqual(@as(u32, 3), s.writes);
    try std.testing.expectEqual(@as(u64, 9), s.write_bytes);
}

test "windows latency: output-only sample" {
    var t: Tracer = .{};
    try std.testing.expect(t.output(10 * ms_ns, 20) == null);
    try std.testing.expect(t.open);
    t.parsed(11 * ms_ns, 1, 1);
    t.renderStart(12 * ms_ns);
    const s = t.present(15 * ms_ns, 0).?;
    try std.testing.expectEqual(SampleKind.output, s.kind);
    try std.testing.expectEqual(@as(u64, 10 * ms_ns), s.t0_ns);
    try std.testing.expectEqual(@as(u64, 5 * ms_ns), s.total_ns);
    try std.testing.expectEqual(@as(u64, 0), s.input_to_write_ns);
}

test "windows latency: a new input closes the old one as incomplete" {
    var t: Tracer = .{};
    _ = t.input(0, .key);
    t.write(1 * ms_ns, 1);
    const old = t.input(100 * ms_ns, .key).?;
    try std.testing.expect(!old.complete);
    try std.testing.expectEqual(@as(u64, 1), t.incomplete);

    // A modifier press (no write) is dropped without a sample.
    try std.testing.expect(t.input(200 * ms_ns, .key) == null);
    try std.testing.expect(t.input(900 * ms_ns, .key) == null);
}

test "windows latency: stats percentiles" {
    var v: [100]u64 = undefined;
    for (&v, 1..) |*x, i| x.* = i;
    const s = stats(&v);
    try std.testing.expectEqual(@as(usize, 100), s.n);
    try std.testing.expectEqual(@as(u64, 50), s.p50);
    try std.testing.expectEqual(@as(u64, 95), s.p95);
    try std.testing.expectEqual(@as(u64, 100), s.max);
}

test "windows latency: disabled marks are no-ops" {
    try std.testing.expect(!enabled());
    markInput(.key);
    markWrite(1);
    markOutput(1);
    markParsed(1, 1);
    markRenderStart();
    markSlotWait(1);
    markPresent(0);
    count(.wheel_message);
    try std.testing.expect(!tracer.open);
}
