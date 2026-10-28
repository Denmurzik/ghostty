//! Taskbar jump list: New Window, New Tab and one task per shell profile,
//! plus the `+new-tab` fallback that starts Ghostty when none runs.
//!
//! Tasks only, no custom category: a category is refused (E_ACCESSDENIED)
//! when the user turned recent items off, tasks are not. The UI thread
//! builds `[]Item` into one heap block and hands it to a worker thread
//! (STA); the worker never reads App state. The list is keyed by the
//! AppUserModelID of the toasts, or by a test AUMID in test mode, so that a
//! test never leaves a link to a test exe on the real taskbar.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const windows_cmdline = @import("../../os/windows_cmdline.zig");
const windows_shell = @import("../../os/windows_shell.zig");
const App = @import("App.zig");
const messages = @import("messages.zig");
const notify = @import("notify.zig");
const profiles = @import("profiles.zig");
const ipc_ops = @import("ipc/ops.zig");

const Config = configpkg.Config;
const shobjidl = win32.shobjidl;
const foundation = win32.foundation;
const com = win32.com;

const log = std.log.scoped(.jumplist);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// How long after start, a profile change or a config reload the list is
/// rebuilt: the burst of changes at startup becomes one build.
const build_delay_ms = 2000;
/// How long `stop` waits for the worker; a COM call stuck in Explorer must
/// not hang quit.
const stop_wait_ms = 2000;
/// Retry delay when the previous worker still runs.
const busy_retry_ms = 500;

pub const Item = struct {
    kind: enum { task, separator },
    title: []const u8,
    args: []const u8,
    icon_path: []const u8,
    icon_index: i32,
};

/// The AppUserModelID of the list: the toasts' one, or the test one.
pub fn aumidForRun() [:0]const u16 {
    return if (ipc_ops.testOpsEnabled()) L(notify.aumid ++ ".e2e") else L(notify.aumid);
}

/// Only characters that need no quoting on a command line (the profile id
/// charset of R-M5-1 plus the argument syntax).
fn argSafe(s: []const u8) bool {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-', ':', '=', '+' => {},
        else => return false,
    };
    return true;
}

/// New Window, New Tab, a separator, then a task per profile except
/// `Default`. `alloc` is an arena: every string is copied into it and the
/// caller frees the whole block at once.
pub fn buildItems(alloc: Allocator, exe: []const u8, class: ?[]const u8, profile_list: []const windows_shell.Profile) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    const exe_copy = try alloc.dupe(u8, exe);
    // The class selects the instance: with a configured `class` the tasks
    // must name it, or New Tab finds no server and starts a second Ghostty.
    const class_arg: []const u8 = if (class) |c| blk: {
        const arg = try std.fmt.allocPrint(alloc, "--class={s}", .{c});
        if (argSafe(arg)) break :blk arg;
        log.warn("class {s} cannot be a task argument", .{c});
        break :blk "";
    } else "";
    const sep: []const u8 = if (class_arg.len > 0) " " else "";
    try items.append(alloc, .{ .kind = .task, .title = "New Window", .args = class_arg, .icon_path = exe_copy, .icon_index = 0 });
    try items.append(alloc, .{
        .kind = .task,
        .title = "New Tab",
        .args = try std.fmt.allocPrint(alloc, "+new-tab {s}{s}--working-directory=home", .{ class_arg, sep }),
        .icon_path = exe_copy,
        .icon_index = 0,
    });
    try items.append(alloc, .{ .kind = .separator, .title = "", .args = "", .icon_path = "", .icon_index = 0 });
    for (profile_list) |p| {
        if (p.kind == .default) continue;
        const args = try std.fmt.allocPrint(alloc, "--profile={s}{s}{s}", .{ p.id, sep, class_arg });
        if (!argSafe(p.id) or p.name.len == 0) {
            log.warn("skipping profile {s}: not representable as a task", .{p.id});
            continue;
        }
        try items.append(alloc, .{
            .kind = .task,
            .title = try alloc.dupe(u8, p.name),
            .args = args,
            .icon_path = if (p.icon.len > 0) try alloc.dupe(u8, p.icon) else exe_copy,
            .icon_index = 0,
        });
    }
    return items.items;
}

