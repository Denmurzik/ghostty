//! The `IExplorerCommand` class behind the Windows 11 top-level "Open Ghostty
//! here" entry (R-M7-13), and its class factory. Loaded into Explorer (or its
//! surrogate), so no method may fault: every pointer is checked, every error
//! maps to an HRESULT, and nothing here can reach `@panic`.
const std = @import("std");
const com = @import("com.zig");
const ids = @import("ids.zig");

const HRESULT = com.HRESULT;
const GUID = com.GUID;

const u = std.unicode.utf8ToUtf16LeStringLiteral;
const title_text = u("Open Ghostty here");
const exe_name = u("\\ghostty.exe");
const wd_arg = u("--working-directory=");

/// What the class needs from the outside, behind pointers so the tests
/// capture the command line instead of starting a process.
pub const Hooks = struct {
    /// Writes the directory of this DLL (no trailing backslash) into `buf`
    /// and returns its length; null when it does not fit or is unknown.
    module_dir: *const fn (buf: []u16) ?usize,
    /// Starts the process. 0 on success, else a Win32 error code.
    launch: *const fn (cmdline: [:0]u16, cwd: [*:0]const u16) u32,
    /// The file-system path of a folder PIDL, as a `CoTaskMemAlloc` string.
    pidl_path: *const fn (pidl: *anyopaque) ?com.LPWSTR,
};

pub var hooks: Hooks = .{ .module_dir = realModuleDir, .launch = realLaunch, .pidl_path = realPidlPath };

// ---------------------------------------------------------------------------
// Module counts (DllCanUnloadNow = no objects and no locks).

var object_count: std.atomic.Value(u32) = .init(0);
var lock_count: std.atomic.Value(u32) = .init(0);

pub fn canUnloadNow() HRESULT {
    if (object_count.load(.acquire) == 0 and lock_count.load(.acquire) == 0) return com.S_OK;
    return com.S_FALSE;
}

const Command = extern struct {
    vtbl: *const com.IExplorerCommandVtbl,
    /// The second interface (`IObjectWithSite`) of the same object.
    site_vtbl: *const com.IObjectWithSiteVtbl,
    refs: u32,
    /// Explorer's site (owned reference), set through `SetSite`.
    site: ?*anyopaque = null,
};

const Factory = extern struct {
    vtbl: *const com.IClassFactoryVtbl,
    refs: u32,
};

/// `DllGetClassObject`.
pub fn getClassObject(rclsid: ?*const GUID, riid: ?*const GUID, ppv: ?*?*anyopaque) HRESULT {
    const out = ppv orelse return com.E_POINTER;
    out.* = null;
    const clsid = rclsid orelse return com.E_INVALIDARG;
    const iid = riid orelse return com.E_INVALIDARG;
    if (!clsid.eql(&ids.clsid)) return com.CLASS_E_CLASSNOTAVAILABLE;

    const f = create(Factory, .{ .vtbl = &factory_vtbl, .refs = 1 }) orelse return com.E_OUTOFMEMORY;
    const hr = factoryQueryInterface(f, iid, out);
    _ = factoryRelease(f);
    return hr;
}

// ---------------------------------------------------------------------------
// Heap objects. A process-heap block per object; the count drops after the
// free so `DllCanUnloadNow` never says yes while memory is still ours.

extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapAlloc(heap: *anyopaque, flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapFree(heap: *anyopaque, flags: u32, ptr: *anyopaque) callconv(.winapi) i32;

fn create(comptime T: type, init: T) ?*T {
    const heap = GetProcessHeap() orelse return null;
    const mem = HeapAlloc(heap, 0, @sizeOf(T)) orelse return null;
    const obj: *T = @ptrCast(@alignCast(mem));
    obj.* = init;
    _ = object_count.fetchAdd(1, .acq_rel);
    return obj;
}

fn destroy(obj: *anyopaque) void {
    if (GetProcessHeap()) |heap| _ = HeapFree(heap, 0, obj);
    _ = object_count.fetchSub(1, .acq_rel);
}

fn heapSlice16(n: usize) ?[]u16 {
    const heap = GetProcessHeap() orelse return null;
    const mem = HeapAlloc(heap, 0, n * 2) orelse return null;
    return @as([*]u16, @ptrCast(@alignCast(mem)))[0..n];
}

fn heapFree16(s: []u16) void {
    if (GetProcessHeap()) |heap| _ = HeapFree(heap, 0, @ptrCast(s.ptr));
}

// ---------------------------------------------------------------------------
// Class factory.

const factory_vtbl: com.IClassFactoryVtbl = .{
    .unk = .{
        .QueryInterface = &factoryQueryInterfaceC,
        .AddRef = &factoryAddRefC,
        .Release = &factoryReleaseC,
    },
    .CreateInstance = &factoryCreateInstance,
    .LockServer = &factoryLockServer,
};

fn factoryQueryInterface(f: *Factory, iid: *const GUID, out: *?*anyopaque) HRESULT {
    out.* = null;
    if (iid.eql(&com.IID_IUnknown) or iid.eql(&com.IID_IClassFactory)) {
        _ = factoryAddRef(f);
        out.* = f;
        return com.S_OK;
    }
    return com.E_NOINTERFACE;
}

fn factoryAddRef(f: *Factory) u32 {
    return @atomicRmw(u32, &f.refs, .Add, 1, .acq_rel) +% 1;
}

fn factoryRelease(f: *Factory) u32 {
    const prev = @atomicRmw(u32, &f.refs, .Sub, 1, .acq_rel);
    if (prev == 1) destroy(f);
    return prev -% 1;
}

fn factoryQueryInterfaceC(self: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    const i = iid orelse return com.E_INVALIDARG;
    return factoryQueryInterface(@ptrCast(@alignCast(self)), i, o);
}

fn factoryAddRefC(self: *anyopaque) callconv(.winapi) u32 {
    return factoryAddRef(@ptrCast(@alignCast(self)));
}

fn factoryReleaseC(self: *anyopaque) callconv(.winapi) u32 {
    return factoryRelease(@ptrCast(@alignCast(self)));
}

fn factoryCreateInstance(_: *anyopaque, outer: ?*anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    if (outer != null) return com.CLASS_E_NOAGGREGATION;
    const i = iid orelse return com.E_INVALIDARG;
    const c = create(Command, .{ .vtbl = &command_vtbl, .site_vtbl = &site_vtbl, .refs = 1 }) orelse return com.E_OUTOFMEMORY;
    const hr = commandQueryInterface(c, i, o);
    _ = commandRelease(c);
    return hr;
}

fn factoryLockServer(_: *anyopaque, lock: com.BOOL) callconv(.winapi) HRESULT {
    if (lock != 0) {
        _ = lock_count.fetchAdd(1, .acq_rel);
    } else {
        // Never underflow on an unbalanced FALSE.
        var cur = lock_count.load(.acquire);
        while (cur != 0) {
            cur = lock_count.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire) orelse break;
        }
    }
    return com.S_OK;
}

