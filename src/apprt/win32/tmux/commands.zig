//! tmux command handlers on the UI thread (owner: M4 task 7).
//!
//! `execute` runs one tmux command line against a duck-typed `Host`
//! (`Registry.Host` in production, `FakeHost` in tests). It owns the tmux
//! semantics: targets, flags, formats, error texts. The host owns panes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../../../tmux_shim/cli.zig");
const format = @import("../../../tmux_shim/format.zig");

pub const Context = struct {
    /// The pane the calling `tmux.exe` runs in (`TMUX_PANE`), if any.
    caller_pane: ?u32,
    cwd: []const u8,
    /// Client environment, "NAME=value" entries.
    env: []const []const u8,
    stdin: ?[]const u8,
    now_ms: u64,
    deadline_ms: u64,
};

/// The most a request may leave in stdout, and the longest error line. A
/// format can expand far past the request (`#{x}` repeated) and it all sits
/// in the UI thread's arena before the reply is framed.
pub const max_output: usize = 1 << 20;
const max_error_line: usize = 4096;

pub const Output = struct {
    code: u8 = 0,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
};

/// -h splits to the right, -v downwards; -b puts the new pane before.
pub const Direction = enum { right, down, left, up };

pub const Spawn = struct {
    command: ?[]const u8,
    cwd: []const u8,
    client_env: []const []const u8,
    /// Every -e VAR=val, in order.
    extra_env: []const []const u8,
    /// -c
    start_dir: ?[]const u8,
};

pub const SplitRequest = struct {
    direction: Direction,
    size: ?cli.Size,
    focus: bool,
    spawn: Spawn,
};

pub const Layout = enum { main_vertical, tiled };

/// tmux would use main-pane-width; Claude follows with `resize-pane -x 30%`.
pub const main_vertical_share: f16 = 0.3;

pub const ResizeRequest = struct { x: ?cli.Size, y: ?cli.Size };

/// R-M4-7: the visible screen only.
pub const CaptureRequest = struct { to_stdout: bool };

pub const SplitError = error{ NoSpace, TooSmall, Unsupported, NoDirectory, SpawnFailed, OutOfMemory };
pub const RespawnError = error{ Unsupported, NoDirectory, SpawnFailed, OutOfMemory };

pub const Vars = struct {
    pane_id: u32,
    window_id: u32,
    window_index: u32,
    window_name: []const u8,
    pane_index: u32,
    pane_active: bool,
    pane_title: []const u8,
    pane_top: u32,
    pane_left: u32,
    pane_width: u32,
    pane_height: u32,
    pane_pid: u32,
    pane_dead: bool,
    pane_current_path: []const u8,
};

pub const Map = std.StringArrayHashMapUnmanaged([]const u8);

/// Longest option value (the client controls it, and `set-option -a` grows it).
pub const max_option_value = 8192;

/// tmux options, owned by the host (`Registry.State` in production).
pub const Options = struct {
    global: Map = .empty,
    windows: std.AutoHashMapUnmanaged(u32, Map) = .empty,
    panes: std.AutoHashMapUnmanaged(u32, Map) = .empty,
    buffer: ?[]u8 = null,

    pub const RemainOnExit = enum { off, on, failed };

    /// pane > window > global; unset or unknown is `off`.
    pub fn remainOnExit(self: *const Options, pane: u32, window: u32) RemainOnExit {
        const v = self.lookup(pane, window, "remain-on-exit") orelse return .off;
        if (std.mem.eql(u8, v, "on")) return .on;
        if (std.mem.eql(u8, v, "failed")) return .failed;
        return .off;
    }

    /// pane > window > global.
    pub fn lookup(self: *const Options, pane: ?u32, window: ?u32, name: []const u8) ?[]const u8 {
        if (pane) |p| if (self.panes.get(p)) |m| if (m.get(name)) |v| return v;
        if (window) |w| if (self.windows.get(w)) |m| if (m.get(name)) |v| return v;
        return self.global.get(name);
    }

    pub fn dropPane(self: *Options, gpa: Allocator, pane: u32) void {
        var kv = self.panes.fetchRemove(pane) orelse return;
        freeMap(gpa, &kv.value);
    }

    pub fn dropWindow(self: *Options, gpa: Allocator, window: u32) void {
        var kv = self.windows.fetchRemove(window) orelse return;
        freeMap(gpa, &kv.value);
    }

    pub fn deinit(self: *Options, gpa: Allocator) void {
        freeMap(gpa, &self.global);
        var wit = self.windows.valueIterator();
        while (wit.next()) |v| freeMap(gpa, v);
        self.windows.deinit(gpa);
        var pit = self.panes.valueIterator();
        while (pit.next()) |v| freeMap(gpa, v);
        self.panes.deinit(gpa);
        if (self.buffer) |b| gpa.free(b);
        self.* = .{};
    }

    pub fn setBuffer(self: *Options, gpa: Allocator, data: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, data);
        if (self.buffer) |b| gpa.free(b);
        self.buffer = copy;
    }

    pub const Scope = union(enum) { global, window: u32, pane: u32 };

    fn mapFor(self: *Options, gpa: Allocator, scope: Scope) Allocator.Error!*Map {
        switch (scope) {
            .global => return &self.global,
            .window => |id| {
                const e = try self.windows.getOrPut(gpa, id);
                if (!e.found_existing) e.value_ptr.* = .empty;
                return e.value_ptr;
            },
            .pane => |id| {
                const e = try self.panes.getOrPut(gpa, id);
                if (!e.found_existing) e.value_ptr.* = .empty;
                return e.value_ptr;
            },
        }
    }

    pub fn set(self: *Options, gpa: Allocator, scope: Scope, name: []const u8, value: []const u8) Allocator.Error!void {
        const map = try self.mapFor(gpa, scope);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        if (map.getEntry(name)) |e| {
            gpa.free(e.value_ptr.*);
            e.value_ptr.* = v;
            return;
        }
        const k = try gpa.dupe(u8, name);
        errdefer gpa.free(k);
        try map.put(gpa, k, v);
    }

    pub fn unset(self: *Options, gpa: Allocator, scope: Scope, name: []const u8) void {
        const map: *Map = switch (scope) {
            .global => &self.global,
            .window => |id| self.windows.getPtr(id) orelse return,
            .pane => |id| self.panes.getPtr(id) orelse return,
        };
        const kv = map.fetchOrderedRemove(name) orelse return;
        gpa.free(kv.key);
        gpa.free(kv.value);
    }

    fn get(self: *Options, scope: Scope, name: []const u8) ?[]const u8 {
        return switch (scope) {
            .global => self.global.get(name),
            .window => |id| if (self.windows.get(id)) |m| m.get(name) else null,
            .pane => |id| if (self.panes.get(id)) |m| m.get(name) else null,
        };
    }
};

/// tmux 3.5a defaults of the options Claude Code (and scripts) ask for.
fn optionDefault(name: []const u8) ?[]const u8 {
    const defaults = [_][2][]const u8{
        .{ "mouse", "off" },
        .{ "focus-events", "off" },
        .{ "allow-passthrough", "off" },
        .{ "status", "on" },
        .{ "status-position", "bottom" },
        .{ "remain-on-exit", "off" },
        .{ "pane-border-status", "off" },
    };
    for (defaults) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
    return null;
}

fn freeMap(gpa: Allocator, map: *Map) void {
    var it = map.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    map.deinit(gpa);
    map.* = .empty;
}

