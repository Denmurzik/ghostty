//! Win32 keyboard message handling: turns WM_KEYDOWN/UP and the character
//! messages `TranslateMessage` derives from them into core key events.
//!
//! The message loop translates a key-down before dispatching it, so by the
//! time we see it its WM_CHAR/WM_DEADCHAR are already queued. We pull them
//! out of the queue and send them with the key event, which is what lets
//! core match bindings on the physical key and still get the text.
const std = @import("std");
const win32 = @import("win32");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");
const key = @import("key.zig");
const latency = @import("../../os/main.zig").windows_latency;

const user32 = win32.user32;
const log = std.log.scoped(.win32_keyboard);

const WM_KEYFIRST = 0x0100;
const WM_KEYLAST = 0x0109;

/// Bit 30 of a key message's lparam: the key was already down.
const lparam_was_down: usize = 1 << 30;
/// Bit 29: Alt is held (the "context code").
const lparam_alt: usize = 1 << 29;

/// Per-surface keyboard state.
pub const State = struct {
    /// Whether the keyboard layout `hkl` has an AltGr key.
    altgr_cache: ?struct { hkl: user32.HKL, has_altgr: bool } = null,

    /// Joins surrogate pairs that arrive as two WM_CHARs.
    joiner: key.Utf16Joiner = .{},

    /// `GetMessageTime` of the synthetic left Ctrl that AltGr presses
    /// produce, while that key is held. Null when none is.
    last_lctrl_time: ?i32 = null,

    /// A dead key was pressed and its accent is shown as preedit.
    dead_pending: bool = false,
};

/// Handle a window message for `surface`. Null means not handled, and the
/// next handler (or the default window procedure) gets the message.
pub fn handle(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    switch (msg) {
        user32.WM_KEYDOWN, user32.WM_SYSKEYDOWN, user32.WM_CHAR => latency.markInput(.key),
        else => {},
    }

    return switch (msg) {
        user32.WM_KEYDOWN,
        user32.WM_SYSKEYDOWN,
        user32.WM_KEYUP,
        user32.WM_SYSKEYUP,
        => handleKey(surface, msg, wparam, lparam),

        user32.WM_CHAR, user32.WM_SYSCHAR => handleChar(surface, msg, wparam),
        user32.WM_UNICHAR => handleUniChar(surface, wparam),
        user32.WM_DEADCHAR, user32.WM_SYSDEADCHAR => handleDeadChar(surface, wparam),

        user32.WM_INPUTLANGCHANGE => {
            // The default procedure still has to see this one.
            surface.keyboard_state.altgr_cache = null;
            return null;
        },

        else => null,
    };
}

