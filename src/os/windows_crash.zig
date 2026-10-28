//! Windows crash minidumps.
//!
//! An unhandled-exception filter hands the exception to a dedicated dump
//! thread, which writes `<state base>\ghostty\crash\ghostty-<pid>-<tick>.dmp`
//! (the state base is `XDG_STATE_HOME` if set, else `%LOCALAPPDATA%`: the same
//! rule `+crash-report` uses, see `stateBase`)
//! with `MiniDumpWriteDump`. The thread exists because the crashing thread
//! may be out of stack (stack overflow) or hold arbitrary locks. All the
//! heavy state (the `dbghelp.dll` module, the dump path prefix, the events)
//! is prepared at install time, so the filter itself allocates nothing and
//! takes no lock apart from the one-shot gate.
//!
//! The dump is `Normal | WithThreadInfo | WithUnloadedModules | FilterMemory`.
//! `MiniDumpFilterMemory` reduces stack contents to the pointer values a
//! stack walk needs, and no heap is included, so the pty reader's buffer and
//! the screen are not in a dump. Register contents of every thread are kept
//! and can hold small fragments of recent text. Dumps stay local and are never
//! uploaded; the 10 newest are kept. A dump is written as `.dmp.tmp` and
//! renamed when complete, so a timeout never leaves a truncated `.dmp`.
//!
//! Zig's own segfault handler is disabled on Windows (see `main_ghostty.zig`),
//! otherwise its vectored handler would print and abort before this filter
//! ever ran.
//!
//! Known limit: a crash while the process heap lock is held makes
//! `MiniDumpWriteDump` block; the filter gives up after 10 s with no dump. A
//! crash on the dump thread itself writes no dump either.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const windows_log = @import("windows_log.zig");

const log = std.log.scoped(.windows_crash);

const is_windows = builtin.os.tag == .windows;

const win = std.os.windows;
const HANDLE = win.HANDLE;
const DWORD = win.DWORD;
const BOOL = win.BOOL;

pub const MiniDumpNormal: u32 = 0x00000000;
pub const MiniDumpWithFullMemory: u32 = 0x00000002;
pub const MiniDumpFilterMemory: u32 = 0x00000008;
pub const MiniDumpWithUnloadedModules: u32 = 0x00000020;
pub const MiniDumpWithIndirectlyReferencedMemory: u32 = 0x00000040;
pub const MiniDumpWithThreadInfo: u32 = 0x00001000;

/// The dump type. No heap, no indirect memory, stacks reduced to pointers.
pub const dump_type: u32 = MiniDumpNormal |
    MiniDumpWithThreadInfo |
    MiniDumpWithUnloadedModules |
    MiniDumpFilterMemory;

/// How many dumps survive the prune at start.
const keep_dumps: usize = 10;

/// How long a crashing thread waits for the dump before giving up.
const filter_wait_ms: DWORD = 10_000;

const EXCEPTION_EXECUTE_HANDLER: c_long = 1;

