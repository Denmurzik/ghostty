//! Exec implements the logic for starting and stopping a subprocess with a
//! pty as well as spinning up the necessary read thread to read from the
//! pty and forward it to the Termio instance.
const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const EnvMap = std.process.Environ.Map;
const PasswdEntry = internal_os.passwd.Entry;
const windows = internal_os.windows;
const latency = internal_os.windows_latency;
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_fd = @import("../lib/compat/fd.zig");

const log = std.log.scoped(.io_exec);

const is_windows = builtin.target.os.tag == .windows;

/// How long to wait for the read thread to drain the pty after the child
/// exited before moving on (Windows).
const DRAIN_TIMEOUT_MS = 500;

/// The most bytes of one read that are handed to the terminal at a time
/// before the lock is released and the quit event is checked (Windows).
const PROCESS_SLICE_LEN = 2048;

/// The termios poll rate in milliseconds.
const TERMIOS_POLL_MS = 200;

/// If we build with flatpak support then we have to keep track of
/// a potential execution on the host.
const FlatpakHostCommand = if (!build_config.flatpak) struct {
    pub const Completion = struct {};
} else internal_os.FlatpakHostCommand;

/// The subprocess state for our exec backend.
subprocess: Subprocess,

/// Initialize the exec state. This will NOT start it, this only sets
/// up the internal state necessary to start it later.
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Exec {
    var subprocess = try Subprocess.init(alloc, cfg);
    errdefer subprocess.deinit();

    return .{ .subprocess = subprocess };
}

pub fn deinit(self: *Exec) void {
    self.subprocess.deinit();
}

/// Call to initialize the terminal state as necessary for this backend.
/// This is called before any termio begins. This should not be called
/// after termio begins because it may put the internal terminal state
/// into a bad state.
pub fn initTerminal(self: *Exec, term: *terminal.Terminal) void {
    // If we have an initial pwd requested by the subprocess, then we
    // set that on the terminal now. This allows rapidly initializing
    // new surfaces to use the proper pwd.
    if (self.subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Setup our initial grid/screen size from the terminal. This
    // can't fail because the pty should not exist at this point.
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Exec,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // Start our subprocess
    const pty_fds = self.subprocess.start(alloc) catch |err| {
        // If we specifically got this error then we are in the forked
        // process and our child failed to execute. If we DIDN'T
        // get this specific error then we're in the parent and
        // we need to bubble it up.
        if (err != error.ExecFailedInChild) return err;

        // We're in the child. Nothing more we can do but abnormal exit.
        // The Command will output some additional information.
        std.process.exit(1);
    };
    errdefer self.subprocess.stop();

    // Watcher to detect subprocess exit
    var process: ?xev.Process = if (self.subprocess.process) |v| switch (v) {
        .fork_exec => |cmd| try xev.Process.init(
            cmd.pid orelse return error.ProcessNoPid,
        ),

        // If we're executing via Flatpak then we can't do
        // traditional process watching (its implemented
        // as a special case in os/flatpak.zig) since the
        // command is on the host.
        .flatpak => null,
    } else return error.ProcessNotStarted;
    errdefer if (process) |*p| p.deinit();

    // Track our process start time for abnormal exits
    const process_start: std.Io.Timestamp = .now(global.io(), .awake);

    // Create what we'll use to kill our read thread. On POSIX that is a
    // pipe: pipe[0] is the read end, pipe[1] is the write end. On Windows
    // it is a quit event (plus an event the read thread signals once it
    // has seen the end of the pty stream).
    const events: WindowsEvents = if (comptime is_windows) try WindowsEvents.init() else {};
    errdefer if (comptime is_windows) events.deinit();
    const pipe: [2]posix.fd_t = if (comptime is_windows) undefined else try internal_os.pipe();
    errdefer if (comptime !is_windows) closeFd(pipe[0]);
    errdefer if (comptime !is_windows) closeFd(pipe[1]);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(pty_fds.write);
    errdefer stream.deinit();

    // Start our timer to read termios state changes. This is used
    // to detect things such as when password input is being done
    // so we can render the terminal in a different way.
    var termios_timer = try xev.Timer.init();
    errdefer termios_timer.deinit();

    // Start our read thread
    const read_thread = if (comptime is_windows) try std.Thread.spawn(
        internal_os.thread.spawn_config,
        ReadThread.threadMainWindows,
        .{ pty_fds.read, io, events.quit, events.drained },
    ) else try std.Thread.spawn(
        internal_os.thread.spawn_config,
        ReadThread.threadMainPosix,
        .{ pty_fds.read, io, pipe[0] },
    );
    read_thread.setName(global.io(), "io-reader") catch {};

    // Setup our threadata backend state to be our own
    td.backend = .{ .exec = .{
        .start = process_start,
        .write_stream = stream,
        .process = process,
        .read_thread = read_thread,
        .read_thread_pipe = if (comptime is_windows) {} else pipe[1],
        .read_thread_events = events,
        .read_thread_fd = pty_fds.read,
        .pty = if (comptime is_windows) &self.subprocess.pty.? else {},
        .termios_timer = termios_timer,
    } };

    // Start our process watcher. If we have an xev.Process use it.
    if (process) |*p| p.wait(
        td.loop,
        &td.backend.exec.process_wait_c,
        termio.Termio.ThreadData,
        td,
        processExit,
    ) else if (comptime build_config.flatpak) flatpak: {
        switch (self.subprocess.process orelse break :flatpak) {
            // If we're in flatpak and we have a flatpak command
            // then we can run the special flatpak logic for watching.
            .flatpak => |*c| c.waitXev(
                td.loop,
                &td.backend.exec.flatpak_wait_c,
                termio.Termio.ThreadData,
                td,
                flatpakExit,
            ),

            .fork_exec => {},
        }
    }

    // Start our termios timer. We don't support this on Windows.
    // Fundamentally, we could support this on Windows so we're just
    // waiting for someone to implement it.
    if (comptime builtin.target.os.tag != .windows) {
        termios_timer.run(
            td.loop,
            &td.backend.exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }
}

pub fn threadExit(self: *Exec, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    if (exec.exited) self.subprocess.externalExit();
    self.subprocess.stop();

    // Quit our read thread after exiting the subprocess so that
    // we don't get stuck waiting for data to stop flowing if it is
    // a particularly noisy process.
    if (comptime is_windows) {
        if (windows.exp.kernel32.SetEvent(exec.read_thread_events.quit) == windows.FALSE) {
            log.warn("error signalling read thread quit event err={}", .{windows.GetLastError()});
        }
    } else switch (posix.errno(posix.system.write(exec.read_thread_pipe, "x", 1))) {
        .SUCCESS => {},

        // EPIPE means that our read thread is closed already, which is
        // completely fine since that is what we were trying to achieve.
        .PIPE => {},

        else => |e| log.warn(
            "error writing to read thread quit pipe err=E{s}",
            .{@tagName(e)},
        ),
    }

    exec.read_thread.join();

    // Nothing reads the pty anymore, and closing the pseudo console
    // can block until its output is drained, so make sure it is closed
    // from a helper thread before the pty is torn down.
    if (comptime is_windows) exec.pty.closeConsoleAsync();
}

pub fn focusGained(
    self: *Exec,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;

    assert(td.backend == .exec);
    const execdata = &td.backend.exec;

    // Windows has no termios, so there is nothing to poll.
    if (comptime builtin.target.os.tag == .windows) return;

    if (!focused) {
        // Flag the timer to end on the next iteration. This is
        // a lot cheaper than doing full timer cancellation.
        execdata.termios_timer_running = false;
    } else {
        // Always set this to true. There is a race condition if we lose
        // focus and regain focus before the termios timer ticks where
        // if we don't set this unconditionally the timer will end on
        // the next iteration.
        execdata.termios_timer_running = true;

        // If we're focused, we want to start our termios timer. We
        // only do this if it isn't already running. We use the termios
        // callback because that'll trigger an immediate state check AND
        // start the timer.
        if (execdata.termios_timer_c.state() != .active) {
            _ = termiosTimer(td, undefined, undefined, {});
        }
    }
}

pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    return try self.subprocess.resize(grid_size, screen_size);
}

fn processExitCommon(td: *termio.Termio.ThreadData, exit_code: u32) void {
    assert(td.backend == .exec);
    const execdata = &td.backend.exec;
    execdata.exited = true;

    // Determine how long the process was running for.
    const runtime_ms: u64 = @max(
        0,
        execdata.start.untilNow(global.io(), .awake).toMilliseconds(),
    );
    log.debug("child process exited status={} runtime={}ms", .{ exit_code, runtime_ms });

    // The child is gone, so close the pseudo console. That flushes its
    // last output and then ends the output pipe, which the read thread
    // sees as EOF. Give it a moment to hand everything to the terminal
    // before we tell the surface, which may close right away.
    if (comptime is_windows) {
        execdata.pty.closeConsoleAsync();
        const wait = windows.exp.kernel32.WaitForSingleObject(
            execdata.read_thread_events.drained,
            DRAIN_TIMEOUT_MS,
        );
        if (wait != windows.WAIT_OBJECT_0) log.warn(
            "read thread did not drain within {}ms after child exit result={}",
            .{ DRAIN_TIMEOUT_MS, wait },
        );
    }

    // We always notify the surface immediately that the child has
    // exited and some metadata about the exit.
    _ = td.surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = exit_code,
            .runtime_ms = runtime_ms,
        },
    }, .{ .forever = {} });
}

fn processExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
    return .disarm;
}

fn flatpakExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *FlatpakHostCommand.Completion,
    r: FlatpakHostCommand.WaitError!u8,
) void {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
}

fn termiosTimer(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    // log.debug("termios timer fired", .{});

    // This should never happen because we guard starting our
    // timer on windows but we want this assertion to fire if
    // we ever do start the timer on windows.
    // TODO: support on windows
    if (comptime builtin.target.os.tag == .windows) {
        @panic("termios timer not implemented on Windows");
    }

    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in termios timer callback err={}", .{err});
            @panic("crash in termios timer callback");
        },
    };

    const td = td_.?;
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    // This is kind of hacky but we rebuild a Pty struct to get the
    // termios data.
    const mode: ptypkg.Mode = (Pty{
        .master = exec.read_thread_fd,
        .slave = undefined,
    }).getMode() catch |err| err: {
        log.warn("error getting termios mode err={}", .{err});

        // If we have an error we return the default mode values
        // which are the likely values.
        break :err .{};
    };

    // If the mode changed, then we process it.
    if (!std.meta.eql(mode, exec.termios_mode)) mode_change: {
        log.debug("termios change mode={}", .{mode});
        exec.termios_mode = mode;

        // We assume we're in some sort of password input if we're
        // in canonical mode and not echoing. This is a heuristic.
        const password_input = mode.canonical and !mode.echo;

        // If our password input state changed on the terminal then
        // we notify the surface.
        {
            td.renderer_state.mutex.lockUncancelable(global.io());
            defer td.renderer_state.mutex.unlock(global.io());
            const t = td.renderer_state.terminal;
            if (t.flags.password_input == password_input) {
                break :mode_change;
            }
        }

        // We have to notify the surface that we're in password input.
        // We must block on this because the balanced true/false state
        // of this is critical to apprt behavior.
        _ = td.surface_mailbox.push(.{
            .password_input = password_input,
        }, .{ .forever = {} });
    }

    // Repeat the timer
    if (exec.termios_timer_running) {
        exec.termios_timer.run(
            td.loop,
            &exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }

    return .disarm;
}

pub fn queueWrite(
    self: *Exec,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const exec = &td.backend.exec;

    // If our process is exited then we don't send any more writes.
    if (exec.exited) return;

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const w = try exec.write_pool.create(alloc);
        w.td = exec;
        const buf = &w.buf;
        const slice = slice: {
            // The maximum end index is either the end of our data or
            // the end of our buffer, whichever is smaller.
            const max = @min(data.len, i + buf.len);

            // Fast
            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow, have to replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                // CRLF
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        //for (slice) |b| log.warn("write: {x}", .{b});

        exec.write_stream.queueWrite(
            td.loop,
            &exec.write_queue,
            &w.req,
            .{ .slice = slice },
            ThreadData.Write,
            w,
            ttyWrite,
        );
        if (comptime is_windows) latency.markWrite(slice.len);
    }
}

fn ttyWrite(
    w_: ?*ThreadData.Write,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const w = w_.?;
    w.td.write_pool.destroy(w);

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{d});

    return .disarm;
}

