//! Desktop notifications and command-finished notices: WinRT toasts for an
//! unpackaged app. The app registers its own AppUserModelID under HKCU the
//! first time a toast is shown, so no installer is needed. Everything the
//! terminal program controls (title, body) is sanitized before it reaches
//! the toast XML. Where a toast cannot be shown the taskbar button flashes.
//!
//! In test mode (`GHOSTTY_WIN32_TEST_IPC=1`) no toast is ever created and the
//! registry stays untouched: the notice is only recorded for the IPC `state`
//! op.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const bell = @import("bell.zig");
const ipc_ops = @import("ipc/ops.zig");
const messages = @import("messages.zig");

const advapi32 = win32.advapi32;
const com = win32.com;
const foundation = win32.foundation;
const winrt = win32.winrt;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;
const HWND = foundation.HWND;

const log = std.log.scoped(.win32_notify);

/// The AppUserModelID the toasts are shown under. The debug build has its own
/// so that a development run never rewrites the registration of an installed
/// build.
pub const aumid = if (builtin.mode == .debug)
    "com.mitchellh.ghostty.windows-unofficial-debug"
else
    "com.mitchellh.ghostty.windows-unofficial";

const display_name = "Ghostty \u{2014} Unofficial Windows port";
const aumid_subkey = "Software\\Classes\\AppUserModelId\\" ++ aumid;

/// The icon the toast shows, written to disk on the first toast: the
/// registration takes a file path.
const icon_png = @embedFile("notify_icon.png");

/// Limits in code points; core truncates first, this is the backstop.
const max_title_cp = 256;
const max_body_cp = 1024;

/// Toasts kept alive after `Show`: the in-process `Activated` event only
/// fires while the notification object lives.
const live_capacity = 16;

const recorded_capacity = 16;

/// A notice recorded in test mode. The text is cut to fit.
pub const Recorded = struct {
    title: [256]u8 = undefined,
    title_len: u16 = 0,
    body: [1024]u8 = undefined,
    body_len: u16 = 0,
    surface: u32 = 0,

    fn set(self: *Recorded, title: []const u8, body: []const u8, surface: u32) void {
        self.title_len = copyTruncated(&self.title, title);
        self.body_len = copyTruncated(&self.body, body);
        self.surface = surface;
    }
};

fn copyTruncated(dest: []u8, src: []const u8) u16 {
    var n = @min(dest.len, src.len);
    // Never cut a multi-byte sequence in half.
    while (n > 0 and n < src.len and src[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(dest[0..n], src[0..n]);
    return @intCast(n);
}

/// The last `recorded_capacity` notices, oldest first.
pub const RingBuffer = struct {
    items: [recorded_capacity]Recorded = undefined,
    /// Index of the oldest entry.
    start: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *RingBuffer, title: []const u8, body: []const u8, surface: u32) void {
        const slot: u8 = if (self.len < recorded_capacity) blk: {
            const s = (self.start + self.len) % recorded_capacity;
            self.len += 1;
            break :blk s;
        } else blk: {
            const s = self.start;
            self.start = (self.start + 1) % recorded_capacity;
            break :blk s;
        };
        self.items[slot].set(title, body, surface);
    }

    pub fn at(self: *const RingBuffer, i: usize) *const Recorded {
        return &self.items[(@as(usize, self.start) + i) % recorded_capacity];
    }
};

pub const State = struct {
    notifier: ?*winrt.IToastNotifier = null,
    registered: bool = false,
    /// A failed toast was reported already (the log and the flash are not
    /// repeated per notice).
    warned: bool = false,
    recorded: RingBuffer = .{},
    /// Every notice seen in test mode, including the ones the ring dropped.
    recorded_total: u32 = 0,
    live: [live_capacity]?*winrt.IToastNotification = @splat(null),
    live_next: u8 = 0,
};

// -- Toast XML ------------------------------------------------------------------

/// `text` as UTF-8 that is safe to show: invalid sequences become U+FFFD,
/// C0 and C1 controls (except newline and tab) and the bidi override and
/// isolate characters are dropped, and at most `max_cp` code points stay.
/// Caller owns the result.
pub fn sanitize(alloc: Allocator, text: []const u8, max_cp: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < max_cp) {
        var cp: u21 = 0xFFFD;
        var n: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(text[i])) |len| {
            if (i + len <= text.len) {
                if (std.unicode.utf8Decode(text[i..][0..len])) |decoded| {
                    cp = decoded;
                    n = len;
                } else |_| {}
            }
        } else |_| {}
        i += n;

        if (isStripped(cp)) continue;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..len]);
        count += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn isStripped(cp: u21) bool {
    if (cp == '\n' or cp == '\t') return false;
    return switch (cp) {
        0x00...0x1F, 0x7F...0x9F => true,
        // LRM, RLM and the embeddings and overrides.
        0x200E, 0x200F, 0x202A...0x202E => true,
        // Isolates.
        0x2066...0x2069 => true,
        // Not allowed in XML text.
        0xFFFE, 0xFFFF => true,
        else => false,
    };
}

