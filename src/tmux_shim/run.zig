//! The testable logic of `tmux.exe`: argv in, request out, response mapped
//! to an exit code and the bytes for stdout and stderr. No Win32 here; the
//! transport and the stdin reader are passed in.
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("ipc_protocol");
const cli = @import("cli.zig");

pub const TransportError = error{ NoServer, NotOurServer, Timeout, BrokenPipe, ProtocolError, OutOfMemory };

/// What the client waits for a response at most.
pub const client_timeout_ms = 10_000;
/// The request deadline is this much earlier than the client's own timeout,
/// so the server never acts on a request the client has already given up on.
pub const deadline_margin_ms = 250;

pub const version_text = "tmux 3.5a\n";

pub const Env = struct {
    tmux: ?[]const u8,
    tmux_pane: ?[]const u8,
    trace: ?[]const u8,
    stats: bool,
    /// "K=V" entries; see `buildBlock`.
    block: []const []const u8,
};

pub const Outcome = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    /// Bytes of stdin that were forwarded (trace only; content is never traced).
    stdin_len: usize = 0,
};

/// The environment block that goes on the wire: entries that start with '='
/// (the `=C:` per-drive cwd variables) and entries that are not valid UTF-8
/// (unpaired surrogates) are dropped. `dropped` receives how many.
pub fn buildBlock(arena: Allocator, entries: []const []const u8, dropped: ?*usize) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var n_dropped: usize = 0;
    for (entries) |e| {
        if (e.len == 0 or e[0] == '=' or !std.unicode.utf8ValidateSlice(e)) {
            n_dropped += 1;
            continue;
        }
        try out.append(arena, e);
    }
    if (dropped) |d| d.* = n_dropped;
    return out.items;
}

