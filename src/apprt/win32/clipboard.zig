//! Win32 clipboard access for a surface: text in and out of the system
//! clipboard (CF_UNICODETEXT), and the asynchronous request flow core
//! expects from an apprt.
//!
//! Core asks for clipboard contents (`request`) or hands over text to
//! write behind a confirmation (`setClipboard` with `confirm`) while it is
//! busy on the stack: inside a key callback, or in the middle of a
//! mailbox tick. Neither may show a modal dialog there, because a message
//! box pumps messages and would re-enter the window procedure, and core,
//! while core state is in use. So both only queue the work and post
//! `WM_GHOSTTY_CLIPBOARD_READ` to the surface window; the work runs from
//! the message loop, where the surface may still disappear under a dialog
//! (`State` covers that).
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const dialogs = @import("dialogs.zig");
const util = @import("util.zig");

const log = std.log.scoped(.win32_clipboard);

/// Posted to a surface window when `State` has queued work. No payload; a
/// destroyed window simply drops it.
pub const WM_GHOSTTY_CLIPBOARD_READ = win32.user32.WM_APP + 2;

/// How often a busy clipboard (another process has it open) is retried
/// after the first attempt, and how long to wait between attempts.
const open_retries = 5;
const open_retry_ms = 10;

/// How much of the text a confirmation prompt shows.
const preview_chars = 512;

/// One queued piece of clipboard work.
const Pending = struct {
    req: apprt.ClipboardRequest,

    /// The text of an `osc_52_write`, owned by the queue.
    text: ?[:0]u8 = null,
};

/// Per-surface clipboard state: the FIFO of work waiting for the message
/// loop, plus whatever a confirmation dialog currently on screen needs to
/// survive its surface being destroyed. UI thread only.
pub const State = struct {
    queue: std.ArrayList(Pending) = .empty,

    /// The entry whose confirmation dialog is up. Not in `queue`.
    active: ?Pending = null,

    /// Set while a dialog is up: points at a flag on the stack of the code
    /// showing it, which `cancelAll` sets so that code knows the surface
    /// was destroyed under the dialog and must not be touched again.
    abandoned: ?*bool = null,

    fn pop(self: *State) ?Pending {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// Deny every request that was never answered and release the queue.
    /// `deny` is called with `ctx` once per request, the one behind a
    /// dialog first, then the queued ones in order.
    fn cancelAll(
        self: *State,
        alloc: Allocator,
        ctx: anytype,
        comptime deny: fn (@TypeOf(ctx), apprt.ClipboardRequest) void,
    ) void {
        if (self.abandoned) |flag| flag.* = true;
        self.abandoned = null;

        if (self.active) |p| {
            deny(ctx, p.req);
            if (p.text) |t| alloc.free(t);
            self.active = null;
        }

        for (self.queue.items) |p| {
            deny(ctx, p.req);
            if (p.text) |t| alloc.free(t);
        }
        self.queue.deinit(alloc);
        self.queue = .empty;
    }
};

/// Whether `t` exists on Windows: only the standard clipboard does.
pub fn supports(t: apprt.Clipboard) bool {
    return t == .standard;
}

/// Handle a window message for `surface`. Null means not handled, and the
/// default window procedure gets the message.
pub fn handle(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = wparam;
    _ = lparam;
    if (msg != WM_GHOSTTY_CLIPBOARD_READ) return null;
    drain(surface);
    return 0;
}

/// Start a clipboard read for core. The text is read and handed back to
/// core from the message loop, never from this call.
pub fn request(
    surface: *Surface,
    t: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (!supports(t)) return .unsupported;
    switch (req) {
        .paste, .osc_52_read => {},
        // Not supported by this apprt; core answers the program.
        .osc_52_write, .kitty_read, .kitty_write, .list => return .unsupported,
    }

    // Lets performable paste bindings fall through when there is nothing
    // to paste (an image, say). An OSC 52 read of such a clipboard is
    // answered with empty contents instead.
    if (req == .paste and
        win32.user32.IsClipboardFormatAvailable(win32.user32.CF_UNICODETEXT) == 0)
    {
        return .unavailable;
    }

    try enqueue(surface, .{ .req = req });
    return .started;
}

/// Core's clipboard write. Text goes straight to the clipboard; with
/// `confirm` it is queued behind a confirmation prompt instead and written
/// through core once the user agrees.
pub fn setClipboard(
    surface: *Surface,
    t: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (!supports(t)) return error.Unsupported;

    // Only text can be put on the clipboard; a write with nothing else to
    // offer is an error core can report (kitty answers EIO).
    const text: [:0]const u8 = for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) break content.data;
    } else return error.NoTextContent;

    if (!confirm) return write(surface.hwnd, text);

    const alloc = surface.window.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, text, 0);
    errdefer alloc.free(copy);
    try enqueue(surface, .{ .req = .{ .osc_52_write = t }, .text = copy });
}