/// The thread local data for the exec implementation.
pub const ThreadData = struct {
    /// The state for a single queued pty write. The write request and
    /// the buffer it writes from must both remain pointer-stable until
    /// the write completes, so they're pooled together and checked out
    /// per write.
    pub const Write = struct {
        /// Backpointer to the thread data so the write completion
        /// callback can put this back into the pool.
        td: *ThreadData,

        /// The libxev write request.
        req: xev.WriteRequest,

        /// The buffer for the data being written.
        buf: [64]u8,
    };

    /// Process start time and boolean of whether its already exited.
    start: std.Io.Timestamp,
    exited: bool = false,

    /// The data stream is the main IO for the pty.
    write_stream: xev.Stream,

    /// The process watcher
    process: ?xev.Process,

    /// This is the pool of available (unused) write states. If you grab
    /// one from the pool, you must put it back when you're done!
    write_pool: std.heap.MemoryPool(Write) = .empty,

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// This is used for both waiting for the process to exit and then
    /// subsequently to wait for the data_stream to close.
    process_wait_c: xev.Completion = .{},

    // The completion specific to Flatpak process waiting. If
    // we aren't compiling with Flatpak support this is zero-sized.
    flatpak_wait_c: FlatpakHostCommand.Completion = .{},

    /// Reader thread state
    read_thread: std.Thread,
    read_thread_pipe: if (is_windows) void else posix.fd_t,
    read_thread_events: WindowsEvents,
    read_thread_fd: posix.fd_t,

    /// The pty, so the child exit path can close the pseudo console (Windows).
    pty: if (is_windows) *Pty else void,

    /// The timer to detect termios state changes.
    termios_timer: xev.Timer,
    termios_timer_c: xev.Completion = .{},
    termios_timer_running: bool = true,

    /// The last known termios mode. Used for change detection
    /// to prevent unnecessary locking of expensive mutexes.
    termios_mode: ptypkg.Mode = .{},

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        if (comptime is_windows) self.read_thread_events.deinit() else closeFd(self.read_thread_pipe);

        // Clear our write pool. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_pool.deinit(alloc);

        // Stop our process watcher
        if (self.process) |*p| p.deinit();

        // Stop our write stream
        self.write_stream.deinit();

        // Stop our termios timer
        self.termios_timer.deinit();
    }
};

pub const Config = struct {
    command: ?configpkg.Command = null,

    /// The environment for the subprocess. init takes ownership of this
    /// whether or not it succeeds, so the caller must not free it after
    /// calling init.
    env: EnvMap,
    env_override: configpkg.RepeatableStringMap = .{},
    shell_integration: configpkg.Config.ShellIntegration = .detect,
    shell_integration_features: configpkg.Config.ShellIntegrationFeatures = .{},
    cursor_blink: ?bool = null,
    working_directory: ?[]const u8 = null,
    resources_dir: ?[]const u8,
    term: []const u8,

    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,
};

