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
const hooks_mod = @import("hooks.zig");
const messages = @import("messages.zig");
const util = @import("util.zig");
const secure_input = @import("secure_input.zig");
const drop = @import("drop.zig");
const clipboard_formats = @import("clipboard_formats.zig");
const selection_store = @import("selection_store.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32_clipboard);

/// Posted to a surface window when `State` has queued work. No payload; a
/// destroyed window simply drops it.
pub const WM_GHOSTTY_CLIPBOARD_READ = messages.WM_GHOSTTY_CLIPBOARD_READ;

/// How often a busy clipboard (another process has it open) is retried
/// after the first attempt, and how long to wait between attempts.
const open_retries = 5;
const open_retry_ms = 10;

/// What a Kitty clipboard read gathered from the clipboard: the data of the
/// requested representations and the listing, read once before any prompt.
/// The prompt shows these bytes and an allowed read serves these same
/// bytes; the clipboard is never read again.
const Gathered = struct {
    /// Data owned by `alloc`; each `mime` is borrowed (the canonical text
    /// name, or the request's own spelling) and only valid while the request
    /// is alive.
    contents: []terminal.clipboard.Content = &.{},

    /// The listing, the slice and every name owned by `alloc`.
    available: []const []const u8 = &.{},

    fn deinit(self: *Gathered, alloc: Allocator) void {
        for (self.contents) |c| alloc.free(c.data);
        alloc.free(self.contents);
        for (self.available) |a| alloc.free(a);
        alloc.free(self.available);
        self.* = .{};
    }
};

/// One queued piece of clipboard work.
const Pending = struct {
    req: apprt.ClipboardRequest,

    /// The text of an `osc_52_write`, owned by the queue.
    text: ?[:0]u8 = null,

    /// What a `kitty_read` gathered, owned by the entry from the moment it
    /// is shown to the user until the request is answered.
    gathered: ?Gathered = null,

    /// Free what the entry owns. Not the request: core consumes or denies it.
    fn release(self: *Pending, alloc: Allocator) void {
        if (self.text) |t| alloc.free(t);
        self.text = null;
        if (self.gathered) |*g| g.deinit(alloc);
        self.gathered = null;
    }
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

        if (self.active) |*p| {
            deny(ctx, p.req);
            p.release(alloc);
            self.active = null;
        }

        for (self.queue.items) |*p| {
            deny(ctx, p.req);
            p.release(alloc);
        }
        self.queue.deinit(alloc);
        self.queue = .empty;
    }
};

/// The MIME types the clipboard offers, and one representation of it.
pub const listMimes = clipboard_formats.list;
pub const readMime = clipboard_formats.readMime;

/// Whether `t` exists on Windows: the standard clipboard and the selection
/// clipboard, which is Ghostty's own in-process store (as on macOS) and never
/// the Windows clipboard. The X11 primary selection does not exist (a Kitty
/// `loc=primary` is answered ENOSYS).
pub fn supports(t: apprt.Clipboard) bool {
    return t == .standard or t == .selection;
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
    if (preflight(&surface.app.selection, t, req)) |answer| return answer;

    // Lets performable paste bindings fall through when there is nothing
    // to paste (an image, say). An OSC 52 read of such a clipboard is
    // answered with empty contents instead.
    if (req == .paste and t == .standard and sourceFor(
        req,
        win32.user32.IsClipboardFormatAvailable(win32.user32.CF_UNICODETEXT) != 0,
        win32.user32.IsClipboardFormatAvailable(cf_hdrop) != 0,
    ) == null) {
        return .unavailable;
    }

    try enqueue(surface, .{ .req = req });
    return .started;
}

/// `admission`, plus the selection clipboard: a paste from an empty one is
/// `.unavailable`, so a binding (middle click) falls through (R-M8-9). The
/// system clipboard is checked by `request` itself.
fn preflight(
    selection: *const selection_store.Store,
    t: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) ?apprt.ClipboardReadResult {
    if (admission(t, req)) |answer| return answer;
    if (req == .paste and t == .selection and selection.get("text/plain") == null) return .unavailable;
    return null;
}

/// The answer to a request that is turned away before anything is queued
/// or asked: a clipboard Windows does not have, and the one request type
/// that is never started here. Null means the request is queued. A Kitty
/// read or write to a location this apprt cannot serve is `.unsupported`
/// (core answers the program ENOSYS) before any prompt.
fn admission(t: apprt.Clipboard, req: apprt.ClipboardRequest) ?apprt.ClipboardReadResult {
    if (!supports(t)) return .unsupported;
    return switch (req) {
        // An OSC 52 write comes through `setClipboard`.
        .osc_52_write => .unsupported,
        .paste, .osc_52_read, .kitty_read, .kitty_write, .list => null,
    };
}

const cf_hdrop = win32.ole32.CF_HDROP;

const Source = enum { text, files };

/// What a request reads from the clipboard. Text wins when both formats
/// exist (Explorer puts only `CF_HDROP` for a file copy). A file list is
/// only ever offered to a paste: an OSC 52 read never returns one.
fn sourceFor(req: apprt.ClipboardRequest, has_text: bool, has_files: bool) ?Source {
    if (has_text) return .text;
    if (has_files and req == .paste) return .files;
    return null;
}

/// The paste text for a `DROPFILES` block: its paths quoted for `kind`,
/// exactly as a drop is. A path a drag or a copy source could use to break
/// the quoting (control characters, `"<>|*?`) refuses the whole list.
fn textFromDropFiles(alloc: Allocator, kind: drop.ShellKind, block: []const u8) ![:0]u8 {
    const paths = try drop.pathsFromDropFiles(alloc, block);
    defer drop.freePaths(alloc, paths);
    for (paths) |p| if (!drop.pathIsSafe(p)) {
        log.warn("refusing a pasted file list with a path that has control or shell characters", .{});
        return error.UnsafePath;
    };
    const views: []const []const u8 = @ptrCast(paths);
    const quoted = try drop.quote(alloc, kind, views);
    defer alloc.free(quoted);
    return alloc.dupeSentinel(u8, quoted, 0);
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

    // The selection clipboard never leaves the process: no Windows
    // clipboard, no toast, no secure-input markers.
    if (t == .selection and !confirm) return setSelection(surface.app, contents);

    if (!confirm) {
        const alloc = surface.app.core_app.alloc;
        var p = try clipboard_formats.plan(alloc, contents);
        defer p.deinit(alloc);
        // A write with nothing the clipboard can hold is an error core can
        // report (kitty answers EIO).
        if (p.entries.len == 0) return error.NothingToWrite;
        try clipboard_formats.writePlan(surface.hwnd, p, secure_input.copying(surface.app));
        hooks_mod.clipboardWritten(surface, p.cleared);
        return;
    }

    // Behind a confirmation only OSC 52 text is written.
    const text: [:0]const u8 = for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) break content.data;
    } else return error.NothingToWrite;

    const alloc = surface.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, text, 0);
    errdefer alloc.free(copy);
    try enqueue(surface, .{ .req = .{ .osc_52_write = t }, .text = copy });
}

