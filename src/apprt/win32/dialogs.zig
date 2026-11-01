//! Modal confirmation dialogs in the Windows 11 style (a WinUI
//! `ContentDialog`, see `dialog/Dialog.zig`); a plain message box when the
//! dialog cannot be built.
//!
//! A dialog runs its own message loop, so anything that shows one can see
//! its window, and the surface behind it, destroyed before the call
//! returns, and posted messages (IPC ops included) run re-entrantly inside
//! it. Dialogs are therefore shown only from posted-message handlers, never
//! from `performAction`, core callbacks or IPC op handlers, and every call
//! site checks that its window survived. See `clipboard.zig` for how that
//! is handled for clipboard prompts.
//!
//! Everything shown is made safe first (`dialog/text.zig`): control and
//! bidi characters are written out, never drawn or obeyed, and a body too
//! tall for the screen scrolls instead of being cut.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const Dialog = @import("dialog/Dialog.zig");
const dtext = @import("dialog/text.zig");
const dlayout = @import("dialog/layout.zig");
const clipboard_image = @import("clipboard_image.zig");

const IDYES = 6;
const MB_DEFBUTTON2 = 0x00000100;

/// Id of the affirmative custom button ("&Close", "Allow"). "Allow" has no
/// mnemonic: the question appears asynchronously, and a user who keeps
/// typing must not accept it by accident.
const button_accept = 100;

/// Id of the cancelling button, and the answer of Esc and the close button.
const button_cancel = Dialog.cancel_id;

const log = std.log.scoped(.win32_dialogs);

const w16 = std.unicode.utf8ToUtf16LeStringLiteral;

/// What a close would take down. Decides the sentence of the confirmation.
pub const CloseKind = enum { surface, tab, window, all_windows, app };

/// Ask whether `kind` may be closed while a process is still running in it.
pub fn confirmCloseKind(owner: win32.foundation.HWND, kind: CloseKind) bool {
    const buttons = [_]ListButton{
        .{ .id = button_accept, .text = "&Close" },
        .{ .id = button_cancel, .text = "Cancel" },
    };
    const answer = show(
        owner,
        "Ghostty",
        closeInstruction(kind),
        "A process is still running. Closing will end it.",
        "",
        &buttons,
        button_cancel,
    ) orelse return fallbackBox(owner, closeTitle(kind), closeBody(kind));
    return answer == button_accept;
}

fn closeInstruction(kind: CloseKind) []const u8 {
    return switch (kind) {
        .surface => "Close this terminal?",
        .tab => "Close this tab?",
        .window => "Close this window?",
        .all_windows => "Close all windows?",
        .app => "Quit Ghostty?",
    };
}

fn closeTitle(kind: CloseKind) []const u8 {
    return switch (kind) {
        .surface => "Close Terminal",
        .tab => "Close Tab",
        .window => "Close Window",
        .all_windows => "Close All Windows",
        .app => "Quit Ghostty",
    };
}

fn closeBody(kind: CloseKind) []const u8 {
    return switch (kind) {
        .surface => "A process is still running in this terminal. Close it anyway?",
        .tab => "A process is still running in this tab. Close it anyway?",
        .window => "A process is still running in this window. Close it anyway?",
        .all_windows => "Processes are still running in your windows. Close them all anyway?",
        .app => "Processes are still running. Quit Ghostty anyway?",
    };
}

const confirm_buttons = [_]ListButton{
    .{ .id = button_accept, .text = "Allow" },
    .{ .id = button_cancel, .text = "Cancel" },
};

/// Show a question on top of `owner`. True for "Allow". "Cancel" is the
/// default button: every question asked here is about something that is
/// hard to undo. The text is shown in full (it scrolls when it is long);
/// control and bidi characters in it are written out, and invalid UTF-8
/// shows as U+FFFD.
pub fn confirm(
    owner: win32.foundation.HWND,
    title: []const u8,
    body: []const u8,
) bool {
    const answer = show(owner, title, title, body, "", &confirm_buttons, button_cancel) orelse
        return fallbackBox(owner, title, body);
    return answer == button_accept;
}

/// Set by `taskDialogIcon` for the next `show` (UI thread, dialogs are modal).
var take_icon: bool = false;

/// `taskDialogList` with the app icon above the text.
pub fn taskDialogIcon(
    owner: ?win32.foundation.HWND,
    title: []const u8,
    instruction: []const u8,
    body: []const u8,
    buttons: []const ListButton,
    default_id: i32,
) ?i32 {
    take_icon = true;
    defer take_icon = false;
    return taskDialogList(owner, title, instruction, body, buttons, default_id);
}

