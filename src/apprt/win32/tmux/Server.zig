//! tmux pipe server glue (owner: M4 task 8).
//!
//! A second instance of the M2 `ipc/Server.zig` serves `\\.\pipe\ghostty-tmux-<pid>-<nonce>`.
//! It posts `WM_GHOSTTY_IPC` with wparam 1; the UI thread parses the request
//! here and runs it through `Registry.run`. The pipe is current-user only
//! with `PIPE_REJECT_REMOTE_CLIENTS` (both come from `ipc.Server.claim`), and
//! only `op: "tmux"` is answered: the per-user M2 pipe never answers it and
//! this pipe never answers an M2 op.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Registry = @import("Registry.zig");
const labels = @import("labels.zig");
const global = @import("../../../global.zig");
const util = @import("../util.zig");
const protocol = @import("../ipc/protocol.zig");
const instance = @import("../instance.zig");
const messages = @import("../messages.zig");
const Config = @import("../../../config.zig").Config;
const ipc = struct {
    const Server = @import("../ipc/Server.zig");
};

const log = std.log.scoped(.win32_tmux_server);

/// `WM_GHOSTTY_IPC` wparam of this pipe.
pub const post_tag: usize = 1;
/// Low byte of the `WM_GHOSTTY_IPC` wparam of the opt-in external (user)
/// pipe; the claim's generation sits above it (`userTag`).
pub const post_tag_user: usize = 2;

/// The wparam of the user pipe's `n`th claim. A message posted by an earlier
/// claim can then never be mistaken for one of the live server, whose
/// `Pending`s are different objects.
pub fn userTag(generation: usize) usize {
    return post_tag_user | (generation << 8);
}

/// A silent client must not hold the queue: 500 ms to send its request and
/// 200 ms to read the answer.
const io_timeout_ms = 500;
const close_wait_ms = 200;

/// `App.tmux_server`.
pub const State = struct {
    server: ?*ipc.Server = null,
    /// UTF-8 pipe name; null when the claim failed.
    pipe: ?[]u8 = null,
    /// Directory of `tmux.exe` (the directory of this exe).
    exe_dir: ?[]u8 = null,
    /// `start` ran (the app is the primary instance).
    started: bool = false,
    /// The external pipe (`windows-tmux-external`, R-M5-14); null while the
    /// key is false or the claim failed.
    user_server: ?*ipc.Server = null,
    user_pipe: ?[]u8 = null,
    /// Counts the claims of the user pipe (`userTag`).
    user_generation: usize = 0,
};

/// Where a `WM_GHOSTTY_IPC` goes.
pub const Route = enum { main, tmux, tmux_user, drop };

/// Routing on wparam first. A tmux request is answered even when the main
/// pipe is not ours (standalone process); a request of a stopped server is
/// dropped, its `Pending` belongs to the server again. `user_tag` is the
/// `post_tag` of the live user-pipe server, if any; a message of another
/// generation is dropped.
pub fn routeIpc(wparam: usize, main_server: ?*ipc.Server, tmux_server: ?*ipc.Server, user_tag: ?usize) Route {
    if (wparam == post_tag) return if (tmux_server == null) .drop else .tmux;
    if (wparam & 0xFF == post_tag_user) return if (user_tag != null and user_tag.? == wparam) .tmux_user else .drop;
    if (wparam == 0) return if (main_server == null) .drop else .main;
    return .drop;
}