const Subprocess = struct {
    const c = @import("posix_c");

    arena: std.heap.ArenaAllocator,
    cwd: ?[:0]const u8,
    env: ?EnvMap,
    args: []const [:0]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    process: ?Process = null,

    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,

    /// Union that represents the running process type.
    const Process = union(enum) {
        /// Standard POSIX fork/exec
        fork_exec: Command,

        /// Flatpak DBus command
        flatpak: FlatpakHostCommand,
    };

    const ArgsFormatter = struct {
        args: []const [:0]const u8,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("`{s}`", .{a});
            }
        }
    };

    /// Initialize the subprocess. This will NOT start it, this only sets
    /// up the internal state necessary to start it later.
    pub fn init(gpa: Allocator, cfg: Config) !Subprocess {
        // We have a lot of maybe-allocations that all share the same lifetime
        // so use an arena so we don't end up in an accounting nightmare.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Get our env. If a default env isn't provided by the caller
        // then we get it ourselves.
        var env = cfg.env;
        errdefer env.deinit();

        // Diagnostic variables of the Windows port stay with Ghostty.
        if (comptime is_windows) {
            internal_os.windows.scrubDiagnosticEnv(&env);
        }

        // If we have a resources dir then set our env var
        if (cfg.resources_dir) |dir| {
            log.info("found Ghostty resources dir: {s}", .{dir});
            try env.put("GHOSTTY_RESOURCES_DIR", dir);
        }

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (cfg.resources_dir) |base| {
            try env.put("TERM", cfg.term);
            try env.put("COLORTERM", "truecolor");

            // Assume that the resources directory is adjacent to the terminfo
            // database
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir = try std.mem.print(&buf, "{s}/terminfo", .{
                std.fs.path.dirname(base) orelse unreachable,
            });
            try env.put("TERMINFO", dir);
        } else {
            if (comptime builtin.target.os.tag.isDarwin()) {
                log.warn("ghostty terminfo not found, using xterm-256color", .{});
                log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
                log.warn("you're using a valid app bundle.", .{});
            }

            try env.put("TERM", "xterm-256color");
            try env.put("COLORTERM", "truecolor");
        }

        // Add our binary to the path if we can find it.
        ghostty_path: {
            // Skip this for flatpak since host cannot reach them
            if ((comptime build_config.flatpak) and
                internal_os.isFlatpak())
            {
                break :ghostty_path;
            }

            var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const exe_bin_path = exe_buf[0 .. std.process.executablePath(
                global.io(),
                &exe_buf,
            ) catch |err| {
                log.warn("failed to get ghostty exe path err={}", .{err});
                break :ghostty_path;
            }];
            const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :ghostty_path;
            log.debug("appending ghostty bin to path dir={s}", .{exe_dir});

            // We always set this so that if the shell overwrites the path
            // scripts still have a way to find the Ghostty binary when
            // running in Ghostty.
            try env.put("GHOSTTY_BIN_DIR", exe_dir);

            // Append if we have a path. We want to append so that ghostty is
            // the last priority in the path. If we don't have a path set
            // then we just set it to the directory of the binary.
            if (env.get("PATH")) |path| {
                // Verify that our path doesn't already contain this entry
                var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry, exe_dir)) break :ghostty_path;
                }

                try env.put(
                    "PATH",
                    try appendEnv(alloc, path, exe_dir),
                );
            } else {
                try env.put("PATH", exe_dir);
            }
        }

        // On macOS, export additional data directories from our
        // application bundle.
        if (comptime builtin.target.os.tag.isDarwin()) darwin: {
            const resources_dir = cfg.resources_dir orelse break :darwin;

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

            const xdg_data_dir_key = "XDG_DATA_DIRS";
            if (std.mem.print(&buf, "{s}/..", .{resources_dir})) |data_dir| {
                try env.put(
                    xdg_data_dir_key,
                    try appendEnv(
                        alloc,
                        env.get(xdg_data_dir_key) orelse "/usr/local/share:/usr/share",
                        data_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; err={}", .{ xdg_data_dir_key, err });
            }

            const manpath_key = "MANPATH";
            if (std.mem.print(&buf, "{s}/../man", .{resources_dir})) |man_dir| {
                // Always append with colon in front, as it mean that if
                // `MANPATH` is empty, then it should be treated as an extra
                // path instead of overriding all paths set by OS.
                try env.put(
                    manpath_key,
                    try appendEnvAlways(
                        alloc,
                        env.get(manpath_key) orelse "",
                        man_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; man pages may not be available; err={}", .{ manpath_key, err });
            }
        }

        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

        // VTE_VERSION is set by gnome-terminal and other VTE-based terminals.
        // We don't want our child processes to think we're running under VTE.
        // This is not apprt-specific, so we do it here.
        _ = env.orderedRemove("VTE_VERSION");

        // Setup our shell integration, if we can.
        const shell_command: configpkg.Command = shell: {
            const default_shell_command: configpkg.Command =
                cfg.command orelse .{ .shell = switch (builtin.target.os.tag) {
                    .windows => "cmd.exe",
                    else => "sh",
                } };

            // Always set up shell features (GHOSTTY_SHELL_FEATURES). These are
            // used by both automatic and manual shell integrations.
            try shell_integration.setupFeatures(
                &env,
                cfg.shell_integration_features,
                cfg.cursor_blink orelse true,
            );

            const force: ?shell_integration.Shell = switch (cfg.shell_integration) {
                .none => {
                    // This is a source of confusion for users despite being
                    // opt-in since it results in some Ghostty features not
                    // working. We always want to log it.
                    log.info("shell integration disabled by configuration", .{});
                    break :shell default_shell_command;
                },

                .detect => null,
                .bash => .bash,
                .elvish => .elvish,
                .fish => .fish,
                .nushell => .nushell,
                .zsh => .zsh,
            };

            const dir = cfg.resources_dir orelse {
                log.warn("no resources dir set, shell integration disabled", .{});
                break :shell default_shell_command;
            };

            const integration = try shell_integration.setup(
                alloc,
                dir,
                default_shell_command,
                &env,
                force,
            ) orelse {
                log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
                break :shell default_shell_command;
            };

            log.info(
                "shell integration automatically injected shell={}",
                .{integration.shell},
            );

            break :shell integration.command;
        };

        // Add the environment variables that override any others.
        {
            var it = cfg.env_override.iterator();
            while (it.next()) |entry| try env.put(
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }

        // Build our args list
        const args: []const [:0]const u8 = execCommand(
            alloc,
            shell_command,
            internal_os.passwd,
        ) catch |err| switch (err) {
            // If we fail to allocate space for the command we want to
            // execute, we'd still like to try to run something so
            // Ghostty can launch (and maybe the user can debug this further).
            // Realistically, if you're getting OOM, I think other stuff is
            // about to crash, but we can try.
            error.OutOfMemory => oom: {
                log.warn("failed to allocate space for command args, falling back to basic shell", .{});

                // The comptime here is important to ensure the full slice
                // is put into the binary data and not the stack.
                break :oom comptime switch (builtin.target.os.tag) {
                    .windows => &.{"cmd.exe"},
                    else => &.{"/bin/sh"},
                };
            },

            // This logs on its own, this is a bad error.
            error.SystemError => return err,
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        const cwd: ?[:0]u8 = if (cfg.working_directory) |cwd|
            try alloc.dupeSentinel(u8, cwd, 0)
        else
            null;

        // Propagate the current working directory (CWD) to the shell, enabling
        // the shell to display the current directory name rather than the
        // resolved path for symbolic links. This is important and based
        // on the same behavior in Konsole and Kitty (see the linked issues):
        // https://bugs.kde.org/show_bug.cgi?id=242114
        // https://github.com/kovidgoyal/kitty/issues/1595
        // https://github.com/ghostty-org/ghostty/discussions/7769
        if (cwd) |pwd| try env.put("PWD", pwd);

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .args = args,

            .rt_pre_exec_info = cfg.rt_pre_exec_info,
            .rt_post_fork_info = cfg.rt_post_fork_info,

            // Should be initialized with initTerminal call.
            .grid_size = .{},
            .screen_size = .{ .width = 1, .height = 1 },
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
        if (self.env) |*env| env.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start the subprocess. If the subprocess is already started this
    /// will crash.
    pub fn start(self: *Subprocess, alloc: Allocator) !struct {
        read: Pty.Fd,
        write: Pty.Fd,
    } {
        assert(self.pty == null and self.process == null);

        // This function is funny because on POSIX systems it can
        // fail in the forked process. This is flipped to true if
        // we're in an error state in the forked process (child
        // process).
        var in_child: bool = false;

        // Create our pty
        var pty = try Pty.open(.{
            .ws_row = @intCast(self.grid_size.rows),
            .ws_col = @intCast(self.grid_size.columns),
            .ws_xpixel = @intCast(self.screen_size.width),
            .ws_ypixel = @intCast(self.screen_size.height),
        });
        self.pty = pty;
        errdefer if (!in_child) {
            if (comptime builtin.target.os.tag != .windows) {
                _ = posix.system.close(pty.slave);
            }

            pty.deinit();
            self.pty = null;
        };

        // Cleanup we only run in our parent when we successfully start
        // the process.
        defer if (!in_child and self.process != null) {
            if (comptime builtin.target.os.tag != .windows) {
                // Once our subcommand is started we can close the slave
                // side. This prevents the slave fd from being leaked to
                // future children.
                _ = posix.system.close(pty.slave);
            } else {
                // The pseudo console holds its own copies of the child
                // side handles. Closing ours is what lets the output pipe
                // report EOF once the pseudo console closes.
                self.pty.?.closeChildSide();
            }

            // Successful start we can clear out some memory.
            if (self.env) |*env| {
                env.deinit();
                self.env = null;
            }
        };

        log.debug("starting command command={f}", .{ArgsFormatter{ .args = self.args }});

        // If we can't access the cwd, then don't set any cwd and inherit.
        // This is important because our cwd can be set by the shell (OSC 7)
        // and we don't want to break new windows.
        const cwd: ?[:0]const u8 = if (self.cwd) |proposed| cwd: {
            if ((comptime build_config.flatpak) and internal_os.isFlatpak()) {
                // Flatpak sandboxing prevents access to certain reserved paths
                // regardless of configured permissions. Perform a test spawn
                // to get around this problem
                //
                // https://docs.flatpak.org/en/latest/sandbox-permissions.html#reserved-paths
                log.info("flatpak detected, will use host command to verify cwd access", .{});
                const dev_null = try std.Io.Dir.cwd().openFile(
                    global.io(),
                    "/dev/null",
                    .{ .mode = .read_write },
                );
                defer dev_null.close(global.io());
                var cmd: internal_os.FlatpakHostCommand = .{
                    .argv = &[_][]const u8{
                        "/bin/sh",
                        "-c",
                        ":",
                    },
                    .cwd = proposed,
                    .stdin = dev_null.handle,
                    .stdout = dev_null.handle,
                    .stderr = dev_null.handle,
                };
                _ = cmd.spawn(alloc) catch |err| {
                    log.warn("cannot spawn command at cwd, ignoring: {}", .{err});
                    break :cwd null;
                };
                _ = try cmd.wait();

                break :cwd proposed;
            }

            if (std.Io.Dir.cwd().access(global.io(), proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;

        // In flatpak, we use the HostCommand to execute our shell.
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }

            // Flatpak command must have a stable pointer.
            self.process = .{ .flatpak = .{
                .argv = self.args,
                .cwd = cwd,
                .env = if (self.env) |*env| env else null,
                .stdin = pty.slave,
                .stdout = pty.slave,
                .stderr = pty.slave,
            } };
            var cmd = &self.process.?.flatpak;
            const pid = try cmd.spawn(alloc);
            errdefer killCommandFlatpak(cmd);

            log.info("started subcommand on host via flatpak API path={s} pid={}", .{
                self.args[0],
                pid,
            });

            return .{
                .read = pty.master,
                .write = pty.master,
            };
        }

        // Build our subcommand
        var cmd: Command = .{
            .path = self.args[0],
            .args = self.args,
            .env = if (self.env) |*env| env else null,
            .cwd = cwd,
            .stdin = if (builtin.target.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .stdout = if (builtin.target.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .stderr = if (builtin.target.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .pseudo_console = if (builtin.target.os.tag == .windows) pty.pseudo_console else {},
            .os_pre_exec = switch (comptime builtin.target.os.tag) {
                .windows => null,
                else => f: {
                    const f = struct {
                        fn callback(cmd: *Command) ?u8 {
                            const sp = cmd.getData(Subprocess) orelse unreachable;
                            sp.childPreExec() catch |err| log.err(
                                "error initializing child: {}",
                                .{err},
                            );
                            return null;
                        }
                    };
                    break :f f.callback;
                },
            },
            .rt_pre_exec = if (comptime @hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.preExec else null,
            .rt_pre_exec_info = self.rt_pre_exec_info,
            .rt_post_fork = if (comptime @hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.postFork else null,
            .rt_post_fork_info = self.rt_post_fork_info,
            .data = self,
        };

        cmd.start(alloc) catch |err| {
            // We have to do this because start on Windows can't
            // ever return ExecFailedInChild
            const StartError = error{ExecFailedInChild} || @TypeOf(err);
            switch (@as(StartError, err)) {
                // If we fail in our child we need to flag it so our
                // errdefers don't run.
                error.ExecFailedInChild => {
                    in_child = true;
                    return err;
                },

                else => return err,
            }
        };
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });

        self.process = .{ .fork_exec = cmd };
        return switch (builtin.target.os.tag) {
            .windows => .{
                .read = pty.out_pipe,
                .write = pty.in_pipe,
            },

            else => .{
                .read = pty.master,
                .write = pty.master,
            },
        };
    }

    /// This should be called after fork but before exec in the child process.
    /// To repeat: this function RUNS IN THE FORKED CHILD PROCESS before
    /// exec is called; it does NOT run in the main Ghostty process.
    fn childPreExec(self: *Subprocess) !void {
        // Setup our pty
        try self.pty.?.childPreExec();
    }

    /// Called to notify that we exited externally so we can unset our
    /// running state.
    pub fn externalExit(self: *Subprocess) void {
        // The child is gone on its own. Whatever it left running stays.
        if (comptime is_windows) {
            if (self.process) |*p| switch (p.*) {
                .fork_exec => |*cmd| {
                    cmd.closeProcess();
                },
                .flatpak => {},
            };
        }
        self.process = null;
    }

    /// Stop the subprocess. This is safe to call anytime. This will wait
    /// for the subprocess to register that it has been signalled, but not
    /// for it to terminate, so it will not block.
    /// This does not close the pty.
    pub fn stop(self: *Subprocess) void {
        switch (self.process orelse return) {
            .fork_exec => |*cmd| {
                // Note: this will also wait for the command to exit, so
                // DO NOT call cmd.wait
                killCommand(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});

                // Closing the pseudo console sends CTRL_CLOSE_EVENT to
                // the console clients attached to it, which ends them.
                if (comptime is_windows) {
                    if (self.pty) |*pty| pty.closeConsoleAsync();
                }
            },

            .flatpak => |*cmd| if (comptime build_config.flatpak) {
                killCommandFlatpak(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});
                _ = cmd.wait() catch |err|
                    log.err("error waiting for command to exit: {}", .{err});
            },
        }

        self.process = null;
    }

    /// Resize the pty subprocess. This is safe to call anytime.
    pub fn resize(
        self: *Subprocess,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        self.grid_size = grid_size;
        self.screen_size = screen_size;

        if (self.pty) |*pty| {
            // It is theoretically possible for the grid or screen size to
            // exceed u16, although the terminal in that case isn't very
            // usable. This should be protected upstream but we still clamp
            // in case there is a bad caller which has happened before.
            try pty.setSize(.{
                .ws_row = std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
                .ws_col = std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
                .ws_xpixel = std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
                .ws_ypixel = std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            });
        }
    }

    /// Kill the underlying subprocess. This sends a SIGHUP to the child
    /// process. This also waits for the command to exit and will return the
    /// exit code.
    fn killCommand(command: *Command) !void {
        if (command.pid) |pid| {
            switch (builtin.target.os.tag) {
                .windows => {
                    // Only the child goes. The console programs attached
                    // to its pseudo console end when stop closes it; ones
                    // with a console of their own and GUI programs stay.
                    defer command.closeProcess();
                    try command.killChild();

                    _ = try command.wait(false);
                },

                else => try killPid(pid),
            }
        }
    }

    fn killPid(pid: c.pid_t) !void {
        const pgid = getpgid(pid) orelse return;

        // It is possible to send a killpg between the time that
        // our child process calls setsid but before or simultaneous
        // to calling execve. In this case, the direct child dies
        // but grandchildren survive. To work around this, we loop
        // and repeatedly kill the process group until all
        // descendents are well and truly dead. We will not rest
        // until the entire family tree is obliterated.
        while (true) {
            switch (posix.errno(c.killpg(pgid, c.SIGHUP))) {
                .SUCCESS => log.debug("process group killed pgid={}", .{pgid}),
                else => |err| killpg: {
                    if ((comptime builtin.target.os.tag.isDarwin()) and
                        err == .PERM)
                    {
                        log.debug("killpg failed with EPERM, expected on Darwin and ignoring", .{});
                        break :killpg;
                    }

                    log.warn("error killing process group pgid={} err={}", .{ pgid, err });
                    return error.KillFailed;
                },
            }

            // See Command.zig wait for why we specify WNOHANG.
            // The gist is that it lets us detect when children
            // are still alive without blocking so that we can
            // kill them again.
            const res_pid = while (true) {
                const rc = posix.system.waitpid(pid, null, std.c.W.NOHANG);
                if (posix.errno(rc) == .INTR) continue;
                break rc;
            };
            log.debug("waitpid result={}", .{res_pid});
            if (res_pid != 0) break;
            try std.Io.sleep(global.io(), .fromMilliseconds(10), .awake);
        }
    }

    fn getpgid(pid: c.pid_t) ?c.pid_t {
        // Get our process group ID. Before the child pid calls setsid
        // the pgid will be ours because we forked it. Its possible that
        // we may be calling this before setsid if we are killing a surface
        // VERY quickly after starting it.
        const my_pgid = c.getpgid(0);

        // We loop while pgid == my_pgid. The expectation if we have a valid
        // pid is that setsid will eventually be called because it is the
        // FIRST thing the child process does and as far as I can tell,
        // setsid cannot fail. I'm sure that's not true, but I'd rather
        // have a bug reported than defensively program against it now.
        while (true) {
            const pgid = c.getpgid(pid);
            if (pgid == my_pgid) {
                log.warn("pgid is our own, retrying", .{});
                std.Io.sleep(global.io(), .fromMilliseconds(10), .awake) catch {};
                continue;
            }

            // Don't know why it would be zero but its not a valid pid
            if (pgid == 0) return null;

            // If the pid doesn't exist then... we're done!
            if (pgid == c.ESRCH) return null;

            // If we have an error we're done.
            if (pgid < 0) {
                log.warn("error getting pgid for kill", .{});
                return null;
            }

            return pgid;
        }
    }

    /// Kill the underlying process started via Flatpak host command.
    /// This sends a signal via the Flatpak API.
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }

    /// Get information about the process(es) running within the subprocess.
    /// Returns `null` if there was an error getting the information or the
    /// information is not available on a particular platform.
    pub fn getProcessInfo(self: *Subprocess, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        const pty = &(self.pty orelse return null);
        return pty.getProcessInfo(info);
    }
};

/// The read thread works with a companion gather thread to form a two-stage
/// pipeline that moves pty output into the terminal:
///
///   io-gather:  read()/poll() the pty into one of a few rotating
///               buffers, batching bulk output.
///   io-reader:  hand each filled buffer to processOutput (terminal
///               lock, VT parse, state update, render scheduling).
///
/// This used to be a single serial loop (and still is on Windows):
///
///   while (true) { blocking_read(); exit_if_eof(); process(); }
///
/// I found on macOS that the kernel tty output queue caps every read
/// on the master at 1 KB no matter how large the read buffer is. This means
/// that producers (e.g. `cat`) stall with the above architecture because
/// there are windows in the `process()` part where we aren't draining
/// the kernel pty fd.
///
/// Instead, having a separate thread gather and drain the kernel pty
/// into a rotating set of preallocated buffers minimizes this stall
/// period to effectively zero: while the io-reader thread parses
/// one batch, the gather thread is draining the kernel queue. There is
/// still stalling (our VT parse is a bottleneck now), but we don't stall
/// between them.
///
/// Interactive latency is preserved: a batch is delivered on the
/// first EAGAIN unless the stream is saturated (>= 1 KiB gathered
/// means the writer filled the kernel queue), in which case we bridge
/// the producer's microsecond refill gaps with a short poll, bounded
/// by a small total budget per batch that is well under a display
/// frame. This means that small outputs that are more typical continue
/// to be interactive.
///
/// We use basic poll/read syscalls here because we are only
/// monitoring two fds and this is still much faster and lower
/// overhead than any async mechanism.
pub const ReadThread = struct {
    /// The number of buffers rotated between the gather and parse
    /// stages. The gather stage can run at most this many batches
    /// ahead of the parse stage before it blocks, which (via the
    /// kernel pty queue) is also what preserves flow control to the
    /// child. Empirically chosen through measurements on an M4 Max.
    /// Less than 4 there are minor slowdowns, above 4 there are no
    /// improvements.
    const buffer_count = 4;

    /// The capacity of each gather buffer. One batch is also the unit
    /// of work the parse stage does per terminal lock acquisition, so
    /// this bounds both gather latency and lock hold time.
    const buffer_capacity = 64 * 1024;

    /// How many gathered bytes mark a stream as saturated. The macOS
    /// kernel tty output queue hands the master at most about 1 KiB
    /// per read, so gathering a full 1 KiB means the writer filled
    /// the queue (a bulk stream worth briefly waiting on), while
    /// anything smaller is an interactive trickle that must be
    /// delivered with no added latency.
    const bridge_threshold = 1024;

    /// How many times an EAGAIN on a saturated stream is retried
    /// with an immediate read before we're willing to sleep in poll.
    /// Basically, a spin retry.
    ///
    /// The writer refills the drained kernel queue within a few
    /// microseconds, while a sleep and wakeup through poll costs
    /// several more. If the gather stage sleeps on every refill gap,
    /// the whole pipeline degenerates to lockstep with the writer at
    /// about 1 KiB per wakeup. A short burst of nonblocking reads
    /// bridges nearly all refill gaps without sleeping. Measured, 8
    /// to 16 retries catches over 90% of the gaps and nearly doubles
    /// the saturated drain rate, and larger values helped little.
    /// The cost is bounded to at most this many extra ~0.5us read
    /// syscalls per gap, and we only spin on streams that already
    /// gathered a full kernel queue, so an idle or interactive
    /// terminal never spins.
    const bridge_spin_max = 16;

    /// How long one bridge poll waits for the writer's next refill
    /// once the spin retries above have failed. If the stream is
    /// quiet for this long the burst is over and we deliver what we
    /// have.
    const bridge_poll_timeout_ms = 1;

    /// The longest one batch may spend bridging refill gaps before it
    /// is delivered regardless. This bounds output latency for
    /// streams that produce just enough to keep bridging. Three
    /// milliseconds is well under one display frame, so batching is
    /// invisible on screen.
    const gather_budget_ns = 3 * std.time.ns_per_ms;

    /// The state shared between the gather and parse stages. This is
    /// a fixed ring of buffers plus the metadata to rotate ownership
    /// between the two threads. A buffer is owned by exactly one
    /// stage at a time, so buffer contents need no locking. Only the
    /// ring metadata is guarded by the mutex.
    const Pipeline = struct {
        mutex: std.Io.Mutex = .init,

        /// Signaled when a batch is published or the gather stage is
        /// done. Waited on by the parse stage.
        batch_ready: std.Io.Condition = .init,

        /// Signaled when a batch has been consumed. Waited on by the
        /// gather stage when all buffers are in flight (backpressure).
        slot_free: std.Io.Condition = .init,

        /// The number of valid bytes in each buffer. Set at publish
        /// time by the gather stage, read by the parse stage.
        lens: [buffer_count]usize = @splat(0),

        /// Ring state: head is the next slot the gather stage fills,
        /// tail is the next slot the parse stage consumes, count is
        /// the number of published, unconsumed batches.
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        /// Set by the gather stage (under the mutex) while it sleeps
        /// in a bridge poll. The parse stage only writes to the idle
        /// pipe when this is set, so an interactive terminal never
        /// pays the pipe syscalls.
        bridging: bool = false,

        /// A self-pipe the parse stage uses to interrupt the gather
        /// stage's bridge poll the moment it runs out of batches.
        /// Bridging a refill gap is only free while the parse stage
        /// is busy; once it goes idle, every additional microsecond
        /// spent bridging is added straight to output latency. The
        /// write end is used by the parse stage, the read end is
        /// polled by the gather stage. -1 when unavailable, in which
        /// case bridge polls are bounded by their timeout only.
        idle_read_fd: posix.fd_t = -1,
        idle_write_fd: posix.fd_t = -1,

        /// Set by the gather stage when the stream is over (quit
        /// signal, EOF, or pty error). The parse stage drains any
        /// remaining batches and then exits.
        done: bool = false,

        /// The buffer storage itself.
        bufs: [buffer_count][buffer_capacity]u8 = undefined,
    };

    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer _ = posix.system.close(quit);

        // Right now, on Darwin, `std.Thread.setName` can only name the current
        // thread, and we have no way to get the current thread from within it,
        // so instead we use this code to name the thread instead.
        if (builtin.target.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-reader".*);
            setQosClass();
        }

        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        // Set the fd to non-blocking so the gather stage can drain it
        // in a tight loop and fall back to poll for readiness. The
        // pipeline can't run with a blocking fd (a blocking read
        // would hang the gather stage on a quiet pty), but this also
        // can't realistically fail on a valid pty master.
        if (!setNonblock(fd)) {
            log.err("read thread exiting, pty fd must be non-blocking", .{});
            return;
        }

        // Shared pipeline
        var pipeline: Pipeline = .{};

        // The idle self-pipe (see the Pipeline field docs). If we
        // can't create it we still run correctly, bridge polls are
        // just bounded by their timeout instead of being interrupted
        // when the parse stage goes idle.
        if (compat_fd.pipe2(.{
            .CLOEXEC = true,
            .NONBLOCK = true,
        })) |fds| {
            pipeline.idle_read_fd = fds[0];
            pipeline.idle_write_fd = fds[1];
        } else |err| {
            log.warn("read thread failed to create idle pipe err={}", .{err});
        }
        defer if (pipeline.idle_read_fd >= 0) {
            compat_fd.close(pipeline.idle_read_fd);
            compat_fd.close(pipeline.idle_write_fd);
        };

        const gather_thread = std.Thread.spawn(
            .{},
            gatherMainPosix,
            .{ fd, quit, &pipeline },
        ) catch |err| {
            // If we can't spawn a thread the process is already
            // doomed (every surface spawns several), so don't try
            // to limp along.
            log.err("read thread exiting, failed to spawn gather thread err={}", .{err});
            return;
        };
        defer gather_thread.join();
        if (comptime !builtin.target.os.tag.isDarwin()) {
            gather_thread.setName(global.io(), "io-gather") catch {};
        }

        // This thread is the parse stage. We consume batches in ring
        // order until the gather stage reports the stream is over and
        // the ring is drained.
        while (true) {
            const batch: []const u8 = batch: {
                pipeline.mutex.lockUncancelable(global.io());
                defer pipeline.mutex.unlock(global.io());
                while (pipeline.count == 0) {
                    if (pipeline.done) return;
                    pipeline.batch_ready.waitUncancelable(global.io(), &pipeline.mutex);
                }
                const slot = pipeline.tail;
                break :batch pipeline.bufs[slot][0..pipeline.lens[slot]];
            };

            // The batch buffer is owned by this stage until we advance
            // the tail below, so it is safe to read outside the lock.
            io.processOutput(batch);

            {
                pipeline.mutex.lockUncancelable(global.io());
                pipeline.tail = (pipeline.tail + 1) % buffer_count;
                pipeline.count -= 1;
                const wake = pipeline.count == 0 and
                    pipeline.bridging and
                    pipeline.idle_write_fd >= 0;
                pipeline.mutex.unlock(global.io());
                pipeline.slot_free.signal(global.io());

                // We ran out of batches while the gather stage is
                // bridging a refill gap: interrupt its poll so it
                // delivers what it has instead of sleeping out the
                // timeout while we sit idle.
                if (wake) {
                    _ = posix.system.write(pipeline.idle_write_fd, "i", 1);
                }
            }

            // Batch boundary: hand the renderer state mutex off if
            // the renderer is waiting. See renderer.State.lockDemand.
            io.renderer_state.yieldToDemand(global.io());
        }
    }

    /// The gather stage. This drains the pty into rotating buffers,
    /// bridging the kernel queue's refill gaps for saturated streams,
    /// and publishes each batch to the parse stage. This thread owns
    /// all fd monitoring, including the quit fd.
    fn gatherMainPosix(fd: posix.fd_t, quit: posix.fd_t, pipeline: *Pipeline) void {
        if (builtin.target.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-gather".*);
            setQosClass();
        }

        // However we exit, tell the parse stage the stream is over so
        // it drains the ring and joins us.
        defer {
            pipeline.mutex.lockUncancelable(global.io());
            pipeline.done = true;
            pipeline.mutex.unlock(global.io());
            pipeline.batch_ready.signal(global.io());
        }

        // The fds we poll: data on the pty, our quit notification,
        // and the parse stage's idle wake. The idle fd only
        // participates in bridge polls (the parse stage only writes
        // while we're bridging), so the outer poll slices it off.
        var pollfds: [3]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = pipeline.idle_read_fd, .events = posix.POLL.IN, .revents = undefined },
        };

        while (true) {
            // Claim the next free buffer. This blocks only when the
            // parse stage is a full ring behind, which is exactly when
            // we should stop reading and let the kernel queue exert
            // backpressure on the child.
            const buf: *[buffer_capacity]u8 = buf: {
                pipeline.mutex.lockUncancelable(global.io());
                defer pipeline.mutex.unlock(global.io());
                while (pipeline.count == buffer_count) {
                    pipeline.slot_free.waitUncancelable(global.io(), &pipeline.mutex);
                }
                break :buf &pipeline.bufs[pipeline.head];
            };

            var total: usize = 0;
            var bridge_start: ?std.Io.Timestamp = null;
            var spins: usize = 0;
            var fatal = false;

            // Fill the buffer from the pty. For a saturated stream the
            // kernel queue momentarily runs dry while the writer
            // refills it in parallel, so we bridge those gaps with
            // spin retries and a short poll instead of delivering a
            // tiny batch.
            gather: while (total < buffer_capacity) {
                const n = posix.read(
                    fd,
                    buf[total..],
                ) catch |err| switch (err) {
                    error.WouldBlock => {
                        // Anything below the threshold is interactive.
                        if (total < bridge_threshold) break :gather;

                        // The stream is saturated, so we bridge the
                        // gap. First retry the read directly a bounded
                        // number of times, since the refill usually
                        // lands within microseconds.
                        if (spins < bridge_spin_max) {
                            spins += 1;
                            continue :gather;
                        }

                        // Still dry, so we want to sleep in poll for
                        // the next refill, within our latency budget.
                        const now = std.Io.Timestamp.now(global.io(), .awake);
                        if (bridge_start) |start| {
                            if (start.durationTo(now).toNanoseconds() >= gather_budget_ns)
                                break :gather;
                        } else bridge_start = now;

                        // Bridging a refill gap is only free while the
                        // parse stage is busy, since the wait hides
                        // behind parse time. Once the parser is idle,
                        // every microsecond we hold this batch is
                        // added straight to output latency, and for a
                        // request/response producer (a burst ending
                        // in a query, e.g. frame + cursor position
                        // report) the writer is blocked on a reply to
                        // data sitting in this buffer, so a poll here
                        // would always sleep its full timeout. Deliver
                        // now if the parser is idle, and otherwise arm
                        // the idle wake so it can interrupt our poll
                        // the moment that changes.
                        {
                            pipeline.mutex.lockUncancelable(global.io());
                            defer pipeline.mutex.unlock(global.io());
                            if (pipeline.count == 0) break :gather;
                            pipeline.bridging = true;
                        }

                        const r = posix.poll(
                            &pollfds,
                            bridge_poll_timeout_ms,
                        ) catch |poll_err| {
                            clearBridging(pipeline);
                            log.warn("bridge poll failed err={}", .{poll_err});
                            break :gather;
                        };
                        clearBridging(pipeline);

                        // Quiet for a full timeout means the burst
                        // ended.
                        if (r == 0) break :gather;

                        // On a quit signal we deliver what we have
                        // and stop.
                        if (pollfds[1].revents & posix.POLL.IN != 0) {
                            log.info("read thread got quit signal", .{});
                            fatal = true;
                            break :gather;
                        }

                        // The parse stage went idle: drain the wake
                        // and deliver what we have. The pty may have
                        // data as well, but the next batch can pick
                        // that up; an idle parser means delivery must
                        // not wait.
                        if (pollfds[2].revents & posix.POLL.IN != 0) {
                            var trash: [16]u8 = undefined;
                            while (true) {
                                const drained = posix.read(
                                    pipeline.idle_read_fd,
                                    &trash,
                                ) catch break;
                                if (drained < trash.len) break;
                            }
                            break :gather;
                        }

                        // HUP without IN means no more data is
                        // coming. Deliver and let the outer poll
                        // decide what to do.
                        if (pollfds[0].revents & posix.POLL.IN == 0)
                            break :gather;

                        continue :gather;
                    },

                    // The pty is closed. We're probably gracefully
                    // shutting down.
                    error.NotOpenForReading,
                    error.InputOutput,
                    => {
                        log.info("io gather exiting", .{});
                        fatal = true;
                        break :gather;
                    },

                    else => {
                        log.err("io gather error err={}", .{err});
                        unreachable;
                    },
                };

                // This happens on macOS instead of WouldBlock when the
                // child process dies. Deliver what we have and let the
                // outer poll detect HUP.
                if (n == 0) break :gather;

                total += n;

                // Each refill gap gets a fresh spin budget.
                spins = 0;
            }

            // Publish the batch (if any) to the parse stage and rotate
            // to the next buffer.
            if (total > 0) {
                pipeline.mutex.lockUncancelable(global.io());
                pipeline.lens[pipeline.head] = total;
                pipeline.head = (pipeline.head + 1) % buffer_count;
                pipeline.count += 1;
                pipeline.mutex.unlock(global.io());
                pipeline.batch_ready.signal(global.io());
            }

            if (fatal) return;

            // A full buffer means the stream is still hot, so go
            // claim the next buffer without an intervening poll.
            if (total == buffer_capacity) continue;

            // Wait for data. The idle fd is sliced off: the parse
            // stage only writes to it while we're bridging.
            _ = posix.poll(pollfds[0..2], -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // If our quit fd is set, we're done.
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }

            // If our pty fd is closed, then we're also done with our
            // read thread.
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pty fd closed, read thread exiting", .{});
                return;
            }
        }
    }

    /// Clears the bridging flag armed before a bridge poll, closing
    /// the window in which the parse stage writes idle wakes.
    fn clearBridging(pipeline: *Pipeline) void {
        pipeline.mutex.lockUncancelable(global.io());
        defer pipeline.mutex.unlock(global.io());
        pipeline.bridging = false;
    }

    /// Sets the QoS class of the calling thread for the read pipeline
    /// (macOS only). Both pipeline threads feed content the user is
    /// actively watching, and at default QoS the scheduler may place
    /// them on efficiency cores with wakeup latencies that are large
    /// compared to the ~10us cadence of the pty producer/consumer
    /// dance. Measured on an M4 Max, this results in a 15% throughput
    /// difference (on the change, not 15% total).
    fn setQosClass() void {
        internal_os.macos.setQosClass(.user_initiated) catch |err| {
            log.warn("error setting QoS class err={}", .{err});
        };
    }

    /// Sets the fd to non-blocking mode. Returns false on failure.
    fn setNonblock(fd: posix.fd_t) bool {
        const flags = posix.system.fcntl(fd, posix.F.GETFL);
        if (flags == -1) {
            log.warn("read thread failed to get flags err=E{s}", .{@tagName(posix.errno(-1))});
            return false;
        }

        switch (posix.errno(posix.system.fcntl(
            fd,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        ))) {
            .SUCCESS => {},
            else => |e| {
                log.warn("read thread failed to set flags err=E{s}", .{@tagName(e)});
                return false;
            },
        }
        return true;
    }

    fn threadMainWindows(
        fd: posix.fd_t,
        io: *termio.Termio,
        quit_event: windows.HANDLE,
        drained_event: windows.HANDLE,
    ) void {
        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        const Ctx = struct {
            io: *termio.Termio,
            quit: windows.HANDLE,

            fn process(self: @This(), slice: []const u8) void {
                self.io.processOutput(slice);

                // See threadMainPosix: hand the renderer state mutex
                // off if the renderer is waiting, since this loop
                // would otherwise starve it under heavy output.
                self.io.renderer_state.yieldToDemand(global.io());
                latency.markYield();
            }

            fn onData(self: @This(), buf: []const u8) void {
                latency.markOutput(buf.len);
                processSlicedWindows(self.quit, self, buf, process);
            }
        };
        const end = readLoopWindows(fd, quit_event, Ctx{ .io = io, .quit = quit_event }, Ctx.onData);

        switch (end) {
            .quit => log.info("read thread got quit signal", .{}),
            .eof => log.info("pty closed, read thread exiting", .{}),
            .err => log.warn("pty read failed, read thread exiting", .{}),
        }

        // Tell the child exit path that nothing more will be read. A read
        // error also counts: nothing will be drained after it either.
        if (end != .quit) {
            if (windows.exp.kernel32.SetEvent(drained_event) == windows.FALSE) {
                log.warn("error signalling drained event err={}", .{windows.GetLastError()});
            }
        }
    }
};

/// Hand `buf` to `process` in slices of at most `PROCESS_SLICE_LEN` bytes
/// and stop when `quit_event` is signalled (Windows). The rest of `buf` is
/// dropped then, since nobody is left to look at it.
///
/// `process` takes the terminal lock for as long as it works. In a slow
/// build a single 64 KiB read can keep it for many seconds, and that blocks
/// the renderer thread (and so the window teardown that waits for it)
/// as well as this thread's own response to the quit event.
pub fn processSlicedWindows(
    quit_event: windows.HANDLE,
    ctx: anytype,
    buf: []const u8,
    comptime process: fn (@TypeOf(ctx), []const u8) void,
) void {
    var rest = buf;
    while (rest.len > 0) {
        if (windows.exp.kernel32.WaitForSingleObject(quit_event, 0) == windows.WAIT_OBJECT_0) return;
        const len = @min(rest.len, PROCESS_SLICE_LEN);
        process(ctx, rest[0..len]);
        rest = rest[len..];
    }
}

pub const ReadLoopEnd = enum {
    /// The writing side of the pty is gone and everything was delivered.
    eof,

    /// The quit event was signalled.
    quit,

    /// An unexpected read error.
    err,
};

/// Read `handle` (a pipe opened for overlapped I/O) and hand every chunk to
/// `onData` until the stream ends or `quit_event` is signalled. Windows only.
///
/// The read is overlapped so we can wait for data and for the quit event at
/// the same time, instead of cancelling a blocking read from another thread.
pub fn readLoopWindows(
    handle: windows.HANDLE,
    quit_event: windows.HANDLE,
    ctx: anytype,
    comptime onData: fn (@TypeOf(ctx), []const u8) void,
) ReadLoopEnd {
    var buf: [64 * 1024]u8 = undefined;

    const read_event = windows.exp.kernel32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse {
        log.err("error creating read event err={}", .{windows.GetLastError()});
        return .err;
    };
    defer _ = windows.exp.kernel32.CloseHandle(read_event);

    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = read_event;

    while (true) {
        // Check for quit before every read. If the pty is busy a read is
        // always ready, and the wait below would keep picking it over the
        // quit event.
        if (windows.exp.kernel32.WaitForSingleObject(quit_event, 0) == windows.WAIT_OBJECT_0) {
            return .quit;
        }

        var n: windows.DWORD = 0;
        if (windows.exp.kernel32.ReadFile(handle, &buf, buf.len, null, &overlapped) == windows.FALSE) {
            switch (windows.GetLastError()) {
                .IO_PENDING => {},
                .BROKEN_PIPE => return .eof,
                else => |err| {
                    log.err("io reader error err={}", .{err});
                    return .err;
                },
            }

            const handles = [2]windows.HANDLE{ read_event, quit_event };
            const wait = windows.exp.kernel32.WaitForMultipleObjects(
                handles.len,
                &handles,
                windows.FALSE,
                windows.INFINITE,
            );
            if (wait != windows.WAIT_OBJECT_0) {
                // Cancel the read and wait until the kernel is done with
                // our buffer and OVERLAPPED before they go out of scope.
                _ = windows.exp.kernel32.CancelIoEx(handle, &overlapped);
                if (windows.exp.kernel32.GetOverlappedResult(handle, &overlapped, &n, windows.TRUE) != windows.FALSE and n > 0) {
                    onData(ctx, buf[0..n]);
                }

                if (wait == windows.WAIT_OBJECT_0 + 1) return .quit;
                log.err("io reader wait error result={} err={}", .{ wait, windows.GetLastError() });
                return .err;
            }

            if (windows.exp.kernel32.GetOverlappedResult(handle, &overlapped, &n, windows.FALSE) == windows.FALSE) {
                switch (windows.GetLastError()) {
                    .BROKEN_PIPE => return .eof,

                    // Somebody cancelled our read, which only happens
                    // when we are being shut down.
                    .OPERATION_ABORTED => return .quit,

                    else => |err| {
                        log.err("io reader error err={}", .{err});
                        return .err;
                    },
                }
            }
        } else {
            // The read completed at once. With an OVERLAPPED the count
            // `ReadFile` reports is not defined; ask for it.
            n = syncReadCount(handle, &overlapped) orelse return .err;
        }

        if (n > 0) onData(ctx, buf[0..n]);
    }
}

/// The byte count of an overlapped read that `ReadFile` completed
/// synchronously. Null if the system does not know it.
fn syncReadCount(handle: windows.HANDLE, overlapped: *windows.OVERLAPPED) ?windows.DWORD {
    var n: windows.DWORD = 0;
    if (windows.exp.kernel32.GetOverlappedResult(handle, overlapped, &n, windows.FALSE) == windows.FALSE) {
        log.err("io reader result error err={}", .{windows.GetLastError()});
        return null;
    }
    return n;
}

/// The events used to coordinate the Windows read thread with the rest
/// of the backend (void elsewhere, where a pipe is used instead).
const WindowsEvents = if (is_windows) struct {
    /// Set by threadExit to stop the read loop.
    quit: windows.HANDLE,

    /// Set by the read thread when the pty stream ended and everything
    /// that was read has been handed to the terminal.
    drained: windows.HANDLE,

    fn init() !WindowsEvents {
        const quit = windows.exp.kernel32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = windows.exp.kernel32.CloseHandle(quit);
        const drained = windows.exp.kernel32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        return .{ .quit = quit, .drained = drained };
    }

    fn deinit(self: WindowsEvents) void {
        _ = windows.exp.kernel32.CloseHandle(self.quit);
        _ = windows.exp.kernel32.CloseHandle(self.drained);
    }
} else void;

/// Closes a pipe/file descriptor, which is a HANDLE on Windows.
fn closeFd(fd: posix.fd_t) void {
    if (comptime builtin.target.os.tag == .windows) {
        _ = windows.exp.kernel32.CloseHandle(fd);
    } else {
        _ = posix.system.close(fd);
    }
}

/// Builds the argv array for the process we should exec for the
/// configured command. This isn't as straightforward as it seems since
/// we deal with shell-wrapping, macOS login shells, etc.
///
/// The passwdpkg comptime argument is expected to have a single function
/// `get(Allocator)` that returns a passwd entry. This is used by macOS
/// to determine the username and home directory for the login shell.
/// It is unused on other platforms.
///
/// Memory ownership:
///
/// The allocator should be an arena, since the returned value may or
/// may not be allocated and args may or may not be allocated (or copied).
/// Pointers in the return value may point to pointers in the command
/// struct.
fn execCommand(
    alloc: Allocator,
    command: configpkg.Command,
    comptime passwdpkg: type,
) (Allocator.Error || error{SystemError})![]const [:0]const u8 {
    // If we're on macOS, we have to use `login(1)` to get all of
    // the proper environment variables set, a login shell, and proper
    // hushlogin behavior.
    if (comptime builtin.target.os.tag.isDarwin()) darwin: {
        const passwd = passwdpkg.get(alloc) catch |err| {
            log.warn("failed to read passwd, not using a login shell err={}", .{err});
            break :darwin;
        };

        const username = passwd.name orelse {
            log.warn("failed to get username, not using a login shell", .{});
            break :darwin;
        };

        const hush = if (passwd.home) |home| hush: {
            var dir = std.Io.Dir.openDirAbsolute(global.io(), home, .{}) catch |err| {
                log.warn(
                    "failed to open home dir, not checking for hushlogin err={}",
                    .{err},
                );
                break :hush false;
            };
            defer dir.close(global.io());

            break :hush if (dir.access(global.io(), ".hushlogin", .{})) true else |_| false;
        } else false;

        // If we made it this far we're going to start building
        // the actual command.
        var args: std.ArrayList([:0]const u8) = try .initCapacity(
            alloc,

            // This capacity is chosen based on what we'd need to
            // execute a shell command (very common). We can/will
            // grow if necessary for a longer command (uncommon).
            9,
        );
        defer args.deinit(alloc);

        // The reason for executing login this way is unclear. This
        // comment will attempt to explain but prepare for a truly
        // unhinged reality.
        //
        // The first major issue is that on macOS, a lot of users
        // put shell configurations in ~/.bash_profile instead of
        // ~/.bashrc (or equivalent for another shell). This file is only
        // loaded for a login shell so macOS users expect all their terminals
        // to be login shells. No other platform behaves this way and its
        // totally braindead but somehow the entire dev community on
        // macOS has cargo culted their way to this reality so we have to
        // do it...
        //
        // To get a login shell, you COULD just prepend argv0 with a `-`
        // but that doesn't fully work because `getlogin()` C API will
        // return the wrong value, SHELL won't be set, and various
        // other login behaviors that macOS users expect.
        //
        // The proper way is to use `login(1)`. But login(1) forces
        // the working directory to change to the home directory,
        // which we may not want. If we specify "-l" then we can avoid
        // this behavior but now the shell isn't a login shell.
        //
        // There is another issue: `login(1)` on macOS 14.3 and earlier
        // checked for ".hushlogin" in the working directory. This means
        // that if we specify "-l" then we won't get hushlogin honored
        // if its in the home directory (which is standard). To get
        // around this, we check for hushlogin ourselves and if present
        // specify the "-q" flag to login(1).
        //
        // So to get all the behaviors we want, we specify "-l" but
        // execute "bash" (which is built-in to macOS). We then use
        // the bash builtin "exec" to replace the process with a login
        // shell ("-l" on exec) with the command we really want.
        //
        // We use "bash" instead of other shells that ship with macOS
        // because as of macOS Sonoma, we found with a microbenchmark
        // that bash can `exec` into the desired command ~2x faster
        // than zsh.
        //
        // To figure out a lot of this logic I read the login.c
        // source code in the OSS distribution Apple provides for
        // macOS.
        //
        // Awesome.
        try args.append(alloc, "/usr/bin/login");
        if (hush) try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
        try args.append(alloc, username);

        switch (command) {
            // Direct args can be passed directly to login, since
            // login uses execvp we don't need to worry about PATH
            // searching.
            .direct => |v| try args.appendSlice(alloc, v),

            .shell => |v| {
                // Use "exec" to replace the bash process with
                // our intended command so we don't have a parent
                // process hanging around.
                const cmd = try alloc.printSentinel(
                    "exec -l {s}",
                    .{v},
                    0,
                );

                // We execute bash with "--noprofile --norc" so that it doesn't
                // load startup files so that (1) our shell integration doesn't
                // break and (2) user configuration doesn't mess this process
                // up.
                try args.append(alloc, "/bin/bash");
                try args.append(alloc, "--noprofile");
                try args.append(alloc, "--norc");
                try args.append(alloc, "-c");
                try args.append(alloc, cmd);
            },
        }

        return try args.toOwnedSlice(alloc);
    }

    return switch (command) {
        // We need to clone the command since there's no guarantee the config remains valid.
        .direct => (try command.clone(alloc)).direct,

        .shell => |v| shell: {
            var args: std.ArrayList([:0]const u8) = try .initCapacity(alloc, 4);
            defer args.deinit(alloc);

            if (comptime builtin.target.os.tag == .windows) {
                // On Windows we run the shell value directly rather than
                // wrapping in `cmd.exe /C <shell>`. An intermediate cmd
                // process is wasteful for the common case (`wsl ~`,
                // `pwsh -NoLogo`, etc.) and has visible side effects
                // (extra process in the tree, per-process cmd AutoRun
                // state not reaching the user's actual shell).
                //
                // Values with arguments (or quotes) are split with the
                // MS C runtime command line rules, see tokenizeWindows.
                //
                // Note we don't free any of the memory below since it is
                // allocated in the arena.
                if (std.mem.indexOfAny(u8, v, " \t\"") == null) {
                    // No arguments. If the shell is literally "cmd.exe"
                    // (the default), resolve via %COMSPEC% which is the
                    // documented path to the current command processor.
                    // Other values are passed as-is and resolved by
                    // `internal_os.path.expand` in Command.startWindows.
                    const argv0 = if (std.ascii.eqlIgnoreCase(v, "cmd.exe"))
                        global.environ().getAlloc(alloc, "COMSPEC") catch
                            try alloc.dupe(u8, v)
                    else
                        try alloc.dupe(u8, v);
                    try args.append(alloc, try alloc.dupeSentinel(u8, argv0, 0));
                } else {
                    try args.appendSlice(alloc, try tokenizeWindows(alloc, v));
                }
                break :shell try args.toOwnedSlice(alloc);
            } else {
                // We run our shell wrapped in `/bin/sh` so that we don't have
                // to parse the command line ourselves if it has arguments.
                // Additionally, some environments (NixOS, I found) use /bin/sh
                // to setup some environment variables that are important to
                // have set.
                try args.append(alloc, "/bin/sh");
                if (internal_os.isFlatpak()) try args.append(alloc, "-l");
                try args.append(alloc, "-c");
            }

            try args.append(alloc, v);
            break :shell try args.toOwnedSlice(alloc);
        },
    };
}

pub const tokenizeWindows = internal_os.windows_cmdline.tokenizeWindows;

/// Append a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
fn appendEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    // Otherwise we must prefix.
    return try appendEnvAlways(alloc, current, value);
}

/// Always append value to environment, even when it is empty.
/// This is useful because some env vars (like MANPATH) want there
/// to be an empty prefix to preserve existing values.
///
/// The returned value is always allocated so it must be freed.
fn appendEnvAlways(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    return try alloc.print("{s}{c}{s}", .{
        current,
        std.fs.path.delimiter,
        value,
    });
}

/// Get information about the process(es) running within the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Exec, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.subprocess.getProcessInfo(info);
}