fn appendEscaped(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        '\'' => try out.appendSlice(alloc, "&apos;"),
        else => try out.append(alloc, c),
    };
}

/// The `ToastGeneric` XML of a notice, UTF-16 with a NUL after the end.
/// Activating the toast carries `surface=<id>` in `launch`.
pub fn toastXml(alloc: Allocator, title: []const u8, body: []const u8, surface_id: u32) ![:0]u16 {
    const clean_title = try sanitize(alloc, title, max_title_cp);
    defer alloc.free(clean_title);
    const clean_body = try sanitize(alloc, body, max_body_cp);
    defer alloc.free(clean_body);

    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(alloc);
    const launch = try std.fmt.allocPrint(alloc, "<toast launch=\"surface={d}\"><visual><binding template=\"ToastGeneric\"><text>", .{surface_id});
    defer alloc.free(launch);
    try xml.appendSlice(alloc, launch);
    try appendEscaped(alloc, &xml, clean_title);
    try xml.appendSlice(alloc, "</text>");
    if (clean_body.len > 0) {
        try xml.appendSlice(alloc, "<text>");
        try appendEscaped(alloc, &xml, clean_body);
        try xml.appendSlice(alloc, "</text>");
    }
    try xml.appendSlice(alloc, "</binding></visual></toast>");
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, xml.items);
}

// -- AUMID registration -----------------------------------------------------------

/// Where the registration writes: the real registry or, in tests, a fake.
/// The slices are not NUL terminated.
pub const RegistryWriter = struct {
    ctx: *anyopaque,
    setString: *const fn (ctx: *anyopaque, subkey: []const u16, name: []const u16, value: []const u16) bool,
};

