//! Update checker (R-M5-9): a worker thread per check (WinHTTP, a 10 s
//! deadline enforced from the UI thread), the schedule on the `update` timer,
//! the toast and the `check_for_updates` dialog. The pure parts live in
//! `release.zig` (feed, versions) and `state.zig` (schedule, state file).
const Updater = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const os = @import("../../../os/main.zig");
const App = @import("../App.zig");
const dialogs = @import("../dialogs.zig");
const ipc_ops = @import("../ipc/ops.zig");
const messages = @import("../messages.zig");
const notify = @import("../notify.zig");
const shell_open = @import("../shell_open.zig");
const util = @import("../util.zig");
const persist = @import("state.zig");
const release = @import("release.zig");

const winhttp = win32.winhttp;
const Config = configpkg.Config;
const HWND = win32.foundation.HWND;
const LPARAM = win32.foundation.LPARAM;

const log = std.log.scoped(.win32_update);

/// The answer is a few KiB; anything bigger is not the release list.
const max_body = 1024 * 1024;
/// Wall-clock limit of one check, enforced by the `update` timer.
const deadline_ms = 10_000;
/// How often the timer looks at the deadline while a check runs.
const poll_ms = 250;
/// The first automatic check, counted from the start of the app.
const first_check_ms = 60_000;
const interval_ms: u32 = 24 * 60 * 60 * 1000;

const env_url_var = "GHOSTTY_WIN32_UPDATE_URL";
const env_n_var = "GHOSTTY_WIN32_TEST_CURRENT_N";

const button_open = 100;
const button_close = 2;

pub const Outcome = union(enum) {
    /// A release newer than this build.
    newer: release.Release,
    /// This build is the newest.
    current,
    /// A local build (no `-win.<N>`): the newest release, for the dialog.
    local: release.Release,
    failed: []const u8,
};

/// Posted by the worker (heap, `WM_GHOSTTY_UPDATE_RESULT`), freed by the
/// receiver. `arena` owns the strings of `outcome`.
pub const Result = struct {
    manual: bool,
    outcome: Outcome,
    arena: ?std.heap.ArenaAllocator = null,

    fn deinit(self: *Result) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }
};

/// What the UI thread and one worker share. Heap block, two references (the
/// app's and the worker's); whoever drops the last frees it. The worker
/// touches nothing but this block, so a worker that outlives `stop` (and the
/// app) cannot reach freed memory.
pub const Shared = struct {
    alloc: Allocator,
    refs: std.atomic.Value(u32) = .init(2),
    /// The WinHTTP request handle of the check that runs; whoever swaps it
    /// to zero closes it.
    request: std.atomic.Value(usize) = .init(0),
    manual: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    /// The worker is out of everything it does (set last, before its release).
    done: std.atomic.Value(bool) = .init(false),
    /// The app is quitting: the worker skips the module unload wait.
    stopping: std.atomic.Value(bool) = .init(false),

    fn create(alloc: Allocator, manual: bool) Allocator.Error!*Shared {
        const s = try alloc.create(Shared);
        s.* = .{ .alloc = alloc };
        s.manual.store(manual, .seq_cst);
        return s;
    }

    fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .seq_cst) == 1) self.alloc.destroy(self);
    }
};

pub const State = struct {
    /// The running (or last) check's shared block; this is the app's reference.
    shared: ?*Shared = null,
    deadline_ms: u64 = 0,
    /// The last result that was handled (the worker's arena moves in).
    last: ?Result = null,

    mode: persist.Mode = .off,
    current_n: ?u32 = null,
    /// `GHOSTTY_WIN32_UPDATE_URL`, read in test mode only.
    env_url: ?[]u8 = null,
    store: persist.State = .{},
    phase: Phase = .idle,
    /// A manual check was asked for while one ran: its result answers it.
    manual_pending: bool = false,
    stopping: bool = false,
    /// The release page of the last newer release, owned by the app allocator.
    open_url: ?[]u8 = null,
    warned_download: bool = false,
    showing: bool = false,
    fetches: u32 = 0,
    results: u32 = 0,
    dialogs_shown: u32 = 0,
    toasts: u32 = 0,
};

const Phase = enum { idle, waiting, fetching };

fn testMode() bool {
    return ipc_ops.testOpsEnabled();
}

// -- Pure decisions -------------------------------------------------------------

