//! Renderer recovery after the health of a surface turned bad (debounced by
//! a timer on the message window).
//!
//! A lost GPU device leaves every surface renderer on the dead generation.
//! The timer finds the surfaces whose renderer reports `deviceLost()`, and
//! unrealizes/realizes their core renderer on the UI thread, as the GTK
//! apprt does: the renderer then moves to a fresh device generation on its
//! own thread (`renderer.D3D11.recoverDevice`). Repeated losses first turn
//! custom shaders off, then the hardware adapter (WARP).
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const renderer = @import("../../renderer.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const badges = @import("badges.zig");
const messages = @import("messages.zig");
const Inspector = @import("inspector/Inspector.zig");

const log = std.log.scoped(.win32_recovery);

/// `rendererHealth` waits this long before the first sweep: one lost
/// device makes every surface unhealthy within a few frames.
const debounce_ms: u32 = 250;

/// While a recovered surface may still fail again, the timer keeps
/// checking at this interval.
const verify_ms: u32 = 500;

/// A surface that is lost again within this time after a recovery counts as
/// a failure of that recovery.
const repeat_window_ms: u64 = 5_000;

/// This many failures within `warp_window_ms` switch to WARP.
const failures_for_warp = 3;
const warp_window_ms: u64 = 60_000;

/// The longest wait between two sweeps while a surface cannot be recovered.
const backoff_cap_ms: u32 = 30_000;

const no_device_text = "Rendering paused: no GPU device could be created. Retrying\u{2026}";
/// Stays on every surface after the switch to WARP, until it is closed.
const warp_final_text = "Software rendering: the GPU kept resetting. Restart Ghostty to use the GPU again.";
const custom_shaders_text = "Rendering paused: the GPU was reset. Custom shaders are turned off. Recovering\u{2026}";
const warp_text = "Rendering paused: the GPU keeps resetting. Switching to software rendering\u{2026}";

/// Surfaces whose last recovery is remembered, to tell a repeated loss from
/// a new one.
const remembered = 16;

pub const State = struct {
    /// The recovery timer is set.
    armed: bool = false,

    /// Times (`nowMs`, never 0) of the last failures, oldest first.
    failures: [failures_for_warp]u64 = .{ 0, 0, 0 },

    /// The hardware adapter was given up (`Device.preferWarp`).
    warp: bool = false,

    /// Custom shaders were turned off after a loss.
    shaders_disabled: bool = false,

    /// Delay of the next sweep while recoveries keep failing.
    backoff_ms: u32 = verify_ms,

    /// Renderers moved to a new device so far (IPC test state).
    recovered: u32 = 0,

    /// Surface ids and `nowMs` of their last recovery, round robin.
    last_id: [remembered]u32 = @splat(0),
    last_ms: [remembered]u64 = @splat(0),
    last_next: u8 = 0,

    fn remember(self: *State, id: u32, now_ms: u64) void {
        for (&self.last_id, &self.last_ms) |*i, *t| {
            if (i.* == id) {
                t.* = now_ms;
                return;
            }
        }
        self.last_id[self.last_next] = id;
        self.last_ms[self.last_next] = now_ms;
        self.last_next = (self.last_next + 1) % remembered;
    }

    /// Whether `id` was recovered less than `repeat_window_ms` ago.
    fn recoveredRecently(self: *const State, id: u32, now_ms: u64) bool {
        for (self.last_id, self.last_ms) |i, t| {
            if (i == id) return now_ms -| t < repeat_window_ms;
        }
        return false;
    }

    /// Whether any surface was recovered less than `repeat_window_ms` ago.
    fn anyRecentRecovery(self: *const State, now_ms: u64) bool {
        for (self.last_id, self.last_ms) |i, t| {
            if (i != 0 and now_ms -| t < repeat_window_ms) return true;
        }
        return false;
    }

    fn recordFailure(self: *State, now_ms: u64) void {
        self.failures[0] = self.failures[1];
        self.failures[1] = self.failures[2];
        self.failures[2] = now_ms;
    }
};

pub const Decision = enum { retry, warp };

/// Whether the failures (times of `nowMs`, 0 = none) call for WARP: three
/// of them within a minute.
pub fn decide(failures: []const u64, now_ms: u64) Decision {
    var recent: usize = 0;
    for (failures) |f| {
        if (f != 0 and now_ms -| f <= warp_window_ms) recent += 1;
    }
    return if (recent >= failures_for_warp) .warp else .retry;
}

pub const ShaderDecision = enum { disable_shaders, count_failure };

/// A loss while a custom shader runs is blamed on the shader first: the
/// shaders are turned off before the loss counts toward WARP, so a shader
/// that hangs the GPU cannot cause three system-wide TDR freezes.
pub fn decideShader(custom_shader_active: bool, shaders_disabled: bool) ShaderDecision {
    return if (custom_shader_active and !shaders_disabled) .disable_shaders else .count_failure;
}

fn nowMs() u64 {
    // Never 0: 0 marks an empty slot.
    return @as(u64, @intCast(@max(0, std.Io.Timestamp.now(global.io(), .awake).toMilliseconds()))) +| 1;
}

/// `WM_TIMER` on the message window; null when the id is not ours.
pub fn timer(app: *App, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    if (wparam != messages.timers.msg_window.recovery) return null;
    _ = win32.user32.KillTimer(app.msg_hwnd, messages.timers.msg_window.recovery);
    app.recovery.armed = false;
    sweep(app, nowMs());
    return 0;
}

/// The renderer of `surface` reported its health. Bad health arms the
/// recovery timer once; good health needs nothing (the badge hides itself).
pub fn rendererHealth(surface: *Surface, health: apprt.Action.Value(.renderer_health)) void {
    if (health == .healthy) {
        // The bar of the switch to WARP is not cleared by a healthy frame.
        if (surface.app.recovery.warp) badges.setHealthText(surface, warp_final_text);
        return;
    }
    arm(surface.app, debounce_ms);
}

fn arm(app: *App, ms: u32) void {
    if (app.recovery.armed) return;
    if (win32.user32.SetTimer(app.msg_hwnd, messages.timers.msg_window.recovery, ms, null) == 0) {
        log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
        return;
    }
    app.recovery.armed = true;
}

/// Seam for the composition mode (Task 15a): called for every surface whose
/// renderer is moved to a new device, after the swap chain was dropped, so
/// the compositor can forget the old chain. The renderer hands the new
/// chain off again by itself (`PresentTarget.hand_off`).
/// `composition.appStarted` installs it.
pub var composition_hook: ?*const fn (surface: *Surface) void = null;

/// One pass over all surfaces: those whose device was lost are moved to a
/// new one.
fn sweep(app: *App, now_ms: u64) void {
    const state = &app.recovery;

    var lost: usize = 0;
    var repeated = false;
    var failed_acquire = false;
    var shader_active = false;
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const s = entry.view;
                if (!isLost(s)) continue;
                lost += 1;
                // A failed attempt to get a device is not the GPU failing again.
                if (s.core_surface.renderer.api.deviceRecoverFailed()) {
                    failed_acquire = true;
                } else if (state.recoveredRecently(s.id, now_ms)) {
                    repeated = true;
                }
                if (customShadersConfigured(s)) shader_active = true;
            }
        }
    }

    if (lost == 0) {
        // A recovered surface may still fail on its first frames.
        state.backoff_ms = verify_ms;
        if (state.anyRecentRecovery(now_ms)) arm(app, verify_ms);
        return;
    }

    var text: ?[]const u8 = null;
    if (failed_acquire) text = no_device_text;
    switch (decideShader(shader_active, renderer.Device.customShadersDisabled())) {
        .disable_shaders => {
            renderer.Device.disableCustomShaders();
            state.shaders_disabled = true;
            text = custom_shaders_text;
            log.warn("custom shaders disabled after device loss", .{});
        },
        .count_failure => if (repeated) {
            state.recordFailure(now_ms);
            if (!state.warp and decide(&state.failures, now_ms) == .warp) {
                state.warp = true;
                text = warp_text;
                renderer.Device.preferWarp();
                log.warn("device lost {d} times within a minute, switching to WARP", .{failures_for_warp});
            }
        },
    }

    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const s = entry.view;
                if (!isLost(s)) continue;
                if (text) |t| badges.setHealthText(s, t);
                recoverSurface(state, s, now_ms);
            }
        }
    }

    Inspector.deviceChanged(app);

    // Surfaces that fail again or cannot get a device are retried less and
    // less often (no unrealize/realize and log line every 500 ms).
    if (repeated or failed_acquire) {
        arm(app, state.backoff_ms);
        state.backoff_ms = @min(state.backoff_ms *| 2, backoff_cap_ms);
    } else {
        state.backoff_ms = verify_ms;
        arm(app, verify_ms);
    }
}