fn L(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Writes `DisplayName` and `IconUri` under
/// `HKCU\Software\Classes\AppUserModelId\<aumid>`: what Windows needs to show
/// a toast of an unpackaged app under its own name and icon.
pub fn registerAumid(w: RegistryWriter, icon_path: []const u8) bool {
    var icon_buf: [1024]u16 = undefined;
    const icon_len = std.unicode.utf8ToUtf16Le(&icon_buf, icon_path) catch return false;

    const subkey = L(aumid_subkey);
    if (!w.setString(w.ctx, subkey, L("DisplayName"), L(display_name))) return false;
    return w.setString(w.ctx, subkey, L("IconUri"), icon_buf[0..icon_len]);
}

fn registrySetString(_: *anyopaque, subkey: []const u16, name: []const u16, value: []const u16) bool {
    var subkey_buf: [256:0]u16 = undefined;
    var name_buf: [64:0]u16 = undefined;
    var value_buf: [1100:0]u16 = undefined;
    if (subkey.len >= subkey_buf.len or name.len >= name_buf.len or value.len >= value_buf.len) return false;
    @memcpy(subkey_buf[0..subkey.len], subkey);
    subkey_buf[subkey.len] = 0;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    @memcpy(value_buf[0..value.len], value);
    value_buf[value.len] = 0;

    var key: advapi32.HKEY = undefined;
    if (advapi32.RegCreateKeyExW(
        advapi32.HKEY_CURRENT_USER,
        &subkey_buf,
        0,
        null,
        advapi32.REG_OPTION_NON_VOLATILE,
        advapi32.KEY_WRITE,
        null,
        &key,
        null,
    ) != 0) return false;
    defer _ = advapi32.RegCloseKey(key);

    return advapi32.RegSetValueExW(
        key,
        &name_buf,
        0,
        advapi32.REG_SZ,
        @ptrCast(&value_buf),
        @intCast((value.len + 1) * @sizeOf(u16)),
    ) == 0;
}

var real_writer_ctx: u8 = 0;
const real_writer: RegistryWriter = .{ .ctx = &real_writer_ctx, .setString = registrySetString };

/// Writes the icon next to the other per-user data and returns its path
/// (caller owns it); null where it cannot be written.
fn writeIcon(alloc: Allocator) ?[]u8 {
    const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    const dir = std.fmt.allocPrint(alloc, "{s}\\Ghostty", .{base}) catch return null;
    defer alloc.free(dir);
    const path = std.fmt.allocPrint(alloc, "{s}\\notify-icon.png", .{dir}) catch return null;
    errdefer alloc.free(path);

    const io = global.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| {
        log.warn("unable to create icon directory err={}", .{err});
        alloc.free(path);
        return null;
    };
    cwd.writeFile(io, .{ .sub_path = path, .data = icon_png }) catch |err| {
        log.warn("unable to write the notification icon err={}", .{err});
        alloc.free(path);
        return null;
    };
    return path;
}

// -- Activation delegate ----------------------------------------------------------

/// The COM object behind the `Activated` event of one toast. WinRT calls
/// `Invoke` on a thread of its own, so the object does nothing but post a
/// message to the message window.
const Delegate = extern struct {
    iface: winrt.ToastActivatedHandler,
    refs: u32,
    hwnd: ?HWND,
    surface_id: u32,

    const vtable: winrt.ToastActivatedHandler.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    /// One reference, owned by the caller.
    fn create(hwnd: ?HWND, surface_id: u32) Allocator.Error!*Delegate {
        // Released from any thread, hence not the app's allocator.
        const self = try std.heap.smp_allocator.create(Delegate);
        self.* = .{
            .iface = .{ .vtable = &vtable },
            .refs = 1,
            .hwnd = hwnd,
            .surface_id = surface_id,
        };
        return self;
    }

    fn from(iface: *winrt.ToastActivatedHandler) *Delegate {
        return @fieldParentPtr("iface", iface);
    }

    fn sameGuid(a: *const foundation.GUID, b: foundation.GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(&b));
    }

    fn queryInterface(iface: *winrt.ToastActivatedHandler, riid: *const foundation.GUID, out: *?*anyopaque) callconv(.winapi) foundation.HRESULT {
        // The agile marker tells WinRT the object may be called on any thread
        // (no proxy, no marshaling to the UI thread).
        if (sameGuid(riid, com.IUnknown.iid) or
            sameGuid(riid, winrt.ToastActivatedHandler.iid) or
            sameGuid(riid, winrt.IAgileObject_iid))
        {
            _ = addRef(iface);
            out.* = iface;
            return foundation.S_OK;
        }
        out.* = null;
        return win32.ole32.E_NOINTERFACE;
    }

    fn addRef(iface: *winrt.ToastActivatedHandler) callconv(.winapi) u32 {
        const self = from(iface);
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }

    fn release(iface: *winrt.ToastActivatedHandler) callconv(.winapi) u32 {
        const self = from(iface);
        const left = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) - 1;
        if (left == 0) std.heap.smp_allocator.destroy(self);
        return left;
    }

    fn invoke(iface: *winrt.ToastActivatedHandler, _: ?*winrt.IToastNotification, _: ?*winrt.IInspectable) callconv(.winapi) foundation.HRESULT {
        const self = from(iface);
        if (self.hwnd) |hwnd| {
            _ = win32.user32.PostMessageW(hwnd, messages.WM_GHOSTTY_NOTIFY_CLICK, self.surface_id, 0);
        }
        return foundation.S_OK;
    }
};

