//! Modal confirmation dialogs (TaskDialog; MessageBoxW when it is unavailable).
//!
//! A dialog runs its own message loop, so anything that shows one can see
//! its window, and the surface behind it, destroyed before the call
//! returns, and posted messages (IPC ops included) run re-entrantly inside
//! it. Dialogs are therefore shown only from posted-message handlers, never
//! from `performAction`, core callbacks or IPC op handlers, and every call
//! site checks that its window survived. See `clipboard.zig` for how that
//! is handled for clipboard prompts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const comctl32 = win32.comctl32;

const IDYES = 6;
const MB_DEFBUTTON2 = 0x00000100;

/// Id of the affirmative custom button ("&Close", "&Allow").
const button_accept = 100;

/// The codepoint that stands in for bytes that are not valid UTF-8.
const replacement: u21 = 0xFFFD;

/// First codepoint of the Unicode "Control Pictures" block: U+2400 + c is
/// the visible symbol for the control character c.
const control_pictures: u21 = 0x2400;

const log = std.log.scoped(.win32_dialogs);

const w16 = std.unicode.utf8ToUtf16LeStringLiteral;

/// What a close would take down. Decides the sentence of the confirmation.
pub const CloseKind = enum { surface, tab, window, all_windows, app };

/// Ask whether `kind` may be closed while a process is still running in it.
pub fn confirmCloseKind(owner: win32.foundation.HWND, kind: CloseKind) bool {
    const buttons = [_]comctl32.TASKDIALOG_BUTTON{
        .{ .nButtonID = button_accept, .pszButtonText = w16("&Close") },
        .{ .nButtonID = comctl32.IDCANCEL, .pszButtonText = w16("Cancel") },
    };
    const config = buildConfig(owner, kind, &buttons);
    return switch (comctl32.taskDialogShow(&config)) {
        .pressed => |id| id == button_accept,
        .failed => |hr| refused(hr),
        .unavailable => fallbackBox(owner, closeTitle(kind), closeBody(kind)),
    };
}

/// The task dialog failed, maybe after it had been on screen: asking again
/// would prompt twice, so the answer is the default button (Cancel), and the
/// failure is logged.
fn refused(hr: i32) bool {
    log.warn("task dialog failed, taking the default button hr=0x{x}", .{@as(u32, @bitCast(hr))});
    return false;
}

/// The task dialog of a close confirmation. Pure: nothing is shown.
fn buildConfig(
    owner: win32.foundation.HWND,
    kind: CloseKind,
    buttons: []const comctl32.TASKDIALOG_BUTTON,
) comctl32.TASKDIALOGCONFIG {
    return buildConfigText(
        owner,
        w16("Ghostty"),
        closeInstruction(kind),
        w16("A process is still running. Closing will end it."),
        buttons,
    );
}

fn buildConfigText(
    owner: ?win32.foundation.HWND,
    title: [*:0]const u16,
    instruction: ?[*:0]const u16,
    content: [*:0]const u16,
    buttons: []const comctl32.TASKDIALOG_BUTTON,
) comctl32.TASKDIALOGCONFIG {
    return .{
        .hwndParent = owner,
        .dwFlags = comctl32.TDF_POSITION_RELATIVE_TO_WINDOW | comctl32.TDF_ALLOW_DIALOG_CANCELLATION,
        .pszWindowTitle = title,
        .pszMainInstruction = instruction,
        .pszContent = content,
        .cButtons = @intCast(buttons.len),
        .pButtons = buttons.ptr,
        .nDefaultButton = comctl32.IDCANCEL,
    };
}

