//! UI-thread handlers of IPC operations. The IPC thread only moves bytes;
//! `handle` runs on the UI thread (from `WM_GHOSTTY_IPC`) and turns one
//! request into one response.
//!
//! The user-facing ops (`new-window`, `new-tab`, `toggle-quick-terminal`)
//! are always served. The test ops (`action`, `dpi`, `color-scheme`, `export-io`,
//! `state`) answer `unknown op` unless the process was started with
//! `GHOSTTY_WIN32_TEST_IPC=1`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const global = @import("../../../global.zig");
const App = @import("../App.zig");
const Overrides = @import("../Overrides.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../Window.zig");
const geom = @import("../geom.zig");
const instance = @import("../instance.zig");
const theme = @import("../theme.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const QuickTerminal = @import("../QuickTerminal.zig");
const export_io = @import("../export_io.zig");
const hooks = @import("../hooks.zig");
const scrollbar = @import("../scrollbar.zig");

const log = std.log.scoped(.win32_ipc_ops);

const kernel32 = win32.kernel32;
const user32 = win32.user32;

const test_ops_var = "GHOSTTY_WIN32_TEST_IPC";

/// Test hook: replaces the answer of `testOpsEnabled`.
pub var test_ops_override: ?bool = null;

/// 0 not read yet, 1 off, 2 on.
var test_ops_cache: std.atomic.Value(u8) = .init(0);

/// Reads `GHOSTTY_WIN32_TEST_IPC` once and removes it from the process
/// environment, so that shells and nested launches never inherit test ops.
/// Called at startup, before any child process exists.
pub fn cacheTestOps(alloc: Allocator) void {
    const on = if (@import("../../../os/main.zig").windows.diagnosticEnv(alloc, test_ops_var)) |value| blk: {
        defer alloc.free(value);
        break :blk std.mem.eql(u8, value, "1");
    } else false;
    test_ops_cache.store(if (on) 2 else 1, .release);
    _ = kernel32.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(test_ops_var), null);
}

/// Whether the test ops are served: `GHOSTTY_WIN32_TEST_IPC` was `1` at
/// process start.
pub fn testOpsEnabled() bool {
    if (test_ops_override) |o| return o;
    return test_ops_cache.load(.acquire) == 2;
}

/// Answers one request. Never fails: errors become a response. The result
/// is owned by the caller (allocated with `alloc`).
pub fn handle(app: *App, alloc: Allocator, request: []const u8) []u8 {
    return handleEarly(app, alloc, request, null).?;
}

/// Like `handle`, but with `early` the ops that create windows answer `ok`
/// through it as soon as the request is accepted, before the (slow) window
/// is built, so the client never times out on window creation and starts a
/// second window of its own. The result is then null: it was answered.
pub fn handleEarly(app: *App, alloc: Allocator, request: []const u8, early: ?*Server.Pending) ?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const req = protocol.parseRequest(a, request) catch |err| return switch (err) {
        error.BadRequest => reply(alloc, .bad_request, "", "bad request", null),
        error.OutOfMemory => reply(alloc, .failed, "", "out of memory", null),
    };
    if (req.v != protocol.version) {
        return reply(alloc, .version_mismatch, "", "protocol version mismatch", null);
    }
    if (protocol.expired(req, kernel32.GetTickCount64())) {
        return reply(alloc, .failed, "", "expired", null);
    }

    const op = std.meta.stringToEnum(Op, req.op) orelse
        return reply(alloc, .bad_request, "", "unknown op", null);
    if (op.isTest() and !testOpsEnabled()) {
        return reply(alloc, .bad_request, "", "unknown op", null);
    }

    return switch (op) {
        .@"new-window" => newWindow(app, alloc, a, req, early),
        .@"new-tab" => newTab(app, alloc, a, req, early),
        .@"toggle-quick-terminal" => toggleQuickTerminal(app, alloc),
        .action => action(app, alloc, req),
        .dpi => setDpi(app, alloc, req),
        .pwd => setPwd(app, alloc, req),
        .@"color-scheme" => colorScheme(app, alloc, req),
        .state => state(app, alloc),
        .@"export-io" => exportIo(app, alloc, req),
    };
}

const Op = enum {
    @"new-window",
    @"new-tab",
    @"toggle-quick-terminal",
    action,
    dpi,
    pwd,
    @"color-scheme",
    state,
    @"export-io",

    fn isTest(self: Op) bool {
        return switch (self) {
            .@"new-window", .@"new-tab", .@"toggle-quick-terminal" => false,
            .action, .dpi, .pwd, .@"color-scheme", .state, .@"export-io" => true,
        };
    }
};