/// Runs the tmux command line `argv` (`cli.Global.rest`: one or more
/// commands separated by ";"). Output and errors go to `out`; the first
/// failing command stops the sequence. All allocations come from `arena`.
pub fn execute(
    comptime Host: type,
    host: *Host,
    arena: Allocator,
    argv: []const []const u8,
    ctx: Context,
    out: *Output,
) Allocator.Error!void {
    if (ctx.now_ms >= ctx.deadline_ms) {
        return failOut(out, arena, "ghostty: server timed out", .{});
    }
    var diag: cli.Diag = .{};
    const cmds = cli.parseCommands(arena, argv, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Usage => return failOut(out, arena, "{s}", .{diag.message()}),
    };
    for (cmds) |*cmd| {
        const env: Env(Host) = .{ .host = host, .arena = arena, .ctx = ctx, .out = out };
        try env.run(cmd);
        if (out.code != 0) return;
    }
}

fn failOut(out: *Output, arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    out.code = 1;
    const s = try std.fmt.allocPrint(arena, fmt ++ "\n", args);
    // An echoed argument can be megabytes long.
    if (s.len > max_error_line) {
        try out.stderr.appendSlice(arena, s[0..max_error_line]);
        try out.stderr.append(arena, '\n');
    } else try out.stderr.appendSlice(arena, s);
}

/// Format variable lookup for `format.expand`.
const Fmt = struct {
    arena: Allocator,
    vars: Vars,
    window_panes: usize,
    options: *const Options,
    oom: bool = false,
    /// What the expansion may still add (`max_output` less the stdout so far).
    budget: usize = max_output,
    too_large: bool = false,

    pub fn lookup(self: *Fmt, name: []const u8) ?[]const u8 {
        const value = self.lookupRaw(name) orelse return null;
        if (value.len > self.budget) {
            self.too_large = true;
            self.budget = 0;
            return null;
        }
        self.budget -= value.len;
        return value;
    }

    fn lookupRaw(self: *Fmt, name: []const u8) ?[]const u8 {
        const v = &self.vars;
        const eql = std.mem.eql;
        if (eql(u8, name, "pane_id")) return self.print("%{d}", .{v.pane_id});
        if (eql(u8, name, "window_id")) return self.print("@{d}", .{v.window_id});
        if (eql(u8, name, "window_index")) return self.print("{d}", .{v.window_index});
        if (eql(u8, name, "window_name")) return v.window_name;
        if (eql(u8, name, "window_panes")) return self.print("{d}", .{self.window_panes});
        if (eql(u8, name, "pane_index")) return self.print("{d}", .{v.pane_index});
        if (eql(u8, name, "pane_active")) return flag(v.pane_active);
        if (eql(u8, name, "pane_title")) return v.pane_title;
        if (eql(u8, name, "pane_top")) return self.print("{d}", .{v.pane_top});
        if (eql(u8, name, "pane_left")) return self.print("{d}", .{v.pane_left});
        if (eql(u8, name, "pane_width")) return self.print("{d}", .{v.pane_width});
        if (eql(u8, name, "pane_height")) return self.print("{d}", .{v.pane_height});
        if (eql(u8, name, "pane_bottom")) return self.print("{d}", .{v.pane_top + v.pane_height -| 1});
        if (eql(u8, name, "pane_right")) return self.print("{d}", .{v.pane_left + v.pane_width -| 1});
        if (eql(u8, name, "pane_pid")) return self.print("{d}", .{v.pane_pid});
        if (eql(u8, name, "pane_dead")) return flag(v.pane_dead);
        if (eql(u8, name, "pane_current_path")) return v.pane_current_path;
        // Fixed answers (Claude's startup probes, recon section 9).
        // They shadow Options: set-option of these names does not change the answer.
        const fixed = [_][2][]const u8{
            .{ "session_name", "0" },
            .{ "session_id", "$0" },
            .{ "client_termtype", "xterm-ghostty" },
            .{ "client_termname", "xterm-ghostty" },
            .{ "allow-passthrough", "off" },
            .{ "focus-events", "0" },
            .{ "status", "on" },
            .{ "status-position", "bottom" },
            .{ "window_bigger", "0" },
            .{ "client_control_mode", "0" },
            .{ "pane_synchronized", "0" },
            .{ "pane_in_mode", "0" },
            .{ "window_zoomed_flag", "0" },
        };
        for (fixed) |kv| if (eql(u8, kv[0], name)) return kv[1];
        return self.options.lookup(v.pane_id, v.window_id, name);
    }

    fn flag(b: bool) []const u8 {
        return if (b) "1" else "0";
    }

    fn print(self: *Fmt, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch {
            self.oom = true;
            return null;
        };
    }
};