/// The URL a check fetches. Outside test mode always the endpoint. In test
/// mode only a loopback `http` override; without one, nothing is fetched.
pub fn urlForRun(env_url: ?[]const u8, test_mode: bool) ?[]const u8 {
    if (!test_mode) return release.endpoint;
    const url = env_url orelse return null;
    const parts = parseUrl(url) orelse return null;
    if (parts.secure or !std.mem.eql(u8, parts.host, "127.0.0.1")) return null;
    return url;
}

/// The release number of this run: the build's `-win.<N>`; in test mode the
/// environment may stand in for it.
pub fn currentNForRun(build_version: []const u8, env_n: ?[]const u8, test_mode: bool) ?u32 {
    if (test_mode) if (env_n) |text| return std.fmt.parseUnsigned(u32, text, 10) catch null;
    return release.currentN(build_version);
}

pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    /// Starts with '/'.
    path: []const u8,
};

/// `http(s)://host[:port]/path`. No user info, no query right after the host.
pub fn parseUrl(url: []const u8) ?Url {
    var secure = true;
    var rest = std.mem.cutPrefix(u8, url, "https://") orelse blk: {
        secure = false;
        break :blk std.mem.cutPrefix(u8, url, "http://") orelse return null;
    };
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    const path = rest[slash..];
    rest = authority;
    if (std.mem.indexOfAny(u8, authority, "@?#\\ ") != null) return null;

    var host = authority;
    var port: u16 = if (secure) winhttp.INTERNET_DEFAULT_HTTPS_PORT else winhttp.INTERNET_DEFAULT_HTTP_PORT;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseUnsigned(u16, authority[colon + 1 ..], 10) catch return null;
        if (port == 0) return null;
    }
    if (host.len == 0) return null;
    return .{ .secure = secure, .host = host, .port = port, .path = path };
}

pub const DialogKind = enum { none, available, current, local, failed };

pub const Plan = struct {
    toast: bool,
    dialog: DialogKind,
};

/// What a result asks for. A toast only for a newer release that was not
/// announced yet; a dialog only when the user asked for the check.
pub fn plan(manual: bool, outcome: std.meta.Tag(Outcome), announce: bool) Plan {
    return .{
        .toast = outcome == .newer and announce,
        .dialog = if (!manual) .none else switch (outcome) {
            .newer => .available,
            .current => .current,
            .local => .local,
            .failed => .failed,
        },
    };
}

// -- WinHTTP fetch (worker thread only) -----------------------------------------

pub const FetchError = error{ BadUrl, NoWinHttp, Network, Status, TooLarge, OutOfMemory };

/// Win32 error or HTTP status behind the last `Network` / `Status` error of
/// this thread.
threadlocal var fetch_detail: u32 = 0;

/// `WinHttpCloseHandle` of the loaded module, for the UI thread's deadline
/// close; zero while no module is loaded.
var g_close: std.atomic.Value(usize) = .init(0);
/// The UI thread is inside a close call (the module must not unload).
var g_closing: std.atomic.Value(bool) = .init(false);

/// Closes the request handle of `handle` once; whoever gets it closes it.
/// Safe from the UI thread: the module is not unloaded meanwhile.
fn closeShared(handle: *std.atomic.Value(usize)) bool {
    g_closing.store(true, .seq_cst);
    defer g_closing.store(false, .seq_cst);
    const h = handle.swap(0, .seq_cst);
    if (h == 0) return false;
    closeHook(h);
    return true;
}

/// Injectable for tests.
var closeHook: *const fn (usize) void = closeReal;

fn closeReal(h: usize) void {
    const addr = g_close.load(.seq_cst);
    if (addr == 0) return;
    const f: winhttp.CloseHandleFn = @ptrFromInt(addr);
    _ = f(@ptrFromInt(h));
}