/// The command line of the instance that `+new-tab` starts when none runs:
/// the class and every argument IPC would forward (all but `--class=` and
/// `--surface-id=`). `alloc` is an arena (the class argument is allocated).
pub fn fallbackArgv(alloc: Allocator, exe: []const u8, class: ?[]const u8, args: []const [:0]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, exe);
    if (class) |c| try argv.append(alloc, try std.fmt.allocPrint(alloc, "--class={s}", .{c}));
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--class=") or std.mem.startsWith(u8, a, "--surface-id=")) continue;
        try argv.append(alloc, a);
    }
    return argv.items;
}

// -- Worker ---------------------------------------------------------------------------

const hr_unset = std.math.minInt(i64);

const Job = struct {
    arena: std.heap.ArenaAllocator,
    mode: enum { build, delete },
    exe: []const u8,
    home: []const u8,
    items: []const Item,
    aumid: [:0]const u16,
    test_mode: bool,
    done: foundation.HANDLE,
};

var worker: ?std.Thread = null;
var done_event: ?foundation.HANDLE = null;
var enabled: bool = true;
var off_deleted: bool = false;
var last_sig: ?u64 = null;
var titles: ?[]u8 = null;
var title_alloc: ?Allocator = null;

var hr_delete: std.atomic.Value(i64) = .init(hr_unset);
var hr_begin: std.atomic.Value(i64) = .init(hr_unset);
var hr_commit: std.atomic.Value(i64) = .init(hr_unset);
var runs: std.atomic.Value(u32) = .init(0);

fn hrOf(hr: foundation.HRESULT) i64 {
    return hr;
}

fn create(comptime T: type, clsid: *const foundation.GUID) foundation.Error!*T {
    var out: ?*anyopaque = null;
    try foundation.check(win32.ole32.CoCreateInstance(clsid, null, win32.ole32.CLSCTX_INPROC_SERVER, &T.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

fn workerMain(job: *Job) void {
    const done = job.done;
    const init_hr = win32.ole32.CoInitializeEx(null, win32.ole32.COINIT_APARTMENTTHREADED);
    const inited = foundation.succeeded(init_hr);
    run(job) catch |err| {
        log.warn("jump list failed err={}", .{err});
        _ = hr_commit.cmpxchgStrong(hr_unset, foundation.E_FAIL, .release, .monotonic);
    };
    if (inited) win32.ole32.CoUninitialize();
    var arena = job.arena;
    arena.deinit();
    _ = runs.fetchAdd(1, .release);
    _ = win32.kernel32.SetEvent(done);
}

fn run(job: *Job) !void {
    const alloc = job.arena.allocator();
    const list = try create(shobjidl.ICustomDestinationList, &shobjidl.CLSID_DestinationList);
    defer com.release(list);

    if (job.mode == .delete or job.test_mode) {
        const hr = list.vtable.DeleteList(list, job.aumid.ptr);
        hr_delete.store(hrOf(hr), .release);
        const code: u32 = @bitCast(hr);
        if (job.test_mode) {
            log.info("{s} e2e list hr=0x{x}", .{ if (job.mode == .delete) "deleted" else "reset", code });
        } else {
            log.info("deleted the jump list hr=0x{x}", .{code});
        }
        if (job.mode == .delete) return;
    }

    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, job.exe);
    const home_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, job.home);

    list.setAppId(job.aumid.ptr) catch |err| {
        log.warn("SetAppID failed", .{});
        return err;
    };

    var min_slots: u32 = 0;
    var removed: ?*anyopaque = null;
    const begin_hr = list.vtable.BeginList(list, &min_slots, &shobjidl.IID_IObjectArray, &removed);
    hr_begin.store(hrOf(begin_hr), .release);
    if (!foundation.succeeded(begin_hr)) return;
    // The list has tasks only; what the user removed is of no interest.
    if (removed) |r| com.release(@as(*shobjidl.IObjectArray, @ptrCast(@alignCast(r))));
    var committed = false;
    defer if (!committed) list.abortList();

    const coll = try create(shobjidl.IObjectCollection, &shobjidl.CLSID_EnumerableObjectCollection);
    defer com.release(coll);
    for (job.items) |item| {
        const link = makeLink(alloc, item, exe_w, home_w) catch |err| {
            log.warn("makeLink {s} failed", .{item.title});
            return err;
        };
        defer com.release(link);
        try coll.addObject(link);
    }
    const array = try com.queryInterface(coll, shobjidl.IObjectArray);
    defer com.release(array);
    try list.addUserTasks(array);

    const commit_hr = list.vtable.CommitList(list);
    hr_commit.store(hrOf(commit_hr), .release);
    committed = foundation.succeeded(commit_hr);
}

fn makeLink(alloc: Allocator, item: Item, exe_w: [:0]const u16, home_w: [:0]const u16) !*shobjidl.IShellLinkW {
    const link = try create(shobjidl.IShellLinkW, &shobjidl.CLSID_ShellLink);
    errdefer com.release(link);

    switch (item.kind) {
        .task => {
            try link.setPath(exe_w.ptr);
            const args_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, item.args);
            try link.setArguments(args_w.ptr);
            try link.setWorkingDirectory(home_w.ptr);
            const icon_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, item.icon_path);
            try link.setIconLocation(icon_w.ptr, item.icon_index);
            const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, item.title);
            const store = try com.queryInterface(link, shobjidl.IPropertyStore);
            defer com.release(store);
            var pv = try shobjidl.PROPVARIANT.fromString(title_w);
            defer pv.clear();
            try store.setValue(&shobjidl.PKEY_Title, &pv);
            try store.commit();
        },
        .separator => {
            const store = try com.queryInterface(link, shobjidl.IPropertyStore);
            defer com.release(store);
            var pv = shobjidl.PROPVARIANT.fromBool(true);
            try store.setValue(&shobjidl.PKEY_AppUserModel_IsDestListSeparator, &pv);
            try store.commit();
        },
    }
    return link;
}