// -- Lifecycle and actions ----------------------------------------------------------

fn testMode() bool {
    return ipc_ops.testOpsEnabled();
}

pub fn appStarted(app: *App) void {
    _ = app;
    if (testMode()) return;
    // The taskbar groups the windows under the same ID the toasts use.
    const hr = win32.shell32.SetCurrentProcessExplicitAppUserModelID(std.unicode.utf8ToUtf16LeStringLiteral(aumid));
    if (!foundation.succeeded(hr)) log.warn("unable to set the AppUserModelID hr=0x{x}", .{@as(u32, @bitCast(hr))});
}

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    _ = app;
    _ = config;
}

/// `WM_GHOSTTY_NOTIFY_CLICK` on the message window (wparam = surface id):
/// bring the surface of the clicked toast forward, if it is still alive.
pub fn clicked(app: *App, wparam: WPARAM) void {
    const id = std.math.cast(u32, wparam) orelse return;
    const surface = findSurface(app, id) orelse return;
    const window = surface.window;
    const index = window.tabIndex(surface.tab) orelse return;
    surface.tab.focused = surface;
    window.selectTabFocus(index, false);
    window.activate();
}

fn findSurface(app: *App, id: u32) ?*Surface {
    for (app.windows.items) |w| {
        if (w.findSurface(id)) |s| return s;
    }
    return null;
}

pub fn desktop(app: *App, target: apprt.Target, value: apprt.Action.Value(.desktop_notification)) !bool {
    if (!app.config.@"desktop-notifications") return false;
    const surface = switch (target) {
        .app => null,
        .surface => |s| app.surfaceFor(s),
    };
    // OSC 9 has no title: the toast carries the app's name instead.
    show(app, surface, if (value.title.len == 0) "Ghostty" else value.title, value.body);
    return true;
}

/// Whether a finished command asks for a notice: `unfocused` only when the
/// surface is not focused, and only commands longer than `after`.
pub fn shouldNotify(
    mode: configpkg.Config.NotifyOnCommandFinish,
    focused: bool,
    duration: configpkg.Config.Duration,
    after: configpkg.Config.Duration,
) bool {
    switch (mode) {
        .never => return false,
        .unfocused => if (focused) return false,
        .always => {},
    }
    return !duration.lte(after);
}

pub fn commandFinished(app: *App, target: apprt.Target, value: apprt.Action.Value(.command_finished)) !bool {
    const surface = switch (target) {
        .app => return false,
        .surface => |s| app.surfaceFor(s) orelse return false,
    };
    const config = &app.config;
    if (!shouldNotify(
        config.@"notify-on-command-finish",
        surfaceFocused(surface),
        value.duration,
        config.@"notify-on-command-finish-after",
    )) return true;

    const action = config.@"notify-on-command-finish-action";
    if (action.bell) _ = bell.ring(surface);
    if (!action.notify) return true;

    const alloc = app.core_app.alloc;
    const title: []const u8 = if (value.exit_code) |code|
        (if (code == 0) "Command Succeeded" else "Command Failed")
    else
        "Command Finished";
    const body = (if (value.exit_code) |code|
        std.fmt.allocPrint(alloc, "Command took {f} and exited with code {d}.", .{ value.duration.round(std.time.ns_per_ms), code })
    else
        std.fmt.allocPrint(alloc, "Command took {f}.", .{value.duration.round(std.time.ns_per_ms)})) catch return true;
    defer alloc.free(body);

    show(app, surface, title, body);
    return true;
}

