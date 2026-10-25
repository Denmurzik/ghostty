//! Win32 mouse message handling: buttons with capture, motion, wheel and
//! cursor shapes. Coordinates reach core in physical client pixels, which
//! is what the window messages carry (the process is per-monitor DPI aware).
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_mouse);

/// Must match the class `Surface` registers; used to recognise surfaces
/// when routing wheel messages.
const surface_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

extern "user32" fn GetClassNameW(
    hwnd: win32.foundation.HWND,
    buf: [*]u16,
    max: i32,
) callconv(.winapi) i32;

extern "user32" fn SystemParametersInfoW(
    action: u32,
    param: u32,
    pv: ?*anyopaque,
    win_ini: u32,
) callconv(.winapi) i32;

const SPI_GETWHEELSCROLLLINES = 0x0068;
const SPI_GETWHEELSCROLLCHARS = 0x006C;

/// The "scroll one page" setting, reported as UINT_MAX.
const WHEEL_PAGESCROLL = 0xFFFFFFFF;

/// Lines (or characters) per wheel notch when the system says nothing usable.
const default_scroll_amount = 3;

/// Per-surface mouse state.
pub const State = struct {
    /// The cursor shape core last asked for.
    shape: terminal.MouseShape = .text,

    /// Whether core asked for the cursor to be hidden while typing.
    hidden: bool = false,

    /// Buttons currently held, as a bitmask indexed by `input.MouseButton`.
    /// The window holds mouse capture while this is non-zero.
    captured_buttons: u16 = 0,

    /// Whether a `WM_MOUSELEAVE` notification is armed.
    tracking_leave: bool = false,
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
        user32.WM_MOUSEMOVE => {
            trackLeave(surface);
            sendPos(surface, lparam, currentMods());
            return 0;
        },

        user32.WM_MOUSELEAVE => {
            surface.mouse_state.tracking_leave = false;
            // While a button is held the capture keeps the position
            // flowing; clearing it would break a drag selection.
            if (surface.mouse_state.captured_buttons == 0) {
                cursorPos(surface, .{ .x = -1, .y = -1 }, currentMods());
            }
            return 0;
        },

        user32.WM_LBUTTONDOWN,
        user32.WM_LBUTTONDBLCLK,
        user32.WM_RBUTTONDOWN,
        user32.WM_RBUTTONDBLCLK,
        user32.WM_MBUTTONDOWN,
        user32.WM_MBUTTONDBLCLK,
        user32.WM_XBUTTONDOWN,
        user32.WM_XBUTTONDBLCLK,
        user32.WM_LBUTTONUP,
        user32.WM_RBUTTONUP,
        user32.WM_MBUTTONUP,
        user32.WM_XBUTTONUP,
        => {
            const ev = buttonEvent(msg, wparam) orelse return null;
            handleButton(surface, ev.button, ev.state, lparam);
            // XBUTTON messages are the odd ones out: TRUE means handled.
            return switch (msg) {
                user32.WM_XBUTTONDOWN,
                user32.WM_XBUTTONDBLCLK,
                user32.WM_XBUTTONUP,
                => 1,
                else => 0,
            };
        },

        user32.WM_MOUSEWHEEL, user32.WM_MOUSEHWHEEL => {
            handleWheel(surface, msg, wparam, lparam);
            return 0;
        },

        // Capture taken away (alt-tab, a modal dialog): the button-up
        // will never arrive, so release what core thinks is held.
        user32.WM_CAPTURECHANGED => {
            releaseHeld(surface);
            return 0;
        },

        user32.WM_SETCURSOR => {
            if (user32.loWord(@bitCast(lparam)) != user32.HTCLIENT) return null;
            applyCursor(surface.mouse_state);
            return 1;
        },

        else => return null,
    }
}

/// Re-apply the cursor now. Window messages only update the cursor when
/// the mouse moves, so a shape or visibility action calls this to take
/// effect immediately while the pointer is over the surface.
pub fn refreshCursor(surface: *Surface) void {
    var pt: win32.foundation.POINT = .{ .x = 0, .y = 0 };
    if (win32.user32.GetCursorPos(&pt) == 0) return;
    if (win32.user32.WindowFromPoint(pt) != surface.hwnd) return;
    applyCursor(surface.mouse_state);
}

