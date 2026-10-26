//! Named-pipe IPC server thread.
//!
//! `claim` creates the first pipe instance (so the instance name is held
//! from App.init on), `start` runs the IPC thread. The thread only moves
//! bytes: it reads one request frame per client, posts `WM_GHOSTTY_IPC`
//! with a `*Pending` to the UI thread, waits for `complete`, and writes
//! the response. It never calls SendMessage, and it never parses or
//! executes a request: that happens on the UI thread, which must answer
//! `expired` requests (`protocol.expired`) without acting on them, and
//! must check `Overrides.forwardable(args)` before `Overrides.parse` of
//! any forwarded args.
const Server = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const instance = @import("../instance.zig");
const messages = @import("../messages.zig");
const util = @import("../util.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const global = @import("../../../global.zig");

const log = std.log.scoped(.win32_ipc_server);

const kernel32 = win32.kernel32;
const advapi32 = win32.advapi32;
const HANDLE = win32.foundation.HANDLE;
const HWND = win32.foundation.HWND;

/// Upper bound for reading a request and for writing a response.
const io_timeout_ms = 2000;
/// How long a finished client gets to read the response and close.
const close_wait_ms = 1000;
const pipe_buffer = 64 << 10;
const thread_stack = 64 << 10;

/// One request in flight between the IPC thread and the UI thread. Two
/// references: the server's and the UI handler's (dropped by `complete`).
pub const Pending = struct {
    request: []u8,
    response: ?[]u8 = null,
    done: HANDLE,
    refs: std.atomic.Value(u8) = .init(2),
    alloc: Allocator,
    /// Set by the first `complete`, so the UI handler and `stop` cannot
    /// both answer (or both drop the UI reference).
    completed: std.atomic.Value(bool) = .init(false),
};

alloc: Allocator,
name: [:0]u16,
/// Allocated by the system (`LocalFree`).
descriptor: ?*anyopaque,
/// The listening instance until the thread takes it over.
pipe: ?HANDLE,
quit: HANDLE,
/// Overlapped-op event of the IPC thread (created by `start`).
event: ?HANDLE = null,
thread: ?std.Thread = null,
msg_hwnd: ?HWND = null,
/// This process's elevation, as used for peer checks. A copy so tests
/// can flip it on the server side only.
elevated: bool,
/// The request the thread was still waiting on when it saw `quit`.
outstanding: ?*Pending = null,
/// Test hook: behave as if `PostMessageW` failed.
test_fail_post: std.atomic.Value(bool) = .init(false),

/// Creates the first pipe instance now. `AddressInUse`: another server
/// already owns the name (same user and elevation).
pub fn claim(
    alloc: Allocator,
    name: [:0]const u16,
) error{ AddressInUse, SecurityFailed, Unexpected, OutOfMemory }!*Server {
    const elevated = instance.isElevated();
    const sid = instance.currentUserSid(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SecurityFailed,
    };
    defer alloc.free(sid);

    // Only our user may open the pipe; an elevated server additionally
    // forbids write access to anything below High integrity, so a
    // medium-integrity process cannot connect (and be mistaken for a peer).
    const sddl = try std.fmt.allocPrint(alloc, "D:P(A;;GA;;;{s}){s}", .{
        sid,
        if (elevated) "S:(ML;;NW;;;HI)" else "",
    });
    defer alloc.free(sddl);
    const sddl_w = util.utf16z(alloc, sddl) catch return error.OutOfMemory;
    defer alloc.free(sddl_w);
    var descriptor: ?*anyopaque = null;
    if (advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        advapi32.SDDL_REVISION_1,
        &descriptor,
        null,
    ) == 0) {
        log.err("security descriptor failed err={}", .{kernel32.GetLastError()});
        return error.SecurityFailed;
    }
    errdefer _ = kernel32.LocalFree(descriptor);

    const owned_name = try alloc.allocSentinel(u16, name.len, 0);
    @memcpy(owned_name, name);
    errdefer alloc.free(owned_name);
    const quit = kernel32.CreateEventW(null, 1, 0, null) orelse return error.Unexpected;
    errdefer _ = kernel32.CloseHandle(quit);

    const self = try alloc.create(Server);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .name = owned_name,
        .descriptor = descriptor,
        .pipe = null,
        .quit = quit,
        .elevated = elevated,
    };
    self.pipe = self.createInstance(true) orelse return switch (kernel32.GetLastError()) {
        kernel32.ERROR_ACCESS_DENIED => error.AddressInUse,
        else => |err| blk: {
            log.err("CreateNamedPipeW failed err={}", .{err});
            break :blk error.Unexpected;
        },
    };
    return self;
}

