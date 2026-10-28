//! Taskbar progress (ITaskbarList3, OSC 9;4). One progress per window: the
//! last report from any surface wins.
const std = @import("std");
const win32 = @import("win32");
const terminal = @import("../../terminal/main.zig");
const messages = @import("messages.zig");
const Window = @import("Window.zig");

const com = win32.com;
const ITaskbarList3 = win32.shell32.ITaskbarList3;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;

const log = std.log.scoped(.win32_taskbar);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const Report = terminal.osc.Command.ProgressReport;

/// A report that is not refreshed for this long is dropped, like GTK does,
/// so a program that died mid-progress does not leave the bar up.
const stale_timeout_ms: u32 = 15_000;
/// `WM_TIMER` id of the stale timer on a top-level window.
const stale_timer_id: usize = messages.timers.window.taskbar_stale;

pub const State = struct {
    progress: ?Report = null,
    /// The surface (by id) that made the report; 0 when none.
    reporter: u32 = 0,
    /// Created lazily, again after every "TaskbarButtonCreated".
    list: ?*ITaskbarList3 = null,
    /// The reports of parked surfaces (they may come back with an undo), one
    /// per surface; the oldest is replaced when the slots run out.
    stash: [stash_slots]?Stashed = @splat(null),

    const Stashed = struct { reporter: u32, report: Report };
    const stash_slots = 4;

    /// The surface `id` is parked: its report moves to the stash. False when
    /// the bar shows nothing of it.
    fn dropFor(self: *State, id: u32) bool {
        const p = self.progress orelse return false;
        if (self.reporter != id) return false;
        self.forget(id);
        // Free slot, else the oldest (slot 0) goes.
        var at: usize = 0;
        for (self.stash, 0..) |s, i| {
            if (s == null) {
                at = i;
                break;
            }
        } else {
            std.mem.copyForwards(?Stashed, self.stash[0 .. stash_slots - 1], self.stash[1..]);
            at = stash_slots - 1;
        }
        self.stash[at] = .{ .reporter = id, .report = p };
        return true;
    }

    /// The surface `id` is gone for good (or left the window): no report of
    /// it may come back.
    fn forget(self: *State, id: u32) void {
        for (&self.stash) |*s| {
            if (s.*) |v| if (v.reporter == id) {
                s.* = null;
            };
        }
    }

    /// The report to show again for the surface `id` that came back: only
    /// while nothing else is on the bar.
    fn takeStash(self: *State, id: u32) ?Report {
        for (&self.stash) |*s| {
            const v = s.* orelse continue;
            if (v.reporter != id) continue;
            s.* = null;
            if (self.progress != null) return null;
            return v.report;
        }
        return null;
    }
};

/// `TBPF_*` for a progress state.
pub fn tbpfFor(state: Report.State) u32 {
    return switch (state) {
        .remove => win32.shell32.TBPF_NOPROGRESS,
        .set => win32.shell32.TBPF_NORMAL,
        .@"error" => win32.shell32.TBPF_ERROR,
        .indeterminate => win32.shell32.TBPF_INDETERMINATE,
        .pause => win32.shell32.TBPF_PAUSED,
    };
}

/// Show `report` on the taskbar button of `window`, remembering that surface
/// `reporter` made the report.
pub fn setProgressFrom(window: *Window, reporter: u32, report: Report) bool {
    const st = &window.taskbar;
    _ = win32.user32.KillTimer(window.hwnd, stale_timer_id);

    if (report.state == .remove) {
        st.progress = null;
        st.reporter = 0;
    } else {
        // `error` and `pause` without a value keep the bar where it was.
        var stored = report;
        if (stored.progress == null and (report.state == .@"error" or report.state == .pause)) {
            if (st.progress) |old| stored.progress = old.progress;
        }
        st.progress = stored;
        st.reporter = reporter;
        if (win32.user32.SetTimer(window.hwnd, stale_timer_id, stale_timeout_ms, null) == 0)
            log.warn("SetTimer failed err={}", .{win32.kernel32.GetLastError()});
    }

    apply(window);
    return true;
}

/// The surface `id` is closing for good, or leaves the window: its progress
/// goes with it and nothing of it is kept.
pub fn surfaceClosed(window: *Window, id: u32) void {
    window.taskbar.forget(id);
    if (window.taskbar.reporter != id or window.taskbar.progress == null) return;
    _ = setProgressFrom(window, 0, .{ .state = .remove });
}

/// The surface `id` is parked (a close the undo keeps): its progress leaves
/// the bar and waits for `surfaceRestored`.
pub fn surfaceParked(window: *Window, id: u32) void {
    if (!window.taskbar.dropFor(id)) return;
    _ = setProgressFrom(window, 0, .{ .state = .remove });
}

/// The surface `id` is back from a close-undo: its progress returns.
pub fn surfaceRestored(window: *Window, id: u32) void {
    const report = window.taskbar.takeStash(id) orelse return;
    _ = setProgressFrom(window, id, report);
}

test "win32 taskbar: the progress of a parked surface comes back with it" {
    var st: State = .{};
    try std.testing.expect(!st.dropFor(5)); // nothing reported
    st.progress = .{ .state = .set, .progress = 40 };
    st.reporter = 5;
    try std.testing.expect(!st.dropFor(6)); // another surface is parked
    try std.testing.expect(st.dropFor(5));
    st.progress = null;
    st.reporter = 0;
    try std.testing.expect(st.takeStash(6) == null);
    try std.testing.expectEqual(@as(?u8, 40), st.takeStash(5).?.progress);
    try std.testing.expect(st.takeStash(5) == null); // once

    // A newer report on the bar wins over the stash.
    st.progress = .{ .state = .set, .progress = 10 };
    st.reporter = 5;
    try std.testing.expect(st.dropFor(5));
    st.progress = .{ .state = .set, .progress = 90 };
    st.reporter = 7;
    try std.testing.expect(st.takeStash(5) == null);
}