fn applyCursor(state: State) void {
    if (state.hidden) {
        _ = win32.user32.SetCursor(null);
        return;
    }
    _ = win32.user32.SetCursor(win32.user32.LoadCursorW(null, cursorFor(state.shape)));
}

/// The system cursor (an `IDC_*` resource) for a core cursor shape.
pub fn cursorFor(shape: terminal.MouseShape) *const anyopaque {
    const user32 = win32.user32;
    return switch (shape) {
        .text, .vertical_text => user32.IDC_IBEAM,
        .pointer, .grab, .grabbing => user32.IDC_HAND,
        .help => user32.IDC_HELP,
        .progress => user32.IDC_APPSTARTING,
        .wait => user32.IDC_WAIT,
        .crosshair, .cell => user32.IDC_CROSS,
        .move, .all_scroll => user32.IDC_SIZEALL,
        .no_drop, .not_allowed => user32.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => user32.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => user32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => user32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => user32.IDC_SIZENWSE,
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => user32.IDC_ARROW,
    };
}

/// Convert a wheel delta (`WHEEL_DELTA` = 120 per notch) to core's scroll
/// offset in notches. A delta that is not a whole number of notches comes
/// from a high-resolution wheel or a precision touchpad.
pub fn wheelOffset(delta: i16) struct { offset: f64, precision: bool } {
    const d: f64 = @floatFromInt(delta);
    return .{
        .offset = d / @as(f64, win32.user32.WHEEL_DELTA),
        .precision = @rem(delta, win32.user32.WHEEL_DELTA) != 0,
    };
}

/// Decode a button message into the core button and its state, or null
/// for messages that are not button messages (or an unknown X button).
fn buttonEvent(msg: u32, wparam: win32.foundation.WPARAM) ?struct {
    button: input.MouseButton,
    state: input.MouseButtonState,
} {
    const user32 = win32.user32;
    return switch (msg) {
        user32.WM_LBUTTONDOWN, user32.WM_LBUTTONDBLCLK => .{ .button = .left, .state = .press },
        user32.WM_LBUTTONUP => .{ .button = .left, .state = .release },
        user32.WM_RBUTTONDOWN, user32.WM_RBUTTONDBLCLK => .{ .button = .right, .state = .press },
        user32.WM_RBUTTONUP => .{ .button = .right, .state = .release },
        user32.WM_MBUTTONDOWN, user32.WM_MBUTTONDBLCLK => .{ .button = .middle, .state = .press },
        user32.WM_MBUTTONUP => .{ .button = .middle, .state = .release },
        user32.WM_XBUTTONDOWN, user32.WM_XBUTTONDBLCLK, user32.WM_XBUTTONUP => x: {
            // Back and forward are buttons 8 and 9 in core, as in GTK.
            const button: input.MouseButton = switch (user32.getXButton(wparam)) {
                user32.XBUTTON1 => .eight,
                user32.XBUTTON2 => .nine,
                else => return null,
            };
            break :x .{
                .button = button,
                .state = if (msg == user32.WM_XBUTTONUP) .release else .press,
            };
        },
        else => null,
    };
}

fn buttonBit(button: input.MouseButton) u16 {
    const n: u4 = @intCast(@intFromEnum(button));
    return @as(u16, 1) << n;
}