// ---------------------------------------------------------------------------
// The command.

const command_vtbl: com.IExplorerCommandVtbl = .{
    .unk = .{
        .QueryInterface = &commandQueryInterfaceC,
        .AddRef = &commandAddRefC,
        .Release = &commandReleaseC,
    },
    .GetTitle = &getTitle,
    .GetIcon = &getIcon,
    .GetToolTip = &getToolTip,
    .GetCanonicalName = &getCanonicalName,
    .GetState = &getState,
    .Invoke = &invoke,
    .GetFlags = &getFlags,
    .EnumSubCommands = &enumSubCommands,
};

fn commandQueryInterface(c: *Command, iid: *const GUID, out: *?*anyopaque) HRESULT {
    out.* = null;
    if (iid.eql(&com.IID_IUnknown) or iid.eql(&com.IID_IExplorerCommand)) {
        _ = commandAddRef(c);
        out.* = c;
        return com.S_OK;
    }
    if (iid.eql(&com.IID_IObjectWithSite)) {
        _ = commandAddRef(c);
        out.* = @ptrCast(&c.site_vtbl);
        return com.S_OK;
    }
    return com.E_NOINTERFACE;
}

fn commandAddRef(c: *Command) u32 {
    return @atomicRmw(u32, &c.refs, .Add, 1, .acq_rel) +% 1;
}

fn commandRelease(c: *Command) u32 {
    const prev = @atomicRmw(u32, &c.refs, .Sub, 1, .acq_rel);
    if (prev == 1) {
        if (c.site) |s| unkRelease(s);
        destroy(c);
    }
    return prev -% 1;
}

fn unkRelease(p: *anyopaque) void {
    const v: *const *const com.IUnknownVtbl = @ptrCast(@alignCast(p));
    _ = v.*.Release(p);
}

fn unkAddRef(p: *anyopaque) void {
    const v: *const *const com.IUnknownVtbl = @ptrCast(@alignCast(p));
    _ = v.*.AddRef(p);
}

/// A new reference to `iid` on `p`, or null.
fn queryInterface(p: *anyopaque, iid: *const GUID) ?*anyopaque {
    const v: *const *const com.IUnknownVtbl = @ptrCast(@alignCast(p));
    var out: ?*anyopaque = null;
    if (!com.succeeded(v.*.QueryInterface(p, iid, &out))) return null;
    return out;
}

fn commandQueryInterfaceC(self: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    const i = iid orelse return com.E_INVALIDARG;
    return commandQueryInterface(@ptrCast(@alignCast(self)), i, o);
}

fn commandAddRefC(self: *anyopaque) callconv(.winapi) u32 {
    return commandAddRef(@ptrCast(@alignCast(self)));
}

fn commandReleaseC(self: *anyopaque) callconv(.winapi) u32 {
    return commandRelease(@ptrCast(@alignCast(self)));
}

// IObjectWithSite: the same object seen through its second vtable pointer.

const site_vtbl: com.IObjectWithSiteVtbl = .{
    .unk = .{
        .QueryInterface = &siteQueryInterface,
        .AddRef = &siteAddRef,
        .Release = &siteRelease,
    },
    .SetSite = &setSite,
    .GetSite = &getSite,
};

fn fromSite(p: *anyopaque) *Command {
    const field: *const *const com.IObjectWithSiteVtbl = @ptrCast(@alignCast(p));
    return @constCast(@fieldParentPtr("site_vtbl", field));
}

fn siteQueryInterface(self: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    const i = iid orelse return com.E_INVALIDARG;
    return commandQueryInterface(fromSite(self), i, o);
}

fn siteAddRef(self: *anyopaque) callconv(.winapi) u32 {
    return commandAddRef(fromSite(self));
}

fn siteRelease(self: *anyopaque) callconv(.winapi) u32 {
    return commandRelease(fromSite(self));
}

fn setSite(self: *anyopaque, site: ?*anyopaque) callconv(.winapi) HRESULT {
    const c = fromSite(self);
    if (site) |s| unkAddRef(s);
    if (c.site) |old| unkRelease(old);
    c.site = site;
    return com.S_OK;
}

fn getSite(self: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    const i = iid orelse return com.E_INVALIDARG;
    const s = fromSite(self).site orelse return com.E_FAIL;
    o.* = queryInterface(s, i) orelse return com.E_NOINTERFACE;
    return com.S_OK;
}

