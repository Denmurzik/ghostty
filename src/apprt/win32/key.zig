//! Pure keyboard translation helpers: scancode and modifier decoding, AltGr
//! handling and UTF-16 to UTF-8 text assembly. Nothing here touches a
//! window; `keyboard.zig` wires these into the message loop.
const std = @import("std");
const win32 = @import("win32");
const input = @import("../../input.zig");

const user32 = win32.user32;

/// The 256 virtual-key states as `GetKeyboardState` lays them out: bit 7
/// is "down", bit 0 is "toggled" (lock keys).
pub const KeyState = [256]u8;

const down_bit: u8 = 0x80;
const toggle_bit: u8 = 0x01;

/// Scancodes are looked up as `sc` for plain keys and `0x100 + sc` for
/// keys with the E0 prefix. Chromium's table has no other prefixes.
const scancode_table: [0x200]input.Key = table: {
    @setEvalBranchQuota(20000);
    var t: [0x200]input.Key = @splat(.unidentified);
    for (input.keycodes.entries) |entry| {
        if (entry.native == 0) continue;
        const idx = tableIndex(entry.native) orelse continue;
        if (t[idx] == .unidentified) t[idx] = entry.key;
    }
    break :table t;
};

fn tableIndex(native: u32) ?usize {
    if (native < 0x100) return native;
    if (native & 0xFF00 == 0xE000) return 0x100 + (native & 0xFF);
    return null;
}

/// The physical key of a WM_KEYDOWN/UP: the scancode of `lparam`, with the
/// E0 prefix when the extended bit is set. Pause and NumLock share
/// scancode 0x45 and are told apart by `vk`. The fake shifts Windows
/// injects around some extended keys have no key.
pub fn physicalKey(lparam: win32.foundation.LPARAM, vk: u16) input.Key {
    const bits: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((bits >> 16) & 0xFF);
    const extended = bits & (1 << 24) != 0;

    const native: u32 = switch (vk) {
        user32.VK_PAUSE => 0x45,
        user32.VK_NUMLOCK => 0xE045,
        else => if (extended) 0xE000 | scancode else scancode,
    };
    if (native == 0xE02A or native == 0xE036) return .unidentified;

    const idx = tableIndex(native) orelse return .unidentified;
    return scancode_table[idx];
}

fn isDown(state: *const KeyState, vk: u16) bool {
    return state[vk] & down_bit != 0;
}

/// Modifiers from a key state. A side is "right" only when the right key
/// is down and the left is not.
pub fn mods(state: *const KeyState) input.Mods {
    var m: input.Mods = .{};

    const shift_l = isDown(state, user32.VK_LSHIFT);
    const shift_r = isDown(state, user32.VK_RSHIFT);
    if (shift_l or shift_r or isDown(state, user32.VK_SHIFT)) {
        m.shift = true;
        if (shift_r and !shift_l) m.sides.shift = .right;
    }

    const ctrl_l = isDown(state, user32.VK_LCONTROL);
    const ctrl_r = isDown(state, user32.VK_RCONTROL);
    if (ctrl_l or ctrl_r or isDown(state, user32.VK_CONTROL)) {
        m.ctrl = true;
        if (ctrl_r and !ctrl_l) m.sides.ctrl = .right;
    }

    const alt_l = isDown(state, user32.VK_LMENU);
    const alt_r = isDown(state, user32.VK_RMENU);
    if (alt_l or alt_r or isDown(state, user32.VK_MENU)) {
        m.alt = true;
        if (alt_r and !alt_l) m.sides.alt = .right;
    }

    const win_l = isDown(state, user32.VK_LWIN);
    const win_r = isDown(state, user32.VK_RWIN);
    if (win_l or win_r) {
        m.super = true;
        if (win_r and !win_l) m.sides.super = .right;
    }

    m.caps_lock = state[user32.VK_CAPITAL] & toggle_bit != 0;
    m.num_lock = state[user32.VK_NUMLOCK] & toggle_bit != 0;
    return m;
}