/// One button of `taskDialogList`.
pub const ListButton = struct {
    id: i32,
    text: []const u8,
};

const list_buttons_max = 4;

/// A dialog with a headline (`instruction`), a paragraph and a scrollable
/// list of lines in a code font (`body`: everything up to the first blank
/// line is the paragraph, the rest is the list; with no blank line it is
/// all list) and custom buttons. The id of the pressed button; `2` when it
/// was dismissed; null when the dialog could not be shown (the body is
/// then shown in a plain message box). Text that does not fit the fixed
/// buffers is cut.
pub fn taskDialogList(
    owner: ?win32.foundation.HWND,
    title: []const u8,
    instruction: []const u8,
    body: []const u8,
    buttons: []const ListButton,
    default_id: i32,
) ?i32 {
    const split = std.mem.indexOf(u8, body, "\n\n");
    const intro = if (split) |at| body[0..at] else "";
    const lines = if (split) |at| body[at + 2 ..] else body;
    if (show(owner, title, instruction, intro, lines, buttons, default_id)) |id| return id;

    var box_title: [128]u16 = undefined;
    var box_body: [16384]u16 = undefined;
    _ = win32.user32.MessageBoxW(
        owner,
        dtext.toWideFit(&box_body, body, .paragraphs),
        dtext.toWide(&box_title, title, .single_line),
        win32.user32.MB_OK | win32.user32.MB_ICONWARNING,
    );
    return null;
}

/// Builds the wide text and runs the dialog. Null when it could not be
/// shown.
fn show(
    owner: ?win32.foundation.HWND,
    window_title: []const u8,
    title: []const u8,
    body: []const u8,
    list: []const u8,
    buttons: []const ListButton,
    default_id: i32,
) ?i32 {
    return showWith(owner, window_title, title, body, list, buttons, default_id, null, null);
}

/// `show` with a preview image and a switch (see `Dialog.Spec`).
fn showWith(
    owner: ?win32.foundation.HWND,
    window_title: []const u8,
    title: []const u8,
    body: []const u8,
    list: []const u8,
    buttons: []const ListButton,
    default_id: i32,
    image: ?Dialog.Image,
    check: ?Dialog.Check,
) ?i32 {
    var window_buf: [128]u16 = undefined;
    var title_buf: [256]u16 = undefined;
    var body_buf: [8192]u16 = undefined;
    var list_buf: [16384]u16 = undefined;
    var label_bufs: [list_buttons_max][64]u16 = undefined;
    var wide_buttons: [list_buttons_max]Dialog.Button = undefined;

    const count = @min(buttons.len, list_buttons_max);
    var default_index: usize = 0;
    for (buttons[0..count], 0..) |b, i| {
        wide_buttons[i] = .{ .id = b.id, .text = dtext.toWide(&label_bufs[i], b.text, .single_line) };
        if (b.id == default_id) default_index = i;
    }

    return Dialog.run(.{
        .owner = owner,
        .window_title = dtext.toWide(&window_buf, window_title, .single_line),
        .title = dtext.toWide(&title_buf, title, .single_line),
        .body = dtext.toWideFit(&body_buf, body, .paragraphs),
        .list = dtext.toWideFit(&list_buf, list, .paragraphs),
        .buttons = wide_buttons[0..count],
        .default_index = default_index,
        .icon = take_icon,
        .image = image,
        .check = check,
    });
}

/// A one-button information dialog. Like every dialog here it runs a message
/// loop: only from posted-message handlers.
pub fn inform(
    owner: win32.foundation.HWND,
    window_title: []const u8,
    title: []const u8,
    body: []const u8,
) void {
    const buttons = [_]ListButton{.{ .id = button_accept, .text = "OK" }};
    if (show(owner, window_title, title, body, "", &buttons, button_accept) == null) {
        log.warn("the dialog could not be built, using a message box", .{});
        var title_buf: [128]u16 = undefined;
        var body_buf: [2048]u16 = undefined;
        _ = win32.user32.MessageBoxW(
            owner,
            dtext.toWideFit(&body_buf, body, .paragraphs),
            dtext.toWide(&title_buf, window_title, .single_line),
            0,
        );
    }
}

/// The M1 message box, for when the dialog cannot be built.
fn fallbackBox(owner: ?win32.foundation.HWND, title: []const u8, body: []const u8) bool {
    log.warn("the dialog could not be built, using a message box", .{});
    var title_buf: [128]u16 = undefined;
    var body_buf: [2048]u16 = undefined;
    const result = win32.user32.MessageBoxW(
        owner,
        dtext.toWideFit(&body_buf, body, .paragraphs),
        dtext.toWide(&title_buf, title, .single_line),
        win32.user32.MB_YESNO | win32.user32.MB_ICONQUESTION | MB_DEFBUTTON2,
    );
    return result == IDYES;
}