// -- UI thread -------------------------------------------------------------------------

/// Copies everything the worker needs into one arena on `backing`; the Job
/// lives in that arena. `job.arena` is assigned after the last allocation, so
/// it is the arena that owns every node. Free with `freeJob`.
fn prepareJob(
    backing: Allocator,
    mode: @FieldType(Job, "mode"),
    src: []const Item,
    exe: []const u8,
    home: []const u8,
    test_mode: bool,
    done: foundation.HANDLE,
) Allocator.Error!*Job {
    var arena: std.heap.ArenaAllocator = .init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();
    const job = try a.create(Job);
    const items = try a.alloc(Item, src.len);
    for (src, items) |s, *d| d.* = .{
        .kind = s.kind,
        .title = try a.dupe(u8, s.title),
        .args = try a.dupe(u8, s.args),
        .icon_path = try a.dupe(u8, s.icon_path),
        .icon_index = s.icon_index,
    };
    job.* = .{
        .arena = undefined,
        .mode = mode,
        .exe = try a.dupe(u8, exe),
        .home = try a.dupe(u8, home),
        .items = items,
        .aumid = aumidForRun(),
        .test_mode = test_mode,
        .done = done,
    };
    job.arena = arena;
    return job;
}

fn freeJob(job: *Job) void {
    var arena = job.arena;
    arena.deinit();
}

