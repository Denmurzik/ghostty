//! Title rules shared by the tab strip and the caption, following Ghostty
//! for macOS: a title is what the program set; with none, a ghost.
const std = @import("std");

/// Shown when no program set a title (`SurfaceView_AppKit`).
pub const fallback = "\u{1F47B}";

/// How long a surface waits for its first title before the ghost shows.
pub const grace_ms = 500;

/// Coalesces title changes so a command that sets the title twice in a row
/// (the command, then the folder) does not flicker.
pub const debounce_ms = 75;

/// The title a program-set `raw` stands for, or null for no title.
/// ConPTY (conhost) announces the process image path as the title of a
/// console that never set one, and "<image path> - <command>" while a
/// command runs under cmd; the path is noise, the command is a title.
pub fn programTitle(raw: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    const admin = "Administrator: ";
    if (text.len >= admin.len and std.ascii.eqlIgnoreCase(text[0..admin.len], admin)) {
        text = std.mem.trim(u8, text[admin.len..], " ");
    }
    if (text.len == 0) return null;

    const rest = afterImagePath(text) orelse return text;
    const tail = std.mem.trim(u8, rest, " \t");
    if (tail.len == 0 or std.mem.eql(u8, tail, "-")) return null;
    if (!std.mem.startsWith(u8, rest, " ") or !std.mem.startsWith(u8, tail, "- ")) return text;
    const command = std.mem.trim(u8, tail[2..], " \t");
    return if (command.len == 0) null else command;
}

/// The text after an executable image path that `text` starts with
/// (an absolute path, or a bare "name.exe"), null when it starts with none.
fn afterImagePath(text: []const u8) ?[]const u8 {
    const quoted = text[0] == '"';
    const body = if (quoted) text[1..] else text;
    const absolute = isAbsolute(body);

    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(body, from, ".exe")) |at| {
        const end = at + ".exe".len;
        from = end;
        if (quoted) {
            if (end >= body.len or body[end] != '"') continue;
            if (!absolute and !isBareName(body[0..end])) return null;
            return body[end + 1 ..];
        }
        if (end < body.len and body[end] != ' ') continue;
        if (!absolute and !isBareName(body[0..end])) return null;
        return body[end..];
    }
    return null;
}

fn isAbsolute(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '\\' or path[2] == '/')) return true;
    return std.mem.startsWith(u8, path, "\\\\");
}

fn isBareName(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, " \\/:") == null;
}

test "win32 title rules: conhost image path is no title" {
    const none = [_][]const u8{
        "C:\\WINDOWS\\SYSTEM32\\cmd.exe",
        "c:\\windows\\system32\\CMD.EXE",
        "C:\\Program Files\\Git\\bin\\bash.exe",
        // The idle placeholder pane of the tmux shim.
        "C:\\D\\Ghostty\\zig-out\\bin\\tmux.exe",
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "Administrator: C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "\"C:\\Program Files\\Git\\bin\\bash.exe\"",
        "\\\\server\\share\\tool.exe",
        "pwsh.exe",
        "C:\\WINDOWS\\SYSTEM32\\cmd.exe - ",
        "   ",
        "",
    };
    for (none) |raw| try std.testing.expectEqual(@as(?[]const u8, null), programTitle(raw));
}

test "win32 title rules: conhost command form shows the command" {
    try std.testing.expectEqualStrings(
        "ping localhost",
        programTitle("C:\\WINDOWS\\SYSTEM32\\cmd.exe - ping localhost").?,
    );
    try std.testing.expectEqualStrings(
        "dir /s",
        programTitle("\"C:\\WINDOWS\\SYSTEM32\\cmd.exe\" - dir /s").?,
    );
    try std.testing.expectEqualStrings(
        "npm test",
        programTitle("C:\\Program Files\\PowerShell\\7\\pwsh.exe - npm test").?,
    );
}

test "win32 title rules: real titles pass through" {
    const keep = [_][]const u8{
        "MINGW64:/c/Users/me",
        "C:\\Users\\me",
        "C:\\Users\\me\\project",
        "vim main.zig",
        "~/src - nvim",
        "tool.exe is great",
        "C:\\tools\\a.exe.txt",
        "\u{1F47B}",
    };
    for (keep) |raw| try std.testing.expectEqualStrings(raw, programTitle(raw).?);
}

/// Like `programTitle`, for a surface whose title was `previous`: cmd builds
/// its running title from the console title, "<previous> - <command>", so
/// that prefix is dropped.
pub fn programTitleAfter(previous: ?[]const u8, raw: []const u8) ?[]const u8 {
    const title = programTitle(raw) orelse return null;
    const prev = previous orelse return title;
    if (prev.len == 0 or !std.mem.startsWith(u8, title, prev)) return title;
    const rest = title[prev.len..];
    if (!std.mem.startsWith(u8, rest, " - ")) return title;
    const command = std.mem.trim(u8, rest[3..], " \t");
    return if (command.len == 0) title else command;
}

test "win32 title rules: cmd running title drops the working directory" {
    const cwd = "C:\\Users\\me\\proj";
    try std.testing.expectEqualStrings(
        "ping  -n 6 127.0.0.1",
        programTitleAfter(cwd, "C:\\Users\\me\\proj - ping  -n 6 127.0.0.1").?,
    );
    try std.testing.expectEqualStrings(cwd, programTitleAfter(null, cwd).?);
    try std.testing.expectEqualStrings("C:\\other - x", programTitleAfter(cwd, "C:\\other - x").?);
    try std.testing.expectEqualStrings(cwd, programTitleAfter(cwd, cwd).?);
}

/// The title row text with `window-subtitle = working-directory`: the title,
/// then the directory after an em dash. The caption (taskbar) keeps the title
/// alone. A directory the title already shows adds nothing.
pub fn withSubtitle(alloc: std.mem.Allocator, title: []const u8, pwd: ?[]const u8) std.mem.Allocator.Error![:0]u8 {
    const dir = pwd orelse "";
    if (dir.len == 0 or std.mem.indexOf(u8, title, dir) != null) return alloc.dupeSentinel(u8, title, 0);
    return std.fmt.allocPrintSentinel(alloc, "{s} \u{2014} {s}", .{ title, dir }, 0);
}

test "win32 title rules: subtitle" {
    const a = std.testing.allocator;
    const s = try withSubtitle(a, "bash", "C:/work");
    defer a.free(s);
    try std.testing.expectEqualStrings("bash \u{2014} C:/work", s);
    const t = try withSubtitle(a, "vim C:/work/a", "C:/work");
    defer a.free(t);
    try std.testing.expectEqualStrings("vim C:/work/a", t);
    const u = try withSubtitle(a, "x", null);
    defer a.free(u);
    try std.testing.expectEqualStrings("x", u);
}