/// Deny every clipboard request still pending for `surface`. Called before
/// the core surface is torn down.
pub fn cancelPending(surface: *Surface) void {
    const alloc = surface.window.app.core_app.alloc;
    surface.clipboard_state.cancelAll(alloc, &surface.core_surface, denyCore);
}

fn denyCore(core: *CoreSurface, req: apprt.ClipboardRequest) void {
    core.denyClipboardRequest(req);
}

fn enqueue(surface: *Surface, p: Pending) !void {
    const alloc = surface.window.app.core_app.alloc;
    const state = &surface.clipboard_state;
    try state.queue.append(alloc, p);
    if (win32.user32.PostMessageW(surface.hwnd, WM_GHOSTTY_CLIPBOARD_READ, 0, 0) == 0) {
        _ = state.queue.pop();
        return error.PostMessageFailed;
    }
}

/// Run the queued work, in order. A dialog shown on the way lets further
/// messages through; those find `abandoned` set and leave the queue to
/// this loop.
fn drain(surface: *Surface) void {
    const state = &surface.clipboard_state;
    if (state.abandoned != null) return;

    // Taken up front: after a dialog the surface may be gone.
    const alloc = surface.window.app.core_app.alloc;
    while (state.pop()) |p| {
        if (!process(surface, alloc, p)) return;
    }
}

const Answer = enum { yes, no, gone };

/// Handle one entry. False means the surface was destroyed behind a
/// dialog and must not be touched.
fn process(surface: *Surface, alloc: Allocator, p: Pending) bool {
    switch (p.req) {
        .osc_52_write => {
            const text = p.text orelse return true;
            const answer = confirmWith(
                surface,
                alloc,
                p,
                "Clipboard Write",
                "An application in this terminal wants to write to your clipboard. Allow it?",
                text,
            );
            switch (answer) {
                .gone => return false,
                .yes => surface.core_surface.completeClipboardRequest(p.req, .{
                    .contents = &.{.{ .mime = "text/plain", .data = text }},
                    .confirmed = true,
                }) catch |err| log.warn("clipboard write failed err={}", .{err}),
                .no => surface.core_surface.denyClipboardRequest(p.req),
            }
            alloc.free(text);
            return true;
        },

        .paste, .osc_52_read => {
            const maybe_text = read(alloc, surface.hwnd) catch |err| blk: {
                log.warn("clipboard read failed err={}", .{err});
                break :blk null;
            };
            // Nothing to give: a paste just doesn't happen and an OSC 52
            // read is answered with empty contents.
            const text = maybe_text orelse {
                surface.core_surface.denyClipboardRequest(p.req);
                return true;
            };
            defer alloc.free(text);

            surface.core_surface.completeClipboardRequest(p.req, .{
                .contents = &.{.{ .mime = "text/plain", .data = text }},
            }) catch |err| switch (err) {
                error.UnsafePaste, error.UnauthorizedPaste => {
                    const unsafe = p.req == .paste;
                    switch (confirmWith(
                        surface,
                        alloc,
                        p,
                        if (unsafe) "Confirm Paste" else "Clipboard Read",
                        if (unsafe)
                            "This text may be unsafe to paste: it contains line breaks or control characters. Paste it anyway?"
                        else
                            "An application in this terminal wants to read your clipboard. Allow it?",
                        text,
                    )) {
                        .gone => return false,
                        .yes => surface.core_surface.completeClipboardRequest(p.req, .{
                            .contents = &.{.{ .mime = "text/plain", .data = text }},
                            .confirmed = true,
                        }) catch |e| log.warn("clipboard request failed err={}", .{e}),
                        .no => surface.core_surface.denyClipboardRequest(p.req),
                    }
                },
                else => log.warn("clipboard request failed err={}", .{err}),
            };
            return true;
        },

        // `request` never queues these.
        .kitty_read, .kitty_write, .list => unreachable,
    }
}

