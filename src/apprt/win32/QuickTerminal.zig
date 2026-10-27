//! The quick terminal: a window of its own kind that slides in from a
//! screen edge, like Ghostty for macOS (`QuickTerminalController`). It is
//! created on first use with one tab, kept hidden between uses (its shell
//! stays alive) and destroyed when its last surface closes.
//!
//! Sizes are physical pixels of the monitor the window is on: percentages
//! of its work area, `px` values and core's pixel defaults scaled by
//! monitor DPI / 96.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const geom = @import("geom.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");

const Config = configpkg.Config;
const user32 = win32.user32;
const HWND = win32.foundation.HWND;

const log = std.log.scoped(.win32_quick);

/// Time between two steps of the slide.
const step_ms = 8;

pub const Anim = struct {
    from: geom.Rect,
    to: geom.Rect,
    start_ns: u64,
    duration_ns: u64,
    hiding: bool,
};

pub const State = struct {
    window: ?*Window = null,
    /// Shown, or sliding in. False as soon as the slide out begins.
    shown: bool = false,
    anim: ?Anim = null,
    /// The foreground window of another application when the terminal was
    /// shown; focus goes back to it when the terminal is toggled away.
    prev_foreground: ?HWND = null,
};

// -- Geometry (pure) --------------------------------------------------------

/// `size` with its pixel values and core's pixel defaults scaled to `dpi`.
fn scaledSize(size: Config.QuickTerminalSize, position: Config.QuickTerminalPosition, dpi: u32) Config.QuickTerminalSize {
    var out = size;
    inline for (.{ &out.primary, &out.secondary }) |field| {
        if (field.*) |v| switch (v) {
            .pixels => |px| field.* = .{ .pixels = scalePx(px, dpi) },
            .percentage => {},
        };
    }
    // The pixel defaults of `QuickTerminalSize.calculate`. A missing
    // secondary size maximizes the axis except for the centered terminal.
    if (out.primary == null) out.primary = .{ .pixels = scalePx(if (position == .center) 800 else 400, dpi) };
    if (out.secondary == null and position == .center) out.secondary = .{ .pixels = scalePx(400, dpi) };
    return out;
}

fn scalePx(px: u32, dpi: u32) u32 {
    const v = geom.scale(@intCast(@min(px, 1 << 24)), dpi);
    return @intCast(@max(v, 0));
}

/// Where the shown terminal goes: anchored to its edge of the work area,
/// centered along the other axis.
pub fn targetRect(
    position: Config.QuickTerminalPosition,
    size: Config.QuickTerminalSize,
    work: geom.Rect,
    dpi: u32,
) geom.Rect {
    const dims = scaledSize(size, position, dpi).calculate(position, .{
        .width = @intCast(@max(work.w, 0)),
        .height = @intCast(@max(work.h, 0)),
    });
    const w: i32 = @intCast(@min(@max(dims.width, 1), @as(u32, @intCast(@max(work.w, 1)))));
    const h: i32 = @intCast(@min(@max(dims.height, 1), @as(u32, @intCast(@max(work.h, 1)))));
    const cx = work.x + @divFloor(work.w - w, 2);
    const cy = work.y + @divFloor(work.h - h, 2);
    return switch (position) {
        .top => .{ .x = cx, .y = work.y, .w = w, .h = h },
        .bottom => .{ .x = cx, .y = work.bottom() - h, .w = w, .h = h },
        .left => .{ .x = work.x, .y = cy, .w = w, .h = h },
        .right => .{ .x = work.right() - w, .y = cy, .w = w, .h = h },
        .center => .{ .x = cx, .y = cy, .w = w, .h = h },
    };
}

/// The rectangle just past the anchored edge, where a slide starts and
/// ends. The centered terminal does not move.
pub fn hiddenRect(position: Config.QuickTerminalPosition, shown: geom.Rect, work: geom.Rect) geom.Rect {
    var r = shown;
    switch (position) {
        .top => r.y = work.y - shown.h,
        .bottom => r.y = work.bottom(),
        .left => r.x = work.x - shown.w,
        .right => r.x = work.right(),
        .center => {},
    }
    return r;
}