/// Snapshot of the modifier and lock keys, as of the message being
/// processed (`GetKeyState` follows the message queue, not the hardware).
pub fn captureKeyState() KeyState {
    var state: KeyState = @splat(0);
    const vks = [_]u16{
        user32.VK_SHIFT,   user32.VK_LSHIFT,   user32.VK_RSHIFT,
        user32.VK_CONTROL, user32.VK_LCONTROL, user32.VK_RCONTROL,
        user32.VK_MENU,    user32.VK_LMENU,    user32.VK_RMENU,
        user32.VK_LWIN,    user32.VK_RWIN,     user32.VK_CAPITAL,
        user32.VK_NUMLOCK,
    };
    for (vks) |vk| {
        const s = user32.GetKeyState(vk);
        var v: u8 = 0;
        if (s < 0) v |= down_bit;
        if (s & 1 != 0) v |= toggle_bit;
        state[vk] = v;
    }
    return state;
}

/// Whether `hkl` has an AltGr key: some character is reached with
/// Ctrl+Alt held. Scans Latin text and the euro sign, which covers every
/// AltGr layout (their AltGr plane always carries `@`, `{`, `\` or `€`).
pub fn layoutHasAltGr(hkl: user32.HKL) bool {
    const ctrl_alt: i16 = 0x2 | 0x4;
    var ch: u16 = 0x20;
    while (ch <= 0x2FF) : (ch += 1) {
        if (altGrChar(hkl, ch, ctrl_alt)) return true;
    }
    return altGrChar(hkl, 0x20AC, ctrl_alt);
}

fn altGrChar(hkl: user32.HKL, ch: u16, ctrl_alt: i16) bool {
    const r = user32.VkKeyScanExW(ch, hkl);
    if (r == -1) return false;
    return (r >> 8) & ctrl_alt == ctrl_alt;
}

/// The character `vk` produces on `hkl` with no modifier held, as a
/// codepoint. Zero when it produces none (or only a control character).
/// A dead key yields its accent. Flag 0x4 keeps the layout's dead-key
/// state untouched, so asking is free of side effects.
pub fn unshiftedCodepoint(hkl: user32.HKL, vk: u16, scancode: u16) u21 {
    const empty: KeyState = @splat(0);
    var buf: [4]u16 = undefined;
    const n = user32.ToUnicodeEx(vk, scancode, &empty, &buf, buf.len, 0x4, hkl);

    // A negative count is a dead key; the accent is still in the buffer.
    const len: usize = @intCast(if (n < 0) 1 else n);
    if (len == 0) return 0;

    const units = buf[0..len];
    const cp: u21 = blk: {
        if (std.unicode.utf16IsHighSurrogate(units[0])) {
            if (len < 2) return 0;
            break :blk std.unicode.utf16DecodeSurrogatePair(units[0..2]) catch return 0;
        }
        if (std.unicode.utf16IsLowSurrogate(units[0])) return 0;
        break :blk units[0];
    };
    if (cp < 0x20 or cp == 0x7F) return 0;
    return cp;
}

pub const AltGrResult = struct {
    mods: input.Mods,
    consumed: input.Mods,
};

/// On an AltGr layout the right Alt key arrives as Ctrl+Alt. When it
/// produced text that pair is part of the character, not a modifier: both
/// are dropped from `m` and reported consumed.
pub fn applyAltGr(
    m: input.Mods,
    has_altgr_layout: bool,
    ralt_down: bool,
    produced_text: bool,
) AltGrResult {
    if (!has_altgr_layout or !ralt_down or !produced_text) {
        return .{ .mods = m, .consumed = .{} };
    }

    var out = m;
    out.ctrl = false;
    out.alt = false;
    return .{ .mods = out, .consumed = .{ .ctrl = true, .alt = true } };
}

/// A key message as far as `isSyntheticAltGrCtrl` cares.
pub const KeyMessage = struct {
    /// WM_KEYDOWN or WM_SYSKEYDOWN, as opposed to a release.
    is_down: bool,
    /// The generic virtual key: key messages never carry the left/right
    /// variants (VK_LCONTROL, VK_RMENU), which exist only in key state.
    vk: u16,
    lparam: win32.foundation.LPARAM,
    /// `GetMessageTime` of the message.
    time: i32,
};

fn isExtended(lparam: win32.foundation.LPARAM) bool {
    const bits: usize = @bitCast(lparam);
    return bits & (1 << 24) != 0;
}

/// Whether the key-down `ctrl` is the left Ctrl Windows injects before the
/// right Alt of an AltGr press: a left (non-extended) Ctrl immediately
/// followed by a right (extended) Alt key-down with the same timestamp.
/// `next` is the next queued key message, if any.
pub fn isSyntheticAltGrCtrl(ctrl: KeyMessage, next: ?KeyMessage) bool {
    if (!ctrl.is_down or ctrl.vk != user32.VK_CONTROL or isExtended(ctrl.lparam)) return false;
    const n = next orelse return false;
    return n.is_down and
        n.vk == user32.VK_MENU and
        isExtended(n.lparam) and
        n.time == ctrl.time;
}