/// Ask the user about `p`, showing `text` in the prompt. While the dialog
/// is up `p` is registered in the state so that destroying the surface
/// denies it, and the answer is `.gone` if that happened.
fn confirmWith(
    surface: *Surface,
    alloc: Allocator,
    p: Pending,
    title: []const u8,
    question: []const u8,
    text: []const u8,
) Answer {
    // Everything the dialog needs is copied out first: the surface may not
    // be there when it returns.
    const owner = surface.window.hwnd;
    const state = &surface.clipboard_state;

    const preview = dialogs.previewText(alloc, text, preview_chars) catch return .no;
    defer alloc.free(preview);
    const body = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ question, preview }) catch return .no;
    defer alloc.free(body);

    var abandoned = false;
    state.abandoned = &abandoned;
    state.active = p;

    const yes = dialogs.confirm(owner, title, body);

    // Past this point only the local flag may be looked at before it is
    // known whether the surface survived.
    if (abandoned) return .gone;
    state.abandoned = null;
    state.active = null;
    return if (yes) .yes else .no;
}

/// Put `text_utf8` on the system clipboard as CF_UNICODETEXT, with lone
/// line feeds turned into the CRLF other Windows programs expect. `hwnd`
/// must be a real window: it becomes the clipboard owner, and a clipboard
/// opened without one cannot be given data.
pub fn write(hwnd: win32.foundation.HWND, text_utf8: []const u8) !void {
    const alloc = global.alloc();
    const wide = try util.utf16z(alloc, text_utf8);
    defer alloc.free(wide);

    var lone_lf: usize = 0;
    for (wide, 0..) |c, i| {
        if (c == '\n' and (i == 0 or wide[i - 1] != '\r')) lone_lf += 1;
    }

    const bytes = (wide.len + lone_lf + 1) * @sizeOf(u16);
    const mem = win32.kernel32.GlobalAlloc(win32.kernel32.GMEM_MOVEABLE, bytes) orelse
        return error.OutOfMemory;
    // The clipboard owns the memory once SetClipboardData succeeds.
    var owned = false;
    defer if (!owned) {
        _ = win32.kernel32.GlobalFree(mem);
    };

    {
        const ptr = win32.kernel32.GlobalLock(mem) orelse return error.LockFailed;
        defer _ = win32.kernel32.GlobalUnlock(mem);
        const dst: [*]u16 = @ptrCast(@alignCast(ptr));
        var n: usize = 0;
        for (wide, 0..) |c, i| {
            if (c == '\n' and (i == 0 or wide[i - 1] != '\r')) {
                dst[n] = '\r';
                n += 1;
            }
            dst[n] = c;
            n += 1;
        }
        dst[n] = 0;
    }

    try openClipboard(hwnd);
    defer _ = win32.user32.CloseClipboard();

    if (win32.user32.EmptyClipboard() == 0) return error.EmptyClipboardFailed;
    if (win32.user32.SetClipboardData(win32.user32.CF_UNICODETEXT, mem) == null)
        return error.SetClipboardFailed;
    owned = true;
}

/// The clipboard's text as UTF-8 with CRLF turned into LF, or null when
/// it holds none. Caller owns the result.
pub fn read(alloc: Allocator, hwnd: win32.foundation.HWND) !?[:0]u8 {
    if (win32.user32.IsClipboardFormatAvailable(win32.user32.CF_UNICODETEXT) == 0) return null;

    try openClipboard(hwnd);
    defer _ = win32.user32.CloseClipboard();

    const handle_ = win32.user32.GetClipboardData(win32.user32.CF_UNICODETEXT) orelse return null;
    const capacity = win32.kernel32.GlobalSize(handle_) / @sizeOf(u16);
    const ptr = win32.kernel32.GlobalLock(handle_) orelse return error.LockFailed;
    defer _ = win32.kernel32.GlobalUnlock(handle_);

    // The data is NUL terminated, but never trust another process with
    // that: stop at the end of the block too.
    const units: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (len < capacity and units[len] != 0) len += 1;

    return try utf16ToUtf8(alloc, units[0..len]);
}