/// Which clipboard prompt this is. Decides the title, the sentence and the
/// button labels.
pub const ClipboardKind = enum { paste, read, write };

/// One representation of the clipboard that the prompt is about.
pub const ClipboardPart = struct {
    mime: []const u8,
    data: []const u8,
};

pub const ClipboardAnswer = struct {
    allow: bool,
    /// The "remember" switch was on when the dialog was accepted. Always
    /// false for a denial (a refusal is never remembered, as on macOS), when
    /// the prompt had no switch, and for the message box fallback.
    remember: bool,
};

const remember_label = w16("Remember this choice for the session");

/// Characters of a MIME type, and of the text, the clipboard prompt shows.
const clipboard_mime_chars = 64;
const clipboard_text_chars = 512;

/// Everything a clipboard prompt shows, as UTF-8 (the dialog widens it).
const ClipboardPrompt = struct {
    title: []const u8,
    /// The macOS sentence (`ClipboardRequest.text()`).
    body: []const u8,
    /// One line per part, a blank line, the first text.
    list: []const u8,
    allow: []const u8,
    deny: []const u8,
    /// The first image that decodes, scaled down to fit.
    image: ?clipboard_image.Bgra,

    fn deinit(self: *ClipboardPrompt, alloc: Allocator) void {
        alloc.free(self.list);
        if (self.image) |*i| i.deinit(alloc);
        self.* = undefined;
    }
};

fn clipboardTitle(kind: ClipboardKind) []const u8 {
    return switch (kind) {
        .read => "Clipboard Read",
        .write => "Clipboard Write",
        .paste => "Confirm Paste",
    };
}

/// `ClipboardRequest.text()` of macOS. The program's own name for the
/// request (the kitty protocol has one) is not shown: it is controlled by the
/// program and would let it put its own words in this prompt.
fn clipboardBody(kind: ClipboardKind) []const u8 {
    return switch (kind) {
        .paste => "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed.",
        .read => "An application is attempting to read from the clipboard.\nThe current clipboard contents are shown below.",
        .write => "An application is attempting to write to the clipboard.\nThe content to write is shown below.",
    };
}

/// The type of `mime` without parameters, trimmed.
fn mimeBase(mime: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    return std.mem.trim(u8, mime[0..semi], " \t");
}

/// Whether the whole type of `mime` is `full` (ignoring case and parameters).
fn mimeIs(mime: []const u8, full: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mimeBase(mime), full);
}

fn mimeIsImage(mime: []const u8) bool {
    const base = mimeBase(mime);
    return base.len > "image/".len and std.ascii.eqlIgnoreCase(base[0.."image/".len], "image/");
}

/// "7 bytes", "1.2 KB", "3.4 MB": binary units, one decimal.
fn sizeText(buf: []u8, n: usize) []const u8 {
    if (n == 1) return "1 byte";
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} bytes", .{n}) catch "?";
    const units = [_][]const u8{ "KB", "MB", "GB" };
    var unit: usize = 1024;
    for (units, 0..) |name, i| {
        // Tenths of the unit, rounded; 1024.0 KB is 1.0 MB.
        const tenths = (@as(u128, n) * 10 + unit / 2) / unit;
        if (tenths < 10240 or i == units.len - 1) {
            return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ tenths / 10, tenths % 10, name }) catch "?";
        }
        unit *= 1024;
    }
    unreachable;
}