fn handleKey(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    const vk: u16 = @truncate(wparam);
    const bits: usize = @bitCast(lparam);
    const sys = msg == user32.WM_SYSKEYDOWN or msg == user32.WM_SYSKEYUP;
    const is_down = msg == user32.WM_KEYDOWN or msg == user32.WM_SYSKEYDOWN;
    const state = &surface.keyboard_state;

    if (key.passToSystem(vk, sys, bits & lparam_alt != 0)) return null;

    switch (vk) {
        // The IME owns the key. Its result arrives as IME messages.
        user32.VK_PROCESSKEY => return 0,

        // Synthesized input: the text arrives as a lone WM_CHAR.
        user32.VK_PACKET => return 0,

        // Key messages carry the generic VK; the side is lparam's extended bit.
        user32.VK_CONTROL => if (swallowAltGrCtrl(state, is_down, vk, lparam)) return 0,

        else => {},
    }

    const hkl = user32.GetKeyboardLayout(0);
    const lparam_sc = withScancode(lparam, vk, hkl);
    const scancode: u16 = @intCast((@as(usize, @bitCast(lparam_sc)) >> 16) & 0xFF);

    const key_state = key.captureKeyState();
    var event: input.KeyEvent = .{
        .action = if (!is_down) .release else if (bits & lparam_was_down != 0) .repeat else .press,
        .key = key.physicalKey(lparam_sc, vk),
        .mods = key.mods(&key_state),
    };

    if (hkl) |h| event.unshifted_codepoint = key.unshiftedCodepoint(h, vk, scancode);

    // Text only comes with a press. Drain it before calling into core,
    // which may run a nested message loop.
    var text_buf: [64]u8 = undefined;
    var text: []const u8 = "";
    var dead = false;
    if (is_down) {
        const drained = drainChars(surface, &text_buf);
        text = drained.text;
        dead = drained.dead;
    }

    var stripped_buf: [64]u8 = undefined;
    var preedit: ?[]const u8 = null;
    if (dead) {
        // A dead key: show the accent and wait for the next key.
        event.composing = true;
        event.utf8 = text;
        preedit = text;
        state.dead_pending = true;
    } else if (text.len > 0) {
        const clear_preedit = state.dead_pending;
        state.dead_pending = false;

        event.utf8 = key.stripControl(text, &stripped_buf);
        if (event.mods.shift and event.utf8.len > 0) event.consumed_mods.shift = true;

        const has_altgr = hasAltGr(state, hkl);
        const altgr = key.applyAltGr(
            event.mods,
            has_altgr,
            key_state[user32.VK_RMENU] & 0x80 != 0,
            event.utf8.len > 0,
        );
        event.mods = altgr.mods;
        event.consumed_mods.ctrl = altgr.consumed.ctrl;
        event.consumed_mods.alt = altgr.consumed.alt;

        if (clear_preedit) sendPreedit(surface, null);
    }

    if (preedit) |p| sendPreedit(surface, p);

    // The effect is irrelevant: only Alt+F4 and Alt+Space ever go to the
    // system, and those returned above. The surface may be gone after a
    // close effect, so nothing touches it from here on.
    _ = surface.core_surface.keyCallback(event) catch |err|
        log.warn("key callback failed err={}", .{err});
    return 0;
}

/// `lparam` with a scancode filled in for injected keys that have none
/// (`keybd_event` with scancode 0), so they still map to a physical key.
fn withScancode(
    lparam: win32.foundation.LPARAM,
    vk: u16,
    hkl: ?user32.HKL,
) win32.foundation.LPARAM {
    const bits: usize = @bitCast(lparam);
    if ((bits >> 16) & 0xFF != 0) return lparam;

    const sc = user32.MapVirtualKeyExW(vk, user32.MAPVK_VK_TO_VSC_EX, hkl);
    if (sc == 0) return lparam;

    var out = bits | (@as(usize, sc & 0xFF) << 16);
    if (sc & 0xFF00 == 0xE000) out |= 1 << 24;
    return @bitCast(out);
}

/// AltGr presses send a left Ctrl key-down and a right Alt key-down with
/// the same timestamp. The Ctrl half is not a key the user pressed, so it
/// never reaches core, nor does its release. True when swallowed.
fn swallowAltGrCtrl(
    state: *State,
    is_down: bool,
    vk: u16,
    lparam: win32.foundation.LPARAM,
) bool {
    if (!is_down) {
        if (!key.isSyntheticAltGrCtrlRelease(vk, lparam, state.last_lctrl_time != null)) return false;
        state.last_lctrl_time = null;
        return true;
    }

    const time = user32.GetMessageTime();
    var next: user32.MSG = .{};
    const queued = user32.PeekMessageW(&next, null, WM_KEYFIRST, WM_KEYLAST, user32.PM_NOREMOVE) != 0;
    const synthetic = key.isSyntheticAltGrCtrl(
        .{ .is_down = true, .vk = vk, .lparam = lparam, .time = time },
        if (queued) .{
            .is_down = next.message == user32.WM_KEYDOWN or next.message == user32.WM_SYSKEYDOWN,
            .vk = @truncate(next.wParam),
            .lparam = next.lParam,
            .time = @bitCast(next.time),
        } else null,
    );
    state.last_lctrl_time = if (synthetic) time else null;
    return synthetic;
}

fn hasAltGr(state: *State, hkl: ?user32.HKL) bool {
    const h = hkl orelse return false;
    if (state.altgr_cache) |c| {
        if (c.hkl == h) return c.has_altgr;
    }
    const has = key.layoutHasAltGr(h);
    state.altgr_cache = .{ .hkl = h, .has_altgr = has };
    return has;
}

const Drained = struct {
    /// UTF-8 of the character messages, or of the dead key's accent.
    text: []const u8,
    /// The text is a dead key's accent, not a typed character.
    dead: bool,
};