fn surfaceFocused(surface: *Surface) bool {
    const window = surface.window;
    const foreground = win32.user32.GetForegroundWindow() == window.hwnd;
    return foreground and win32.user32.GetFocus() == surface.hwnd;
}

/// Shows (or in test mode records) one notice. Never fails: a toast that
/// cannot be shown flashes the taskbar button instead.
fn show(app: *App, surface: ?*Surface, title: []const u8, body: []const u8) void {
    const surface_id: u32 = if (surface) |s| s.id else 0;

    if (testMode()) {
        const alloc = app.core_app.alloc;
        const clean_title = sanitize(alloc, title, max_title_cp) catch return;
        defer alloc.free(clean_title);
        const clean_body = sanitize(alloc, body, max_body_cp) catch return;
        defer alloc.free(clean_body);
        app.notify.recorded.push(clean_title, clean_body, surface_id);
        app.notify.recorded_total += 1;
        return;
    }

    showToast(app, title, body, surface_id) catch |err| {
        if (!app.notify.warned) {
            app.notify.warned = true;
            log.warn("unable to show a toast, flashing the window instead err={}", .{err});
        }
        flash(app, surface);
    };
}

fn flash(app: *App, surface: ?*Surface) void {
    const window: *Window = if (surface) |s| s.window else app.last_active orelse {
        if (app.windows.items.len == 0) return;
        return flashWindow(app.windows.items[0]);
    };
    flashWindow(window);
}

fn flashWindow(window: *Window) void {
    var info: win32.user32.FLASHWINFO = .{
        .hwnd = window.hwnd,
        .dwFlags = win32.user32.FLASHW_TRAY | win32.user32.FLASHW_TIMERNOFG,
    };
    _ = win32.user32.FlashWindowEx(&info);
}

fn showToast(app: *App, title: []const u8, body: []const u8, surface_id: u32) !void {
    const state = &app.notify;
    const alloc = app.core_app.alloc;
    const notifier = try ensureNotifier(app);

    const xml_text = try toastXml(alloc, title, body, surface_id);
    defer alloc.free(xml_text);

    const doc = try winrt.activateInstance("Windows.Data.Xml.Dom.XmlDocument");
    defer com.release(doc);
    {
        const io = try com.queryInterface(doc, winrt.IXmlDocumentIO);
        defer com.release(io);
        var xml = try winrt.String.init(xml_text);
        defer xml.deinit();
        try io.loadXml(xml.handle);
    }

    const factory = try winrt.getActivationFactory(winrt.IToastNotificationFactory, winrt.IToastNotificationFactory.class_name);
    defer com.release(factory);
    const toast = try factory.createToastNotification(doc);
    errdefer com.release(toast);

    const handler = try Delegate.create(app.msg_hwnd, surface_id);
    // The toast holds its own reference once the event is added.
    defer _ = Delegate.release(&handler.iface);
    _ = try toast.addActivated(&handler.iface);

    try notifier.show(toast);

    com.release(state.live[state.live_next]);
    state.live[state.live_next] = toast;
    state.live_next = (state.live_next + 1) % live_capacity;
}

