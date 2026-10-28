const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const Config = configpkg.Config;
const global = @import("../global.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `edit-config` command opens the Ghostty configuration file in the
/// editor specified by the `$VISUAL` or `$EDITOR` environment variables.
///
/// IMPORTANT: This command will not reload the configuration after
/// editing. You will need to manually reload the configuration using the
/// application menu, configured keybind, or by restarting Ghostty. We
/// plan to auto-reload in the future, but Ghostty isn't capable of
/// this yet.
///
/// The filepath opened is the default user-specific configuration
/// file, which is typically located at `$XDG_CONFIG_HOME/ghostty/config.ghostty`.
/// On macOS, this may also be located at
/// `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`.
/// On macOS, whichever path exists and is non-empty will be prioritized,
/// prioritizing the Application Support directory if neither are
/// non-empty.
///
/// This command prefers the `$VISUAL` environment variable over `$EDITOR`,
/// if both are set. If neither are set, it will print an error
/// and exit.
///
/// On Windows the editor runs detached and this command exits 0 at once.
/// The editor is the `$VISUAL` or `$EDITOR` command line (Windows quoting
/// rules). A GUI program (VS Code, Notepad++) or a `.cmd`/`.bat` launcher
/// (`code.cmd`) is started directly and hidden from view. A console
/// program is run by a separate Ghostty window of the configured `class`,
/// because a terminal editor cannot share the calling console. Unlike on
/// other systems, with neither variable set Notepad opens the file instead of
/// printing an error.
pub fn run(alloc: Allocator) !u8 {
    // Implementation note (by @mitchellh): I do proper memory cleanup
    // throughout this command, even though we plan on doing `exec`.
    // I do this out of good hygiene in case we ever change this to
    // not using `exec` anymore and because this command isn't performance
    // critical where setting up the defer cleanup is a problem.

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const result = runInner(alloc, stderr);
    // Flushing *shouldn't* fail but...
    stderr.flush() catch {};
    return result;
}

fn runInner(alloc: Allocator, stderr: *std.Io.Writer) !u8 {
    // We require libc because we want to use std.c.environ for envp
    // and not have to build that ourselves. We can remove this
    // limitation later but Ghostty already heavily requires libc
    // so this is not a big deal.
    comptime assert(builtin.link_libc);

    // We load the configuration once because that will write our
    // default configuration files to disk. We don't use the config.
    var config = try Config.load(alloc);
    defer config.deinit();

    // Find the preferred path.
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);

    // There is no exec on Windows: spawn the editor and leave.
    if (comptime builtin.target.os.tag == .windows) {
        return runWindows(alloc, stderr, path, config.class);
    }

    const command = internal_os.getConfigEditCommand(alloc, path, .{ .default_editor = .failure }) catch |err| {
        switch (err) {
            error.NoEditorConfigured => {
                try stderr.print(
                    \\The $EDITOR or $VISUAL environment variable is not set or is empty.
                    \\This environment variable is required to edit the Ghostty configuration
                    \\via this CLI command.
                    \\
                    \\Please set the environment variable to your preferred terminal
                    \\text editor and try again.
                    \\
                    \\If you prefer to edit the configuration file another way,
                    \\you can find the configuration file at the following path:
                    \\
                    \\
                ,
                    .{},
                );

                // Output the path using the OSC8 sequence so that it is linked.
                try stderr.print(
                    "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
                    .{ path, path },
                );

                return 1;
            },
            error.WriteFailed,
            error.OutOfMemory,
            => |e| return e,
        }
    };
    defer alloc.free(command);

    // Run/replace process (using execve)
    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        command.ptr,
    };
    const envp = std.c.environ;
    const err = std.posix.errno(std.posix.system.execve(argv[0].?, &argv, envp));

    // If we reached this point then exec failed.
    try stderr.print(
        \\Failed to execute the editor (E{t}).
        \\
        \\This is usually due to the executable path not existing, invalid
        \\permissions, or the shell environment not being set up
        \\correctly.
        \\
        \\Command: {s}
        \\
    , .{
        err,
        command,
    });
    // Output the path using the OSC8 sequence so that it is linked.
    try stderr.print(
        "Path: \x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
        .{ path, path },
    );
    return 1;
}

// ---- Windows ----------------------------------------------------------

/// Nothing to search with when `isGuiResolved` is called by the tests.
var gui_env: ?*const std.process.Environ.Map = null;