/// The current folder of the Explorer window that hosts the command, for an
/// invocation with no item array (the desktop and folder backgrounds): site ->
/// `IServiceProvider` -> top-level `IShellBrowser` -> active view ->
/// `IFolderView` -> `IPersistFolder2` -> folder PIDL -> file-system path.
/// The caller frees the string with `CoTaskMemFree`.
fn siteFolderPath(c: *Command) ?com.LPWSTR {
    const site = c.site orelse return null;
    const sp = queryInterface(site, &com.IID_IServiceProvider) orelse return null;
    defer unkRelease(sp);
    const spv = @as(*const *const com.IServiceProviderVtbl, @ptrCast(@alignCast(sp))).*;
    var browser: ?*anyopaque = null;
    if (!com.succeeded(spv.QueryService(sp, &com.SID_STopLevelBrowser, &com.IID_IShellBrowser, &browser))) return null;
    const b = browser orelse return null;
    defer unkRelease(b);
    const bv = @as(*const *const com.IShellBrowserVtbl, @ptrCast(@alignCast(b))).*;
    var view: ?*anyopaque = null;
    if (!com.succeeded(bv.QueryActiveShellView(b, &view))) return null;
    const v = view orelse return null;
    defer unkRelease(v);
    const fv = queryInterface(v, &com.IID_IFolderView) orelse return null;
    defer unkRelease(fv);
    const fvv = @as(*const *const com.IFolderViewVtbl, @ptrCast(@alignCast(fv))).*;
    var folder: ?*anyopaque = null;
    if (!com.succeeded(fvv.GetFolder(fv, &com.IID_IPersistFolder2, &folder))) return null;
    const f = folder orelse return null;
    defer unkRelease(f);
    const fvt = @as(*const *const com.IPersistFolder2Vtbl, @ptrCast(@alignCast(f))).*;
    var pidl: ?*anyopaque = null;
    if (!com.succeeded(fvt.GetCurFolder(f, &pidl))) return null;
    const p = pidl orelse return null;
    defer com.CoTaskMemFree(p);
    return hooks.pidl_path(p);
}

/// A `CoTaskMemAlloc`'d copy of the concatenated parts (with the NUL).
fn coJoin(parts: []const []const u16) ?[*:0]u16 {
    var n: usize = 0;
    for (parts) |p| n += p.len;
    const bytes = std.math.mul(usize, n + 1, 2) catch return null;
    const mem = com.CoTaskMemAlloc(bytes) orelse return null;
    const out: [*]u16 = @ptrCast(@alignCast(mem));
    var i: usize = 0;
    for (parts) |p| {
        @memcpy(out[i..][0..p.len], p);
        i += p.len;
    }
    out[i] = 0;
    return @ptrCast(out);
}

fn getTitle(_: *anyopaque, _: ?*com.IShellItemArray, out: ?*?com.LPWSTR) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    o.* = coJoin(&.{title_text}) orelse return com.E_OUTOFMEMORY;
    return com.S_OK;
}

fn getIcon(_: *anyopaque, _: ?*com.IShellItemArray, out: ?*?com.LPWSTR) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    var buf: [2048]u16 = undefined;
    const n = hooks.module_dir(&buf) orelse return com.E_FAIL;
    if (n > buf.len) return com.E_FAIL;
    // The bare `path,index` form, as the in-box commands return it.
    o.* = coJoin(&.{ buf[0..n], exe_name, u(",0") }) orelse return com.E_OUTOFMEMORY;
    return com.S_OK;
}

fn getToolTip(_: *anyopaque, _: ?*com.IShellItemArray, out: ?*?com.LPWSTR) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = null;
    return com.E_NOTIMPL;
}

fn getCanonicalName(_: *anyopaque, out: ?*GUID) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = ids.verb_guid;
    return com.S_OK;
}

/// The single item of `array`, or null for none, several or a failure. The
/// caller releases it.
fn onlyItem(array: *com.IShellItemArray) ?*com.IShellItem {
    var count: u32 = 0;
    if (!com.succeeded(array.vtbl.GetCount(array, &count)) or count != 1) return null;
    var item: ?*com.IShellItem = null;
    if (!com.succeeded(array.vtbl.GetItemAt(array, 0, &item))) return null;
    return item;
}

/// The file-system path of `item` (`CoTaskMemAlloc`'d), or null.
fn itemPath(item: *com.IShellItem) ?com.LPWSTR {
    var name: ?com.LPWSTR = null;
    if (!com.succeeded(item.vtbl.GetDisplayName(item, com.SIGDN_FILESYSPATH, &name))) return null;
    return name;
}

/// `GetState` ignores `fOkToBeSlow`: both checks are cheap for a file-system
/// item, and a hidden entry on E_PENDING would only add a second call.
fn getState(self: *anyopaque, array: ?*com.IShellItemArray, _: com.BOOL, out: ?*u32) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = com.ECS_HIDDEN;
    const c: *Command = @ptrCast(@alignCast(self));
    const a = array orelse {
        // Folder and desktop backgrounds can come with no items.
        if (siteFolderPath(c)) |p| {
            com.CoTaskMemFree(p);
            o.* = com.ECS_ENABLED;
        }
        return com.S_OK;
    };
    const item = onlyItem(a) orelse return com.S_OK;
    defer item.release();
    var attrs: u32 = 0;
    if (!com.succeeded(item.vtbl.GetAttributes(item, com.SFGAO_FILESYSTEM, &attrs))) return com.S_OK;
    if (attrs & com.SFGAO_FILESYSTEM == 0) return com.S_OK;
    // An item can carry the attribute and still have no file-system path.
    const p = itemPath(item) orelse return com.S_OK;
    com.CoTaskMemFree(p);
    o.* = com.ECS_ENABLED;
    return com.S_OK;
}