fn reply(
    alloc: Allocator,
    code: protocol.Code,
    stdout: []const u8,
    stderr: []const u8,
    data_json: ?[]const u8,
) []u8 {
    return protocol.encodeResponse(alloc, code, stdout, stderr, data_json) catch {
        // Out of memory twice over: nothing can be allocated for an answer. An
        // empty one frees as a no-op; `Server` turns it into "no response".
        return &.{};
    };
}

/// The overrides of a forwarded request. A command never comes through the
/// pipe, whatever a client sent (defence in depth).
fn overridesOf(alloc: Allocator, arena: Allocator, req: protocol.Request) union(enum) {
    ok: Overrides,
    refused: []u8,
} {
    if (!Overrides.forwardable(req.args)) {
        return .{ .refused = reply(alloc, .failed, "", "arguments are not accepted over IPC", null) };
    }
    const overrides = Overrides.parse(arena, req.args) catch |err| {
        log.warn("invalid IPC arguments err={}", .{err});
        return .{ .refused = reply(alloc, .failed, "", "invalid arguments", null) };
    };
    return .{ .ok = overrides };
}

fn newWindow(app: *App, alloc: Allocator, arena: Allocator, req: protocol.Request, early: ?*Server.Pending) ?[]u8 {
    const overrides = switch (overridesOf(alloc, arena, req)) {
        .ok => |o| o,
        .refused => |r| return r,
    };
    return openWindow(app, alloc, null, overrides, early);
}

/// Answers `ok` through `early` (when given) and reports whether it did.
fn answerEarly(alloc: Allocator, early: ?*Server.Pending) bool {
    const pending = early orelse return false;
    Server.complete(pending, reply(alloc, .ok, "", "", null));
    return true;
}

fn openWindow(app: *App, alloc: Allocator, parent: ?*CoreSurface, overrides: Overrides, early: ?*Server.Pending) ?[]u8 {
    const answered = answerEarly(alloc, early);
    const window = Window.create(app, .{ .parent = parent, .overrides = overrides }) catch |err| {
        log.warn("unable to create a window err={}", .{err});
        if (answered) return null;
        return reply(alloc, .failed, "", "unable to create a window", null);
    };
    window.show();
    _ = user32.SetForegroundWindow(window.hwnd);
    if (answered) return null;
    return reply(alloc, .ok, "", "", null);
}

fn newTab(app: *App, alloc: Allocator, arena: Allocator, req: protocol.Request, early: ?*Server.Pending) ?[]u8 {
    const overrides = switch (overridesOf(alloc, arena, req)) {
        .ok => |o| o,
        .refused => |r| return r,
    };
    const id = std.fmt.parseInt(u64, req.core_surface, 10) catch
        return reply(alloc, .bad_request, "", "bad surface id", null);

    const core = if (id == 0)
        app.core_app.focusedSurface()
    else
        app.core_app.findSurfaceByID(id);
    const window = if (core) |c| app.windowFor(c) else null;

    const w = window orelse return openWindow(app, alloc, core, overrides, early);
    const answered = answerEarly(alloc, early);
    _ = w.addTab(.{ .parent = core, .overrides = overrides }) catch |err| {
        log.warn("unable to create a tab err={}", .{err});
        if (answered) return null;
        return reply(alloc, .failed, "", "unable to create a tab", null);
    };
    _ = user32.SetForegroundWindow(w.hwnd);
    if (answered) return null;
    return reply(alloc, .ok, "", "", null);
}

/// The surface a test op addresses: `id` of this process (window-local
/// ids are unique), 0 for the focused one.
fn targetSurface(app: *App, id: u32) ?*Surface {
    if (id != 0) {
        for (app.windows.items) |w| {
            if (w.findSurface(id)) |s| return s;
        }
        return null;
    }
    if (app.core_app.focusedSurface()) |core| {
        if (app.surfaceFor(core)) |s| return s;
    }
    const w = app.last_active orelse return null;
    const tab = w.activeTab() orelse return null;
    return tab.focusedSurface();
}

fn targetWindow(app: *App, id: u32) ?*Window {
    if (id != 0) {
        for (app.windows.items) |w| {
            if (w.id == id) return w;
        }
        return null;
    }
    if (app.last_active) |w| return w;
    return app.lastNormalWindow();
}