/// Replace the selection clipboard with `contents`.
fn setSelection(app: *App, contents: []const apprt.ClipboardContent) !void {
    var buf: [selection_store.max_contents]selection_store.Content = undefined;
    const n = @min(contents.len, buf.len);
    for (contents[0..n], buf[0..n]) |c, *slot| slot.* = .{ .mime = c.mime, .data = c.data };
    if (n == 0) return error.NothingToWrite;
    try app.selection.set(app.core_app.alloc, buf[0..n]);
}

/// Deny every clipboard request still pending for `surface`. Called before
/// the core surface is torn down.
pub fn cancelPending(surface: *Surface) void {
    const alloc = surface.app.core_app.alloc;
    surface.clipboard_state.cancelAll(alloc, &surface.core_surface, denyCore);
}

fn denyCore(core: *CoreSurface, req: apprt.ClipboardRequest) void {
    core.denyClipboardRequest(req);
}

fn enqueue(surface: *Surface, p: Pending) !void {
    const alloc = surface.app.core_app.alloc;
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
    const alloc = surface.app.core_app.alloc;
    while (state.pop()) |p| {
        if (!process(surface, alloc, p)) return;
    }
}

const Answer = enum { yes, no, gone };

/// The user's decision on a prompt. `remember` is only ever true with `.yes`.
const Decision = struct {
    answer: Answer,
    remember: bool = false,
};

/// Handle one entry. False means the surface was destroyed behind a
/// dialog and must not be touched.
fn process(surface: *Surface, alloc: Allocator, p: Pending) bool {
    switch (p.req) {
        .osc_52_write => {
            const text = p.text orelse return true;
            const parts = [_]dialogs.ClipboardPart{.{ .mime = "text/plain", .data = text }};
            const answer = confirmParts(surface, p, .write, &parts, false).answer;
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

        // Never prompts: a listing discloses no data.
        .list => {
            var flow: ListFlow = .{ .surface = surface, .p = p };
            runList(&flow);
            return true;
        },

        .kitty_write => |kitty| {
            var flow: KittyFlow = .{ .surface = surface, .alloc = alloc, .p = p };
            return runKitty(&flow, .{}, kitty.pw.len > 0);
        },

        .kitty_read => |kitty| {
            var entry = p;
            const started: std.Io.Timestamp = .now(global.io(), .awake);
            entry.gathered = gatherFor(alloc, surface, kitty) catch |err| {
                log.warn("clipboard read failed err={}", .{err});
                surface.core_surface.denyClipboardRequest(p.req);
                return true;
            };
            const g = entry.gathered.?;
            var bytes: usize = 0;
            for (g.contents) |c| bytes += c.data.len;
            log.info("kitty read gathered {d} representations, {d} bytes in {d} ms", .{
                g.contents.len,
                bytes,
                started.durationTo(.now(global.io(), .awake)).toMilliseconds(),
            });
            var flow: KittyFlow = .{ .surface = surface, .alloc = alloc, .p = entry };
            const alive = runKitty(&flow, g, kitty.pw.len > 0);
            // Gone: `cancelAll` already freed what the entry owned.
            if (alive) entry.release(alloc);
            return alive;
        },

        .paste, .osc_52_read => {
            // Text handed to `pasteText` travels with the entry; anything
            // else is read from the clipboard now.
            const given = p.text;
            const maybe_text: ?[:0]u8 = given orelse readTextFor(alloc, surface, p.req) catch |err| blk: {
                log.warn("clipboard read failed err={}", .{err});
                break :blk null;
            };
            // Nothing to give: a paste just doesn't happen and an OSC 52
            // read is answered with empty contents.
            const text = maybe_text orelse {
                surface.core_surface.denyClipboardRequest(p.req);
                return true;
            };

            var flow: RequestFlow = .{ .surface = surface, .alloc = alloc, .p = p };
            const alive = runRequest(&flow, text);
            // Gone: `cancelAll` already freed what the entry owned.
            if (alive or given == null) alloc.free(text);
            return alive;
        },
    }
}

/// The core and dialog side of a paste or OSC 52 read, so that
/// `runRequest` can be driven by a fake in tests.
const RequestFlow = struct {
    surface: *Surface,
    alloc: Allocator,
    p: Pending,

    fn complete(self: *RequestFlow, text: []const u8, confirmed: bool) !void {
        try self.surface.core_surface.completeClipboardRequest(self.p.req, .{
            .contents = &.{.{ .mime = "text/plain", .data = text }},
            .confirmed = confirmed,
        });
    }

    fn confirm(self: *RequestFlow, text: []const u8) Answer {
        const parts = [_]dialogs.ClipboardPart{.{ .mime = "text/plain", .data = text }};
        const kind: dialogs.ClipboardKind = if (self.p.req == .paste) .paste else .read;
        return confirmParts(self.surface, self.p, kind, &parts, false).answer;
    }

    fn deny(self: *RequestFlow) void {
        self.surface.core_surface.denyClipboardRequest(self.p.req);
    }
};

/// Complete a paste or OSC 52 read with `text`: straight away when core
/// accepts it, behind a confirmation when core calls it unsafe or
/// unauthorized. Nothing reaches the pty before the answer. A request that
/// cannot be completed is denied, which answers an OSC 52 read with empty
/// contents. False means the surface was destroyed behind the dialog.
fn runRequest(flow: anytype, text: []const u8) bool {
    flow.complete(text, false) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            switch (flow.confirm(text)) {
                .gone => return false,
                .yes => flow.complete(text, true) catch |e| {
                    log.warn("clipboard request failed err={}", .{e});
                    flow.deny();
                },
                .no => flow.deny(),
            }
        },
        else => {
            log.warn("clipboard request failed err={}", .{err});
            flow.deny();
        },
    };
    return true;
}

/// Paste `text` that did not come from the clipboard (a file drop, say)
/// the way Ctrl+V pastes: through the same confirmation when it is unsafe.
/// Queued, never run inline, for the reason in the file header. A failure
/// is logged and the text dropped.
pub fn pasteText(surface: *Surface, text: [:0]const u8) void {
    const alloc = surface.app.core_app.alloc;
    const copy = alloc.dupeSentinel(u8, text, 0) catch |err| {
        log.warn("paste text copy failed err={}", .{err});
        return;
    };
    enqueue(surface, .{ .req = .{ .paste = .standard }, .text = copy }) catch |err| {
        log.warn("paste text queue failed err={}", .{err});
        alloc.free(copy);
    };
}

/// Ask the user about `p`, showing `parts` in the prompt (the dialog copies
/// what it shows before it appears). While the dialog is up `p` is
/// registered in the state so that destroying the surface denies it, and
/// the answer is `.gone` if that happened.
fn confirmParts(
    surface: *Surface,
    p: Pending,
    kind: dialogs.ClipboardKind,
    parts: []const dialogs.ClipboardPart,
    can_remember: bool,
) Decision {
    // Everything the dialog needs is copied out first: the surface may not
    // be there when it returns.
    const owner = surface.window.hwnd;
    const state = &surface.clipboard_state;

    var abandoned = false;
    state.abandoned = &abandoned;
    state.active = p;

    const got = dialogs.confirmClipboard(owner, kind, parts, can_remember);

    // Past this point only the local flag may be looked at before it is
    // known whether the surface survived.
    if (abandoned) return .{ .answer = .gone };
    state.abandoned = null;
    state.active = null;
    return .{
        .answer = if (got.allow) .yes else .no,
        .remember = got.allow and can_remember and got.remember,
    };
}