/// Builds what `confirmClipboard` shows. `max_w` and `max_h` (px) bound the
/// picture.
fn buildClipboardPrompt(
    alloc: Allocator,
    kind: ClipboardKind,
    parts: []const ClipboardPart,
    max_w: u32,
    max_h: u32,
) Allocator.Error!ClipboardPrompt {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    // The first image that decodes is previewed; no other part is.
    var image: ?clipboard_image.Bgra = null;
    errdefer if (image) |*i| i.deinit(alloc);
    var image_part: ?usize = null;
    for (parts, 0..) |part, i| {
        if (!mimeIsImage(part.mime)) continue;
        var rgba = clipboard_image.decode(alloc, part.mime, part.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer rgba.deinit(alloc);
        image = clipboard_image.preview(alloc, rgba, max_w, max_h) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        image_part = i;
        break;
    }

    for (parts, 0..) |part, i| {
        if (i > 0) try list.append(alloc, '\n');
        const mime = try escapeDeceptive(alloc, part.mime, .link, clipboard_mime_chars);
        defer alloc.free(mime);
        var size_buf: [32]u8 = undefined;
        try list.appendSlice(alloc, mime);
        try list.appendSlice(alloc, " \u{2014} ");
        try list.appendSlice(alloc, sizeText(&size_buf, part.data.len));
        if (mimeIsImage(part.mime) and image_part != i) try list.appendSlice(alloc, " (no preview)");
    }

    // The first text: text/plain, else any part that is valid UTF-8.
    var text: ?[]const u8 = null;
    for (parts) |part| {
        if (mimeIs(part.mime, "text/plain") and part.data.len > 0) {
            text = part.data;
            break;
        }
    }
    if (text == null) for (parts) |part| {
        if (mimeIsImage(part.mime)) continue;
        if (part.data.len > 0 and std.unicode.utf8ValidateSlice(part.data)) {
            text = part.data;
            break;
        }
    };
    if (text) |t| if (t.len > 0) {
        // Enough bytes for the characters shown, however they are escaped.
        const shown = try escapeDeceptive(alloc, t[0..@min(t.len, 4096)], .paste, clipboard_text_chars);
        defer alloc.free(shown);
        try list.appendSlice(alloc, if (list.items.len > 0) "\n\n" else "");
        try list.appendSlice(alloc, shown);
    };

    return .{
        .title = clipboardTitle(kind),
        .body = clipboardBody(kind),
        .list = try list.toOwnedSlice(alloc),
        .allow = if (kind == .paste) "Paste" else "Allow",
        .deny = if (kind == .paste) "Cancel" else "Deny",
        .image = image,
    };
}

/// Ask whether the program may use the clipboard (`read`, `write`) or paste
/// `parts`. The prompt lists every part with its size, previews the first
/// image that decodes and the first text (hidden characters written out), and
/// can offer to remember the answer for the session. Deny (Cancel) is the
/// default button. Like every dialog here it runs a message loop: only from
/// posted-message handlers.
pub fn confirmClipboard(
    owner: ?win32.foundation.HWND,
    kind: ClipboardKind,
    parts: []const ClipboardPart,
    can_remember: bool,
) ClipboardAnswer {
    const deny: ClipboardAnswer = .{ .allow = false, .remember = false };
    const alloc = std.heap.page_allocator;

    // The picture is scaled for the owner's DPI to the room it gets.
    const dpi: u32 = if (owner) |o| ownerDpi(o) else 96;
    const content_dip = dlayout.max_w - 2 * dlayout.pad;
    var prompt = buildClipboardPrompt(
        alloc,
        kind,
        parts,
        @intCast(@divFloor(content_dip * @as(i32, @intCast(dpi)), 96)),
        @intCast(@divFloor(dlayout.image_max_h * @as(i32, @intCast(dpi)), 96)),
    ) catch return deny;
    defer prompt.deinit(alloc);

    const buttons = [_]ListButton{
        .{ .id = button_accept, .text = prompt.allow },
        .{ .id = button_cancel, .text = prompt.deny },
    };

    var remember = false;
    const image: ?Dialog.Image = if (prompt.image) |img|
        .{ .width = img.width, .height = img.height, .bgra = img.pixels }
    else
        null;
    const check: ?Dialog.Check = if (can_remember) .{ .label = remember_label, .state = &remember } else null;

    const answer = showWith(
        owner,
        prompt.title,
        prompt.title,
        prompt.body,
        prompt.list,
        &buttons,
        button_cancel,
        image,
        check,
    ) orelse {
        // No dialog: the message box shows the same words; it has no switch.
        const text = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ prompt.body, prompt.list }) catch return deny;
        defer alloc.free(text);
        return .{ .allow = fallbackBox(owner, prompt.title, text), .remember = false };
    };
    return clipboardAnswer(answer, can_remember, remember);
}

/// What the pressed button and the switch mean. Only an acceptance can be
/// remembered: a ticked switch on Deny, Esc or close must not turn into a
/// session-long grant.
fn clipboardAnswer(pressed: i32, can_remember: bool, ticked: bool) ClipboardAnswer {
    const allow = pressed == button_accept;
    return .{ .allow = allow, .remember = allow and can_remember and ticked };
}

fn ownerDpi(owner: win32.foundation.HWND) u32 {
    const dpi = win32.user32.GetDpiForWindow(owner);
    return if (dpi != 0) dpi else 96;
}

