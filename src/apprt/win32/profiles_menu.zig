//! Profile menu of the tab strip (right click on "+") and the tray: one
//! "new tab" item per shell profile, a separator, and a "New Window"
//! submenu with the same profiles. Command ids: `0x5000 + 2*i` opens profile
//! `i` in a tab, `0x5001 + 2*i` in a window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const App = @import("App.zig");
const Overrides = @import("Overrides.zig");
const Window = @import("Window.zig");
const profiles = @import("profiles.zig");
const strip_input = @import("strip_input.zig");

const user32 = win32.user32;

const log = std.log.scoped(.win32_profiles_menu);

const MF_POPUP: u32 = 0x00000010;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const first_id: u32 = 0x5000;
/// The tray menu has its own range; its items open windows only.
pub const tray_first_id: u32 = 0x5400;
/// More profiles than this are not listed (keeps the id ranges apart).
pub const max_profiles = 128;

pub const Entry = struct {
    /// UTF-8, with the `&` of the accelerator.
    label: []const u8,
    id: u32,
    profile: usize,
};

pub const Built = struct {
    tab: []Entry,
    window: []Entry,
};

pub fn tabId(index: usize) u32 {
    return first_id + 2 * @as(u32, @intCast(index));
}

pub fn windowId(index: usize) u32 {
    return first_id + 1 + 2 * @as(u32, @intCast(index));
}

pub const Decoded = struct { index: usize, window: bool };

pub fn decode(id: u32) ?Decoded {
    if (id < first_id or id >= first_id + 2 * max_profiles) return null;
    const rel = id - first_id;
    return .{ .index = rel / 2, .window = rel % 2 == 1 };
}

/// The labels and ids of the menu for `list`. The labels of one menu use
/// every accelerator letter at most once; `reserved` letters belong to other
/// items of the same menu ("New &Window" at the top level).
pub fn buildItems(arena: Allocator, list: []const profiles.Profile) !Built {
    const n = @min(list.len, max_profiles);
    const tab = try arena.alloc(Entry, n);
    const window = try arena.alloc(Entry, n);
    var used_tab = Used.initWith("w");
    var used_window = Used.initWith("");
    for (list[0..n], 0..) |p, i| {
        tab[i] = .{ .label = try labelFor(arena, p.name, &used_tab), .id = tabId(i), .profile = i };
        window[i] = .{ .label = try labelFor(arena, p.name, &used_window), .id = windowId(i), .profile = i };
    }
    return .{ .tab = tab, .window = window };
}

const Used = struct {
    set: [128]bool = @splat(false),

    fn initWith(letters: []const u8) Used {
        var u: Used = .{};
        for (letters) |c| u.set[c] = true;
        return u;
    }

    fn take(self: *Used, c: u8) bool {
        const lower = std.ascii.toLower(c);
        if (!std.ascii.isAlphanumeric(lower) or self.set[lower]) return false;
        self.set[lower] = true;
        return true;
    }
};