/// Where a Kitty read finds the clipboard, so `gather` can be driven by a
/// fake in tests.
const ClipboardReader = struct {
    hwnd: win32.foundation.HWND,

    fn read(self: ClipboardReader, alloc: Allocator, mime: []const u8) !?[]u8 {
        return readMime(alloc, self.hwnd, mime);
    }

    fn list(
        self: ClipboardReader,
        buf: *[clipboard_formats.max_listing][]const u8,
        names: *clipboard_formats.NameBuf,
    ) ![]const []const u8 {
        return listMimes(self.hwnd, buf, names);
    }
};

/// Where a Kitty read finds the selection clipboard: the in-process store.
const StoreReader = struct {
    store: *const selection_store.Store,

    fn read(self: StoreReader, alloc: Allocator, mime: []const u8) !?[]u8 {
        const data = self.store.get(mime) orelse return null;
        return try alloc.dupe(u8, data);
    }

    fn list(
        self: StoreReader,
        buf: *[clipboard_formats.max_listing][]const u8,
        names: *clipboard_formats.NameBuf,
    ) ![]const []const u8 {
        _ = names;
        return self.store.mimes(buf);
    }
};

/// `gather` from the clipboard `kitty` names.
fn gatherFor(
    alloc: Allocator,
    surface: *Surface,
    kitty: *const apprt.ClipboardRequest.KittyRead,
) Allocator.Error!Gathered {
    if (kitty.location == .selection) {
        return gather(alloc, kitty, StoreReader{ .store = &surface.app.selection });
    }
    return gather(alloc, kitty, ClipboardReader{ .hwnd = surface.hwnd });
}

/// The text a paste or an OSC 52 read of `req` finds: the selection
/// clipboard's, or the system clipboard's (`readFor`).
fn readTextFor(alloc: Allocator, surface: *Surface, req: apprt.ClipboardRequest) !?[:0]u8 {
    const t: apprt.Clipboard = switch (req) {
        .paste, .osc_52_read => |c| c,
        else => .standard,
    };
    if (t == .selection) return readSelection(alloc, &surface.app.selection);
    return readFor(alloc, surface, req);
}

/// The first text of the selection clipboard, made valid UTF-8 as an OSC 52
/// payload is. Null when it holds none. Caller owns the result.
fn readSelection(alloc: Allocator, store: *const selection_store.Store) Allocator.Error!?[:0]u8 {
    const text = store.get("text/plain") orelse return null;
    const clean = try sanitize(alloc, text);
    defer alloc.free(clean);
    if (clean.len == 0) return null;
    return try alloc.dupeSentinel(u8, clean, 0);
}

/// The name a representation is served under: every text alias is
/// `text/plain` (core matches the aliases itself), anything else keeps the
/// request's spelling.
fn servedName(mime: []const u8) []const u8 {
    return if (terminal.clipboard.isTextMime(mime)) "text/plain" else mime;
}

/// Read what a Kitty read asked for, once: each requested representation
/// (read under its served name once, however often or under which alias it
/// was asked for) and, when requested, the listing. A representation that
/// cannot be read is simply absent, which is how the protocol says "not
/// available"; so is a failed listing. Only an allocation failure is an
/// error.
fn gather(
    alloc: Allocator,
    kitty: *const apprt.ClipboardRequest.KittyRead,
    reader: anytype,
) Allocator.Error!Gathered {
    var out: std.ArrayList(terminal.clipboard.Content) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c.data);
        out.deinit(alloc);
    }

    for (kitty.mimes, 0..) |mime, i| {
        const name = servedName(mime);
        const again = for (kitty.mimes[0..i]) |earlier| {
            if (std.mem.eql(u8, servedName(earlier), name)) break true;
        } else false;
        if (again) continue;

        const got = reader.read(alloc, name) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.warn("clipboard representation not read err={}", .{err});
            continue;
        };
        const data = got orelse continue;
        errdefer alloc.free(data);
        try out.append(alloc, .{ .mime = name, .data = data });
    }

    var available: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (available.items) |a| alloc.free(a);
        available.deinit(alloc);
    }
    if (kitty.list) {
        var buf: [clipboard_formats.max_listing][]const u8 = undefined;
        var names: clipboard_formats.NameBuf = .{};
        if (reader.list(&buf, &names)) |found| {
            for (found) |m| {
                const copy = try alloc.dupe(u8, m);
                errdefer alloc.free(copy);
                try available.append(alloc, copy);
            }
        } else |err| log.warn("clipboard listing not read err={}", .{err});
    }

    const contents = try out.toOwnedSlice(alloc);
    errdefer {
        for (contents) |c| alloc.free(c.data);
        alloc.free(contents);
    }
    return .{ .contents = contents, .available = try available.toOwnedSlice(alloc) };
}

/// The core side of a paste event listing, so that `runList` can be driven
/// by a fake in tests.
const ListFlow = struct {
    surface: *Surface,
    p: Pending,

    fn listing(
        self: *ListFlow,
        buf: *[clipboard_formats.max_listing][]const u8,
        names: *clipboard_formats.NameBuf,
    ) ![]const []const u8 {
        if (self.p.req == .list and self.p.req.list == .selection) {
            return self.surface.app.selection.mimes(buf);
        }
        return listMimes(self.surface.hwnd, buf, names);
    }

    fn complete(self: *ListFlow, available: []const []const u8) !void {
        try self.surface.core_surface.completeClipboardRequest(self.p.req, .{ .available = available });
    }

    fn deny(self: *ListFlow) void {
        self.surface.core_surface.denyClipboardRequest(self.p.req);
    }
};

/// Answer a listing request with the MIME types on the clipboard. Never
/// asks: the listing is metadata only. A failure still ends the request.
fn runList(flow: anytype) void {
    var buf: [clipboard_formats.max_listing][]const u8 = undefined;
    var names: clipboard_formats.NameBuf = .{};
    const found = flow.listing(&buf, &names) catch |err| {
        log.warn("clipboard listing failed err={}", .{err});
        flow.deny();
        return;
    };
    flow.complete(found) catch |err| {
        log.warn("clipboard listing not delivered err={}", .{err});
        flow.deny();
    };
}

/// The core and dialog side of a Kitty read or write, so that `runKitty` can
/// be driven by a fake in tests.
const KittyFlow = struct {
    surface: *Surface,
    alloc: Allocator,
    /// For a read, with `gathered` set (the same data `runKitty` is given).
    p: Pending,

    /// True when answering discloses nothing: a read that found no data (its
    /// listing is metadata, as for the `.` read that never prompts).
    fn disclosesNothing(self: *const KittyFlow, g: Gathered) bool {
        return self.p.req == .kitty_read and g.contents.len == 0;
    }

    fn complete(self: *KittyFlow, g: Gathered, confirmed: bool, remember: bool) !void {
        try self.surface.core_surface.completeClipboardRequest(self.p.req, completeFor(g, confirmed, remember));
    }

    /// The prompt shows exactly what will be served: the gathered data of a
    /// read, the committed contents of a write.
    fn confirm(self: *KittyFlow, g: Gathered, can_remember: bool) Decision {
        const kind: dialogs.ClipboardKind = if (self.p.req == .kitty_write) .write else .read;
        const parts = self.alloc.alloc(dialogs.ClipboardPart, partCount(self.p.req, g)) catch return .{ .answer = .no };
        defer self.alloc.free(parts);
        fillParts(self.p.req, g, parts);
        return confirmParts(self.surface, self.p, kind, parts, can_remember);
    }

    fn deny(self: *KittyFlow) void {
        self.surface.core_surface.denyClipboardRequest(self.p.req);
    }
};