test "execCommand darwin: shell command" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .shell = "foo bar baz" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });

    try testing.expectEqual(8, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "/bin/bash");
    try testing.expectEqualStrings(result[4], "--noprofile");
    try testing.expectEqualStrings(result[5], "--norc");
    try testing.expectEqualStrings(result[6], "-c");
    try testing.expectEqualStrings(result[7], "exec -l foo bar baz");
}

test "execCommand darwin: direct command" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .direct = &.{
        "foo",
        "bar baz",
    } }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });

    try testing.expectEqual(5, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "foo");
    try testing.expectEqualStrings(result[4], "bar baz");
}

test "execCommand: shell command, empty passwd" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                // Empty passwd entry means we can't construct a macOS
                // login command and falls back to POSIX behavior.
                return .{};
            }
        },
    );

    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}

test "execCommand: shell command, error passwd" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                // Failed passwd entry means we can't construct a macOS
                // login command and falls back to POSIX behavior.
                return error.Fail;
            }
        },
    );

    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}

test "execCommand: direct command, error passwd" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }, struct {
        fn get(_: Allocator) !PasswdEntry {
            // Failed passwd entry means we can't construct a macOS
            // login command and falls back to POSIX behavior.
            return error.Fail;
        }
    });

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}

test "execCommand: direct command, config freed" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var command_arena = ArenaAllocator.init(testing.allocator);
    const command_alloc = command_arena.allocator();
    const command = try (configpkg.Command{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }).clone(command_alloc);

    const result = try execCommand(alloc, command, struct {
        fn get(_: Allocator) !PasswdEntry {
            // Failed passwd entry means we can't construct a macOS
            // login command and falls back to POSIX behavior.
            return error.Fail;
        }
    });

    command_arena.deinit();

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}

