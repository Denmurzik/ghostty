//! POSIX-shell command-line parsing for respawn-pane and split-window (owner: M4 task 4).
//! Grammar: `[cd W &&] [env (NAME=W)*] W+` with POSIX quoting and no expansions.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Parsed = struct {
    cwd: ?[]const u8,
    env: []const []const u8,
    argv: []const []const u8,
};

const Token = struct {
    text: []const u8,
    /// True when the token is the bare, unquoted `&&`.
    and_and: bool,
    /// True when any part of the word was quoted or escaped.
    quoted: bool,
};

pub fn parse(arena: Allocator, s: []const u8) error{ Unsupported, OutOfMemory }!Parsed {
    var toks: std.ArrayList(Token) = .empty;
    try tokenize(arena, s, &toks);
    if (toks.items.len == 0) return error.Unsupported;

    var idx: usize = 0;
    var cwd: ?[]const u8 = null;
    if (isWord(toks.items[0], "cd")) {
        if (toks.items.len < 4) return error.Unsupported;
        if (toks.items[1].and_and or !toks.items[2].and_and) return error.Unsupported;
        cwd = toks.items[1].text;
        idx = 3;
    }
    // A stray `&&` anywhere else is not supported.
    for (toks.items[idx..]) |t| if (t.and_and) return error.Unsupported;

    var env: std.ArrayList([]const u8) = .empty;
    if (idx < toks.items.len and isWord(toks.items[idx], "env")) {
        idx += 1;
        // `env -i`, `env -u NAME`, ...: options are not supported.
        if (idx < toks.items.len and !toks.items[idx].quoted and
            std.mem.startsWith(u8, toks.items[idx].text, "-")) return error.Unsupported;
        while (idx < toks.items.len and isAssignment(toks.items[idx])) : (idx += 1) {
            try env.append(arena, toks.items[idx].text);
        }
    }
    if (idx >= toks.items.len) return error.Unsupported;

    const argv = try arena.alloc([]const u8, toks.items.len - idx);
    for (toks.items[idx..], argv) |t, *a| a.* = t.text;
    return .{ .cwd = cwd, .env = try env.toOwnedSlice(arena), .argv = argv };
}

fn isWord(t: Token, word: []const u8) bool {
    return !t.quoted and !t.and_and and std.mem.eql(u8, t.text, word);
}

/// NAME=value where NAME is an identifier.
fn isAssignment(t: Token) bool {
    if (t.and_and) return false;
    const eq = std.mem.indexOfScalar(u8, t.text, '=') orelse return false;
    if (eq == 0) return false;
    for (t.text[0..eq], 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

fn tokenize(arena: Allocator, s: []const u8, out: *std.ArrayList(Token)) error{ Unsupported, OutOfMemory }!void {
    var i: usize = 0;
    while (true) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) return;

        if (s[i] == '&' and i + 1 < s.len and s[i + 1] == '&') {
            const after = i + 2;
            if (after < s.len and s[after] != ' ' and s[after] != '\t') return error.Unsupported;
            try out.append(arena, .{ .text = "&&", .and_and = true, .quoted = false });
            i = after;
            continue;
        }

        var buf: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t') break;
            if (isControl(c)) return error.Unsupported;
            switch (c) {
                '\'' => {
                    quoted = true;
                    i += 1;
                    const end = std.mem.indexOfScalarPos(u8, s, i, '\'') orelse return error.Unsupported;
                    for (s[i..end]) |b| if (isControl(b) and b != '\t') return error.Unsupported;
                    try buf.appendSlice(arena, s[i..end]);
                    i = end + 1;
                },
                '"' => {
                    quoted = true;
                    i += 1;
                    while (true) {
                        if (i >= s.len) return error.Unsupported;
                        const d = s[i];
                        if (d == '"') {
                            i += 1;
                            break;
                        }
                        if (isControl(d) and d != '\t') return error.Unsupported;
                        if (d == '\\') {
                            if (i + 1 >= s.len) return error.Unsupported;
                            const e = s[i + 1];
                            if (e == '"' or e == '\\' or e == '$' or e == '`') {
                                try buf.append(arena, e);
                                i += 2;
                            } else {
                                try buf.append(arena, '\\');
                                i += 1;
                            }
                            continue;
                        }
                        // Unescaped expansions inside double quotes are not supported.
                        if (d == '$' or d == '`') return error.Unsupported;
                        try buf.append(arena, d);
                        i += 1;
                    }
                },
                '\\' => {
                    quoted = true;
                    if (i + 1 >= s.len) return error.Unsupported;
                    const e = s[i + 1];
                    if (isControl(e)) return error.Unsupported;
                    try buf.append(arena, e);
                    i += 2;
                },
                '$', '`', '*', '?', '[', ';', '|', '&', '<', '>', '(', ')', '~', '{', '}', '!' => return error.Unsupported,
                // A word starting with an unquoted `#` is a shell comment.
                '#' => {
                    if (buf.items.len == 0 and !quoted) return error.Unsupported;
                    try buf.append(arena, c);
                    i += 1;
                },
                else => {
                    try buf.append(arena, c);
                    i += 1;
                },
            }
        }
        try out.append(arena, .{ .text = try buf.toOwnedSlice(arena), .and_and = false, .quoted = quoted });
    }
}