fn Env(comptime Host: type) type {
    return struct {
        const Self = @This();
        const Pane = Host.Pane;
        const Window = Host.Window;

        host: *Host,
        arena: Allocator,
        ctx: Context,
        out: *Output,

        fn run(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            switch (cmd.id) {
                .split_window => try self.splitWindow(cmd),
                .respawn_pane => try self.respawnPane(cmd),
                .kill_pane => try self.killPane(cmd),
                .select_layout => try self.selectLayout(cmd),
                .resize_pane => try self.resizePane(cmd),
                .select_pane => try self.selectPane(cmd),
                .set_option => try self.setOption(cmd),
                .display_message => try self.displayMessage(cmd),
                .list_panes => try self.listPanes(cmd),
                .list_windows => try self.listWindows(cmd),
                .show_environment => try self.showEnvironment(cmd),
                .show_options => try self.showOptions(cmd),
                .load_buffer => try self.loadBuffer(cmd),
                .send_keys => try self.sendKeys(cmd),
                .capture_pane => try self.capturePane(cmd),
            }
        }

        fn replyTooLarge(self: Self) Allocator.Error!void {
            self.out.stdout.clearRetainingCapacity();
            return self.fail("ghostty: reply too large", .{});
        }

        fn fail(self: Self, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
            return failOut(self.out, self.arena, fmt, args);
        }

        /// Maps a host error to tmux's text; OutOfMemory propagates.
        fn hostError(self: Self, err: anyerror) Allocator.Error!void {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Unsupported) return self.fail("ghostty: unsupported pane command", .{});
            if (err == error.NoDirectory) return self.fail("can't find directory: {s}", .{self.host.failed_dir});
            if (err == error.NoSpace) return self.fail("no space for new pane", .{});
            if (err == error.TooSmall) return self.fail("create pane failed: pane too small", .{});
            if (err == error.SpawnFailed) return self.fail("create pane failed: could not start the command", .{});
            return self.fail("ghostty: {s}", .{@errorName(err)});
        }

        /// False (after reporting) when the positional count is out of range.
        fn counts(self: Self, cmd: *const cli.Command, min: usize, max: ?usize) Allocator.Error!bool {
            const n = cmd.positional.len;
            if (n < min) {
                try self.fail("command {s}: too few arguments (need at least {d})", .{ cli.commandName(cmd.id), min });
                return false;
            }
            if (max) |m| if (n > m) {
                try self.fail("command {s}: too many arguments (need at most {d})", .{ cli.commandName(cmd.id), m });
                return false;
            };
            return true;
        }

        /// False (after reporting) when one of `flags` is set.
        fn reject(self: Self, cmd: *const cli.Command, flags: []const u8) Allocator.Error!bool {
            for (flags) |c| if (cmd.has(c)) {
                try self.fail("{s}: -{c} is not supported by Ghostty", .{ cli.commandName(cmd.id), c });
                return false;
            };
            return true;
        }

        fn currentPane(self: Self) ?Pane {
            if (self.ctx.caller_pane) |id| if (self.host.findPane(id)) |p| return p;
            return self.host.fallbackPane();
        }

        fn resolvePane(self: Self, t: ?[]const u8) Allocator.Error!?Pane {
            switch (cli.parseTarget(t)) {
                .none => {
                    if (self.currentPane()) |p| return p;
                    try self.fail("no current target", .{});
                },
                .pane => |id| {
                    if (self.host.findPane(id)) |p| return p;
                    try self.fail("can't find pane: {s}", .{t.?});
                },
                .window => |id| {
                    if (self.host.findWindow(id)) |w| return self.host.activePane(w);
                    try self.fail("can't find window: {s}", .{t.?});
                },
                .invalid => |s| try self.fail("can't find pane: {s}", .{s}),
            }
            return null;
        }

        fn resolveWindow(self: Self, t: ?[]const u8) Allocator.Error!?Window {
            switch (cli.parseTarget(t)) {
                .none => {
                    if (self.currentPane()) |p| return self.host.windowOf(p);
                    try self.fail("no current target", .{});
                },
                .pane => |id| {
                    if (self.host.findPane(id)) |p| return self.host.windowOf(p);
                    try self.fail("can't find pane: {s}", .{t.?});
                },
                .window => |id| {
                    if (self.host.findWindow(id)) |w| return w;
                    try self.fail("can't find window: {s}", .{t.?});
                },
                .invalid => |s| try self.fail("can't find window: {s}", .{s}),
            }
            return null;
        }

        fn windowIdOf(self: Self, pane: Pane) u32 {
            return self.host.windowId(self.host.windowOf(pane));
        }

        /// Appends `fmt` expanded for `pane` plus a newline to stdout.
        fn emitLine(self: Self, fmt: []const u8, pane: Pane) Allocator.Error!void {
            const win = self.host.windowOf(pane);
            var f: Fmt = .{
                .arena = self.arena,
                .vars = self.host.vars(pane),
                .window_panes = (try self.host.panes(self.arena, win)).len,
                .options = self.host.options(),
                .budget = max_output -| self.out.stdout.items.len,
            };
            var aw: std.Io.Writer.Allocating = .init(self.arena);
            format.expand(&aw.writer, fmt, &f) catch return error.OutOfMemory;
            if (f.oom) return error.OutOfMemory;
            if (f.too_large or aw.written().len >= max_output -| self.out.stdout.items.len) return self.replyTooLarge();
            try self.out.stdout.appendSlice(self.arena, aw.written());
            try self.out.stdout.append(self.arena, '\n');
        }

        fn parseSizeFlag(self: Self, v: []const u8) Allocator.Error!?cli.Size {
            if (cli.parseSize(v)) |s| return s;
            try self.fail("size invalid: {s}", .{v});
            return null;
        }

        fn joinCommand(self: Self, cmd: *const cli.Command) Allocator.Error!?[]const u8 {
            if (cmd.positional.len == 0) return null;
            return try std.mem.join(self.arena, " ", cmd.positional);
        }

        fn spawnOf(self: Self, cmd: *const cli.Command) Allocator.Error!Spawn {
            const extra = cmd.env_values;
            return .{
                .command = try self.joinCommand(cmd),
                .cwd = self.ctx.cwd,
                .client_env = self.ctx.env,
                .extra_env = extra,
                .start_dir = cmd.value('c'),
            };
        }

        fn splitWindow(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            // -Z is accepted and ignored: Claude never sends it and Spawn has no zoom state.
            if (!try self.reject(cmd, "fI")) return;
            const target = (try self.resolvePane(cmd.value('t'))) orelse return;

            var size: ?cli.Size = null;
            if (cmd.value('l')) |v| size = (try self.parseSizeFlag(v)) orelse return;
            if (cmd.value('p')) |v| {
                const n = std.fmt.parseInt(u8, v, 10) catch 0;
                if (n < 1 or n > 100) return self.fail("size invalid: {s}", .{v});
                size = .{ .percent = n };
            }
            const before = cmd.has('b');
            const direction: Direction = if (cmd.has('h'))
                (if (before) .left else .right)
            else
                (if (before) .up else .down);

            const spawn = try self.spawnOf(cmd);
            const pane = self.host.split(target, .{
                .direction = direction,
                .size = size,
                .focus = !cmd.has('d'),
                .spawn = spawn,
            }) catch |err| return self.hostError(err);

            if (cmd.has('P')) {
                try self.emitLine(cmd.value('F') orelse "#{session_name}:#{window_index}.#{pane_index}", pane);
            }
        }

        fn respawnPane(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            if (!cmd.has('k') and !self.host.exited(pane)) {
                return self.fail("pane %{d} still active", .{self.host.vars(pane).pane_id});
            }
            const spawn = try self.spawnOf(cmd);
            self.host.respawn(pane, spawn) catch |err| return self.hostError(err);
        }

        fn killPane(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.counts(cmd, 0, 0)) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            if (!cmd.has('a')) {
                self.host.kill(pane);
                return;
            }
            // Handles die with the first kill: collect ids, re-resolve each.
            const keep = self.host.vars(pane).pane_id;
            const all = try self.host.panes(self.arena, self.host.windowOf(pane));
            const ids = try self.arena.alloc(u32, all.len);
            for (all, ids) |p, *id| id.* = self.host.vars(p).pane_id;
            for (ids) |id| {
                if (id == keep) continue;
                if (self.host.findPane(id)) |p| self.host.kill(p);
            }
        }

        fn selectLayout(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "Enop")) return;
            if (!try self.counts(cmd, 0, 1)) return;
            const win = (try self.resolveWindow(cmd.value('t'))) orelse return;
            if (cmd.positional.len == 0) return;
            const name = cmd.positional[0];
            const layout: Layout = if (std.mem.eql(u8, name, "main-vertical"))
                .main_vertical
            else if (std.mem.eql(u8, name, "tiled"))
                .tiled
            else
                return; // other layouts: accepted, no change
            self.host.layout(win, layout) catch |err| return self.hostError(err);
        }

        fn resizePane(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "LRUDMT")) return;
            if (!try self.counts(cmd, 0, 0)) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            if (cmd.has('Z')) {
                self.host.toggleZoom(pane);
                return;
            }
            var req: ResizeRequest = .{ .x = null, .y = null };
            if (cmd.value('x')) |v| req.x = (try self.parseSizeFlag(v)) orelse return;
            if (cmd.value('y')) |v| req.y = (try self.parseSizeFlag(v)) orelse return;
            if (req.x == null and req.y == null) return;
            self.host.resize(pane, req) catch |err| return self.hostError(err);
        }

        fn selectPane(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "LRUDlmMZ")) return;
            if (!try self.counts(cmd, 0, 0)) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            if (cmd.value('T')) |title| {
                self.host.setTitle(pane, title) catch |err| return self.hostError(err);
                self.host.optionsChanged(self.windowIdOf(pane));
                return;
            }
            self.host.focus(pane);
        }

        fn setOption(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "U")) return;
            if (!try self.counts(cmd, 1, 2)) return;
            const name = cmd.positional[0];
            const value: []const u8 = if (cmd.positional.len > 1) cmd.positional[1] else "";

            const t = cmd.value('t');
            var scope: Options.Scope = .global;
            var window_id: ?u32 = null;
            if (cmd.has('p') or (!cmd.has('w') and !cmd.has('g') and !cmd.has('s') and cli.parseTarget(t) == .pane)) {
                const pane = (try self.resolvePane(t)) orelse return;
                scope = .{ .pane = self.host.vars(pane).pane_id };
                window_id = self.windowIdOf(pane);
            } else if (cmd.has('w') and !cmd.has('g')) {
                const win = (try self.resolveWindow(t)) orelse return;
                window_id = self.host.windowId(win);
                scope = .{ .window = window_id.? };
            } else if (self.currentPane()) |p| {
                window_id = self.windowIdOf(p);
            }

            const gpa = self.host.gpa();
            const opts = self.host.options();
            if (cmd.has('u')) {
                opts.unset(gpa, scope, name);
            } else if (cmd.has('a')) {
                const old = opts.get(scope, name) orelse "";
                if (old.len + value.len > max_option_value) {
                    return self.fail("ghostty: option value too long (at most {d} bytes)", .{max_option_value});
                }
                const joined = try std.mem.concat(self.arena, u8, &.{ old, value });
                try opts.set(gpa, scope, name, joined);
            } else {
                if (value.len > max_option_value) {
                    return self.fail("ghostty: option value too long (at most {d} bytes)", .{max_option_value});
                }
                try opts.set(gpa, scope, name, value);
            }
            if (window_id) |w| self.host.optionsChanged(w);
        }

        fn displayMessage(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "aICcl")) return;
            if (!try self.counts(cmd, 0, 1)) return;
            if (!cmd.has('p')) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            const fmt: []const u8 = if (cmd.positional.len > 0)
                cmd.positional[0]
            else
                cmd.value('F') orelse "[#{session_name}] #{window_index}:#{window_name}, current pane #{pane_index}";
            try self.emitLine(fmt, pane);
        }

        fn listPanes(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "f")) return;
            if (!try self.counts(cmd, 0, 0)) return;
            const fmt = cmd.value('F') orelse "#{pane_index}: [#{pane_width}x#{pane_height}] #{pane_id}";
            if (cmd.has('a') or cmd.has('s')) {
                for (try self.host.windows(self.arena)) |w| {
                    for (try self.host.panes(self.arena, w)) |p| {
                        try self.emitLine(fmt, p);
                        if (self.out.code != 0) return;
                    }
                }
                return;
            }
            const win = (try self.resolveWindow(cmd.value('t'))) orelse return;
            for (try self.host.panes(self.arena, win)) |p| {
                try self.emitLine(fmt, p);
                if (self.out.code != 0) return;
            }
        }

        fn listWindows(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "f")) return;
            if (!try self.counts(cmd, 0, 0)) return;
            const fmt = cmd.value('F') orelse "#{window_index}: #{window_name} (#{window_panes} panes) #{window_id}";
            // tmux lists the target's session (-a: all sessions): every window here.
            for (try self.host.windows(self.arena)) |w| {
                try self.emitLine(fmt, self.host.activePane(w));
                if (self.out.code != 0) return;
            }
        }

        fn showEnvironment(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.counts(cmd, 0, 1)) return;
            // The environment is empty: any named variable is unknown.
            if (cmd.positional.len == 1) return self.fail("unknown variable: {s}", .{cmd.positional[0]});
        }

        /// `show-options [-AgpqvwH] [-t target] [name]`. Values come from the options
        /// the client set; unset names answer tmux's defaults (so `show -Av mouse` is `off`).
        fn showOptions(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "H")) return;
            if (!try self.counts(cmd, 0, 1)) return;
            const opts = self.host.options();
            const t = cmd.value('t');

            var pane_id: ?u32 = null;
            var window_id: ?u32 = null;
            var scope: Options.Scope = .global;
            if (cmd.has('p') and !cmd.has('g')) {
                const pane = (try self.resolvePane(t)) orelse return;
                pane_id = self.host.vars(pane).pane_id;
                window_id = self.windowIdOf(pane);
                scope = .{ .pane = pane_id.? };
            } else if (cmd.has('w') and !cmd.has('g')) {
                const win = (try self.resolveWindow(t)) orelse return;
                window_id = self.host.windowId(win);
                scope = .{ .window = window_id.? };
            } else if (cmd.has('A')) {
                if (self.currentPane()) |p| {
                    pane_id = self.host.vars(p).pane_id;
                    window_id = self.windowIdOf(p);
                }
            }

            if (cmd.positional.len == 1) {
                const name = cmd.positional[0];
                const value: ?[]const u8 = if (cmd.has('A') or scope == .global)
                    opts.lookup(pane_id, window_id, name) orelse optionDefault(name)
                else
                    opts.get(scope, name);
                if (value) |v| try self.emitOption(cmd, name, v);
                return;
            }
            const map: ?*const Map = switch (scope) {
                .global => &opts.global,
                .window => |id| opts.windows.getPtr(id),
                .pane => |id| opts.panes.getPtr(id),
            };
            if (map) |m| {
                var it = m.iterator();
                while (it.next()) |e| {
                    try self.emitOption(cmd, e.key_ptr.*, e.value_ptr.*);
                    if (self.out.code != 0) return;
                }
            }
        }

        fn emitOption(self: Self, cmd: *const cli.Command, name: []const u8, value: []const u8) Allocator.Error!void {
            const out = &self.out.stdout;
            if (name.len + value.len + 3 > max_output -| out.items.len) return self.replyTooLarge();
            if (cmd.has('v')) {
                try out.appendSlice(self.arena, value);
            } else {
                try out.appendSlice(self.arena, name);
                try out.append(self.arena, ' ');
                const quote = value.len == 0 or std.mem.indexOfScalar(u8, value, ' ') != null;
                if (quote) try out.append(self.arena, '"');
                try out.appendSlice(self.arena, value);
                if (quote) try out.append(self.arena, '"');
            }
            try out.append(self.arena, '\n');
        }

        fn loadBuffer(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.counts(cmd, 1, 1)) return;
            const data = self.ctx.stdin;
            if (!std.mem.eql(u8, cmd.positional[0], "-") or data == null) {
                return self.fail("load-buffer: only stdin (-) is supported by Ghostty", .{});
            }
            try self.host.options().setBuffer(self.host.gpa(), data.?);
            // Like OSC 52 through tmux, the clipboard follows clipboard-write; the
            // buffer is kept either way.
            if (cmd.has('w') and self.host.clipboardWriteAllowed()) {
                self.host.setClipboard(data.?) catch |err| return self.hostError(err);
            }
        }

        fn sendKeys(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "RXMKc")) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            var repeat: u32 = 1;
            if (cmd.value('N')) |v| {
                repeat = std.fmt.parseInt(u32, v, 10) catch 0;
                if (repeat == 0) return self.fail("repeat count invalid: {s}", .{v});
            }
            self.host.sendKeys(pane, cmd.positional, cmd.has('l'), cmd.has('H'), repeat) catch |err| {
                if (err == error.UnknownKey) return self.fail("unknown key", .{});
                if (err == error.TooLarge) return self.fail("ghostty: request too large", .{});
                return self.hostError(err);
            };
        }

        fn capturePane(self: Self, cmd: *const cli.Command) Allocator.Error!void {
            if (!try self.reject(cmd, "abCeMPT")) return;
            if (!try self.counts(cmd, 0, 0)) return;
            const pane = (try self.resolvePane(cmd.value('t'))) orelse return;
            // Visible screen only (R-M4-7): a range is tolerated, like tmux's
            // lenience, but not honoured.
            if (cmd.has('S') or cmd.has('E')) {
                try self.out.stderr.appendSlice(self.arena, "capture-pane: -S and -E are ignored, only the visible screen is captured\n");
            }
            var aw: std.Io.Writer.Allocating = .init(self.arena);
            self.host.capture(pane, .{ .to_stdout = cmd.has('p') }, &aw.writer) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return self.hostError(err);
            };
            if (cmd.has('p')) {
                if (aw.written().len >= max_output -| self.out.stdout.items.len) return self.replyTooLarge();
                try self.out.stdout.appendSlice(self.arena, aw.written());
            } else {
                try self.host.options().setBuffer(self.host.gpa(), aw.written());
            }
        }
    };
}