/// GET `url` and return the body (at most `max_body` bytes). The request
/// handle is published in `handle_out` so that another thread can abort the
/// call by closing it.
pub fn fetch(arena: Allocator, url: []const u8, max_bytes: usize, handle_out: *std.atomic.Value(usize), stopping: *const std.atomic.Value(bool)) FetchError![]u8 {
    const parts = parseUrl(url) orelse return error.BadUrl;
    const api = winhttp.Api.load() orelse return error.NoWinHttp;
    g_close.store(@intFromPtr(api.closeHandle), .seq_cst);

    const event = win32.kernel32.CreateEventW(null, 1, 0, null);
    var session: ?winhttp.HINTERNET = null;
    var connection: ?winhttp.HINTERNET = null;
    var notify_set = false;
    defer {
        // The request first (unless the UI thread did), then its parents.
        const left = handle_out.swap(0, .seq_cst);
        if (left != 0) _ = api.closeHandle(@ptrFromInt(left));
        if (connection) |c| _ = api.closeHandle(c);
        if (session) |s| _ = api.closeHandle(s);
        unloadWhenSafe(api, event, notify_set, stopping);
    }

    const agent = util.utf16z(arena, std.fmt.allocPrint(arena, "Ghostty/{s} (Windows)", .{build_config.version_string}) catch return error.OutOfMemory) catch return error.OutOfMemory;
    // The loopback override (plain http) never asks a proxy or runs WPAD.
    session = if (!parts.secure)
        api.open(agent, winhttp.WINHTTP_ACCESS_TYPE_NO_PROXY, null, null, 0) orelse return netError()
    else
        api.open(agent, winhttp.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
            api.open(agent, winhttp.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse
            return netError();
    if (event) |e| {
        var handle: win32.foundation.HANDLE = e;
        notify_set = api.setOption(session, winhttp.WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT, @ptrCast(&handle), @sizeOf(win32.foundation.HANDLE)) != 0;
    }
    if (api.setTimeouts(session.?, 10_000, 10_000, 10_000, 10_000) == 0) return netError();

    const host = util.utf16z(arena, parts.host) catch return error.OutOfMemory;
    const path = util.utf16z(arena, parts.path) catch return error.OutOfMemory;
    connection = api.connect(session.?, host, parts.port, 0) orelse return netError();
    const flags: u32 = if (parts.secure) winhttp.WINHTTP_FLAG_SECURE else 0;
    const request = api.openRequest(connection.?, std.unicode.utf8ToUtf16LeStringLiteral("GET"), path, null, null, null, flags) orelse return netError();
    handle_out.store(@intFromPtr(request), .seq_cst);
    // A redirect would take the request off the address that was checked: any 3xx fails.
    var policy: u32 = winhttp.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (api.setOption(request, winhttp.WINHTTP_OPTION_REDIRECT_POLICY, @ptrCast(&policy), @sizeOf(u32)) == 0) return netError();

    const headers = std.unicode.utf8ToUtf16LeStringLiteral("Accept: application/vnd.github+json\r\n");
    if (api.sendRequest(request, headers, @intCast(headers.len), null, 0, 0, 0) == 0) return netError();
    if (api.receiveResponse(request, null) == 0) return netError();

    var status: u32 = 0;
    var status_len: u32 = @sizeOf(u32);
    if (api.queryHeaders(request, winhttp.WINHTTP_QUERY_STATUS_CODE | winhttp.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_len, null) == 0) return netError();
    log.info("update: {s} answered HTTP {d}", .{ url, status });
    if (status != 200) {
        fetch_detail = status;
        return error.Status;
    }

    var body: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        var read: u32 = 0;
        if (api.readData(request, &chunk, chunk.len, &read) == 0) return netError();
        if (read == 0) break;
        if (body.items.len + read > max_bytes) return error.TooLarge;
        body.appendSlice(arena, chunk[0..read]) catch return error.OutOfMemory;
    }
    return body.items;
}

fn netError() error{Network} {
    fetch_detail = win32.kernel32.GetLastError();
    return error.Network;
}

/// Gives the module back once WinHTTP signalled that nothing of it runs
/// (≤ 2 s) and the UI thread is not inside a close call. When the signal
/// does not come the module stays loaded.
fn unloadWhenSafe(api: winhttp.Api, event: ?win32.foundation.HANDLE, notify_set: bool, stopping: *const std.atomic.Value(bool)) void {
    g_close.store(0, .seq_cst);
    while (g_closing.load(.seq_cst)) std.atomic.spinLoopHint();
    if (event) |e| {
        defer _ = win32.kernel32.CloseHandle(e);
        // Quitting: the process is going, the module stays loaded and the worker is out at once.
        if (notify_set) {
            var waited: u32 = 0;
            while (waited < 2000 and !stopping.load(.seq_cst)) : (waited += 50) {
                if (win32.kernel32.WaitForSingleObjectEx(e, 50, 0) == 0) {
                    api.unload();
                    return;
                }
            }
        }
    }
    log.warn("winhttp.dll stays loaded, no unload notification", .{});
}

// -- Worker ----------------------------------------------------------------------

fn workerMain(shared: *Shared, hwnd: HWND, url: []u8, current_n: ?u32, stable_only: bool) void {
    // Last: after `done` and the release the worker owns nothing any more.
    defer shared.release();
    defer shared.done.store(true, .seq_cst);
    defer std.heap.smp_allocator.free(url);

    var result = std.heap.smp_allocator.create(Result) catch return;
    result.* = .{ .manual = false, .outcome = .current, .arena = .init(std.heap.smp_allocator) };
    const arena = result.arena.?.allocator();

    log.info("update: fetching {s}", .{url});
    result.outcome = check(arena, shared, url, current_n, stable_only);
    result.manual = shared.manual.load(.seq_cst);
    post(hwnd, result);
}

fn check(arena: Allocator, shared: *Shared, url: []const u8, current_n: ?u32, stable_only: bool) Outcome {
    const body = fetch(arena, url, max_body, &shared.request, &shared.stopping) catch |err| {
        const text = switch (err) {
            error.BadUrl => "the update address is invalid",
            error.NoWinHttp => "WinHTTP is not available",
            error.Network => if (shared.timed_out.load(.seq_cst))
                "no answer within 10 seconds"
            else
                std.fmt.allocPrint(arena, "network error {d}", .{fetch_detail}) catch "network error",
            error.Status => std.fmt.allocPrint(arena, "the server answered HTTP {d}", .{fetch_detail}) catch "the server refused",
            error.TooLarge => "the answer is too large",
            error.OutOfMemory => "out of memory",
        };
        return .{ .failed = text };
    };
    const newest = release.newest(arena, body, stable_only) catch |err| return .{ .failed = switch (err) {
        error.NotJson => "the server's answer is not a release list",
        error.NoRelease => "no Windows release was found",
        error.OutOfMemory => "out of memory",
    } };
    const n = current_n orelse return .{ .local = newest };
    return if (newest.n > n) .{ .newer = newest } else .current;
}

/// To the message window; frees the result when nobody takes it.
fn post(hwnd: HWND, result: *Result) void {
    const lparam: LPARAM = @bitCast(@intFromPtr(result));
    if (win32.user32.PostMessageW(hwnd, messages.WM_GHOSTTY_UPDATE_RESULT, 0, lparam) == 0) destroy(result);
}

fn destroy(result: *Result) void {
    result.deinit();
    std.heap.smp_allocator.destroy(result);
}

// -- Lifecycle -------------------------------------------------------------------

pub fn start(app: *App) void {
    const st = &app.update;
    const test_mode = testMode();
    const alloc = app.core_app.alloc;

    if (test_mode) {
        st.env_url = os.windows.diagnosticEnv(alloc, env_url_var);
        const env_n = os.windows.diagnosticEnv(alloc, env_n_var);
        defer if (env_n) |n| alloc.free(n);
        st.current_n = currentNForRun(build_config.version_string, env_n, true);
    } else {
        st.current_n = currentNForRun(build_config.version_string, null, false);
    }
    loadStore(app);
    evaluate(app, &app.config);
}

/// How long `stop` waits for a worker that is still out in WinHTTP.
const stop_budget_ms = 2000;

/// Asks the worker to leave and waits up to `budget_ms` for it, then drops the
/// app's reference. A worker that is late finishes on its own heap block and
/// frees it; it never touches anything of the app. True when it was out in time.
fn stopShared(slot: *?*Shared, budget_ms: u32) bool {
    const shared = slot.* orelse return true;
    slot.* = null;
    shared.stopping.store(true, .seq_cst);
    // Closing the request aborts the blocking call; ask again until the worker is out.
    var waited: u32 = 0;
    while (!shared.done.load(.seq_cst) and waited < budget_ms) : (waited += 20) {
        _ = closeShared(&shared.request);
        win32.kernel32.Sleep(20);
    }
    const in_time = shared.done.load(.seq_cst);
    if (!in_time) log.warn("the update worker did not stop in time", .{});
    shared.release();
    return in_time;
}

pub fn stop(app: *App) void {
    const st = &app.update;
    const hwnd = app.msg_hwnd;
    _ = win32.user32.KillTimer(hwnd, messages.timers.msg_window.update);
    st.phase = .idle;
    st.stopping = true;
    _ = stopShared(&st.shared, stop_budget_ms);

    // Results nobody will handle any more.
    var msg: win32.user32.MSG = undefined;
    const m = messages.WM_GHOSTTY_UPDATE_RESULT;
    while (win32.user32.PeekMessageW(&msg, hwnd, m, m, win32.user32.PM_REMOVE) != 0) {
        destroy(@ptrFromInt(@as(usize, @bitCast(msg.lParam))));
    }

    const alloc = app.core_app.alloc;
    if (st.last) |*last| last.deinit();
    st.last = null;
    if (st.open_url) |u| alloc.free(u);
    st.open_url = null;
    if (st.env_url) |u| alloc.free(u);
    st.env_url = null;
}

pub fn configChanged(app: *App, config: *const Config) void {
    evaluate(app, config);
}

/// Picks the mode from the config and arms or disarms the schedule.
fn evaluate(app: *App, config: *const Config) void {
    const st = &app.update;
    if (config.@"auto-update" == .download and !st.warned_download) {
        st.warned_download = true;
        log.warn("auto-update = download is not supported on Windows, checking only", .{});
    }
    st.mode = persist.modeFor(config.@"auto-update", builtin.mode == .debug, testMode(), st.current_n);
    switch (st.mode) {
        .off => if (st.phase == .waiting) {
            _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.update);
            st.phase = .idle;
        },
        // Only the process that owns the pipe checks on its own, so that two
        // instances never announce the same release twice.
        .check => if (st.phase == .idle and app.serving()) {
            const now_s = nowSeconds();
            // 60 s after the start; later when the last check is recent.
            var delay: i64 = first_check_ms;
            if (!persist.due(st.store, now_s)) {
                delay = @max(delay, (st.store.last_check + 24 * 60 * 60 - now_s) * 1000);
            }
            arm(app, .waiting, @intCast(@min(delay, @as(i64, interval_ms))));
        },
    }
}