/// The slide at `now_ns`: ease-out cubic, exactly `to` once done.
pub fn frameAt(anim: Anim, now_ns: u64) struct { rect: geom.Rect, done: bool } {
    const elapsed = now_ns -| anim.start_ns;
    if (anim.duration_ns == 0 or elapsed >= anim.duration_ns) return .{ .rect = anim.to, .done = true };

    const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(anim.duration_ns));
    const inv = 1.0 - t;
    const e = 1.0 - inv * inv * inv;
    return .{
        .rect = .{
            .x = lerp(anim.from.x, anim.to.x, e),
            .y = lerp(anim.from.y, anim.to.y, e),
            .w = lerp(anim.from.w, anim.to.w, e),
            .h = lerp(anim.from.h, anim.to.h, e),
        },
        .done = false,
    };
}

fn lerp(a: i32, b: i32, e: f64) i32 {
    const d: f64 = @floatFromInt(b - a);
    return a + @as(i32, @intFromFloat(@round(d * e)));
}

/// A toggle during a slide turns it around from where the window is now.
pub fn reverse(anim: Anim, now_ns: u64, duration_ns: u64, shown: geom.Rect, hidden: geom.Rect) Anim {
    return .{
        .from = frameAt(anim, now_ns).rect,
        .to = if (anim.hiding) shown else hidden,
        .start_ns = now_ns,
        .duration_ns = duration_ns,
        .hiding = !anim.hiding,
    };
}

/// How many of `windows` (anything with a `kind`) count for
/// `quit-after-last-window-closed` and the tray: the quick terminal never
/// does, as a hidden macOS window does not keep the app open either.
pub fn countNormal(windows: anytype) usize {
    var n: usize = 0;
    for (windows) |w| {
        if (w.kind == .normal) n += 1;
    }
    return n;
}

/// Whether a tab may be dropped on the strip of a window of `kind`.
pub fn acceptsTabDrop(kind: Window.Kind) bool {
    return kind == .normal;
}

// -- Monitor ----------------------------------------------------------------

pub fn monitorFor(screen: Config.QuickTerminalScreen) ?user32.HMONITOR {
    switch (screen) {
        .main, .@"macos-menu-bar" => {},
        .mouse => {
            var pt: win32.foundation.POINT = .{ .x = 0, .y = 0 };
            if (user32.GetCursorPos(&pt) != 0) {
                if (user32.MonitorFromPoint(pt, user32.MONITOR_DEFAULTTONEAREST)) |m| return m;
            }
        },
    }
    return user32.MonitorFromPoint(.{ .x = 0, .y = 0 }, user32.MONITOR_DEFAULTTOPRIMARY);
}

fn workArea(monitor: user32.HMONITOR) ?geom.Rect {
    var info: user32.MONITORINFO = .{};
    if (user32.GetMonitorInfoW(monitor, &info) == 0) return null;
    return geom.Rect.fromRECT(info.rcWork);
}

// -- Window -----------------------------------------------------------------

fn nowNs() u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toNanoseconds()));
}

fn durationNs(config: *const Config) u64 {
    const s = config.@"quick-terminal-animation-duration";
    if (!(s > 0)) return 0;
    return @intFromFloat(@min(s, 10.0) * std.time.ns_per_s);
}

const Placement = struct { shown: geom.Rect, hidden: geom.Rect };

/// The rectangles on `monitor` at `dpi`.
fn placementOn(config: *const Config, monitor: user32.HMONITOR, dpi: u32) ?Placement {
    const work = workArea(monitor) orelse return null;
    const position = config.@"quick-terminal-position";
    const shown = targetRect(position, config.@"quick-terminal-size", work, dpi);
    return .{ .shown = shown, .hidden = hiddenRect(position, shown, work) };
}