/// `name` with `&` before a letter nobody has taken: the first letter of a
/// word if possible ("Windows &PowerShell" when W is spoken for), else any.
fn labelFor(arena: Allocator, name: []const u8, used: *Used) ![]const u8 {
    var pick: ?usize = null;
    var word_start = true;
    for (name, 0..) |c, i| {
        if (word_start and used.take(c)) {
            pick = i;
            break;
        }
        word_start = c == ' ';
    }
    if (pick == null) {
        for (name, 0..) |c, i| {
            if (used.take(c)) {
                pick = i;
                break;
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (pick != null and pick.? == i) try out.append(arena, '&');
        // A literal ampersand is doubled.
        if (c == '&') try out.append(arena, '&');
        try out.append(arena, c);
    }
    return out.items;
}

fn appendEntries(menu: user32.HMENU, arena: Allocator, entries: []const Entry) void {
    for (entries) |e| {
        const label = std.unicode.utf8ToUtf16LeAllocZ(arena, e.label) catch continue;
        _ = user32.AppendMenuW(menu, user32.MF_STRING, e.id, label.ptr);
    }
}

pub fn showForStrip(window: *Window, screen_x: i32, screen_y: i32) void {
    const app = window.app;
    strip_input.hideTooltip(window);

    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // The machine may have changed since the last time.
    const list = profiles.refresh(app);
    if (list.len == 0) return;
    const built = buildItems(a, list) catch return;
    // `list` belongs to the cache, which may be rebuilt while the menu runs.
    const ids = a.alloc([]const u8, built.tab.len) catch return;
    for (ids, 0..) |*slot, i| slot.* = a.dupe(u8, list[i].id) catch return;

    const menu = user32.CreatePopupMenu() orelse {
        log.warn("unable to create the profile menu err={}", .{win32.kernel32.GetLastError()});
        return;
    };
    defer _ = user32.DestroyMenu(menu);
    const sub = user32.CreatePopupMenu() orelse return;
    // Owned by `menu` once appended.
    var sub_appended = false;
    defer if (!sub_appended) {
        _ = user32.DestroyMenu(sub);
    };

    appendEntries(menu, a, built.tab);
    _ = user32.AppendMenuW(menu, user32.MF_SEPARATOR, 0, null);
    appendEntries(sub, a, built.window);
    sub_appended = user32.AppendMenuW(menu, MF_POPUP, @intFromPtr(sub), L("New &Window")) != 0;

    // The menu belongs to the foreground window, or it will not close
    // when the user clicks elsewhere.
    _ = user32.SetForegroundWindow(window.hwnd);
    const cmd = user32.TrackPopupMenuEx(
        menu,
        user32.TPM_RETURNCMD | user32.TPM_RIGHTBUTTON,
        screen_x,
        screen_y,
        window.hwnd,
        null,
    );
    // Lets the loop of the menu finish before the next message.
    _ = user32.PostMessageW(window.hwnd, user32.WM_NULL, 0, 0);
    if (cmd <= 0) return;
    const d = decode(@intCast(cmd)) orelse return;
    if (d.index >= ids.len) return;

    // The loop of the menu ran messages: the window may be gone and the
    // profile cache rebuilt. Look both up again.
    for (app.windows.items) |w| if (w == window) {
        for (profiles.get(app)) |p| {
            if (std.mem.eql(u8, p.id, ids[d.index])) {
                launch(app, window, p.id, d.window);
                return;
            }
        }
        return;
    };
}

/// Starts profile `id` in a new tab of `window`, or in a new window.
pub fn launch(app: *App, window: ?*Window, id: []const u8, new_window: bool) void {
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var overrides: Overrides = .{ .profile = a.dupeSentinel(u8, id, 0) catch return };
    overrides.resolve(a, profiles.resolver(app)) catch |err| {
        log.warn("unable to start profile {s} err={}", .{ id, err });
        return;
    };

    if (window) |w| if (!new_window) {
        const parent = if (w.activeTab()) |tab|
            if (tab.focusedSurface()) |s| &s.core_surface else null
        else
            null;
        _ = w.addTab(.{ .parent = parent, .overrides = overrides }) catch |err| {
            log.warn("unable to create a tab err={}", .{err});
            return;
        };
        if (w.activeTab()) |tab| tab.focus();
        return;
    };

    const created = Window.create(app, .{ .overrides = overrides }) catch |err| {
        log.warn("unable to create a window err={}", .{err});
        return;
    };
    created.show();
    created.activate();
}

/// Appends a "New Window with Profile" submenu to the tray menu. The ids
/// start at `first`; returns the next free id.
pub fn appendTrayItems(app: *App, menu: user32.HMENU, first: u32) u32 {
    const list = profiles.refresh(app);
    if (list.len == 0) return first;
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const built = buildItems(a, list) catch return first;

    const sub = user32.CreatePopupMenu() orelse return first;
    var next = first;
    for (built.window) |e| {
        const label = std.unicode.utf8ToUtf16LeAllocZ(a, e.label) catch continue;
        _ = user32.AppendMenuW(sub, user32.MF_STRING, trayId(first, e.profile), label.ptr);
        next = trayId(first, e.profile) + 1;
    }
    if (user32.AppendMenuW(menu, MF_POPUP, @intFromPtr(sub), L("New Window with &Profile")) == 0) {
        _ = user32.DestroyMenu(sub);
    }
    return next;
}

fn trayId(first: u32, index: usize) u32 {
    return first + @as(u32, @intCast(index));
}

pub fn isTrayId(id: u32) bool {
    return id >= tray_first_id and id < tray_first_id + max_profiles;
}

/// Runs a tray menu command of this module; false if `id` is not ours.
pub fn trayCommand(app: *App, id: u32) bool {
    if (!isTrayId(id)) return false;
    const list = profiles.get(app);
    const index = id - tray_first_id;
    if (index < list.len) launch(app, null, list[index].id, true);
    return true;
}

fn testProfile(id: []const u8, name: []const u8) profiles.Profile {
    return .{ .id = id, .name = name, .kind = .cmd, .argv = &.{}, .icon = "" };
}

test "win32 profiles menu: items, ids and unique accelerators" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]profiles.Profile{
        testProfile("default", "Default"),
        testProfile("git-bash", "Git Bash"),
        testProfile("powershell", "Windows PowerShell"),
        testProfile("cmd", "Command Prompt"),
        testProfile("wsl:Ubuntu", "Ubuntu"),
        testProfile("wsl:Debian", "Debian"),
    };
    const built = try buildItems(arena.allocator(), &list);
    try std.testing.expectEqual(@as(usize, 6), built.tab.len);
    try std.testing.expectEqualStrings("&Default", built.tab[0].label);
    try std.testing.expectEqualStrings("&Git Bash", built.tab[1].label);
    // W belongs to "New &Window" at the top level.
    try std.testing.expectEqualStrings("Windows &PowerShell", built.tab[2].label);
    try std.testing.expectEqualStrings("&Command Prompt", built.tab[3].label);
    try std.testing.expectEqual(@as(u32, 0x5000), built.tab[0].id);
    try std.testing.expectEqual(@as(u32, 0x5004), built.tab[2].id);
    try std.testing.expectEqual(@as(u32, 0x5001), built.window[0].id);
    try std.testing.expectEqual(@as(u32, 0x5007), built.window[3].id);
    // In the submenu W is free.
    try std.testing.expectEqualStrings("&Windows PowerShell", built.window[2].label);

    // No accelerator twice in one menu, and the top level never uses W.
    for ([_][]const Entry{ built.tab, built.window }, 0..) |entries, which| {
        var seen: [128]bool = @splat(false);
        for (entries) |e| {
            const at = std.mem.indexOfScalar(u8, e.label, '&') orelse continue;
            const c = std.ascii.toLower(e.label[at + 1]);
            try std.testing.expect(!seen[c]);
            seen[c] = true;
            if (which == 0) try std.testing.expect(c != 'w');
        }
    }

    // Round trip of the ids.
    const d = decode(built.window[3].id).?;
    try std.testing.expectEqual(@as(usize, 3), d.index);
    try std.testing.expect(d.window);
    try std.testing.expect(!decode(built.tab[1].id).?.window);
    try std.testing.expect(decode(0x4fff) == null);
    try std.testing.expect(decode(tray_first_id) == null);
}

test "win32 profiles menu: ampersand in a name and running out of letters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var used: Used = .{};
    try std.testing.expectEqualStrings("&R&&D", try labelFor(arena.allocator(), "R&D", &used));
    // Both letters taken: no accelerator, no crash.
    try std.testing.expectEqualStrings("R", try labelFor(arena.allocator(), "R", &used));
}