fn arm(app: *App, phase: Phase, ms: u32) void {
    if (win32.user32.SetTimer(app.msg_hwnd, messages.timers.msg_window.update, ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
        app.update.phase = .idle;
        return;
    }
    app.update.phase = phase;
}

fn nowSeconds() i64 {
    const ts = std.Io.Timestamp.now(global.io(), .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

/// The `check_for_updates` action: a check now that always answers.
pub fn checkNow(app: *App, target: apprt.Target, value: void) !bool {
    _ = target;
    _ = value;
    startCheck(app, true);
    return true;
}

fn startCheck(app: *App, manual: bool) void {
    const st = &app.update;
    if (st.stopping) return;

    if (st.shared) |running| {
        // One check at a time; a manual ask joins the one that runs. Its worker may
        // have read `manual` already, so the result handler answers it as well.
        if (!running.done.load(.seq_cst)) {
            if (manual) {
                running.manual.store(true, .seq_cst);
                st.manual_pending = true;
            }
            return;
        }
        running.release();
        st.shared = null;
    }

    const url = urlForRun(st.env_url, testMode()) orelse {
        // Test mode without a loopback override: nothing leaves the machine.
        postFailed(app, "update checks are disabled in test mode");
        return;
    };
    const copy = std.heap.smp_allocator.dupe(u8, url) catch return;

    const shared = Shared.create(std.heap.smp_allocator, manual) catch {
        std.heap.smp_allocator.free(copy);
        return;
    };
    st.deadline_ms = win32.kernel32.GetTickCount64() + deadline_ms;
    st.fetches += 1;
    const thread = std.Thread.spawn(.{}, workerMain, .{ shared, app.msg_hwnd, copy, st.current_n, app.config.@"auto-update-channel" == .stable }) catch |err| {
        log.warn("unable to start the update worker err={}", .{err});
        std.heap.smp_allocator.free(copy);
        std.heap.smp_allocator.destroy(shared);
        postFailed(app, "unable to start the check");
        return;
    };
    thread.detach();
    st.shared = shared;
    arm(app, .fetching, poll_ms);
}

/// A failed result without a fetch, through the same path as the worker's.
fn postFailed(app: *App, text: []const u8) void {
    const result = std.heap.smp_allocator.create(Result) catch return;
    result.* = .{ .manual = true, .outcome = .current, .arena = .init(std.heap.smp_allocator) };
    const copy = result.arena.?.allocator().dupe(u8, text) catch {
        destroy(result);
        return;
    };
    result.outcome = .{ .failed = copy };
    post(app.msg_hwnd, result);
}

// -- UI thread: timer and results ----------------------------------------------------

/// Whether the deadline of the running check has passed; closes its request
/// then (once).
fn deadlineExpired(st: *State, shared: *Shared, now_ms: u64) bool {
    if (now_ms < st.deadline_ms) return false;
    st.deadline_ms = std.math.maxInt(u64);
    shared.timed_out.store(true, .seq_cst);
    return closeShared(&shared.request);
}

pub fn onTimer(app: *App) void {
    const st = &app.update;
    switch (st.phase) {
        .idle => _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.update),
        .fetching => if (st.shared) |shared| {
            if (!shared.done.load(.seq_cst) and deadlineExpired(st, shared, win32.kernel32.GetTickCount64())) {
                log.warn("update check: deadline passed, request closed", .{});
            }
        },
        .waiting => {
            _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.update);
            st.phase = .idle;
            if (st.mode == .check) startCheck(app, false);
        },
    }
}

pub fn onResult(app: *App, lparam: LPARAM) void {
    const posted: *Result = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const st = &app.update;
    // The result is ours now; the shell it was allocated in goes.
    var result = posted.*;
    std.heap.smp_allocator.destroy(posted);

    st.results += 1;
    // Reschedule: the next automatic check in 24 h.
    if (st.mode == .check and st.phase != .waiting) arm(app, .waiting, interval_ms) else if (st.phase == .fetching) {
        _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.update);
        st.phase = .idle;
    }

    const alloc = app.core_app.alloc;
    var announce = false;
    switch (result.outcome) {
        .newer, .local => |r| {
            setOpenUrl(app, r.html_url);
            if (result.outcome == .newer) announce = persist.shouldAnnounce(st.store, r, st.current_n orelse r.n);
        },
        .current => {},
        .failed => |text| log.info("update: check failed: {s}", .{text}),
    }
    if (result.outcome != .failed) {
        st.store.last_check = nowSeconds();
        if (announce) st.store.notified = result.outcome.newer.n;
        saveStore(app);
    }

    const manual = result.manual or st.manual_pending;
    st.manual_pending = false;
    result.manual = manual;
    const decided = plan(manual, std.meta.activeTag(result.outcome), announce);
    if (decided.toast) {
        const r = result.outcome.newer;
        if (std.fmt.allocPrint(alloc, "Ghostty {s} is available", .{r.version})) |title| {
            defer alloc.free(title);
            notify.showUpdate(app, title, "Open the release page");
            st.toasts += 1;
        } else |_| {}
    }

    if (st.last) |*old| old.deinit();
    st.last = result;
    // `result` moved into `st.last`; show from there.
    showDialog(app, decided.dialog);
}