/// Whether a left Ctrl release closes a swallowed synthetic AltGr Ctrl.
pub fn isSyntheticAltGrCtrlRelease(vk: u16, lparam: win32.foundation.LPARAM, swallowed: bool) bool {
    return swallowed and vk == user32.VK_CONTROL and !isExtended(lparam);
}

/// Copy `text` into `buf` without C0 controls and DEL. Core encodes those
/// from the key and modifiers; the text must stay out of its way. UTF-8
/// continuation bytes are all >= 0x80, so filtering bytes is safe. Output
/// is truncated to `buf.len`.
pub fn stripControl(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Invalid bytes count as one-byte units; they are copied as is.
        const len = @min(std.unicode.utf8ByteSequenceLength(text[i]) catch 1, text.len - i);
        defer i += len;
        if (len == 1 and (text[i] < 0x20 or text[i] == 0x7F)) continue;
        // Never cut a code point: stop at the first one that does not fit.
        if (n + len > buf.len) break;
        @memcpy(buf[n..][0..len], text[i..][0..len]);
        n += len;
    }
    return buf[0..n];
}

/// Append `src` to `dest` if all of it fits; true when it did. A code
/// point is never cut in the middle.
pub fn appendWhole(dest: []u8, src: []const u8) bool {
    if (src.len > dest.len) return false;
    @memcpy(dest[0..src.len], src);
    return true;
}

/// Whether Alt is held and `vk` is a numpad digit: a step of an Alt+numpad
/// character code. The composed character arrives as a lone WM_CHAR, so
/// the digits themselves are not keys for core.
pub fn isAltNumpadDigit(vk: u16, alt_down: bool) bool {
    return alt_down and vk >= user32.VK_NUMPAD0 and vk <= user32.VK_NUMPAD9;
}

/// Whether Shift stays a modifier of a key that produced `text`. Shift
/// that picked the character (a letter, a symbol) is consumed by it; a key
/// whose text is its unshifted character (the space bar) is unchanged by
/// Shift, so `shift+space` stays a binding.
pub fn shiftConsumed(shift: bool, text: []const u8, unshifted: u21) bool {
    if (!shift or text.len == 0) return false;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return true;
    if (len != text.len) return true;
    const cp = std.unicode.utf8Decode(text) catch return true;
    return cp != unshifted;
}

/// The fake Shift Windows injects around some extended keys (Insert, Home,
/// arrows with NumLock on): scancode E0 2A/E0 36 on a Shift key.
pub fn isFakeShift(lparam: win32.foundation.LPARAM, vk: u16) bool {
    if (vk != user32.VK_SHIFT and vk != user32.VK_LSHIFT and vk != user32.VK_RSHIFT) return false;
    const bits: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((bits >> 16) & 0xFF);
    return bits & (1 << 24) != 0 and (scancode == 0x2A or scancode == 0x36);
}

/// Joins UTF-16 code units, delivered one WM_CHAR at a time, into UTF-8.
/// A high surrogate waits for its low half; an unpaired half becomes
/// U+FFFD.
pub const Utf16Joiner = struct {
    pending_high: ?u16 = null,

    /// The most `feed` writes: U+FFFD for a dropped surrogate followed by
    /// a 3-byte character.
    pub const max_out = 8;

    /// Feed one unit. Null means more input is needed.
    pub fn feed(self: *Utf16Joiner, unit: u16, out: *[max_out]u8) ?[]const u8 {
        var n: usize = 0;

        if (self.pending_high) |high| {
            self.pending_high = null;
            if (std.unicode.utf16IsLowSurrogate(unit)) {
                const cp = std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch unreachable;
                n += std.unicode.utf8Encode(cp, out[n..]) catch unreachable;
                return out[0..n];
            }
            n += encode(0xFFFD, out[n..]);
        }

        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.pending_high = unit;
        } else if (std.unicode.utf16IsLowSurrogate(unit)) {
            n += encode(0xFFFD, out[n..]);
        } else {
            n += encode(unit, out[n..]);
        }

        return if (n == 0) null else out[0..n];
    }

    fn encode(cp: u21, out: []u8) usize {
        return std.unicode.utf8Encode(cp, out) catch unreachable;
    }
};