test "execCommand windows: bare cmd.exe resolves via COMSPEC" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .shell = "cmd.exe" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });

    try testing.expectEqual(1, result.len);

    // Expect COMSPEC if available, otherwise the documented fallback.
    const expected = testing.environ.getAlloc(alloc, "COMSPEC") catch
        try alloc.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
    try testing.expectEqualStrings(expected, result[0]);
}

test "execCommand windows: bare non-cmd shell is passed through" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .shell = "pwsh.exe" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });

    try testing.expectEqual(1, result.len);
    try testing.expectEqualStrings("pwsh.exe", result[0]);
}

test "execCommand windows: shell with args is split on whitespace" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .shell = "wsl ~" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("wsl", result[0]);
    try testing.expectEqualStrings("~", result[1]);
}

test "execCommand windows: direct command is passed through unchanged" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .direct = &.{
        "C:\\tools\\foo.exe",
        "arg with spaces",
    } }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("C:\\tools\\foo.exe", result[0]);
    try testing.expectEqualStrings("arg with spaces", result[1]);
}

fn expectTokens(input: []const u8, expected: []const []const u8) !void {
    const testing = std.testing;
    const tokens = try tokenizeWindows(testing.allocator, input);
    defer {
        for (tokens) |t| testing.allocator.free(t);
        testing.allocator.free(tokens);
    }
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, got| try testing.expectEqualStrings(want, got);
}