fn handleButton(
    surface: *Surface,
    button: input.MouseButton,
    state: input.MouseButtonState,
    lparam: win32.foundation.LPARAM,
) void {
    const user32 = win32.user32;
    const ms = &surface.mouse_state;
    const mods = currentMods();

    switch (state) {
        .press => {
            // A click is also the way a surface takes keyboard focus.
            if (user32.GetFocus() != surface.hwnd) _ = user32.SetFocus(surface.hwnd);
            if (ms.captured_buttons == 0) _ = user32.SetCapture(surface.hwnd);
            ms.captured_buttons |= buttonBit(button);
        },
        .release => {
            ms.captured_buttons &= ~buttonBit(button);
            if (ms.captured_buttons == 0) _ = user32.ReleaseCapture();
        },
    }

    // Core acts at the position of its last cursor event, which may be
    // stale (touch, pen, a click right after a focus change).
    sendPos(surface, lparam, mods);

    _ = surface.core_surface.mouseButtonCallback(state, button, mods) catch |err|
        log.warn("mouse button callback failed err={}", .{err});

    // Releasing a drag outside the window: no WM_MOUSELEAVE is coming for
    // a pointer that was already out, so clear the stale hover here.
    if (state == .release and ms.captured_buttons == 0 and !insideClient(surface, lparam)) {
        cursorPos(surface, .{ .x = -1, .y = -1 }, mods);
    }
}

fn insideClient(surface: *Surface, lparam: win32.foundation.LPARAM) bool {
    var rc: win32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (win32.user32.GetClientRect(surface.hwnd, &rc) == 0) return true;
    const x = win32.user32.getXLparam(lparam);
    const y = win32.user32.getYLparam(lparam);
    return x >= rc.left and x < rc.right and y >= rc.top and y < rc.bottom;
}

/// Report a release for every button still held, after capture was lost.
fn releaseHeld(surface: *Surface) void {
    const ms = &surface.mouse_state;
    if (ms.captured_buttons == 0) return;
    const mods = currentMods();
    var held = ms.captured_buttons;
    ms.captured_buttons = 0;

    var n: u4 = 0;
    while (held != 0) : (n += 1) {
        const bit = @as(u16, 1) << n;
        if (held & bit != 0) {
            held &= ~bit;
            const button: input.MouseButton = @enumFromInt(n);
            _ = surface.core_surface.mouseButtonCallback(.release, button, mods) catch |err|
                log.warn("mouse button callback failed err={}", .{err});
        }
    }
}

fn handleWheel(
    surface: *Surface,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) void {
    const user32 = win32.user32;

    // Wheel messages go to the focused window with screen coordinates;
    // the one under the cursor should scroll.
    const screen: win32.foundation.POINT = .{
        .x = user32.getXLparam(lparam),
        .y = user32.getYLparam(lparam),
    };
    if (user32.WindowFromPoint(screen)) |target| {
        if (target != surface.hwnd and isSurfaceWindow(target)) {
            _ = user32.SendMessageW(target, msg, wparam, lparam);
            return;
        }
    }

    const delta = user32.getWheelDelta(wparam);
    const w = wheelOffset(delta);
    const horizontal = msg == user32.WM_MOUSEHWHEEL;

    // Core takes precision scrolls in pixels and discrete ones in notches
    // (applying its own lines-per-notch). A precision delta is turned into
    // the pixels the system's lines-per-notch setting would scroll, so it
    // matches the notch wheel.
    var offset = w.offset;
    if (w.precision) {
        const cell = surface.core_surface.size.cell;
        offset = precisionPixels(
            delta,
            wheelScrollAmount(if (horizontal) SPI_GETWHEELSCROLLCHARS else SPI_GETWHEELSCROLLLINES),
            if (horizontal) cell.width else cell.height,
        );
    }

    // Core's positive y is up, as for the wheel. Its x is inverted: the
    // wheel reports right as positive (GTK makes the same flip).
    surface.core_surface.scrollCallback(
        if (horizontal) -offset else 0,
        if (horizontal) 0 else offset,
        .{ .precision = w.precision },
    ) catch |err| log.warn("scroll callback failed err={}", .{err});
}

/// The pixels a precision wheel delta scrolls: `WHEEL_DELTA` units are one
/// notch, which is `amount` cells of `cell_size` pixels.
fn precisionPixels(delta: i16, amount: u32, cell_size: u32) f64 {
    const notches = @as(f64, @floatFromInt(delta)) / @as(f64, win32.user32.WHEEL_DELTA);
    return notches * @as(f64, @floatFromInt(amount)) * @as(f64, @floatFromInt(cell_size));
}

