//! tmux argv parser for the `tmux.exe` shim: global flags, command name
//! resolution (tmux 3.5a names, aliases and unique prefixes) and per-command
//! getopt templates. std only: also compiled into the main test exe.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error text for a failed parse. `parseGlobal` and `parseCommands` fill it
/// before returning `error.Usage`.
pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    fn print(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = out.len;
    }
};

pub const Global = struct {
    socket_path: ?[]const u8 = null,
    socket_name: ?[]const u8 = null,
    version: bool = false,
    rest: []const []const u8,
};

/// tmux's global template is "2c:CDdf:hlL:NqS:T:uUvV".
pub fn parseGlobal(argv: []const []const u8, diag: *Diag) error{Usage}!Global {
    var g: Global = .{ .rest = argv };
    var i: usize = 0;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len < 2 or arg[0] != '-') break;
        i += 1;
        if (std.mem.eql(u8, arg, "--")) break;
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const c = arg[j];
            switch (c) {
                'c', 'C', 'D', 'T' => {
                    diag.print("-{c} is not supported by Ghostty", .{c});
                    return error.Usage;
                },
                'h' => {
                    diag.print("usage: tmux [-V] [-S socket-path] command [flags]", .{});
                    return error.Usage;
                },
                '2', 'd', 'l', 'N', 'q', 'u', 'U', 'v' => {},
                'V' => g.version = true,
                'f', 'L', 'S' => {
                    var val: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        val = arg[j + 1 ..];
                    } else if (i < argv.len) {
                        val = argv[i];
                        i += 1;
                    } else {
                        diag.print("-{c} expects an argument", .{c});
                        return error.Usage;
                    }
                    switch (c) {
                        'S' => g.socket_path = val,
                        'L' => g.socket_name = val,
                        else => {}, // -f: config file, ignored
                    }
                    break;
                },
                else => {
                    diag.print("unknown option -{c}", .{c});
                    return error.Usage;
                },
            }
        }
    }
    g.rest = argv[i..];
    return g;
}

pub const CommandId = enum {
    split_window,
    respawn_pane,
    kill_pane,
    select_layout,
    resize_pane,
    select_pane,
    set_option,
    display_message,
    list_panes,
    list_windows,
    show_environment,
    load_buffer,
    send_keys,
    capture_pane,
};

pub fn commandName(id: CommandId) []const u8 {
    return switch (id) {
        .split_window => "split-window",
        .respawn_pane => "respawn-pane",
        .kill_pane => "kill-pane",
        .select_layout => "select-layout",
        .resize_pane => "resize-pane",
        .select_pane => "select-pane",
        .set_option => "set-option",
        .display_message => "display-message",
        .list_panes => "list-panes",
        .list_windows => "list-windows",
        .show_environment => "show-environment",
        .load_buffer => "load-buffer",
        .send_keys => "send-keys",
        .capture_pane => "capture-pane",
    };
}

/// tmux 3.5a `cmd-*.c` `.args` templates.
fn template(id: CommandId) []const u8 {
    return switch (id) {
        .split_window => "bc:de:fF:hIl:p:Pt:vZ",
        .respawn_pane => "c:e:kt:",
        .kill_pane => "at:",
        .select_layout => "Enopt:",
        .resize_pane => "DLMRTt:Ux:y:Z",
        .select_pane => "DdegLlMmP:RT:t:UZ",
        .set_option => "aFgopqst:uUw",
        .display_message => "aCc:d:lINpt:F:v",
        .list_panes => "asF:f:t:",
        .list_windows => "F:f:at:",
        .show_environment => "hgst:",
        .load_buffer => "b:t:w",
        .send_keys => "c:FHKlMN:Rt:X",
        .capture_pane => "ab:CeE:JMNpPqS:Tt:",
    };
}

pub const Command = struct {
    id: CommandId,
    flags: std.StaticBitSet(128),
    values: [128]?[]const u8,
    positional: []const []const u8,

    pub fn has(self: *const Command, f: u8) bool {
        return f < 128 and self.flags.isSet(f);
    }

    pub fn value(self: *const Command, f: u8) ?[]const u8 {
        if (f >= 128) return null;
        return self.values[f];
    }
};

const Entry = struct { name: []const u8, alias: ?[]const u8 = null, id: ?CommandId = null };