fn createInstance(self: *Server, first: bool) ?HANDLE {
    var sa: kernel32.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = self.descriptor };
    const first_flag: u32 = if (first) kernel32.FILE_FLAG_FIRST_PIPE_INSTANCE else 0;
    const open_mode: u32 = kernel32.PIPE_ACCESS_DUPLEX | kernel32.FILE_FLAG_OVERLAPPED | first_flag;
    const h = kernel32.CreateNamedPipeW(
        self.name.ptr,
        open_mode,
        kernel32.PIPE_TYPE_BYTE | kernel32.PIPE_READMODE_BYTE | kernel32.PIPE_WAIT |
            kernel32.PIPE_REJECT_REMOTE_CLIENTS,
        kernel32.PIPE_UNLIMITED_INSTANCES,
        pipe_buffer,
        pipe_buffer,
        0,
        &sa,
    );
    if (h == kernel32.INVALID_HANDLE_VALUE) return null;
    return h;
}

/// Starts the IPC thread. Clients that connected since `claim` wait in
/// the pipe.
pub fn start(self: *Server, msg_hwnd: HWND) !void {
    self.msg_hwnd = msg_hwnd;
    self.event = kernel32.CreateEventW(null, 1, 0, null) orelse return error.Unexpected;
    self.thread = try std.Thread.spawn(.{ .stack_size = thread_stack }, run, .{self});
}

/// Stops the thread, answers whatever is still outstanding with code 1
/// and frees the server. Call it once the UI can no longer dispatch
/// `WM_GHOSTTY_IPC` (after the message loop), since the UI handler may
/// not touch a `*Pending` after this has completed it.
pub fn stop(self: *Server) void {
    if (self.thread) |t| {
        _ = kernel32.SetEvent(self.quit);
        t.join();
    } else if (self.pipe) |p| {
        _ = kernel32.CloseHandle(p);
    }

    if (self.outstanding) |p| {
        if (protocol.encodeResponse(self.alloc, .failed, "", "shutting down", null)) |bytes| {
            complete(p, bytes);
        } else |_| {
            // Out of memory: the waiter just gets no response.
            if (!p.completed.swap(true, .acq_rel)) {
                _ = kernel32.SetEvent(p.done);
                release(p, self.alloc);
            }
        }
        release(p, self.alloc);
    }

    if (self.event) |e| _ = kernel32.CloseHandle(e);
    _ = kernel32.CloseHandle(self.quit);
    _ = kernel32.LocalFree(self.descriptor);
    self.alloc.free(self.name);
    self.alloc.destroy(self);
}

/// UI thread: hands over `response` (allocated with the server's
/// allocator), wakes the IPC thread and drops the UI reference. Only the
/// first completion counts.
pub fn complete(pending: *Pending, response: []u8) void {
    if (pending.completed.swap(true, .acq_rel)) {
        pending.alloc.free(response);
        return;
    }
    pending.response = response;
    _ = kernel32.SetEvent(pending.done);
    release(pending, pending.alloc);
}

/// Drops one reference; the last one frees.
pub fn release(pending: *Pending, alloc: Allocator) void {
    if (pending.refs.fetchSub(1, .acq_rel) != 1) return;
    _ = kernel32.CloseHandle(pending.done);
    alloc.free(pending.request);
    if (pending.response) |r| alloc.free(r);
    alloc.destroy(pending);
}

const Accept = enum { connected, retry, quit, failed };