fn getFlags(_: *anyopaque, out: ?*u32) callconv(.winapi) HRESULT {
    const o = out orelse return com.E_POINTER;
    o.* = com.ECF_DEFAULT;
    return com.S_OK;
}

fn enumSubCommands(_: *anyopaque, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    if (out) |o| o.* = null;
    return com.E_NOTIMPL;
}

/// Longest path accepted: `CreateProcessW` takes at most 32767 characters of
/// command line, and ours adds the exe path and the option name.
const max_path_len = 30000;

fn invoke(self: *anyopaque, array: ?*com.IShellItemArray, _: ?*anyopaque) callconv(.winapi) HRESULT {
    const c: *Command = @ptrCast(@alignCast(self));
    const a = array orelse {
        const p = siteFolderPath(c) orelse return com.E_INVALIDARG;
        defer com.CoTaskMemFree(p);
        return launchIn(std.mem.span(p));
    };
    const item = onlyItem(a) orelse return com.E_INVALIDARG;
    defer item.release();
    const raw = itemPath(item) orelse return com.E_FAIL;
    defer com.CoTaskMemFree(raw);
    return launchIn(std.mem.span(raw));
}

/// Builds `"<dll dir>\ghostty.exe" "--working-directory=<path>\."` (the
/// classic verb's shape) and starts it in `<path>`. A path that already ends
/// in a backslash (a drive root) gets just the dot.
fn launchIn(path: []const u16) HRESULT {
    if (path.len == 0 or path.len > max_path_len) return com.E_INVALIDARG;
    // A file-system path never holds a quote; refuse one rather than let it
    // break out of the argument.
    if (std.mem.indexOfScalar(u16, path, '"') != null) return com.E_INVALIDARG;

    var dir_buf: [2048]u16 = undefined;
    const dir_len = hooks.module_dir(&dir_buf) orelse return com.E_FAIL;
    if (dir_len > dir_buf.len) return com.E_FAIL;
    const dir = dir_buf[0..dir_len];

    const sep: []const u16 = if (path[path.len - 1] == '\\') u("") else u("\\");
    const parts = [_][]const u16{
        u("\""), dir,  exe_name, u("\" \""),
        wd_arg,  path, sep,      u(".\""),
    };
    var n: usize = 0;
    for (parts) |p| n += p.len;
    const buf = heapSlice16(n + 1) orelse return com.E_OUTOFMEMORY;
    defer heapFree16(buf);
    var i: usize = 0;
    for (parts) |p| {
        @memcpy(buf[i..][0..p.len], p);
        i += p.len;
    }
    buf[i] = 0;

    // The cwd needs its own NUL.
    const cwd = heapSlice16(path.len + 1) orelse return com.E_OUTOFMEMORY;
    defer heapFree16(cwd);
    @memcpy(cwd[0..path.len], path);
    cwd[path.len] = 0;

    const err = hooks.launch(buf[0..n :0], cwd[0..path.len :0]);
    if (err == 0) return com.S_OK;
    const hr = com.hresultFromWin32(err);
    return if (hr == com.S_OK) com.E_FAIL else hr;
}

// ---------------------------------------------------------------------------
// Real hooks.