test "windows tokenize: quoted path with spaces" {
    try expectTokens(
        "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i",
        &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" },
    );
}

test "windows tokenize: escaped quote and non-ASCII" {
    try expectTokens("say \"\\\"hi\\\"\" Ж", &.{ "say", "\"hi\"", "Ж" });
    try expectTokens(
        "\"C:\\Users\\Анна Ли\\bin\\sh.exe\" -c \"echo Привет\"",
        &.{ "C:\\Users\\Анна Ли\\bin\\sh.exe", "-c", "echo Привет" },
    );
}

test "windows tokenize: backslash and quote rules" {
    // Backslashes not before a quote are literal.
    try expectTokens("a C:\\dir\\file", &.{ "a", "C:\\dir\\file" });
    // 2n backslashes then a quote: n backslashes, the quote toggles.
    try expectTokens("a \"x\\\\\" b", &.{ "a", "x\\", "b" });
    // 2n+1 backslashes then a quote: n backslashes and a literal quote.
    try expectTokens("a \\\\\\\"b", &.{ "a", "\\\"b" });
    // A doubled quote inside quotes is a literal quote.
    try expectTokens("a \"x\"\"y\" z", &.{ "a", "x\"y", "z" });
    // The program name has no escapes, so it may end in a backslash.
    try expectTokens("\"C:\\dir with space\\\" arg", &.{ "C:\\dir with space\\", "arg" });
}

test "windows tokenize: whitespace and empty arguments" {
    try expectTokens("", &.{});
    try expectTokens(" \t ", &.{});
    try expectTokens("  wsl \t ~  ", &.{ "wsl", "~" });
    try expectTokens("prog \"\" x", &.{ "prog", "", "x" });
    // Quotes join with adjacent text into one argument.
    try expectTokens("prog a\"b c\"d", &.{ "prog", "ab cd" });
}

test "windows tokenize: round trip with the Command quoting" {
    const testing = std.testing;
    const argv: []const []const u8 = &.{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "--login",
        "a \"quoted\" arg",
        "trailing backslash\\",
        "tab\there",
        "Ж ж",
    };
    const line = try Command.windowsCreateCommandLine(testing.allocator, argv);
    defer testing.allocator.free(line);
    try expectTokens(line, argv);

    // Empty arguments, and a program path with a space that ends in a
    // backslash (the program name has no escapes).
    const odd: []const []const u8 = &.{ "C:\\dir with space\\", "", "x", "" };
    const odd_line = try Command.windowsCreateCommandLine(testing.allocator, odd);
    defer testing.allocator.free(odd_line);
    try expectTokens(odd_line, odd);
}

test "windows tokenize: execCommand splits a quoted shell value" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{
        .shell = "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i",
    }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });

    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", result[0]);
    try testing.expectEqualStrings("--login", result[1]);
    try testing.expectEqualStrings("-i", result[2]);
}

test "init frees the env when it fails" {
    const testing = std.testing;

    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();

    const Run = struct {
        fn initWithEnv(alloc: Allocator, cfg: *const configpkg.Config) !void {
            var env: EnvMap = .init(alloc);
            {
                errdefer env.deinit();
                try env.put("HOME", "/home/ghostty");
                try env.put("SHELL", "/bin/sh");
            }

            // The env is not freed here once init has it: the failing
            // allocator reports it as a leak unless init freed it.
            var exec = try init(alloc, .{
                .env = env,
                .resources_dir = null,
                .term = "xterm-ghostty",
                .rt_pre_exec_info = .init(cfg),
                .rt_post_fork_info = .init(cfg),
            });
            exec.deinit();
        }
    };

    // Fail each allocation in turn, while building the env and inside init,
    // as std.testing.checkAllAllocationFailures does. That function cannot
    // be used directly: init deliberately falls back to a basic shell when
    // building the command fails, so some runs succeed despite the failure.
    // Every run must still free all it allocated.
    const count = count: {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        try Run.initWithEnv(failing.allocator(), &config);
        break :count failing.alloc_index;
    };
    for (0..count) |fail_index| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        Run.initWithEnv(failing.allocator(), &config) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

/// Runs `readLoopWindows` on its own thread and collects what it reads, so a
/// test can wait for it with a bound instead of risking a hang.
const TestReadLoop = struct {
    const k32 = windows.exp.kernel32;

    handle: windows.HANDLE,
    quit: windows.HANDLE,
    done: windows.HANDLE,
    collected: std.ArrayList(u8) = .empty,
    end: ReadLoopEnd = .err,
    thread: ?std.Thread = null,

    fn init(handle: windows.HANDLE) !TestReadLoop {
        const quit = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer _ = k32.CloseHandle(quit);
        const done = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        return .{ .handle = handle, .quit = quit, .done = done };
    }

    /// Unblocks and joins the thread (if it still runs) and frees everything.
    fn deinit(self: *TestReadLoop) void {
        _ = k32.SetEvent(self.quit);
        if (self.thread) |t| t.join();
        self.collected.deinit(std.testing.allocator);
        _ = k32.CloseHandle(self.quit);
        _ = k32.CloseHandle(self.done);
    }

    fn start(self: *TestReadLoop) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TestReadLoop) void {
        self.end = readLoopWindows(self.handle, self.quit, self, onData);
        _ = k32.SetEvent(self.done);
    }

    fn onData(self: *TestReadLoop, buf: []const u8) void {
        self.collected.appendSlice(std.testing.allocator, buf) catch @panic("oom");
    }

    /// Wait up to `ms` for the loop to return.
    fn waitDone(self: *TestReadLoop, ms: u32) bool {
        return k32.WaitForSingleObject(self.done, ms) == windows.WAIT_OBJECT_0;
    }
};