/// `argv` excludes the program name. `transport` provides
/// `nowMs() u64` and `request(alloc, pipe, expected_pid, payload, deadline_ms) TransportError![]u8`;
/// `stdin` provides `read(arena, limit: usize) error{TooLarge, ReadFailed, OutOfMemory}![]u8`
/// and is only touched for `load-buffer … -`.
pub fn run(
    arena: Allocator,
    argv: []const []const u8,
    env: Env,
    cwd: []const u8,
    transport: anytype,
    stdin: anytype,
) !Outcome {
    var diag: cli.Diag = .{};
    const g = cli.parseGlobal(argv, &diag) catch |err| switch (err) {
        error.Usage => return fail(arena, "{s}\n", .{diag.message()}),
    };
    if (g.version) return .{ .code = 0, .stdout = version_text, .stderr = "" };

    // External-server mode (-L) is not available.
    if (g.socket_name != null and g.socket_path == null) {
        return fail(arena, "no server running on {s}\n", .{g.socket_name.?});
    }
    const pipe: []const u8 = pipe: {
        if (g.socket_path) |p| break :pipe p;
        if (env.tmux) |t| {
            const first = t[0 .. std.mem.indexOfScalar(u8, t, ',') orelse t.len];
            if (first.len > 0) break :pipe first;
        }
        return fail(arena, "no server running on default\n", .{});
    };
    // Only a Ghostty tmux pipe is ever opened: no file, UNC or foreign pipe
    // path gets the request (it carries the environment).
    const expected_pid = protocol.tmuxPipePid(pipe) orelse
        return fail(arena, "not a Ghostty tmux socket\n", .{});

    for (g.rest) |a| {
        if (!std.unicode.utf8ValidateSlice(a)) return fail(arena, "ghostty: invalid UTF-8 in arguments\n", .{});
    }
    if (!std.unicode.utf8ValidateSlice(cwd)) return fail(arena, "ghostty: invalid UTF-8 in arguments\n", .{});

    var stdin_text: ?[]const u8 = null;
    if (wantsStdin(arena, g.rest)) {
        const bytes = stdin.read(arena, protocol.max_stdin_tmux) catch |err| switch (err) {
            error.TooLarge => return fail(arena, "ghostty: request too large\n", .{}),
            error.ReadFailed => return fail(arena, "ghostty: cannot read stdin\n", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) return fail(arena, "ghostty: invalid UTF-8 on stdin\n", .{});
        stdin_text = bytes;
    }

    const start = transport.nowMs();
    const payload = try protocol.encodeRequest(arena, .{
        .v = protocol.version,
        .op = "tmux",
        .args = g.rest,
        .cwd = cwd,
        .env = env.block,
        .stdin = stdin_text,
        .pane = env.tmux_pane orelse "",
        .deadline_ms = start + client_timeout_ms - deadline_margin_ms,
    });
    if (payload.len > protocol.max_request_tmux) return fail(arena, "ghostty: request too large\n", .{});

    const stdin_len = if (stdin_text) |s| s.len else 0;
    const bytes = transport.request(arena, pipe, expected_pid, payload, start + client_timeout_ms) catch |err| {
        var out = switch (err) {
            error.NoServer, error.NotOurServer => try fail(arena, "no server running on {s}\n", .{pipe}),
            error.Timeout => try fail(arena, "ghostty: server timed out\n", .{}),
            else => try fail(arena, "ghostty: lost connection to {s}\n", .{pipe}),
        };
        out.stdin_len = stdin_len;
        return out;
    };
    const resp = protocol.parseResponse(arena, bytes) catch {
        var out = try fail(arena, "ghostty: lost connection to {s}\n", .{pipe});
        out.stdin_len = stdin_len;
        return out;
    };
    return .{
        .code = if (resp.code == .ok) 0 else 1,
        .stdout = resp.stdout,
        .stderr = resp.stderr,
        .stdin_len = stdin_len,
    };
}

fn fail(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Outcome {
    return .{ .code = 1, .stdout = "", .stderr = try std.fmt.allocPrint(arena, fmt, args) };
}

/// True when some command of the line is `load-buffer` whose last
/// positional argument is "-".
fn wantsStdin(arena: Allocator, rest: []const []const u8) bool {
    var diag: cli.Diag = .{};
    const cmds = cli.parseCommands(arena, rest, &diag) catch return false;
    for (cmds) |c| {
        if (c.id != .load_buffer) continue;
        if (c.positional.len > 0 and std.mem.eql(u8, c.positional[c.positional.len - 1], "-")) return true;
    }
    return false;
}

// ---- tests -----------------------------------------------------------

const FakeTransport = struct {
    now: u64 = 1000,
    reply: ?[]const u8 = null,
    err: ?TransportError = null,
    calls: usize = 0,
    pipe: []const u8 = "",
    expected_pid: u32 = 0,
    payload: []const u8 = "",
    deadline: u64 = 0,

    pub fn nowMs(self: *FakeTransport) u64 {
        return self.now;
    }

    pub fn request(self: *FakeTransport, alloc: Allocator, pipe: []const u8, expected_pid: u32, payload: []const u8, deadline_ms: u64) TransportError![]u8 {
        self.calls += 1;
        self.pipe = pipe;
        self.expected_pid = expected_pid;
        self.payload = payload;
        self.deadline = deadline_ms;
        if (self.err) |e| return e;
        return try alloc.dupe(u8, self.reply orelse "");
    }
};

const NoStdin = struct {
    pub fn read(_: NoStdin, _: Allocator, _: usize) error{ TooLarge, ReadFailed, OutOfMemory }![]u8 {
        @panic("stdin must not be read");
    }
};

const BytesStdin = struct {
    data: []const u8,
    pub fn read(self: BytesStdin, _: Allocator, limit: usize) error{ TooLarge, ReadFailed, OutOfMemory }![]u8 {
        if (self.data.len > limit) return error.TooLarge;
        return @constCast(self.data);
    }
};

fn testEnv(over: struct { tmux: ?[]const u8 = null, pane: ?[]const u8 = null, block: []const []const u8 = &.{} }) Env {
    return .{ .tmux = over.tmux, .tmux_pane = over.pane, .trace = null, .stats = false, .block = over.block };
}

const ok_reply = "{\"v\":1,\"code\":0,\"stdout\":\"%5\\n\",\"stderr\":\"\",\"data\":null}";

test "tmux shim run: -V needs no server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{};
    const out = try run(arena_state.allocator(), &.{"-V"}, testEnv(.{}), "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqualStrings("tmux 3.5a\n", out.stdout);
    try std.testing.expectEqual(@as(usize, 0), tr.calls);
}

test "tmux shim run: no TMUX and no -S" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{};
    const out = try run(arena_state.allocator(), &.{ "display-message", "-p", "x" }, testEnv(.{}), "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 1), out.code);
    try std.testing.expectEqualStrings("no server running on default\n", out.stderr);
    try std.testing.expectEqual(@as(usize, 0), tr.calls);
}

test "tmux shim run: -L without -S is not a server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{};
    const out = try run(arena_state.allocator(), &.{ "-L", "work", "list-panes" }, testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-1-ab,1,0" }), "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 1), out.code);
    try std.testing.expectEqualStrings("no server running on work\n", out.stderr);
    try std.testing.expectEqual(@as(usize, 0), tr.calls);
}