extern "kernel32" fn GetModuleHandleExW(flags: u32, addr: ?*const anyopaque, out: *?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateProcessW(
    app: ?[*:0]const u16,
    cmdline: ?[*:0]u16,
    proc_attrs: ?*anyopaque,
    thread_attrs: ?*anyopaque,
    inherit: i32,
    flags: u32,
    env: ?*anyopaque,
    cwd: ?[*:0]const u16,
    si: *StartupInfo,
    pi: *ProcessInformation,
) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const StartupInfo = extern struct {
    cb: u32 = @sizeOf(StartupInfo),
    lpReserved: ?*anyopaque = null,
    lpDesktop: ?*anyopaque = null,
    lpTitle: ?*anyopaque = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*anyopaque = null,
    hStdInput: ?*anyopaque = null,
    hStdOutput: ?*anyopaque = null,
    hStdError: ?*anyopaque = null,
};

const ProcessInformation = extern struct {
    hProcess: ?*anyopaque = null,
    hThread: ?*anyopaque = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

const create_unicode_environment: u32 = 0x00000400;
const module_from_address: u32 = 0x4;
const module_unchanged_refcount: u32 = 0x2;

fn anchor() void {}

fn realModuleDir(buf: []u16) ?usize {
    var module: ?*anyopaque = null;
    if (GetModuleHandleExW(module_from_address | module_unchanged_refcount, @ptrCast(&anchor), &module) == 0) return null;
    if (buf.len == 0 or buf.len > std.math.maxInt(u32)) return null;
    const n = GetModuleFileNameW(module, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null; // failed or truncated
    return std.mem.lastIndexOfScalar(u16, buf[0..n], '\\');
}

fn realLaunch(cmdline: [:0]u16, cwd: [*:0]const u16) u32 {
    var si: StartupInfo = .{};
    var pi: ProcessInformation = .{};
    if (CreateProcessW(null, cmdline.ptr, null, null, 0, create_unicode_environment, null, cwd, &si, &pi) == 0) {
        const e = GetLastError();
        return if (e == 0) 0xFFFF else e;
    }
    if (pi.hThread) |h| _ = CloseHandle(h);
    if (pi.hProcess) |h| _ = CloseHandle(h);
    return 0;
}

fn realPidlPath(pidl: *anyopaque) ?com.LPWSTR {
    var name: ?com.LPWSTR = null;
    if (!com.succeeded(com.SHGetNameFromIDList(pidl, com.SIGDN_FILESYSPATH, &name))) return null;
    return name;
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

fn cmdOf(p: ?*anyopaque) *Command {
    return @ptrCast(@alignCast(p.?));
}

fn callQi(p: *anyopaque, iid: *const GUID) struct { HRESULT, ?*anyopaque } {
    const v: *const *const com.IUnknownVtbl = @ptrCast(@alignCast(p));
    var out: ?*anyopaque = null;
    const hr = v.*.QueryInterface(p, iid, &out);
    return .{ hr, out };
}

fn release(p: *anyopaque) u32 {
    const v: *const *const com.IUnknownVtbl = @ptrCast(@alignCast(p));
    return v.*.Release(p);
}

test "explorer command: factory and refcount" {
    var out: ?*anyopaque = null;

    const bad: GUID = .{ .Data1 = 1, .Data2 = 2, .Data3 = 3, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 1 } };
    try testing.expectEqual(com.CLASS_E_CLASSNOTAVAILABLE, getClassObject(&bad, &com.IID_IClassFactory, &out));
    try testing.expect(out == null);
    try testing.expectEqual(com.E_POINTER, getClassObject(&ids.clsid, &com.IID_IClassFactory, null));
    try testing.expectEqual(com.E_NOINTERFACE, getClassObject(&ids.clsid, &com.IID_IExplorerCommand, &out));
    try testing.expectEqual(com.S_OK, canUnloadNow());

    try testing.expectEqual(com.S_OK, getClassObject(&ids.clsid, &com.IID_IClassFactory, &out));
    const fac = out.?;
    try testing.expectEqual(com.S_FALSE, canUnloadNow());

    const f = @as(*const *const com.IClassFactoryVtbl, @ptrCast(@alignCast(fac))).*;

    var inst: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, f.CreateInstance(fac, null, &com.IID_IExplorerCommand, &inst));
    try testing.expect(inst != null);
    try testing.expectEqual(@as(u32, 1), cmdOf(inst).refs);

    // IUnknown too; another IID is refused and leaves the count alone.
    const hr_unk, const unk = callQi(inst.?, &com.IID_IUnknown);
    try testing.expectEqual(com.S_OK, hr_unk);
    try testing.expect(unk != null);
    try testing.expectEqual(@as(u32, 2), cmdOf(inst).refs);
    const hr_bad, const none = callQi(inst.?, &com.IID_IClassFactory);
    try testing.expectEqual(com.E_NOINTERFACE, hr_bad);
    try testing.expect(none == null);
    try testing.expectEqual(@as(u32, 2), cmdOf(inst).refs);

    var other: ?*anyopaque = null;
    try testing.expectEqual(com.E_NOINTERFACE, f.CreateInstance(fac, null, &com.IID_IClassFactory, &other));
    try testing.expect(other == null);
    try testing.expectEqual(com.CLASS_E_NOAGGREGATION, f.CreateInstance(fac, fac, &com.IID_IUnknown, &other));
    try testing.expectEqual(com.E_POINTER, f.CreateInstance(fac, null, &com.IID_IUnknown, null));

    // A held lock keeps the module loaded after every object is gone.
    try testing.expectEqual(com.S_OK, f.LockServer(fac, 1));
    try testing.expectEqual(@as(u32, 1), release(unk.?));
    try testing.expectEqual(@as(u32, 0), release(inst.?));
    try testing.expectEqual(@as(u32, 0), release(fac));
    try testing.expectEqual(com.S_FALSE, canUnloadNow());

    // Release the lock through a fresh factory.
    var fac2: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, getClassObject(&ids.clsid, &com.IID_IUnknown, &fac2));
    const f2 = @as(*const *const com.IClassFactoryVtbl, @ptrCast(@alignCast(fac2.?))).*;
    try testing.expectEqual(com.S_OK, f2.LockServer(fac2.?, 0));
    try testing.expectEqual(com.S_OK, f2.LockServer(fac2.?, 0)); // unbalanced: ignored
    try testing.expectEqual(@as(u32, 0), release(fac2.?));
    try testing.expectEqual(com.S_OK, canUnloadNow());
}

fn fakeModuleDir(buf: []u16) ?usize {
    const dir = u("C:\\Program Files\\Ghostty");
    if (dir.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    return dir.len;
}

var captured_cmd: [512]u8 = undefined;
var captured_cmd_len: usize = 0;
var captured_cwd: [512]u8 = undefined;
var captured_cwd_len: usize = 0;
var fake_launch_error: u32 = 0;

fn fakeLaunch(cmdline: [:0]u16, cwd: [*:0]const u16) u32 {
    captured_cmd_len = std.unicode.utf16LeToUtf8(&captured_cmd, cmdline) catch 0;
    captured_cwd_len = std.unicode.utf16LeToUtf8(&captured_cwd, std.mem.span(cwd)) catch 0;
    return fake_launch_error;
}

const FakeHooks = struct {
    saved: Hooks,

    fn install() FakeHooks {
        const saved = hooks;
        hooks = .{ .module_dir = fakeModuleDir, .launch = fakeLaunch, .pidl_path = fakePidlPath };
        captured_cmd_len = 0;
        captured_cwd_len = 0;
        fake_launch_error = 0;
        return .{ .saved = saved };
    }

    fn restore(self: FakeHooks) void {
        hooks = self.saved;
    }
};

fn stub() callconv(.winapi) HRESULT {
    return com.E_NOTIMPL;
}

fn fakeAddRef(_: *anyopaque) callconv(.winapi) u32 {
    return 2;
}

fn fakeRelease(_: *anyopaque) callconv(.winapi) u32 {
    return 1;
}

const FakeItem = extern struct {
    vtbl: *const com.IShellItemVtbl,
    path: [*:0]const u16,
    attrs: u32,
};

fn fakeGetDisplayName(self: *anyopaque, sigdn: u32, out: *?com.LPWSTR) callconv(.winapi) HRESULT {
    const item: *FakeItem = @ptrCast(@alignCast(self));
    out.* = null;
    if (sigdn != com.SIGDN_FILESYSPATH) return com.E_INVALIDARG;
    const src = std.mem.span(item.path);
    const mem = com.CoTaskMemAlloc((src.len + 1) * 2) orelse return com.E_OUTOFMEMORY;
    const dst: [*]u16 = @ptrCast(@alignCast(mem));
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    out.* = @ptrCast(dst);
    return com.S_OK;
}

fn fakeItemAttributes(self: *anyopaque, mask: u32, out: *u32) callconv(.winapi) HRESULT {
    const item: *FakeItem = @ptrCast(@alignCast(self));
    out.* = item.attrs & mask;
    return if (out.* == mask) com.S_OK else com.S_FALSE;
}

const item_vtbl: com.IShellItemVtbl = .{
    .unk = .{ .QueryInterface = @ptrCast(&stub), .AddRef = &fakeAddRef, .Release = &fakeRelease },
    .BindToHandler = @ptrCast(&stub),
    .GetParent = @ptrCast(&stub),
    .GetDisplayName = &fakeGetDisplayName,
    .GetAttributes = &fakeItemAttributes,
    .Compare = @ptrCast(&stub),
};

const FakeArray = extern struct {
    vtbl: *const com.IShellItemArrayVtbl,
    items: [*]const *FakeItem,
    count: u32,
};

fn fakeGetCount(self: *anyopaque, out: *u32) callconv(.winapi) HRESULT {
    const a: *FakeArray = @ptrCast(@alignCast(self));
    out.* = a.count;
    return com.S_OK;
}

fn fakeGetItemAt(self: *anyopaque, i: u32, out: *?*com.IShellItem) callconv(.winapi) HRESULT {
    const a: *FakeArray = @ptrCast(@alignCast(self));
    out.* = null;
    if (i >= a.count) return com.E_INVALIDARG;
    out.* = @ptrCast(a.items[i]);
    return com.S_OK;
}

const array_vtbl: com.IShellItemArrayVtbl = .{
    .unk = .{ .QueryInterface = @ptrCast(&stub), .AddRef = &fakeAddRef, .Release = &fakeRelease },
    .BindToHandler = @ptrCast(&stub),
    .GetPropertyStore = @ptrCast(&stub),
    .GetPropertyDescriptionList = @ptrCast(&stub),
    .GetAttributes = @ptrCast(&stub),
    .GetCount = &fakeGetCount,
    .GetItemAt = &fakeGetItemAt,
    .EnumItems = @ptrCast(&stub),
};

const fs_folder: u32 = com.SFGAO_FILESYSTEM | 0x20000000;

/// Makes a command and returns its interface pointer; the caller releases.
fn newCommand() !*anyopaque {
    var fac: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, getClassObject(&ids.clsid, &com.IID_IClassFactory, &fac));
    defer _ = release(fac.?);
    const f = @as(*const *const com.IClassFactoryVtbl, @ptrCast(@alignCast(fac.?))).*;
    var inst: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, f.CreateInstance(fac.?, null, &com.IID_IExplorerCommand, &inst));
    return inst.?;
}