/// Open the clipboard for `hwnd`, retrying while another process has it.
fn openClipboard(hwnd: win32.foundation.HWND) !void {
    var attempt: usize = 0;
    while (win32.user32.OpenClipboard(hwnd) == 0) : (attempt += 1) {
        if (attempt >= open_retries) {
            log.warn("clipboard is busy err={}", .{win32.kernel32.GetLastError()});
            return error.ClipboardBusy;
        }
        std.Io.sleep(global.io(), .fromMilliseconds(open_retry_ms), .awake) catch {};
    }
}

/// UTF-16 to UTF-8 with CRLF turned into LF. Unpaired surrogates become
/// U+FFFD instead of failing the whole paste.
fn utf16ToUtf8(alloc: Allocator, units: []const u16) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, units.len);

    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        const u = units[i];
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len and
            units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF)
        {
            cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        } else if (u >= 0xD800 and u <= 0xDFFF) {
            cp = 0xFFFD;
        } else if (u == '\r' and i + 1 < units.len and units[i + 1] == '\n') {
            continue;
        }

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..n]);
    }

    return try out.toOwnedSliceSentinel(alloc, 0);
}

// The tests below use the real system clipboard. Each saves its current
// text and puts it back at the end; other formats (images, files) do not
// survive, and a concurrent clipboard user can still race them.

fn testWindow() !win32.foundation.HWND {
    return win32.user32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        null,
        win32.user32.WS_POPUP,
        0,
        0,
        0,
        0,
        null,
        null,
        null,
        null,
    ) orelse error.CreateWindowFailed;
}

extern "user32" fn EnumClipboardFormats(format: u32) callconv(.winapi) u32;

/// Skips the calling test when the clipboard holds anything but text
/// (images, files, HTML, app-private formats): the tests empty the
/// clipboard, and only its text could be put back afterwards. The text
/// formats Windows converts between on its own do not count.
fn skipUnlessOnlyText(hwnd: win32.foundation.HWND) !void {
    openClipboard(hwnd) catch return error.SkipZigTest;
    defer _ = win32.user32.CloseClipboard();

    const cf_oemtext = 7;
    const cf_locale = 16;
    var format: u32 = 0;
    while (true) {
        format = EnumClipboardFormats(format);
        if (format == 0) return;
        switch (format) {
            win32.user32.CF_TEXT, cf_oemtext, win32.user32.CF_UNICODETEXT, cf_locale => {},
            // No notice is printed: output on stderr makes `zig build test`
            // report the whole run as failed, skip or not.
            else => return error.SkipZigTest,
        }
    }
}

const SavedClipboard = struct {
    text: ?[:0]u8,

    fn save(hwnd: win32.foundation.HWND) !SavedClipboard {
        try skipUnlessOnlyText(hwnd);
        return .{ .text = try read(std.testing.allocator, hwnd) };
    }

    fn restore(self: SavedClipboard, hwnd: win32.foundation.HWND) void {
        if (self.text) |t| {
            write(hwnd, t) catch |err| std.debug.print("restoring the clipboard failed: {}\n", .{err});
            std.testing.allocator.free(t);
        } else if (win32.user32.OpenClipboard(hwnd) != 0) {
            _ = win32.user32.EmptyClipboard();
            _ = win32.user32.CloseClipboard();
        }
    }
};

