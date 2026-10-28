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

const IDYES = 6;
const MB_DEFBUTTON2 = 0x00000100;

/// Id of the affirmative custom button ("&Close", "&Allow").
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
    const buttons = [_]ListButton{
        .{ .id = button_accept, .text = "&Allow" },
        .{ .id = button_cancel, .text = "Cancel" },
    };
    const answer = show(owner, title, title, body, "", &buttons, button_cancel) orelse
        return fallbackBox(owner, title, body);
    return answer == button_accept;
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
    });
}

/// The M1 message box, for when the dialog cannot be built.
fn fallbackBox(owner: win32.foundation.HWND, title: []const u8, body: []const u8) bool {
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