/// Claims and starts the tmux pipe. Called right after the main pipe was
/// claimed and this launch was not forwarded, before the first window exists.
pub fn start(app: *App) void {
    const alloc = app.core_app.alloc;
    const st = &app.tmux_server;
    st.started = true;
    // The external pipe does not depend on the per-process one either.
    defer syncExternal(app, &app.config);

    // The exe dir does not depend on the claim: a failed claim still puts
    // the shim dir on PATH (the shim then answers "no server running").
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(global.io(), &dir_buf)) |n| {
        st.exe_dir = alloc.dupe(u8, dir_buf[0..n]) catch null;
    } else |err| log.warn("unable to resolve the exe directory err={}", .{err});

    var nonce_bytes: [8]u8 = undefined;
    global.io().randomSecure(&nonce_bytes) catch |err| {
        log.warn("no random source for the tmux pipe name err={}", .{err});
        return;
    };
    var name_buf: [128]u8 = undefined;
    const name = protocol.tmuxPipeName(
        &name_buf,
        win32.kernel32.GetCurrentProcessId(),
        std.mem.readInt(u64, &nonce_bytes, .little),
    ) catch return;
    const name_w = util.utf16z(alloc, name) catch return;
    defer alloc.free(name_w);

    const server = ipc.Server.claim(alloc, name_w) catch |err| {
        log.warn("unable to claim the tmux pipe err={}", .{err});
        return;
    };
    server.post_tag = post_tag;
    server.max_request = protocol.max_request_tmux;
    server.io_timeout_ms = io_timeout_ms;
    server.close_wait_ms = close_wait_ms;
    server.start(app.msg_hwnd) catch |err| {
        log.warn("unable to start the tmux server err={}", .{err});
        server.stop();
        return;
    };
    st.server = server;
    st.pipe = alloc.dupe(u8, name) catch null;
}

/// `windows-tmux-external` changed (a reload): claims or releases the user
/// pipe. Only the primary instance (after `start`) ever claims it.
pub fn configChanged(app: *App, config: *const Config) void {
    syncExternal(app, config);
}

fn syncExternal(app: *App, config: *const Config) void {
    const st = &app.tmux_server;
    if (!st.started) return;
    if (config.@"windows-tmux-external") {
        // Only the primary instance (the owner of the main pipe) serves it: a
        // standalone process would take the name from the one that should.
        if (st.user_server == null and app.serving()) claimUser(app);
    } else {
        stopUser(app);
    }
}

fn claimUser(app: *App) void {
    const alloc = app.core_app.alloc;
    const st = &app.tmux_server;

    const sid = instance.currentUserSid(alloc) catch |err| {
        log.warn("no user SID for the external tmux pipe err={}", .{err});
        return;
    };
    defer alloc.free(sid);
    var session: u32 = 0;
    if (win32.kernel32.ProcessIdToSessionId(win32.kernel32.GetCurrentProcessId(), &session) == 0) {
        // tmux.exe could not name the pipe either: nobody would look it up.
        log.warn("ProcessIdToSessionId failed err={}, not opening the external tmux pipe", .{win32.kernel32.GetLastError()});
        return;
    }
    var name_buf: [512]u8 = undefined;
    const name = protocol.tmuxUserPipeName(&name_buf, sid, session, app.config.class orelse instance.defaultClass(), instance.isElevated()) catch return;
    const name_w = util.utf16z(alloc, name) catch return;
    defer alloc.free(name_w);

    // `claim` is the M2 claim: first instance only, current-user ACL (plus
    // the integrity label when elevated), no remote clients; and every
    // client is checked (same user, elevation and integrity) before a byte
    // of its request is read.
    const server = ipc.Server.claim(alloc, name_w) catch |err| {
        log.warn("unable to claim the external tmux pipe err={}", .{err});
        return;
    };
    st.user_generation += 1;
    server.post_tag = userTag(st.user_generation);
    server.max_request = protocol.max_request_tmux;
    server.io_timeout_ms = io_timeout_ms;
    server.close_wait_ms = close_wait_ms;
    server.start(app.msg_hwnd) catch |err| {
        log.warn("unable to start the external tmux server err={}", .{err});
        server.stop();
        return;
    };
    st.user_server = server;
    st.user_pipe = alloc.dupe(u8, name) catch null;
    log.info("external tmux pipe open", .{});
}

/// Removes the user pipe's posted `WM_GHOSTTY_IPC` messages from the queue
/// before its server stops: `Server.stop` completes (and frees) what the
/// server still waits on, so a message that outlived it must never reach a
/// handler. Messages of the other pipes are posted again. The generation in
/// the wparam is the second line of defence (`routeIpc`).
fn drainUserMessages(app: *App) void {
    var keep: [8]win32.user32.MSG = undefined;
    var kept: usize = 0;
    var msg: win32.user32.MSG = undefined;
    const m = messages.WM_GHOSTTY_IPC;
    while (kept < keep.len and win32.user32.PeekMessageW(&msg, app.msg_hwnd, m, m, win32.user32.PM_REMOVE) != 0) {
        if (msg.wParam & 0xFF == post_tag_user) continue;
        keep[kept] = msg;
        kept += 1;
    }
    for (keep[0..kept]) |k| _ = win32.user32.PostMessageW(app.msg_hwnd, k.message, k.wParam, k.lParam);
}