test "tmux shim run: -S beats TMUX" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{ .reply = ok_reply };
    const out = try run(
        arena_state.allocator(),
        &.{ "-S", "\\\\.\\pipe\\ghostty-tmux-42-00000000000000ff", "list-panes" },
        testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" }),
        "C:\\",
        &tr,
        NoStdin{},
    );
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ghostty-tmux-42-00000000000000ff", tr.pipe);
    try std.testing.expectEqual(@as(u32, 42), tr.expected_pid);
}

test "tmux shim run: TMUX first field and expected pid from pipe name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{ .reply = ok_reply };
    _ = try run(arena_state.allocator(), &.{"list-panes"}, testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" }), "C:\\", &tr, NoStdin{});
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa", tr.pipe);
    try std.testing.expectEqual(@as(u32, 7), tr.expected_pid);
    try std.testing.expectEqual(@as(?u32, 42), protocol.tmuxPipePid("\\\\.\\pipe\\ghostty-tmux-42-00ff00ff00ff00ff"));
    try std.testing.expectEqual(@as(?u32, null), protocol.tmuxPipePid("\\\\.\\pipe\\ghostty-tmux-x"));
}

test "tmux shim run: request fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dropped: usize = 0;
    const block = try buildBlock(a, &.{ "=C:=C:\\x", "PATH=C:\\bin", "BAD=\xed\xa0\x80", "EMPTY=", "" }, &dropped);
    try std.testing.expectEqual(@as(usize, 3), dropped);

    var tr: FakeTransport = .{ .now = 5000, .reply = ok_reply };
    const argv = [_][]const u8{ "split-window", "-h", "-P", "-F", "#{pane_id}" };
    const out = try run(a, &argv, testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0", .pane = "%3", .block = block }), "C:\\work", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 0), out.code);

    const req = try protocol.parseRequest(a, tr.payload);
    try std.testing.expectEqualStrings("tmux", req.op);
    try std.testing.expectEqual(@as(u32, 1), req.v);
    try std.testing.expectEqual(argv.len, req.args.len);
    for (argv, req.args) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("%3", req.pane);
    try std.testing.expectEqualStrings("C:\\work", req.cwd);
    try std.testing.expectEqual(@as(usize, 2), req.env.len);
    for (req.env) |e| {
        try std.testing.expect(!std.mem.startsWith(u8, e, "=C:"));
        try std.testing.expect(std.unicode.utf8ValidateSlice(e));
    }
    try std.testing.expect(req.stdin == null);
    try std.testing.expectEqual(@as(u64, 5000 + 9750), req.deadline_ms);
    try std.testing.expectEqual(@as(u64, 5000 + 10_000), tr.deadline);
}

test "tmux shim run: response mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" });

    var ok: FakeTransport = .{ .reply = ok_reply };
    const o1 = try run(a, &.{"list-panes"}, env, "C:\\", &ok, NoStdin{});
    try std.testing.expectEqual(@as(u8, 0), o1.code);
    try std.testing.expectEqualStrings("%5\n", o1.stdout);

    var failed: FakeTransport = .{ .reply = "{\"v\":1,\"code\":1,\"stdout\":\"\",\"stderr\":\"can't find pane: %9\\n\"}" };
    const o2 = try run(a, &.{"kill-pane"}, env, "C:\\", &failed, NoStdin{});
    try std.testing.expectEqual(@as(u8, 1), o2.code);
    try std.testing.expectEqualStrings("can't find pane: %9\n", o2.stderr);

    var bad_req: FakeTransport = .{ .reply = "{\"v\":1,\"code\":2,\"stdout\":\"\",\"stderr\":\"bad\"}" };
    try std.testing.expectEqual(@as(u8, 1), (try run(a, &.{"kill-pane"}, env, "C:\\", &bad_req, NoStdin{})).code);

    var garbage: FakeTransport = .{ .reply = "not json" };
    const o3 = try run(a, &.{"list-panes"}, env, "C:\\", &garbage, NoStdin{});
    try std.testing.expectEqual(@as(u8, 1), o3.code);
    try std.testing.expectEqualStrings("ghostty: lost connection to \\\\.\\pipe\\ghostty-tmux-7-00000000000000aa\n", o3.stderr);
}

test "tmux shim run: transport errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" });
    const pipe = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa";

    inline for (.{
        .{ error.NoServer, "no server running on " ++ pipe ++ "\n" },
        .{ error.NotOurServer, "no server running on " ++ pipe ++ "\n" },
        .{ error.Timeout, "ghostty: server timed out\n" },
        .{ error.BrokenPipe, "ghostty: lost connection to " ++ pipe ++ "\n" },
        .{ error.ProtocolError, "ghostty: lost connection to " ++ pipe ++ "\n" },
    }) |case| {
        var tr: FakeTransport = .{ .err = case[0] };
        const out = try run(a, &.{"list-panes"}, env, "C:\\", &tr, NoStdin{});
        try std.testing.expectEqual(@as(u8, 1), out.code);
        try std.testing.expectEqualStrings(case[1], out.stderr);
    }
}