// Tests

const FakeHost = @import("FakeHost.zig");
const testing = std.testing;

const static_fixture = @embedFile("testdata/claude-spawn.static.jsonl");
const live_fixture = @embedFile("testdata/claude-spawn.jsonl");

const Rig = struct {
    host: FakeHost,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Rig {
        return .{
            .host = try FakeHost.init(testing.allocator),
            .arena_state = .init(testing.allocator),
        };
    }

    fn deinit(self: *Rig) void {
        self.host.deinit();
        self.arena_state.deinit();
    }

    fn arena(self: *Rig) Allocator {
        return self.arena_state.allocator();
    }

    fn ctxWith(stdin: ?[]const u8) Context {
        return .{
            .caller_pane = 1,
            .cwd = "C:\\work",
            .env = &.{},
            .stdin = stdin,
            .now_ms = 0,
            .deadline_ms = 1000,
        };
    }

    fn runCtx(self: *Rig, ctx: Context, args: []const []const u8) !Output {
        var out: Output = .{};
        try execute(FakeHost, &self.host, self.arena(), args, ctx, &out);
        return out;
    }

    fn run(self: *Rig, args: []const []const u8) !Output {
        return self.runCtx(ctxWith(null), args);
    }

    /// Runs and requires exit 0; returns stdout.
    fn ok(self: *Rig, args: []const []const u8) ![]const u8 {
        const out = try self.run(args);
        if (out.code != 0) std.debug.print("unexpected failure: {s}\n", .{out.stderr.items});
        try testing.expectEqual(@as(u8, 0), out.code);
        return out.stdout.items;
    }

    /// Runs, requires exit 1 and stderr containing `needle`.
    fn bad(self: *Rig, args: []const []const u8, needle: []const u8) !void {
        const out = try self.run(args);
        try testing.expectEqual(@as(u8, 1), out.code);
        if (std.mem.indexOf(u8, out.stderr.items, needle) == null) {
            std.debug.print("stderr {s} lacks {s}\n", .{ out.stderr.items, needle });
            return error.TestExpectedEqual;
        }
    }
};