/// The system's lines (or characters) per wheel notch.
fn wheelScrollAmount(action: u32) u32 {
    var amount: u32 = default_scroll_amount;
    if (SystemParametersInfoW(action, 0, &amount, 0) == 0) return default_scroll_amount;
    if (amount == WHEEL_PAGESCROLL) return default_scroll_amount;
    return amount;
}

fn isSurfaceWindow(hwnd: win32.foundation.HWND) bool {
    var buf: [surface_class_name.len + 1]u16 = undefined;
    const len = GetClassNameW(hwnd, &buf, buf.len);
    if (len <= 0) return false;
    return std.mem.eql(u16, buf[0..@intCast(len)], surface_class_name);
}

/// Ask for a `WM_MOUSELEAVE` once the pointer leaves the client area.
fn trackLeave(surface: *Surface) void {
    const ms = &surface.mouse_state;
    if (ms.tracking_leave) return;
    var tme: win32.user32.TRACKMOUSEEVENT = .{
        .dwFlags = win32.user32.TME_LEAVE,
        .hwndTrack = surface.hwnd,
    };
    if (win32.user32.TrackMouseEvent(&tme) != 0) ms.tracking_leave = true;
}

fn sendPos(surface: *Surface, lparam: win32.foundation.LPARAM, mods: input.Mods) void {
    cursorPos(surface, .{
        .x = @floatFromInt(win32.user32.getXLparam(lparam)),
        .y = @floatFromInt(win32.user32.getYLparam(lparam)),
    }, mods);
}

fn cursorPos(surface: *Surface, pos: apprt.CursorPos, mods: input.Mods) void {
    surface.core_surface.cursorPosCallback(pos, mods) catch |err|
        log.warn("cursor pos callback failed err={}", .{err});
}

fn keyDown(vk: i32) bool {
    return win32.user32.GetKeyState(vk) < 0;
}

fn keyToggled(vk: i32) bool {
    return win32.user32.GetKeyState(vk) & 1 != 0;
}

/// The modifier keys held right now.
fn currentMods() input.Mods {
    const user32 = win32.user32;
    var mods: input.Mods = .{};
    if (keyDown(user32.VK_SHIFT)) {
        mods.shift = true;
        if (keyDown(user32.VK_RSHIFT)) mods.sides.shift = .right;
    }
    if (keyDown(user32.VK_CONTROL)) {
        mods.ctrl = true;
        if (keyDown(user32.VK_RCONTROL)) mods.sides.ctrl = .right;
    }
    if (keyDown(user32.VK_MENU)) {
        mods.alt = true;
        if (keyDown(user32.VK_RMENU)) mods.sides.alt = .right;
    }
    if (keyDown(user32.VK_LWIN) or keyDown(user32.VK_RWIN)) {
        mods.super = true;
        if (keyDown(user32.VK_RWIN)) mods.sides.super = .right;
    }
    mods.caps_lock = keyToggled(user32.VK_CAPITAL);
    mods.num_lock = keyToggled(user32.VK_NUMLOCK);
    return mods;
}

test "win32 mouse: wheel offsets" {
    const testing = std.testing;

    const one = wheelOffset(120);
    try testing.expectEqual(@as(f64, 1.0), one.offset);
    try testing.expect(!one.precision);

    const down = wheelOffset(-240);
    try testing.expectEqual(@as(f64, -2.0), down.offset);
    try testing.expect(!down.precision);

    const fine = wheelOffset(30);
    try testing.expectEqual(@as(f64, 0.25), fine.offset);
    try testing.expect(fine.precision);

    const fine_neg = wheelOffset(-60);
    try testing.expectEqual(@as(f64, -0.5), fine_neg.offset);
    try testing.expect(fine_neg.precision);

    const none = wheelOffset(0);
    try testing.expectEqual(@as(f64, 0), none.offset);
    try testing.expect(!none.precision);
}