/// Whether the config of the surface names custom shaders. Read under the
/// draw mutex, the render thread writes the renderer state.
fn customShadersConfigured(s: *Surface) bool {
    const r = &s.core_surface.renderer;
    r.draw_mutex.lockUncancelable(global.io());
    defer r.draw_mutex.unlock(global.io());
    return r.has_custom_shaders;
}

fn isLost(s: *Surface) bool {
    if (!s.initialized) return false;
    return s.core_surface.renderer.api.deviceLost();
}

/// Unrealizes and realizes the core renderer (UI thread, like the GTK
/// apprt does), then wakes its thread, which does the move.
fn recoverSurface(state: *State, s: *Surface, now_ms: u64) void {
    s.core_surface.displayUnrealized();
    s.core_surface.displayRealized() catch |err| {
        log.warn("core displayRealized failed err={}", .{err});
        return;
    };
    if (composition_hook) |hook| hook(s);
    s.core_surface.refreshCallback() catch |err|
        log.warn("refresh after a device loss failed err={}", .{err});
    state.remember(s.id, now_ms);
    state.recovered += 1;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    const state = &app.recovery;
    try jw.beginObject();
    try jw.objectField("armed");
    try jw.write(state.armed);
    try jw.objectField("warp");
    try jw.write(state.warp);
    try jw.objectField("shaders_disabled");
    try jw.write(state.shaders_disabled);
    try jw.objectField("recovered");
    try jw.write(state.recovered);
    var bars: u32 = 0;
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.badges.health) |label| {
                    if (label.popup.visible) bars += 1;
                }
            }
        }
    }
    // Surfaces showing the health bar right now.
    try jw.objectField("bars");
    try jw.write(bars);
    try jw.endObject();
}