const FixtureLine = struct {
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
};

const IdMap = struct {
    panes: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    windows: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    pending_pane: ?u32 = null,
    pending_window: ?u32 = null,

    fn map(self: *IdMap, sigil: u8) *std.AutoHashMapUnmanaged(u32, u32) {
        return if (sigil == '%') &self.panes else &self.windows;
    }

    const Id = struct { sigil: u8, n: u32 };

    /// "%12" / "@3" as a whole string.
    fn parseId(s: []const u8) ?Id {
        if (s.len < 2 or (s[0] != '%' and s[0] != '@')) return null;
        const n = std.fmt.parseInt(u32, s[1..], 10) catch return null;
        return .{ .sigil = s[0], .n = n };
    }

    /// Rewrites an argv element that is exactly an id; binds unknown ids to
    /// the id the last answer created.
    fn rewrite(self: *IdMap, arena: Allocator, s: []const u8) !?[]const u8 {
        const id = parseId(s) orelse return null;
        const m = self.map(id.sigil);
        const live = m.get(id.n) orelse blk: {
            const pend = if (id.sigil == '%') &self.pending_pane else &self.pending_window;
            const p = pend.* orelse return error.UnboundFixtureId;
            pend.* = null;
            try m.put(arena, id.n, p);
            break :blk p;
        };
        return try std.fmt.allocPrint(arena, "{c}{d}", .{ id.sigil, live });
    }

    /// Compares `got` with the fixture answer `want`; ids in `want` map to
    /// live ids (binding unknown ones on first sight).
    fn matches(self: *IdMap, arena: Allocator, want: []const u8, got: []const u8) !bool {
        var i: usize = 0;
        var j: usize = 0;
        while (i < want.len) {
            const c = want[i];
            if ((c == '%' or c == '@') and i + 1 < want.len and std.ascii.isDigit(want[i + 1])) {
                var e = i + 1;
                while (e < want.len and std.ascii.isDigit(want[e])) e += 1;
                const fid = try std.fmt.parseInt(u32, want[i + 1 .. e], 10);
                if (j >= got.len or got[j] != c) return false;
                var ge = j + 1;
                while (ge < got.len and std.ascii.isDigit(got[ge])) ge += 1;
                if (ge == j + 1) return false;
                const lid = try std.fmt.parseInt(u32, got[j + 1 .. ge], 10);
                const m = self.map(c);
                if (m.get(fid)) |bound| {
                    if (bound != lid) return false;
                } else try m.put(arena, fid, lid);
                i = e;
                j = ge;
            } else {
                if (j >= got.len or got[j] != c) return false;
                i += 1;
                j += 1;
            }
        }
        return j == got.len;
    }
};

fn leafId(tree: *const FakeHost.Tree, h: FakeHost.Tree.Node.Handle) u32 {
    return tree.nodes[h.idx()].leaf.id;
}

test "win32 tmux commands: replay Claude spawn fixture" {
    try replayFixture(static_fixture);
}

test "win32 tmux commands: replay live Claude spawn capture" {
    try replayFixture(live_fixture);
}

fn replayFixture(text: []const u8) !void {
    var rig = try Rig.init();
    defer rig.deinit();
    const arena = rig.arena();

    var ids: IdMap = .{};
    try ids.panes.put(arena, 1, 1); // fixture leader %1 is the fake leader
    var teardown_checked = false;
    var lines_run: usize = 0;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (std.mem.trim(u8, raw, " \r\t").len == 0) continue;
        const line = try std.json.parseFromSliceLeaky(FixtureLine, arena, raw, .{ .ignore_unknown_fields = true });
        var argv = line.argv;
        if (argv.len > 0 and (std.mem.eql(u8, argv[0], "tmux") or std.mem.endsWith(u8, argv[0], "tmux.exe"))) argv = argv[1..];

        var diag: cli.Diag = .{};
        const g = try cli.parseGlobal(argv, &diag);
        const rest = try arena.alloc([]const u8, g.rest.len);
        for (g.rest, rest) |s, *d| d.* = (try ids.rewrite(arena, s)) orelse s;

        if (rest.len == 0) return error.FixtureLineWithoutCommand;
        if (!teardown_checked and std.mem.eql(u8, rest[0], "kill-pane")) {
            teardown_checked = true;
            try expectSpawnedTree(&rig, &ids);
        }

        var stdin: ?[]const u8 = null;
        if (line.stdin) |s| {
            const n = try std.fmt.parseInt(usize, s[0 .. std.mem.indexOfScalar(u8, s, ' ') orelse s.len], 10);
            const buf = try arena.alloc(u8, n);
            @memset(buf, 'x');
            stdin = buf;
        }

        const out = try rig.runCtx(Rig.ctxWith(stdin), rest);
        if (out.code != 0) std.debug.print("line failed: {s}\nstderr: {s}\n", .{ raw, out.stderr.items });
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqual(@as(usize, 0), out.stderr.items.len);

        if (line.stdout) |want| {
            if (!try ids.matches(arena, want, out.stdout.items)) {
                std.debug.print("line: {s}\nwant: {s}\ngot:  {s}\n", .{ raw, want, out.stdout.items });
                return error.TestExpectedEqual;
            }
        } else if (IdMap.parseId(std.mem.trimEnd(u8, out.stdout.items, "\n"))) |id| {
            // A live capture without answers: the next unseen fixture id gets it.
            if (id.sigil == '%') ids.pending_pane = id.n else ids.pending_window = id.n;
        }
        lines_run += 1;
    }

    try testing.expect(lines_run >= 20);
    try testing.expect(teardown_checked);
    // The cleanup lines left only the leader.
    const left = try rig.host.paneIds(arena, 0);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(@as(u32, 1), left[0]);
}