fn closeInstruction(kind: CloseKind) [*:0]const u16 {
    return switch (kind) {
        .surface => w16("Close this terminal?"),
        .tab => w16("Close this tab?"),
        .window => w16("Close this window?"),
        .all_windows => w16("Close all windows?"),
        .app => w16("Quit Ghostty?"),
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
/// hard to undo. Text that does not fit the (generous) fixed buffers is
/// cut, and invalid UTF-8 shows as U+FFFD.
pub fn confirm(
    owner: win32.foundation.HWND,
    title: []const u8,
    body: []const u8,
) bool {
    var title_buf: [128]u16 = undefined;
    var body_buf: [2048]u16 = undefined;
    const wide_title = toWide(&title_buf, title);
    const wide_body = toWide(&body_buf, body);

    const buttons = [_]comctl32.TASKDIALOG_BUTTON{
        .{ .nButtonID = button_accept, .pszButtonText = w16("&Allow") },
        .{ .nButtonID = comctl32.IDCANCEL, .pszButtonText = w16("Cancel") },
    };
    const config = buildConfigText(owner, wide_title, null, wide_body, &buttons);
    return switch (comctl32.taskDialogShow(&config)) {
        .pressed => |id| id == button_accept,
        .failed => |hr| refused(hr),
        .unavailable => fallbackBox(owner, title, body),
    };
}

/// One button of `taskDialogList`.
pub const ListButton = struct {
    id: i32,
    text: []const u8,
};

const list_buttons_max = 4;

/// A task dialog with a warning icon, a main instruction, a body (a list
/// of lines, say) and custom buttons. The id of the pressed button; null
/// when the dialog failed (nothing is asked a second time). Without
/// `TaskDialogIndirect` the body is shown in a plain message box and the
/// result is null as well. Text that does not fit the fixed buffers is cut.
pub fn taskDialogList(
    owner: ?win32.foundation.HWND,
    title: []const u8,
    instruction: []const u8,
    body: []const u8,
    buttons: []const ListButton,
    default_id: i32,
) ?i32 {
    var title_buf: [128]u16 = undefined;
    var instruction_buf: [256]u16 = undefined;
    var body_buf: [16384]u16 = undefined;
    var text_bufs: [list_buttons_max][64]u16 = undefined;
    var raw: [list_buttons_max]comctl32.TASKDIALOG_BUTTON = undefined;
    const count = @min(buttons.len, list_buttons_max);
    for (buttons[0..count], 0..) |b, i| raw[i] = .{
        .nButtonID = b.id,
        .pszButtonText = toWide(&text_bufs[i], b.text).ptr,
    };

    var config = buildConfigText(
        owner,
        toWide(&title_buf, title),
        toWide(&instruction_buf, instruction),
        toWide(&body_buf, body),
        raw[0..count],
    );
    config.pszMainIcon = @ptrFromInt(comctl32.TD_WARNING_ICON);
    config.nDefaultButton = default_id;
    switch (comctl32.taskDialogShow(&config)) {
        .pressed => |id| return id,
        .failed => |hr| {
            log.warn("task dialog failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return null;
        },
        .unavailable => {
            var box_title: [128]u16 = undefined;
            var box_body: [16384]u16 = undefined;
            _ = win32.user32.MessageBoxW(
                owner,
                toWide(&box_body, body),
                toWide(&box_title, title),
                win32.user32.MB_OK | win32.user32.MB_ICONWARNING,
            );
            return null;
        },
    }
}

/// The M1 message box, for when `TaskDialogIndirect` cannot be used.
fn fallbackBox(owner: win32.foundation.HWND, title: []const u8, body: []const u8) bool {
    var title_buf: [128]u16 = undefined;
    var body_buf: [2048]u16 = undefined;
    const result = win32.user32.MessageBoxW(
        owner,
        toWide(&body_buf, body),
        toWide(&title_buf, title),
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

        var cp = nextCodepoint(text, &i);
        if (cp < 0x20) {
            cp += control_pictures;
        } else if (cp == 0x7F) {
            cp = control_pictures + 0x21;
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

/// Decode the codepoint at `text[i.*]` and advance `i`. A byte that does
/// not start a valid sequence yields U+FFFD and advances by one.
fn nextCodepoint(text: []const u8, i: *usize) u21 {
    const start = i.*;
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch {
        i.* += 1;
        return replacement;
    };
    if (start + len > text.len) {
        i.* += 1;
        return replacement;
    }
    const cp = std.unicode.utf8Decode(text[start..][0..len]) catch {
        i.* += 1;
        return replacement;
    };
    i.* += len;
    return cp;
}

/// UTF-8 to a null-terminated UTF-16 string in `buf`, cut at the buffer's
/// end (never in the middle of a surrogate pair).
fn toWide(buf: []u16, text: []const u8) [:0]u16 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = nextCodepoint(text, &i);
        const units: usize = if (cp >= 0x10000) 2 else 1;
        if (n + units + 1 > buf.len) break;

        if (units == 2) {
            const c = cp - 0x10000;
            buf[n] = 0xD800 + @as(u16, @intCast(c >> 10));
            buf[n + 1] = 0xDC00 + @as(u16, @intCast(c & 0x3FF));
        } else {
            buf[n] = @intCast(cp);
        }
        n += units;
    }

    buf[n] = 0;
    return buf[0..n :0];
}

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

test "win32 dialogs: wide conversion handles non-BMP, invalid bytes and truncation" {
    var buf: [8]u16 = undefined;

    const wide = toWide(&buf, "aЖ😀\xff");
    try std.testing.expectEqualSlices(
        u16,
        &.{ 'a', 0x0416, 0xD83D, 0xDE00, 0xFFFD },
        wide,
    );
    try std.testing.expectEqual(@as(u16, 0), buf[wide.len]);

    // Room for 3 units plus the terminator: the surrogate pair does not fit
    // after "ab" so it is dropped whole.
    var small: [4]u16 = undefined;
    const cut = toWide(&small, "ab😀c");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b' }, cut);
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

test "win32 dialogs: task dialog config is valid" {
    const owner: win32.foundation.HWND = @ptrFromInt(0x1000);
    const buttons = [_]comctl32.TASKDIALOG_BUTTON{
        .{ .nButtonID = button_accept, .pszButtonText = w16("&Close") },
        .{ .nButtonID = comctl32.IDCANCEL, .pszButtonText = w16("Cancel") },
    };
    for (std.enums.values(CloseKind)) |kind| {
        const config = buildConfig(owner, kind, &buttons);
        try std.testing.expectEqual(@sizeOf(comctl32.TASKDIALOGCONFIG), config.cbSize);
        try std.testing.expectEqual(comctl32.IDCANCEL, config.nDefaultButton);
        try std.testing.expectEqual(2, config.cButtons);
        try std.testing.expect(config.dwFlags & comctl32.TDF_POSITION_RELATIVE_TO_WINDOW != 0);
        try std.testing.expectEqual(owner, config.hwndParent.?);
        try std.testing.expect(config.pszMainInstruction != null);
    }
    try std.testing.expectEqualSlices(u16, w16("Quit Ghostty?"), std.mem.span(closeInstruction(.app)));
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