fn setOpenUrl(app: *App, url: []const u8) void {
    const alloc = app.core_app.alloc;
    const copy = alloc.dupe(u8, url) catch return;
    if (app.update.open_url) |old| alloc.free(old);
    app.update.open_url = copy;
}

/// The toast was clicked, or the dialog's button: the release page, only if
/// it is one of this fork's.
pub fn openReleasePage(app: *App) void {
    const url = app.update.open_url orelse return;
    if (!release.isReleaseUrl(url)) {
        log.warn("refusing to open a release page outside the fork's releases", .{});
        return;
    }
    shell_open.submit(app, 0, .unknown, url);
}

fn showDialog(app: *App, kind: DialogKind) void {
    const st = &app.update;
    if (kind == .none) return;
    // The dialog runs a message loop; a second one would stack.
    if (st.showing) return;
    const last = st.last orelse return;
    const alloc = app.core_app.alloc;

    var instruction: []const u8 = undefined;
    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| alloc.free(b);
    var open_button = false;
    switch (kind) {
        .none => unreachable,
        .available => {
            const r = last.outcome.newer;
            instruction = std.fmt.allocPrint(alloc, "Ghostty {s} is available", .{r.version}) catch return;
            body_owned = std.fmt.allocPrint(alloc, "You are running {s}.\n\n", .{build_config.version_string}) catch return;
            open_button = true;
        },
        .current => {
            instruction = alloc.dupe(u8, "Ghostty is up to date") catch return;
            body_owned = std.fmt.allocPrint(alloc, "You are running {s}, the newest release.\n\n", .{build_config.version_string}) catch return;
        },
        .local => {
            const r = last.outcome.local;
            instruction = alloc.dupe(u8, "This is a local build") catch return;
            body_owned = std.fmt.allocPrint(alloc, "The newest release is {s}. A local build does not compare itself with releases.\n\n", .{r.version}) catch return;
            open_button = true;
        },
        .failed => {
            instruction = alloc.dupe(u8, "Could not check for updates") catch return;
            body_owned = std.fmt.allocPrint(alloc, "{s}.\n\n", .{last.outcome.failed}) catch return;
        },
    }
    defer alloc.free(instruction);

    const with_open = [_]dialogs.ListButton{
        .{ .id = button_open, .text = "&Open release page" },
        .{ .id = button_close, .text = "Close" },
    };
    const only_close = [_]dialogs.ListButton{.{ .id = button_close, .text = "Close" }};
    const buttons: []const dialogs.ListButton = if (open_button) &with_open else &only_close;

    const owner: ?HWND = if (app.last_active) |w| w.hwnd else null;
    st.showing = true;
    st.dialogs_shown += 1;
    const answer = dialogs.taskDialogList(owner, "Check for Updates", instruction, body_owned.?, buttons, if (open_button) button_open else button_close);
    st.showing = false;
    if (answer != null and answer.? == button_open) openReleasePage(app);
}

