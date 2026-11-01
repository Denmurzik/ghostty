//! Keyboard state machine of the dialog: where the focus is, and what a key
//! does there. Pure; the window feeds it keys and acts on the answer.
//!
//! The focus ring is the list (when the dialog has one), the switch (when it
//! has one) and then the buttons. Enter presses the focused button (the
//! default one when the list or the switch has the focus), Esc and Alt+F4
//! cancel, Tab and Shift+Tab walk the ring and wrap, the arrow keys walk the
//! buttons. Space on the switch is the control's own.
const std = @import("std");

pub const Key = enum { tab, shift_tab, left, right, up, down, home, end, enter, escape, alt_f4 };

pub const Focus = union(enum) {
    list,
    check,
    button: usize,

    pub fn eql(a: Focus, b: Focus) bool {
        return std.meta.eql(a, b);
    }
};

pub const Action = union(enum) {
    /// Not ours: the focused control handles the key itself.
    pass,
    /// Handled, nothing to do.
    none,
    /// Move the focus (and show the keyboard focus rectangle).
    focus: Focus,
    /// Press button `n`.
    activate: usize,
    /// Close with the cancel result.
    cancel,
};

pub const State = struct {
    /// Number of buttons, at least 1.
    count: usize,
    default: usize,
    has_list: bool,
    has_check: bool = false,
    focus: Focus,

    /// The focus starts on the default button.
    pub fn init(count: usize, default: usize, has_list: bool) State {
        return initWith(count, default, has_list, false);
    }

    pub fn initWith(count: usize, default: usize, has_list: bool, has_check: bool) State {
        std.debug.assert(count >= 1);
        const d = if (default < count) default else 0;
        return .{ .count = count, .default = d, .has_list = has_list, .has_check = has_check, .focus = .{ .button = d } };
    }

    /// Where Tab goes from here: the ring is the list if there is one, the
    /// switch if there is one, then the buttons.
    fn ringIndex(self: *const State, f: Focus) usize {
        const before: usize = @as(usize, @intFromBool(self.has_list)) + @intFromBool(self.has_check);
        return switch (f) {
            .list => 0,
            .check => @intFromBool(self.has_list),
            .button => |i| i + before,
        };
    }

    fn ringFocus(self: *const State, idx: usize) Focus {
        var at = idx;
        if (self.has_list) {
            if (at == 0) return .list;
            at -= 1;
        }
        if (self.has_check) {
            if (at == 0) return .check;
            at -= 1;
        }
        return .{ .button = at };
    }

    fn ringLen(self: *const State) usize {
        return self.count + @as(usize, @intFromBool(self.has_list)) + @intFromBool(self.has_check);
    }

    /// Feed one key. The state follows a returned `.focus`.
    pub fn press(self: *State, key: Key) Action {
        switch (key) {
            .escape, .alt_f4 => return .cancel,
            .enter => return .{ .activate = switch (self.focus) {
                .button => |i| i,
                .list, .check => self.default,
            } },
            .tab, .shift_tab => {
                const len = self.ringLen();
                const at = self.ringIndex(self.focus);
                const next = if (key == .tab) (at + 1) % len else (at + len - 1) % len;
                return self.moveTo(self.ringFocus(next));
            },
            .left, .right, .up, .down, .home, .end => {
                const i = switch (self.focus) {
                    .list, .check => return .pass,
                    .button => |i| i,
                };
                const to: usize = switch (key) {
                    .left, .up => (i + self.count - 1) % self.count,
                    .right, .down => (i + 1) % self.count,
                    .home => 0,
                    else => self.count - 1,
                };
                return self.moveTo(.{ .button = to });
            },
        }
    }

    fn moveTo(self: *State, f: Focus) Action {
        self.focus = f;
        return .{ .focus = f };
    }

    /// The focus moved by other means (a click on the list).
    pub fn set(self: *State, f: Focus) void {
        switch (f) {
            .list => if (self.has_list) {
                self.focus = f;
            },
            .check => if (self.has_check) {
                self.focus = f;
            },
            .button => |i| if (i < self.count) {
                self.focus = f;
            },
        }
    }
};

test "win32 dialog keys: enter presses the focused button, esc cancels" {
    var s = State.init(2, 1, false);
    try std.testing.expectEqual(Action{ .activate = 1 }, s.press(.enter));
    try std.testing.expectEqual(Action.cancel, s.press(.escape));
    try std.testing.expectEqual(Action.cancel, s.press(.alt_f4));
    // Neither moves the focus.
    try std.testing.expect(s.focus.eql(.{ .button = 1 }));
}

test "win32 dialog keys: tab cycles and wraps, shift+tab goes back" {
    var s = State.init(3, 0, false);
    try std.testing.expectEqual(Action{ .focus = .{ .button = 1 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 2 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 2 } }, s.press(.shift_tab));
    try std.testing.expectEqual(Action{ .activate = 2 }, s.press(.enter));
}

test "win32 dialog keys: arrows walk the buttons" {
    var s = State.init(3, 0, false);
    try std.testing.expectEqual(Action{ .focus = .{ .button = 1 } }, s.press(.right));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 2 } }, s.press(.down));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.right));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 2 } }, s.press(.left));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.home));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 2 } }, s.press(.end));
}

test "win32 dialog keys: a single button has nowhere to go" {
    var s = State.init(1, 0, false);
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.left));
}

test "win32 dialog keys: the list is part of the ring and keeps its arrows" {
    var s = State.init(2, 0, true);
    // Tab from the first button goes on to the second, then wraps to the list.
    try std.testing.expectEqual(Action{ .focus = .{ .button = 1 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .list }, s.press(.tab));
    // The list handles arrows itself, and Enter there presses the default.
    try std.testing.expectEqual(Action.pass, s.press(.down));
    try std.testing.expectEqual(Action.pass, s.press(.left));
    try std.testing.expectEqual(Action{ .activate = 0 }, s.press(.enter));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .list }, s.press(.shift_tab));
}

test "win32 dialog keys: default out of range falls back to the first button" {
    var s = State.init(2, 7, false);
    try std.testing.expectEqual(Action{ .activate = 0 }, s.press(.enter));
    // A click on the list of a dialog without one changes nothing.
    s.set(.list);
    try std.testing.expect(s.focus.eql(.{ .button = 0 }));
    s.set(.{ .button = 1 });
    try std.testing.expect(s.focus.eql(.{ .button = 1 }));
}

test "win32 dialog keys: the switch sits between the list and the buttons" {
    var s = State.initWith(2, 0, true, true);
    // Buttons first, then the list, then the switch, then back to the buttons.
    try std.testing.expectEqual(Action{ .focus = .{ .button = 1 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .list }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .check }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .check }, s.press(.shift_tab));
    try std.testing.expectEqual(Action{ .focus = .list }, s.press(.shift_tab));
    // Enter on the switch presses the default button, arrows are the control's.
    s.set(.check);
    try std.testing.expectEqual(Action.pass, s.press(.left));
    try std.testing.expectEqual(Action{ .activate = 0 }, s.press(.enter));
    try std.testing.expectEqual(Action.cancel, s.press(.escape));
}

test "win32 dialog keys: a switch without a list" {
    var s = State.initWith(2, 1, false, true);
    try std.testing.expectEqual(Action{ .focus = .check }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 0 } }, s.press(.tab));
    try std.testing.expectEqual(Action{ .focus = .{ .button = 1 } }, s.press(.tab));
    // No switch: `.check` is not accepted.
    var plain = State.init(2, 0, true);
    plain.set(.check);
    try std.testing.expect(plain.focus.eql(.{ .button = 0 }));
}