/// What core is given to answer with: the gathered data itself, never a copy
/// or a second read. (A write carries its own contents in the request.)
fn completeFor(g: Gathered, confirmed: bool, remember: bool) CoreSurface.CompleteClipboard {
    return .{
        .contents = g.contents,
        .available = g.available,
        .confirmed = confirmed,
        .remember = remember,
    };
}

/// How many representations the prompt of `req` lists.
fn partCount(req: apprt.ClipboardRequest, g: Gathered) usize {
    return switch (req) {
        .kitty_read => g.contents.len,
        .kitty_write => |w| w.contents.len,
        else => 0,
    };
}

/// The representations the prompt of `req` lists: the gathered data of a
/// read, the committed contents of a write. `parts.len == partCount(..)`.
fn fillParts(req: apprt.ClipboardRequest, g: Gathered, parts: []dialogs.ClipboardPart) void {
    switch (req) {
        .kitty_read => for (g.contents, parts) |c, *part| {
            part.* = .{ .mime = c.mime, .data = c.data };
        },
        .kitty_write => |w| for (w.contents, parts) |c, *part| {
            part.* = .{ .mime = c.mime, .data = c.data };
        },
        else => {},
    }
}

/// Answer a Kitty read or write: straight away when core accepts it,
/// behind a confirmation when it is unauthorized, with the same data in
/// the prompt and in the answer. Every path ends in exactly one of core
/// consuming the request or `deny`: past core's permission check it
/// consumes the request even when it then fails, so a failure there is only
/// logged. `can_remember` is true for a request with a session password.
/// False means the surface was destroyed behind the dialog. `g` is what a
/// read gathered (empty for a write): the one value handed both to the
/// prompt and to the answer.
fn runKitty(flow: anytype, g: Gathered, can_remember: bool) bool {
    flow.complete(g, flow.disclosesNothing(g), false) catch |err| switch (err) {
        error.UnauthorizedPaste => {
            const decision = flow.confirm(g, can_remember);
            switch (decision.answer) {
                .gone => return false,
                .no => flow.deny(),
                .yes => flow.complete(g, true, decision.remember and can_remember) catch |e| switch (e) {
                    // Cannot happen once confirmed; never leave it unanswered.
                    error.UnauthorizedPaste => flow.deny(),
                    else => log.warn("clipboard request failed err={}", .{e}),
                },
            }
        },
        else => log.warn("clipboard request failed err={}", .{err}),
    };
    return true;
}

/// Put `text_utf8` on the system clipboard as CF_UNICODETEXT, with lone
/// line feeds turned into the CRLF other Windows programs expect. `hwnd`
/// must be a real window: it becomes the clipboard owner, and a clipboard
/// opened without one cannot be given data.
pub fn write(hwnd: win32.foundation.HWND, text_utf8: []const u8, secure: bool) !void {
    const alloc = global.alloc();
    var p = try clipboard_formats.textPlan(alloc, text_utf8);
    defer p.deinit(alloc);
    try clipboard_formats.writePlan(hwnd, p, secure);
}

/// A DWORD-valued clipboard format registered by name. Clipboard monitors
/// (Windows clipboard history, cloud clipboard, third-party managers) read
/// these by convention; nothing enforces them, any program can still read
/// the data itself.
pub const ExtraFormat = struct {
    name: [:0]const u16,
    value: u32,
};

const secure_formats = [_]ExtraFormat{
    .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("ExcludeClipboardContentFromMonitorProcessing"), .value = 1 },
    .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("CanIncludeInClipboardHistory"), .value = 0 },
    .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("CanUploadToCloudClipboard"), .value = 0 },
};

/// The formats a copy adds next to its text: the three exclusion markers
/// while secure input is on, none otherwise.
pub fn extraFormats(secure: bool) []const ExtraFormat {
    return if (secure) &secure_formats else &.{};
}

/// Adds `extra` to the open clipboard. Best effort: the copy itself has
/// succeeded and a missing marker must not undo it.
pub fn setExtraFormat(extra: ExtraFormat) void {
    const format = win32.user32.RegisterClipboardFormatW(extra.name.ptr);
    if (format == 0) {
        log.warn("unable to register a clipboard format err={}", .{win32.kernel32.GetLastError()});
        return;
    }
    const mem = win32.kernel32.GlobalAlloc(win32.kernel32.GMEM_MOVEABLE, @sizeOf(u32)) orelse return;
    {
        const ptr = win32.kernel32.GlobalLock(mem) orelse {
            _ = win32.kernel32.GlobalFree(mem);
            return;
        };
        defer _ = win32.kernel32.GlobalUnlock(mem);
        const dst: *align(1) u32 = @ptrCast(ptr);
        dst.* = extra.value;
    }
    if (win32.user32.SetClipboardData(format, mem) == null) {
        log.warn("unable to set a clipboard marker err={}", .{win32.kernel32.GetLastError()});
        _ = win32.kernel32.GlobalFree(mem);
    }
}