fn action(app: *App, alloc: Allocator, req: protocol.Request) []u8 {
    const parsed = input.Binding.Action.parse(req.action) catch
        return reply(alloc, .bad_request, "", "invalid action", null);
    const surface = targetSurface(app, req.surface) orelse
        return reply(alloc, .failed, "", "no such surface", null);
    const performed = surface.core().performBindingAction(parsed) catch |err| {
        log.warn("binding action failed err={}", .{err});
        return reply(alloc, .failed, "", "action failed", null);
    };
    return reply(alloc, .ok, "", "", if (performed) "{\"performed\":true}" else "{\"performed\":false}");
}

fn setDpi(app: *App, alloc: Allocator, req: protocol.Request) []u8 {
    const window = targetWindow(app, req.window) orelse
        return reply(alloc, .failed, "", "no such window", null);
    window.applyDpi(req.dpi, null);
    return reply(alloc, .ok, "", "", null);
}

/// Test op: the focused surface of the window reports `path` as its working
/// directory (as OSC 7 will, once it is translated for Windows).
fn setPwd(app: *App, alloc: Allocator, req: protocol.Request) []u8 {
    const window = targetWindow(app, req.window) orelse
        return reply(alloc, .failed, "", "no such window", null);
    const tab = window.activeTab() orelse return reply(alloc, .failed, "", "no tab", null);
    const surface = tab.focusedSurface() orelse return reply(alloc, .failed, "", "no surface", null);
    surface.setPwd(req.path) catch return reply(alloc, .failed, "", "out of memory", null);
    window.surfaceTitleChanged(surface);
    return reply(alloc, .ok, "", "", null);
}

fn colorScheme(app: *App, alloc: Allocator, req: protocol.Request) []u8 {
    const scheme = std.meta.stringToEnum(apprt.ColorScheme, req.scheme) orelse
        return reply(alloc, .bad_request, "", "invalid scheme", null);
    theme.schemeChanged(app, scheme);
    return reply(alloc, .ok, "", "", null);
}

fn toggleQuickTerminal(app: *App, alloc: Allocator) []u8 {
    if (!QuickTerminal.ipcToggle(app)) {
        return reply(alloc, .failed, "", "quick terminal could not be toggled", null);
    }
    return reply(alloc, .ok, "", "", null);
}

/// A test-op destination: an absolute path on a drive (`X:\`). UNC, device
/// (`\\?\`, `\\.\`), rooted-only and relative paths are refused.
fn testPathOk(path: []const u8) bool {
    if (path.len < 3) return false;
    if (!std.ascii.isAlphabetic(path[0]) or path[1] != ':') return false;
    if (path[2] != '\\' and path[2] != '/') return false;
    if (path.len > 3 and (path[3] == '\\' or path[3] == '/')) return false;
    return std.mem.indexOfScalar(u8, path, 0) == null;
}

test "win32 ipc: export-io path must be an absolute drive path" {
    const testing = std.testing;
    try testing.expect(testPathOk("C:\\tmp\\out.txt"));
    try testing.expect(testPathOk("d:/tmp/out.txt"));
    try testing.expect(!testPathOk(""));
    try testing.expect(!testPathOk("out.txt"));
    try testing.expect(!testPathOk("C:out.txt"));
    try testing.expect(!testPathOk("\\tmp\\out.txt"));
    try testing.expect(!testPathOk("\\\\server\\share\\x"));
    try testing.expect(!testPathOk("//server/share/x"));
    try testing.expect(!testPathOk("\\\\?\\C:\\x"));
    try testing.expect(!testPathOk("\\\\.\\C:\\x"));
    try testing.expect(!testPathOk("C:\\\\x"));
    try testing.expect(!export_io.pathSafe("C:\\tmp\\..\\x"));
    try testing.expect(!export_io.pathSafe("C:\\tmp\\x.txt:s"));
}

/// Test op: what the inspector's export button emits, which a script cannot
/// click. `path` is the destination; no dialog is shown.
fn exportIo(app: *App, alloc: Allocator, req: protocol.Request) []u8 {
    const surface = targetSurface(app, req.surface) orelse
        return reply(alloc, .failed, "", "no such surface", null);
    if (!testPathOk(req.path) or !export_io.pathSafe(req.path)) return reply(alloc, .bad_request, "", "invalid path", null);
    const saved = export_io.saveTest(app, .{ .surface = surface.core() }, .{ .contents = req.text }, req.path);
    if (!saved) return reply(alloc, .failed, "", "export failed", null);
    return reply(alloc, .ok, "", "", null);
}

fn state(app: *App, alloc: Allocator) []u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    writeState(&aw.writer, app) catch return reply(alloc, .failed, "", "out of memory", null);
    return reply(alloc, .ok, "", "", aw.written());
}