const Exp = if (is_windows) struct {
    const ExceptionFilter = *const fn (?*anyopaque) callconv(.winapi) c_long;
    const ThreadProc = *const fn (?*anyopaque) callconv(.winapi) DWORD;

    extern "kernel32" fn SetUnhandledExceptionFilter(f: ?ExceptionFilter) callconv(.winapi) ?ExceptionFilter;
    extern "kernel32" fn CreateEventW(a: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn CreateThread(a: ?*anyopaque, stack: usize, start: ThreadProc, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?HANDLE, flags: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetProcAddress(m: HANDLE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    /// `MINIDUMP_EXCEPTION_INFORMATION` is declared under `pshpack4.h`.
    const ExceptionInfo = extern struct {
        thread_id: DWORD align(4),
        exception_pointers: ?*anyopaque align(4),
        client_pointers: BOOL align(4),
    };

    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
    extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileMappingW(h: HANDLE, a: ?*anyopaque, protect: DWORD, hi: DWORD, lo: DWORD, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(m: HANDLE, access: DWORD, hi: DWORD, lo: DWORD, bytes: usize) callconv(.winapi) ?[*]u8;
    extern "kernel32" fn FlushViewOfFile(base: [*]const u8, bytes: usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UnmapViewOfFile(base: [*]const u8) callconv(.winapi) BOOL;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;

    /// The head of `EXCEPTION_POINTERS` / `EXCEPTION_RECORD`.
    const ExceptionRecord = extern struct {
        code: DWORD,
        flags: DWORD,
        chained: ?*anyopaque,
        address: ?*anyopaque,
    };
    const ExceptionPointers = extern struct {
        record: ?*const ExceptionRecord,
        context: ?*anyopaque,
    };

    const MiniDumpWriteDumpFn = *const fn (
        process: HANDLE,
        pid: DWORD,
        file: HANDLE,
        kind: u32,
        exception: ?*const ExceptionInfo,
        user_stream: ?*anyopaque,
        callback: ?*anyopaque,
    ) callconv(.winapi) BOOL;
} else struct {};

/// State shared by the filter and the dump thread. It is set up by
/// `install` and only read by the filter; nothing here is allocated later.
const State = struct {
    /// Dump path prefix `<dir>\ghostty-<pid>-`, UTF-16, no terminator.
    prefix: [600]u16 = undefined,
    prefix_len: usize = 0,
    /// The crash directory, UTF-16, null-terminated, for `CreateDirectoryW`.
    dir_len: usize = 0,

    /// Set by the dump thread once `MiniDumpWriteDump` is resolved.
    write_dump: ?Exp.MiniDumpWriteDumpFn = null,

    /// Manual-reset events: `trigger` wakes the dump thread, `done` is set
    /// when it has finished (and stays set).
    trigger: ?HANDLE = null,
    done: ?HANDLE = null,

    /// Exception handed over by the filter (null for the panic path).
    info: Exp.ExceptionInfo = undefined,

    /// Thread id of the dump thread; a crash there must not wait for itself.
    dump_thread_id: std.atomic.Value(u32) = .init(0),

    /// The first crash takes the gate; later ones just wait.
    gate: std.atomic.Value(u32) = .init(0),
};

var state: State = .{};

/// 0 = not installed, 1 = installing, 2 = installed.
var install_state: std.atomic.Value(u32) = .init(0);

/// Why `install` failed, for `ensureInstalled` to log once the log is open.
var install_error: ?[]const u8 = null;

/// The ours-replaced warning is logged once.
var replaced_logged: std.atomic.Value(bool) = .init(false);

/// The directory dumps live under: `XDG_STATE_HOME` when non-empty, else
/// `LOCALAPPDATA`. Same rule as `os.xdg.state` on Windows, so `+crash-report`
/// finds what this module writes.
pub fn stateBase(xdg_state_home: []const u8, local_app_data: []const u8) []const u8 {
    return if (xdg_state_home.len > 0) xdg_state_home else local_app_data;
}

/// Install the filter and start the dump thread. `state_base` is the state
/// base directory (UTF-8, see `stateBase`). Safe to call more than once. Failures
/// are logged and leave dumping disabled; they are never fatal.
pub fn install(state_base: []const u8) void {
    if (comptime !is_windows) return;
    if (install_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;

    installInner(state_base) catch |err| {
        // The log file is usually not open yet; `ensureInstalled` reports it.
        install_error = @errorName(err);
        log.warn("crash dumps disabled err={}", .{err});
        install_state.store(0, .release);
        return;
    };
    install_state.store(2, .release);
}

/// `install` with the state base read from the process environment.
pub fn installFromEnv() void {
    if (comptime !is_windows) return;
    const GetEnvironmentVariableW = struct {
        extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: DWORD) callconv(.winapi) DWORD;
    }.GetEnvironmentVariableW;

    var xdg8: [1560]u8 = undefined;
    var lad8: [1560]u8 = undefined;
    const xdg = envUtf8(GetEnvironmentVariableW, "XDG_STATE_HOME", &xdg8);
    const lad = envUtf8(GetEnvironmentVariableW, "LOCALAPPDATA", &lad8);
    install(stateBase(xdg, lad));
}

fn envUtf8(get: anytype, comptime name: []const u8, out: []u8) []const u8 {
    var wbuf: [520]u16 = undefined;
    const n = get(std.unicode.utf8ToUtf16LeStringLiteral(name), &wbuf, wbuf.len);
    if (n == 0 or n >= wbuf.len) return "";
    const len = std.unicode.utf16LeToUtf8(out, wbuf[0..n]) catch return "";
    return out[0..len];
}

fn installInner(state_base: []const u8) !void {
    if (state_base.len == 0) return error.NoStateBase;

    // `<LAD>\ghostty\crash\ghostty-<pid>-` into the static prefix.
    var utf8: [1100]u8 = undefined;
    const dir8 = std.fmt.bufPrint(&utf8, "{s}\\ghostty\\crash", .{
        std.mem.trimEnd(u8, state_base, "\\/"),
    }) catch return error.PathTooLong;
    // Room for the prefix tail (\ghostty-<pid>-) and the ".dmp.tmp" suffix.
    const need = std.unicode.calcUtf16LeLen(dir8) catch return error.InvalidPath;
    if (need + 64 > state.prefix.len) return error.PathTooLong;
    const dir_len = try std.unicode.utf8ToUtf16Le(&state.prefix, dir8);
    // Windows wants backslashes for CreateDirectoryW.
    for (state.prefix[0..dir_len]) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    state.dir_len = dir_len;

    var tail: [48]u8 = undefined;
    const tail8 = try std.fmt.bufPrint(&tail, "\\ghostty-{d}-", .{Exp.GetCurrentProcessId()});
    state.prefix_len = dir_len + try std.unicode.utf8ToUtf16Le(state.prefix[dir_len..], tail8);

    state.trigger = Exp.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;
    state.done = Exp.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;

    const thread = Exp.CreateThread(null, 64 * 1024, dumpThread, null, 0, null) orelse
        return error.ThreadFailed;
    _ = Exp.CloseHandle(thread);

    _ = Exp.SetUnhandledExceptionFilter(&filter);
}

/// Re-install the filter if another module replaced it. Logs once.
pub fn ensureInstalled() void {
    if (comptime !is_windows) return;
    if (install_state.load(.acquire) != 2) {
        if (install_error) |e| {
            install_error = null;
            log.warn("crash dumps disabled err={s}", .{e});
        }
        return;
    }
    const prev = Exp.SetUnhandledExceptionFilter(&filter);
    if (prev != null and prev.? == &filter) return;
    if (!replaced_logged.swap(true, .acq_rel)) {
        log.warn("unhandled exception filter was replaced, reinstalled", .{});
    }
}

/// Ask for a dump from the panic path: no exception record, the caller is
/// the thread of interest. Returns when the dump is written or after 10 s.
pub fn dumpNow() void {
    if (comptime !is_windows) return;
    if (install_state.load(.acquire) != 2) return;
    request(null);
}

/// Hand an exception (or null) to the dump thread and wait for it.
fn request(exception_pointers: ?*anyopaque) void {
    const done = state.done orelse return;
    // A crash on the dump thread would wait for itself: give up at once.
    if (Exp.GetCurrentThreadId() == state.dump_thread_id.load(.acquire)) return;
    if (state.gate.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        // Somebody else is already dumping; wait for them.
        _ = Exp.WaitForSingleObject(done, filter_wait_ms);
        return;
    }
    state.info = .{
        .thread_id = Exp.GetCurrentThreadId(),
        .exception_pointers = exception_pointers,
        .client_pointers = .FALSE,
    };
    _ = Exp.SetEvent(state.trigger orelse return);
    if (Exp.WaitForSingleObject(done, filter_wait_ms) != 0) {
        logCrash("crash dump timed out after {d} s, no dump", .{filter_wait_ms / 1000});
    }
}

fn filter(exception_pointers: ?*anyopaque) callconv(.winapi) c_long {
    request(exception_pointers);
    // No WER dialog: the process ends here with the exception code.
    return EXCEPTION_EXECUTE_HANDLER;
}

fn dumpThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    state.dump_thread_id.store(Exp.GetCurrentThreadId(), .release);
    prepare();

    const trigger = state.trigger orelse return 0;
    _ = Exp.WaitForSingleObject(trigger, 0xFFFFFFFF);

    writeDump();
    _ = Exp.SetEvent(state.done orelse return 0);
    return 0;
}

/// Resolve dbghelp and prune old dumps, off the main thread.
fn prepare() void {
    const flags: DWORD = 0x800; // LOAD_LIBRARY_SEARCH_SYSTEM32
    if (Exp.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("dbghelp.dll"), null, flags)) |m| {
        if (Exp.GetProcAddress(m, "MiniDumpWriteDump")) |p| {
            state.write_dump = @ptrCast(@alignCast(p));
        }
    }
    if (state.write_dump == null) log.warn("crash dumps disabled: dbghelp.dll unavailable", .{});

    var dir8: [1560]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&dir8, state.prefix[0..state.dir_len]) catch return;
    _ = pruneKeep(std.heap.page_allocator, dir8[0..n], keep_dumps) catch |err| {
        log.warn("failed to prune crash dumps err={}", .{err});
    };
}

fn writeDump() void {
    var code_buf: [48]u8 = undefined;
    const what = describeException(&code_buf);

    const write_dump = state.write_dump orelse {
        logCrash("crash happened ({s}), no dump: dbghelp.dll unavailable", .{what});
        return;
    };

    // The directory is created lazily so a clean run never makes it.
    createDirs();

    var path_buf: [640]u16 = undefined;
    const path = dumpPath(&path_buf, state.prefix[0..state.prefix_len], Exp.GetTickCount64());
    var tmp_buf: [660]u16 = undefined;
    @memcpy(tmp_buf[0..path.len], path);
    for (".tmp", 0..) |c, i| tmp_buf[path.len + i] = c;
    tmp_buf[path.len + 4] = 0;
    const tmp: [:0]const u16 = tmp_buf[0 .. path.len + 4 :0];

    const GENERIC_READ_WRITE: DWORD = 0xC0000000;
    const CREATE_ALWAYS: DWORD = 2;
    const h = Exp.CreateFileW(tmp.ptr, GENERIC_READ_WRITE, 0, null, CREATE_ALWAYS, 0x80, null);
    if (h == win.INVALID_HANDLE_VALUE) {
        logCrash("crash happened ({s}), no dump: cannot create file err={d}", .{ what, Exp.GetLastError() });
        return;
    }

    const ok = write_dump(
        Exp.GetCurrentProcess(),
        Exp.GetCurrentProcessId(),
        h,
        dump_type,
        if (state.info.exception_pointers != null) &state.info else null,
        null,
        null,
    );
    const write_err = Exp.GetLastError();
    if (ok == .FALSE) {
        _ = Exp.CloseHandle(h);
        logCrash("crash happened ({s}), no dump: MiniDumpWriteDump err={d}", .{ what, write_err });
        return;
    }

    // FilterMemory leaves some live stack frames intact, so zero every
    // non-pointer word of every thread stack ourselves. A dump we cannot
    // scrub is deleted, never kept.
    const scrubbed = scrubFile(h);
    _ = Exp.CloseHandle(h);
    if (scrubbed == null) {
        _ = Exp.DeleteFileW(tmp.ptr);
        logCrash("crash happened ({s}), no dump: scrub failed", .{what});
        return;
    }

    const MOVEFILE_REPLACE_EXISTING: DWORD = 1;
    if (Exp.MoveFileExW(tmp.ptr, path.ptr, MOVEFILE_REPLACE_EXISTING) == .FALSE) {
        logCrash("crash happened ({s}), no dump: rename failed err={d}", .{ what, Exp.GetLastError() });
        return;
    }

    var out: [1300]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&out, path) catch 0;
    logCrash("crash dump written to {s} ({s})", .{ out[0..n], what });
}

/// Map the dump file and scrub it in place (no heap). Null on any failure.
fn scrubFile(h: HANDLE) ?usize {
    var size: i64 = 0;
    if (Exp.GetFileSizeEx(h, &size) == .FALSE or size <= 0) return null;
    const PAGE_READWRITE: DWORD = 0x04;
    const FILE_MAP_WRITE: DWORD = 0x02;
    const map = Exp.CreateFileMappingW(h, null, PAGE_READWRITE, 0, 0, null) orelse return null;
    defer _ = Exp.CloseHandle(map);
    const base = Exp.MapViewOfFile(map, FILE_MAP_WRITE, 0, 0, 0) orelse return null;
    defer _ = Exp.UnmapViewOfFile(base);
    const bytes = base[0..@intCast(size)];
    const n = scrubStacks(bytes) orelse return null;
    if (Exp.FlushViewOfFile(base, 0) == .FALSE) return null;
    return n;
}

fn rd32(b: []const u8, off: usize) ?u32 {
    if (off > b.len or b.len - off < 4) return null;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn rd64(b: []const u8, off: usize) ?u64 {
    if (off > b.len or b.len - off < 8) return null;
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// Zero every 8-byte word of every thread stack in a minidump (64-bit
/// targets) that is not zero and does not look like a user-mode pointer.
/// Returns the number of words zeroed, or null if the dump is not
/// understood. Pure over `bytes`.
pub fn scrubStacks(bytes: []u8) ?usize {
    if (rd32(bytes, 0) != 0x504d444d) return null; // "MDMP"
    const streams = rd32(bytes, 8) orelse return null;
    const dir = rd32(bytes, 12) orelse return null;
    var zeroed: usize = 0;
    var found = false;
    var k: usize = 0;
    while (k < streams) : (k += 1) {
        const e = dir + 12 * k;
        const kind = rd32(bytes, e) orelse return null;
        const rva = rd32(bytes, e + 8) orelse return null;
        if (kind != 3) continue; // ThreadListStream
        found = true;
        const count = rd32(bytes, rva) orelse return null;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const t = rva + 4 + 48 * i;
            const start = rd64(bytes, t + 24) orelse return null;
            const len = rd32(bytes, t + 32) orelse return null;
            const data = rd32(bytes, t + 36) orelse return null;
            if (data > bytes.len or bytes.len - data < len) return null;
            // Words are aligned in the target's address space.
            var off: usize = @intCast((8 - (start & 7)) & 7);
            while (off + 8 <= len) : (off += 8) {
                const word = std.mem.readInt(u64, bytes[data + off ..][0..8], .little);
                if (word == 0) continue;
                if (word >= 0x10000 and word <= 0x00007FFF_FFFFFFFF) continue;
                @memset(bytes[data + off ..][0..8], 0);
                zeroed += 1;
            }
            // Unaligned head and tail bytes cannot hold a pointer.
            @memset(bytes[data..][0..@min(len, (8 - (start & 7)) & 7)], 0);
            const tail = (len -| @as(usize, @intCast((8 - (start & 7)) & 7))) & 7;
            @memset(bytes[data + len - tail ..][0..tail], 0);
        }
    }
    return if (found) zeroed else null;
}

/// `code=0x... addr=0x...` from the exception record, or `panic` when the
/// dump was asked for without one. Plain reads: the crashing thread is still
/// parked in the filter, so the record is valid.
fn describeException(buf: []u8) []const u8 {
    const ptrs: *const Exp.ExceptionPointers = @ptrCast(@alignCast(state.info.exception_pointers orelse return "panic"));
    const rec = ptrs.record orelse return "code unknown";
    return std.fmt.bufPrint(buf, "code=0x{x:0>8} addr=0x{x}", .{ rec.code, @intFromPtr(rec.address) }) catch "code unknown";
}

/// Log from the crash path: straight to the file and debugger sinks, no
/// stderr lock (the crashed thread may hold it).
fn logCrash(comptime format: []const u8, args: anytype) void {
    windows_log.logFmt(.err, .windows_crash, format, args, .{});
}

/// Create `<LAD>ghostty` and `<LAD>ghosttycrash` (failures are ignored,
/// the file creation reports them).
fn createDirs() void {
    var buf: [640]u16 = undefined;
    const dir = state.dir_len;
    @memcpy(buf[0..dir], state.prefix[0..dir]);
    var sep = dir;
    while (sep > 0 and buf[sep - 1] != '\\') sep -= 1;
    if (sep == 0) return;
    sep -= 1; // the backslash before "crash"
    buf[sep] = 0;
    _ = Exp.CreateDirectoryW(@ptrCast(&buf), null);
    buf[sep] = '\\';
    buf[dir] = 0;
    _ = Exp.CreateDirectoryW(@ptrCast(&buf), null);
}

/// Build `<prefix><tick>.dmp` (null-terminated) into `buf`. Pure.
pub fn dumpPath(buf: []u16, prefix: []const u16, tick: u64) [:0]const u16 {
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [20]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{tick}) catch unreachable;
    for (d) |c| {
        buf[n] = c;
        n += 1;
    }
    for (".dmp") |c| {
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// Delete all but the `keep` newest `*.dmp` files in `dir`. Returns the
/// number deleted.
pub fn pruneKeep(alloc: Allocator, dir: []const u8, keep: usize) !usize {
    // A private instance: this runs on the dump thread, concurrently with
    // the main thread's use of the global one.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var d = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer d.close(io);

    const Entry = struct { name: []u8, mtime: i96 };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e.name);
        entries.deinit(alloc);
    }

    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        // A leftover from a dump that timed out.
        if (std.ascii.endsWithIgnoreCase(e.name, ".dmp.tmp")) {
            d.deleteFile(io, e.name) catch {};
            continue;
        }
        if (!std.ascii.endsWithIgnoreCase(e.name, ".dmp")) continue;
        const stat = d.statFile(io, e.name, .{}) catch continue;
        const name = try alloc.dupe(u8, e.name);
        errdefer alloc.free(name);
        try entries.append(alloc, .{ .name = name, .mtime = stat.mtime.nanoseconds });
    }
    if (entries.items.len <= keep) return 0;

    std.mem.sort(Entry, entries.items, {}, struct {
        fn newerFirst(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.newerFirst);

    var deleted: usize = 0;
    for (entries.items[keep..]) |e| {
        d.deleteFile(io, e.name) catch continue;
        deleted += 1;
    }
    return deleted;
}

/// Deliberate crashes for the e2e test op: `av`, `stack` or `panic`.
pub fn testCrash(kind: []const u8) void {
    if (std.mem.eql(u8, kind, "av")) {
        const p: *volatile u32 = @ptrFromInt(8);
        p.* = 1;
    } else if (std.mem.eql(u8, kind, "stack")) {
        _ = overflow(0);
    } else if (std.mem.eql(u8, kind, "panic")) {
        @panic("deliberate test crash");
    }
}

/// Unbounded recursion with a multi-page frame (so the OS stack probe walks the guard page) so it cannot become a loop.
fn overflow(n: usize) usize {
    var pad: [8192]u8 = undefined;
    const p: *volatile [8192]u8 = &pad;
    p[n % 8192] = @truncate(n);
    return overflow(n + 1) +% p[(n + 1) % 8192];
}

test "windows crash: dump type filters memory" {
    try std.testing.expect(dump_type & MiniDumpFilterMemory != 0);
    try std.testing.expect(dump_type & MiniDumpWithFullMemory == 0);
    try std.testing.expect(dump_type & MiniDumpWithIndirectlyReferencedMemory == 0);
}

test "windows crash: dump path" {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\crash\\ghostty-42-");
    var buf: [128]u16 = undefined;
    const p = dumpPath(&buf, prefix, 123456);
    const want = std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\crash\\ghostty-42-123456.dmp");
    try std.testing.expectEqualSlices(u16, want, p);
    try std.testing.expectEqual(@as(u16, 0), p[p.len]);
}

test "windows crash: prune keeps the 10 newest" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const base: i96 = 1_700_000_000 * std.time.ns_per_s;
    for (0..13) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "ghostty-1-{d}.dmp", .{i});
        var f = try tmp.dir.createFile(io, name, .{});
        defer f.close(io);
        try f.setTimestamps(io, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = base + @as(i96, @intCast(i)) * std.time.ns_per_s } },
        });
    }
    // A non-dump file is left alone.
    (try tmp.dir.createFile(io, "notes.txt", .{})).close(io);

    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir);

    try std.testing.expectEqual(@as(usize, 3), try pruneKeep(alloc, dir, 10));

    // The three oldest (0, 1, 2) are gone; 3..12 and the txt remain.
    for (0..13) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "ghostty-1-{d}.dmp", .{i});
        const exists = if (tmp.dir.statFile(io, name, .{})) |_| true else |_| false;
        try std.testing.expectEqual(i >= 3, exists);
    }
    _ = try tmp.dir.statFile(io, "notes.txt", .{});

    try std.testing.expectEqual(@as(usize, 0), try pruneKeep(alloc, dir, 10));
}

