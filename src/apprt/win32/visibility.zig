//! `toggle_visibility`: hides or shows every window of the app. Like macOS:
//! with a Ghostty window in the foreground all visible normal windows are
//! hidden (remembered with the foreground one); otherwise the remembered
//! ones come back and the remembered foreground window is brought forward.
const std = @import("std");
const win32 = @import("win32");
const App = @import("App.zig");
const Window = @import("Window.zig");

const Allocator = std.mem.Allocator;
const user32 = win32.user32;

const log = std.log.scoped(.win32_visibility);

pub const State = struct {
    /// Ids of the windows `toggle` hid, in z-order of the app's list.
    hidden: std.ArrayList(u32) = .empty,
    /// The window that was in the foreground when they were hidden.
    foreground: ?u32 = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.hidden.deinit(alloc);
        self.* = .{};
    }

    /// Remember `ids` as hidden.
    fn hide(self: *State, alloc: Allocator, ids: []const u32, foreground: ?u32) !void {
        self.hidden.clearRetainingCapacity();
        try self.hidden.appendSlice(alloc, ids);
        self.foreground = foreground;
    }

    /// The remembered ids (owned by the caller) and foreground; the state
    /// is empty afterwards.
    fn restore(self: *State, alloc: Allocator) !Restored {
        const ids = try self.hidden.toOwnedSlice(alloc);
        const fg = self.foreground;
        self.foreground = null;
        return .{ .ids = ids, .foreground = fg };
    }
};

const Restored = struct { ids: []u32, foreground: ?u32 };

/// Hide the windows if a normal one of the app is in the foreground, show
/// them otherwise. Returns whether anything was done.
pub fn toggle(app: *App) !bool {
    const alloc = app.core_app.alloc;
    const state = &app.visibility;

    if (foregroundWindow(app)) |fg| {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(alloc);
        for (app.windows.items) |w| {
            if (w.kind != .normal or user32.IsWindowVisible(w.hwnd) == 0) continue;
            try ids.append(alloc, w.id);
        }
        try state.hide(alloc, ids.items, fg.id);
        for (app.windows.items) |w| {
            for (ids.items) |id| {
                if (id == w.id) _ = user32.ShowWindow(w.hwnd, user32.SW_HIDE);
            }
        }
        return true;
    }

    const remembered = try state.restore(alloc);
    defer alloc.free(remembered.ids);
    var shown = false;
    var front: ?*Window = null;
    for (remembered.ids) |id| {
        const w = windowById(app, id) orelse continue;
        _ = user32.ShowWindow(w.hwnd, user32.SW_SHOWNOACTIVATE);
        shown = true;
        if (remembered.foreground == id) front = w;
    }
    if (front == null) front = if (shown) windowById(app, remembered.ids[0]) else lastNormal(app);
    if (front) |w| {
        w.activate();
        return true;
    }
    return shown;
}

/// The normal window of the app that is in the foreground, if any.
fn foregroundWindow(app: *App) ?*Window {
    const fg = user32.GetForegroundWindow() orelse return null;
    for (app.windows.items) |w| {
        if (w.kind == .normal and w.hwnd == fg and user32.IsWindowVisible(w.hwnd) != 0) return w;
    }
    return null;
}

fn windowById(app: *App, id: u32) ?*Window {
    for (app.windows.items) |w| {
        if (w.id == id and w.kind == .normal) return w;
    }
    return null;
}

/// The last active normal window, else any.
fn lastNormal(app: *App) ?*Window {
    if (app.last_active) |w| if (w.kind == .normal) return w;
    for (app.windows.items) |w| {
        if (w.kind == .normal) return w;
    }
    return null;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "win32 visibility: hide then show restores the same set" {
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.hide(alloc, &.{ 3, 5, 9 }, 5);
    try testing.expectEqualSlices(u32, &.{ 3, 5, 9 }, state.hidden.items);

    const r = try state.restore(alloc);
    defer alloc.free(r.ids);
    try testing.expectEqualSlices(u32, &.{ 3, 5, 9 }, r.ids);
    try testing.expectEqual(@as(?u32, 5), r.foreground);

    // Restoring twice finds nothing; the next hide starts fresh.
    const again = try state.restore(alloc);
    defer alloc.free(again.ids);
    try testing.expectEqual(@as(usize, 0), again.ids.len);
    try testing.expectEqual(@as(?u32, null), again.foreground);

    try state.hide(alloc, &.{7}, null);
    try testing.expectEqualSlices(u32, &.{7}, state.hidden.items);
    try testing.expectEqual(@as(?u32, null), state.foreground);
}