/// Starts the worker for `job`-to-be. False when it could not be started.
fn spawn(app: *App, mode: @FieldType(Job, "mode"), items_from: ?[]const Item) bool {
    const alloc = app.core_app.alloc;
    const ev = win32.kernel32.CreateEventW(null, 1, 0, null) orelse {
        log.warn("CreateEvent failed err={}", .{win32.kernel32.GetLastError()});
        return false;
    };

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var exe: []const u8 = "";
    var home: []const u8 = "";
    defer if (home.len > 0) alloc.free(home);
    if (mode == .build) {
        const exe_len = std.process.executablePath(global.io(), &exe_buf) catch return failEvent(ev);
        exe = exe_buf[0..exe_len];
        home = global.environ().getAlloc(alloc, "USERPROFILE") catch return failEvent(ev);
    }
    const job = prepareJob(std.heap.page_allocator, mode, items_from orelse &.{}, exe, home, ipc_ops.testOpsEnabled(), ev) catch return failEvent(ev);

    hr_delete.store(hr_unset, .release);
    hr_begin.store(hr_unset, .release);
    hr_commit.store(hr_unset, .release);

    // The titles the state reports belong to this job.
    freeTitles();
    if (mode == .build) setTitles(alloc, job.items);

    worker = std.Thread.spawn(.{}, workerMain, .{job}) catch |err| {
        log.warn("unable to start the jump list worker err={}", .{err});
        freeJob(job);
        return failEvent(ev);
    };
    done_event = ev;
    return true;
}

fn failEvent(ev: foundation.HANDLE) bool {
    _ = win32.kernel32.CloseHandle(ev);
    return false;
}

fn setTitles(alloc: Allocator, items: []const Item) void {
    var buf: std.ArrayList(u8) = .empty;
    for (items) |item| {
        const t = if (item.kind == .separator) "-" else item.title;
        buf.appendSlice(alloc, t) catch return buf.deinit(alloc);
        buf.append(alloc, '\n') catch return buf.deinit(alloc);
    }
    titles = buf.toOwnedSlice(alloc) catch return buf.deinit(alloc);
    title_alloc = alloc;
}

fn freeTitles() void {
    if (titles) |t| title_alloc.?.free(t);
    titles = null;
}

/// True when no worker runs (it was reaped if it had ended).
fn reap() bool {
    const w = worker orelse return true;
    const ev = done_event.?;
    if (win32.kernel32.WaitForSingleObjectEx(ev, 0, 0) != 0) return false;
    w.join();
    _ = win32.kernel32.CloseHandle(ev);
    worker = null;
    done_event = null;
    return true;
}

fn arm(app: *App, ms: u32) void {
    if (win32.user32.SetTimer(app.msg_hwnd, messages.timers.msg_window.jumplist_delay, ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
    }
}

/// The end of `App.init`.
pub fn schedule(app: *App) void {
    enabled = app.config.@"windows-jump-list";
    arm(app, build_delay_ms);
}

/// The profile list changed.
pub fn profilesChanged(app: *App) void {
    arm(app, build_delay_ms);
}

pub fn configChanged(app: *App, config: *const Config) void {
    enabled = config.@"windows-jump-list";
    arm(app, build_delay_ms);
}

pub fn stop(app: *App) void {
    _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.jumplist_delay);
    if (!waitWorker()) return;
    // A test must not leave a list that points at a test exe.
    if (ipc_ops.testOpsEnabled() and spawn(app, .delete, null)) _ = waitWorker();
    freeTitles();
}

/// Waits up to `stop_wait_ms` for the worker; false (and the worker leaked)
/// when it does not end.
fn waitWorker() bool {
    const w = worker orelse return true;
    const ev = done_event.?;
    if (win32.kernel32.WaitForSingleObjectEx(ev, stop_wait_ms, 0) != 0) {
        log.warn("the jump list worker does not end, leaving it", .{});
        w.detach();
        worker = null;
        done_event = null;
        return false;
    }
    return reap();
}

/// The `+new-tab` fallback when no instance runs; true when it handled the call.
pub fn newTabFallback(alloc: Allocator, class: ?[]const u8, args: []const [:0]const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
        log.warn("+new-tab: unable to find the own executable err={}", .{err});
        return false;
    };
    return startDetached(a, exe_buf[0..exe_len], class, args) catch |err| {
        log.warn("+new-tab: unable to start Ghostty err={}", .{err});
        return false;
    };
}