fn writeState(w: *std.Io.Writer, app: *App) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    try jw.objectField("class");
    try jw.write(app.config.class orelse instance.defaultClass());
    try jw.objectField("serving");
    try jw.write(app.serving());
    try jw.objectField("elevated");
    try jw.write(instance.isElevated());
    try jw.objectField("pipe_owner");
    try jw.write(app.serving());
    try jw.objectField("tray");
    try jw.beginObject();
    try jw.objectField("visible");
    try jw.write(app.tray.visible);
    try jw.endObject();
    try jw.objectField("windows");
    try jw.beginArray();
    for (app.windows.items) |window| try writeWindow(&jw, window);
    try jw.endArray();
    try hooks.testState(app, &jw);
    try jw.endObject();
}

fn rectArray(r: geom.Rect) [4]i32 {
    return .{ r.x, r.y, r.right(), r.bottom() };
}

fn rectOf(rc: win32.foundation.RECT) [4]i32 {
    return .{ rc.left, rc.top, rc.right, rc.bottom };
}

fn writeHwnd(jw: *std.json.Stringify, hwnd: win32.foundation.HWND) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(hwnd)}) catch unreachable;
    try jw.write(text);
}

fn writeWindow(jw: *std.json.Stringify, window: *Window) !void {
    const hwnd = window.hwnd;
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(window.id);
    try jw.objectField("hwnd");
    try writeHwnd(jw, hwnd);
    try jw.objectField("title");
    try jw.write(if (window.title_override) |t| t else if (window.activeTab()) |tab| tab.title() else "Ghostty");
    try jw.objectField("dpi");
    try jw.write(window.dpi);
    try jw.objectField("maximized");
    try jw.write(user32.IsZoomed(hwnd) != 0);
    try jw.objectField("minimized");
    try jw.write(user32.IsIconic(hwnd) != 0);
    try jw.objectField("fullscreen");
    try jw.write(window.placement.fullscreen);
    try jw.objectField("topmost");
    try jw.write(window.placement.topmost);
    try jw.objectField("decorations");
    try jw.write(@tagName(window.frame.decorations));

    // Client area in screen coordinates.
    var client: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = user32.GetClientRect(hwnd, &client);
    var corners = [2]win32.foundation.POINT{
        .{ .x = client.left, .y = client.top },
        .{ .x = client.right, .y = client.bottom },
    };
    _ = user32.ClientToScreen(hwnd, &corners[0]);
    _ = user32.ClientToScreen(hwnd, &corners[1]);
    try jw.objectField("client");
    try jw.write([4]i32{ corners[0].x, corners[0].y, corners[1].x, corners[1].y });

    var outer: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = user32.GetWindowRect(hwnd, &outer);
    try jw.objectField("window");
    try jw.write(rectOf(outer));

    try jw.objectField("cell");
    if (window.cell_size) |c| {
        try jw.write([2]u32{ c.width, c.height });
    } else {
        try jw.write([2]u32{ 0, 0 });
    }

    try jw.objectField("progress");
    if (window.taskbar.progress) |p| {
        try jw.beginObject();
        try jw.objectField("state");
        try jw.write(@tagName(p.state));
        try jw.objectField("value");
        try jw.write(p.progress);
        try jw.endObject();
    } else {
        try jw.write(null);
    }

    try jw.objectField("active_tab");
    try jw.write(window.active_tab);

    try writeStrip(jw, window);

    try jw.objectField("tabs");
    try jw.beginArray();
    for (window.tabs.items, 0..) |tab, i| try writeTab(jw, window, tab, i == window.active_tab);
    try jw.endArray();
    try jw.endObject();
}

fn writeStrip(jw: *std.json.Stringify, window: *Window) !void {
    const strip = &window.strip;
    try jw.objectField("strip");
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(@tagName(strip.mode));
    try jw.objectField("bounds");
    try jw.write(rectArray(strip.bounds));
    try jw.objectField("tabs");
    try jw.beginArray();
    for (strip.tabs.items) |r| try jw.write(rectArray(r));
    try jw.endArray();
    inline for (.{ "title_row", "tab_row", "track", "title_text" }) |name| {
        try jw.objectField(name);
        try jw.write(rectArray(@field(strip, name)));
    }
    inline for (.{ "new_tab", "minimize", "maximize", "close", "proxy_icon" }) |name| {
        try jw.objectField(name);
        if (@field(strip, name)) |r| try jw.write(rectArray(r)) else try jw.write(null);
    }
    try jw.objectField("caption");
    try jw.write(rectArray(strip.caption));
    try jw.endObject();
}

