//! Client transport of `tmux.exe`: one request frame to the Ghostty tmux
//! pipe and one response frame back.
//!
//! The pipe is opened with `SECURITY_IDENTIFICATION` so the server cannot
//! impersonate the caller, and the server process must be the pid that is
//! written into the pipe name before a single byte is sent. A busy pipe
//! (all instances taken) is retried with a growing backoff until the
//! deadline; only a missing pipe means "no server".
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("ipc_protocol");
const win = @import("win.zig");

pub const TransportError = @import("run.zig").TransportError;

const max_name_u16 = 300;

/// Waits between open attempts on a busy pipe: 50, 100, 200, 400, 800, 1000, 1000, ...
fn nextBackoff(ms: u32) u32 {
    return @min(ms * 2, 1000);
}

/// UTF-8 to UTF-16 in `out`; null when the name does not fit or is invalid.
fn toUtf16(out: *[max_name_u16:0]u16, name: []const u8) ?usize {
    const len = std.unicode.calcUtf16LeLen(name) catch return null;
    if (len > max_name_u16) return null;
    return std.unicode.utf8ToUtf16Le(out, name) catch null;
}

/// `deadline_ms` is an absolute `GetTickCount64` value; it bounds the whole
/// exchange. `expected_pid` (from `protocol.pidFromTmuxPipe`) must equal the
/// pipe server's pid when given. Caller owns the returned response payload.
pub fn request(
    alloc: Allocator,
    name: []const u8,
    expected_pid: ?u32,
    payload: []const u8,
    deadline_ms: u64,
) TransportError![]u8 {
    if (payload.len > protocol.max_frame) return error.ProtocolError;

    var name_w: [max_name_u16:0]u16 = undefined;
    const n = toUtf16(&name_w, name) orelse return error.NoServer;
    name_w[n] = 0;
    const name_z: [*:0]const u16 = @ptrCast(&name_w);

    const pipe = try open(name_z, deadline_ms);
    defer _ = win.CloseHandle(pipe);

    // Never write the request into a file or a device that happens to have
    // this name.
    if (win.GetFileType(pipe) != win.FILE_TYPE_PIPE) return error.NotOurServer;

    if (expected_pid) |want| {
        var pid: u32 = 0;
        if (win.GetNamedPipeServerProcessId(pipe, &pid) == 0 or pid != want) return error.NotOurServer;
    }

    const event = win.CreateEventW(null, 1, 0, null) orelse return error.BrokenPipe;
    defer _ = win.CloseHandle(event);
    const io: Io = .{ .pipe = pipe, .event = event, .deadline = deadline_ms };

    const wire = try alloc.alloc(u8, 4 + payload.len);
    defer alloc.free(wire);
    std.mem.writeInt(u32, wire[0..4], @intCast(payload.len), .little);
    @memcpy(wire[4..], payload);
    try io.writeAll(wire);

    var hdr: [4]u8 = undefined;
    try io.readExact(&hdr);
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > protocol.max_frame) return error.ProtocolError;
    const response = try alloc.alloc(u8, len);
    errdefer alloc.free(response);
    try io.readExact(response);
    return response;
}

fn open(name: [*:0]const u16, deadline: u64) TransportError!win.HANDLE {
    var backoff: u32 = 50;
    while (true) {
        const h = win.CreateFileW(
            name,
            win.GENERIC_READ | win.GENERIC_WRITE,
            0,
            null,
            win.OPEN_EXISTING,
            win.FILE_FLAG_OVERLAPPED | win.SECURITY_SQOS_PRESENT | win.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != win.INVALID_HANDLE_VALUE) return h;
        switch (win.GetLastError()) {
            win.ERROR_FILE_NOT_FOUND => return error.NoServer,
            win.ERROR_PIPE_BUSY => {
                const now = win.GetTickCount64();
                if (now >= deadline) return error.Timeout;
                const remaining: u32 = @intCast(@min(deadline - now, win.INFINITE - 1));
                _ = win.WaitNamedPipeW(name, @min(remaining, backoff));
                backoff = nextBackoff(backoff);
            },
            // Typically ERROR_ACCESS_DENIED: a pipe of that name that is not
            // ours (other user, other integrity level).
            else => return error.NotOurServer,
        }
    }
}