fn startDetached(a: Allocator, exe: []const u8, class: ?[]const u8, args: []const [:0]const u8) !bool {
    const windows = internal_os.windows;
    const argv = try fallbackArgv(a, exe, class, args);
    const cmd = try windows_cmdline.createCommandLine(a, argv);
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(a, cmd);

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;
    const detached_process = 0x00000008;
    const new_process_group = 0x00000200;
    if (windows.exp.kernel32.CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        detached_process | new_process_group,
        null,
        null,
        &si,
        &pi,
    ) == windows.FALSE) return error.CreateProcessFailed;
    _ = windows.exp.kernel32.CloseHandle(pi.hThread);
    _ = windows.exp.kernel32.CloseHandle(pi.hProcess);
    return true;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.objectField("enabled");
    try jw.write(enabled);
    try jw.objectField("running");
    try jw.write(worker != null);
    try jw.objectField("runs");
    try jw.write(runs.load(.acquire));
    inline for (.{ .{ "hr_delete", &hr_delete }, .{ "hr_begin", &hr_begin }, .{ "hr_commit", &hr_commit } }) |f| {
        try jw.objectField(f[0]);
        const v = f[1].load(.acquire);
        if (v == hr_unset) try jw.write(null) else try jw.write(@as(i32, @truncate(v)));
    }
    try jw.objectField("titles");
    try jw.beginArray();
    if (titles) |t| {
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |line| {
            if (line.len > 0) try jw.write(line);
        }
    }
    try jw.endArray();
    try jw.endObject();
}

/// The `jumplist_delay` timer fired.
pub fn onTimer(app: *App) void {
    _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.jumplist_delay);
    if (!app.serving()) return;
    if (!reap()) return arm(app, busy_retry_ms);

    if (!enabled) {
        // Turning the key off removes the list once.
        if (!off_deleted and spawn(app, .delete, null)) {
            off_deleted = true;
            last_sig = null;
        }
        return;
    }
    off_deleted = false;

    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
        log.warn("unable to find the own executable err={}", .{err});
        return;
    };
    const items = buildItems(a, exe_buf[0..exe_len], app.config.class, profiles.get(app)) catch return;
    const sig = signature(items);
    if (last_sig) |s| if (s == sig) return;
    if (spawn(app, .build, items)) last_sig = sig;
}

fn signature(items: []const Item) u64 {
    var h = std.hash.Wyhash.init(0);
    for (items) |item| {
        h.update(&.{@backingInt(item.kind)});
        h.update(item.title);
        h.update("\x00");
        h.update(item.args);
        h.update("\x00");
        h.update(item.icon_path);
        h.update("\x00");
    }
    return h.final();
}

// -- Tests -----------------------------------------------------------------------------

fn testProfile(id: []const u8, name: []const u8, kind: @FieldType(windows_shell.Profile, "kind"), icon: []const u8) windows_shell.Profile {
    return .{ .id = id, .name = name, .kind = kind, .argv = &.{}, .icon = icon };
}

test "win32 jumplist: tasks, separator, profile tasks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]windows_shell.Profile{
        testProfile("default", "Default", .default, ""),
        testProfile("git-bash", "Git Bash", .git_bash, "C:\\Git\\bin\\bash.exe"),
        testProfile("wsl:Ubuntu", "Ubuntu", .wsl, "C:\\Windows\\System32\\wsl.exe"),
    };
    const items = try buildItems(arena.allocator(), "C:\\g\\ghostty.exe", null, &list);
    try std.testing.expectEqual(@as(usize, 5), items.len);

    try std.testing.expectEqualStrings("New Window", items[0].title);
    try std.testing.expectEqualStrings("", items[0].args);
    try std.testing.expectEqualStrings("C:\\g\\ghostty.exe", items[0].icon_path);
    try std.testing.expectEqualStrings("New Tab", items[1].title);
    try std.testing.expectEqualStrings("+new-tab --working-directory=home", items[1].args);
    try std.testing.expectEqual(.separator, items[2].kind);
    try std.testing.expectEqualStrings("Git Bash", items[3].title);
    try std.testing.expectEqualStrings("--profile=git-bash", items[3].args);
    try std.testing.expectEqualStrings("C:\\Git\\bin\\bash.exe", items[3].icon_path);
    try std.testing.expectEqualStrings("Ubuntu", items[4].title);
    try std.testing.expectEqualStrings("--profile=wsl:Ubuntu", items[4].args);
}