/// Every tmux 3.5a command, in tmux's (alphabetical) order. Only the 14
/// supported ones carry an id.
const table = [_]Entry{
    .{ .name = "attach-session", .alias = "attach" },
    .{ .name = "bind-key", .alias = "bind" },
    .{ .name = "break-pane", .alias = "breakp" },
    .{ .name = "capture-pane", .alias = "capturep", .id = .capture_pane },
    .{ .name = "choose-buffer" },
    .{ .name = "choose-client" },
    .{ .name = "choose-tree" },
    .{ .name = "clear-history", .alias = "clearhist" },
    .{ .name = "clear-prompt-history", .alias = "clearphist" },
    .{ .name = "clock-mode" },
    .{ .name = "command-prompt" },
    .{ .name = "confirm-before", .alias = "confirm" },
    .{ .name = "copy-mode" },
    .{ .name = "customize-mode" },
    .{ .name = "delete-buffer", .alias = "deleteb" },
    .{ .name = "detach-client", .alias = "detach" },
    .{ .name = "display-menu", .alias = "menu" },
    .{ .name = "display-message", .alias = "display", .id = .display_message },
    .{ .name = "display-panes", .alias = "displayp" },
    .{ .name = "display-popup", .alias = "popup" },
    .{ .name = "find-window", .alias = "findw" },
    .{ .name = "has-session", .alias = "has" },
    .{ .name = "if-shell", .alias = "if" },
    .{ .name = "join-pane", .alias = "joinp" },
    .{ .name = "kill-pane", .alias = "killp", .id = .kill_pane },
    .{ .name = "kill-server" },
    .{ .name = "kill-session" },
    .{ .name = "kill-window", .alias = "killw" },
    .{ .name = "link-window", .alias = "linkw" },
    .{ .name = "list-buffers", .alias = "lsb" },
    .{ .name = "list-clients", .alias = "lsc" },
    .{ .name = "list-commands", .alias = "lscm" },
    .{ .name = "list-keys", .alias = "lsk" },
    .{ .name = "list-panes", .alias = "lsp", .id = .list_panes },
    .{ .name = "list-sessions", .alias = "ls" },
    .{ .name = "list-windows", .alias = "lsw", .id = .list_windows },
    .{ .name = "load-buffer", .alias = "loadb", .id = .load_buffer },
    .{ .name = "lock-client", .alias = "lockc" },
    .{ .name = "lock-server", .alias = "lock" },
    .{ .name = "lock-session", .alias = "locks" },
    .{ .name = "move-pane", .alias = "movep" },
    .{ .name = "move-window", .alias = "movew" },
    .{ .name = "new-session", .alias = "new" },
    .{ .name = "new-window", .alias = "neww" },
    .{ .name = "next-layout", .alias = "nextl" },
    .{ .name = "next-window", .alias = "next" },
    .{ .name = "paste-buffer", .alias = "pasteb" },
    .{ .name = "pipe-pane", .alias = "pipep" },
    .{ .name = "previous-layout", .alias = "prevl" },
    .{ .name = "previous-window", .alias = "prev" },
    .{ .name = "refresh-client", .alias = "refresh" },
    .{ .name = "rename-session", .alias = "rename" },
    .{ .name = "rename-window", .alias = "renamew" },
    .{ .name = "resize-pane", .alias = "resizep", .id = .resize_pane },
    .{ .name = "resize-window", .alias = "resizew" },
    .{ .name = "respawn-pane", .alias = "respawnp", .id = .respawn_pane },
    .{ .name = "respawn-window", .alias = "respawnw" },
    .{ .name = "rotate-window", .alias = "rotatew" },
    .{ .name = "run-shell", .alias = "run" },
    .{ .name = "save-buffer", .alias = "saveb" },
    .{ .name = "select-layout", .alias = "selectl", .id = .select_layout },
    .{ .name = "select-pane", .alias = "selectp", .id = .select_pane },
    .{ .name = "select-window", .alias = "selectw" },
    .{ .name = "send-keys", .alias = "send", .id = .send_keys },
    .{ .name = "send-prefix" },
    .{ .name = "server-access" },
    .{ .name = "set-buffer", .alias = "setb" },
    .{ .name = "set-environment", .alias = "setenv" },
    .{ .name = "set-hook" },
    .{ .name = "set-option", .alias = "set", .id = .set_option },
    .{ .name = "set-window-option", .alias = "setw" },
    .{ .name = "show-buffer", .alias = "showb" },
    .{ .name = "show-environment", .alias = "showenv", .id = .show_environment },
    .{ .name = "show-hooks" },
    .{ .name = "show-messages", .alias = "showmsgs" },
    .{ .name = "show-options", .alias = "show" },
    .{ .name = "show-prompt-history", .alias = "showphist" },
    .{ .name = "show-window-options", .alias = "showw" },
    .{ .name = "source-file", .alias = "source" },
    .{ .name = "split-window", .alias = "splitw", .id = .split_window },
    .{ .name = "start-server", .alias = "start" },
    .{ .name = "suspend-client", .alias = "suspendc" },
    .{ .name = "swap-pane", .alias = "swapp" },
    .{ .name = "swap-window", .alias = "swapw" },
    .{ .name = "switch-client", .alias = "switchc" },
    .{ .name = "unbind-key", .alias = "unbind" },
    .{ .name = "unlink-window", .alias = "unlinkw" },
    .{ .name = "wait-for", .alias = "wait" },
};

