//! Named-pipe IPC client used to forward a launch to a running instance.
//!
//! The client refuses to talk to a server that is not "us" (same user,
//! same elevation) before it writes a single byte, opens the pipe so the
//! server cannot impersonate the caller, and stamps every request with a
//! deadline so a server that picks it up after the client gave up refuses
//! to act on it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const instance = @import("../instance.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const global = @import("../../../global.zig");

const log = std.log.scoped(.win32_ipc_client);

const kernel32 = win32.kernel32;
const HANDLE = win32.foundation.HANDLE;

pub const Error = error{ NoServer, NotOurServer, Timeout, BrokenPipe, ProtocolError, OutOfMemory };

/// The request deadline is this much earlier than the client's own
/// timeout, so the server never acts on a request the client has already
/// given up on.
const deadline_margin_ms = 250;

/// Deadline value of a wait that never times out.
pub const no_deadline = std.math.maxInt(u64);

pub const IoError = error{ Timeout, Quit, Broken };

/// Synchronous-looking I/O over one overlapped pipe handle, with an
/// absolute `GetTickCount64` deadline and an optional quit event (the
/// server thread). Not thread safe: one op at a time.
pub const Io = struct {
    pipe: HANDLE,
    /// Manual-reset event owned by the caller, reused for every op.
    event: HANDLE,
    quit: ?HANDLE = null,

    /// Waits for the overlapped op started with `ov`, cancelling it on
    /// timeout or quit. Returns the transferred byte count.
    pub fn finish(self: Io, ov: *kernel32.OVERLAPPED, deadline: u64) IoError!u32 {
        var handles = [2]HANDLE{ self.event, self.quit orelse self.event };
        const count: u32 = if (self.quit != null) 2 else 1;
        const now = kernel32.GetTickCount64();
        const remaining: u32 = if (deadline == no_deadline)
            kernel32.INFINITE
        else if (deadline <= now)
            0
        else
            @intCast(@min(deadline - now, kernel32.INFINITE - 1));
        const wait = kernel32.WaitForMultipleObjects(count, &handles, 0, remaining);
        var transferred: u32 = 0;
        if (wait != kernel32.WAIT_OBJECT_0) {
            _ = kernel32.CancelIoEx(self.pipe, ov);
            _ = kernel32.GetOverlappedResult(self.pipe, ov, &transferred, 1);
            return if (wait == kernel32.WAIT_OBJECT_0 + 1) error.Quit else error.Timeout;
        }
        if (kernel32.GetOverlappedResult(self.pipe, ov, &transferred, 0) == 0) return error.Broken;
        return transferred;
    }

    fn begin(self: Io) kernel32.OVERLAPPED {
        _ = kernel32.ResetEvent(self.event);
        return .{ .hEvent = self.event };
    }

    /// At least one byte, or an error; end of stream is `Broken`.
    pub fn readSome(self: Io, buf: []u8, deadline: u64) IoError!usize {
        var ov = self.begin();
        var n: u32 = 0;
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (kernel32.ReadFile(self.pipe, buf.ptr, len, &n, &ov) == 0) {
            if (kernel32.GetLastError() != kernel32.ERROR_IO_PENDING) return error.Broken;
            n = try self.finish(&ov, deadline);
        }
        if (n == 0) return error.Broken;
        return n;
    }

    pub fn readExact(self: Io, buf: []u8, deadline: u64) IoError!void {
        var got: usize = 0;
        while (got < buf.len) got += try self.readSome(buf[got..], deadline);
    }

    pub fn writeAll(self: Io, data: []const u8, deadline: u64) IoError!void {
        var sent: usize = 0;
        while (sent < data.len) {
            var ov = self.begin();
            var n: u32 = 0;
            const rest = data[sent..];
            const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
            if (kernel32.WriteFile(self.pipe, rest.ptr, len, &n, &ov) == 0) {
                if (kernel32.GetLastError() != kernel32.ERROR_IO_PENDING) return error.Broken;
                n = try self.finish(&ov, deadline);
            }
            if (n == 0) return error.Broken;
            sent += n;
        }
    }

    /// One frame (u32 LE length + payload) in a single write.
    pub fn writeFrame(self: Io, alloc: Allocator, payload: []const u8, deadline: u64) (IoError || error{OutOfMemory})!void {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        protocol.writeFrame(&aw.writer, payload) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.FrameTooLarge => return error.Broken,
        };
        try self.writeAll(aw.written(), deadline);
    }
};