fn testElapsedMs(start: std.Io.Timestamp) i64 {
    return start.untilNow(global.io(), .awake).toMilliseconds();
}

test "windows exec: sync-completed read uses GetOverlappedResult" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;

    const pipe = try Pty.createOutPipe();
    defer _ = windows.exp.kernel32.CloseHandle(pipe.read);
    defer _ = windows.exp.kernel32.CloseHandle(pipe.write);

    const event = windows.exp.kernel32.CreateEventW(null, windows.TRUE, windows.FALSE, null).?;
    defer _ = windows.exp.kernel32.CloseHandle(event);
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = event;

    // Data is waiting, so the read completes before `ReadFile` returns. The
    // count pointer is null: the byte count may only come from the result.
    var written: windows.DWORD = 0;
    try testing.expect(windows.exp.kernel32.WriteFile(pipe.write, "ghostty", 7, &written, null) != windows.FALSE);
    var buf: [64]u8 = undefined;
    try testing.expect(windows.exp.kernel32.ReadFile(pipe.read, &buf, buf.len, null, &overlapped) != windows.FALSE);
    try testing.expectEqual(@as(?windows.DWORD, 7), syncReadCount(pipe.read, &overlapped));
    try testing.expectEqualStrings("ghostty", buf[0..7]);
}

test "windows exec: read loop returns promptly when quit is signalled while blocked" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;

    const pipe = try Pty.createOutPipe();
    defer _ = windows.exp.kernel32.CloseHandle(pipe.read);
    defer _ = windows.exp.kernel32.CloseHandle(pipe.write);

    var loop = try TestReadLoop.init(pipe.read);
    defer loop.deinit();
    try loop.start();

    // Nothing is ever written, so the loop is blocked in its wait.
    try std.Io.sleep(global.io(), .fromMilliseconds(50), .awake);
    try testing.expect(!loop.waitDone(0));

    const start: std.Io.Timestamp = .now(global.io(), .awake);
    try testing.expect(windows.exp.kernel32.SetEvent(loop.quit) != windows.FALSE);
    try testing.expect(loop.waitDone(1000));
    try testing.expect(testElapsedMs(start) < 1000);
    try testing.expectEqual(ReadLoopEnd.quit, loop.end);
    try testing.expectEqual(@as(usize, 0), loop.collected.items.len);
}

test "windows exec: read loop notices quit even when data is always ready" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;

    const pipe = try Pty.createOutPipe();
    defer _ = windows.exp.kernel32.CloseHandle(pipe.read);
    defer _ = windows.exp.kernel32.CloseHandle(pipe.write);

    var loop = try TestReadLoop.init(pipe.read);
    defer loop.deinit();

    // Data is waiting and so is the quit signal: quit must win.
    var written: windows.DWORD = 0;
    try testing.expect(windows.exp.kernel32.WriteFile(pipe.write, "ghostty", 7, &written, null) != windows.FALSE);
    try testing.expect(windows.exp.kernel32.SetEvent(loop.quit) != windows.FALSE);

    try loop.start();
    try testing.expect(loop.waitDone(1000));
    try testing.expectEqual(ReadLoopEnd.quit, loop.end);
}

test "windows exec: read loop delivers all bytes before EOF" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;

    const total = 1024 * 1024;
    const chunk_len = 4096;

    const pipe = try Pty.createOutPipe();
    // Until the writer thread owns the write end and the cleanup defer
    // below is armed, setup failures clean up here.
    var armed = false;
    errdefer if (!armed) {
        _ = windows.exp.kernel32.CloseHandle(pipe.read);
        _ = windows.exp.kernel32.CloseHandle(pipe.write);
    };
    var loop = try TestReadLoop.init(pipe.read);
    errdefer if (!armed) loop.deinit();
    try loop.start();

    // Write 1 MiB (more than the pipe buffers, so the writer has to wait
    // for the reader), then close the writing end to produce EOF.
    const Writer = struct {
        fn run(handle: windows.HANDLE) void {
            defer _ = windows.exp.kernel32.CloseHandle(handle);
            var chunk: [chunk_len]u8 = undefined;
            var offset: usize = 0;
            while (offset < total) : (offset += chunk_len) {
                for (&chunk, 0..) |*b, i| b.* = @intCast((offset + i) % 251);
                var written: windows.DWORD = 0;
                if (windows.exp.kernel32.WriteFile(handle, &chunk, chunk_len, &written, null) == windows.FALSE) return;
                if (written != chunk_len) return;
            }
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{pipe.write});
    armed = true;
    defer {
        // Stop the reader first, then close its pipe: that also fails the
        // writer's pending write if the reader stopped early.
        loop.deinit();
        _ = windows.exp.kernel32.CloseHandle(pipe.read);
        writer.join();
    }

    try testing.expect(loop.waitDone(10_000));
    try testing.expectEqual(ReadLoopEnd.eof, loop.end);
    try testing.expectEqual(@as(usize, total), loop.collected.items.len);
    for (loop.collected.items, 0..) |b, i| {
        if (b != i % 251) return error.TestUnexpectedResult;
    }
}

test "windows exec: output before child exit is drained and EOF follows" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 });
    defer pty.deinit();

    var cmd: Command = .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/c", "echo ghostty-drain-token" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(testing.allocator);
    defer _ = k32.CloseHandle(cmd.pid.?);
    pty.closeChildSide();

    var loop = try TestReadLoop.init(pty.out_pipe);
    defer loop.deinit();
    try loop.start();

    // The child prints its token and exits well within this bound.
    try testing.expectEqual(
        @as(windows.DWORD, windows.WAIT_OBJECT_0),
        k32.WaitForSingleObject(cmd.pid.?, 10_000),
    );

    // The read side must see EOF shortly after the console is closed.
    const start: std.Io.Timestamp = .now(global.io(), .awake);
    pty.closeConsoleAsync();
    try testing.expect(loop.waitDone(1000));
    try testing.expect(testElapsedMs(start) < 1000);
    try testing.expectEqual(ReadLoopEnd.eof, loop.end);
    try testing.expect(std.mem.indexOf(u8, loop.collected.items, "ghostty-drain-token") != null);
}

/// A handle (terminate, synchronize) to a child process of `parent` whose
/// image is named `name`, found with a Toolhelp snapshot; null if none yet.
fn openChildNamed(parent: windows.HANDLE, name: []const u8) ?windows.HANDLE {
    const PROCESSENTRY32W = extern struct {
        dwSize: windows.DWORD,
        cntUsage: windows.DWORD,
        th32ProcessID: windows.DWORD,
        th32DefaultHeapID: windows.ULONG_PTR,
        th32ModuleID: windows.DWORD,
        cntThreads: windows.DWORD,
        th32ParentProcessID: windows.DWORD,
        pcPriClassBase: i32,
        dwFlags: windows.DWORD,
        szExeFile: [260]u16,
    };
    const T = struct {
        extern "kernel32" fn GetProcessId(process: windows.HANDLE) callconv(.winapi) windows.DWORD;
        extern "kernel32" fn CreateToolhelp32Snapshot(flags: windows.DWORD, pid: windows.DWORD) callconv(.winapi) windows.HANDLE;
        extern "kernel32" fn Process32FirstW(snapshot: windows.HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn Process32NextW(snapshot: windows.HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;
    };
    const TH32CS_SNAPPROCESS = 0x2;
    const parent_pid = T.GetProcessId(parent);
    const snapshot = T.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return null;
    defer _ = windows.exp.kernel32.CloseHandle(snapshot);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    var ok = T.Process32FirstW(snapshot, &entry);
    while (ok != windows.FALSE) : (ok = T.Process32NextW(snapshot, &entry)) {
        if (entry.th32ParentProcessID != parent_pid) continue;
        const len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len;
        var buf: [260 * 3]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&buf, entry.szExeFile[0..len]) catch continue;
        if (!std.ascii.eqlIgnoreCase(buf[0..n], name)) continue;
        return windows.OpenProcess(
            windows.SYNCHRONIZE | windows.PROCESS_TERMINATE,
            windows.FALSE,
            entry.th32ProcessID,
        );
    }
    return null;
}

test "windows exec: closing the pseudo console ends attached console clients" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 });
    defer pty.deinit();

    var cmd: Command = .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/k", "ping -n 60 127.0.0.1" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(testing.allocator);
    defer cmd.closeProcess();
    pty.closeChildSide();

    var loop = try TestReadLoop.init(pty.out_pipe);
    defer loop.deinit();
    try loop.start();

    // Find the ping among the shell's children and keep a handle to it.
    var ping: ?windows.HANDLE = null;
    defer if (ping) |h| {
        _ = k32.TerminateProcess(h, 0);
        _ = k32.CloseHandle(h);
    };
    const begin: std.Io.Timestamp = .now(global.io(), .awake);
    while (ping == null) {
        ping = openChildNamed(cmd.pid.?, "ping.exe");
        if (ping != null) break;
        try testing.expect(testElapsedMs(begin) < 8000);
        try std.Io.sleep(global.io(), .fromMilliseconds(50), .awake);
    }

    // The shell goes right away, the ping only when the console closes.
    try cmd.killChild();
    _ = try cmd.wait(false);
    cmd.closeProcess();
    try testing.expectEqual(
        @as(windows.DWORD, windows.WAIT_TIMEOUT),
        k32.WaitForSingleObject(ping.?, 200),
    );

    pty.closeConsoleAsync();
    try testing.expectEqual(
        @as(windows.DWORD, windows.WAIT_OBJECT_0),
        k32.WaitForSingleObject(ping.?, 6000),
    );
}

test "windows exec: quit is honoured within a bound while a large stream is processed slowly" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    // A terminal that parses slowly (a Debug build) takes seconds for one
    // 64 KiB read. The read thread must still stop promptly on quit, and
    // not only once it is done with the whole read.
    const SlowSink = struct {
        quit: windows.HANDLE,
        started: std.atomic.Value(bool) = .init(false),

        fn process(self: *@This(), slice: []const u8) void {
            self.started.store(true, .release);
            std.Io.sleep(global.io(), .fromMilliseconds(@intCast(slice.len / 32)), .awake) catch {};
        }

        fn onData(self: *@This(), buf: []const u8) void {
            processSlicedWindows(self.quit, self, buf, process);
        }
    };

    const Reader = struct {
        fn run(
            handle: windows.HANDLE,
            sink: *SlowSink,
            end: *ReadLoopEnd,
            done: windows.HANDLE,
        ) void {
            end.* = readLoopWindows(handle, sink.quit, sink, SlowSink.onData);
            _ = k32.SetEvent(done);
        }
    };

    // The writer floods the pipe until its writes fail.
    const Writer = struct {
        fn run(handle: windows.HANDLE) void {
            defer _ = k32.CloseHandle(handle);
            const chunk: [64 * 1024]u8 = @splat('x');
            while (true) {
                var written: windows.DWORD = 0;
                if (k32.WriteFile(handle, &chunk, chunk.len, &written, null) == windows.FALSE) return;
            }
        }
    };

    const pipe = try Pty.createOutPipe();
    errdefer _ = k32.CloseHandle(pipe.read);
    errdefer _ = k32.CloseHandle(pipe.write);

    const quit = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(quit);
    const done = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(done);

    var sink: SlowSink = .{ .quit = quit };
    var end: ReadLoopEnd = .err;

    const writer = try std.Thread.spawn(.{}, Writer.run, .{pipe.write});
    // Let the pipe fill up so that the first read is a large one.
    try std.Io.sleep(global.io(), .fromMilliseconds(100), .awake);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ pipe.read, &sink, &end, done });
    defer {
        // Unblock the reader if the test failed, then close the pipe: that
        // also fails the writer's pending write.
        _ = k32.SetEvent(quit);
        reader.join();
        _ = k32.CloseHandle(pipe.read);
        writer.join();
    }

    for (0..500) |_| {
        if (sink.started.load(.acquire)) break;
        try std.Io.sleep(global.io(), .fromMilliseconds(10), .awake);
    }
    try testing.expect(sink.started.load(.acquire));

    const start: std.Io.Timestamp = .now(global.io(), .awake);
    try testing.expect(k32.SetEvent(quit) != windows.FALSE);
    try testing.expect(k32.WaitForSingleObject(done, 5000) == windows.WAIT_OBJECT_0);
    try testing.expect(testElapsedMs(start) < 1000);
    try testing.expectEqual(ReadLoopEnd.quit, end);
}