// -- State file ---------------------------------------------------------------------

var save_counter: std.atomic.Value(u32) = .init(0);

fn statePath(alloc: Allocator) ?[]u8 {
    const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}\\ghostty\\update.json", .{base}) catch null;
}

fn loadStore(app: *App) void {
    const alloc = app.core_app.alloc;
    const path = statePath(alloc) orelse return;
    defer alloc.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(4096)) catch return;
    defer alloc.free(data);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    app.update.store = persist.load(arena.allocator(), data);
}

/// Through a temp file and a move, so a crash never leaves half a file.
/// The temp name carries the process id and a counter, so two instances never share one.
fn saveStore(app: *App) void {
    const alloc = app.core_app.alloc;
    const path = statePath(alloc) orelse return;
    defer alloc.free(path);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    persist.save(&w, app.update.store) catch return;

    const io = global.io();
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch |err| {
        log.warn("unable to create the state directory err={}", .{err});
        return;
    };
    const temp = std.fmt.allocPrint(alloc, "{s}.{d}-{d}.tmp", .{ path, win32.kernel32.GetCurrentProcessId(), save_counter.fetchAdd(1, .monotonic) }) catch return;
    defer alloc.free(temp);
    cwd.writeFile(io, .{ .sub_path = temp, .data = w.buffered() }) catch |err| {
        log.warn("unable to write the update state err={}", .{err});
        return;
    };
    const wide_temp = util.utf16z(alloc, temp) catch return;
    defer alloc.free(wide_temp);
    const wide_path = util.utf16z(alloc, path) catch return;
    defer alloc.free(wide_path);
    if (win32.kernel32.MoveFileExW(wide_temp, wide_path, win32.kernel32.MOVEFILE_REPLACE_EXISTING) == 0) {
        log.warn("unable to replace the update state err={}", .{win32.kernel32.GetLastError()});
        cwd.deleteFile(io, temp) catch {};
    }
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    const st = &app.update;
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(@tagName(st.mode));
    try jw.objectField("current_n");
    try jw.write(st.current_n);
    try jw.objectField("fetches");
    try jw.write(st.fetches);
    try jw.objectField("results");
    try jw.write(st.results);
    try jw.objectField("toasts");
    try jw.write(st.toasts);
    try jw.objectField("dialogs");
    try jw.write(st.dialogs_shown);
    try jw.objectField("notified");
    try jw.write(st.store.notified);
    try jw.objectField("last_check");
    try jw.write(st.store.last_check);
    try jw.objectField("last");
    if (st.last) |last| {
        try jw.beginObject();
        try jw.objectField("manual");
        try jw.write(last.manual);
        try jw.objectField("kind");
        try jw.write(@tagName(last.outcome));
        switch (last.outcome) {
            .newer, .local => |r| {
                try jw.objectField("n");
                try jw.write(r.n);
                try jw.objectField("version");
                try jw.write(r.version);
            },
            .failed => |text| {
                try jw.objectField("error");
                try jw.write(text);
            },
            .current => {},
        }
        try jw.endObject();
    } else try jw.write(null);
    try jw.endObject();
}