/// leader | (alpha / beta) at 30%, titles, remain-on-exit, respawn commands.
fn expectSpawnedTree(rig: *Rig, ids: *IdMap) !void {
    const alpha = ids.panes.get(2).?;
    const beta = ids.panes.get(3).?;
    const win = ids.windows.get(1).?;
    const tree = rig.host.treeOf(win);

    const root = tree.nodes[0].split;
    try testing.expectEqual(FakeHost.Tree.Split.Layout.horizontal, root.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.30), @as(f32, root.ratio), 0.005);
    try testing.expectEqual(@as(u32, 1), leafId(tree, root.left));
    const right = tree.nodes[root.right.idx()].split;
    try testing.expectEqual(FakeHost.Tree.Split.Layout.vertical, right.layout);
    try testing.expectEqual(alpha, leafId(tree, right.left));
    try testing.expectEqual(beta, leafId(tree, right.right));

    for ([_]u32{ alpha, beta }) |p| {
        try testing.expect(rig.host.titleOf(p).len > 0);
        try testing.expectEqual(Options.RemainOnExit.failed, rig.host.opts.remainOnExit(p, win));
        const r = rig.host.spawnsOf(p, .respawn, 0).?;
        try testing.expect(std.mem.startsWith(u8, r.command.?, "cd '"));
    }
    try testing.expectEqualStrings("alpha", rig.host.titleOf(alpha));
    try testing.expectEqualStrings("beta", rig.host.titleOf(beta));
}

test "win32 tmux commands: show-options answers tmux defaults and set values" {
    var rig = try Rig.init();
    defer rig.deinit();
    try testing.expectEqualStrings("off\n", try rig.ok(&.{ "show", "-Av", "mouse" }));
    try testing.expectEqualStrings("off\n", try rig.ok(&.{ "show", "-gv", "focus-events" }));
    try testing.expectEqualStrings("mouse off\n", try rig.ok(&.{ "show-options", "-g", "mouse" }));
    _ = try rig.ok(&.{ "set-option", "-g", "mouse", "on" });
    try testing.expectEqualStrings("on\n", try rig.ok(&.{ "show", "-Av", "mouse" }));
    _ = try rig.ok(&.{ "set-option", "-g", "status-left", "a b" });
    try testing.expectEqualStrings("mouse on\nstatus-left \"a b\"\n", try rig.ok(&.{ "show", "-g" }));
    try testing.expectEqualStrings("", try rig.ok(&.{ "show", "-gv", "no-such-option" }));
    try rig.bad(&.{ "show", "-H" }, "-H is not supported");
}

test "win32 tmux commands: split refuses below two cells" {
    var rig = try Rig.init();
    defer rig.deinit();
    // 99 cells of a 996 px span leave 6 px: below two cells.
    try rig.bad(&.{ "split-window", "-h", "-l", "99", "-t", "%1" }, "no space for new pane");
    try rig.bad(&.{ "split-window", "-h", "-l", "100%", "-t", "%1" }, "create pane failed: pane too small");
    try testing.expectEqual(@as(usize, 1), (try rig.host.paneIds(rig.arena(), 0)).len);
    // Injected host errors map to tmux's texts.
    rig.host.inject_split = error.NoSpace;
    try rig.bad(&.{ "split-window", "-t", "%1" }, "no space for new pane");
    rig.host.inject_split = error.TooSmall;
    try rig.bad(&.{ "split-window", "-t", "%1" }, "create pane failed: pane too small");
}

test "win32 tmux commands: kill-pane twice and kill of a pane in a closed tab" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%1" });
    _ = try rig.ok(&.{ "kill-pane", "-t", "%2" });
    try rig.bad(&.{ "kill-pane", "-t", "%2" }, "can't find pane: %2");

    const other = try rig.host.addWindow();
    try testing.expectEqual(@as(usize, 2), rig.host.windowCount());
    const target = try std.fmt.allocPrint(rig.arena(), "%{d}", .{other});
    _ = try rig.ok(&.{ "kill-pane", "-t", target });
    try testing.expectEqual(@as(usize, 1), rig.host.windowCount());
    try rig.bad(&.{ "kill-pane", "-t", target }, "can't find pane");
    try rig.bad(&.{ "list-panes", "-t", "@2" }, "can't find window: @2");
}

test "win32 tmux commands: kill-pane -a keeps only the target" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%1" });
    _ = try rig.ok(&.{ "split-window", "-d", "-v", "-t", "%2" });
    _ = try rig.ok(&.{ "kill-pane", "-a", "-t", "%2" });
    try testing.expectEqualStrings("%2\n", try rig.ok(&.{ "list-panes", "-F", "#{pane_id}" }));
}

test "win32 tmux commands: respawn keeps id and options" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "set-option", "-p", "-t", "%1", "remain-on-exit", "failed" });
    _ = try rig.ok(&.{ "select-pane", "-t", "%1", "-T", "lead" });
    _ = try rig.ok(&.{ "respawn-pane", "-k", "-t", "%1", "--", "cd 'C:\\x' && cat" });
    try testing.expectEqual(Options.RemainOnExit.failed, rig.host.opts.remainOnExit(1, 1));
    try testing.expectEqualStrings("lead", rig.host.titleOf(1));
    try testing.expectEqualStrings("%1\n", try rig.ok(&.{ "display-message", "-p", "-t", "%1", "#{pane_id}" }));
    const r = rig.host.spawnsOf(1, .respawn, 0).?;
    try testing.expectEqualStrings("cd 'C:\\x' && cat", r.command.?);
    // The respawn used one id up: the next pane is %3, not %2.
    try testing.expectEqualStrings("%3\n", try rig.ok(&.{ "split-window", "-d", "-P", "-F", "#{pane_id}" }));
}

test "win32 tmux commands: respawn without -k on a live pane" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.bad(&.{ "respawn-pane", "-t", "%1", "--", "cat" }, "pane %1 still active");
    try testing.expect(rig.host.spawnsOf(1, .respawn, 0) == null);
    rig.host.markExited(1);
    _ = try rig.ok(&.{ "respawn-pane", "-t", "%1", "--", "cat" });
    try testing.expect(rig.host.spawnsOf(1, .respawn, 0) != null);
}

test "win32 tmux commands: unsupported pane command" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.host.inject_split = error.Unsupported;
    const out = try rig.run(&.{ "split-window", "-t", "%1" });
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqualStrings("ghostty: unsupported pane command\n", out.stderr.items);
    rig.host.inject_respawn = error.Unsupported;
    try rig.bad(&.{ "respawn-pane", "-k", "-t", "%1" }, "ghostty: unsupported pane command");
}

