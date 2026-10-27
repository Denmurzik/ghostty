//! Links in terminal output: the hover state and opening them.
//! M3 skeleton: `hover` and the state come with the feature; `open` is the
//! allowlist code of M2 (`link_policy`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const app_actions = @import("actions/app_actions.zig");
const link_policy = @import("link_policy.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_actions);

pub const State = struct {};

pub fn surfaceDestroying(surface: *Surface) void {
    _ = surface;
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `url_confirm`.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    _ = window;
    _ = lparam;
}

pub fn hover(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_over_link)) bool {
    _ = app;
    _ = target;
    _ = value;
    log.debug("M3 stub action=mouse_over_link", .{});
    return false;
}

/// `text` and `html` are paths Ghostty wrote itself (screen and scrollback
/// files) and open like the config file. `unknown` and `osc8` come from
/// terminal output, so nothing there may run a program: web and mail URLs go
/// to the shell, local paths are only selected in Explorer (see
/// `link_policy`). Always true so the core never falls back to `os.open`.
pub fn open(app: *App, target: apprt.Target, value: apprt.Action.Value(.open_url)) bool {
    _ = target;
    return openWith(app.core_app.alloc, value);
}

fn openWith(alloc: Allocator, value: apprt.Action.Value(.open_url)) bool {
    if (link_policy.isTrusted(value.kind)) {
        _ = app_actions.shellOpen(alloc, value.url);
        return true;
    }

    var buf: [link_policy.max_len]u8 = undefined;
    switch (link_policy.classify(&buf, value.url)) {
        .refuse => |why| log.warn("refusing to open link kind={t} why={s}", .{ value.kind, why }),
        .open => |url| {
            const wide = util.utf16z(alloc, url) catch |err| {
                log.warn("unable to convert link err={}", .{err});
                return true;
            };
            defer alloc.free(wide);
            const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
            const rc = win32.shell32.ShellExecuteW(null, verb, wide.ptr, null, null, win32.user32.SW_SHOWNORMAL);
            if (rc <= 32) log.warn("unable to open link rc={}", .{rc});
        },
        .reveal => |path| {
            const params = std.fmt.allocPrint(alloc, "/select,\"{s}\"", .{path}) catch |err| {
                log.warn("unable to build explorer arguments err={}", .{err});
                return true;
            };
            defer alloc.free(params);
            const wide = util.utf16z(alloc, params) catch |err| {
                log.warn("unable to convert explorer arguments err={}", .{err});
                return true;
            };
            defer alloc.free(wide);
            const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
            const explorer = std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe");
            const rc = win32.shell32.ShellExecuteW(null, verb, explorer, wide.ptr, null, win32.user32.SW_SHOWNORMAL);
            if (rc <= 32) log.warn("unable to reveal link rc={}", .{rc});
        },
    }
    return true;
}

test "win32 actions: open_url arm never returns false" {
    // Only refused input: an allowed URL would start the owner's browser.
    const refused = [_][]const u8{
        "ms-msdt:/id PCWDiagnostic",
        "",
        "javascript:alert(1)",
        "\\\\server\\share\\x.exe",
    };
    for (refused) |url| {
        try std.testing.expect(openWith(std.testing.allocator, .{ .kind = .osc8, .url = url }));
        try std.testing.expect(openWith(std.testing.allocator, .{ .kind = .unknown, .url = url }));
    }

    // Longer than the policy takes: refused, not truncated.
    const long = try std.testing.allocator.alloc(u8, link_policy.max_len + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    try std.testing.expect(openWith(std.testing.allocator, .{ .kind = .unknown, .url = long }));
}