fn run(self: *Server) void {
    const event = self.event.?;
    var cur = self.pipe.?;
    self.pipe = null;
    while (true) {
        const io: client.Io = .{ .pipe = cur, .event = event, .quit = self.quit };
        switch (self.accept(io)) {
            .connected => {},
            // The client went away before we accepted it (ERROR_NO_DATA):
            // recycle the instance and accept the next one.
            .retry => {
                _ = kernel32.DisconnectNamedPipe(cur);
                continue;
            },
            .quit, .failed => {
                _ = kernel32.CloseHandle(cur);
                return;
            },
        }

        // The next client gets its own instance right away and waits
        // there for its turn.
        const next = self.createInstance(false);
        self.serve(io);
        _ = kernel32.DisconnectNamedPipe(cur);
        _ = kernel32.CloseHandle(cur);

        cur = next orelse self.createInstance(false) orelse {
            log.err("cannot create the next pipe instance err={}, IPC stops", .{kernel32.GetLastError()});
            return;
        };
        if (kernel32.WaitForSingleObjectEx(self.quit, 0, 0) == kernel32.WAIT_OBJECT_0) {
            _ = kernel32.CloseHandle(cur);
            return;
        }
    }
}

fn accept(self: *Server, io: client.Io) Accept {
    _ = self;
    _ = kernel32.ResetEvent(io.event);
    var ov: kernel32.OVERLAPPED = .{ .hEvent = io.event };
    if (kernel32.ConnectNamedPipe(io.pipe, &ov) != 0) return .connected;
    switch (kernel32.GetLastError()) {
        kernel32.ERROR_PIPE_CONNECTED => return .connected,
        kernel32.ERROR_IO_PENDING => {
            _ = io.finish(&ov, client.no_deadline) catch |err| return switch (err) {
                error.Quit => .quit,
                error.Broken => .retry,
                error.Timeout => .failed,
            };
            return .connected;
        },
        kernel32.ERROR_NO_DATA => return .retry,
        else => |err| {
            log.err("ConnectNamedPipe failed err={}", .{err});
            return .failed;
        },
    }
}

/// One client: check the peer, read the request, round-trip it through the
/// UI thread, answer. Every failure just drops the client.
fn serve(self: *Server, io: client.Io) void {
    var pid: u32 = 0;
    if (kernel32.GetNamedPipeClientProcessId(io.pipe, &pid) == 0 or
        !instance.peerMatchesAs(pid, self.elevated))
    {
        log.warn("rejected pipe client pid={}", .{pid});
        self.reply(io, .failed, "peer rejected");
        return;
    }

    const read_deadline = kernel32.GetTickCount64() + io_timeout_ms;
    var hdr: [4]u8 = undefined;
    io.readExact(&hdr, read_deadline) catch return;
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > protocol.max_request_m2) {
        self.reply(io, .bad_request, "request too large");
        return;
    }
    const request = self.alloc.alloc(u8, len) catch {
        self.reply(io, .failed, "out of memory");
        return;
    };
    io.readExact(request, read_deadline) catch {
        self.alloc.free(request);
        return;
    };

    const done = kernel32.CreateEventW(null, 1, 0, null) orelse {
        self.alloc.free(request);
        self.reply(io, .failed, "out of resources");
        return;
    };
    const pending = self.alloc.create(Pending) catch {
        _ = kernel32.CloseHandle(done);
        self.alloc.free(request);
        self.reply(io, .failed, "out of memory");
        return;
    };
    pending.* = .{ .request = request, .done = done, .alloc = self.alloc };

    // A full queue answers at once: waiting on a UI that cannot take the
    // message would hold this client for ever.
    if (self.test_fail_post.load(.acquire) or win32.user32.PostMessageW(
        self.msg_hwnd,
        messages.WM_GHOSTTY_IPC,
        0,
        @bitCast(@intFromPtr(pending)),
    ) == 0) {
        release(pending, self.alloc);
        release(pending, self.alloc);
        self.reply(io, .failed, "busy");
        return;
    }

    // No timeout: a modal UI keeps dispatching posted messages.
    const handles = [2]HANDLE{ pending.done, self.quit };
    if (kernel32.WaitForMultipleObjects(2, &handles, 0, kernel32.INFINITE) != kernel32.WAIT_OBJECT_0) {
        self.outstanding = pending;
        return;
    }
    defer release(pending, self.alloc);

    if (pending.response) |response| {
        self.send(io, response);
    } else {
        self.reply(io, .failed, "no response");
    }
    self.waitClosed(io);
}

fn reply(self: *Server, io: client.Io, code: protocol.Code, message: []const u8) void {
    const bytes = protocol.encodeResponse(self.alloc, code, "", message, null) catch return;
    defer self.alloc.free(bytes);
    self.send(io, bytes);
    self.waitClosed(io);
}