/// Sends `payload` (a JSON `protocol.Request`) to the server behind
/// `name` and returns the response frame. Caller owns the result.
pub fn request(alloc: Allocator, name: [:0]const u16, payload: []const u8, timeout_ms: u32) Error![]u8 {
    const start = kernel32.GetTickCount64();
    const deadline = start + timeout_ms;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var req = protocol.parseRequest(arena.allocator(), payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRequest => return error.ProtocolError,
    };
    const margin: u64 = if (timeout_ms > deadline_margin_ms) timeout_ms - deadline_margin_ms else timeout_ms / 2;
    req.deadline_ms = start + @max(margin, 1);
    const stamped = try protocol.encodeRequest(alloc, req);
    defer alloc.free(stamped);

    const pipe = try open(name, deadline);
    defer _ = kernel32.CloseHandle(pipe);

    var pid: u32 = 0;
    if (kernel32.GetNamedPipeServerProcessId(pipe, &pid) == 0 or !instance.peerMatches(pid)) {
        log.warn("pipe server pid={} is not this user at this elevation", .{pid});
        return error.NotOurServer;
    }
    _ = win32.user32.AllowSetForegroundWindow(pid);

    const event = kernel32.CreateEventW(null, 1, 0, null) orelse return error.BrokenPipe;
    defer _ = kernel32.CloseHandle(event);
    const io: Io = .{ .pipe = pipe, .event = event };

    io.writeFrame(alloc, stamped, deadline) catch |err| return mapIo(err);

    var hdr: [4]u8 = undefined;
    io.readExact(&hdr, deadline) catch |err| return mapIo(err);
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > protocol.max_frame) return error.ProtocolError;
    const response = try alloc.alloc(u8, len);
    errdefer alloc.free(response);
    io.readExact(response, deadline) catch |err| return mapIo(err);
    return response;
}

fn mapIo(err: (IoError || error{OutOfMemory})) Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.OutOfMemory,
        error.Quit, error.Broken => error.BrokenPipe,
    };
}

/// Opens the pipe, waiting for a free instance until `deadline`.
fn open(name: [:0]const u16, deadline: u64) Error!HANDLE {
    while (true) {
        const h = kernel32.CreateFileW(
            name.ptr,
            kernel32.GENERIC_READ | kernel32.GENERIC_WRITE,
            0,
            null,
            kernel32.OPEN_EXISTING,
            kernel32.FILE_FLAG_OVERLAPPED | kernel32.SECURITY_SQOS_PRESENT | kernel32.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != kernel32.INVALID_HANDLE_VALUE) return h;
        switch (kernel32.GetLastError()) {
            kernel32.ERROR_FILE_NOT_FOUND => return error.NoServer,
            kernel32.ERROR_PIPE_BUSY => {
                const now = kernel32.GetTickCount64();
                if (now >= deadline) return error.Timeout;
                const remaining: u32 = @intCast(@min(deadline - now, kernel32.INFINITE - 1));
                if (kernel32.WaitNamedPipeW(name.ptr, remaining) == 0 and
                    kernel32.GetLastError() == kernel32.ERROR_SEM_TIMEOUT)
                    return error.Timeout;
            },
            // Typically ERROR_ACCESS_DENIED: a pipe of that name that is
            // not ours (other user, other integrity level).
            else => |err| {
                log.warn("cannot open pipe err={}", .{err});
                return error.NotOurServer;
            },
        }
    }
}

test "win32 ipc client: no server" {
    const alloc = std.testing.allocator;
    const name = try Server.testPipeName(alloc);
    defer alloc.free(name);
    const payload = try protocol.encodeRequest(alloc, .{ .v = 1, .op = "x" });
    defer alloc.free(payload);

    const t0 = kernel32.GetTickCount64();
    try std.testing.expectError(error.NoServer, request(alloc, name, payload, 1000));
    try std.testing.expect(kernel32.GetTickCount64() - t0 < 50);
}

test "win32 ipc client: busy server times out and the late request is not executed" {
    const alloc = std.testing.allocator;
    const name = try Server.testPipeName(alloc);
    defer alloc.free(name);
    var ui = try Server.TestUi.create(alloc);
    defer ui.destroy();
    const server = try Server.claim(alloc, name);
    try server.start(ui.hwnd);
    defer server.stop();

    var done: std.atomic.Value(u32) = .init(0);
    var call: Server.TestUi.Call = .{ .alloc = alloc, .name = name, .op = "late", .timeout_ms = 300, .done = &done };
    const thread = try std.Thread.spawn(.{}, Server.TestUi.Call.run, .{&call});
    // The "UI" is blocked for longer than the client waits.
    std.Io.sleep(global.io(), .fromMilliseconds(600), .awake) catch {};
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), done.load(.acquire));
    try std.testing.expectError(error.Timeout, call.result.?);

    try ui.pumpUntil(&ui.expired, 1);
    try std.testing.expectEqual(@as(u32, 0), ui.handled.load(.acquire));
}