test "windows crash: install twice is a no-op" {
    if (comptime !is_windows) return error.SkipZigTest;
    // Leaves a live filter and dump thread in the test binary; harmless,
    // the test root keeps Zig's own vectored handler.
    install("C:\\ghostty-test-nowhere");
    try std.testing.expectEqual(@as(u32, 2), install_state.load(.acquire));
    const trigger = state.trigger;
    const done = state.done;
    install("C:\\ghostty-test-elsewhere");
    try std.testing.expectEqual(@as(u32, 2), install_state.load(.acquire));
    try std.testing.expectEqual(trigger, state.trigger);
    try std.testing.expectEqual(done, state.done);
    ensureInstalled();
}

test "windows crash: state base follows XDG_STATE_HOME like +crash-report" {
    if (comptime !is_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\t");
    try env.put("LOCALAPPDATA", "C:\\Users\\t\\AppData\\Local");

    for ([_][]const u8{ "", "D:\\state" }) |xdg| {
        try env.put("XDG_STATE_HOME", xdg);
        const dir = try @import("../crash/dir.zig").defaultDir(std.testing.io, alloc, &env);
        defer alloc.free(dir.path);
        const base = stateBase(xdg, "C:\\Users\\t\\AppData\\Local");
        const want = try std.fmt.allocPrint(alloc, "{s}\\ghostty/crash", .{base});
        defer alloc.free(want);
        try std.testing.expectEqualStrings(want, dir.path);
    }
}

test "windows crash: scrub zeroes non-pointer stack words" {
    var buf: [512]u8 = @splat(0xAA);
    const w = std.mem.writeInt;
    // Header, one stream (the thread list) at 32, stack data at 128.
    w(u32, buf[0..4], 0x504d444d, .little);
    w(u32, buf[8..12], 1, .little);
    w(u32, buf[12..16], 16, .little);
    w(u32, buf[16..20], 3, .little);
    w(u32, buf[24..28], 32, .little);
    w(u32, buf[32..36], 1, .little); // one thread
    const t = 36;
    w(u64, buf[t + 24 ..][0..8], 0x1000, .little); // aligned start
    w(u32, buf[t + 32 ..][0..4], 40, .little); // 5 words
    w(u32, buf[t + 36 ..][0..4], 128, .little);
    const text = "echo M5SECRETMARK";
    @memset(buf[128..168], 0);
    @memcpy(buf[128 .. 128 + 16], text[0..16]);
    w(u64, buf[144..][0..8], 0x7ff612345678, .little); // a pointer: kept
    w(u64, buf[152..][0..8], 0x1234, .little); // small int: zeroed
    w(u64, buf[160..][0..8], 0, .little);

    const n = scrubStacks(&buf).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "M5SECRET") == null);
    try std.testing.expectEqual(@as(u64, 0x7ff612345678), std.mem.readInt(u64, buf[144..][0..8], .little));
    try std.testing.expectEqual(@as(?usize, null), scrubStacks(buf[1..]));
}