test "win32 tmux commands: missing directory is a tmux-like error" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.host.inject_split = error.NoDirectory;
    rig.host.failed_dir = "C:\\gone";
    const out = try rig.run(&.{ "split-window", "-t", "%1" });
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqualStrings("can't find directory: C:\\gone\n", out.stderr.items);
}

test "win32 tmux commands: select-pane -T does not move focus" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%1" });
    try testing.expectEqual(@as(u32, 1), rig.host.focused);
    _ = try rig.ok(&.{ "select-pane", "-t", "%2", "-T", "alpha" });
    try testing.expectEqual(@as(u32, 1), rig.host.focused);
    try testing.expectEqualStrings("alpha", rig.host.titleOf(2));
    // Without -T it focuses; -P and friends are ignored.
    _ = try rig.ok(&.{ "select-pane", "-t", "%2", "-P", "bg=red" });
    try testing.expectEqual(@as(u32, 2), rig.host.focused);
    try rig.bad(&.{ "select-pane", "-L" }, "select-pane: -L is not supported by Ghostty");
}

test "win32 tmux commands: -d keeps focus, no -d focuses" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%1" });
    try testing.expectEqual(@as(u32, 1), rig.host.focused);
    _ = try rig.ok(&.{ "split-window", "-v", "-t", "%2" });
    try testing.expectEqual(@as(u32, 3), rig.host.focused);
}

test "win32 tmux commands: unsupported flags fail loudly" {
    var rig = try Rig.init();
    defer rig.deinit();
    const cases = [_]struct { argv: []const []const u8, msg: []const u8 }{
        .{ .argv = &.{ "split-window", "-f" }, .msg = "split-window: -f is not supported by Ghostty" },
        .{ .argv = &.{ "split-window", "-I" }, .msg = "split-window: -I is not supported by Ghostty" },
        .{ .argv = &.{ "select-layout", "-n" }, .msg = "select-layout: -n is not supported by Ghostty" },
        .{ .argv = &.{ "resize-pane", "-L" }, .msg = "resize-pane: -L is not supported by Ghostty" },
        .{ .argv = &.{ "display-message", "-a" }, .msg = "display-message: -a is not supported by Ghostty" },
        .{ .argv = &.{ "send-keys", "-X" }, .msg = "send-keys: -X is not supported by Ghostty" },
        .{ .argv = &.{ "capture-pane", "-M" }, .msg = "capture-pane: -M is not supported by Ghostty" },
        .{ .argv = &.{ "list-panes", "-f", "x" }, .msg = "list-panes: -f is not supported by Ghostty" },
    };
    for (cases) |c| try rig.bad(c.argv, c.msg);
    try testing.expectEqual(@as(usize, 1), (try rig.host.paneIds(rig.arena(), 0)).len);
}

test "win32 tmux commands: set-option and select-pane -T report optionsChanged" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "set-option", "-p", "-t", "%1", "pane-border-style", "fg=red" });
    try testing.expectEqual(@as(usize, 1), rig.host.options_changed.items.len);
    try testing.expectEqual(@as(u32, 1), rig.host.options_changed.items[0]);
    _ = try rig.ok(&.{ "select-pane", "-t", "%1", "-T", "x" });
    try testing.expectEqual(@as(usize, 2), rig.host.options_changed.items.len);
    _ = try rig.ok(&.{ "set-option", "-w", "-t", "@1", "pane-border-status", "top" });
    try testing.expectEqual(@as(usize, 3), rig.host.options_changed.items.len);
    // Scopes land in the right maps; -a appends, -u unsets, unknown names are accepted.
    try testing.expectEqualStrings("fg=red", rig.host.opts.panes.get(1).?.get("pane-border-style").?);
    try testing.expectEqualStrings("top", rig.host.opts.windows.get(1).?.get("pane-border-status").?);
    _ = try rig.ok(&.{ "set-option", "-g", "status-left", "a" });
    _ = try rig.ok(&.{ "set-option", "-g", "-a", "status-left", "b" });
    try testing.expectEqualStrings("ab", rig.host.opts.global.get("status-left").?);
    _ = try rig.ok(&.{ "set-option", "-g", "-u", "status-left" });
    try testing.expect(rig.host.opts.global.get("status-left") == null);
    _ = try rig.ok(&.{ "set-option", "-q", "no-such-option", "1" });
    // Without a scope flag a pane target means the pane.
    _ = try rig.ok(&.{ "set-option", "-t", "%1", "remain-on-exit", "on" });
    try testing.expectEqual(Options.RemainOnExit.on, rig.host.opts.remainOnExit(1, 1));
}

test "win32 tmux commands: unknown target" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.bad(&.{ "display-message", "-p", "-t", "%99", "x" }, "can't find pane: %99");
    try rig.bad(&.{ "display-message", "-p", "-t", "@9", "x" }, "can't find window: @9");
    try rig.bad(&.{ "display-message", "-p", "-t", "0:1", "x" }, "can't find pane: 0:1");
    try rig.bad(&.{ "list-panes", "-t", "nope" }, "can't find window: nope");
    try rig.bad(&.{ "split-window", "-t", "%99" }, "can't find pane: %99");
    // @N as a pane target is the window's active pane.
    try testing.expectEqualStrings("%1\n", try rig.ok(&.{ "display-message", "-p", "-t", "@1", "#{pane_id}" }));
    // No -t: the caller's pane; a stale caller falls back to the focused pane.
    var ctx = Rig.ctxWith(null);
    ctx.caller_pane = 77;
    const out = try rig.runCtx(ctx, &.{ "display-message", "-p", "#{pane_id}" });
    try testing.expectEqualStrings("%1\n", out.stdout.items);
}

test "win32 tmux commands: sequence stops at first error" {
    var rig = try Rig.init();
    defer rig.deinit();
    const out = try rig.run(&.{ "set-option", "-g", "a", "1", ";", "kill-pane", "-t", "%9", ";", "set-option", "-g", "b", "2" });
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(rig.host.opts.global.get("a") != null);
    try testing.expect(rig.host.opts.global.get("b") == null);
    // A parse error anywhere runs nothing.
    const out2 = try rig.run(&.{ "set-option", "-g", "c", "1", ";", "frobnicate" });
    try testing.expectEqual(@as(u8, 1), out2.code);
    try testing.expect(rig.host.opts.global.get("c") == null);
}

test "win32 tmux commands: expired request does nothing" {
    var rig = try Rig.init();
    defer rig.deinit();
    var ctx = Rig.ctxWith(null);
    ctx.now_ms = 1000;
    const out = try rig.runCtx(ctx, &.{ "split-window", "-t", "%1" });
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqualStrings("ghostty: server timed out\n", out.stderr.items);
    try testing.expectEqual(@as(usize, 1), (try rig.host.paneIds(rig.arena(), 0)).len);
    try testing.expectEqual(@as(usize, 1), rig.host.spawns.items.len);
}

test "win32 tmux commands: remain-on-exit resolution pane > window > global" {
    var rig = try Rig.init();
    defer rig.deinit();
    try testing.expectEqual(Options.RemainOnExit.off, rig.host.opts.remainOnExit(1, 1));
    _ = try rig.ok(&.{ "set-option", "-g", "remain-on-exit", "on" });
    try testing.expectEqual(Options.RemainOnExit.on, rig.host.opts.remainOnExit(1, 1));
    _ = try rig.ok(&.{ "set-option", "-w", "-t", "@1", "remain-on-exit", "failed" });
    try testing.expectEqual(Options.RemainOnExit.failed, rig.host.opts.remainOnExit(1, 1));
    try testing.expectEqual(Options.RemainOnExit.on, rig.host.opts.remainOnExit(1, 2));
    _ = try rig.ok(&.{ "set-option", "-p", "-t", "%1", "remain-on-exit", "off" });
    try testing.expectEqual(Options.RemainOnExit.off, rig.host.opts.remainOnExit(1, 1));
    _ = try rig.ok(&.{ "set-option", "-p", "-u", "-t", "%1", "remain-on-exit" });
    try testing.expectEqual(Options.RemainOnExit.failed, rig.host.opts.remainOnExit(1, 1));
    rig.host.opts.dropPane(testing.allocator, 1);
    try testing.expect(rig.host.opts.panes.get(1) == null);
}

