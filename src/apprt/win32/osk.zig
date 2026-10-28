//! On-screen keyboard (owner: M5 Task 16, R-M5-13). `show_on_screen_keyboard`
//! toggles the touch keyboard only while it is hidden (an empty
//! IFrameworkInputPane rect); it never hides it. COM runs on the UI thread,
//! which is already an STA.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const win32 = @import("win32");
const App = @import("App.zig");
const ipc_ops = @import("ipc/ops.zig");

const foundation = win32.foundation;
const tip = win32.tip;
const com = win32.com;

const log = std.log.scoped(.win32_osk);

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

pub const Decision = enum { toggle, nothing };

/// A null rect (Location failed) means the state is unknown: toggle.
pub fn decide(rect: ?foundation.RECT) Decision {
    const r = rect orelse return .toggle;
    return if (r.right <= r.left or r.bottom <= r.top) .toggle else .nothing;
}

/// The side effects, injectable for tests.
pub const Ops = struct {
    ctx: *anyopaque,
    location: *const fn (*anyopaque) ?foundation.RECT,
    toggle: *const fn (*anyopaque) foundation.HRESULT,
    launch: *const fn (*anyopaque) void,
};

pub const Outcome = enum { already_visible, toggled, failed };

pub fn run(ops: Ops) Outcome {
    if (decide(ops.location(ops.ctx)) == .nothing) return .already_visible;
    var hr = ops.toggle(ops.ctx);
    if (hr == tip.REGDB_E_CLASSNOTREG) {
        // TabTip is not running: start it, then retry once.
        ops.launch(ops.ctx);
        hr = ops.toggle(ops.ctx);
    }
    return if (foundation.succeeded(hr)) .toggled else .failed;
}

/// Counts `show_on_screen_keyboard` calls in test mode (nothing is shown).
var requests: u32 = 0;

fn testMode() bool {
    return ipc_ops.testOpsEnabled();
}

fn realLocation(_: *anyopaque) ?foundation.RECT {
    var pane: ?*anyopaque = null;
    const hr = win32.ole32.CoCreateInstance(&tip.CLSID_FrameworkInputPane, null, win32.ole32.CLSCTX_INPROC_SERVER, &tip.IID_IFrameworkInputPane, &pane);
    if (!foundation.succeeded(hr)) return null;
    const p: *tip.IFrameworkInputPane = @ptrCast(@alignCast(pane orelse return null));
    defer com.release(p);
    var rect: foundation.RECT = std.mem.zeroes(foundation.RECT);
    if (!foundation.succeeded(p.location(&rect))) return null;
    return rect;
}

fn realToggle(_: *anyopaque) foundation.HRESULT {
    var obj: ?*anyopaque = null;
    const hr = win32.ole32.CoCreateInstance(&tip.CLSID_UIHostNoLaunch, null, win32.ole32.CLSCTX_INPROC_SERVER | tip.CLSCTX_LOCAL_SERVER, &tip.IID_ITipInvocation, &obj);
    if (!foundation.succeeded(hr)) return hr;
    const t: *tip.ITipInvocation = @ptrCast(@alignCast(obj orelse return foundation.E_FAIL));
    defer com.release(t);
    return t.toggle(tip.GetDesktopWindow());
}

fn realLaunch(_: *anyopaque) void {
    var buf: [std.fs.max_path_bytes / 2]u16 = undefined;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("CommonProgramFiles");
    const n = GetEnvironmentVariableW(name, &buf, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\microsoft shared\\ink\\TabTip.exe");
    if (n + suffix.len >= buf.len) return;
    @memcpy(buf[n..][0..suffix.len], suffix);
    buf[n + suffix.len] = 0;
    const r = win32.shell32.ShellExecuteW(null, null, @ptrCast(&buf), null, null, 1);
    if (r <= 32) log.warn("unable to start TabTip.exe code={d}", .{r});
    // The keyboard host needs a moment to register its class.
    Sleep(300);
}

pub fn show(app: *App, target: apprt.Target, value: void) !bool {
    _ = app;
    _ = target;
    _ = value;
    if (testMode()) {
        requests += 1;
        return true;
    }
    var dummy: u8 = 0;
    const out = run(.{ .ctx = &dummy, .location = realLocation, .toggle = realToggle, .launch = realLaunch });
    if (out == .failed) log.warn("unable to open the touch keyboard", .{});
    return out != .failed;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    _ = app;
    try jw.beginObject();
    try jw.objectField("requests");
    try jw.write(requests);
    try jw.endObject();
}

// -- Tests --------------------------------------------------------------------------

const Fake = struct {
    rect: ?foundation.RECT = null,
    results: []const foundation.HRESULT = &.{},
    toggles: usize = 0,
    launches: usize = 0,

    fn location(ctx: *anyopaque) ?foundation.RECT {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.rect;
    }
    fn toggle(ctx: *anyopaque) foundation.HRESULT {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        defer self.toggles += 1;
        return self.results[@min(self.toggles, self.results.len - 1)];
    }
    fn launch(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.launches += 1;
    }
    fn ops(self: *Fake) Ops {
        return .{ .ctx = self, .location = location, .toggle = toggle, .launch = launch };
    }
};

test "win32 osk: decision" {
    const empty = std.mem.zeroes(foundation.RECT);
    const shown: foundation.RECT = .{ .left = 0, .top = 500, .right = 1000, .bottom = 800 };
    try std.testing.expectEqual(Decision.toggle, decide(empty));
    try std.testing.expectEqual(Decision.toggle, decide(null));
    try std.testing.expectEqual(Decision.nothing, decide(shown));

    var f: Fake = .{ .rect = shown, .results = &.{foundation.S_OK} };
    try std.testing.expectEqual(Outcome.already_visible, run(f.ops()));
    try std.testing.expectEqual(@as(usize, 0), f.toggles);

    f = .{ .rect = empty, .results = &.{foundation.S_OK} };
    try std.testing.expectEqual(Outcome.toggled, run(f.ops()));
    try std.testing.expectEqual(@as(usize, 1), f.toggles);
    try std.testing.expectEqual(@as(usize, 0), f.launches);
}

test "win32 osk: class not registered launches TabTip" {
    var f: Fake = .{
        .rect = std.mem.zeroes(foundation.RECT),
        .results = &.{ tip.REGDB_E_CLASSNOTREG, foundation.S_OK },
    };
    try std.testing.expectEqual(Outcome.toggled, run(f.ops()));
    try std.testing.expectEqual(@as(usize, 1), f.launches);
    try std.testing.expectEqual(@as(usize, 2), f.toggles);

    // Still not registered after the launch: one retry only.
    f = .{ .rect = null, .results = &.{tip.REGDB_E_CLASSNOTREG} };
    try std.testing.expectEqual(Outcome.failed, run(f.ops()));
    try std.testing.expectEqual(@as(usize, 1), f.launches);
    try std.testing.expectEqual(@as(usize, 2), f.toggles);
}
