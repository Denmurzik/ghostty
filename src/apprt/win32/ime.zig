//! Win32 IME (IMM32) message handling. Composition text is drawn by core as
//! preedit, so the system composition window is suppressed; only the
//! candidate window is left to the IME, positioned at the cursor cell.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_ime);

/// Per-surface ime state.
pub const State = struct {
    /// Whether a composition is in progress (between WM_IME_STARTCOMPOSITION
    /// and WM_IME_ENDCOMPOSITION). The keyboard handler consults this so
    /// keys the IME owns (VK_PROCESSKEY) are not forwarded as key events.
    composing: bool = false,
};

/// Handle a window message for `surface`. Null means not handled, and the
/// next handler (or the default window procedure) gets the message.
pub fn handle(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    const user32 = win32.user32;
    switch (msg) {
        // We draw the composition string ourselves as preedit, so the
        // IME must not show its own composition window. The candidate
        // window stays with the IME.
        user32.WM_IME_SETCONTEXT => {
            const bits: usize = @bitCast(lparam);
            const masked = bits & ~@as(usize, win32.imm32.ISC_SHOWUICOMPOSITIONWINDOW);
            return user32.DefWindowProcW(surface.hwnd, msg, wparam, @bitCast(masked));
        },

        user32.WM_IME_STARTCOMPOSITION => {
            surface.ime_state.composing = true;
            updateWindows(surface);
            return 0;
        },

        user32.WM_IME_COMPOSITION => {
            const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
            composition(surface, flags);
            return 0;
        },

        user32.WM_IME_ENDCOMPOSITION => {
            surface.ime_state.composing = false;
            surface.core_surface.preeditCallback(null) catch |err|
                log.warn("clearing preedit failed err={}", .{err});
            return 0;
        },

        else => return null,
    }
}

fn composition(surface: *Surface, flags: u32) void {
    const imm32 = win32.imm32;
    const himc = imm32.ImmGetContext(surface.hwnd) orelse return;
    defer _ = imm32.ImmReleaseContext(surface.hwnd, himc);

    // A committed result may arrive together with the next composition
    // string, so the result goes first.
    if (flags & imm32.GCS_RESULTSTR != 0) result: {
        const text = compositionString(surface, himc, imm32.GCS_RESULTSTR) orelse break :result;
        defer surface.window.app.core_app.alloc.free(text);

        surface.core_surface.preeditCallback(null) catch |err|
            log.warn("clearing preedit failed err={}", .{err});
        if (text.len > 0) surface.core_surface.textCallback(text) catch |err|
            log.warn("sending ime result failed err={}", .{err});
    }

    // Either a composition string, or no flags at all, which is how a
    // cancelled composition shows up.
    if (flags & imm32.GCS_COMPSTR != 0 or flags == 0) preedit: {
        const text = compositionString(surface, himc, imm32.GCS_COMPSTR) orelse break :preedit;
        defer surface.window.app.core_app.alloc.free(text);

        surface.core_surface.preeditCallback(if (text.len > 0) text else null) catch |err|
            log.warn("setting preedit failed err={}", .{err});
        updateWindows(surface);
    }
}

/// Read a composition string as UTF-8; null on failure. Caller frees with
/// the app allocator.
fn compositionString(
    surface: *Surface,
    himc: win32.imm32.HIMC,
    index: u32,
) ?[]u8 {
    const imm32 = win32.imm32;
    const alloc = surface.window.app.core_app.alloc;

    const bytes = imm32.ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes < 0) return null;

    const units = alloc.alloc(u16, @as(usize, @intCast(bytes)) / 2) catch return null;
    defer alloc.free(units);
    if (units.len > 0) {
        const got = imm32.ImmGetCompositionStringW(himc, index, units.ptr, @intCast(units.len * 2));
        if (got < 0) return null;
    }

    return std.unicode.utf16LeToUtf8Alloc(alloc, units) catch |err| {
        log.warn("invalid composition string err={}", .{err});
        return null;
    };
}

/// Move the composition and candidate windows to the cursor cell.
fn updateWindows(surface: *Surface) void {
    const imm32 = win32.imm32;
    const himc = imm32.ImmGetContext(surface.hwnd) orelse return;
    defer _ = imm32.ImmReleaseContext(surface.hwnd, himc);

    const pos = surface.core_surface.imePoint();
    const scale = surface.content_scale.x;
    const point = candidatePos(pos, scale);

    const comp: imm32.COMPOSITIONFORM = .{
        .dwStyle = imm32.CFS_POINT,
        .ptCurrentPos = point,
        .rcArea = std.mem.zeroes(win32.foundation.RECT),
    };
    _ = imm32.ImmSetCompositionWindow(himc, &comp);

    const cand: imm32.CANDIDATEFORM = .{
        .dwIndex = 0,
        .dwStyle = imm32.CFS_EXCLUDE,
        .ptCurrentPos = point,
        .rcArea = excludeRect(pos, scale),
    };
    _ = imm32.ImmSetCandidateWindow(himc, &cand);
}

/// Client-pixel position for the candidate window. `p.y` from core is
/// already the bottom of the cursor cell.
pub fn candidatePos(p: apprt.IMEPos, scale: f32) win32.foundation.POINT {
    return .{
        .x = scaled(p.x, scale),
        .y = scaled(p.y, scale),
    };
}

/// Client-pixel rectangle the candidate window must not cover: the cursor
/// cell, from `p.y - p.height` to `p.y`.
pub fn excludeRect(p: apprt.IMEPos, scale: f32) win32.foundation.RECT {
    return .{
        .left = scaled(p.x, scale),
        .top = scaled(p.y - p.height, scale),
        .right = scaled(p.x + p.width, scale),
        .bottom = scaled(p.y, scale),
    };
}

fn scaled(v: f64, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

test "win32 ime: candidate position is the cursor bottom" {
    const p: apprt.IMEPos = .{ .x = 10, .y = 20, .width = 8, .height = 16 };
    const pt = candidatePos(p, 1.5);
    try std.testing.expectEqual(@as(i32, 15), pt.x);
    try std.testing.expectEqual(@as(i32, 30), pt.y);
}

test "win32 ime: exclude rect covers the cursor cell" {
    const p: apprt.IMEPos = .{ .x = 10, .y = 20, .width = 8, .height = 16 };
    const r = excludeRect(p, 1.5);
    try std.testing.expectEqual(@as(i32, 15), r.left);
    try std.testing.expectEqual(@as(i32, 6), r.top);
    try std.testing.expectEqual(@as(i32, 27), r.right);
    try std.testing.expectEqual(@as(i32, 30), r.bottom);
}