fn vtblOf(c: *anyopaque) *const com.IExplorerCommandVtbl {
    return @as(*const *const com.IExplorerCommandVtbl, @ptrCast(@alignCast(c))).*;
}

fn expectCoString(want: []const u8, got: ?com.LPWSTR) !void {
    const p = got orelse return error.TestUnexpectedResult;
    defer com.CoTaskMemFree(p);
    var buf: [512]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&buf, std.mem.span(p));
    try testing.expectEqualStrings(want, buf[0..n]);
}

test "explorer command: title, icon, flags" {
    const fh = FakeHooks.install();
    defer fh.restore();
    const c = try newCommand();
    defer _ = release(c);
    const v = vtblOf(c);

    var s: ?com.LPWSTR = null;
    try testing.expectEqual(com.S_OK, v.GetTitle(c, null, &s));
    try expectCoString("Open Ghostty here", s);

    try testing.expectEqual(com.S_OK, v.GetIcon(c, null, &s));
    try expectCoString("C:\\Program Files\\Ghostty\\ghostty.exe,0", s);

    try testing.expectEqual(com.E_NOTIMPL, v.GetToolTip(c, null, &s));
    try testing.expect(s == null);

    var g: GUID = undefined;
    try testing.expectEqual(com.S_OK, v.GetCanonicalName(c, &g));
    try testing.expect(g.eql(&ids.verb_guid));

    var flags: u32 = 99;
    try testing.expectEqual(com.S_OK, v.GetFlags(c, &flags));
    try testing.expectEqual(com.ECF_DEFAULT, flags);

    var sub: ?*anyopaque = c;
    try testing.expectEqual(com.E_NOTIMPL, v.EnumSubCommands(c, &sub));
    try testing.expect(sub == null);

    // Null out-pointers are errors, not crashes.
    try testing.expectEqual(com.E_POINTER, v.GetTitle(c, null, null));
    try testing.expectEqual(com.E_POINTER, v.GetIcon(c, null, null));
    try testing.expectEqual(com.E_POINTER, v.GetCanonicalName(c, null));
    try testing.expectEqual(com.E_POINTER, v.GetFlags(c, null));
}

