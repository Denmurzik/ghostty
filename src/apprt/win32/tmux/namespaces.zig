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

pub const Namespace = struct {
    /// The `-L` name (`default` without `-L`).
    name: []const u8,
    /// The session name; null until `new-session`.
    session: ?[]const u8 = null,
    /// The Ghostty window (`Window.id`) that shows the session.
    window_id: ?u32 = null,
    /// tmux window name -> tab id (`@N`), in creation order. A second window
    /// of the same name replaces the first entry (the first stays reachable
    /// by id).
    tab_names: std.StringArrayHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *Namespace, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.session) |s| gpa.free(s);
        for (self.tab_names.keys()) |k| gpa.free(k);
        self.tab_names.deinit(gpa);
    }

    pub fn setSession(self: *Namespace, gpa: Allocator, name: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, name);
        if (self.session) |s| gpa.free(s);
        self.session = copy;
    }

    pub fn setTab(self: *Namespace, gpa: Allocator, name: []const u8, tab_id: u32) error{ OutOfMemory, TooManyTabs }!void {
        if (self.tab_names.getPtr(name)) |v| {
            v.* = tab_id;
            return;
        }
        if (self.tab_names.count() >= max_tabs) return error.TooManyTabs;
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try self.tab_names.put(gpa, key, tab_id);
    }

    pub fn tabByName(self: *const Namespace, name: []const u8) ?u32 {
        return self.tab_names.get(name);
    }

    /// The name of tab `tab_id`, the newest of several with one id.
    pub fn nameOf(self: *const Namespace, tab_id: u32) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.tab_names.keys(), self.tab_names.values()) |k, v| {
            if (v == tab_id) found = k;
        }
        return found;
    }

    pub fn hasTab(self: *const Namespace, tab_id: u32) bool {
        for (self.tab_names.values()) |v| if (v == tab_id) return true;
        return false;
    }

    /// Forgets the tabs for which `alive(ctx, id)` is false.
    pub fn prune(self: *Namespace, gpa: Allocator, ctx: anytype, comptime alive: fn (@TypeOf(ctx), u32) bool) void {
        var i: usize = 0;
        while (i < self.tab_names.count()) {
            if (alive(ctx, self.tab_names.values()[i])) {
                i += 1;
                continue;
            }
            gpa.free(self.tab_names.keys()[i]);
            self.tab_names.orderedRemoveAt(i);
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
    try a.setTab(gpa, "swarm-view", 7);
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

test "win32 tmux namespaces: prune and tab limit" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const ns = try t.ensure(gpa, "n");
    try ns.setTab(gpa, "a", 1);
    try ns.setTab(gpa, "b", 2);
    try ns.setTab(gpa, "a", 3); // same name: replaced
    try std.testing.expectEqual(@as(usize, 2), ns.tab_names.count());

    const Alive = struct {
        fn f(keep: u32, id: u32) bool {
            return id == keep;
        }
    };
    ns.prune(gpa, @as(u32, 2), Alive.f);
    try std.testing.expectEqual(@as(usize, 1), ns.tab_names.count());
    try std.testing.expectEqual(@as(?u32, 2), ns.tabByName("b"));

    var buf: [16]u8 = undefined;
    for (0..max_tabs - 1) |i| try ns.setTab(gpa, try std.fmt.bufPrint(&buf, "t{d}", .{i}), @intCast(i + 10));
    try std.testing.expectError(error.TooManyTabs, ns.setTab(gpa, "overflow", 1));
}