fn runWindows(alloc: Allocator, stderr: *std.Io.Writer, path: []const u8, class: ?[]const u8) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try global.environMap();
    defer env.deinit();
    gui_env = &env;
    defer gui_env = null;

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(global.io(), &exe_buf) catch |err| {
        try stderr.print("Unable to find the Ghostty executable ({t}).\n", .{err});
        return 1;
    };

    const argv = try windowsEditorArgv(
        a,
        exe_buf[0..exe_len],
        class,
        nonEmpty(env.get("VISUAL")),
        nonEmpty(env.get("EDITOR")),
        path,
        nonEmpty(env.get("SystemRoot")) orelse "C:\\Windows",
        isGuiResolved,
    );

    // A GUI editor is started by its resolved path.
    var spawn_argv = argv;
    if (!std.mem.eql(u8, argv[0], exe_buf[0..exe_len])) {
        if (resolveExe(a, &env, argv[0])) |resolved| {
            const copy = try a.dupe([]const u8, argv);
            copy[0] = resolved;
            spawn_argv = copy;
        }
    }

    const child = std.process.spawn(global.io(), .{
        .argv = spawn_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // A launcher script would otherwise flash a console window.
        .create_no_window = isBatch(spawn_argv[0]),
    }) catch |err| {
        try stderr.print("Failed to start the editor ({t}).\n\nCommand: {s}\n", .{ err, argv[0] });
        try stderr.print("Path: {s}\n", .{path});
        return 1;
    };

    // The editor runs on its own; its handles are not needed.
    if (child.id) |h| std.os.windows.CloseHandle(h);
    std.os.windows.CloseHandle(child.thread_handle);
    try stderr.print("Opening {s}\n", .{path});
    return 0;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// The command to run for the editor. `{editor_exe, tokens[1..]..., path}`
/// for a GUI editor, `{exe, "--class=<c>", "-e", tokens..., path}` for a
/// console one (a separate Ghostty runs it), Notepad without an editor.
/// `VISUAL` wins over `EDITOR`; an empty value counts as unset. Everything
/// is allocated with `alloc` (pass an arena).
fn windowsEditorArgv(
    alloc: Allocator,
    exe: []const u8,
    class: ?[]const u8,
    visual: ?[]const u8,
    editor: ?[]const u8,
    path: []const u8,
    system_root: []const u8,
    isGui: *const fn ([]const u8) bool,
) ![]const []const u8 {
    const spec = nonEmpty(visual) orelse nonEmpty(editor);
    const tokens: []const []const u8 = if (spec) |s|
        @ptrCast(try internal_os.windows_cmdline.tokenizeWindows(alloc, s))
    else
        &.{};

    var out: std.ArrayList([]const u8) = .empty;
    if (tokens.len == 0) {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ system_root, "System32", "notepad.exe" }));
        try out.append(alloc, path);
        return out.items;
    }

    if (isGui(tokens[0])) {
        try out.appendSlice(alloc, tokens);
    } else {
        try out.append(alloc, exe);
        if (class) |c| try out.append(alloc, try std.fmt.allocPrint(alloc, "--class={s}", .{c}));
        try out.append(alloc, "-e");
        try out.appendSlice(alloc, tokens);
    }
    try out.append(alloc, path);
    return out.items;
}

/// A `.cmd`/`.bat` launcher (`code.cmd`): it hands the file to a GUI program,
/// so it is not given a Ghostty window.
fn isBatch(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat");
}

fn isGuiResolved(token: []const u8) bool {
    const env = gui_env orelse return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const resolved = resolveExe(arena.allocator(), env, token) orelse return false;
    return isBatch(resolved) or peIsGui(resolved);
}

/// `token` as an existing file: as it is when it names a path, else
/// searched in PATH, each time with the PATHEXT extensions when it has none.
fn resolveExe(alloc: Allocator, env: *const std.process.Environ.Map, token: []const u8) ?[]const u8 {
    const has_dir = std.mem.indexOfAny(u8, token, "\\/:") != null;
    if (has_dir) return withExtensions(alloc, env, "", token);

    var it = std.mem.splitScalar(u8, env.get("PATH") orelse "", ';');
    while (it.next()) |raw| {
        const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\""), "\\/");
        if (dir.len == 0) continue;
        if (withExtensions(alloc, env, dir, token)) |found| return found;
    }
    return null;
}

fn withExtensions(alloc: Allocator, env: *const std.process.Environ.Map, dir: []const u8, name: []const u8) ?[]const u8 {
    const base = if (dir.len == 0)
        alloc.dupe(u8, name) catch return null
    else
        std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    if (std.fs.path.extension(name).len > 0 and fileExists(base)) return base;

    var exts = std.mem.splitScalar(u8, env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD", ';');
    while (exts.next()) |ext| {
        if (ext.len == 0) continue;
        const candidate = std.mem.concat(alloc, u8, &.{ base, ext }) catch return null;
        if (fileExists(candidate)) return candidate;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{}) catch return false;
    file.close(global.io());
    return true;
}

/// Whether the executable at `path` has the Windows GUI subsystem (reads
/// the Subsystem field of the PE optional header). False for anything that
/// is not a readable PE file.
fn peIsGui(path: []const u8) bool {
    const io = global.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);

    var dos: [0x40]u8 = undefined;
    if ((file.readPositionalAll(io, &dos, 0) catch return false) != dos.len) return false;
    if (dos[0] != 'M' or dos[1] != 'Z') return false;
    const pe_offset = std.mem.readInt(u32, dos[0x3c..][0..4], .little);

    // "PE\0\0", the COFF header (20 bytes), then the optional header, whose
    // Subsystem field is at offset 68 for both PE32 and PE32+.
    var hdr: [24 + 70]u8 = undefined;
    if ((file.readPositionalAll(io, &hdr, pe_offset) catch return false) != hdr.len) return false;
    if (!std.mem.eql(u8, hdr[0..4], "PE\x00\x00")) return false;
    const subsystem = std.mem.readInt(u16, hdr[24 + 68 ..][0..2], .little);
    return subsystem == 2; // IMAGE_SUBSYSTEM_WINDOWS_GUI
}