/// The notifier of the app's AUMID, created (after the registration) on the
/// first toast.
fn ensureNotifier(app: *App) !*winrt.IToastNotifier {
    const state = &app.notify;
    if (state.notifier) |n| return n;

    if (!state.registered) {
        state.registered = true;
        const alloc = app.core_app.alloc;
        const icon = writeIcon(alloc);
        defer if (icon) |p| alloc.free(p);
        if (!registerAumid(real_writer, icon orelse "")) log.warn("unable to register the AppUserModelID", .{});
    }

    const statics = try winrt.getActivationFactory(winrt.IToastNotificationManagerStatics, winrt.IToastNotificationManagerStatics.class_name);
    defer com.release(statics);
    var id = try winrt.String.init(std.unicode.utf8ToUtf16LeStringLiteral(aumid));
    defer id.deinit();
    const notifier = try statics.createToastNotifierWithId(id.handle);
    state.notifier = notifier;
    return notifier;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    const state = &app.notify;
    try jw.beginObject();
    try jw.objectField("total");
    try jw.write(state.recorded_total);
    try jw.objectField("recorded");
    try jw.beginArray();
    const count = @min(state.recorded.len, recorded_capacity);
    for (0..count) |i| {
        const r = state.recorded.at(i);
        try jw.beginObject();
        try jw.objectField("title");
        try jw.write(r.title[0..@min(r.title_len, r.title.len)]);
        try jw.objectField("body");
        try jw.write(r.body[0..@min(r.body_len, r.body.len)]);
        try jw.objectField("surface");
        try jw.write(r.surface);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

// -- Tests ------------------------------------------------------------------------

const testing = std.testing;

fn xmlUtf8(xml: [:0]const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(testing.allocator, xml);
}

test "win32 notify: toast xml escapes and strips" {
    const xml = try toastXml(testing.allocator, "a<b>&\"'", "x\u{202E}y\x1bz", 7);
    defer testing.allocator.free(xml);
    const text = try xmlUtf8(xml);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        "<toast launch=\"surface=7\"><visual><binding template=\"ToastGeneric\">" ++
            "<text>a&lt;b&gt;&amp;&quot;&apos;</text><text>xyz</text></binding></visual></toast>",
        text,
    );

    // Long text is cut at the limits, code points rather than bytes.
    const long_title = try testing.allocator.alloc(u8, 300 * 2);
    defer testing.allocator.free(long_title);
    for (0..300) |i| @memcpy(long_title[i * 2 ..][0..2], "\u{00E9}");
    const long_body = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(long_body);
    @memset(long_body, 'q');

    const cut = try toastXml(testing.allocator, long_title, long_body, 1);
    defer testing.allocator.free(cut);
    const cut_text = try xmlUtf8(cut);
    defer testing.allocator.free(cut_text);
    try testing.expectEqual(@as(usize, 256), std.mem.count(u8, cut_text, "\u{00E9}"));
    try testing.expectEqual(@as(usize, 1024), std.mem.count(u8, cut_text, "q"));

    // Invalid UTF-8 never reaches the XML.
    const bad = try toastXml(testing.allocator, "a\xffb", "", 1);
    defer testing.allocator.free(bad);
    const bad_text = try xmlUtf8(bad);
    defer testing.allocator.free(bad_text);
    try testing.expect(std.mem.indexOf(u8, bad_text, "a\u{FFFD}b</text></binding>") != null);
}

const FakeWriter = struct {
    calls: usize = 0,
    subkey_ok: bool = true,
    display_name: [128]u8 = undefined,
    display_name_len: usize = 0,
    icon: [64]u8 = undefined,
    icon_len: usize = 0,

    fn set(ctx: *anyopaque, subkey: []const u16, name: []const u16, value: []const u16) bool {
        const self: *FakeWriter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (!std.mem.eql(u16, subkey, L(aumid_subkey))) self.subkey_ok = false;
        if (std.mem.eql(u16, name, L("DisplayName"))) {
            self.display_name_len = std.unicode.utf16LeToUtf8(&self.display_name, value) catch 0;
        } else if (std.mem.eql(u16, name, L("IconUri"))) {
            self.icon_len = std.unicode.utf16LeToUtf8(&self.icon, value) catch 0;
        }
        return true;
    }
};

test "win32 notify: aumid registration through the writer" {
    var fake: FakeWriter = .{};
    try testing.expect(registerAumid(.{ .ctx = &fake, .setString = FakeWriter.set }, "C:\\icons\\g.png"));
    try testing.expectEqual(@as(usize, 2), fake.calls);
    try testing.expect(fake.subkey_ok);
    try testing.expectEqualStrings("Ghostty \u{2014} Unofficial Windows port", fake.display_name[0..fake.display_name_len]);
    try testing.expectEqualStrings("C:\\icons\\g.png", fake.icon[0..fake.icon_len]);

    // A failing writer fails the registration.
    const Failing = struct {
        fn set(_: *anyopaque, _: []const u16, _: []const u16, _: []const u16) bool {
            return false;
        }
    };
    try testing.expect(!registerAumid(.{ .ctx = &fake, .setString = Failing.set }, "x"));
}

test "win32 notify: command_finished policy" {
    const Duration = configpkg.Config.Duration;
    const s = std.time.ns_per_s;
    const after: Duration = .{ .duration = 5 * s };
    const Mode = configpkg.Config.NotifyOnCommandFinish;

    const cases = [_]struct { mode: Mode, focused: bool, secs: u64, want: bool }{
        .{ .mode = .never, .focused = false, .secs = 60, .want = false },
        .{ .mode = .never, .focused = true, .secs = 60, .want = false },
        .{ .mode = .unfocused, .focused = true, .secs = 60, .want = false },
        .{ .mode = .unfocused, .focused = false, .secs = 60, .want = true },
        .{ .mode = .unfocused, .focused = false, .secs = 5, .want = false },
        .{ .mode = .always, .focused = true, .secs = 60, .want = true },
        .{ .mode = .always, .focused = true, .secs = 6, .want = true },
        .{ .mode = .always, .focused = false, .secs = 5, .want = false },
        .{ .mode = .always, .focused = false, .secs = 4, .want = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, shouldNotify(c.mode, c.focused, .{ .duration = c.secs * s }, after));
    }
    // `-after = 0s` notifies anything that took time.
    try testing.expect(shouldNotify(.always, true, .{ .duration = 1 }, .{ .duration = 0 }));
    try testing.expect(!shouldNotify(.always, true, .{ .duration = 0 }, .{ .duration = 0 }));
}

test "win32 notify: delegate refcount" {
    const hwnd = win32.user32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.user32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = win32.user32.DestroyWindow(hwnd);

    const d = try Delegate.create(hwnd, 42);
    const iface = &d.iface;
    try testing.expectEqual(@as(u32, 2), iface.vtable.AddRef(iface));
    try testing.expectEqual(@as(u32, 1), iface.vtable.Release(iface));

    // QueryInterface hands out the delegate, the agile marker and IUnknown
    // with a reference each; anything else is refused.
    var out: ?*anyopaque = null;
    try testing.expectEqual(foundation.S_OK, iface.vtable.QueryInterface(iface, &winrt.ToastActivatedHandler.iid, &out));
    try testing.expect(out == @as(?*anyopaque, iface));
    try testing.expectEqual(foundation.S_OK, iface.vtable.QueryInterface(iface, &winrt.IAgileObject_iid, &out));
    try testing.expectEqual(foundation.S_OK, iface.vtable.QueryInterface(iface, &com.IUnknown.iid, &out));
    try testing.expectEqual(@as(u32, 4), @atomicLoad(u32, &d.refs, .monotonic));
    try testing.expect(iface.vtable.QueryInterface(iface, &winrt.IInspectable.iid, &out) != foundation.S_OK);
    try testing.expect(out == null);
    for (0..3) |_| _ = iface.vtable.Release(iface);
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &d.refs, .monotonic));

    // Invoke posts exactly one message carrying the surface id.
    try testing.expectEqual(foundation.S_OK, iface.vtable.Invoke(iface, null, null));
    var msg: win32.user32.MSG = undefined;
    const filter = messages.WM_GHOSTTY_NOTIFY_CLICK;
    try testing.expect(win32.user32.PeekMessageW(&msg, hwnd, filter, filter, win32.user32.PM_REMOVE) != 0);
    try testing.expectEqual(@as(usize, 42), msg.wParam);
    try testing.expect(win32.user32.PeekMessageW(&msg, hwnd, filter, filter, win32.user32.PM_REMOVE) == 0);

    try testing.expectEqual(@as(u32, 0), iface.vtable.Release(iface));
}