fn stopUser(app: *App) void {
    const alloc = app.core_app.alloc;
    const st = &app.tmux_server;
    if (st.user_server) |server| {
        st.user_server = null;
        drainUserMessages(app);
        server.stop();
        log.info("external tmux pipe closed", .{});
    }
    if (st.user_pipe) |p| alloc.free(p);
    st.user_pipe = null;
}

/// After the message loop, like `App.stopServer`.
pub fn stop(app: *App) void {
    const alloc = app.core_app.alloc;
    const st = &app.tmux_server;
    stopUser(app);
    st.started = false;
    if (st.server) |server| {
        st.server = null;
        server.stop();
    }
    if (st.pipe) |p| alloc.free(p);
    st.pipe = null;
    if (st.exe_dir) |d| alloc.free(d);
    st.exe_dir = null;
}

/// UI thread: one request from the tmux pipe (`external`: from the user pipe).
pub fn handle(app: *App, pending: *ipc.Server.Pending, external: bool) void {
    const Runner = struct {
        app: *App,
        external: bool,
        pub fn run(self: @This(), arena: Allocator, req: protocol.Request) Registry.Reply {
            if (self.external) return Registry.runExternal(req, arena) catch
                .{ .code = .failed, .stdout = "", .stderr = "ghostty: out of memory\n" };
            return Registry.run(self.app, req, arena);
        }
    };
    const response = respond(
        pending.alloc,
        pending.request,
        win32.kernel32.GetTickCount64(),
        Runner{ .app = app, .external = external },
        external,
    ) catch {
        // Out of memory: the empty answer is the "no response" fallback.
        ipc.Server.complete(pending, pending.alloc.dupe(u8, "") catch return);
        return;
    };
    ipc.Server.complete(pending, response);
}

/// Parses and answers one request; `runner.run(arena, req) Registry.Reply`
/// does the work for a well-formed `tmux` request. Caller owns the result.
/// `external`: the request came over the user pipe, which serves only
/// requests with a valid namespace; the per-process pipe refuses one.
pub fn respond(alloc: Allocator, request: []const u8, now_ms: u64, runner: anytype, external: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const req = protocol.parseRequest(a, request) catch |err| return switch (err) {
        error.BadRequest => reply(alloc, .bad_request, "bad request"),
        error.OutOfMemory => reply(alloc, .failed, "out of memory"),
    };
    if (req.v != protocol.version) return reply(alloc, .version_mismatch, "protocol version mismatch\n");
    if (protocol.expired(req, now_ms)) return reply(alloc, .failed, "expired");
    if (!std.mem.eql(u8, req.op, "tmux")) return reply(alloc, .bad_request, "unknown op");
    if (external) {
        const ns = req.namespace orelse return reply(alloc, .bad_request, "namespace required");
        if (!protocol.validNamespace(ns)) return reply(alloc, .bad_request, "bad namespace");
    } else if (req.namespace != null) {
        return reply(alloc, .bad_request, "namespace not accepted");
    }
    // A hostile client does not run tmux.exe, so its caps are checked here.
    if (req.stdin) |s| {
        if (s.len > protocol.max_stdin_tmux) return reply(alloc, .failed, "ghostty: request too large\n");
    }

    const r: Registry.Reply = runner.run(a, req);
    return protocol.encodeResponse(alloc, r.code, r.stdout, r.stderr, null);
}

fn reply(alloc: Allocator, code: protocol.Code, stderr: []const u8) ![]u8 {
    return protocol.encodeResponse(alloc, code, "", stderr, null);
}

/// The `tmux` object of the IPC `state` op.
pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.objectField("tmux");
    try jw.beginObject();
    try jw.objectField("pipe");
    if (app.tmux_server.pipe) |p| try jw.write(p) else try jw.write(null);
    try jw.objectField("user_pipe");
    if (app.tmux_server.user_pipe) |p| try jw.write(p) else try jw.write(null);
    try jw.objectField("panes");
    try jw.beginArray();
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const s = entry.view;
                try jw.beginObject();
                try jw.objectField("pane");
                try jw.print("\"%{d}\"", .{s.pane_id});
                try jw.objectField("surface");
                try jw.write(s.id);
                try jw.objectField("tab");
                try jw.write(tab.id);
                try jw.objectField("window");
                try jw.write(window.id);
                try jw.objectField("env_tmux_pane");
                if (s.env_tmux_pane) |n| try jw.print("\"%{d}\"", .{n}) else try jw.write(null);
                try jw.endObject();
            }
        }
    }
    try jw.endArray();
    try jw.objectField("labels");
    try labels.testState(app, jw);
    try jw.endObject();
}