fn setRect(hwnd: HWND, r: geom.Rect) void {
    _ = user32.SetWindowPos(hwnd, null, r.x, r.y, r.w, r.h, user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
}

fn currentRect(hwnd: HWND) geom.Rect {
    var rc: win32.foundation.RECT = undefined;
    if (user32.GetWindowRect(hwnd, &rc) == 0) return .{};
    return geom.Rect.fromRECT(rc);
}

/// Whether `hwnd` belongs to this process.
fn ownWindow(hwnd: ?HWND) bool {
    const h = hwnd orelse return false;
    var pid: u32 = 0;
    _ = user32.GetWindowThreadProcessId(h, &pid);
    return pid == win32.kernel32.GetCurrentProcessId();
}

fn create(app: *App) !*Window {
    const window = try Window.create(app, .{ .kind = .quick });
    app.quick.window = window;
    return window;
}

pub fn configChanged(app: *App, config: *const Config) void {
    const state = &app.quick;
    const window = state.window orelse return;
    if (!state.shown) return;

    const monitor = user32.MonitorFromWindow(window.hwnd, user32.MONITOR_DEFAULTTONEAREST) orelse return;
    const place = placementOn(config, monitor, window.dpi) orelse return;
    // A slide in progress heads for the new place.
    if (state.anim) |*a| {
        a.to = place.shown;
        return;
    }
    setRect(window.hwnd, place.shown);
}

/// `WM_ACTIVATE` (autohide) and `WM_TIMER` (slide) on a quick window.
pub fn windowMessage(
    window: *Window,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    if (window.kind != .quick) return null;
    const app = window.app;
    switch (msg) {
        user32.WM_ACTIVATE => {
            if ((wparam & 0xFFFF) != user32.WA_INACTIVE) return null;
            if (app.quick.window != window or !app.quick.shown) return null;
            if (!app.config.@"quick-terminal-autohide") return null;
            // The window taking the activation: the terminal's own dialogs,
            // overlays and inspector keep it open.
            const other: ?HWND = if (lparam == 0) null else @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (ownWindow(other)) return null;
            hide(app, window, false);
            return null;
        },
        user32.WM_TIMER => {
            if (wparam != messages.timers.window.quick_slide) return null;
            step(app, window);
            return 0;
        },
        else => return null,
    }
}

pub fn windowChanged(window: *Window, change: hooks.WindowChange) void {
    if (change != .destroying) return;
    const state = &window.app.quick;
    if (state.window != window) return;
    _ = user32.KillTimer(window.hwnd, messages.timers.window.quick_slide);
    state.* = .{};
}

/// Show or hide the quick terminal; the `toggle_quick_terminal` action.
pub fn toggle(app: *App) bool {
    toggleOrError(app) catch |err| {
        log.warn("unable to toggle the quick terminal err={}", .{err});
        return false;
    };
    return true;
}

/// The `toggle-quick-terminal` IPC op; false when there is nothing to toggle.
pub fn ipcToggle(app: *App) bool {
    return toggle(app);
}

fn toggleOrError(app: *App) !void {
    const window = app.quick.window orelse try create(app);
    if (app.quick.shown) {
        hide(app, window, true);
    } else {
        show(app, window);
    }
}

fn show(app: *App, window: *Window) void {
    const state = &app.quick;
    const now = nowNs();
    const config = &app.config;

    const was_visible = user32.IsWindowVisible(window.hwnd) != 0;
    if (!was_visible) {
        const fg = user32.GetForegroundWindow();
        state.prev_foreground = if (fg != null and !ownWindow(fg)) fg else null;
    }

    const monitor = monitorFor(config.@"quick-terminal-screen") orelse return;
    // Onto the monitor first: moving between monitors of different DPI
    // updates the window's DPI, which the sizes depend on.
    const work = workArea(monitor) orelse return;
    if (!was_visible) {
        _ = user32.SetWindowPos(window.hwnd, null, work.x, work.y, 0, 0, user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    }
    const place = placementOn(config, monitor, window.dpi) orelse return;
    const duration = durationNs(config);

    state.shown = true;
    if (state.anim) |a| {
        // Turned around mid-slide: from where the window is.
        state.anim = reverse(a, now, duration, place.shown, place.hidden);
    } else {
        const from = if (was_visible) currentRect(window.hwnd) else place.hidden;
        state.anim = .{ .from = from, .to = place.shown, .start_ns = now, .duration_ns = duration, .hiding = false };
        setRect(window.hwnd, from);
    }

    if (!was_visible) {
        _ = user32.ShowWindow(window.hwnd, user32.SW_SHOWNA);
        _ = user32.SetWindowPos(window.hwnd, user32.HWND_TOPMOST, 0, 0, 0, 0, user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOACTIVATE);
    }
    startSlide(window);
    window.activate();
}

/// Slide out. `restore_focus` gives the foreground back to the window the
/// terminal took it from (a toggle; an autohide has lost it already).
fn hide(app: *App, window: *Window, restore_focus: bool) void {
    const state = &app.quick;
    const now = nowNs();
    const config = &app.config;

    state.shown = false;
    const prev = state.prev_foreground;
    state.prev_foreground = null;
    if (restore_focus) {
        if (prev) |p| {
            if (user32.IsWindow(p) != 0) _ = user32.SetForegroundWindow(p);
        }
    }

    // Out to the monitor the window is on.
    const monitor = user32.MonitorFromWindow(window.hwnd, user32.MONITOR_DEFAULTTONEAREST) orelse {
        finish(window);
        return;
    };
    const place = placementOn(config, monitor, window.dpi) orelse {
        finish(window);
        return;
    };
    const duration = durationNs(config);
    if (state.anim) |a| {
        state.anim = reverse(a, now, duration, place.shown, place.hidden);
    } else {
        state.anim = .{ .from = currentRect(window.hwnd), .to = place.hidden, .start_ns = now, .duration_ns = duration, .hiding = true };
    }
    startSlide(window);
}

fn startSlide(window: *Window) void {
    const anim = window.app.quick.anim orelse return;
    // Nothing to animate: land at once.
    if (anim.duration_ns == 0 or std.meta.eql(anim.from, anim.to)) {
        setRect(window.hwnd, anim.to);
        landed(window.app, window);
        return;
    }
    if (user32.SetTimer(window.hwnd, messages.timers.window.quick_slide, step_ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
        setRect(window.hwnd, anim.to);
        landed(window.app, window);
    }
}

fn step(app: *App, window: *Window) void {
    const anim = app.quick.anim orelse {
        _ = user32.KillTimer(window.hwnd, messages.timers.window.quick_slide);
        return;
    };
    const f = frameAt(anim, nowNs());
    setRect(window.hwnd, f.rect);
    if (f.done) landed(app, window);
}

/// The slide ended: a hidden terminal leaves the screen.
fn landed(app: *App, window: *Window) void {
    _ = user32.KillTimer(window.hwnd, messages.timers.window.quick_slide);
    const hiding = if (app.quick.anim) |a| a.hiding else !app.quick.shown;
    app.quick.anim = null;
    if (hiding) finish(window);
}

fn finish(window: *Window) void {
    _ = user32.KillTimer(window.hwnd, messages.timers.window.quick_slide);
    window.app.quick.anim = null;
    _ = user32.ShowWindow(window.hwnd, user32.SW_HIDE);
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    const state = &app.quick;
    try jw.beginObject();
    try jw.objectField("exists");
    try jw.write(state.window != null);
    try jw.objectField("shown");
    try jw.write(state.shown);
    try jw.objectField("animating");
    try jw.write(state.anim != null);
    if (state.window) |w| {
        const r = currentRect(w.hwnd);
        try jw.objectField("window");
        try jw.write(w.id);
        var buf: [32]u8 = undefined;
        try jw.objectField("hwnd");
        try jw.write(std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(w.hwnd)}) catch unreachable);
        try jw.objectField("visible");
        try jw.write(user32.IsWindowVisible(w.hwnd) != 0);
        try jw.objectField("rect");
        try jw.beginObject();
        try jw.objectField("x");
        try jw.write(r.x);
        try jw.objectField("y");
        try jw.write(r.y);
        try jw.objectField("w");
        try jw.write(r.w);
        try jw.objectField("h");
        try jw.write(r.h);
        try jw.endObject();
    }
    try jw.endObject();
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const work_1080: geom.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };

test "win32 quick: targetRect per position and size" {
    const full_half: Config.QuickTerminalSize = .{
        .primary = .{ .percentage = 50 },
        .secondary = .{ .percentage = 100 },
    };
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 1920, .h = 520 }, targetRect(.top, full_half, work_1080, 96));
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 520, .w = 1920, .h = 520 }, targetRect(.bottom, full_half, work_1080, 96));

    // Defaults of core: 400 px on the primary axis, the other maximized.
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 1920, .h = 400 }, targetRect(.top, .{}, work_1080, 96));
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 160, .w = 400, .h = 720 }, targetRect(.left, .{ .secondary = .{ .pixels = 720 } }, work_1080, 96));

    const forty: Config.QuickTerminalSize = .{ .primary = .{ .percentage = 40 } };
    try testing.expectEqual(geom.Rect{ .x = 1152, .y = 0, .w = 768, .h = 1040 }, targetRect(.right, forty, work_1080, 96));

    const half: Config.QuickTerminalSize = .{ .primary = .{ .percentage = 50 }, .secondary = .{ .percentage = 50 } };
    try testing.expectEqual(geom.Rect{ .x = 480, .y = 260, .w = 960, .h = 520 }, targetRect(.center, half, work_1080, 96));
    // Core's centered default: 800 x 400.
    try testing.expectEqual(geom.Rect{ .x = 560, .y = 320, .w = 800, .h = 400 }, targetRect(.center, .{}, work_1080, 96));

    // A work area that does not start at the origin; sizes never exceed it.
    const second: geom.Rect = .{ .x = 1920, .y = 40, .w = 1280, .h = 960 };
    try testing.expectEqual(geom.Rect{ .x = 1920, .y = 40, .w = 1280, .h = 400 }, targetRect(.top, .{}, second, 96));
    try testing.expectEqual(geom.Rect{ .x = 1920, .y = 40, .w = 1280, .h = 960 }, targetRect(.top, .{ .primary = .{ .pixels = 5000 } }, second, 96));

    const px: Config.QuickTerminalSize = .{ .primary = .{ .pixels = 300 }, .secondary = .{ .pixels = 1000 } };
    try testing.expectEqual(geom.Rect{ .x = 460, .y = 0, .w = 1000, .h = 300 }, targetRect(.top, px, work_1080, 96));
}