/// Mirrors tmux's `cmd_find`: an exact alias or name wins, otherwise a unique
/// name prefix. Resolving to a command outside the supported 14 is "unknown".
fn resolve(name: []const u8, diag: *Diag) error{Usage}!CommandId {
    var found: ?*const Entry = null;
    var ambiguous = false;
    for (&table) |*e| {
        const alias_hit = if (e.alias) |a| std.mem.eql(u8, a, name) else false;
        if (alias_hit or std.mem.eql(u8, e.name, name)) {
            found = e;
            ambiguous = false;
            break;
        }
        if (!std.mem.startsWith(u8, e.name, name)) continue;
        if (found != null) ambiguous = true;
        found = e;
    }
    if (ambiguous) {
        var list: [200]u8 = undefined;
        var n: usize = 0;
        for (&table) |*e| {
            if (!std.mem.startsWith(u8, e.name, name)) continue;
            const sep: []const u8 = if (n == 0) "" else ", ";
            if (n + sep.len + e.name.len > list.len) break;
            @memcpy(list[n..][0..sep.len], sep);
            n += sep.len;
            @memcpy(list[n..][0..e.name.len], e.name);
            n += e.name.len;
        }
        diag.print("ambiguous command: {s}, could be: {s}", .{ name, list[0..n] });
        return error.Usage;
    }
    if (found) |e| {
        if (e.id) |id| return id;
        diag.print("{s}: unsupported by Ghostty", .{e.name});
        return error.Usage;
    }
    diag.print("unknown command: {s}", .{name});
    return error.Usage;
}

fn parseOne(argv: []const []const u8, diag: *Diag) error{Usage}!Command {
    const id = try resolve(argv[0], diag);
    const cmd_name = commandName(id);
    const tmpl = template(id);
    var cmd: Command = .{
        .id = id,
        .flags = .empty,
        .values = @splat(null),
        .positional = &.{},
    };
    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len < 2 or arg[0] != '-') break;
        i += 1;
        if (std.mem.eql(u8, arg, "--")) break;
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const c = arg[j];
            const pos = if (c < 128 and c != ':') std.mem.indexOfScalar(u8, tmpl, c) else null;
            const p = pos orelse {
                diag.print("command {s}: unknown flag -{c}", .{ cmd_name, c });
                return error.Usage;
            };
            cmd.flags.set(c);
            if (p + 1 < tmpl.len and tmpl[p + 1] == ':') {
                if (j + 1 < arg.len) {
                    cmd.values[c] = arg[j + 1 ..];
                } else if (i < argv.len) {
                    cmd.values[c] = argv[i];
                    i += 1;
                } else {
                    diag.print("command {s}: -{c} expects an argument", .{ cmd_name, c });
                    return error.Usage;
                }
                break;
            }
        }
    }
    cmd.positional = argv[i..];
    return cmd;
}

/// Parses one tmux command line (argv without argv[0] and the global flags),
/// split into commands at the argv elements ";".
pub fn parseCommands(
    arena: Allocator,
    argv: []const []const u8,
    diag: *Diag,
) error{ Usage, OutOfMemory }![]Command {
    var out: std.ArrayList(Command) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= argv.len) : (i += 1) {
        if (i < argv.len and !std.mem.eql(u8, argv[i], ";")) continue;
        if (i > start) try out.append(arena, try parseOne(argv[start..i], diag));
        start = i + 1;
    }
    if (out.items.len == 0) {
        diag.print("no command given", .{});
        return error.Usage;
    }
    return out.items;
}