test "win32 notify: recorded ring keeps the last notices" {
    var ring: RingBuffer = .{};
    for (0..recorded_capacity + 3) |i| {
        var buf: [8]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable;
        ring.push(title, "body", @intCast(i));
    }
    try testing.expectEqual(@as(u8, recorded_capacity), ring.len);
    const first = ring.at(0);
    try testing.expectEqualStrings("t3", first.title[0..first.title_len]);
    const last = ring.at(recorded_capacity - 1);
    try testing.expectEqual(@as(u32, recorded_capacity + 2), last.surface);

    // Text beyond the buffers is cut on a character boundary.
    var long: [300]u8 = undefined;
    for (0..150) |i| @memcpy(long[i * 2 ..][0..2], "\u{00E9}");
    ring.push(&long, "", 1);
    const cut = ring.at(recorded_capacity - 1);
    try testing.expectEqual(@as(u16, 256), cut.title_len);
}

// -- WinRT bindings --------------------------------------------------------------
// Their tests live here: the pkg/win32 test roots are not part of the main test build.

fn winrtSlots(comptime T: type) usize {
    return @sizeOf(T.VTable) / @sizeOf(usize);
}

test "win32 winrt: slot counts" {
    // Total slots including IInspectable (6), counted from the SDK 10.0.26100 headers.
    try testing.expectEqual(6, winrtSlots(winrt.IInspectable));
    try testing.expectEqual(9, winrtSlots(winrt.IToastNotificationManagerStatics));
    try testing.expectEqual(7, winrtSlots(winrt.IToastNotificationFactory));
    try testing.expectEqual(12, winrtSlots(winrt.IToastNotifier));
    try testing.expectEqual(15, winrtSlots(winrt.IToastNotification));
    try testing.expectEqual(9, winrtSlots(winrt.IXmlDocumentIO));
    try testing.expectEqual(4, winrtSlots(winrt.ToastActivatedHandler));

    // The methods the code calls sit at their header positions.
    const ptr = @sizeOf(usize);
    try testing.expectEqual(7 * ptr, @offsetOf(winrt.IToastNotificationManagerStatics.VTable, "CreateToastNotifierWithId"));
    try testing.expectEqual(6 * ptr, @offsetOf(winrt.IToastNotificationFactory.VTable, "CreateToastNotification"));
    try testing.expectEqual(6 * ptr, @offsetOf(winrt.IToastNotifier.VTable, "Show"));
    try testing.expectEqual(11 * ptr, @offsetOf(winrt.IToastNotification.VTable, "add_Activated"));
    try testing.expectEqual(6 * ptr, @offsetOf(winrt.IXmlDocumentIO.VTable, "LoadXml"));
}

test "win32 winrt: toast factory activates" {
    if (winrt.api() == null) return error.SkipZigTest;
    // The app thread is initialized by `App.init`; a test thread joins the MTA.
    const init = win32.ole32.CoInitializeEx(null, 0);
    defer if (foundation.succeeded(init)) win32.ole32.CoUninitialize();
    const statics = winrt.getActivationFactory(winrt.IToastNotificationManagerStatics, winrt.IToastNotificationManagerStatics.class_name) catch |err| {
        std.debug.print("skip: no toast manager factory err={}\n", .{err});
        return error.SkipZigTest;
    };
    com.release(statics);
}

test "win32 winrt: string round trip" {
    if (winrt.api() == null) return error.SkipZigTest;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("hello \u{1F600}");
    var s = try winrt.String.init(text);
    defer s.deinit();
    try testing.expectEqualSlices(u16, text, s.slice());
}