test "win32 quick: pixel size scales with monitor DPI" {
    const work: geom.Rect = .{ .x = 0, .y = 0, .w = 2880, .h = 1560 };
    const size: Config.QuickTerminalSize = .{ .primary = .{ .pixels = 800 }, .secondary = .{ .pixels = 400 } };
    const r = targetRect(.center, size, work, 144);
    try testing.expectEqual(@as(i32, 1200), r.w);
    try testing.expectEqual(@as(i32, 600), r.h);
    // The default is scaled too.
    const d = targetRect(.top, .{}, work, 144);
    try testing.expectEqual(@as(i32, 600), d.h);
    try testing.expectEqual(@as(i32, 2880), d.w);
}

test "win32 quick: hiddenRect off edge" {
    const shown: geom.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 520 };
    try testing.expectEqual(geom.Rect{ .x = 0, .y = -520, .w = 1920, .h = 520 }, hiddenRect(.top, shown, work_1080));

    const bottom: geom.Rect = .{ .x = 0, .y = 520, .w = 1920, .h = 520 };
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 1040, .w = 1920, .h = 520 }, hiddenRect(.bottom, bottom, work_1080));

    const left: geom.Rect = .{ .x = 0, .y = 100, .w = 400, .h = 840 };
    try testing.expectEqual(geom.Rect{ .x = -400, .y = 100, .w = 400, .h = 840 }, hiddenRect(.left, left, work_1080));

    const right: geom.Rect = .{ .x = 1520, .y = 100, .w = 400, .h = 840 };
    try testing.expectEqual(geom.Rect{ .x = 1920, .y = 100, .w = 400, .h = 840 }, hiddenRect(.right, right, work_1080));

    const center: geom.Rect = .{ .x = 480, .y = 260, .w = 960, .h = 520 };
    try testing.expectEqual(center, hiddenRect(.center, center, work_1080));
}