// -- Tests ----------------------------------------------------------------------------

const testing = std.testing;

test "win32 update: test mode without override never fetches" {
    try testing.expect(urlForRun(null, true) == null);
    try testing.expect(urlForRun("http://example.com/", true) == null);
    try testing.expect(urlForRun("", true) == null);
}

test "win32 update: url override only in test mode and only loopback http" {
    try testing.expectEqualStrings("http://127.0.0.1:5000/x", urlForRun("http://127.0.0.1:5000/x", true).?);
    try testing.expect(urlForRun("https://127.0.0.1/", true) == null);
    try testing.expect(urlForRun("http://127.0.0.1.evil/", true) == null);
    try testing.expect(urlForRun("http://127.0.0.1@evil.example/", true) == null);
    try testing.expect(urlForRun("http://127.0.0.1:5000", true) == null);
    // Outside test mode the override is ignored.
    try testing.expectEqualStrings(release.endpoint, urlForRun("http://127.0.0.1:5000/x", false).?);
    try testing.expectEqualStrings(release.endpoint, urlForRun(null, false).?);

    try testing.expectEqual(@as(?u32, 3), currentNForRun("1.3.2-dev", "3", true));
    try testing.expectEqual(@as(?u32, null), currentNForRun("1.3.2-dev", "3", false));
    try testing.expectEqual(@as(?u32, null), currentNForRun("1.3.2-dev", null, true));
    try testing.expectEqual(@as(?u32, 5), currentNForRun("1.3.2-dev-win.5", null, false));
    try testing.expectEqual(@as(?u32, null), currentNForRun("1.3.2-dev", "x", true));
}