/// What an OSC 52 payload may carry that the clipboard cannot: invalid
/// UTF-8 becomes U+FFFD, and an embedded NUL ends the text (a Windows
/// clipboard string is NUL terminated). Caller owns the result.
pub fn sanitize(alloc: Allocator, text: []const u8) ![]u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, 0)) |nul| {
        log.warn("clipboard text has an embedded NUL, truncated at byte {}", .{nul});
        end = nul;
    }
    const src = text[0..end];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, src.len);

    var i: usize = 0;
    while (i < src.len) {
        const len = std.unicode.utf8ByteSequenceLength(src[i]) catch 0;
        if (len != 0 and i + len <= src.len and std.unicode.utf8ValidateSlice(src[i..][0..len])) {
            try out.appendSlice(alloc, src[i..][0..len]);
            i += len;
        } else {
            try out.appendSlice(alloc, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
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

/// What `req` pastes from the clipboard: its text, else (a paste only) the
/// quoted paths of a copied file list. Null when there is neither.
fn readFor(alloc: Allocator, surface: *Surface, req: apprt.ClipboardRequest) !?[:0]u8 {
    if (try read(alloc, surface.hwnd)) |text| return text;
    if (sourceFor(req, false, win32.user32.IsClipboardFormatAvailable(cf_hdrop) != 0) == null) return null;
    return readFiles(alloc, surface.hwnd, surface.shell_kind);
}

/// The quoted paths of the clipboard's `CF_HDROP`, or null without one.
fn readFiles(alloc: Allocator, hwnd: win32.foundation.HWND, kind: drop.ShellKind) !?[:0]u8 {
    try openClipboard(hwnd);
    defer _ = win32.user32.CloseClipboard();

    const handle_ = win32.user32.GetClipboardData(cf_hdrop) orelse return null;
    const size = win32.kernel32.GlobalSize(handle_);
    const ptr = win32.kernel32.GlobalLock(handle_) orelse return error.LockFailed;
    defer _ = win32.kernel32.GlobalUnlock(handle_);

    const bytes: [*]const u8 = @ptrCast(ptr);
    return try textFromDropFiles(alloc, kind, bytes[0..size]);
}

/// Open the clipboard for `hwnd`, retrying while another process has it.
pub fn openClipboard(hwnd: win32.foundation.HWND) !void {
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
        format = win32.user32.EnumClipboardFormats(format);
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
            write(hwnd, t, false) catch |err| std.debug.print("restoring the clipboard failed: {}\n", .{err});
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
    try write(hwnd, text, false);

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
    try write(hwnd, "", false);
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
    try write(hwnd, "held ж", false);
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

/// A gathered read as `gather` makes it, for the tests.
fn testGathered(alloc: Allocator) !Gathered {
    const contents = try alloc.alloc(terminal.clipboard.Content, 2);
    errdefer alloc.free(contents);
    contents[0] = .{ .mime = "text/plain", .data = try alloc.dupe(u8, "hello") };
    errdefer alloc.free(contents[0].data);
    contents[1] = .{ .mime = "image/png", .data = try alloc.dupe(u8, "PNGDATA") };
    errdefer alloc.free(contents[1].data);
    const available = try alloc.alloc([]const u8, 2);
    errdefer alloc.free(available);
    available[0] = try alloc.dupe(u8, "text/plain");
    errdefer alloc.free(available[0]);
    available[1] = try alloc.dupe(u8, "image/png");
    return .{ .contents = contents, .available = available };
}

test "win32 clipboard: pending request is denied when the surface closes" {
    const alloc = std.testing.allocator;

    // The requests are only recorded (the recorder does not destroy them),
    // so stand-ins are enough.
    var kitty_read: apprt.ClipboardRequest.KittyRead = undefined;
    var kitty_write: apprt.ClipboardRequest.KittyWrite = undefined;

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
    // Kitty entries: a read with data gathered, a listing.
    try state.queue.append(alloc, .{
        .req = .{ .kitty_read = &kitty_read },
        .gathered = try testGathered(alloc),
    });
    try state.queue.append(alloc, .{ .req = .{ .list = .standard } });
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
        &.{ .osc_52_write, .paste, .osc_52_read, .osc_52_write, .kitty_read, .list },
        rec.denied.items,
    );

    // A second cancel (nothing left) is a no-op.
    state.cancelAll(alloc, &rec, Recorder.deny);
    try std.testing.expectEqual(@as(usize, 6), rec.denied.items.len);

    // A kitty write behind its dialog, and a read whose data was shown.
    state.active = .{ .req = .{ .kitty_write = &kitty_write } };
    try state.queue.append(alloc, .{
        .req = .{ .kitty_read = &kitty_read },
        .gathered = try testGathered(alloc),
    });
    state.cancelAll(alloc, &rec, Recorder.deny);
    try std.testing.expectEqualSlices(
        apprt.ClipboardRequestType,
        &.{ .kitty_write, .kitty_read },
        rec.denied.items[6..],
    );
}

test "win32 clipboard: osc52 invalid utf8 replaced" {
    const alloc = std.testing.allocator;

    const a = try sanitize(alloc, "a\xffb\xe2\x82");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}", a);

    // Valid text is untouched, an embedded NUL ends it.
    const b = try sanitize(alloc, "Ж😀\x00tail");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("Ж😀", b);
}

const FakeFlow = struct {
    /// What core says to an unconfirmed completion.
    unsafe: bool,
    answer: Answer,
    fail_confirmed: bool = false,

    written: usize = 0,
    asked: usize = 0,
    denied: usize = 0,

    fn complete(self: *FakeFlow, text: []const u8, confirmed: bool) error{ UnsafePaste, UnauthorizedPaste, OutOfMemory }!void {
        _ = text;
        if (!confirmed and self.unsafe) return error.UnsafePaste;
        if (confirmed and self.fail_confirmed) return error.OutOfMemory;
        self.written += 1;
    }

    fn confirm(self: *FakeFlow, text: []const u8) Answer {
        _ = text;
        self.asked += 1;
        // Nothing may have been written before the answer.
        std.debug.assert(self.written == 0);
        return self.answer;
    }

    fn deny(self: *FakeFlow) void {
        self.denied += 1;
    }
};

test "win32 clipboard: pasteText asks for unsafe text" {
    // Multi-line text: asked first, written only after yes.
    var multi: FakeFlow = .{ .unsafe = true, .answer = .yes };
    try std.testing.expect(runRequest(&multi, "a\nb"));
    try std.testing.expectEqual(@as(usize, 1), multi.asked);
    try std.testing.expectEqual(@as(usize, 1), multi.written);

    // Declined: nothing written, the request is denied.
    var no: FakeFlow = .{ .unsafe = true, .answer = .no };
    try std.testing.expect(runRequest(&no, "a\nb"));
    try std.testing.expectEqual(@as(usize, 0), no.written);
    try std.testing.expectEqual(@as(usize, 1), no.denied);

    // Safe text: written at once, no question.
    var single: FakeFlow = .{ .unsafe = false, .answer = .no };
    try std.testing.expect(runRequest(&single, "one line"));
    try std.testing.expectEqual(@as(usize, 0), single.asked);
    try std.testing.expectEqual(@as(usize, 1), single.written);

    // Surface destroyed behind the dialog.
    var gone: FakeFlow = .{ .unsafe = true, .answer = .gone };
    try std.testing.expect(!runRequest(&gone, "a\nb"));

    // A confirmed completion that fails still answers the request.
    var failing: FakeFlow = .{ .unsafe = true, .answer = .yes, .fail_confirmed = true };
    try std.testing.expect(runRequest(&failing, "a\nb"));
    try std.testing.expectEqual(@as(usize, 1), failing.denied);
}

test "win32 clipboard: secure copy adds exclusion formats" {
    try std.testing.expectEqual(@as(usize, 0), extraFormats(false).len);

    const extras = extraFormats(true);
    try std.testing.expectEqual(@as(usize, 3), extras.len);
    const expected = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "ExcludeClipboardContentFromMonitorProcessing", .value = 1 },
        .{ .name = "CanIncludeInClipboardHistory", .value = 0 },
        .{ .name = "CanUploadToCloudClipboard", .value = 0 },
    };
    for (extras, expected) |extra, want| {
        var buf: [64]u8 = undefined;
        const n = try std.unicode.utf16LeToUtf8(&buf, extra.name);
        try std.testing.expectEqualStrings(want.name, buf[0..n]);
        try std.testing.expectEqual(want.value, extra.value);
    }
}

fn testDropFiles(alloc: Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var header: [20]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 20, .little);
    std.mem.writeInt(u32, header[16..20], 1, .little);
    try out.appendSlice(alloc, &header);
    for (paths) |p| {
        const w = try std.unicode.utf8ToUtf16LeAlloc(alloc, p);
        defer alloc.free(w);
        for (w) |u| try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
        try out.appendSlice(alloc, &.{ 0, 0 });
    }
    try out.appendSlice(alloc, &.{ 0, 0 });
    return out.toOwnedSlice(alloc);
}