test "win32 quick: frameAt eases and ends exactly at to" {
    const anim: Anim = .{
        .from = .{ .x = 0, .y = -520, .w = 1920, .h = 520 },
        .to = .{ .x = 0, .y = 0, .w = 1920, .h = 520 },
        .start_ns = 1000,
        .duration_ns = 200_000_000,
        .hiding = false,
    };
    try testing.expectEqual(anim.from, frameAt(anim, 1000).rect);
    try testing.expectEqual(anim.from, frameAt(anim, 0).rect);
    try testing.expect(!frameAt(anim, 1000).done);

    // Ease-out: more than half way at half the time, monotonic.
    const mid = frameAt(anim, 1000 + 100_000_000);
    try testing.expect(!mid.done);
    try testing.expect(mid.rect.y > -260);
    try testing.expect(mid.rect.y < 0);
    var last: i32 = -521;
    var t: u64 = 0;
    while (t < 200_000_000) : (t += 8_000_000) {
        const y = frameAt(anim, 1000 + t).rect.y;
        try testing.expect(y >= last);
        last = y;
    }

    const end = frameAt(anim, 1000 + 200_000_000);
    try testing.expect(end.done);
    try testing.expectEqual(anim.to, end.rect);
    try testing.expectEqual(anim.to, frameAt(anim, 1000 + 999_000_000).rect);

    // No duration: there at once.
    var instant = anim;
    instant.duration_ns = 0;
    try testing.expect(frameAt(instant, 1000).done);
    try testing.expectEqual(anim.to, frameAt(instant, 1000).rect);
}