/// The key event for text that no key of ours produced: `SendInput`
/// unicode (VK_PACKET), WM_UNICHAR, a character without a handled
/// key-down, Alt+numpad. A keyless press carrying the text, like the GTK
/// commit and our IME result. `Surface.textCallback` would turn it into a
/// bracketed paste, which a program that enabled that mode inserts as
/// pasted text instead of typed keys.
pub fn textEvent(text: []const u8) input.KeyEvent {
    return .{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = text,
    };
}

/// Whether a system-key message goes to `DefWindowProc` instead of core:
/// only Alt+F4 (close) and Alt+Space (system menu). Everything else with
/// Alt, and F10, is the terminal's.
pub fn passToSystem(vk: u16, sys: bool, alt_down: bool) bool {
    if (!sys or !alt_down) return false;
    return vk == user32.VK_F4 or vk == user32.VK_SPACE;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

/// Layouts a test loaded, so that exactly those are unloaded afterwards.
const TestLayouts = struct {
    before: [64]user32.HKL = undefined,
    before_len: usize = 0,

    fn init() TestLayouts {
        var self: TestLayouts = .{};
        self.before_len = list(&self.before);
        return self;
    }

    fn list(out: []user32.HKL) usize {
        const n = user32.GetKeyboardLayoutList(@intCast(out.len), out.ptr);
        return if (n < 0) 0 else @intCast(n);
    }

    /// Load a layout by KLID without activating it; null when this
    /// machine cannot.
    fn load(self: *TestLayouts, comptime klid: []const u8) ?user32.HKL {
        _ = self;
        const w = std.unicode.utf8ToUtf16LeStringLiteral(klid);
        return user32.LoadKeyboardLayoutW(w, user32.KLF_NOTELLSHELL);
    }

    fn deinit(self: *TestLayouts) void {
        var now: [64]user32.HKL = undefined;
        const n = list(&now);
        for (now[0..n]) |hkl| {
            const known = for (self.before[0..self.before_len]) |b| {
                if (b == hkl) break true;
            } else false;
            if (!known) _ = user32.UnloadKeyboardLayout(hkl);
        }
    }
};

fn lparamOf(scancode: u32, extended: bool) win32.foundation.LPARAM {
    var bits: usize = scancode << 16;
    if (extended) bits |= 1 << 24;
    return @bitCast(bits);
}

test "win32 key: physical key from extended scancode" {
    try testing.expectEqual(input.Key.arrow_up, physicalKey(lparamOf(0x48, true), user32.VK_UP));
    try testing.expectEqual(input.Key.numpad_8, physicalKey(lparamOf(0x48, false), user32.VK_NUMPAD8));
    try testing.expectEqual(input.Key.key_c, physicalKey(lparamOf(0x2E, false), 'C'));
    try testing.expectEqual(input.Key.control_right, physicalKey(lparamOf(0x1D, true), user32.VK_RCONTROL));
    try testing.expectEqual(input.Key.shift_right, physicalKey(lparamOf(0x36, false), user32.VK_RSHIFT));
    // The fake shifts Windows injects around some extended keys.
    try testing.expectEqual(input.Key.unidentified, physicalKey(lparamOf(0x2A, true), user32.VK_SHIFT));
    try testing.expectEqual(input.Key.unidentified, physicalKey(lparamOf(0x36, true), user32.VK_SHIFT));
    // VK_PACKET carries no scancode.
    try testing.expectEqual(input.Key.unidentified, physicalKey(lparamOf(0, false), user32.VK_PACKET));
}

test "win32 key: Pause vs NumLock" {
    // Windows reports both with scancode 0x45, whatever the extended bit.
    try testing.expectEqual(input.Key.pause, physicalKey(lparamOf(0x45, false), user32.VK_PAUSE));
    try testing.expectEqual(input.Key.pause, physicalKey(lparamOf(0x45, true), user32.VK_PAUSE));
    try testing.expectEqual(input.Key.num_lock, physicalKey(lparamOf(0x45, false), user32.VK_NUMLOCK));
    try testing.expectEqual(input.Key.num_lock, physicalKey(lparamOf(0x45, true), user32.VK_NUMLOCK));
}

test "win32 key: mods from key state" {
    var state: KeyState = @splat(0);
    try testing.expectEqual(input.Mods{}, mods(&state));

    state[user32.VK_RSHIFT] = down_bit;
    state[user32.VK_LCONTROL] = down_bit;
    state[user32.VK_RCONTROL] = down_bit;
    state[user32.VK_RMENU] = down_bit;
    state[user32.VK_LWIN] = down_bit;
    state[user32.VK_CAPITAL] = toggle_bit;
    const m = mods(&state);
    try testing.expect(m.shift and m.ctrl and m.alt and m.super);
    try testing.expect(m.caps_lock and !m.num_lock);
    try testing.expectEqual(input.Mods.Side{
        .shift = .right,
        .ctrl = .left, // both down
        .alt = .right,
        .super = .left,
    }, m.sides);
}

test "win32 key: US has no AltGr, DE has AltGr" {
    var layouts = TestLayouts.init();
    defer layouts.deinit();

    const us = layouts.load("00000409") orelse return error.SkipZigTest;
    const de = layouts.load("00000407") orelse return error.SkipZigTest;
    try testing.expect(!layoutHasAltGr(us));
    try testing.expect(layoutHasAltGr(de));
}

test "win32 key: AltGr consumes ctrl+alt only when text produced" {
    const ctrl_alt: input.Mods = .{ .ctrl = true, .alt = true, .sides = .{ .alt = .right } };

    const with_text = applyAltGr(ctrl_alt, true, true, true);
    try testing.expect(!with_text.mods.ctrl and !with_text.mods.alt);
    try testing.expect(with_text.consumed.ctrl and with_text.consumed.alt);

    const no_text = applyAltGr(ctrl_alt, true, true, false);
    try testing.expectEqual(ctrl_alt, no_text.mods);
    try testing.expectEqual(input.Mods{}, no_text.consumed);

    // No AltGr on the layout, or a left Alt: genuine Ctrl+Alt.
    try testing.expectEqual(ctrl_alt, applyAltGr(ctrl_alt, false, true, true).mods);
    try testing.expectEqual(ctrl_alt, applyAltGr(ctrl_alt, true, false, true).mods);

    // Other modifiers survive.
    const shifted = applyAltGr(.{ .shift = true, .ctrl = true, .alt = true }, true, true, true);
    try testing.expect(shifted.mods.shift);
}

test "win32 key: unshifted codepoint on RU layout is Cyrillic, physical key stays .key_c" {
    var layouts = TestLayouts.init();
    defer layouts.deinit();

    const ru = layouts.load("00000419") orelse return error.SkipZigTest;
    const us = layouts.load("00000409") orelse return error.SkipZigTest;

    try testing.expectEqual(@as(u21, 0x0441), unshiftedCodepoint(ru, 'C', 0x2E));
    try testing.expectEqual(@as(u21, 'c'), unshiftedCodepoint(us, 'C', 0x2E));
    // The physical key is the scancode, whatever the layout.
    try testing.expectEqual(input.Key.key_c, physicalKey(lparamOf(0x2E, false), 'C'));

    // Keys without text.
    try testing.expectEqual(@as(u21, 0), unshiftedCodepoint(us, user32.VK_RETURN, 0x1C));
    try testing.expectEqual(@as(u21, 0), unshiftedCodepoint(us, user32.VK_F1, 0x3B));
}

test "win32 key: dead key reports its accent without disturbing layout state" {
    var layouts = TestLayouts.init();
    defer layouts.deinit();

    const de = layouts.load("00000407") orelse return error.SkipZigTest;
    // The key left of 1 is the circumflex dead key on the German layout.
    const cp = unshiftedCodepoint(de, user32.VK_OEM_5, 0x29);
    try testing.expect(cp == '^' or cp == 0x02C6);
    // Asking twice must not have composed anything.
    try testing.expectEqual(cp, unshiftedCodepoint(de, user32.VK_OEM_5, 0x29));
    try testing.expectEqual(@as(u21, 'e'), unshiftedCodepoint(de, 'E', 0x12));
}

test "win32 key: stripControl removes C0" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("ab", stripControl("a\x03b\x7f", &buf));
    try testing.expectEqualStrings("", stripControl("\r\n\t\x1b\x08", &buf));
    try testing.expectEqualStrings("Жж😀", stripControl("Жж\x01😀", &buf));
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings("ab", stripControl("abc", &tiny));
}