test "win32 mouse: precision pixels" {
    const testing = std.testing;

    // Four 30-unit touchpad deltas are one notch: 3 lines of 20 px.
    var total: f64 = 0;
    for (0..4) |_| total += precisionPixels(30, 3, 20);
    try testing.expectEqual(@as(f64, 60), total);
    try testing.expectEqual(precisionPixels(120, 3, 20), total);

    try testing.expectEqual(@as(f64, -15), precisionPixels(-60, 3, 10));
    // The per-notch amount and cell size both scale it.
    try testing.expectEqual(@as(f64, 100), precisionPixels(120, 5, 20));
    try testing.expectEqual(@as(f64, 0), precisionPixels(0, 3, 20));
}

test "win32 mouse: cursor map" {
    const testing = std.testing;
    const user32 = win32.user32;

    try testing.expectEqual(user32.IDC_IBEAM, cursorFor(.text));
    try testing.expectEqual(user32.IDC_IBEAM, cursorFor(.vertical_text));
    try testing.expectEqual(user32.IDC_HAND, cursorFor(.pointer));
    try testing.expectEqual(user32.IDC_HAND, cursorFor(.grab));
    try testing.expectEqual(user32.IDC_HAND, cursorFor(.grabbing));
    try testing.expectEqual(user32.IDC_ARROW, cursorFor(.default));
    try testing.expectEqual(user32.IDC_ARROW, cursorFor(.context_menu));
    try testing.expectEqual(user32.IDC_ARROW, cursorFor(.zoom_in));
    try testing.expectEqual(user32.IDC_CROSS, cursorFor(.crosshair));
    try testing.expectEqual(user32.IDC_WAIT, cursorFor(.wait));
    try testing.expectEqual(user32.IDC_APPSTARTING, cursorFor(.progress));
    try testing.expectEqual(user32.IDC_NO, cursorFor(.not_allowed));
    try testing.expectEqual(user32.IDC_NO, cursorFor(.no_drop));
    try testing.expectEqual(user32.IDC_SIZEALL, cursorFor(.move));
    try testing.expectEqual(user32.IDC_SIZEWE, cursorFor(.col_resize));
    try testing.expectEqual(user32.IDC_SIZEWE, cursorFor(.ew_resize));
    try testing.expectEqual(user32.IDC_SIZENS, cursorFor(.row_resize));
    try testing.expectEqual(user32.IDC_SIZENS, cursorFor(.n_resize));
    try testing.expectEqual(user32.IDC_SIZENESW, cursorFor(.nesw_resize));
    try testing.expectEqual(user32.IDC_SIZENESW, cursorFor(.sw_resize));
    try testing.expectEqual(user32.IDC_SIZENWSE, cursorFor(.nwse_resize));
    try testing.expectEqual(user32.IDC_SIZENWSE, cursorFor(.se_resize));
}

test "win32 mouse: button messages" {
    const testing = std.testing;
    const user32 = win32.user32;

    const l = buttonEvent(user32.WM_LBUTTONDBLCLK, 0).?;
    try testing.expectEqual(input.MouseButton.left, l.button);
    try testing.expectEqual(input.MouseButtonState.press, l.state);

    const r = buttonEvent(user32.WM_RBUTTONUP, 0).?;
    try testing.expectEqual(input.MouseButton.right, r.button);
    try testing.expectEqual(input.MouseButtonState.release, r.state);

    const back = buttonEvent(user32.WM_XBUTTONDOWN, @as(usize, user32.XBUTTON1) << 16).?;
    try testing.expectEqual(input.MouseButton.eight, back.button);
    const fwd = buttonEvent(user32.WM_XBUTTONUP, @as(usize, user32.XBUTTON2) << 16).?;
    try testing.expectEqual(input.MouseButton.nine, fwd.button);
    try testing.expectEqual(input.MouseButtonState.release, fwd.state);

    try testing.expect(buttonEvent(user32.WM_XBUTTONDOWN, @as(usize, 7) << 16) == null);
    try testing.expect(buttonEvent(user32.WM_MOUSEMOVE, 0) == null);
}

test "win32 mouse: button bits" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 0b10), buttonBit(.left));
    try testing.expectEqual(@as(u16, 1 << 9), buttonBit(.nine));
    // Every button fits the mask.
    try testing.expect(buttonBit(.eleven) != 0);
}