test "tmux shim run: load-buffer reads stdin only when asked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" });

    var tr: FakeTransport = .{ .reply = ok_reply };
    const o1 = try run(a, &.{ "display-message", "-p", "x" }, env, "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 0), o1.code);
    // load-buffer from a file does not read stdin either.
    const o2 = try run(a, &.{ "load-buffer", "C:\\x.txt" }, env, "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 0), o2.code);

    const o3 = try run(a, &.{ "load-buffer", "-b", "claude", "-" }, env, "C:\\", &tr, BytesStdin{ .data = "héllo\n" });
    try std.testing.expectEqual(@as(u8, 0), o3.code);
    const req = try protocol.parseRequest(a, tr.payload);
    try std.testing.expectEqualStrings("héllo\n", req.stdin.?);
    try std.testing.expectEqual(@as(usize, 7), o3.stdin_len);
}

test "tmux shim run: load-buffer caps and UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" });
    var tr: FakeTransport = .{ .reply = ok_reply };

    const big = try a.alloc(u8, protocol.max_stdin_tmux + 1);
    @memset(big, 'a');
    const o1 = try run(a, &.{ "load-buffer", "-" }, env, "C:\\", &tr, BytesStdin{ .data = big });
    try std.testing.expectEqual(@as(u8, 1), o1.code);
    try std.testing.expectEqualStrings("ghostty: request too large\n", o1.stderr);

    const exact = try a.alloc(u8, protocol.max_stdin_tmux);
    @memset(exact, 'a');
    const o2 = try run(a, &.{ "load-buffer", "-" }, env, "C:\\", &tr, BytesStdin{ .data = exact });
    try std.testing.expectEqual(@as(u8, 0), o2.code);

    const o3 = try run(a, &.{ "load-buffer", "-" }, env, "C:\\", &tr, BytesStdin{ .data = "\xff\xfe" });
    try std.testing.expectEqual(@as(u8, 1), o3.code);
    try std.testing.expectEqualStrings("ghostty: invalid UTF-8 on stdin\n", o3.stderr);
    try std.testing.expectEqual(@as(usize, 1), tr.calls);
}

test "tmux shim run: usage errors do not reach the server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tr: FakeTransport = .{};
    const out = try run(arena_state.allocator(), &.{ "-Q", "list-panes" }, testEnv(.{ .tmux = "\\\\.\\pipe\\ghostty-tmux-7-00000000000000aa,7,0" }), "C:\\", &tr, NoStdin{});
    try std.testing.expectEqual(@as(u8, 1), out.code);
    try std.testing.expectEqualStrings("unknown option -Q\n", out.stderr);
    try std.testing.expectEqual(@as(usize, 0), tr.calls);
}

test "tmux shim run: only Ghostty tmux pipes are opened" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zeros: [400]u8 = @splat('0');
    const long = try std.fmt.allocPrint(a, "\\\\.\\pipe\\ghostty-tmux-1-{s}", .{&zeros});
    const bad = [_][]const u8{
        "C:\\x\\file.txt",
        "\\\\host\\pipe\\ghostty-tmux-1-00000000000000ab",
        "\\\\.\\pipe\\other",
        "\\\\.\\pipe\\ghostty-tmux-1-ab",
        "\\\\.\\pipe\\ghostty-tmux-x-00000000000000ab",
        long,
    };
    for (bad) |name| {
        var tr: FakeTransport = .{ .reply = ok_reply };
        const out = try run(a, &.{ "-S", name, "list-panes" }, testEnv(.{}), "C:\\", &tr, NoStdin{});
        try std.testing.expectEqual(@as(u8, 1), out.code);
        try std.testing.expectEqualStrings("not a Ghostty tmux socket\n", out.stderr);
        try std.testing.expectEqual(@as(usize, 0), tr.calls);

        var tr2: FakeTransport = .{ .reply = ok_reply };
        const env_tmux = try std.fmt.allocPrint(a, "{s},1,0", .{name});
        const out2 = try run(a, &.{"list-panes"}, testEnv(.{ .tmux = env_tmux }), "C:\\", &tr2, NoStdin{});
        try std.testing.expectEqual(@as(u8, 1), out2.code);
        try std.testing.expectEqual(@as(usize, 0), tr2.calls);
    }
}
