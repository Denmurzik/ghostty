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
/// `WM_TIMER` id of the stale timer on a top-level window; the shared
/// table in `messages.zig` has no entry for it.
const stale_timer_id: usize = 0x2600;

pub const State = struct {
    progress: ?Report = null,
    /// The surface (by id) that made the report; 0 when none.
    reporter: u32 = 0,
    /// Created lazily, again after every "TaskbarButtonCreated".
    list: ?*ITaskbarList3 = null,
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

/// Show `report` on the taskbar button of `window`.
pub fn setProgress(window: *Window, report: Report) bool {
    return setProgressFrom(window, 0, report);
}

/// Like `setProgress`, remembering that surface `reporter` made the report.
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

/// The surface `id` is closing: its progress goes with it.
pub fn surfaceClosed(window: *Window, id: u32) void {
    if (window.taskbar.reporter != id or window.taskbar.progress == null) return;
    _ = setProgressFrom(window, 0, .{ .state = .remove });
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
        messages.WM_GHOSTTY_CLOSE_SURFACE => if (lparam == 0) surfaceClosed(window, @intCast(wparam)),
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