/// A single-line, display-safe rendition of `text` for confirmation
/// prompts: control characters (newlines included) become their visible
/// symbols from the U+2400 block, and anything past `max_chars`
/// codepoints is replaced by one "…". Caller owns the result.
pub fn previewText(alloc: Allocator, text: []const u8, max_chars: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        if (count == max_chars) {
            try appendCodepoint(alloc, &out, 0x2026);
            break;
        }

        var cp = dtext.nextCodepoint(text, &i);
        if (cp < 0x20) {
            cp += dtext.control_pictures;
        } else if (cp == 0x7F) {
            cp = dtext.control_pictures + 0x21;
        }
        try appendCodepoint(alloc, &out, cp);
        count += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Which prompt the text is for. `.link` also counts U+200D (zero width
/// joiner) as deceptive: a link has no use for it, while a pasted emoji
/// sequence does.
pub const DeceptiveSet = enum { paste, link };

/// Whether `cp` hides text or changes its apparent order: C1 controls,
/// U+061C, U+200B/200C, U+200E/200F, U+2028..202E, U+2060, U+2066..2069 and
/// U+FEFF (macOS `UntrustedURL.isUnsafeCharacter`); `.link` adds U+200D.
/// C0 and DEL are not listed: `previewText` draws them as symbols.
pub fn isDeceptive(cp: u21, set: DeceptiveSet) bool {
    return switch (cp) {
        0x0080...0x009F,
        0x061C,
        0x200B,
        0x200C,
        0x200E,
        0x200F,
        0x2028...0x202E,
        0x2060,
        0x2066...0x2069,
        0xFEFF,
        => true,
        0x200D => set == .link,
        else => false,
    };
}

/// `text` with every deceptive codepoint written out as `<U+XXXX>`, then
/// `previewText` (control symbols, at most `max_chars` characters of the
/// escaped text). Caller owns the result.
pub fn escapeDeceptive(alloc: Allocator, text: []const u8, set: DeceptiveSet, max_chars: usize) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const cp = dtext.nextCodepoint(text, &i);
        if (isDeceptive(cp, set)) {
            var buf: [16]u8 = undefined;
            const tag = std.fmt.bufPrint(&buf, "<U+{X:0>4}>", .{cp}) catch unreachable;
            try escaped.appendSlice(alloc, tag);
        } else {
            try appendCodepoint(alloc, &escaped, cp);
        }
    }
    return previewText(alloc, escaped.items, max_chars);
}

fn appendCodepoint(alloc: Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(alloc, buf[0..n]);
}

const comctl32 = win32.comctl32;

test "win32 dialogs: preview escapes control characters and truncates" {
    const alloc = std.testing.allocator;

    // Newline, tab, CR, ESC and DEL all become visible symbols.
    {
        const out = try previewText(alloc, "a\nb\tc\r\x1b[0m\x7f", 512);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("a\u{240A}b\u{2409}c\u{240D}\u{241B}[0m\u{2421}", out);
    }

    // Truncation counts codepoints, not bytes, and appends one ellipsis.
    {
        const out = try previewText(alloc, "ЖЖЖЖЖЖЖЖЖЖ", 4);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("ЖЖЖЖ…", out);
    }

    // Text of exactly the limit is not truncated.
    {
        const out = try previewText(alloc, "😀😀😀", 3);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("😀😀😀", out);
    }

    // The documented 512 character limit.
    {
        const long = try alloc.alloc(u8, 600);
        defer alloc.free(long);
        @memset(long, 'x');
        const out = try previewText(alloc, long, 512);
        defer alloc.free(out);
        try std.testing.expectEqual(@as(usize, 512 + "…".len), out.len);
        try std.testing.expect(std.mem.endsWith(u8, out, "…"));
    }

    // Invalid UTF-8 and the empty string are fine.
    {
        const out = try previewText(alloc, "a\xffb", 512);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("a\u{FFFD}b", out);

        const empty = try previewText(alloc, "", 512);
        defer alloc.free(empty);
        try std.testing.expectEqualStrings("", empty);
    }
}

test "win32 dialogs: deceptive codepoints" {
    const listed = [_]u21{
        0x80,   0x85,   0x9F,   0x061C, 0x200B, 0x200C, 0x200E, 0x200F,
        0x2028, 0x2029, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    };
    for (listed) |cp| {
        try std.testing.expect(isDeceptive(cp, .link));
        try std.testing.expect(isDeceptive(cp, .paste));
    }
    // Text people write, and the neighbours of the ranges.
    for ([_]u21{ 'a', ' ', 0xA0, 0xE9, 0x416, 0x1F600, 0x061B, 0x200A, 0x2010, 0x2027, 0x202F, 0x205F, 0x2065, 0x206A, 0xFEFE }) |cp| {
        try std.testing.expect(!isDeceptive(cp, .link));
        try std.testing.expect(!isDeceptive(cp, .paste));
    }
    // The joiner only matters in a link.
    try std.testing.expect(isDeceptive(0x200D, .link));
    try std.testing.expect(!isDeceptive(0x200D, .paste));
}