// ---- tests -----------------------------------------------------------

const TestRunner = struct {
    calls: *u32,
    pub fn run(self: @This(), arena: Allocator, req: protocol.Request) Registry.Reply {
        _ = arena;
        _ = req;
        self.calls.* += 1;
        return .{ .code = .ok, .stdout = "%5\n", .stderr = "" };
    }
};

fn expectCode(bytes: []const u8, code: protocol.Code) !protocol.Response {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const resp = try protocol.parseResponse(arena.allocator(), bytes);
    try std.testing.expectEqual(code, resp.code);
    return .{
        .code = resp.code,
        .stdout = try std.testing.allocator.dupe(u8, resp.stdout),
        .stderr = try std.testing.allocator.dupe(u8, resp.stderr),
        .data_json = null,
    };
}

fn respondTo(alloc: Allocator, json: []const u8, calls: *u32) ![]u8 {
    return respond(alloc, json, 1000, TestRunner{ .calls = calls }, false);
}

test "win32 tmux: per-process pipe refuses a namespace" {
    const alloc = std.testing.allocator;
    var calls: u32 = 0;

    const with_ns = try respondTo(alloc, "{\"v\":1,\"op\":\"tmux\",\"args\":[\"list-panes\"],\"namespace\":\"work\"}", &calls);
    defer alloc.free(with_ns);
    const r = try expectCode(with_ns, .bad_request);
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    try std.testing.expectEqual(@as(u32, 0), calls);

    // The user pipe is the other way round: it needs a valid namespace.
    for ([_]struct { []const u8, protocol.Code, u32 }{
        .{ "{\"v\":1,\"op\":\"tmux\",\"args\":[\"has-session\"],\"namespace\":\"work\"}", .ok, 1 },
        .{ "{\"v\":1,\"op\":\"tmux\",\"args\":[\"has-session\"]}", .bad_request, 1 },
        .{ "{\"v\":1,\"op\":\"tmux\",\"args\":[\"has-session\"],\"namespace\":\"\"}", .bad_request, 1 },
        .{ "{\"v\":1,\"op\":\"tmux\",\"args\":[\"has-session\"],\"namespace\":\"a\\nb\"}", .bad_request, 1 },
    }) |case| {
        const bytes = try respond(alloc, case[0], 1000, TestRunner{ .calls = &calls }, true);
        defer alloc.free(bytes);
        const rr = try expectCode(bytes, case[1]);
        alloc.free(rr.stdout);
        alloc.free(rr.stderr);
    }
    try std.testing.expectEqual(@as(u32, 1), calls);
    const long: [protocol.max_namespace_len + 1]u8 = @splat('x');
    try std.testing.expect(!protocol.validNamespace(&long));
    try std.testing.expect(protocol.validNamespace(long[0..protocol.max_namespace_len]));
}