/// Remove the WM_CHAR family messages `TranslateMessage` queued for the
/// key-down being handled and return their text.
fn drainChars(surface: *Surface, buf: []u8) Drained {
    var len: usize = 0;
    var dead = false;

    // A key yields at most a few units; bound the loop regardless.
    for (0..16) |_| {
        var peek: user32.MSG = .{};
        if (user32.PeekMessageW(&peek, surface.hwnd, WM_KEYFIRST, WM_KEYLAST, user32.PM_NOREMOVE) == 0) break;
        if (!isCharMessage(peek.message)) break;

        var msg: user32.MSG = .{};
        if (user32.PeekMessageW(&msg, surface.hwnd, peek.message, peek.message, user32.PM_REMOVE) == 0) break;

        const unit: u16 = @truncate(msg.wParam);
        var out: [key.Utf16Joiner.max_out]u8 = undefined;
        const is_dead = msg.message == user32.WM_DEADCHAR or msg.message == user32.WM_SYSDEADCHAR;
        const utf8 = if (is_dead)
            encodeUnit(unit, &out)
        else
            surface.keyboard_state.joiner.feed(unit, &out) orelse continue;

        len += appendCapped(buf[len..], utf8);
        if (is_dead) {
            dead = true;
            break;
        }
    }

    return .{ .text = buf[0..len], .dead = dead };
}

fn isCharMessage(message: u32) bool {
    return switch (message) {
        user32.WM_CHAR, user32.WM_SYSCHAR, user32.WM_DEADCHAR, user32.WM_SYSDEADCHAR => true,
        else => false,
    };
}

fn encodeUnit(unit: u16, out: *[key.Utf16Joiner.max_out]u8) []const u8 {
    const n = std.unicode.utf8Encode(unit, out) catch blk: {
        // A lone surrogate cannot be a dead key; show the replacement.
        break :blk std.unicode.utf8Encode(0xFFFD, out) catch unreachable;
    };
    return out[0..n];
}

fn appendCapped(dest: []u8, src: []const u8) usize {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

/// A character without a key-down we handled: `SendInput` unicode
/// (VK_PACKET), Alt+numpad, characters posted by other programs.
fn handleChar(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
) ?win32.foundation.LRESULT {
    // Alt+Space opens the system menu; that is the default procedure's.
    if (msg == user32.WM_SYSCHAR and wparam == user32.VK_SPACE) return null;

    var out: [key.Utf16Joiner.max_out]u8 = undefined;
    const state = &surface.keyboard_state;
    // Sys characters are only ever Alt+key presses we already sent.
    if (msg == user32.WM_SYSCHAR) return 0;

    const text = state.joiner.feed(@truncate(wparam), &out) orelse return 0;
    sendText(surface, text);
    return 0;
}

/// A code point sent as WM_UNICHAR (UTF-32). `UNICODE_NOCHAR` asks whether
/// we handle the message, which we do.
fn handleUniChar(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    if (wparam == user32.UNICODE_NOCHAR) return 1;

    var out: [key.Utf16Joiner.max_out]u8 = undefined;
    const cp = std.math.cast(u21, wparam) orelse return 0;
    const n = std.unicode.utf8Encode(cp, &out) catch return 0;
    sendText(surface, out[0..n]);
    return 1;
}

/// Deliver text that no key of ours produced, as a keyless press (see
/// `key.textEvent`), never as a paste.
fn sendText(surface: *Surface, text: []const u8) void {
    const state = &surface.keyboard_state;
    if (state.dead_pending) {
        state.dead_pending = false;
        sendPreedit(surface, null);
    }
    _ = surface.core_surface.keyCallback(key.textEvent(text)) catch |err|
        log.warn("text key callback failed err={}", .{err});
}

/// A dead key whose key-down we did not drain.
fn handleDeadChar(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    var out: [key.Utf16Joiner.max_out]u8 = undefined;
    surface.keyboard_state.dead_pending = true;
    sendPreedit(surface, encodeUnit(@truncate(wparam), &out));
    return 0;
}

fn sendPreedit(surface: *Surface, text: ?[]const u8) void {
    surface.core_surface.preeditCallback(text) catch |err|
        log.warn("preedit callback failed err={}", .{err});
}

test {
    _ = key;
}