test "win32 update: parseUrl" {
    const e = parseUrl(release.endpoint).?;
    try testing.expect(e.secure);
    try testing.expectEqualStrings("api.github.com", e.host);
    try testing.expectEqual(@as(u16, 443), e.port);
    try testing.expectEqualStrings("/repos/Denmurzik/ghostty/releases?per_page=20", e.path);
    const l = parseUrl("http://127.0.0.1:5000/x").?;
    try testing.expect(!l.secure);
    try testing.expectEqual(@as(u16, 5000), l.port);
    try testing.expect(parseUrl("ftp://a/") == null);
    try testing.expect(parseUrl("http://a:0/") == null);
    try testing.expect(parseUrl("http:///x") == null);
}

test "win32 update: result handling" {
    // Automatic: a toast for a new release, nothing else, never a dialog.
    try testing.expectEqual(Plan{ .toast = true, .dialog = .none }, plan(false, .newer, true));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .none }, plan(false, .newer, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .none }, plan(false, .current, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .none }, plan(false, .local, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .none }, plan(false, .failed, false));
    // Manual: always a dialog; the toast only when not announced yet.
    try testing.expectEqual(Plan{ .toast = true, .dialog = .available }, plan(true, .newer, true));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .available }, plan(true, .newer, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .current }, plan(true, .current, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .local }, plan(true, .local, false));
    try testing.expectEqual(Plan{ .toast = false, .dialog = .failed }, plan(true, .failed, false));
}

var closed_calls: u32 = 0;
var closed_handle: usize = 0;
fn fakeClose(h: usize) void {
    closed_calls += 1;
    closed_handle = h;
}

test "win32 update: deadline closes the request" {
    const saved = closeHook;
    defer closeHook = saved;
    closeHook = fakeClose;
    closed_calls = 0;

    var st: State = .{};
    const shared = try Shared.create(testing.allocator, false);
    defer {
        shared.release();
        shared.release();
    }
    shared.request.store(0x1234, .seq_cst);
    st.deadline_ms = 10_000;

    // Before the deadline nothing happens.
    try testing.expect(!deadlineExpired(&st, shared, 9_999));
    try testing.expectEqual(@as(u32, 0), closed_calls);
    // After it the handle is closed once, however often the timer fires.
    try testing.expect(deadlineExpired(&st, shared, 10_000));
    try testing.expect(!deadlineExpired(&st, shared, 10_250));
    try testing.expectEqual(@as(u32, 1), closed_calls);
    try testing.expectEqual(@as(usize, 0x1234), closed_handle);
    try testing.expect(shared.timed_out.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), shared.request.load(.seq_cst));
}

fn lateWorker(shared: *Shared, delay_ms: u32) void {
    win32.kernel32.Sleep(delay_ms);
    // Like the real worker: only its own block, `done` then the release.
    shared.done.store(true, .seq_cst);
    shared.release();
}

test "win32 update: a late worker outlives stop and frees its block" {
    var slot: ?*Shared = try Shared.create(testing.allocator, false);
    const shared = slot.?;
    const thread = try std.Thread.spawn(.{}, lateWorker, .{ shared, 400 });

    // The budget runs out long before the worker is done.
    try testing.expect(!stopShared(&slot, 40));
    try testing.expect(slot == null);
    try testing.expect(shared.stopping.load(.seq_cst));
    // The app's side is gone; the worker still has the block and then frees
    // it (the testing allocator reports a leak or a double free).
    try testing.expect(!shared.done.load(.seq_cst));
    thread.join();
}

test "win32 update: a worker that is out in time" {
    var slot: ?*Shared = try Shared.create(testing.allocator, false);
    const thread = try std.Thread.spawn(.{}, lateWorker, .{ slot.?, 0 });
    thread.join();
    try testing.expect(stopShared(&slot, 100));
    try testing.expect(slot == null);
}