fn expectUnsupported(s: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Unsupported, parse(arena_state.allocator(), s));
}

test "tmux shim sh_command: recon §6 Windows example" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(),
        \\cd 'C:\D\den4ik\Ghostty' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_ATTRIBUTION_PROJECT='' 'C:\Users\user\.local\bin\claude.exe' --agent-id researcher@my-team --agent-name researcher --team-name my-team --agent-color red --parent-session-id 3f2c... --model claude-sonnet-5-5
    );
    try std.testing.expectEqualStrings("C:\\D\\den4ik\\Ghostty", p.cwd.?);
    try std.testing.expectEqual(@as(usize, 3), p.env.len);
    try std.testing.expectEqualStrings("CLAUDECODE=1", p.env[0]);
    try std.testing.expectEqualStrings("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", p.env[1]);
    try std.testing.expectEqualStrings("CLAUDE_CODE_ATTRIBUTION_PROJECT=", p.env[2]);
    try std.testing.expectEqualStrings("C:\\Users\\user\\.local\\bin\\claude.exe", p.argv[0]);
    try std.testing.expectEqualStrings("--agent-id", p.argv[1]);
    try std.testing.expectEqualStrings("researcher@my-team", p.argv[2]);
    try std.testing.expectEqualStrings("claude-sonnet-5-5", p.argv[p.argv.len - 1]);
}

test "tmux shim sh_command: quote escape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try parse(a, "'it'\"'\"'s'");
    try std.testing.expectEqualStrings("it's", p.argv[0]);
    const q = try parse(a, "'C:\\a\\'\"'\"'b'");
    try std.testing.expectEqualStrings("C:\\a\\'b", q.argv[0]);
}

test "tmux shim sh_command: double quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(), "\"a \\\"b\\\" \\$c\"");
    try std.testing.expectEqual(@as(usize, 1), p.argv.len);
    try std.testing.expectEqualStrings("a \"b\" $c", p.argv[0]);
}

test "tmux shim sh_command: unsupported" {
    try expectUnsupported("");
    try expectUnsupported("   ");
    try expectUnsupported("$HOME");
    try expectUnsupported("a; b");
    try expectUnsupported("a | b");
    try expectUnsupported("`x`");
    try expectUnsupported("a*");
    try expectUnsupported("a\nb");
    try expectUnsupported("cd x");
    try expectUnsupported("cd x y");
    try expectUnsupported("'abc");
    try expectUnsupported("a && b");
    try expectUnsupported("~/x");
    try expectUnsupported("echo {a,b}");
    try expectUnsupported("a !b");
    try expectUnsupported("a #comment");
    try expectUnsupported("env -i x");
}

test "tmux shim sh_command: # inside a word and quoted braces stay literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cmd = try parse(arena_state.allocator(), "a#b '{x}'");
    try std.testing.expectEqual(@as(usize, 2), cmd.argv.len);
    try std.testing.expectEqualStrings("a#b", cmd.argv[0]);
    try std.testing.expectEqualStrings("{x}", cmd.argv[1]);
}

test "tmux shim sh_command: no cd, no env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(), "'C:\\p q\\x.exe' -a");
    try std.testing.expect(p.cwd == null);
    try std.testing.expectEqual(@as(usize, 0), p.env.len);
    try std.testing.expectEqual(@as(usize, 2), p.argv.len);
    try std.testing.expectEqualStrings("C:\\p q\\x.exe", p.argv[0]);
    try std.testing.expectEqualStrings("-a", p.argv[1]);
}