test "win32 clipboard: a file list pastes as quoted paths" {
    const alloc = std.testing.allocator;
    const paths = [_][]const u8{ "C:\\My Files\\a b.txt", "C:\\it's\\x.txt" };
    const block = try testDropFiles(alloc, &paths);
    defer alloc.free(block);

    for ([_]drop.ShellKind{ .msys, .pwsh, .cmd }) |kind| {
        const want = try drop.quote(alloc, kind, &paths);
        defer alloc.free(want);
        const got = try textFromDropFiles(alloc, kind, block);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(want, got);
    }

    // A path that could break the quoting refuses the whole list.
    const bad = try testDropFiles(alloc, &.{ "C:\\ok.txt", "C:\\a\r\nb.txt" });
    defer alloc.free(bad);
    try std.testing.expectError(error.UnsafePath, textFromDropFiles(alloc, .msys, bad));
}

test "win32 clipboard: text wins over a file list" {
    const paste: apprt.ClipboardRequest = .{ .paste = .standard };
    const read52: apprt.ClipboardRequest = .{ .osc_52_read = .standard };

    try std.testing.expectEqual(Source.text, sourceFor(paste, true, true).?);
    try std.testing.expectEqual(Source.text, sourceFor(read52, true, true).?);
    try std.testing.expectEqual(Source.files, sourceFor(paste, false, true).?);
    try std.testing.expect(sourceFor(paste, false, false) == null);
    // An OSC 52 read never returns a file list.
    try std.testing.expect(sourceFor(read52, false, true) == null);
}

fn testPng(alloc: Allocator) ![:0]u8 {
    const image = @import("clipboard_image.zig");
    var px = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    const png = try image.encodePng(alloc, .{ .width = 2, .height = 2, .pixels = &px });
    defer alloc.free(png);
    return alloc.dupeSentinel(u8, png, 0);
}

test "win32 clipboard: multi-format roundtrip" {
    const alloc = std.testing.allocator;
    const hwnd = try testWindow();
    defer _ = win32.user32.DestroyWindow(hwnd);
    const saved = try SavedClipboard.save(hwnd);
    defer saved.restore(hwnd);

    const png = try testPng(alloc);
    defer alloc.free(png);

    var p = try clipboard_formats.plan(alloc, &.{
        .{ .mime = "text/plain", .data = "rich Ж\nline2" },
        .{ .mime = "text/html", .data = "<b>rich</b>" },
        .{ .mime = "image/png", .data = png },
    });
    defer p.deinit(alloc);
    try clipboard_formats.writePlan(hwnd, p, false);

    const text = (try readMime(alloc, hwnd, "text/plain")).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("rich Ж\nline2", text);

    const frag = (try readMime(alloc, hwnd, "text/html")).?;
    defer alloc.free(frag);
    try std.testing.expectEqualStrings("<b>rich</b>", frag);

    const back = (try readMime(alloc, hwnd, "image/png")).?;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u8, png, back);

    try std.testing.expect(try readMime(alloc, hwnd, "image/gif") == null);
    try std.testing.expect(try readMime(alloc, hwnd, "text/uri-list") == null);

    var buf: [clipboard_formats.max_listing][]const u8 = undefined;
    var names: clipboard_formats.NameBuf = .{};
    const mimes = try listMimes(hwnd, &buf, &names);
    try std.testing.expectEqual(@as(usize, 3), mimes.len);
    try std.testing.expectEqualStrings("text/plain", mimes[0]);
    try std.testing.expectEqualStrings("text/html", mimes[1]);
    try std.testing.expectEqualStrings("image/png", mimes[2]);

    // Programs without PNG support get a DIB (the system derives CF_DIB).
    try std.testing.expect(win32.user32.IsClipboardFormatAvailable(8) != 0);
    try std.testing.expect(win32.user32.IsClipboardFormatAvailable(17) != 0);
}

test "win32 clipboard: png served from a dib" {
    const alloc = std.testing.allocator;
    const image = @import("clipboard_image.zig");
    const hwnd = try testWindow();
    defer _ = win32.user32.DestroyWindow(hwnd);
    const saved = try SavedClipboard.save(hwnd);
    defer saved.restore(hwnd);

    // A 2x2, 24 bpp, bottom-up BI_RGB DIB: rows padded to 8 bytes.
    var dib: [40 + 16]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], 2, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 24, .little);
    std.mem.writeInt(u32, dib[20..24], 16, .little);
    // Bottom row first, BGR: blue, white; then top row: red, green.
    const rows = [_]u8{ 255, 0, 0, 255, 255, 255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0 };
    @memcpy(dib[40..], &rows);

    var entries = [_]clipboard_formats.Entry{.{ .format = .{ .standard = 8 }, .bytes = &dib }};
    try clipboard_formats.writePlan(hwnd, .{ .entries = &entries, .cleared = false }, false);

    const png = (try readMime(alloc, hwnd, "image/png")).?;
    defer alloc.free(png);
    var got = try image.decode(alloc, "image/png", png);
    defer got.deinit(alloc);
    var want = try image.fromDib(alloc, &dib);
    defer want.deinit(alloc);
    try std.testing.expect(got.eql(want));
    try std.testing.expectEqual(@as(u32, 2), got.width);
    // Top-left pixel is the red one.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, got.pixels[0..4]);
}

const FakeReader = struct {
    reads: *usize,

    fn read(self: FakeReader, alloc: Allocator, mime: []const u8) !?[]u8 {
        self.reads.* += 1;
        if (std.mem.eql(u8, mime, "text/plain")) return try alloc.dupe(u8, "hello");
        if (std.mem.eql(u8, mime, "image/png")) return try alloc.dupe(u8, "PNGDATA");
        if (std.mem.eql(u8, mime, "text/rtf")) return error.ClipboardBusy;
        return null;
    }

    fn list(
        self: FakeReader,
        buf: *[clipboard_formats.max_listing][]const u8,
        names: *clipboard_formats.NameBuf,
    ) ![]const []const u8 {
        _ = self;
        _ = names;
        buf[0] = "text/plain";
        buf[1] = "image/png";
        return buf[0..2];
    }
};

/// What the fake core says to a Kitty read or write.
const FakeKitty = struct {
    /// Whether the first unconfirmed completion asks for a prompt.
    ask: bool,
    answer: Decision = .{ .answer = .no },
    /// A read that found nothing to disclose.
    empty: bool = false,
    fail_confirmed: bool = false,

    /// Core consumed the request with a success.
    completions: usize = 0,
    confirmed: bool = false,
    remember: bool = false,
    asked: usize = 0,
    asked_can_remember: bool = false,
    denied: usize = 0,
    first_confirmed_arg: ?bool = null,
    shown: []const terminal.clipboard.Content = &.{},
    served: []const terminal.clipboard.Content = &.{},

    fn disclosesNothing(self: *const FakeKitty, g: Gathered) bool {
        _ = g;
        return self.empty;
    }

    fn complete(self: *FakeKitty, g: Gathered, confirmed: bool, remember: bool) error{ UnauthorizedPaste, OutOfMemory }!void {
        if (self.first_confirmed_arg == null) self.first_confirmed_arg = confirmed;
        if (self.ask and !confirmed) return error.UnauthorizedPaste;
        if (confirmed and self.fail_confirmed) return error.OutOfMemory;
        self.completions += 1;
        self.confirmed = confirmed;
        self.remember = remember;
        self.served = completeFor(g, confirmed, remember).contents;
    }

    fn confirm(self: *FakeKitty, g: Gathered, can_remember: bool) Decision {
        self.asked += 1;
        self.asked_can_remember = can_remember;
        // Nothing may have been answered before the user did.
        std.debug.assert(self.completions == 0);
        self.shown = g.contents;
        return self.answer;
    }

    fn deny(self: *FakeKitty) void {
        self.denied += 1;
    }
};

