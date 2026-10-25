//! The Win32 apprt surface. Stub: Task 18 implements the real contract.
//! Queries that core calls with `try` inside non-failing functions must
//! not return errors, so they report a window-less default instead.
const Surface = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const renderer = @import("../../renderer.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");

app: *App,
core_surface: CoreSurface,

pub fn deinit(self: *Surface) void {
    _ = self;
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

pub fn close(self: *const Surface, process_active: bool) void {
    _ = self;
    _ = process_active;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    _ = self;
    return null;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    _ = self;
    return .{ .x = 1, .y = 1 };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    _ = self;
    return .{ .width = 0, .height = 0 };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    _ = self;
    return .{ .x = 0, .y = 0 };
}

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    _ = clipboard_type;
    return false;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    _ = self;
    _ = clipboard_type;
    _ = state;
    return .unsupported;
}

pub fn setClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = contents;
    _ = confirm;
    return error.Unsupported;
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    return global.environMap();
}

pub fn renderDeviceOptions(self: *const Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}