test "explorer command: state" {
    const c = try newCommand();
    defer _ = release(c);
    const v = vtblOf(c);

    var folder: FakeItem = .{ .vtbl = &item_vtbl, .path = u("C:\\a b\\c"), .attrs = fs_folder };
    var virtual: FakeItem = .{ .vtbl = &item_vtbl, .path = u("X"), .attrs = 0x20000000 };
    var one = [_]*FakeItem{&folder};
    var two = [_]*FakeItem{ &folder, &folder };
    var non_fs = [_]*FakeItem{&virtual};

    var state: u32 = 99;

    var a1: FakeArray = .{ .vtbl = &array_vtbl, .items = &one, .count = 1 };
    try testing.expectEqual(com.S_OK, v.GetState(c, @ptrCast(&a1), 0, &state));
    try testing.expectEqual(com.ECS_ENABLED, state);

    var a0: FakeArray = .{ .vtbl = &array_vtbl, .items = &one, .count = 0 };
    try testing.expectEqual(com.S_OK, v.GetState(c, @ptrCast(&a0), 0, &state));
    try testing.expectEqual(com.ECS_HIDDEN, state);

    var a2: FakeArray = .{ .vtbl = &array_vtbl, .items = &two, .count = 2 };
    try testing.expectEqual(com.S_OK, v.GetState(c, @ptrCast(&a2), 0, &state));
    try testing.expectEqual(com.ECS_HIDDEN, state);

    var an: FakeArray = .{ .vtbl = &array_vtbl, .items = &non_fs, .count = 1 };
    try testing.expectEqual(com.S_OK, v.GetState(c, @ptrCast(&an), 0, &state));
    try testing.expectEqual(com.ECS_HIDDEN, state);

    state = 99;
    try testing.expectEqual(com.S_OK, v.GetState(c, null, 0, &state));
    try testing.expectEqual(com.ECS_HIDDEN, state);
    try testing.expectEqual(com.E_POINTER, v.GetState(c, null, 0, null));
}

// Fake site chain: site -> IServiceProvider -> IShellBrowser -> view ->
// IFolderView -> IPersistFolder2. One struct type per interface; the site and
// the view answer QueryInterface by IID.

const FakeObj = extern struct { vtbl: *const anyopaque };

var fake_site_path: ?[*:0]const u16 = null;

fn fakePidlPath(pidl: *anyopaque) ?com.LPWSTR {
    if (pidl != fake_pidl_ptr) return null;
    const src = std.mem.span(fake_site_path orelse return null);
    const mem = com.CoTaskMemAlloc((src.len + 1) * 2) orelse return null;
    const dst: [*]u16 = @ptrCast(@alignCast(mem));
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @ptrCast(dst);
}

var fake_site_obj: FakeObj = undefined;
var fake_browser_obj: FakeObj = undefined;
var fake_view_obj: FakeObj = undefined;
var fake_fv_obj: FakeObj = undefined;
var fake_pf_obj: FakeObj = undefined;
var fake_site_released: u32 = 0;
var fake_site_added: u32 = 0;

fn siteAdd(_: *anyopaque) callconv(.winapi) u32 {
    fake_site_added += 1;
    return 2;
}
fn siteRel(_: *anyopaque) callconv(.winapi) u32 {
    fake_site_released += 1;
    return 1;
}

fn siteQi(_: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    out.?.* = null;
    if (iid.?.eql(&com.IID_IServiceProvider)) {
        out.?.* = &fake_site_obj;
        return com.S_OK;
    }
    return com.E_NOINTERFACE;
}

fn queryService(_: *anyopaque, sid: *const GUID, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (!sid.eql(&com.SID_STopLevelBrowser) or !iid.eql(&com.IID_IShellBrowser)) return com.E_NOINTERFACE;
    out.* = &fake_browser_obj;
    return com.S_OK;
}

fn queryActiveView(_: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = &fake_view_obj;
    return com.S_OK;
}

fn viewQi(_: *anyopaque, iid: ?*const GUID, out: ?*?*anyopaque) callconv(.winapi) HRESULT {
    out.?.* = null;
    if (iid.?.eql(&com.IID_IFolderView)) {
        out.?.* = &fake_fv_obj;
        return com.S_OK;
    }
    return com.E_NOINTERFACE;
}

fn getFolderFake(_: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (!iid.eql(&com.IID_IPersistFolder2)) return com.E_NOINTERFACE;
    out.* = &fake_pf_obj;
    return com.S_OK;
}

fn getCurFolderFake(_: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // The code frees the PIDL with CoTaskMemFree, so hand out a real block.
    const mem = com.CoTaskMemAlloc(1) orelse return com.E_OUTOFMEMORY;
    out.* = mem;
    fake_pidl_ptr = mem;
    return com.S_OK;
}
var fake_pidl_ptr: ?*anyopaque = null;

const base_unk: com.IUnknownVtbl = .{ .QueryInterface = @ptrCast(&stub), .AddRef = &siteAdd, .Release = &siteRel };

// The site answers IServiceProvider with itself, so its vtable is the
// service-provider one and QueryInterface is that vtable's first slot.
const fake_site_vtbl: com.IServiceProviderVtbl = .{ .unk = .{ .QueryInterface = &siteQi, .AddRef = &siteAdd, .Release = &siteRel }, .QueryService = &queryService };

const fake_browser_vtbl: com.IShellBrowserVtbl = .{
    .unk = base_unk,
    .GetWindow = &stub,
    .ContextSensitiveHelp = &stub,
    .InsertMenusSB = &stub,
    .SetMenuSB = &stub,
    .RemoveMenusSB = &stub,
    .SetStatusTextSB = &stub,
    .EnableModelessSB = &stub,
    .TranslateAcceleratorSB = &stub,
    .BrowseObject = &stub,
    .GetViewStateStream = &stub,
    .GetControlWindow = &stub,
    .SendControlMsg = &stub,
    .QueryActiveShellView = &queryActiveView,
};
const fake_view_vtbl: com.IUnknownVtbl = .{ .QueryInterface = &viewQi, .AddRef = &siteAdd, .Release = &siteRel };
const fake_fv_vtbl: com.IFolderViewVtbl = .{
    .unk = base_unk,
    .GetCurrentViewMode = &stub,
    .SetCurrentViewMode = &stub,
    .GetFolder = &getFolderFake,
};
const fake_pf_vtbl: com.IPersistFolder2Vtbl = .{
    .unk = base_unk,
    .GetClassID = &stub,
    .Initialize = &stub,
    .GetCurFolder = &getCurFolderFake,
};