test "win32 recovery: decide" {
    const ms = std.time.ms_per_s;
    // One or two failures retry.
    try std.testing.expectEqual(Decision.retry, decide(&.{ 0, 0, 0 }, 10 * ms));
    try std.testing.expectEqual(Decision.retry, decide(&.{ 0, 5 * ms, 9 * ms }, 10 * ms));
    // Three within 60 s switch to WARP.
    try std.testing.expectEqual(Decision.warp, decide(&.{ 1 * ms, 20 * ms, 40 * ms }, 41 * ms));
    // Three spread over two minutes do not.
    try std.testing.expectEqual(Decision.retry, decide(&.{ 1 * ms, 60 * ms, 120 * ms }, 121 * ms));
}

test "win32 recovery: custom shader is disabled before counting toward WARP" {
    try std.testing.expectEqual(ShaderDecision.disable_shaders, decideShader(true, false));
    try std.testing.expectEqual(ShaderDecision.count_failure, decideShader(true, true));
    try std.testing.expectEqual(ShaderDecision.count_failure, decideShader(false, false));
    try std.testing.expectEqual(ShaderDecision.count_failure, decideShader(false, true));
}

test "win32 recovery: failures keep the last three and repeats are windowed" {
    var state: State = .{};
    state.recordFailure(1_000);
    state.recordFailure(2_000);
    state.recordFailure(3_000);
    state.recordFailure(4_000);
    try std.testing.expectEqualSlices(u64, &.{ 2_000, 3_000, 4_000 }, &state.failures);

    state.remember(7, 10_000);
    try std.testing.expect(state.recoveredRecently(7, 12_000));
    try std.testing.expect(!state.recoveredRecently(7, 16_000));
    try std.testing.expect(!state.recoveredRecently(8, 12_000));
    try std.testing.expect(state.anyRecentRecovery(12_000));
    try std.testing.expect(!state.anyRecentRecovery(16_000));
}