pub const Target = union(enum) { none, pane: u32, window: u32, invalid: []const u8 };

fn parseId(prefix: u8, s: []const u8) ?u32 {
    if (s.len < 2 or s[0] != prefix) return null;
    for (s[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s[1..], 10) catch null;
}

/// "%N" pane, "@N" window, "@N.%M" pane M, "" / null none; else invalid.
pub fn parseTarget(s: ?[]const u8) Target {
    const t = s orelse return .none;
    if (t.len == 0) return .none;
    if (parseId('%', t)) |n| return .{ .pane = n };
    if (parseId('@', t)) |n| return .{ .window = n };
    if (std.mem.indexOfScalar(u8, t, '.')) |dot| {
        if (parseId('@', t[0..dot]) != null) {
            if (parseId('%', t[dot + 1 ..])) |m| return .{ .pane = m };
        }
    }
    return .{ .invalid = t };
}

pub const Size = union(enum) { cells: u32, percent: u8 };

/// "70%" percent (1...100), "30" cells (>= 1), else null.
pub fn parseSize(s: []const u8) ?Size {
    if (s.len == 0) return null;
    if (s[s.len - 1] == '%') {
        const digits = s[0 .. s.len - 1];
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        const n = std.fmt.parseInt(u8, digits, 10) catch return null;
        if (n < 1 or n > 100) return null;
        return .{ .percent = n };
    }
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    if (n == 0) return null;
    return .{ .cells = n };
}

fn expectUsage(argv: []const []const u8, msg: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    try std.testing.expectError(error.Usage, parseCommands(arena_state.allocator(), argv, &d));
    try std.testing.expectEqualStrings(msg, d.message());
}

test "tmux shim cli: global -S then command" {
    var d: Diag = .{};
    const g = try parseGlobal(&.{ "-S", "\\\\.\\pipe\\ghostty-tmux-7-ab", "display-message", "-p", "#{pane_id}" }, &d);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ghostty-tmux-7-ab", g.socket_path.?);
    try std.testing.expectEqual(@as(usize, 3), g.rest.len);
    try std.testing.expectEqualStrings("display-message", g.rest[0]);
    try std.testing.expect(!g.version);

    const bad = parseGlobal(&.{ "-c", "x", "kill-pane" }, &d);
    try std.testing.expectError(error.Usage, bad);
    try std.testing.expectEqualStrings("-c is not supported by Ghostty", d.message());
}

test "tmux shim cli: -V wins" {
    var d: Diag = .{};
    try std.testing.expect((try parseGlobal(&.{"-V"}, &d)).version);
    const g = try parseGlobal(&.{ "-L", "x", "-V" }, &d);
    try std.testing.expect(g.version);
    try std.testing.expectEqualStrings("x", g.socket_name.?);
}

test "tmux shim cli: Claude spawn argv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const cmds = try parseCommands(arena_state.allocator(), &.{
        "split-window", "-d", "-t", "%1", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat",
    }, &d);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    const c = &cmds[0];
    try std.testing.expectEqual(CommandId.split_window, c.id);
    try std.testing.expect(c.has('d') and c.has('h') and c.has('P'));
    try std.testing.expect(!c.has('v'));
    try std.testing.expectEqualStrings("%1", c.value('t').?);
    try std.testing.expectEqualStrings("70%", c.value('l').?);
    try std.testing.expectEqualStrings("#{pane_id}", c.value('F').?);
    try std.testing.expectEqual(@as(usize, 1), c.positional.len);
    try std.testing.expectEqualStrings("cat", c.positional[0]);
}

test "tmux shim cli: -t before -p" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const cmds = try parseCommands(arena_state.allocator(), &.{ "display-message", "-t", "%3", "-p", "#{window_id}" }, &d);
    const c = &cmds[0];
    try std.testing.expectEqualStrings("%3", c.value('t').?);
    try std.testing.expect(c.has('p'));
    try std.testing.expectEqualStrings("#{window_id}", c.positional[0]);
}