fn send(self: *Server, io: client.Io, payload: []const u8) void {
    io.writeFrame(self.alloc, payload, kernel32.GetTickCount64() + io_timeout_ms) catch |err| {
        log.debug("response not delivered: {}", .{err});
    };
}

/// Disconnecting discards what the client has not read yet, so wait for
/// it to read the response and close its end (or for the timeout).
fn waitClosed(self: *Server, io: client.Io) void {
    _ = self;
    var scratch: [256]u8 = undefined;
    const deadline = kernel32.GetTickCount64() + close_wait_ms;
    while (true) _ = io.readSome(&scratch, deadline) catch return;
}

// -- Tests --------------------------------------------------------------------

/// A pipe name no real Ghostty can ever use.
pub fn testPipeName(alloc: Allocator) ![:0]u16 {
    const Counter = struct {
        var n: std.atomic.Value(u32) = .init(0);
    };
    var buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "\\\\.\\pipe\\ghostty-test-{d}-{d}", .{
        kernel32.GetCurrentProcessId(),
        Counter.n.fetchAdd(1, .monotonic),
    });
    return util.utf16z(alloc, name);
}

/// Plays the UI thread: a message-only window whose procedure echoes
/// requests as `{"echo":<request>}` and honours `expired`.
pub const TestUi = struct {
    alloc: Allocator,
    hwnd: HWND,
    handled: std.atomic.Value(u32) = .init(0),
    expired: std.atomic.Value(u32) = .init(0),

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyIpcTestUi");

    pub fn create(alloc: Allocator) !*TestUi {
        const hinstance = kernel32.GetModuleHandleW(null).?;
        try util.registerClass(&.{
            .lpfnWndProc = wndProc,
            .hInstance = hinstance,
            .lpszClassName = class_name,
        });
        const hwnd = win32.user32.CreateWindowExW(
            0,
            class_name,
            null,
            0,
            0,
            0,
            0,
            0,
            win32.user32.HWND_MESSAGE,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = win32.user32.DestroyWindow(hwnd);
        const self = try alloc.create(TestUi);
        self.* = .{ .alloc = alloc, .hwnd = hwnd };
        util.setUserData(hwnd, self);
        return self;
    }

    pub fn destroy(self: *TestUi) void {
        _ = win32.user32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    fn wndProc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        if (msg == messages.WM_GHOSTTY_IPC) {
            if (util.fromUserData(TestUi, hwnd)) |ui| {
                ui.handle(@ptrFromInt(@as(usize, @bitCast(lparam))));
            }
            return 0;
        }
        return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    fn handle(self: *TestUi, pending: *Pending) void {
        const response = self.respond(pending) catch alloc_fallback: {
            break :alloc_fallback self.alloc.dupe(u8, "{}") catch return;
        };
        complete(pending, response);
    }

    fn respond(self: *TestUi, pending: *Pending) ![]u8 {
        const alloc = self.alloc;
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const req = protocol.parseRequest(arena.allocator(), pending.request) catch
            return protocol.encodeResponse(alloc, .bad_request, "", "bad request", null);
        if (protocol.expired(req, kernel32.GetTickCount64())) {
            _ = self.expired.fetchAdd(1, .acq_rel);
            return protocol.encodeResponse(alloc, .failed, "", "expired", null);
        }
        const data = try std.fmt.allocPrint(alloc, "{{\"echo\":{s}}}", .{pending.request});
        defer alloc.free(data);
        const out = try protocol.encodeResponse(alloc, .ok, "", "", data);
        _ = self.handled.fetchAdd(1, .acq_rel);
        return out;
    }

    /// Dispatches the thread's messages until `counter` reaches `target`.
    pub fn pumpUntil(self: *TestUi, counter: *std.atomic.Value(u32), target: u32) !void {
        _ = self;
        const limit = kernel32.GetTickCount64() + 10_000;
        var msg: win32.user32.MSG = .{};
        while (counter.load(.acquire) < target) {
            if (kernel32.GetTickCount64() > limit) return error.PumpTimeout;
            if (win32.user32.PeekMessageW(&msg, null, 0, 0, win32.user32.PM_REMOVE) != 0) {
                _ = win32.user32.TranslateMessage(&msg);
                _ = win32.user32.DispatchMessageW(&msg);
            } else {
                std.Io.sleep(global.io(), .fromMilliseconds(1), .awake) catch {};
            }
        }
    }

    /// A client on its own thread.
    pub const Call = struct {
        alloc: Allocator,
        name: [:0]const u16,
        op: []const u8,
        timeout_ms: u32,
        done: *std.atomic.Value(u32),
        result: ?client.Error![]u8 = null,
        elapsed_ms: u64 = 0,

        pub fn run(self: *Call) void {
            const t0 = kernel32.GetTickCount64();
            defer {
                self.elapsed_ms = kernel32.GetTickCount64() - t0;
                _ = self.done.fetchAdd(1, .release);
            }
            const payload = protocol.encodeRequest(self.alloc, .{ .v = 1, .op = self.op }) catch {
                self.result = error.OutOfMemory;
                return;
            };
            defer self.alloc.free(payload);
            self.result = client.request(self.alloc, self.name, payload, self.timeout_ms);
        }

        /// Frees the response (if any) and returns its parsed form.
        pub fn expectResponse(self: *Call, arena: Allocator) !protocol.Response {
            const bytes = try self.result.?;
            defer self.alloc.free(bytes);
            // The parsed strings may point into the input.
            return protocol.parseResponse(arena, try arena.dupe(u8, bytes));
        }
    };
};

fn startServer(alloc: Allocator, name: [:0]const u16, ui: *TestUi) !*Server {
    const server = try claim(alloc, name);
    errdefer server.stop();
    try server.start(ui.hwnd);
    return server;
}

test "win32 ipc server: request roundtrip" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try startServer(alloc, name, ui);
    defer server.stop();

    var done: std.atomic.Value(u32) = .init(0);
    var call: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "ping", .timeout_ms = 5000, .done = &done };
    const thread = try std.Thread.spawn(.{}, TestUi.Call.run, .{&call});
    defer thread.join();
    try ui.pumpUntil(&done, 1);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try call.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, resp.code);
    try std.testing.expect(std.mem.indexOf(u8, resp.data_json.?, "\"op\":\"ping\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, resp.data_json.?, "{\"echo\":"));
}