test "win32 clipboard: write then read roundtrip with non-ASCII" {
    const alloc = std.testing.allocator;
    const hwnd = try testWindow();
    defer _ = win32.user32.DestroyWindow(hwnd);
    const saved = try SavedClipboard.save(hwnd);
    defer saved.restore(hwnd);

    const text = "copy Ж😀\nline2";
    try write(hwnd, text);

    const got = (try read(alloc, hwnd)).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings(text, got);

    // Other programs see CRLF.
    {
        try openClipboard(hwnd);
        defer _ = win32.user32.CloseClipboard();
        const h = win32.user32.GetClipboardData(win32.user32.CF_UNICODETEXT).?;
        const ptr: [*]const u16 = @ptrCast(@alignCast(win32.kernel32.GlobalLock(h).?));
        defer _ = win32.kernel32.GlobalUnlock(h);
        const crlf = std.unicode.utf8ToUtf16LeStringLiteral("copy Ж😀\r\nline2");
        try std.testing.expectEqualSlices(u16, crlf, ptr[0..crlf.len]);
        try std.testing.expectEqual(@as(u16, 0), ptr[crlf.len]);
    }

    // An empty string is a valid, empty clipboard text.
    try write(hwnd, "");
    const empty = (try read(alloc, hwnd)).?;
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "win32 clipboard: utf16 decoding normalizes CRLF and survives bad surrogates" {
    const alloc = std.testing.allocator;

    const a = try utf16ToUtf8(alloc, std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb\rc\n"));
    defer alloc.free(a);
    try std.testing.expectEqualStrings("a\nb\rc\n", a);

    const b = try utf16ToUtf8(alloc, &.{ 'x', 0xD83D, 'y', 0xDE00, 0xD83D });
    defer alloc.free(b);
    try std.testing.expectEqualStrings("x\u{FFFD}y\u{FFFD}\u{FFFD}", b);

    const c = try utf16ToUtf8(alloc, &.{ 0xD83D, 0xDE00 });
    defer alloc.free(c);
    try std.testing.expectEqualStrings("😀", c);
}

/// Holds the clipboard open for a short while. `done_opening` is always
/// set, whether or not the clipboard could be opened, so the waiting test
/// never spins on a thread that has already given up.
const Holder = struct {
    done_opening: std.atomic.Value(bool) = .init(false),
    opened: bool = false,

    fn run(self: *Holder) void {
        self.opened = win32.user32.OpenClipboard(null) != 0;
        self.done_opening.store(true, .release);
        if (!self.opened) return;
        std.Io.sleep(global.io(), .fromMilliseconds(15), .awake) catch {};
        _ = win32.user32.CloseClipboard();
    }
};

test "win32 clipboard: write succeeds while another thread holds the clipboard briefly" {
    const alloc = std.testing.allocator;
    const hwnd = try testWindow();
    defer _ = win32.user32.DestroyWindow(hwnd);
    const saved = try SavedClipboard.save(hwnd);
    defer saved.restore(hwnd);

    var holder: Holder = .{};
    const thread = try std.Thread.spawn(.{}, Holder.run, .{&holder});
    defer thread.join();
    // A bounded wait: a stuck holder fails the test instead of hanging it.
    var waited: usize = 0;
    while (!holder.done_opening.load(.acquire)) : (waited += 1) {
        if (waited >= 2000) return error.HolderTimedOut;
        std.Io.sleep(global.io(), .fromMilliseconds(1), .awake) catch {};
    }
    // `opened` is plain data, ordered by the release/acquire pair above.
    if (!holder.opened) return error.SkipZigTest;

    // The holder has it open now: the first attempts fail and are retried.
    try write(hwnd, "held ж");
    const got = (try read(alloc, hwnd)).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("held ж", got);
}

const Recorder = struct {
    denied: std.ArrayList(apprt.ClipboardRequestType) = .empty,

    fn deny(self: *Recorder, req: apprt.ClipboardRequest) void {
        self.denied.append(std.testing.allocator, std.meta.activeTag(req)) catch unreachable;
    }
};

test "win32 clipboard: pending request is denied when the surface closes" {
    const alloc = std.testing.allocator;

    var state: State = .{};
    try state.queue.append(alloc, .{ .req = .{ .paste = .standard } });
    try state.queue.append(alloc, .{ .req = .{ .osc_52_read = .standard } });
    // The one behind a dialog, with text the state owns.
    state.active = .{
        .req = .{ .osc_52_write = .standard },
        .text = try alloc.dupeSentinel(u8, "payload", 0),
    };
    try state.queue.append(alloc, .{
        .req = .{ .osc_52_write = .standard },
        .text = try alloc.dupeSentinel(u8, "queued", 0),
    });
    var abandoned = false;
    state.abandoned = &abandoned;

    var rec: Recorder = .{};
    defer rec.denied.deinit(alloc);
    state.cancelAll(alloc, &rec, Recorder.deny);

    try std.testing.expect(abandoned);
    try std.testing.expect(state.abandoned == null);
    try std.testing.expect(state.active == null);
    try std.testing.expectEqual(@as(usize, 0), state.queue.items.len);
    try std.testing.expectEqualSlices(
        apprt.ClipboardRequestType,
        &.{ .osc_52_write, .paste, .osc_52_read, .osc_52_write },
        rec.denied.items,
    );

    // A second cancel (nothing left) is a no-op.
    state.cancelAll(alloc, &rec, Recorder.deny);
    try std.testing.expectEqual(@as(usize, 4), rec.denied.items.len);
}