test "win32 tmux server: respond maps requests" {
    const alloc = std.testing.allocator;
    var calls: u32 = 0;

    const ok = try respondTo(alloc, "{\"v\":1,\"op\":\"tmux\",\"args\":[\"list-panes\"]}", &calls);
    defer alloc.free(ok);
    const r = try expectCode(ok, .ok);
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqualStrings("%5\n", r.stdout);
    try std.testing.expectEqual(@as(u32, 1), calls);

    for ([_]struct { []const u8, protocol.Code }{
        .{ "{\"v\":1,\"op\":\"new-window\"}", .bad_request },
        .{ "{\"v\":1,\"op\":\"state\"}", .bad_request },
        .{ "not json", .bad_request },
        .{ "{\"v\":2,\"op\":\"tmux\"}", .version_mismatch },
        .{ "{\"v\":1,\"op\":\"tmux\",\"deadline_ms\":999}", .failed },
    }) |case| {
        const bytes = try respondTo(alloc, case[0], &calls);
        defer alloc.free(bytes);
        const rr = try expectCode(bytes, case[1]);
        alloc.free(rr.stdout);
        alloc.free(rr.stderr);
    }
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "win32 tmux server: stdin cap" {
    const alloc = std.testing.allocator;
    var calls: u32 = 0;
    const big = try alloc.alloc(u8, protocol.max_stdin_tmux + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    const json = try protocol.encodeRequest(alloc, .{ .v = 1, .op = "tmux", .args = &.{ "load-buffer", "-" }, .stdin = big });
    defer alloc.free(json);
    const bytes = try respondTo(alloc, json, &calls);
    defer alloc.free(bytes);
    const r = try expectCode(bytes, .failed);
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqualStrings("ghostty: request too large\n", r.stderr);
    try std.testing.expectEqual(@as(u32, 0), calls);

    const ok_json = try protocol.encodeRequest(alloc, .{ .v = 1, .op = "tmux", .args = &.{ "load-buffer", "-" }, .stdin = big[0..protocol.max_stdin_tmux] });
    defer alloc.free(ok_json);
    const ok = try respondTo(alloc, ok_json, &calls);
    defer alloc.free(ok);
    const r2 = try expectCode(ok, .ok);
    alloc.free(r2.stdout);
    alloc.free(r2.stderr);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "win32 tmux server: routing is by wparam before the server check" {
    const fake: *ipc.Server = @ptrFromInt(0x1000);
    // Standalone process: no main server, but the tmux pipe answers.
    try std.testing.expectEqual(Route.tmux, routeIpc(1, null, fake, null));
    try std.testing.expectEqual(Route.drop, routeIpc(0, null, fake, null));
    try std.testing.expectEqual(Route.main, routeIpc(0, fake, null, null));
    try std.testing.expectEqual(Route.drop, routeIpc(1, fake, null, userTag(1)));
    // The user pipe has its own tag per claim; released, or from an earlier
    // claim, its messages are dropped.
    try std.testing.expectEqual(Route.tmux_user, routeIpc(userTag(1), null, null, userTag(1)));
    try std.testing.expectEqual(Route.drop, routeIpc(userTag(1), fake, fake, null));
    try std.testing.expectEqual(Route.drop, routeIpc(userTag(1), null, null, userTag(2)));
    try std.testing.expectEqual(Route.drop, routeIpc(userTag(2), null, null, userTag(1)));
    try std.testing.expectEqual(Route.drop, routeIpc(post_tag_user, null, null, userTag(1)));
    try std.testing.expectEqual(Route.drop, routeIpc(3, fake, fake, userTag(1)));
}

fn testUiHandler(ctx: ?*anyopaque, pending: *ipc.Server.Pending) void {
    const calls: *u32 = @ptrCast(@alignCast(ctx.?));
    const bytes = respond(pending.alloc, pending.request, win32.kernel32.GetTickCount64(), TestRunner{ .calls = calls }, false) catch
        (pending.alloc.dupe(u8, "") catch return);
    ipc.Server.complete(pending, bytes);
}

const TestPipe = struct {
    name: [:0]u16,
    ui: *ipc.Server.TestUi,
    server: *ipc.Server,
    calls: u32 = 0,

    fn create(alloc: Allocator) !*TestPipe {
        const self = try alloc.create(TestPipe);
        errdefer alloc.destroy(self);
        self.* = .{ .name = try ipc.Server.testPipeName(alloc), .ui = undefined, .server = undefined };
        errdefer alloc.free(self.name);
        self.ui = try ipc.Server.TestUi.create(alloc);
        errdefer self.ui.destroy();
        self.ui.custom = testUiHandler;
        self.ui.custom_ctx = &self.calls;
        self.server = try ipc.Server.claim(alloc, self.name);
        errdefer self.server.stop();
        self.server.post_tag = post_tag;
        self.server.max_request = protocol.max_request_tmux;
        self.server.io_timeout_ms = io_timeout_ms;
        self.server.close_wait_ms = close_wait_ms;
        try self.server.start(self.ui.hwnd);
        return self;
    }

    fn destroy(self: *TestPipe, alloc: Allocator) void {
        self.server.stop();
        self.ui.destroy();
        alloc.free(self.name);
        alloc.destroy(self);
    }
};

test "win32 tmux server: tmux pipe answers only op tmux" {
    const alloc = std.testing.allocator;
    const tp = try TestPipe.create(alloc);
    defer tp.destroy(alloc);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    var done: std.atomic.Value(u32) = .init(0);
    var call: ipc.Server.TestUi.Call = .{ .alloc = alloc, .name = tp.name, .op = "new-window", .timeout_ms = 5000, .done = &done };
    const t1 = try std.Thread.spawn(.{}, ipc.Server.TestUi.Call.run, .{&call});
    defer t1.join();
    try tp.ui.pumpUntil(&done, 1);
    const resp = try call.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.bad_request, resp.code);
    try std.testing.expectEqual(@as(u32, 0), tp.calls);

    var call2: ipc.Server.TestUi.Call = .{ .alloc = alloc, .name = tp.name, .op = "tmux", .timeout_ms = 5000, .done = &done };
    const t2 = try std.Thread.spawn(.{}, ipc.Server.TestUi.Call.run, .{&call2});
    defer t2.join();
    try tp.ui.pumpUntil(&done, 2);
    const ok = try call2.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, ok.code);
    try std.testing.expectEqualStrings("%5\n", ok.stdout);
    try std.testing.expectEqual(@as(u32, 1), tp.calls);
}

fn openRaw(name: [:0]const u16) win32.foundation.HANDLE {
    return win32.kernel32.CreateFileW(
        name.ptr,
        win32.kernel32.GENERIC_READ | win32.kernel32.GENERIC_WRITE,
        0,
        null,
        win32.kernel32.OPEN_EXISTING,
        win32.kernel32.FILE_FLAG_OVERLAPPED,
        null,
    );
}

test "win32 tmux server: silent tmux client releases the queue within 600 ms" {
    const alloc = std.testing.allocator;
    const tp = try TestPipe.create(alloc);
    defer tp.destroy(alloc);

    // Connects and writes nothing.
    const silent = openRaw(tp.name);
    try std.testing.expect(silent != win32.kernel32.INVALID_HANDLE_VALUE);
    defer _ = win32.kernel32.CloseHandle(silent);
    const t0 = win32.kernel32.GetTickCount64();

    var done: std.atomic.Value(u32) = .init(0);
    var call: ipc.Server.TestUi.Call = .{ .alloc = alloc, .name = tp.name, .op = "tmux", .timeout_ms = 5000, .done = &done };
    const t1 = try std.Thread.spawn(.{}, ipc.Server.TestUi.Call.run, .{&call});
    defer t1.join();
    try tp.ui.pumpUntil(&done, 1);
    const elapsed = win32.kernel32.GetTickCount64() - t0;
    try std.testing.expect(elapsed < 600);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try call.expectResponse(arena.allocator());
    try std.testing.expectEqual(protocol.Code.ok, resp.code);
}

test "win32 tmux server: 4 MiB limit" {
    const alloc = std.testing.allocator;
    const tp = try TestPipe.create(alloc);
    defer tp.destroy(alloc);

    const h = openRaw(tp.name);
    try std.testing.expect(h != win32.kernel32.INVALID_HANDLE_VALUE);
    defer _ = win32.kernel32.CloseHandle(h);
    const event = win32.kernel32.CreateEventW(null, 1, 0, null).?;
    defer _ = win32.kernel32.CloseHandle(event);
    const client = @import("../ipc/client.zig");
    const io: client.Io = .{ .pipe = h, .event = event };
    const deadline = win32.kernel32.GetTickCount64() + 3000;

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, protocol.max_request_tmux + 1, .little);
    try io.writeAll(&hdr, deadline);
    try io.readExact(&hdr, deadline);
    const body = try alloc.alloc(u8, std.mem.readInt(u32, &hdr, .little));
    defer alloc.free(body);
    try io.readExact(body, deadline);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try protocol.parseResponse(arena.allocator(), body);
    try std.testing.expectEqual(protocol.Code.bad_request, resp.code);
    try std.testing.expectEqual(@as(u32, 0), tp.calls);
}

test "win32 tmux server: M2 pipe does not answer tmux" {
    // The M2 op table has no "tmux" op, so the per-user pipe answers
    // bad_request ("unknown op") without acting.
    try std.testing.expect(std.meta.stringToEnum(@import("../ipc/ops.zig").Op, "tmux") == null);
}