test "win32 dialogs: escapeDeceptive shows hidden characters" {
    const alloc = std.testing.allocator;

    const out = try escapeDeceptive(alloc, "a\u{202E}b\u{200B}c\u{85}\n", .link, 512);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a<U+202E>b<U+200B>c<U+0085>\u{240A}", out);

    // The set matters, plain text and invalid UTF-8 pass through previewText.
    const joiner = try escapeDeceptive(alloc, "a\u{200D}b\xff", .paste, 512);
    defer alloc.free(joiner);
    try std.testing.expectEqualStrings("a\u{200D}b\u{FFFD}", joiner);
    const tagged = try escapeDeceptive(alloc, "a\u{200D}b", .link, 512);
    defer alloc.free(tagged);
    try std.testing.expectEqualStrings("a<U+200D>b", tagged);

    // The limit counts the escaped text.
    const cut = try escapeDeceptive(alloc, "\u{202E}\u{202E}", .link, 10);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("<U+202E><U…", cut);
}

fn testPng(alloc: Allocator) ![]u8 {
    var pixels: [8 * 8 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i *% 37);
    const img: clipboard_image.Rgba = .{ .width = 8, .height = 8, .pixels = &pixels };
    return clipboard_image.encodePng(alloc, img);
}

test "win32 dialogs: only an acceptance is remembered" {
    try std.testing.expectEqual(ClipboardAnswer{ .allow = true, .remember = true }, clipboardAnswer(button_accept, true, true));
    try std.testing.expectEqual(ClipboardAnswer{ .allow = true, .remember = false }, clipboardAnswer(button_accept, true, false));
    try std.testing.expectEqual(ClipboardAnswer{ .allow = true, .remember = false }, clipboardAnswer(button_accept, false, true));
    // Deny, Esc and the close button with the switch ticked.
    try std.testing.expectEqual(ClipboardAnswer{ .allow = false, .remember = false }, clipboardAnswer(button_cancel, true, true));
    try std.testing.expectEqual(ClipboardAnswer{ .allow = false, .remember = false }, clipboardAnswer(Dialog.cancel_id, true, true));
}

test "win32 dialogs: mime matching" {
    try std.testing.expect(mimeIs("text/plain", "text/plain"));
    try std.testing.expect(mimeIs(" Text/Plain ; charset=utf-8", "text/plain"));
    try std.testing.expect(!mimeIs("text/plainx", "text/plain"));
    try std.testing.expect(!mimeIs("text/plain-evil", "text/plain"));
    try std.testing.expect(mimeIsImage("image/png"));
    try std.testing.expect(mimeIsImage("IMAGE/svg+xml; x=y"));
    try std.testing.expect(!mimeIsImage("image/"));
    try std.testing.expect(!mimeIsImage("imagex/png"));
}

test "win32 dialogs: an empty text/plain does not hide the next text" {
    const alloc = std.testing.allocator;
    const parts = [_]ClipboardPart{
        .{ .mime = "text/plain", .data = "" },
        .{ .mime = "text/html", .data = "<i>x</i>" },
    };
    var prompt = try buildClipboardPrompt(alloc, .read, &parts, 500, 200);
    defer prompt.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, prompt.list, "\n\n<i>x</i>"));
}

test "win32 dialogs: size text" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 bytes", sizeText(&buf, 0));
    try std.testing.expectEqualStrings("1 byte", sizeText(&buf, 1));
    try std.testing.expectEqualStrings("7 bytes", sizeText(&buf, 7));
    try std.testing.expectEqualStrings("1023 bytes", sizeText(&buf, 1023));
    try std.testing.expectEqualStrings("1.0 KB", sizeText(&buf, 1024));
    try std.testing.expectEqualStrings("1.2 KB", sizeText(&buf, 1229));
    try std.testing.expectEqualStrings("1.0 MB", sizeText(&buf, 1024 * 1024 - 1));
    try std.testing.expectEqualStrings("2.5 MB", sizeText(&buf, 5 * 512 * 1024));
    try std.testing.expectEqualStrings("3.0 GB", sizeText(&buf, 3 * 1024 * 1024 * 1024));
}