test "win32 clipboard kitty: gather reads each representation once" {
    const alloc = std.testing.allocator;
    var reads: usize = 0;

    var kitty: apprt.ClipboardRequest.KittyRead = undefined;
    kitty.mimes = &[_][:0]const u8{ "UTF8_STRING", "image/png", "text/plain", "image/gif", "text/rtf" };
    kitty.list = true;

    var g = try gather(alloc, &kitty, FakeReader{ .reads = &reads });
    defer g.deinit(alloc);

    // The text alias and `text/plain` are one read; gif is absent, rtf
    // failed: both are simply not served.
    try std.testing.expectEqual(@as(usize, 4), reads);
    try std.testing.expectEqual(@as(usize, 2), g.contents.len);
    try std.testing.expectEqualStrings("text/plain", g.contents[0].mime);
    try std.testing.expectEqualStrings("hello", g.contents[0].data);
    try std.testing.expectEqualStrings("image/png", g.contents[1].mime);
    try std.testing.expectEqual(@as(usize, 2), g.available.len);
    try std.testing.expectEqualStrings("image/png", g.available[1]);

    // Without a listing request there is no listing.
    kitty.list = false;
    var plain = try gather(alloc, &kitty, FakeReader{ .reads = &reads });
    defer plain.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), plain.available.len);
}

test "win32 clipboard kitty: gather frees everything when memory runs out" {
    var kitty: apprt.ClipboardRequest.KittyRead = undefined;
    kitty.mimes = &[_][:0]const u8{ "text/plain", "image/png" };
    kitty.list = true;

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var reads: usize = 0;
        if (gather(a, &kitty, FakeReader{ .reads = &reads })) |got| {
            var g = got;
            g.deinit(a);
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "win32 clipboard kitty: read allowed by policy completes once" {
    const alloc = std.testing.allocator;
    var g = try testGathered(alloc);
    defer g.deinit(alloc);
    var fake: FakeKitty = .{ .ask = false };

    try std.testing.expect(runKitty(&fake, g, true));
    try std.testing.expectEqual(@as(usize, 0), fake.asked);
    try std.testing.expectEqual(@as(usize, 1), fake.completions);
    try std.testing.expectEqual(@as(usize, 0), fake.denied);
    try std.testing.expect(!fake.confirmed);
}

test "win32 clipboard kitty: read asks and serves what was shown" {
    const alloc = std.testing.allocator;
    var reads: usize = 0;
    var kitty: apprt.ClipboardRequest.KittyRead = undefined;
    kitty.mimes = &[_][:0]const u8{ "text/plain", "image/png" };
    kitty.list = false;

    var g = try gather(alloc, &kitty, FakeReader{ .reads = &reads });
    defer g.deinit(alloc);
    var fake: FakeKitty = .{ .ask = true, .answer = .{ .answer = .yes, .remember = true } };
    const reads_before = reads;

    try std.testing.expect(runKitty(&fake, g, true));
    try std.testing.expectEqual(@as(usize, 1), fake.asked);
    try std.testing.expect(fake.asked_can_remember);
    try std.testing.expectEqual(@as(usize, 1), fake.completions);
    try std.testing.expect(fake.confirmed);
    try std.testing.expect(fake.remember);
    try std.testing.expectEqual(@as(usize, 0), fake.denied);
    // `runKitty` handed the prompt and the answer the same data, and read
    // nothing again.
    try std.testing.expectEqual(g.contents.ptr, fake.shown.ptr);
    try std.testing.expectEqual(fake.shown.ptr, fake.served.ptr);
    try std.testing.expectEqualStrings("hello", fake.served[0].data);
    try std.testing.expectEqualStrings("PNGDATA", fake.served[1].data);
    try std.testing.expectEqual(reads_before, reads);

    // Without a password nothing is remembered, whatever the prompt said.
    var anon: FakeKitty = .{ .ask = true, .answer = .{ .answer = .yes, .remember = true } };
    try std.testing.expect(runKitty(&anon, .{}, false));
    try std.testing.expect(!anon.asked_can_remember);
    try std.testing.expect(anon.confirmed);
    try std.testing.expect(!anon.remember);
}

test "win32 clipboard kitty: denied read answers EPERM" {
    const alloc = std.testing.allocator;
    var g = try testGathered(alloc);
    defer g.deinit(alloc);
    var fake: FakeKitty = .{ .ask = true, .answer = .{ .answer = .no } };

    try std.testing.expect(runKitty(&fake, g, true));
    try std.testing.expectEqual(@as(usize, 1), fake.asked);
    try std.testing.expectEqual(@as(usize, 1), fake.denied);
    try std.testing.expectEqual(@as(usize, 0), fake.completions);
}

test "win32 clipboard kitty: write asks and remembers only with a password" {
    var allowed: FakeKitty = .{ .ask = true, .answer = .{ .answer = .yes, .remember = true } };
    try std.testing.expect(runKitty(&allowed, .{}, true));
    try std.testing.expectEqual(@as(usize, 1), allowed.completions);
    try std.testing.expect(allowed.confirmed and allowed.remember);
    try std.testing.expect(allowed.asked_can_remember);

    var no_pw: FakeKitty = .{ .ask = true, .answer = .{ .answer = .yes, .remember = true } };
    try std.testing.expect(runKitty(&no_pw, .{}, false));
    try std.testing.expect(no_pw.confirmed and !no_pw.remember);
    try std.testing.expect(!no_pw.asked_can_remember);

    var denied: FakeKitty = .{ .ask = true, .answer = .{ .answer = .no } };
    try std.testing.expect(runKitty(&denied, .{}, true));
    try std.testing.expectEqual(@as(usize, 1), denied.denied);
    try std.testing.expectEqual(@as(usize, 0), denied.completions);
}

test "win32 clipboard kitty: the prompt lists the committed contents of a write" {
    var kitty: apprt.ClipboardRequest.KittyWrite = undefined;
    kitty.contents = &.{
        .{ .mime = "text/plain", .data = "gh-5522" },
        .{ .mime = "image/png", .data = "PNG" },
    };
    const req: apprt.ClipboardRequest = .{ .kitty_write = &kitty };

    try std.testing.expectEqual(@as(usize, 2), partCount(req, .{}));
    var parts: [2]dialogs.ClipboardPart = undefined;
    fillParts(req, .{}, &parts);
    for (kitty.contents, parts) |c, part| {
        try std.testing.expectEqualStrings(c.mime, part.mime);
        try std.testing.expectEqualStrings(c.data, part.data);
    }
}

test "win32 clipboard kitty: the real prompt and the real answer use the gathered data" {
    const alloc = std.testing.allocator;
    var g = try testGathered(alloc);
    defer g.deinit(alloc);

    // What KittyFlow gives the dialog: the gathered bytes, not copies.
    var kitty: apprt.ClipboardRequest.KittyRead = undefined;
    const req: apprt.ClipboardRequest = .{ .kitty_read = &kitty };
    try std.testing.expectEqual(@as(usize, 2), partCount(req, g));
    var parts: [2]dialogs.ClipboardPart = undefined;
    fillParts(req, g, &parts);
    for (g.contents, parts) |c, part| {
        try std.testing.expectEqualStrings(c.mime, part.mime);
        try std.testing.expectEqual(c.data.ptr, part.data.ptr);
    }

    // What KittyFlow gives core: the same slices, with the answer's flags.
    const first = completeFor(g, false, false);
    const second = completeFor(g, true, true);
    for ([_]CoreSurface.CompleteClipboard{ first, second }) |c| {
        try std.testing.expectEqual(g.contents.ptr, c.contents.ptr);
        try std.testing.expectEqual(g.available.ptr, c.available.ptr);
    }
    try std.testing.expect(!first.confirmed and !first.remember);
    try std.testing.expect(second.confirmed and second.remember);
}

test "win32 clipboard kitty: a read with nothing to show does not prompt" {
    var fake: FakeKitty = .{ .ask = true, .empty = true };
    try std.testing.expect(runKitty(&fake, .{}, true));
    try std.testing.expectEqual(@as(?bool, true), fake.first_confirmed_arg);
    try std.testing.expectEqual(@as(usize, 0), fake.asked);
    try std.testing.expectEqual(@as(usize, 1), fake.completions);
}

test "win32 clipboard kitty: surface gone behind the prompt" {
    const alloc = std.testing.allocator;
    var g = try testGathered(alloc);
    defer g.deinit(alloc);
    var fake: FakeKitty = .{ .ask = true, .answer = .{ .answer = .gone } };

    try std.testing.expect(!runKitty(&fake, g, true));
    // Nothing is answered or denied here: `cancelAll` did, once.
    try std.testing.expectEqual(@as(usize, 0), fake.completions);
    try std.testing.expectEqual(@as(usize, 0), fake.denied);
}

test "win32 clipboard kitty: a failed completion is never denied after core consumed it" {
    var fake: FakeKitty = .{ .ask = true, .answer = .{ .answer = .yes }, .fail_confirmed = true };
    try std.testing.expect(runKitty(&fake, .{}, true));
    try std.testing.expectEqual(@as(usize, 0), fake.denied);
    try std.testing.expectEqual(@as(usize, 0), fake.completions);
}

test "win32 clipboard kitty: unsupported location before any prompt" {
    var kw: apprt.ClipboardRequest.KittyWrite = undefined;
    var kr: apprt.ClipboardRequest.KittyRead = undefined;
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unsupported),
        admission(.primary, .{ .kitty_write = &kw }),
    );
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unsupported),
        admission(.primary, .{ .kitty_read = &kr }),
    );
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unsupported),
        admission(.primary, .{ .list = .primary }),
    );
    // The standard clipboard is queued.
    try std.testing.expect(admission(.standard, .{ .kitty_write = &kw }) == null);
    try std.testing.expect(admission(.standard, .{ .kitty_read = &kr }) == null);
    try std.testing.expect(admission(.standard, .{ .list = .standard }) == null);
}

