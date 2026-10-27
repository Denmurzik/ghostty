//! tmux format-string expansion for the shim (owner: M4 task 4).
const std = @import("std");

/// Expands `fmt` into `w`. `ctx` provides `fn lookup(ctx, name: []const u8) ?[]const u8`.
/// "#{name}" -> lookup or ""; "##" -> "#"; "#D #P #T #S #I #W" are aliases for
/// pane_id pane_index pane_title session_name window_index window_name.
/// "#[...]" and any other "#x" are copied verbatim, as is an unterminated "#{".
pub fn expand(w: *std.Io.Writer, fmt: []const u8, ctx: anytype) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '#' or i + 1 >= fmt.len) {
            try w.writeByte(c);
            i += 1;
            continue;
        }
        const n = fmt[i + 1];
        switch (n) {
            '#' => {
                try w.writeByte('#');
                i += 2;
            },
            '{' => {
                if (std.mem.indexOfScalarPos(u8, fmt, i + 2, '}')) |end| {
                    if (ctx.lookup(fmt[i + 2 .. end])) |v| try w.writeAll(v);
                    i = end + 1;
                } else {
                    try w.writeAll(fmt[i..]);
                    i = fmt.len;
                }
            },
            '[' => {
                const end = if (std.mem.indexOfScalarPos(u8, fmt, i + 2, ']')) |e| e + 1 else i + 2;
                try w.writeAll(fmt[i..end]);
                i = end;
            },
            'D', 'P', 'T', 'S', 'I', 'W' => {
                const name: []const u8 = switch (n) {
                    'D' => "pane_id",
                    'P' => "pane_index",
                    'T' => "pane_title",
                    'S' => "session_name",
                    'I' => "window_index",
                    else => "window_name",
                };
                if (ctx.lookup(name)) |v| try w.writeAll(v);
                i += 2;
            },
            else => {
                try w.writeAll(fmt[i .. i + 2]);
                i += 2;
            },
        }
    }
}

const TestCtx = struct {
    pub fn lookup(_: TestCtx, name: []const u8) ?[]const u8 {
        const map = [_][2][]const u8{
            .{ "pane_id", "%3" },
            .{ "pane_index", "1" },
            .{ "pane_title", "ttl" },
            .{ "session_name", "sess" },
            .{ "window_index", "2" },
            .{ "window_name", "win" },
        };
        for (map) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
};

fn run(fmt: []const u8, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try expand(&w, fmt, TestCtx{});
    return w.buffered();
}

test "tmux shim format: Claude probe" {
    const Probe = struct {
        pub fn lookup(_: @This(), name: []const u8) ?[]const u8 {
            const map = [_][2][]const u8{
                .{ "client_termname", "xterm-ghostty" },
                .{ "pane_synchronized", "off" },
                .{ "pane_dead", "0" },
                .{ "pane_in_mode", "0" },
                .{ "window_zoomed_flag", "0" },
                .{ "pane_active", "on" },
                .{ "pane_bottom", "bottom" },
                .{ "pane_top", "0" },
            };
            for (map) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
            return null;
        }
    };
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try expand(&w, "#{client_termname}\t#{pane_synchronized}\t#{pane_dead}\t#{pane_in_mode}\t#{window_zoomed_flag}\t#{pane_active}\t#{pane_bottom}\t#{pane_top}", Probe{});
    try std.testing.expectEqualStrings("xterm-ghostty\toff\t0\t0\t0\ton\tbottom\t0", w.buffered());
}

test "tmux shim format: unknown var is empty" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[]", try run("[#{nope}]", &buf));
}

test "tmux shim format: ## and #[ ] and short aliases" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("#", try run("##", &buf));
    try std.testing.expectEqualStrings("#[fg=red]x", try run("#[fg=red]x", &buf));
    try std.testing.expectEqualStrings("%3 1 ttl sess 2 win", try run("#D #P #T #S #I #W", &buf));
    try std.testing.expectEqualStrings("#x#", try run("#x#", &buf));
}

test "tmux shim format: unterminated" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a#{pane_id", try run("a#{pane_id", &buf));
    try std.testing.expectEqualStrings("#[abc", try run("#[abc", &buf));
}