test "win32 dialogs: clipboard prompt text" {
    const alloc = std.testing.allocator;
    const png = try testPng(alloc);
    defer alloc.free(png);

    const parts = [_]ClipboardPart{
        .{ .mime = "text/plain", .data = "rm -rf\n" },
        .{ .mime = "image/png", .data = png },
    };
    var size_buf: [32]u8 = undefined;
    const png_line = try std.fmt.allocPrint(alloc, "image/png \u{2014} {s}", .{sizeText(&size_buf, png.len)});
    defer alloc.free(png_line);
    const expect_list = try std.fmt.allocPrint(alloc, "text/plain \u{2014} 7 bytes\n{s}\n\nrm -rf\u{240A}", .{png_line});
    defer alloc.free(expect_list);

    var read = try buildClipboardPrompt(alloc, .read, &parts, 500, 200);
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings(expect_list, read.list);
    try std.testing.expectEqualStrings("Clipboard Read", read.title);
    try std.testing.expectEqualStrings("Allow", read.allow);
    try std.testing.expectEqualStrings("Deny", read.deny);
    try std.testing.expect(std.mem.startsWith(u8, read.body, "An application is attempting to read from the clipboard."));
    // The png decoded, and 8 x 8 stays 8 x 8.
    try std.testing.expect(read.image != null);
    try std.testing.expectEqual(@as(u32, 8), read.image.?.width);

    var write = try buildClipboardPrompt(alloc, .write, &parts, 500, 200);
    defer write.deinit(alloc);
    try std.testing.expectEqualStrings("Clipboard Write", write.title);
    try std.testing.expectEqualStrings("Allow", write.allow);
    try std.testing.expectEqualStrings("Deny", write.deny);
    try std.testing.expect(std.mem.startsWith(u8, write.body, "An application is attempting to write to the clipboard."));

    var paste = try buildClipboardPrompt(alloc, .paste, parts[0..1], 500, 200);
    defer paste.deinit(alloc);
    try std.testing.expectEqualStrings("Confirm Paste", paste.title);
    try std.testing.expectEqualStrings("Paste", paste.allow);
    try std.testing.expectEqualStrings("Cancel", paste.deny);
    try std.testing.expect(std.mem.startsWith(u8, paste.body, "Pasting this text to the terminal may be dangerous"));
    try std.testing.expect(paste.image == null);
    try std.testing.expectEqualStrings("text/plain \u{2014} 7 bytes\n\nrm -rf\u{240A}", paste.list);

    // A 300 byte MIME type from the program is cut at 64 characters.
    const long_mime: [300]u8 = @splat('a');
    const a64: [64]u8 = @splat('a');
    const long = [_]ClipboardPart{.{ .mime = &long_mime, .data = "x" }};
    var cut = try buildClipboardPrompt(alloc, .read, &long, 500, 200);
    defer cut.deinit(alloc);
    const dash = std.mem.indexOf(u8, cut.list, " \u{2014} ").?;
    try std.testing.expectEqualStrings(a64 ++ "\u{2026}", cut.list[0..dash]);

    // The program's name for the request has no way in: the API has no
    // parameter for it, and nothing but the macOS sentences is fixed text.
    for ([_]ClipboardKind{ .paste, .read, .write }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, clipboardBody(k), "name") == null);
        try std.testing.expect(std.mem.indexOf(u8, clipboardTitle(k), "name") == null);
    }
}

test "win32 dialogs: unpreviewable image" {
    const alloc = std.testing.allocator;
    const parts = [_]ClipboardPart{.{ .mime = "image/png", .data = "bad" }};
    var prompt = try buildClipboardPrompt(alloc, .read, &parts, 500, 200);
    defer prompt.deinit(alloc);
    try std.testing.expect(prompt.image == null);
    try std.testing.expectEqualStrings("image/png \u{2014} 3 bytes (no preview)", prompt.list);

    // A second image is listed but not previewed.
    const png = try testPng(alloc);
    defer alloc.free(png);
    const two = [_]ClipboardPart{
        .{ .mime = "image/png", .data = "bad" },
        .{ .mime = "image/png", .data = png },
        .{ .mime = "image/jpeg", .data = png },
    };
    var second = try buildClipboardPrompt(alloc, .read, &two, 500, 200);
    defer second.deinit(alloc);
    try std.testing.expect(second.image != null);
    var lines = std.mem.splitScalar(u8, second.list, '\n');
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "(no preview)"));
    try std.testing.expect(!std.mem.endsWith(u8, lines.next().?, "(no preview)"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "(no preview)"));
}