/// The byte at `offset` of the test stream used by the stream integrity
/// tests: a function of the offset alone, so any split of the stream into
/// writes or reads produces the same bytes, and a lost, repeated or
/// reordered byte shows up at the offset it happened.
fn testStreamByte(offset: usize) u8 {
    var x: u64 = @as(u64, offset / 8) +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    x ^= x >> 31;
    return @truncate(x >> @intCast((offset % 8) * 8));
}

/// Checks a received stream against `testStreamByte` as it arrives.
const TestStreamCheck = struct {
    received: usize = 0,
    first_mismatch: ?usize = null,

    fn feed(self: *TestStreamCheck, buf: []const u8) void {
        for (buf, self.received..) |b, offset| {
            if (self.first_mismatch == null and b != testStreamByte(offset)) {
                self.first_mismatch = offset;
            }
        }
        self.received += buf.len;
    }
};

test "windows exec: sliced processing delivers every byte in order" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    const quit = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(quit);

    const Sink = struct {
        check: TestStreamCheck = .{},
        slices: usize = 0,
        bad_slice: bool = false,

        fn process(self: *@This(), slice: []const u8) void {
            if (slice.len == 0 or slice.len > PROCESS_SLICE_LEN) self.bad_slice = true;
            self.slices += 1;
            self.check.feed(slice);
        }
    };

    // The edge sizes around the slice length and the read buffer, then
    // random sizes up to a full read.
    const edges = [_]usize{
        0,                         1,                     PROCESS_SLICE_LEN - 1,
        PROCESS_SLICE_LEN,         PROCESS_SLICE_LEN + 1, 2 * PROCESS_SLICE_LEN,
        2 * PROCESS_SLICE_LEN + 1, 64 * 1024 - 1,         64 * 1024,
    };
    var prng: std.Random.DefaultPrng = .init(0x30b);
    const random = prng.random();

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var sink: Sink = .{};
    var expected_slices: usize = 0;
    var offset: usize = 0;
    for (0..edges.len + 2000) |i| {
        const len = if (i < edges.len) edges[i] else switch (random.uintLessThan(u8, 4)) {
            0 => random.uintLessThan(usize, 16),
            1 => PROCESS_SLICE_LEN - 2 + random.uintLessThan(usize, 5),
            else => random.uintAtMost(usize, 64 * 1024),
        };
        try src.resize(testing.allocator, len);
        for (src.items, offset..) |*b, o| b.* = testStreamByte(o);
        processSlicedWindows(quit, &sink, src.items, Sink.process);
        expected_slices += std.math.divCeil(usize, len, PROCESS_SLICE_LEN) catch unreachable;
        offset += len;
    }

    try testing.expect(!sink.bad_slice);
    try testing.expectEqual(expected_slices, sink.slices);
    try testing.expectEqual(offset, sink.check.received);
    try testing.expectEqual(@as(?usize, null), sink.check.first_mismatch);
}

test "windows exec: read loop delivers a 50 MB stream of random write sizes intact" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    const total = 50 * 1024 * 1024;

    // The writer splits the stream into writes of random sizes, from zero
    // bytes (which completes a pending read with nothing) to more than the
    // pipe and the read buffer hold, then closes its end to produce EOF.
    const Writer = struct {
        fn run(handle: windows.HANDLE, failed: *bool) void {
            defer _ = k32.CloseHandle(handle);
            const buf = std.heap.page_allocator.alloc(u8, 192 * 1024) catch {
                failed.* = true;
                return;
            };
            defer std.heap.page_allocator.free(buf);

            var prng: std.Random.DefaultPrng = .init(0x50);
            const random = prng.random();
            var offset: usize = 0;
            while (offset < total) {
                const want: usize = switch (random.uintLessThan(u8, 8)) {
                    0 => 0,
                    1 => 1 + random.uintLessThan(usize, 16),
                    2 => PROCESS_SLICE_LEN - 1 + random.uintLessThan(usize, 3),
                    3 => 64 * 1024 - 1 + random.uintLessThan(usize, 3),
                    else => 1 + random.uintLessThan(usize, buf.len),
                };
                const len = @min(want, total - offset);
                for (buf[0..len], offset..) |*b, o| b.* = testStreamByte(o);
                var written: windows.DWORD = 0;
                if (k32.WriteFile(handle, buf.ptr, @intCast(len), &written, null) == windows.FALSE or
                    written != len)
                {
                    failed.* = true;
                    return;
                }
                offset += len;
            }
        }
    };

    // The reader hands every read through the same slicing as the read
    // thread does.
    const Sink = struct {
        quit: windows.HANDLE,
        check: TestStreamCheck = .{},

        fn process(self: *@This(), slice: []const u8) void {
            self.check.feed(slice);
        }

        fn onData(self: *@This(), buf: []const u8) void {
            processSlicedWindows(self.quit, self, buf, process);
        }
    };

    const Reader = struct {
        fn run(handle: windows.HANDLE, sink: *Sink, end: *ReadLoopEnd, done: windows.HANDLE) void {
            end.* = readLoopWindows(handle, sink.quit, sink, Sink.onData);
            _ = k32.SetEvent(done);
        }
    };

    const pipe = try Pty.createOutPipe();
    // Until the threads own the pipe and the cleanup defer below is
    // armed, setup failures clean up here.
    var armed = false;
    errdefer if (!armed) {
        _ = k32.CloseHandle(pipe.read);
        _ = k32.CloseHandle(pipe.write);
    };

    const quit = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(quit);
    const done = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(done);

    var sink: Sink = .{ .quit = quit };
    var end: ReadLoopEnd = .err;
    var write_failed = false;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ pipe.read, &sink, &end, done });
    errdefer if (!armed) {
        _ = k32.SetEvent(quit);
        reader.join();
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{ pipe.write, &write_failed });
    armed = true;

    // Generous: a Debug build checks every byte on both sides.
    const finished = k32.WaitForSingleObject(done, 120_000) == windows.WAIT_OBJECT_0;

    // Stop the reader first, then close its pipe: that also fails the
    // writer's pending write if the reader stopped early.
    _ = k32.SetEvent(quit);
    reader.join();
    _ = k32.CloseHandle(pipe.read);
    writer.join();

    try testing.expect(finished);
    try testing.expect(!write_failed);
    try testing.expectEqual(ReadLoopEnd.eof, end);
    try testing.expectEqual(@as(?usize, null), sink.check.first_mismatch);
    try testing.expectEqual(@as(usize, total), sink.check.received);
}

/// Line `i` of a checked text stream (no newline): an 8-digit index, a
/// printable ASCII payload of 16 to 60 characters and the CRC-32 of the two,
/// at most 78 characters in all. The same lines as `New-CheckedStream` in
/// test/windows/e2e/_stream.ps1.
fn testCheckedLine(buf: *[80]u8, i: u64) []const u8 {
    var x: u64 = i *% 0x9E3779B97F4A7C15 +% 0x30B;
    const len: usize = @intCast(16 + x % 45);
    var w: std.Io.Writer = .fixed(buf);
    w.print("{d:0>8} ", .{i}) catch unreachable;
    for (0..len) |k| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        var c: u8 = @intCast(0x21 + x % 94);
        if (k > 0 and k < len - 1 and (x >> 40) % 7 == 0) c = ' ';
        w.writeByte(c) catch unreachable;
    }
    const crc = std.hash.Crc32.hash(w.buffered());
    w.print(" {x:0>8}", .{crc}) catch unreachable;
    return w.buffered();
}

test "windows exec: checked lines typed through the pseudo console reach the terminal intact" {
    if (comptime !is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const k32 = windows.exp.kernel32;

    // About 1 MB: the terminal parses slowly in a Debug build.
    const line_count = 18_000;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(testing.io, "stream.txt", .{});
        defer file.close(testing.io);
        var buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(testing.io, &buf);
        var line_buf: [80]u8 = undefined;
        for (0..line_count) |i| {
            try file_writer.interface.writeAll(testCheckedLine(&line_buf, i));
            try file_writer.interface.writeByte('\n');
        }
        try file_writer.interface.flush();
    }
    const path = try tmp.dir.realPathFileAlloc(testing.io, "stream.txt", alloc);
    defer alloc.free(path);
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 100,
        .rows = 30,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);

    // The read thread's path: overlapped reads, sliced, into a VT stream.
    const Sink = struct {
        quit: windows.HANDLE,
        stream: terminal.TerminalStream,

        fn process(self: *@This(), slice: []const u8) void {
            self.stream.nextSlice(slice);
        }

        fn onData(self: *@This(), buf: []const u8) void {
            processSlicedWindows(self.quit, self, buf, process);
        }
    };
    const Reader = struct {
        fn run(handle: windows.HANDLE, sink: *Sink, end: *ReadLoopEnd, done: windows.HANDLE) void {
            end.* = readLoopWindows(handle, sink.quit, sink, Sink.onData);
            _ = k32.SetEvent(done);
        }
    };

    var pty = try Pty.open(.{ .ws_row = 30, .ws_col = 100, .ws_xpixel = 0, .ws_ypixel = 0 });
    defer pty.deinit();

    var cmd: Command = .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/c", "type", path_z },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(alloc);
    defer _ = k32.CloseHandle(cmd.pid.?);
    pty.closeChildSide();

    const quit = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(quit);
    const done = k32.CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
        return error.CreateEventFailed;
    defer _ = k32.CloseHandle(done);

    var sink: Sink = .{ .quit = quit, .stream = t.vtStream() };
    defer sink.stream.deinit();
    var end: ReadLoopEnd = .err;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ pty.out_pipe, &sink, &end, done });
    defer {
        _ = k32.SetEvent(quit);
        reader.join();
    }

    // The child ends once the pseudo console took all of its output; the
    // pipe ends once the console is closed and flushed its last frame.
    try testing.expectEqual(
        @as(windows.DWORD, windows.WAIT_OBJECT_0),
        k32.WaitForSingleObject(cmd.pid.?, 120_000),
    );
    pty.closeConsoleAsync();
    try testing.expect(k32.WaitForSingleObject(done, 120_000) == windows.WAIT_OBJECT_0);
    try testing.expectEqual(ReadLoopEnd.eof, end);

    // What the terminal holds, as write_screen_file dumps it.
    var dump: std.Io.Writer.Allocating = .init(alloc);
    defer dump.deinit();
    {
        const screen = t.screens.active;
        const sel: terminal.Selection = .init(
            screen.pages.getTopLeft(.screen),
            screen.pages.getBottomRight(.screen).?,
            false,
        );
        var formatter: terminal.formatter.ScreenFormatter = .init(screen, .{
            .emit = .plain,
            .unwrap = true,
            .trim = false,
        });
        formatter.content = .{ .selection = sel.ordered(screen, .forward) };
        try formatter.format(&dump.writer);
    }

    // Every line, in order, from the first one on.
    var lines = std.mem.splitScalar(u8, dump.written(), '\n');
    var next: usize = 0;
    var bad: usize = 0;
    var line_buf: [80]u8 = undefined;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (next == 0 and !std.mem.startsWith(u8, line, "00000000 ")) continue;
        if (next == line_count) break;
        const want = testCheckedLine(&line_buf, next);
        if (!std.mem.eql(u8, line, want)) {
            bad += 1;
            if (bad <= 10) std.log.err("stream line {d}: want '{s}' got '{s}'", .{ next, want, line });
        }
        next += 1;
    }
    try testing.expectEqual(@as(usize, line_count), next);
    try testing.expectEqual(@as(usize, 0), bad);
}