test "win32 ipc server: second claim on the same name is AddressInUse" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    const first = try claim(alloc, name);
    defer first.stop();
    try std.testing.expectError(error.AddressInUse, claim(alloc, name));
}

test "win32 ipc server: client connected before start() is answered" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try claim(alloc, name);
    defer server.stop();

    var done: std.atomic.Value(u32) = .init(0);
    var call: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "early", .timeout_ms = 5000, .done = &done };
    const thread = try std.Thread.spawn(.{}, TestUi.Call.run, .{&call});
    defer thread.join();
    // The client has connected and written by now; nobody serves it yet.
    std.Io.sleep(global.io(), .fromMilliseconds(150), .awake) catch {};
    try std.testing.expectEqual(@as(u32, 0), done.load(.acquire));
    try server.start(ui.hwnd);
    try ui.pumpUntil(&done, 1);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try call.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, resp.code);
    try std.testing.expect(std.mem.indexOf(u8, resp.data_json.?, "\"op\":\"early\"") != null);
}

test "win32 ipc server: two concurrent clients are both answered in order" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try startServer(alloc, name, ui);
    defer server.stop();

    var done: std.atomic.Value(u32) = .init(0);
    var a: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "first", .timeout_ms = 5000, .done = &done };
    var b: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "second", .timeout_ms = 5000, .done = &done };
    const ta = try std.Thread.spawn(.{}, TestUi.Call.run, .{&a});
    defer ta.join();
    const tb = try std.Thread.spawn(.{}, TestUi.Call.run, .{&b});
    defer tb.join();
    try ui.pumpUntil(&done, 2);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const ra = try a.expectResponse(arena.allocator());
    const rb = try b.expectResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, ra.data_json.?, "\"op\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rb.data_json.?, "\"op\":\"second\"") != null);
    try std.testing.expectEqual(@as(u32, 2), ui.handled.load(.acquire));
}