test "explorer command: null array resolves the folder from the site" {
    const fh = FakeHooks.install();
    defer fh.restore();

    fake_site_obj = .{ .vtbl = &fake_site_vtbl };
    fake_browser_obj = .{ .vtbl = &fake_browser_vtbl };
    fake_view_obj = .{ .vtbl = &fake_view_vtbl };
    fake_fv_obj = .{ .vtbl = &fake_fv_vtbl };
    fake_pf_obj = .{ .vtbl = &fake_pf_vtbl };
    fake_site_path = u("C:\\bg dir");
    fake_site_added = 0;
    fake_site_released = 0;

    const c = try newCommand();
    const v = vtblOf(c);
    var state: u32 = 99;

    // No site yet: hidden, and Invoke refuses.
    try testing.expectEqual(com.S_OK, v.GetState(c, null, 0, &state));
    try testing.expectEqual(com.ECS_HIDDEN, state);
    try testing.expectEqual(com.E_INVALIDARG, v.Invoke(c, null, null));

    // IObjectWithSite through QueryInterface on the same object.
    const hr_site, const ows = callQi(c, &com.IID_IObjectWithSite);
    try testing.expectEqual(com.S_OK, hr_site);
    const ov = @as(*const *const com.IObjectWithSiteVtbl, @ptrCast(@alignCast(ows.?))).*;
    try testing.expectEqual(com.S_OK, ov.SetSite(ows.?, &fake_site_obj));
    try testing.expectEqual(@as(u32, 1), fake_site_added);

    var got: ?*anyopaque = null;
    try testing.expectEqual(com.E_NOINTERFACE, ov.GetSite(ows.?, &com.IID_IClassFactory, &got));
    try testing.expectEqual(com.S_OK, ov.GetSite(ows.?, &com.IID_IServiceProvider, &got));
    try testing.expect(got != null);

    try testing.expectEqual(com.S_OK, v.GetState(c, null, 0, &state));
    try testing.expectEqual(com.ECS_ENABLED, state);

    try testing.expectEqual(com.S_OK, v.Invoke(c, null, null));
    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Ghostty\\ghostty.exe\" \"--working-directory=C:\\bg dir\\.\"",
        captured_cmd[0..captured_cmd_len],
    );
    try testing.expectEqualStrings("C:\\bg dir",captured_cwd[0..captured_cwd_len]);

    // The command's last Release drops the site it holds.
    const released_before = fake_site_released;
    try testing.expectEqual(@as(u32, 1), release(ows.?)); // the QI reference
    _ = release(got.?); // GetSite's reference (fake: counts only)
    try testing.expectEqual(@as(u32, 0), release(c));
    try testing.expect(fake_site_released > released_before);
    try testing.expectEqual(com.S_OK, canUnloadNow());
}

test "explorer command: invoke builds the classic command" {
    const fh = FakeHooks.install();
    defer fh.restore();
    const c = try newCommand();
    defer _ = release(c);
    const v = vtblOf(c);

    var folder: FakeItem = .{ .vtbl = &item_vtbl, .path = u("C:\\a b\\c"), .attrs = fs_folder };
    var items = [_]*FakeItem{&folder};
    var arr: FakeArray = .{ .vtbl = &array_vtbl, .items = &items, .count = 1 };

    try testing.expectEqual(com.S_OK, v.Invoke(c, @ptrCast(&arr), null));
    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Ghostty\\ghostty.exe\" \"--working-directory=C:\\a b\\c\\.\"",
        captured_cmd[0..captured_cmd_len],
    );
    try testing.expectEqualStrings("C:\\a b\\c", captured_cwd[0..captured_cwd_len]);

    var drive: FakeItem = .{ .vtbl = &item_vtbl, .path = u("D:\\"), .attrs = fs_folder };
    var ditems = [_]*FakeItem{&drive};
    arr.items = &ditems;
    try testing.expectEqual(com.S_OK, v.Invoke(c, @ptrCast(&arr), null));
    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Ghostty\\ghostty.exe\" \"--working-directory=D:\\.\"",
        captured_cmd[0..captured_cmd_len],
    );
    try testing.expectEqualStrings("D:\\", captured_cwd[0..captured_cwd_len]);

    // A launch failure is an error HRESULT; bad input is refused.
    fake_launch_error = 2; // ERROR_FILE_NOT_FOUND
    try testing.expectEqual(com.hresultFromWin32(2), v.Invoke(c, @ptrCast(&arr), null));
    fake_launch_error = 0;
    try testing.expectEqual(com.E_INVALIDARG, v.Invoke(c, null, null));
    arr.count = 0;
    try testing.expectEqual(com.E_INVALIDARG, v.Invoke(c, @ptrCast(&arr), null));

    var quoted: FakeItem = .{ .vtbl = &item_vtbl, .path = u("C:\\a\"b"), .attrs = fs_folder };
    var qitems = [_]*FakeItem{&quoted};
    arr.items = &qitems;
    arr.count = 1;
    captured_cmd_len = 0;
    try testing.expectEqual(com.E_INVALIDARG, v.Invoke(c, @ptrCast(&arr), null));
    try testing.expectEqual(@as(usize, 0), captured_cmd_len);
}