test "win32 taskbar: every parked surface keeps its own report, a gone surface none" {
    var st: State = .{};
    // Two surfaces parked one after the other (a tab with two panes).
    st.progress = .{ .state = .set, .progress = 20 };
    st.reporter = 1;
    try std.testing.expect(st.dropFor(1));
    st.progress = .{ .state = .set, .progress = 60 };
    st.reporter = 2;
    try std.testing.expect(st.dropFor(2));
    st.progress = null;
    st.reporter = 0;
    try std.testing.expectEqual(@as(?u8, 20), st.takeStash(1).?.progress);
    st.progress = null;
    try std.testing.expectEqual(@as(?u8, 60), st.takeStash(2).?.progress);

    // A surface that moved to another window or died takes its report along.
    st.progress = .{ .state = .set, .progress = 70 };
    st.reporter = 3;
    try std.testing.expect(st.dropFor(3));
    st.forget(3);
    st.progress = null;
    try std.testing.expect(st.takeStash(3) == null);

    // More parked surfaces than slots: the oldest is lost, the others stay.
    var id: u32 = 10;
    while (id < 10 + State.stash_slots + 1) : (id += 1) {
        st.progress = .{ .state = .set, .progress = 5 };
        st.reporter = id;
        try std.testing.expect(st.dropFor(id));
    }
    st.progress = null;
    try std.testing.expect(st.takeStash(10) == null);
    try std.testing.expect(st.takeStash(10 + State.stash_slots) != null);
}

/// The bar's value for a report: 0-100.
fn valueFor(report: Report) u64 {
    return @min(report.progress orelse 0, 100);
}

fn apply(window: *Window) void {
    const st = &window.taskbar;
    const list = st.list orelse create(window) orelse return;
    const report = st.progress orelse {
        list.setProgressState(window.hwnd, win32.shell32.TBPF_NOPROGRESS) catch |err|
            log.warn("SetProgressState failed err={}", .{err});
        return;
    };
    // The value first, so the bar never shows the new state at the old value.
    if (report.state != .indeterminate) {
        list.setProgressValue(window.hwnd, valueFor(report), 100) catch |err|
            log.warn("SetProgressValue failed err={}", .{err});
    }
    list.setProgressState(window.hwnd, tbpfFor(report.state)) catch |err|
        log.warn("SetProgressState failed err={}", .{err});
}

fn create(window: *Window) ?*ITaskbarList3 {
    var out: ?*anyopaque = null;
    const hr = win32.ole32.CoCreateInstance(
        &win32.shell32.CLSID_TaskbarList,
        null,
        win32.ole32.CLSCTX_INPROC_SERVER,
        &ITaskbarList3.iid,
        &out,
    );
    win32.foundation.check(hr) catch |err| {
        log.warn("unable to create the taskbar list err={}", .{err});
        return null;
    };
    const list: *ITaskbarList3 = @ptrCast(@alignCast(out orelse return null));
    list.hrInit() catch |err| {
        log.warn("taskbar list init failed err={}", .{err});
        com.release(list);
        return null;
    };
    window.taskbar.list = list;
    return list;
}

fn destroyList(window: *Window) void {
    com.release(window.taskbar.list);
    window.taskbar.list = null;
}

pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    if (msg == buttonCreatedMessage()) {
        // The button exists (again, after an Explorer restart): earlier
        // calls were lost, so start over and re-apply the stored progress.
        destroyList(window);
        if (window.taskbar.progress != null) apply(window);
        return null;
    }
    switch (msg) {
        win32.user32.WM_TIMER => if (wparam == stale_timer_id) {
            _ = setProgressFrom(window, 0, .{ .state = .remove });
            return 0;
        },
        // A close that asks first may still be cancelled: only the immediate
        // one takes the progress along.
        messages.WM_GHOSTTY_CLOSE_SURFACE => if (lparam == 0) surfaceParked(window, @intCast(wparam)),
        win32.user32.WM_NCDESTROY => {
            _ = win32.user32.KillTimer(window.hwnd, stale_timer_id);
            destroyList(window);
        },
        else => {},
    }
    return null;
}

var button_created: u32 = 0;

fn buttonCreatedMessage() u32 {
    if (button_created == 0) button_created = win32.user32.RegisterWindowMessageW(L("TaskbarButtonCreated"));
    return button_created;
}

test "win32 taskbar: progress state map" {
    try std.testing.expectEqual(@as(u32, 0), tbpfFor(.remove));
    try std.testing.expectEqual(@as(u32, 2), tbpfFor(.set));
    try std.testing.expectEqual(@as(u32, 4), tbpfFor(.@"error"));
    try std.testing.expectEqual(@as(u32, 1), tbpfFor(.indeterminate));
    try std.testing.expectEqual(@as(u32, 8), tbpfFor(.pause));

    try std.testing.expectEqual(@as(u64, 100), valueFor(.{ .state = .set, .progress = 250 }));
    try std.testing.expectEqual(@as(u64, 40), valueFor(.{ .state = .set, .progress = 40 }));
    try std.testing.expectEqual(@as(u64, 0), valueFor(.{ .state = .set }));
}