test "win32 key: alt+numpad sequence yields one text event" {
    // Every digit of the code is held back while Alt is down...
    for (user32.VK_NUMPAD0..user32.VK_NUMPAD9 + 1) |vk| {
        try testing.expect(isAltNumpadDigit(@intCast(vk), true));
        try testing.expect(!isAltNumpadDigit(@intCast(vk), false));
    }
    try testing.expect(!isAltNumpadDigit('1', true));
    try testing.expect(!isAltNumpadDigit(user32.VK_RETURN, true));

    // ...and the composed character is the only text that gets through.
    var out: [Utf16Joiner.max_out]u8 = undefined;
    var j: Utf16Joiner = .{};
    try testing.expectEqualStrings("é", j.feed(0xE9, &out).?);
}

test "win32 key: shift+space keeps shift" {
    try testing.expect(!shiftConsumed(true, " ", ' '));
    try testing.expect(shiftConsumed(true, "A", 'a'));
    try testing.expect(shiftConsumed(true, "Ж", 'ж'));
    try testing.expect(shiftConsumed(true, "!", '1'));
    // Unknown unshifted character: the text came from the shift.
    try testing.expect(shiftConsumed(true, "x", 0));
    try testing.expect(!shiftConsumed(false, "a", 'a'));
    try testing.expect(!shiftConsumed(true, "", ' '));
    // A key unchanged by Shift on this layout keeps it.
    try testing.expect(!shiftConsumed(true, "ж", 'ж'));
}

