//! tmux server namespaces of the external transport (R-M5-14, owner: M5
//! Task 18). A namespace is what `tmux -L <name>` selects: one session, shown
//! as one Ghostty window whose tabs are the tmux windows, named by `-n`.
//! Everything outside the namespace's tabs is out of reach of its client.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// What an external client may create: it controls the names and the number
/// of requests.
pub const max_namespaces = 8;
pub const max_name = 64;
pub const max_tabs = 64;

/// Panes of one namespace, over all its tabs.
pub const max_panes = 64;

pub const Tab = struct {
    /// The tab id (`@N`).
    id: u32,
    /// The tmux window name; owned. Names may repeat, like in tmux.
    name: []const u8,
};

pub const Namespace = struct {
    /// The `-L` name (`default` without `-L`).
    name: []const u8,
    /// The session name; null until `new-session`.
    session: ?[]const u8 = null,
    /// The Ghostty window (`Window.id`) that shows the session, as last seen.
    window_id: ?u32 = null,
    /// The tabs the client owns, in creation order. This list (at most
    /// `max_tabs`) is what ownership, `kill-server` and the limit are about;
    /// the names are a lookup on it.
    tabs: std.ArrayList(Tab) = .empty,

    pub fn deinit(self: *Namespace, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.session) |s| gpa.free(s);
        for (self.tabs.items) |t| gpa.free(t.name);
        self.tabs.deinit(gpa);
    }

    pub fn setSession(self: *Namespace, gpa: Allocator, name: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, name);
        if (self.session) |s| gpa.free(s);
        self.session = copy;
    }

    pub fn addTab(self: *Namespace, gpa: Allocator, name: []const u8, tab_id: u32) error{ OutOfMemory, TooManyTabs }!void {
        if (self.hasTab(tab_id)) return;
        if (self.tabs.items.len >= max_tabs) return error.TooManyTabs;
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try self.tabs.append(gpa, .{ .id = tab_id, .name = copy });
    }

    pub fn count(self: *const Namespace) usize {
        return self.tabs.items.len;
    }

    /// The newest tab of that name.
    pub fn tabByName(self: *const Namespace, name: []const u8) ?u32 {
        var i = self.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.tabs.items[i].name, name)) return self.tabs.items[i].id;
        }
        return null;
    }

    pub fn nameOf(self: *const Namespace, tab_id: u32) ?[]const u8 {
        for (self.tabs.items) |t| if (t.id == tab_id) return t.name;
        return null;
    }

    pub fn hasTab(self: *const Namespace, tab_id: u32) bool {
        return self.nameOf(tab_id) != null;
    }

    /// Forgets the tabs for which `alive(ctx, id)` is false.
    pub fn prune(self: *Namespace, gpa: Allocator, ctx: anytype, comptime alive: fn (@TypeOf(ctx), u32) bool) void {
        var i: usize = 0;
        while (i < self.tabs.items.len) {
            if (alive(ctx, self.tabs.items[i].id)) {
                i += 1;
                continue;
            }
            gpa.free(self.tabs.items[i].name);
            _ = self.tabs.orderedRemove(i);
        }
    }
};

/// Whether `name` can be a namespace or session name: what `-L` and `-s`
/// carry in practice, and nothing that confuses `session:window` targets.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '@') return false;
    }
    return true;
}

pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(*Namespace) = .empty,

    pub fn get(self: *Table, name: []const u8) ?*Namespace {
        return self.map.get(name);
    }

    pub fn ensure(self: *Table, gpa: Allocator, name: []const u8) error{ OutOfMemory, InvalidName, TooManyNamespaces }!*Namespace {
        if (self.map.get(name)) |ns| return ns;
        if (!validName(name)) return error.InvalidName;
        if (self.map.count() >= max_namespaces) return error.TooManyNamespaces;
        const ns = try gpa.create(Namespace);
        errdefer gpa.destroy(ns);
        ns.* = .{ .name = try gpa.dupe(u8, name) };
        errdefer gpa.free(ns.name);
        try self.map.put(gpa, ns.name, ns);
        return ns;
    }

    pub fn drop(self: *Table, gpa: Allocator, name: []const u8) void {
        const kv = self.map.fetchOrderedRemove(name) orelse return;
        kv.value.deinit(gpa);
        gpa.destroy(kv.value);
    }

    pub fn deinit(self: *Table, gpa: Allocator) void {
        for (self.map.values()) |ns| {
            ns.deinit(gpa);
            gpa.destroy(ns);
        }
        self.map.deinit(gpa);
        self.* = .{};
    }
};

test "win32 tmux namespaces: ensure, get, drop" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);

    try std.testing.expect(t.get("a") == null);
    const a = try t.ensure(gpa, "claude-swarm-1");
    try std.testing.expectEqual(a, try t.ensure(gpa, "claude-swarm-1"));
    try std.testing.expectEqualStrings("claude-swarm-1", a.name);
    try a.setSession(gpa, "claude-swarm");
    try a.addTab(gpa, "swarm-view", 7);
    try std.testing.expectEqual(@as(?u32, 7), a.tabByName("swarm-view"));
    try std.testing.expectEqualStrings("swarm-view", a.nameOf(7).?);
    try std.testing.expect(a.hasTab(7) and !a.hasTab(8));

    t.drop(gpa, "claude-swarm-1");
    try std.testing.expect(t.get("claude-swarm-1") == null);
    t.drop(gpa, "claude-swarm-1");
}

test "win32 tmux namespaces: names and limits" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);

    try std.testing.expectError(error.InvalidName, t.ensure(gpa, ""));
    try std.testing.expectError(error.InvalidName, t.ensure(gpa, "a b"));
    try std.testing.expectError(error.InvalidName, t.ensure(gpa, "a:b"));
    const long: [max_name + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidName, t.ensure(gpa, &long));
    var buf: [16]u8 = undefined;
    for (0..max_namespaces) |i| _ = try t.ensure(gpa, try std.fmt.bufPrint(&buf, "n{d}", .{i}));
    try std.testing.expectError(error.TooManyNamespaces, t.ensure(gpa, "one-more"));
}

test "win32 tmux namespaces: duplicate names keep every tab, prune, limit" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const ns = try t.ensure(gpa, "n");
    try ns.addTab(gpa, "a", 1);
    try ns.addTab(gpa, "b", 2);
    try ns.addTab(gpa, "a", 3); // the same name again: a second tab
    try std.testing.expectEqual(@as(usize, 3), ns.count());
    try std.testing.expectEqual(@as(?u32, 3), ns.tabByName("a"));
    try std.testing.expect(ns.hasTab(1));
    try std.testing.expectEqualStrings("a", ns.nameOf(1).?);

    const Alive = struct {
        fn f(keep: u32, id: u32) bool {
            return id == keep;
        }
    };
    ns.prune(gpa, @as(u32, 2), Alive.f);
    try std.testing.expectEqual(@as(usize, 1), ns.count());
    try std.testing.expectEqual(@as(?u32, 2), ns.tabByName("b"));

    var buf: [16]u8 = undefined;
    for (0..max_tabs - 1) |i| try ns.addTab(gpa, try std.fmt.bufPrint(&buf, "t{d}", .{i}), @intCast(i + 10));
    try std.testing.expectError(error.TooManyTabs, ns.addTab(gpa, "overflow", 1000));
}