const Io = struct {
    pipe: win.HANDLE,
    /// Manual-reset event reused for every op.
    event: win.HANDLE,
    deadline: u64,

    fn finish(self: Io, ov: *win.OVERLAPPED) TransportError!u32 {
        const now = win.GetTickCount64();
        const remaining: u32 = if (self.deadline <= now)
            0
        else
            @intCast(@min(self.deadline - now, win.INFINITE - 1));
        var transferred: u32 = 0;
        if (win.WaitForSingleObject(self.event, remaining) != win.WAIT_OBJECT_0) {
            _ = win.CancelIoEx(self.pipe, ov);
            _ = win.GetOverlappedResult(self.pipe, ov, &transferred, 1);
            return error.Timeout;
        }
        if (win.GetOverlappedResult(self.pipe, ov, &transferred, 0) == 0) return error.BrokenPipe;
        return transferred;
    }

    fn readSome(self: Io, buf: []u8) TransportError!usize {
        _ = win.ResetEvent(self.event);
        var ov: win.OVERLAPPED = .{ .hEvent = self.event };
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (win.ReadFile(self.pipe, buf.ptr, len, null, &ov) == 0 and
            win.GetLastError() != win.ERROR_IO_PENDING) return error.BrokenPipe;
        const n = try self.finish(&ov);
        if (n == 0) return error.BrokenPipe;
        return n;
    }

    fn readExact(self: Io, buf: []u8) TransportError!void {
        var got: usize = 0;
        while (got < buf.len) got += try self.readSome(buf[got..]);
    }

    fn writeAll(self: Io, data: []const u8) TransportError!void {
        var sent: usize = 0;
        while (sent < data.len) {
            _ = win.ResetEvent(self.event);
            var ov: win.OVERLAPPED = .{ .hEvent = self.event };
            const rest = data[sent..];
            const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
            if (win.WriteFile(self.pipe, rest.ptr, len, null, &ov) == 0 and
                win.GetLastError() != win.ERROR_IO_PENDING) return error.BrokenPipe;
            const n = try self.finish(&ov);
            if (n == 0) return error.BrokenPipe;
            sent += n;
        }
    }
};

// ---- tests -----------------------------------------------------------

/// A one-instance pipe server on its own thread. `hold_ms` > 0 keeps the
/// instance connected to a blocker client first, so a real client sees
/// ERROR_PIPE_BUSY.
const TestServer = struct {
    name_w: [max_name_u16:0]u16 = undefined,
    hold_ms: u32 = 0,
    /// false: leave after the hold without serving a request.
    serve: bool = true,
    ready: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *TestServer, name: []const u8) !void {
        const n = toUtf16(&self.name_w, name) orelse return error.NameTooLong;
        self.name_w[n] = 0;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        while (!self.ready.load(.acquire)) win.Sleep(1);
    }

    fn join(self: *TestServer) void {
        if (self.thread) |t| t.join();
    }

    fn run(self: *TestServer) void {
        const name: [*:0]const u16 = @ptrCast(&self.name_w);
        const pipe = win.CreateNamedPipeW(
            name,
            win.PIPE_ACCESS_DUPLEX,
            win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
            1,
            4096,
            4096,
            0,
            null,
        );
        if (pipe == win.INVALID_HANDLE_VALUE) {
            self.ready.store(true, .release);
            return;
        }
        defer _ = win.CloseHandle(pipe);
        self.ready.store(true, .release);

        _ = win.ConnectNamedPipe(pipe, null);
        if (self.hold_ms > 0) {
            win.Sleep(self.hold_ms);
            _ = win.DisconnectNamedPipe(pipe);
            if (!self.serve) return;
            _ = win.ConnectNamedPipe(pipe, null);
        }

        var hdr: [4]u8 = undefined;
        if (!readAllSync(pipe, &hdr)) return;
        const len = std.mem.readInt(u32, &hdr, .little);
        var body: [256]u8 = undefined;
        if (len > body.len or !readAllSync(pipe, body[0..len])) return;
        const reply = "{\"v\":1,\"code\":0,\"stdout\":\"ok\",\"stderr\":\"\"}";
        var out: [4 + reply.len]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], reply.len, .little);
        @memcpy(out[4..], reply);
        var w: u32 = 0;
        _ = win.WriteFile(pipe, &out, out.len, &w, null);
        self.served.store(true, .release);
        // Let the client read before the instance goes away.
        var tail: [1]u8 = undefined;
        _ = readAllSync(pipe, &tail);
    }

    fn readAllSync(pipe: win.HANDLE, buf: []u8) bool {
        var got: usize = 0;
        while (got < buf.len) {
            var n: u32 = 0;
            if (win.ReadFile(pipe, buf[got..].ptr, @intCast(buf.len - got), &n, null) == 0 or n == 0) return false;
            got += n;
        }
        return true;
    }
};

fn testName(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\ghostty-tmux-test-{d}-{d}-{s}", .{
        win.GetCurrentProcessId(),
        win.GetTickCount64(),
        tag,
    });
}