test "win32 ipc server: post failure answers at once" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try startServer(alloc, name, ui);
    defer server.stop();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    server.test_fail_post.store(true, .release);
    var done: std.atomic.Value(u32) = .init(0);
    var failed: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "x", .timeout_ms = 5000, .done = &done };
    const t1 = try std.Thread.spawn(.{}, TestUi.Call.run, .{&failed});
    defer t1.join();
    // Not pumped: the answer must not depend on the UI thread.
    while (done.load(.acquire) < 1) std.Io.sleep(global.io(), .fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(failed.elapsed_ms < 250);
    const resp = try failed.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.failed, resp.code);
    try std.testing.expectEqual(@as(u32, 0), ui.handled.load(.acquire));

    server.test_fail_post.store(false, .release);
    var next: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "y", .timeout_ms = 5000, .done = &done };
    const t2 = try std.Thread.spawn(.{}, TestUi.Call.run, .{&next});
    defer t2.join();
    try ui.pumpUntil(&done, 2);
    const ok = try next.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, ok.code);
}

test "win32 ipc server: oversized frame is answered with bad_request and disconnected" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try startServer(alloc, name, ui);
    defer server.stop();

    const h = kernel32.CreateFileW(
        name.ptr,
        kernel32.GENERIC_READ | kernel32.GENERIC_WRITE,
        0,
        null,
        kernel32.OPEN_EXISTING,
        kernel32.FILE_FLAG_OVERLAPPED,
        null,
    );
    try std.testing.expect(h != kernel32.INVALID_HANDLE_VALUE);
    defer _ = kernel32.CloseHandle(h);
    const event = kernel32.CreateEventW(null, 1, 0, null).?;
    defer _ = kernel32.CloseHandle(event);
    const io: client.Io = .{ .pipe = h, .event = event };
    const deadline = kernel32.GetTickCount64() + 3000;

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, protocol.max_request_m2 + 1, .little);
    try io.writeAll(&hdr, deadline);

    try io.readExact(&hdr, deadline);
    const len = std.mem.readInt(u32, &hdr, .little);
    const body = try alloc.alloc(u8, len);
    defer alloc.free(body);
    try io.readExact(body, deadline);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try protocol.parseResponse(arena.allocator(), body); // body outlives resp
    try std.testing.expectEqual(protocol.Code.bad_request, resp.code);
    try std.testing.expectEqual(@as(u32, 0), ui.handled.load(.acquire));
}

test "win32 ipc: elevation mismatch is rejected" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try claim(alloc, name);
    defer server.stop();
    // The server believes it has the other elevation than this client.
    server.elevated = !instance.isElevated();
    try server.start(ui.hwnd);

    var done: std.atomic.Value(u32) = .init(0);
    var call: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "x", .timeout_ms = 5000, .done = &done };
    const thread = try std.Thread.spawn(.{}, TestUi.Call.run, .{&call});
    defer thread.join();
    try ui.pumpUntil(&done, 1);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try call.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.failed, resp.code);
    try std.testing.expectEqualStrings("peer rejected", resp.stderr);
    try std.testing.expectEqual(@as(u32, 0), ui.handled.load(.acquire));
}

test "win32 ipc server: client opens and closes before accept, next client still served" {
    const alloc = std.testing.allocator;
    const name = try testPipeName(alloc);
    defer alloc.free(name);
    var ui = try TestUi.create(alloc);
    defer ui.destroy();
    const server = try startServer(alloc, name, ui);
    defer server.stop();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    // A is posted and waits for the (unpumped) UI, so B lands on the next
    // instance, which is not being accepted yet.
    var done: std.atomic.Value(u32) = .init(0);
    var a: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "a", .timeout_ms = 5000, .done = &done };
    const ta = try std.Thread.spawn(.{}, TestUi.Call.run, .{&a});
    defer ta.join();
    std.Io.sleep(global.io(), .fromMilliseconds(150), .awake) catch {};
    const h = kernel32.CreateFileW(
        name.ptr,
        kernel32.GENERIC_READ | kernel32.GENERIC_WRITE,
        0,
        null,
        kernel32.OPEN_EXISTING,
        kernel32.FILE_FLAG_OVERLAPPED,
        null,
    );
    try std.testing.expect(h != kernel32.INVALID_HANDLE_VALUE);
    _ = kernel32.CloseHandle(h);
    try ui.pumpUntil(&done, 1);
    _ = try a.expectResponse(arena.allocator());

    var c: TestUi.Call = .{ .alloc = alloc, .name = name, .op = "c", .timeout_ms = 5000, .done = &done };
    const tc = try std.Thread.spawn(.{}, TestUi.Call.run, .{&c});
    defer tc.join();
    try ui.pumpUntil(&done, 2);
    const resp = try c.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, resp.code);
}