test "tmux shim cli: aliases and prefixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const a = arena_state.allocator();
    try std.testing.expectEqual(CommandId.split_window, (try parseCommands(a, &.{"splitw"}, &d))[0].id);
    try std.testing.expectEqual(CommandId.split_window, (try parseCommands(a, &.{"split-w"}, &d))[0].id);
    try std.testing.expectEqual(CommandId.list_panes, (try parseCommands(a, &.{"lsp"}, &d))[0].id);
    try expectUsage(&.{"kill"}, "ambiguous command: kill, could be: kill-pane, kill-server, kill-session, kill-window");
    try expectUsage(&.{"new-session"}, "new-session: unsupported by Ghostty");
    // "show" is tmux's exact alias of show-options: a real, unsupported command.
    try expectUsage(&.{"show"}, "show-options: unsupported by Ghostty");
    try expectUsage(&.{"sho"}, "ambiguous command: sho, could be: show-buffer, show-environment, show-hooks, show-messages, show-options, show-prompt-history, show-window-options");
}

test "tmux shim cli: unknown flag and command" {
    try expectUsage(&.{ "kill-pane", "-Q" }, "command kill-pane: unknown flag -Q");
    try expectUsage(&.{"frobnicate"}, "unknown command: frobnicate");
}

test "tmux shim cli: missing value" {
    try expectUsage(&.{ "split-window", "-t" }, "command split-window: -t expects an argument");
}

test "tmux shim cli: sequence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const cmds = try parseCommands(arena_state.allocator(), &.{ "set-option", "-p", "-t", "%2", "a", "b", ";", "kill-pane", "-t", "%2" }, &d);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(CommandId.set_option, cmds[0].id);
    try std.testing.expectEqual(@as(usize, 2), cmds[0].positional.len);
    try std.testing.expectEqual(CommandId.kill_pane, cmds[1].id);
    try std.testing.expectEqualStrings("%2", cmds[1].value('t').?);
}

test "tmux shim cli: -- ends flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const s = "cd 'C:\\x' && env A=1 'y' -z";
    const cmds = try parseCommands(arena_state.allocator(), &.{ "respawn-pane", "-k", "-t", "%2", "--", s }, &d);
    try std.testing.expect(cmds[0].has('k'));
    try std.testing.expectEqual(@as(usize, 1), cmds[0].positional.len);
    try std.testing.expectEqualStrings(s, cmds[0].positional[0]);
}

test "tmux shim cli: clustered flags and attached values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .{};
    const cmds = try parseCommands(arena_state.allocator(), &.{ "split-window", "-dhPt%4", "-l50%" }, &d);
    const c = &cmds[0];
    try std.testing.expect(c.has('d') and c.has('h') and c.has('P'));
    try std.testing.expectEqualStrings("%4", c.value('t').?);
    try std.testing.expectEqualStrings("50%", c.value('l').?);
}

test "tmux shim cli: targets and sizes" {
    try std.testing.expectEqual(@as(u32, 12), parseTarget("%12").pane);
    try std.testing.expectEqual(@as(u32, 3), parseTarget("@3").window);
    try std.testing.expectEqual(@as(u32, 4), parseTarget("@3.%4").pane);
    try std.testing.expectEqualStrings("0:1", parseTarget("0:1").invalid);
    try std.testing.expect(parseTarget("") == .none);
    try std.testing.expect(parseTarget(null) == .none);
    try std.testing.expectEqual(@as(u8, 70), parseSize("70%").?.percent);
    try std.testing.expectEqual(@as(u32, 30), parseSize("30").?.cells);
    try std.testing.expect(parseSize("0%") == null);
    try std.testing.expect(parseSize("101%") == null);
    try std.testing.expect(parseSize("x") == null);
}

test "tmux shim cli: unsupported real commands, -h and templates" {
    try expectUsage(&.{"has-session"}, "has-session: unsupported by Ghostty");
    try expectUsage(&.{"frobnicate"}, "unknown command: frobnicate");
    var d: Diag = .{};
    try std.testing.expectError(error.Usage, parseGlobal(&.{"-h"}, &d));
    try std.testing.expect(std.mem.startsWith(u8, d.message(), "usage:"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try parseCommands(a, &.{ "list-panes", "-s", "-a" }, &d))[0].has('s'));
    try std.testing.expect((try parseCommands(a, &.{ "capture-pane", "-M" }, &d))[0].has('M'));
    try expectUsage(&.{ "list-windows", "-r" }, "command list-windows: unknown flag -r");
    try expectUsage(&.{ "list-panes", "-O", "x" }, "command list-panes: unknown flag -O");
}