test "tmux shim pipe: no server" {
    var nb: [200]u8 = undefined;
    const name = try testName(&nb, "none");
    const t0 = win.GetTickCount64();
    try std.testing.expectError(
        error.NoServer,
        request(std.testing.allocator, name, null, "{}", t0 + 2000),
    );
    try std.testing.expect(win.GetTickCount64() - t0 < 200);
}

test "tmux shim pipe: a name that does not fit is NoServer" {
    const zeros: [400]u8 = @splat('0');
    const long = "\\\\.\\pipe\\ghostty-tmux-1-" ++ zeros;
    try std.testing.expectError(
        error.NoServer,
        request(std.testing.allocator, long, null, "{}", win.GetTickCount64() + 1000),
    );
    // Invalid UTF-8 as well.
    try std.testing.expectError(
        error.NoServer,
        request(std.testing.allocator, "\xff\xfe", null, "{}", win.GetTickCount64() + 1000),
    );
}

test "tmux shim pipe: a regular file is NotOurServer and stays untouched" {
    var tmp: [260:0]u16 = undefined;
    const tn = win.GetTempPathW(tmp.len, &tmp);
    try std.testing.expect(tn > 0 and tn < 200);
    const leaf = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-tmux-shim-test-file.txt");
    @memcpy(tmp[tn..][0..leaf.len], leaf);
    tmp[tn + leaf.len] = 0;
    const path_w: [*:0]const u16 = @ptrCast(&tmp);
    const h = win.CreateFileW(path_w, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(h != win.INVALID_HANDLE_VALUE);
    _ = win.CloseHandle(h);
    defer _ = win.DeleteFileW(path_w);

    var path8: [600]u8 = undefined;
    const n8 = try std.unicode.utf16LeToUtf8(&path8, tmp[0 .. tn + leaf.len]);
    try std.testing.expectError(
        error.NotOurServer,
        request(std.testing.allocator, path8[0..n8], null, "SECRET", win.GetTickCount64() + 1000),
    );

    const h2 = win.CreateFileW(path_w, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(h2 != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(h2);
    var buf: [16]u8 = undefined;
    var got: u32 = 0;
    _ = win.ReadFile(h2, &buf, buf.len, &got, null);
    try std.testing.expectEqual(@as(u32, 0), got);
}

test "tmux shim pipe: roundtrip with matching pid" {
    const alloc = std.testing.allocator;
    var nb: [200]u8 = undefined;
    const name = try testName(&nb, "ok");
    var server: TestServer = .{};
    try server.start(name);
    defer server.join();

    const reply = try request(alloc, name, win.GetCurrentProcessId(), "{\"v\":1}", win.GetTickCount64() + 5000);
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"stdout\":\"ok\"") != null);
}

test "tmux shim pipe: server pid mismatch is NotOurServer" {
    const alloc = std.testing.allocator;
    var nb: [200]u8 = undefined;
    const name = try testName(&nb, "pid");
    var server: TestServer = .{};
    try server.start(name);
    defer server.join();

    try std.testing.expectError(
        error.NotOurServer,
        request(alloc, name, win.GetCurrentProcessId() + 1, "{}", win.GetTickCount64() + 5000),
    );
    try std.testing.expect(!server.served.load(.acquire));
}

test "tmux shim pipe: busy retries until the deadline" {
    const alloc = std.testing.allocator;
    var nb: [200]u8 = undefined;
    const name = try testName(&nb, "busy");
    var server: TestServer = .{ .hold_ms = 1500 };
    try server.start(name);
    defer server.join();

    var name_w: [max_name_u16:0]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&name_w, name);
    name_w[n] = 0;
    // The blocker takes the only instance.
    const blocker = win.CreateFileW(@ptrCast(&name_w), win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
    try std.testing.expect(blocker != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(blocker);

    const t0 = win.GetTickCount64();
    const reply = try request(alloc, name, null, "{\"v\":1}", t0 + 6000);
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"stdout\":\"ok\"") != null);
    try std.testing.expect(win.GetTickCount64() - t0 >= 1000);
}

test "tmux shim pipe: busy past the deadline is Timeout" {
    const alloc = std.testing.allocator;
    var nb: [200]u8 = undefined;
    const name = try testName(&nb, "timeout");
    var server: TestServer = .{ .hold_ms = 1200, .serve = false };
    try server.start(name);
    defer server.join();

    var name_w: [max_name_u16:0]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&name_w, name);
    name_w[n] = 0;
    const blocker = win.CreateFileW(@ptrCast(&name_w), win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
    try std.testing.expect(blocker != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(blocker);

    const t0 = win.GetTickCount64();
    try std.testing.expectError(error.Timeout, request(alloc, name, null, "{}", t0 + 300));
    try std.testing.expect(win.GetTickCount64() - t0 < 1000);
}