test "win32 quick: reverse mid-animation" {
    const hidden: geom.Rect = .{ .x = 0, .y = -520, .w = 1920, .h = 520 };
    const shown: geom.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 520 };
    const in: Anim = .{ .from = hidden, .to = shown, .start_ns = 0, .duration_ns = 200_000_000, .hiding = false };

    const now: u64 = 60_000_000;
    const cur = frameAt(in, now).rect;
    const back = reverse(in, now, 200_000_000, shown, hidden);
    try testing.expect(back.hiding);
    try testing.expectEqual(cur, back.from);
    try testing.expectEqual(hidden, back.to);
    try testing.expectEqual(now, back.start_ns);
    // It starts where the window is and does not jump.
    try testing.expectEqual(cur, frameAt(back, now).rect);
    try testing.expectEqual(hidden, frameAt(back, now + 200_000_000).rect);

    // And again: back in.
    const again = reverse(back, now + 10_000_000, 200_000_000, shown, hidden);
    try testing.expect(!again.hiding);
    try testing.expectEqual(shown, again.to);
}

test "win32 quick: window counting ignores quick windows" {
    const W = struct { kind: Window.Kind };
    const none = [_]W{};
    try testing.expectEqual(@as(usize, 0), countNormal(&none));
    const only_quick = [_]W{.{ .kind = .quick }};
    try testing.expectEqual(@as(usize, 0), countNormal(&only_quick));
    const mixed = [_]W{ .{ .kind = .normal }, .{ .kind = .quick }, .{ .kind = .normal } };
    try testing.expectEqual(@as(usize, 2), countNormal(&mixed));
}

test "win32 quick: strip refuses tab drops" {
    try testing.expect(acceptsTabDrop(.normal));
    try testing.expect(!acceptsTabDrop(.quick));
}