fn writeTab(jw: *std.json.Stringify, window: *Window, tab: *Tab, active: bool) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(tab.id);
    try jw.objectField("title");
    try jw.write(tab.title());
    try jw.objectField("zoomed");
    try jw.write(tab.tree.zoomed != null);
    try jw.objectField("bell");
    try jw.write(tab.bellRinging());
    try jw.objectField("surfaces");
    try jw.beginArray();
    const focused = tab.focusedSurface();
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        try writeSurface(jw, window, entry.view, active and entry.view == focused);
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeSurface(jw: *std.json.Stringify, window: *Window, s: *Surface, focused: bool) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(s.id);
    // A u64 does not survive a JSON number in PowerShell.
    try jw.objectField("core_id");
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{s.core_surface.id}) catch unreachable);
    try jw.objectField("hwnd");
    try writeHwnd(jw, s.hwnd);

    // In the coordinates of the window's client area.
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = user32.GetWindowRect(s.hwnd, &rc);
    var pts = [2]win32.foundation.POINT{
        .{ .x = rc.left, .y = rc.top },
        .{ .x = rc.right, .y = rc.bottom },
    };
    _ = user32.MapWindowPoints(null, window.hwnd, &pts, 2);
    try jw.objectField("rect");
    try jw.write([4]i32{ pts[0].x, pts[0].y, pts[1].x, pts[1].y });

    try jw.objectField("visible");
    try jw.write(user32.IsWindowVisible(s.hwnd) != 0);
    try jw.objectField("focused");
    try jw.write(focused);
    try jw.objectField("title");
    try jw.write(s.getTitle() orelse "");
    try jw.objectField("pwd");
    try jw.write(s.getPwd() orelse "");
    try jw.objectField("scale");
    try jw.write(s.content_scale.x);
    try jw.objectField("scrollbar");
    try jw.beginObject();
    try jw.objectField("total");
    try jw.write(s.scrollbar.total);
    try jw.objectField("offset");
    try jw.write(s.scrollbar.offset);
    try jw.objectField("len");
    try jw.write(s.scrollbar.len);
    // The overlay scroller: shown, and its knob in px from the top of the surface.
    try jw.objectField("scroller_visible");
    try jw.write(scrollbar.knobOf(s) != null);
    try jw.objectField("scroller_alpha");
    try jw.write(s.scrollbar.alpha);
    try jw.objectField("knob");
    if (scrollbar.knobOf(s)) |k| try jw.write([2]i32{ k.y, k.h }) else try jw.write(null);
    try jw.endObject();
    try jw.endObject();
}

fn expectCode(alloc: Allocator, bytes: []const u8, code: protocol.Code) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const resp = try protocol.parseResponse(arena.allocator(), bytes);
    try std.testing.expectEqual(code, resp.code);
}

test "win32 ipc ops: unknown and test ops are refused without the env flag" {
    const testing = std.testing;
    test_ops_override = false;
    defer test_ops_override = null;

    // The app is never touched by any of these.
    const app: *App = undefined;

    const cases = [_]struct { json: []const u8, code: protocol.Code }{
        .{ .json = "{\"v\":1,\"op\":\"state\"}", .code = .bad_request },
        .{ .json = "{\"v\":1,\"op\":\"action\",\"action\":\"reset\"}", .code = .bad_request },
        .{ .json = "{\"v\":1,\"op\":\"dpi\",\"dpi\":144}", .code = .bad_request },
        .{ .json = "{\"v\":1,\"op\":\"color-scheme\",\"scheme\":\"dark\"}", .code = .bad_request },
        .{ .json = "{\"v\":1,\"op\":\"nonsense\"}", .code = .bad_request },
        .{ .json = "not json", .code = .bad_request },
        .{ .json = "{\"v\":2,\"op\":\"state\"}", .code = .version_mismatch },
        .{ .json = "{\"v\":1,\"op\":\"new-window\",\"deadline_ms\":1}", .code = .failed },
        .{ .json = "{\"v\":1,\"op\":\"new-window\",\"args\":[\"-e\",\"x\"]}", .code = .failed },
        .{ .json = "{\"v\":1,\"op\":\"new-tab\",\"args\":[\"--command=x\"]}", .code = .failed },
    };
    for (cases) |c| {
        const out = handle(app, testing.allocator, c.json);
        defer testing.allocator.free(out);
        expectCode(testing.allocator, out, c.code) catch |err| {
            std.debug.print("request {s}: {s}\n", .{ c.json, out });
            return err;
        };
    }
}