test "win32 key: utf8 buffer never splits a code point" {
    var buf: [4]u8 = undefined;
    // "ab" then a 3-byte character that does not fit in the last 2 bytes.
    try testing.expectEqualStrings("ab", stripControl("ab€", buf[0..4]));
    try testing.expectEqualStrings("a", stripControl("a😀", buf[0..4]));
    try testing.expectEqualStrings("😀", stripControl("😀😀", buf[0..4]));

    var dest: [3]u8 = undefined;
    try testing.expect(!appendWhole(&dest, "ab€"));
    try testing.expect(appendWhole(&dest, "€"));
    try testing.expectEqualStrings("€", &dest);

    // A piece that does not fit leaves the buffer alone, and the drain
    // stops there: a later, smaller piece must not overtake it.
    var small: [3]u8 = undefined;
    var len: usize = 0;
    const pieces = [_][]const u8{ "a", "€", "b" };
    for (pieces) |p| {
        if (appendWhole(small[len..], p)) len += p.len else break;
    }
    try testing.expectEqualStrings("a", small[0..len]);
}

test "win32 key: fake shifts are recognized" {
    try testing.expect(isFakeShift(lparamOf(0x2A, true), user32.VK_SHIFT));
    try testing.expect(isFakeShift(lparamOf(0x36, true), user32.VK_RSHIFT));
    // The real keys are not extended.
    try testing.expect(!isFakeShift(lparamOf(0x2A, false), user32.VK_SHIFT));
    try testing.expect(!isFakeShift(lparamOf(0x36, false), user32.VK_RSHIFT));
    try testing.expect(!isFakeShift(lparamOf(0x2A, true), user32.VK_HOME));
}

test "win32 key: typed text is a keyless press, not a paste" {
    const ev = textEvent("Ж😀");
    try testing.expectEqual(input.Action.press, ev.action);
    try testing.expectEqual(input.Key.unidentified, ev.key);
    try testing.expect(ev.mods.empty());
    try testing.expect(ev.consumed_mods.empty());
    try testing.expect(!ev.composing);
    try testing.expectEqualStrings("Ж😀", ev.utf8);
    try testing.expectEqual(@as(u21, 0), ev.unshifted_codepoint);
}