test "win32 dialogs: hidden characters in the preview" {
    const alloc = std.testing.allocator;
    const parts = [_]ClipboardPart{.{ .mime = "text/plain", .data = "a\u{202E}b" }};
    var prompt = try buildClipboardPrompt(alloc, .paste, &parts, 500, 200);
    defer prompt.deinit(alloc);
    try std.testing.expectEqualStrings("text/plain \u{2014} 5 bytes\n\na<U+202E>b", prompt.list);

    // A MIME type with a bidi override cannot reorder its line either.
    const evil = [_]ClipboardPart{.{ .mime = "text/\u{202E}plain", .data = "x" }};
    var named = try buildClipboardPrompt(alloc, .read, &evil, 500, 200);
    defer named.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, named.list, "\u{202E}") == null);
    try std.testing.expect(std.mem.indexOf(u8, named.list, "<U+202E>") != null);
}

test "win32 dialogs: the text of a part that is not text/plain" {
    const alloc = std.testing.allocator;
    // Valid UTF-8 in another type is the text; bytes that are not are not.
    const html = [_]ClipboardPart{
        .{ .mime = "application/octet-stream", .data = "\xff\xfe" },
        .{ .mime = "text/html", .data = "<b>hi</b>" },
    };
    var prompt = try buildClipboardPrompt(alloc, .read, &html, 500, 200);
    defer prompt.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, prompt.list, "\n\n<b>hi</b>"));
    // No parts: an empty list.
    var none = try buildClipboardPrompt(alloc, .read, &.{}, 500, 200);
    defer none.deinit(alloc);
    try std.testing.expectEqualStrings("", none.list);
    // The text shown is cut at 512 characters.
    const big: [5000]u8 = @splat('y');
    const y512: [512]u8 = @splat('y');
    const parts = [_]ClipboardPart{.{ .mime = "text/plain", .data = &big }};
    var cut = try buildClipboardPrompt(alloc, .paste, &parts, 500, 200);
    defer cut.deinit(alloc);
    const at = std.mem.indexOf(u8, cut.list, "\n\n").? + 2;
    try std.testing.expectEqualStrings(y512 ++ "\u{2026}", cut.list[at..]);
}

test "win32 dialogs: every close kind has its own sentence" {
    const kinds = std.enums.values(CloseKind);
    for (kinds, 0..) |a, i| {
        try std.testing.expect(closeTitle(a).len > 0);
        for (kinds[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, closeBody(a), closeBody(b)));
        }
    }
    // The surface wording keeps the M1 text.
    try std.testing.expectEqualStrings("Close Terminal", closeTitle(.surface));
}

test "win32 dialogs: every close kind asks its own question" {
    const kinds = std.enums.values(CloseKind);
    for (kinds, 0..) |a, i| {
        try std.testing.expect(closeInstruction(a).len > 0);
        for (kinds[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, closeInstruction(a), closeInstruction(b)));
        }
    }
    try std.testing.expectEqualStrings("Quit Ghostty?", closeInstruction(.app));
}

test {
    _ = @import("dialog/colors.zig");
    _ = @import("dialog/extras.zig");
    _ = @import("dialog/keys.zig");
    _ = @import("dialog/layout.zig");
    _ = @import("dialog/text.zig");
    _ = Dialog;
}

// Sizes from a throwaway `zig cc -target x86_64-windows-msvc` program against
// the SDK headers (commctrl.h): sizeof(TASKDIALOGCONFIG) == 160,
// sizeof(TASKDIALOG_BUTTON) == 12.
test "win32 comctl32: TASKDIALOGCONFIG is byte-packed" {
    try std.testing.expectEqual(160, @sizeOf(comctl32.TASKDIALOGCONFIG));
    try std.testing.expectEqual(12, @sizeOf(comctl32.TASKDIALOG_BUTTON));
    try std.testing.expectEqual(148, @offsetOf(comctl32.TASKDIALOGCONFIG, "lpCallbackData"));
}

// The 64-bit layout of commdlg.h's OPENFILENAMEW.
test "win32 comdlg32: OPENFILENAMEW size" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(152, @sizeOf(win32.comdlg32.OPENFILENAMEW));
    try std.testing.expectEqual(96, @offsetOf(win32.comdlg32.OPENFILENAMEW, "Flags"));
    try std.testing.expectEqual(148, @offsetOf(win32.comdlg32.OPENFILENAMEW, "FlagsEx"));
}

test "win32 dialogs: the link confirmation has no mnemonic on Allow" {
    for (confirm_buttons) |b| {
        try std.testing.expect(std.mem.indexOfScalar(u8, b.text, '&') == null);
    }
}