test "win32 jumplist: args need no quoting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]windows_shell.Profile{
        testProfile("wsl:Ubuntu-22.04", "Ubuntu 22.04", .wsl, "C:\\Windows\\System32\\wsl.exe"),
        testProfile("wsl:bad name", "Bad", .wsl, ""),
        testProfile("wsl:q\"uote", "Quote", .wsl, ""),
    };
    const items = try buildItems(arena.allocator(), "C:\\Program Files\\Ghostty\\ghostty.exe", null, &list);
    try std.testing.expectEqual(@as(usize, 4), items.len);
    for (items) |item| {
        // Each space-separated token is one argument that needs no quoting.
        var it = std.mem.tokenizeScalar(u8, item.args, ' ');
        while (it.next()) |tok| {
            const cmd = try windows_cmdline.createCommandLine(arena.allocator(), &.{tok});
            try std.testing.expectEqualStrings(tok, cmd);
        }
    }
}

test "win32 jumplist: fallback keeps class, cwd and profile" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "--working-directory=home", "--profile=cmd", "--surface-id=3", "--font-size=40" };

    const with_class = try fallbackArgv(arena.allocator(), "C:\\g\\ghostty.exe", "x.e2e", &args);
    try std.testing.expectEqual(@as(usize, 5), with_class.len);
    try std.testing.expectEqualStrings("C:\\g\\ghostty.exe", with_class[0]);
    try std.testing.expectEqualStrings("--class=x.e2e", with_class[1]);
    try std.testing.expectEqualStrings("--working-directory=home", with_class[2]);
    try std.testing.expectEqualStrings("--profile=cmd", with_class[3]);
    try std.testing.expectEqualStrings("--font-size=40", with_class[4]);

    const no_class = try fallbackArgv(arena.allocator(), "C:\\g\\ghostty.exe", null, &args);
    try std.testing.expectEqual(@as(usize, 4), no_class.len);
    try std.testing.expectEqualStrings("--working-directory=home", no_class[1]);
}

test "win32 jumplist: tasks carry the configured class" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]windows_shell.Profile{testProfile("cmd", "Command Prompt", .cmd, "")};
    const items = try buildItems(arena.allocator(), "C:\\g\\ghostty.exe", "my.class", &list);
    try std.testing.expectEqualStrings("--class=my.class", items[0].args);
    try std.testing.expectEqualStrings("+new-tab --class=my.class --working-directory=home", items[1].args);
    try std.testing.expectEqualStrings("--profile=cmd --class=my.class", items[3].args);

    // A class that would need quoting is left out.
    const odd = try buildItems(arena.allocator(), "C:\\g\\ghostty.exe", "a b", &list);
    try std.testing.expectEqualStrings("", odd[0].args);
    try std.testing.expectEqualStrings("+new-tab --working-directory=home", odd[1].args);
}

test "win32 jumplist: a job frees all of its memory with job.arena" {
    // testing.allocator reports a leak if a node is lost to a stale arena copy.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]windows_shell.Profile{
        testProfile("git-bash", "Git Bash", .git_bash, "C:\\Git\\bin\\bash.exe"),
        testProfile("cmd", "Command Prompt", .cmd, "C:\\Windows\\System32\\cmd.exe"),
    };
    const items = try buildItems(arena.allocator(), "C:\\g\\ghostty.exe", "x", &list);
    const job = try prepareJob(std.testing.allocator, .build, items, "C:\\g\\ghostty.exe", "C:\\Users\\u", false, undefined);
    try std.testing.expectEqual(items.len, job.items.len);
    try std.testing.expectEqualStrings("C:\\Users\\u", job.home);
    // The worker allocates from the same arena.
    _ = try job.arena.allocator().alloc(u8, 100_000);
    _ = try job.arena.allocator().alloc(u8, 100_000);
    freeJob(job);
}

test "win32 jumplist: aumid follows the mode" {
    const a = aumidForRun();
    try std.testing.expect(a.len > 0);
}