test "win32 key: surrogate pair joined across two WM_CHAR units" {
    var out: [Utf16Joiner.max_out]u8 = undefined;
    var j: Utf16Joiner = .{};

    try testing.expectEqual(@as(?[]const u8, null), j.feed(0xD83D, &out));
    try testing.expectEqualStrings("😀", j.feed(0xDE00, &out).?);

    // A plain BMP unit passes straight through.
    try testing.expectEqualStrings("Ж", j.feed(0x0416, &out).?);

    // Lone high surrogate followed by a BMP unit: replacement, then the unit.
    try testing.expectEqual(@as(?[]const u8, null), j.feed(0xD83D, &out));
    try testing.expectEqualStrings("\u{FFFD}a", j.feed('a', &out).?);
    try testing.expectEqual(@as(?[]const u8, null), j.feed(0xD83D, &out));
    try testing.expectEqualStrings("\u{FFFD}Ж", j.feed(0x0416, &out).?);
    try testing.expectEqualStrings("\u{FFFD}", j.feed(0xDC00, &out).?);

    // A second high surrogate replaces the dangling first.
    try testing.expectEqual(@as(?[]const u8, null), j.feed(0xD83D, &out));
    try testing.expectEqualStrings("\u{FFFD}", j.feed(0xD83D, &out).?);
    try testing.expectEqualStrings("😀", j.feed(0xDE00, &out).?);

    // A lone low surrogate.
    try testing.expectEqualStrings("\u{FFFD}", j.feed(0xDE00, &out).?);
}

test "win32 key: only Alt+F4 and Alt+Space pass to the system" {
    try testing.expect(passToSystem(user32.VK_F4, true, true));
    try testing.expect(passToSystem(user32.VK_SPACE, true, true));
    // F10 is a system key without Alt: it belongs to the terminal.
    try testing.expect(!passToSystem(user32.VK_F10, true, false));
    try testing.expect(!passToSystem(user32.VK_F10, true, true));
    try testing.expect(!passToSystem('X', true, true));
    try testing.expect(!passToSystem(user32.VK_F4, false, false));
    try testing.expect(!passToSystem(user32.VK_SPACE, false, false));
    try testing.expect(!passToSystem(user32.VK_F4, true, false));
}

test "win32 key: synthetic AltGr left Ctrl is told from a real one" {
    const ctrl_down: KeyMessage = .{
        .is_down = true,
        .vk = user32.VK_CONTROL,
        .lparam = lparamOf(0x1D, false),
        .time = 1000,
    };
    const ralt_down: KeyMessage = .{
        .is_down = true,
        .vk = user32.VK_MENU,
        .lparam = lparamOf(0x38, true),
        .time = 1000,
    };

    // Left Ctrl followed by right Alt at the same time: AltGr.
    try testing.expect(isSyntheticAltGrCtrl(ctrl_down, ralt_down));

    // A real left Ctrl followed by an ordinary key.
    var key_a = ralt_down;
    key_a.vk = 'A';
    key_a.lparam = lparamOf(0x1E, false);
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_down, key_a));
    // Nothing queued.
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_down, null));

    // A real Ctrl then a left Alt, or a right Alt a moment later.
    var lalt = ralt_down;
    lalt.lparam = lparamOf(0x38, false);
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_down, lalt));
    var later = ralt_down;
    later.time = 1001;
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_down, later));
    // The next message is a release.
    var ralt_up = ralt_down;
    ralt_up.is_down = false;
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_down, ralt_up));

    // Right Ctrl and releases are never the synthetic press.
    var rctrl = ctrl_down;
    rctrl.lparam = lparamOf(0x1D, true);
    try testing.expect(!isSyntheticAltGrCtrl(rctrl, ralt_down));
    var ctrl_up = ctrl_down;
    ctrl_up.is_down = false;
    try testing.expect(!isSyntheticAltGrCtrl(ctrl_up, ralt_down));

    // The matching release: only a left Ctrl, only after a swallowed press.
    try testing.expect(isSyntheticAltGrCtrlRelease(user32.VK_CONTROL, lparamOf(0x1D, false), true));
    try testing.expect(!isSyntheticAltGrCtrlRelease(user32.VK_CONTROL, lparamOf(0x1D, false), false));
    try testing.expect(!isSyntheticAltGrCtrlRelease(user32.VK_CONTROL, lparamOf(0x1D, true), true));
    try testing.expect(!isSyntheticAltGrCtrlRelease(user32.VK_MENU, lparamOf(0x38, true), true));
}

test "win32 key: layouts loaded by tests are unloaded afterwards" {
    var before: [64]user32.HKL = undefined;
    const n_before = TestLayouts.list(&before);

    {
        var layouts = TestLayouts.init();
        defer layouts.deinit();
        _ = layouts.load("00000407");
        _ = layouts.load("00000419");
        _ = layouts.load("0000040C");
    }

    var after: [64]user32.HKL = undefined;
    const n_after = TestLayouts.list(&after);
    try testing.expectEqual(n_before, n_after);
    try testing.expectEqualSlices(user32.HKL, before[0..n_before], after[0..n_after]);
}