fn alwaysGui(_: []const u8) bool {
    return true;
}

fn neverGui(_: []const u8) bool {
    return false;
}

test "windows edit-config: VISUAL beats EDITOR" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try windowsEditorArgv(arena.allocator(), "C:\\g\\ghostty.exe", null, "vis", "ed", "C:\\c\\config.ghostty", "C:\\Windows", neverGui);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("C:\\g\\ghostty.exe", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings("vis", argv[2]);
    try std.testing.expectEqualStrings("C:\\c\\config.ghostty", argv[3]);
}

test "windows edit-config: quoted editor path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try windowsEditorArgv(
        arena.allocator(),
        "C:\\g\\ghostty.exe",
        "edit",
        "\"C:\\Program Files\\Vim\\vim.exe\" -u NONE",
        null,
        "C:\\c\\config.ghostty",
        "C:\\Windows",
        neverGui,
    );
    const want = [_][]const u8{
        "C:\\g\\ghostty.exe",              "--class=edit", "-e",
        "C:\\Program Files\\Vim\\vim.exe", "-u",           "NONE",
        "C:\\c\\config.ghostty",
    };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "windows edit-config: GUI editor is spawned directly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try windowsEditorArgv(arena.allocator(), "C:\\g\\ghostty.exe", "edit", null, "code.exe --wait", "p", "C:\\Windows", alwaysGui);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("code.exe", argv[0]);
    try std.testing.expectEqualStrings("--wait", argv[1]);
    try std.testing.expectEqualStrings("p", argv[2]);
    for (argv) |arg| try std.testing.expect(!std.mem.endsWith(u8, arg, "ghostty.exe"));
}

test "windows edit-config: .cmd and .bat are launchers" {
    try std.testing.expect(isBatch("C:/Users/u/Programs/Microsoft VS Code/bin/code.cmd"));
    try std.testing.expect(isBatch("x.BAT"));
    try std.testing.expect(!isBatch("vim.exe"));
    try std.testing.expect(!isBatch("cmd"));
}

test "windows edit-config: a config path with spaces is one argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "C:/Users/A B/.config/ghostty/config.ghostty";
    const argv = try windowsEditorArgv(a, "C:/Program Files/Ghostty/ghostty.exe", "edit", "vim", null, path, "C:/Windows", neverGui);
    try std.testing.expectEqualStrings(path, argv[argv.len - 1]);
    // The command line the spawner builds quotes the path, and the child's
    // argv parser reads it back as the same single argument.
    const line = try internal_os.windows_cmdline.createCommandLine(a, argv);
    const back = try internal_os.windows_cmdline.tokenizeWindows(a, line);
    try std.testing.expectEqual(argv.len, back.len);
    for (argv, back) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "windows edit-config: no editor uses notepad" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try windowsEditorArgv(arena.allocator(), "C:\\g\\ghostty.exe", "edit", null, null, "p", "D:\\Win", neverGui);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("D:\\Win\\System32\\notepad.exe", argv[0]);
    try std.testing.expectEqualStrings("p", argv[1]);
}

test "windows edit-config: empty EDITOR counts as unset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An empty VISUAL falls back to EDITOR, and two empty ones to Notepad.
    const one = try windowsEditorArgv(a, "g.exe", null, "", "vim", "p", "C:\\Windows", neverGui);
    try std.testing.expectEqualStrings("vim", one[2]);
    const none = try windowsEditorArgv(a, "g.exe", null, "", "", "p", "C:\\Windows", neverGui);
    try std.testing.expectEqualStrings("C:\\Windows\\System32\\notepad.exe", none[0]);
    // Blank (only spaces) tokenises to nothing: Notepad too.
    const blank = try windowsEditorArgv(a, "g.exe", null, "   ", null, "p", "C:\\Windows", neverGui);
    try std.testing.expectEqualStrings("C:\\Windows\\System32\\notepad.exe", blank[0]);
}

test "windows edit-config: peIsGui" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(peIsGui("C:\\Windows\\System32\\notepad.exe") or
        peIsGui("C:\\Windows\\notepad.exe"));
    try std.testing.expect(!peIsGui("C:\\Windows\\System32\\cmd.exe"));
    try std.testing.expect(!peIsGui("C:\\Windows\\System32\\no-such-file.exe"));
}
