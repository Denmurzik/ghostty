//! Links in terminal output: the hover label and opening them. What a link
//! may do is decided in `shell_open`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const dialogs = @import("dialogs.zig");
const hooks = @import("hooks.zig");
const messages = @import("messages.zig");
const link_policy = @import("link_policy.zig");
const overlay = @import("overlay.zig");
const shell_open = @import("shell_open.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_link);

/// The label shows at most this many characters.
const label_chars = 80;

/// Sizes at 96 DPI, from macOS `URLHoverBanner`: 5 pt padding all round;
/// the line is 26 px high like the resize overlay's. `char_w` is only the
/// guess when the text cannot be measured.
const pad_x = 5;
const char_w = 8;
const height_px = 26;

const ellipsis = "\u{2026}";

pub const State = struct {
    label: ?*overlay.Popup = null,
};

/// The popup and the text it paints.
const Label = struct {
    popup: overlay.Popup,
    text: [label_chars * 2]u16 = undefined,
    text_len: usize = 0,
};

pub fn surfaceDestroying(surface: *Surface) void {
    const popup = surface.link.label orelse return;
    surface.link.label = null;
    popup.destroy();
    const label: *Label = @fieldParentPtr("popup", popup);
    surface.app.core_app.alloc.destroy(label);
}

/// Confirmations posted to a window that is going away are never delivered:
/// take them out of its queue and free them.
pub fn windowDestroying(window: *Window) void {
    var msg: win32.user32.MSG = undefined;
    const m = messages.WM_GHOSTTY_POSTED_DIALOG;
    while (win32.user32.PeekMessageW(&msg, window.hwnd, m, m, win32.user32.PM_REMOVE) != 0) {
        hooks.discardDialog(msg.wParam, msg.lParam);
    }
}

/// A confirmation that will never be delivered.
pub fn discard(lparam: win32.foundation.LPARAM) void {
    const payload: *shell_open.ConfirmPayload = @ptrFromInt(@as(usize, @bitCast(lparam)));
    payload.destroy();
}

/// `WM_GHOSTTY_POSTED_DIALOG` of kind `url_confirm`: the worker met a link
/// that needs the user's consent.
pub fn postedDialog(window: *Window, lparam: win32.foundation.LPARAM) void {
    const payload: *shell_open.ConfirmPayload = @ptrFromInt(@as(usize, @bitCast(lparam)));
    defer payload.destroy();

    const app = window.app;
    if (window.findSurface(payload.surface_id) == null) {
        log.debug("dropping a link confirmation, its surface is gone", .{});
        return;
    }
    // The dialog runs a message loop; a second one would stack.
    if (app.shell_open.confirming) return;

    const alloc = app.core_app.alloc;
    const shown = dialogs.previewText(alloc, payload.url, 200) catch return;
    defer alloc.free(shown);
    const scheme = if (link_policy.schemeEnd(payload.url)) |end| payload.url[0..end] else "unknown";
    const shown_scheme = dialogs.previewText(alloc, scheme, 40) catch return;
    defer alloc.free(shown_scheme);
    const body = std.fmt.allocPrint(
        alloc,
        "A program in this terminal wants to open a \"{s}\" link. That hands control to another program on this computer.\n\n{s}\n\nOnly continue if you trust it.",
        .{ shown_scheme, shown },
    ) catch return;
    defer alloc.free(body);

    app.shell_open.confirming = true;
    const yes = dialogs.confirm(window.hwnd, "Open Link", body);
    app.shell_open.confirming = false;
    shell_open.confirmed(app, payload.url, yes);
}

/// Shows the URL under the pointer in a label at the bottom of the
/// surface, like macOS; an empty URL hides it. Core already applied
/// `link-previews`.
pub fn hover(app: *App, target: apprt.Target, value: apprt.Action.Value(.mouse_over_link)) !bool {
    const core = switch (target) {
        .app => return true,
        .surface => |s| s,
    };
    const surface = app.surfaceFor(core) orelse return true;
    const state = &surface.link;

    if (value.url.len == 0) {
        if (state.label) |p| p.hide();
        return true;
    }

    const alloc = app.core_app.alloc;
    const shortened = try middleEllipsis(alloc, value.url, label_chars);
    defer alloc.free(shortened);
    // Control characters become visible symbols; none may reach the label.
    const safe = try dialogs.previewText(alloc, shortened, label_chars + 1);
    defer alloc.free(safe);

    const label = try ensureLabel(alloc, surface);
    const n = std.unicode.utf8ToUtf16Le(&label.text, safe) catch 0;
    label.text_len = n;
    label.popup.surface = surface;
    label.popup.size = .{ .w = labelWidth(label.text[0..n], surface.window.dpi), .h = height_px };
    try label.popup.show();
    return true;
}

/// Logical width of a label with `text`: the measured text and the padding.
fn labelWidth(text: []const u16, dpi: u32) i32 {
    const px = Chrome.measureLabel(text, dpi) catch |err| blk: {
        log.warn("unable to measure the link label err={}", .{err});
        break :blk @divTrunc(@as(i32, @intCast(text.len)) * char_w * @as(i32, @intCast(dpi)), 96);
    };
    // Back to 96 dpi; one more pixel absorbs the rounding.
    return @divTrunc(px * 96 + @as(i32, @intCast(dpi)) - 1, @as(i32, @intCast(dpi))) + 2 * pad_x + 1;
}

fn ensureLabel(alloc: Allocator, surface: *Surface) !*Label {
    if (surface.link.label) |p| return @fieldParentPtr("popup", p);

    const label = try alloc.create(Label);
    errdefer alloc.destroy(label);
    label.* = .{ .popup = .{
        .kind = .label,
        .anchor = .surface_bottom_left,
        .window = surface.window,
        .surface = surface,
        .size = .{ .w = 0, .h = height_px },
        .margin = 0,
        .paint = paintLabel,
        .avoid_cursor = true,
    } };
    label.popup.ctx = label;
    surface.link.label = &label.popup;
    return label;
}

fn paintLabel(p: *overlay.Popup, ctx: overlay.PaintContext) void {
    const label: *const Label = @ptrCast(@alignCast(p.ctx orelse return));
    Chrome.paintLabel(ctx.hdc, ctx.rect, label.text[0..label.text_len], ctx.palette, ctx.dpi) catch |err| {
        log.warn("unable to paint the link label err={}", .{err});
    };
}

/// `text` cut to `max` characters by replacing the middle with an
/// ellipsis; text that fits is copied. Counts code points; bytes that are
/// not valid UTF-8 count as one each.
pub fn middleEllipsis(alloc: Allocator, text: []const u8, max: usize) ![]u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) i += seqLen(text[i..]);
    if (count <= max) return alloc.dupe(u8, text);

    const head = (max - 1) / 2 + (max - 1) % 2;
    const tail = (max - 1) / 2;

    var head_end: usize = 0;
    var n: usize = 0;
    while (n < head) : (n += 1) head_end += seqLen(text[head_end..]);

    var tail_start: usize = 0;
    n = 0;
    while (n < count - tail) : (n += 1) tail_start += seqLen(text[tail_start..]);

    return std.mem.concat(alloc, u8, &.{ text[0..head_end], ellipsis, text[tail_start..] });
}