const FakeList = struct {
    fail_listing: bool = false,
    fail_complete: bool = false,
    completed: usize = 0,
    denied: usize = 0,
    seen: usize = 0,

    fn listing(
        self: *FakeList,
        buf: *[clipboard_formats.max_listing][]const u8,
        names: *clipboard_formats.NameBuf,
    ) ![]const []const u8 {
        _ = names;
        if (self.fail_listing) return error.ClipboardBusy;
        buf[0] = "text/plain";
        buf[1] = "image/png";
        return buf[0..2];
    }

    fn complete(self: *FakeList, available: []const []const u8) !void {
        if (self.fail_complete) return error.OutOfMemory;
        self.completed += 1;
        self.seen = available.len;
    }

    fn deny(self: *FakeList) void {
        self.denied += 1;
    }
};

test "win32 clipboard kitty: list never prompts" {
    var ok: FakeList = .{};
    runList(&ok);
    try std.testing.expectEqual(@as(usize, 1), ok.completed);
    try std.testing.expectEqual(@as(usize, 2), ok.seen);
    try std.testing.expectEqual(@as(usize, 0), ok.denied);

    // A failure still ends the request, once.
    var busy: FakeList = .{ .fail_listing = true };
    runList(&busy);
    try std.testing.expectEqual(@as(usize, 0), busy.completed);
    try std.testing.expectEqual(@as(usize, 1), busy.denied);

    var lost: FakeList = .{ .fail_complete = true };
    runList(&lost);
    try std.testing.expectEqual(@as(usize, 1), lost.denied);
}

test "win32 clipboard: selection is supported, primary is not" {
    try std.testing.expect(supports(.standard));
    try std.testing.expect(supports(.selection));
    try std.testing.expect(!supports(.primary));
}

test "win32 clipboard: empty selection paste is unavailable" {
    var store: selection_store.Store = .{};
    defer store.deinit();

    // Nothing stored: a middle click falls through.
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unavailable),
        preflight(&store, .selection, .{ .paste = .selection }),
    );

    // A store without text is as good as empty for a paste.
    try store.set(std.testing.allocator, &.{.{ .mime = "image/png", .data = "PNG" }});
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unavailable),
        preflight(&store, .selection, .{ .paste = .selection }),
    );

    // With text the request is queued; so is an OSC 52 read (answered with
    // empty contents when there is nothing).
    try store.set(std.testing.allocator, &.{.{ .mime = "text/plain", .data = "word" }});
    try std.testing.expect(preflight(&store, .selection, .{ .paste = .selection }) == null);
    store.clear();
    try std.testing.expect(preflight(&store, .selection, .{ .osc_52_read = .selection }) == null);

    // The X11 primary selection never exists.
    try std.testing.expectEqual(
        @as(?apprt.ClipboardReadResult, .unsupported),
        preflight(&store, .primary, .{ .paste = .primary }),
    );
}

test "win32 clipboard: the selection serves paste text, a Kitty read and a listing" {
    const alloc = std.testing.allocator;
    var store: selection_store.Store = .{};
    defer store.deinit();
    try std.testing.expect((try readSelection(alloc, &store)) == null);

    try store.set(alloc, &.{
        .{ .mime = "text/plain", .data = "a\xffb\x00tail" },
        .{ .mime = "text/html", .data = "<b>a</b>" },
    });
    const text = (try readSelection(alloc, &store)).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a\u{FFFD}b", text);

    var kitty: apprt.ClipboardRequest.KittyRead = undefined;
    kitty.mimes = &[_][:0]const u8{ "UTF8_STRING", "text/html", "image/png" };
    kitty.list = true;
    var g = try gather(alloc, &kitty, StoreReader{ .store = &store });
    defer g.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), g.contents.len);
    try std.testing.expectEqualStrings("text/plain", g.contents[0].mime);
    try std.testing.expectEqualStrings("<b>a</b>", g.contents[1].data);
    try std.testing.expectEqual(@as(usize, 2), g.available.len);
    try std.testing.expectEqualStrings("text/plain", g.available[0]);
    try std.testing.expectEqualStrings("text/html", g.available[1]);
}

test {
    _ = selection_store;
    _ = @import("clipboard_formats.zig");
    _ = @import("clipboard_html.zig");
    _ = @import("clipboard_image.zig");
    _ = @import("clipboard_mime.zig");
}