test "win32 tmux commands: list-panes order is tree order" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-b", "-t", "%1" }); // %2 left of %1
    _ = try rig.ok(&.{ "split-window", "-d", "-v", "-t", "%2" }); // %3 below %2
    try testing.expectEqualStrings("%2\n%3\n%1\n", try rig.ok(&.{ "list-panes", "-F", "#{pane_id}" }));
    try testing.expectEqualStrings("0: main (3 panes) @1\n", try rig.ok(&.{"list-windows"}));
    try testing.expectEqualStrings("%2\n%3\n%1\n", try rig.ok(&.{ "list-panes", "-a", "-F", "#{pane_id}" }));
    const default_fmt = try rig.ok(&.{ "list-panes", "-t", "@1" });
    try testing.expect(std.mem.startsWith(u8, default_fmt, "0: ["));
    try testing.expect(std.mem.endsWith(u8, default_fmt, " %1\n"));
}

test "win32 tmux commands: select-layout and resize-pane" {
    var rig = try Rig.init();
    defer rig.deinit();
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%1" });
    _ = try rig.ok(&.{ "split-window", "-d", "-h", "-t", "%2" });
    _ = try rig.ok(&.{ "select-layout", "-t", "@1", "tiled" });
    _ = try rig.ok(&.{ "select-layout", "even-horizontal" }); // accepted, no change
    _ = try rig.ok(&.{ "select-layout", "main-vertical" });
    const root = rig.host.treeOf(1).nodes[0].split;
    try testing.expectApproxEqAbs(@as(f32, 0.3), @as(f32, root.ratio), 0.002);
    _ = try rig.ok(&.{ "resize-pane", "-t", "%1", "-x", "50%" });
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, rig.host.treeOf(1).nodes[0].split.ratio), 0.01);
    _ = try rig.ok(&.{ "resize-pane", "-Z", "-t", "%1" });
    try testing.expectEqual(@as(u32, 1), rig.host.zoom_toggles);
    try rig.bad(&.{ "resize-pane", "-x", "0" }, "size invalid: 0");
}

test "win32 tmux commands: display-message, buffers, keys, capture" {
    var rig = try Rig.init();
    defer rig.deinit();
    // Without -p nothing is printed.
    try testing.expectEqualStrings("", try rig.ok(&.{ "display-message", "hi" }));
    try testing.expectEqualStrings("0:0.0\n", try rig.ok(&.{ "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}" }));
    try testing.expectEqualStrings("0:0.1\n", try rig.ok(&.{ "split-window", "-d", "-P" }));
    try testing.expectEqualStrings("", try rig.ok(&.{ "show-environment", "-g" }));
    try rig.bad(&.{ "show-environment", "a", "b" }, "too many arguments");
    try rig.bad(&.{ "show-environment", "-g", "NOPE" }, "unknown variable: NOPE");

    // load-buffer needs "-" and stdin.
    try rig.bad(&.{ "load-buffer", "-" }, "load-buffer");
    try rig.bad(&.{ "load-buffer", "file.txt" }, "load-buffer");
    try rig.bad(&.{"load-buffer"}, "too few arguments");
    const out = try rig.runCtx(Rig.ctxWith("hello"), &.{ "load-buffer", "-w", "-" });
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("hello", rig.host.opts.buffer.?);
    try testing.expectEqualStrings("hello", rig.host.clipboard.?);

    _ = try rig.ok(&.{ "send-keys", "-t", "%1", "-N", "3", "echo", "Enter" });
    try testing.expectEqualStrings("x3:echo|Enter", rig.host.keys.items[0]);
    try rig.bad(&.{ "send-keys", "-N", "0", "a" }, "repeat count invalid");
    try testing.expectEqualStrings("screen of %1\n", try rig.ok(&.{ "capture-pane", "-p", "-t", "%1" }));
    try testing.expectEqualStrings("", try rig.ok(&.{ "capture-pane", "-t", "%1" }));
    try testing.expectEqualStrings("screen of %1\n", rig.host.opts.buffer.?);
    try rig.bad(&.{ "kill-pane", "extra" }, "too many arguments (need at most 0)");
}

test "win32 tmux commands: option values are capped, also when appended" {
    var rig = try Rig.init();
    defer rig.deinit();
    const big = try testing.allocator.alloc(u8, max_option_value);
    defer testing.allocator.free(big);
    @memset(big, 'v');
    _ = try rig.ok(&.{ "set-option", "-g", "status-left", big });
    try rig.bad(&.{ "set-option", "-g", "-a", "status-left", "x" }, "option value too long");
    try testing.expectEqual(@as(usize, max_option_value), rig.host.opts.global.get("status-left").?.len);
    const over = try testing.allocator.alloc(u8, max_option_value + 1);
    defer testing.allocator.free(over);
    @memset(over, 'v');
    try rig.bad(&.{ "set-option", "-g", "other", over }, "option value too long");
    try testing.expect(rig.host.opts.global.get("other") == null);
}

test "win32 tmux commands: a format cannot expand the reply past max_output" {
    var rig = try Rig.init();
    defer rig.deinit();
    const big = try testing.allocator.alloc(u8, max_option_value);
    defer testing.allocator.free(big);
    @memset(big, 'v');
    _ = try rig.ok(&.{ "set-option", "-g", "status-left", big });

    // One expansion fits; 130 x 8192 B pass the 1 MiB cap.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..130) |_| try many.appendSlice(testing.allocator, "#{status-left}");
    try testing.expectEqual(max_option_value + 1, (try rig.ok(&.{ "display-message", "-p", "#{status-left}" })).len);
    try rig.bad(&.{ "display-message", "-p", many.items }, "ghostty: reply too large");
    const out = try rig.run(&.{ "display-message", "-p", many.items });
    try testing.expectEqual(@as(usize, 0), out.stdout.items.len);
    try testing.expect(out.stderr.items.len < 100);

    // The same expansion through list-panes -a -F.
    try rig.bad(&.{ "list-panes", "-a", "-F", many.items }, "ghostty: reply too large");
}

test "win32 tmux commands: send-keys over the cap answers request too large" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.host.keys_too_large = true;
    try rig.bad(&.{ "send-keys", "-t", "%1", "-N", "100000", "a" }, "ghostty: request too large");
}

test "win32 tmux commands: error lines are truncated" {
    var rig = try Rig.init();
    defer rig.deinit();
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'n');
    const out = try rig.run(&.{ "show-environment", "-g", long });
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(out.stderr.items.len <= 4097);
}

test "win32 tmux commands: load-buffer -w keeps the buffer when clipboard-write is deny" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.host.clipboard_denied = true;
    const out = try rig.runCtx(Rig.ctxWith("secret"), &.{ "load-buffer", "-w", "-" });
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("secret", rig.host.opts.buffer.?);
    try testing.expect(rig.host.clipboard == null);
}