/// Bytes of the code point at the start of `s`; 1 for invalid UTF-8.
fn seqLen(s: []const u8) usize {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    if (len > s.len) return 1;
    _ = std.unicode.utf8Decode(s[0..len]) catch return 1;
    return len;
}

/// `text` and `html` are paths Ghostty wrote itself (screen and scrollback
/// files); `unknown` and `osc8` come from terminal output. Either way the
/// worker of `shell_open` decides and acts. Always true so the core never
/// falls back to `os.open`.
pub fn open(app: *App, target: apprt.Target, value: apprt.Action.Value(.open_url)) !bool {
    const url = value.url;
    if (url.len == 0 or url.len > link_policy.max_len) {
        log.warn("refusing to open a link of {d} bytes", .{url.len});
        return true;
    }
    if (shell_open.hasForbidden(url)) {
        log.warn("refusing to open a link with control characters", .{});
        return true;
    }

    const id: u32 = switch (target) {
        .app => 0,
        .surface => |core| if (app.surfaceFor(core)) |s| s.id else 0,
    };
    shell_open.submit(app, id, value.kind, url);
    return true;
}

test "win32 link: label text ellipsis" {
    const alloc = std.testing.allocator;

    const short = try middleEllipsis(alloc, "https://example.com", 80);
    defer alloc.free(short);
    try std.testing.expectEqualStrings("https://example.com", short);

    const exact = try alloc.alloc(u8, 80);
    defer alloc.free(exact);
    @memset(exact, 'a');
    const same = try middleEllipsis(alloc, exact, 80);
    defer alloc.free(same);
    try std.testing.expectEqualStrings(exact, same);

    const long = try alloc.alloc(u8, 200);
    defer alloc.free(long);
    @memset(long[0..100], 'a');
    @memset(long[100..], 'b');
    const cut = try middleEllipsis(alloc, long, 80);
    defer alloc.free(cut);
    try std.testing.expectEqual(@as(usize, 79 + ellipsis.len), cut.len);
    var expected: [79 + ellipsis.len]u8 = undefined;
    @memset(expected[0..40], 'a');
    @memcpy(expected[40..][0..ellipsis.len], ellipsis);
    @memset(expected[40 + ellipsis.len ..], 'b');
    try std.testing.expectEqualStrings(&expected, cut);

    // Multi-byte characters are never split.
    var wide: [100 * 2]u8 = undefined;
    for (0..100) |i| @memcpy(wide[i * 2 ..][0..2], "\xc3\xa9");
    const wide_cut = try middleEllipsis(alloc, &wide, 80);
    defer alloc.free(wide_cut);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_cut));
    try std.testing.expectEqual(@as(usize, 79 * 2 + ellipsis.len), wide_cut.len);
}

test "win32 link: open returns true for refuse and on worker-queue overflow" {
    const alloc = std.testing.allocator;
    var core: @import("../../App.zig") = undefined;
    core.alloc = alloc;
    var app: App = undefined;
    app.core_app = &core;
    app.windows = .empty;
    app.shell_open = .{};
    const target: apprt.Target = .app;

    // Refused before the worker sees them.
    try std.testing.expect(try open(&app, target, .{ .kind = .osc8, .url = "" }));
    try std.testing.expect(try open(&app, target, .{ .kind = .osc8, .url = "https://a/\nb" }));
    try std.testing.expect(try open(&app, target, .{ .kind = .osc8, .url = "https://a/\xc2\x85" }));
    try std.testing.expectEqual(@as(usize, 0), app.shell_open.len);

    // A full queue refuses without starting anything.
    try shell_open.fillQueueForTest(&app.shell_open, alloc);
    defer shell_open.clearForTest(&app.shell_open);
    try std.testing.expect(try open(&app, target, .{ .kind = .osc8, .url = "https://example.com" }));
    try std.testing.expect(app.shell_open.thread == null);
}
