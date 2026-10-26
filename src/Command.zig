//! Command launches sub-processes. This is an alternate implementation to the
//! Zig std.process.Child since at the time of authoring this, std.process.Child
//! didn't support the options necessary to spawn a shell attached to a pty.
//!
//! Consequently, I didn't implement a lot of features that std.process.Child
//! supports because we didn't need them. Cross-platform subprocessing is not
//! a trivial thing to implement (I've done it in three separate languages now)
//! so if we want to replatform onto std.process.Child I'd love to do that.
//! This was just the fastest way to get something built.
//!
//! Issues with std.process.Child:
//!
//!   * No pre_exec callback for logic after fork but before exec.
//!   * posix_spawn is used for Mac, but doesn't support the necessary
//!     features for tty setup.
//!
//!
//! TODO: This may have changed a lot now with the new I/O implementations in
//! >= 0.16.0, so this might warrant a recheck.
const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("config.zig");
const global = @import("global.zig");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const TempDir = internal_os.TempDir;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const EnvMap = std.process.Environ.Map;
const apprt = @import("apprt.zig");

/// Function prototype for a function executed /in the child process/ after the
/// fork, but before exec'ing the command. If the function returns a u8, the
/// child process will be exited with that error code.
const PreExecFn = fn (*Command) ?u8;

/// Allowable set of errors that can be returned by a post fork function. Any
/// errors will result in the failure to create the surface.
pub const PostForkError = error{PostForkError};

/// Function prototype for a function executed /in the parent process/
/// after the fork.
const PostForkFn = fn (*Command) PostForkError!void;

/// Path to the command to run. This doesn't have to be an absolute path,
/// because use exec functions that search the PATH, if necessary.
///
/// This field is null-terminated to avoid a copy for the sake of
/// adding a null terminator since POSIX systems are so common.
path: [:0]const u8,

/// Command-line arguments. It is the responsibility of the caller to set
/// args[0] to the command. If args is empty then args[0] will automatically
/// be set to equal path.
args: []const [:0]const u8,

/// Environment variables for the child process. If this is null, inherits
/// the environment variables from this process. These are the exact
/// environment variables to set; these are /not/ merged.
env: ?*const EnvMap = null,

/// Working directory to change to in the child process. If not set, the
/// working directory of the calling process is preserved.
cwd: ?[:0]const u8 = null,

/// The file handle to set for stdin/out/err. If this isn't set, we do
/// nothing explicitly so it is up to the behavior of the operating system.
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
os_pre_exec: ?*const PreExecFn,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
rt_pre_exec: ?*const PreExecFn,

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_pre_exec_info: RtPreExecInfo,

/// If set, this will be executed in the /in the parent process/ after the fork.
rt_post_fork: ?*const PostForkFn,

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_post_fork_info: RtPostForkInfo,

/// If set, then the process will be created attached to this pseudo console.
/// `stdin`, `stdout`, and `stderr` will be ignored if set.
pseudo_console: if (builtin.target.os.tag == .windows) ?windows.HPCON else void =
    if (builtin.target.os.tag == .windows) null else {},

/// Job object tracking the child and everything it spawns (Windows). Set
/// by start. It has no limits, so closing it (or crashing) kills nothing:
/// GUI programs started from the shell outlive the terminal, as they do in
/// Windows Terminal. jobProcessIds lists its processes.
job: if (builtin.target.os.tag == .windows) ?windows.HANDLE else void =
    if (builtin.target.os.tag == .windows) null else {},

/// User data that is sent to the callback. Set with setData and getData
/// for a more user-friendly API.
data: ?*anyopaque = null,

/// Process ID is set after start is called.
pid: ?posix.system.pid_t = null,

/// The various methods a process may exit.
pub const Exit = if (builtin.target.os.tag == .windows) union(enum) {
    Exited: u32,
} else union(enum) {
    /// Exited by normal exit call, value is exit status
    Exited: u8,

    /// Exited by a signal, value is the signal
    Signal: u32,

    /// Exited by a stop signal, value is signal
    Stopped: u32,

    /// Unknown exit reason, value is the status from waitpid
    Unknown: u32,

    pub fn init(status: u32) Exit {
        return if (posix.W.IFEXITED(status))
            Exit{ .Exited = posix.W.EXITSTATUS(status) }
        else if (posix.W.IFSIGNALED(status))
            Exit{ .Signal = @backingInt(posix.W.TERMSIG(status)) }
        else if (posix.W.IFSTOPPED(status))
            Exit{ .Stopped = @backingInt(posix.W.STOPSIG(status)) }
        else
            Exit{ .Unknown = status };
    }
};

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPreExecInfo = if (@hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.PreExecInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPostForkInfo = if (@hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.PostForkInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Start the subprocess. This returns immediately once the child is started.
///
/// After this is successful, self.pid is available.
pub fn start(self: *Command, alloc: Allocator) !void {
    // Use an arena allocator for the temporary allocations we need in this func.
    // IMPORTANT: do all allocation prior to the fork(). I believe it is undefined
    // behavior if you malloc between fork and exec. The source of the Zig
    // stdlib seems to verify this as well as Go.
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    switch (builtin.target.os.tag) {
        .windows => try self.startWindows(arena),
        else => try self.startPosix(arena),
    }
}

fn startPosix(self: *Command, arena: Allocator) !void {
    // Null-terminate all our arguments
    const argsZ = try arena.allocSentinel(?[*:0]const u8, self.args.len, null);
    for (self.args, 0..) |arg, i| argsZ[i] = arg.ptr;

    // Determine our env vars
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");

    // Fork.
    const pid = try fork();

    if (pid != 0) {
        // Parent, return immediately.
        self.pid = @intCast(pid);
        if (self.rt_post_fork) |f| try f(self);
        return;
    }

    // We are the child.

    // Setup our file descriptors for std streams.
    if (self.stdin) |f| setupFd(f.handle, posix.STDIN_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stdout) |f| setupFd(f.handle, posix.STDOUT_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stderr) |f| setupFd(f.handle, posix.STDERR_FILENO) catch
        return error.ExecFailedInChild;

    // Setup our working directory.
    //
    // NOTE: this can fail if we don't have permission to go to this directory
    // or if due to race conditions it doesn't exist or any various other
    // reasons. We don't want to crash the entire process if this fails so we
    // ignore it. We don't log because that'll show up in the output.
    if (self.cwd) |cwd| _ = posix.system.chdir(cwd);

    // Restore any rlimits that were set by Ghostty. This might fail but
    // any failures are ignored (its best effort).
    global.rlimits().restore();

    // If there are pre exec callbacks, call them now.
    if (self.os_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);
    if (self.rt_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);

    const err: posix.E = execve: {
        // This functionality has been taken from Zig stdlib, a simplified
        // version of the exec bits with PATH search so that we can just
        // offload to execve below.
        const file_slice = std.mem.sliceTo(self.path, 0);
        if (std.mem.findScalar(u8, file_slice, '/') != null) {
            break :execve posix.errno(posix.system.execve(self.path, argsZ, envp));
        }

        var path_expanded_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const PATH = global.environ().getPosix("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
        var it = std.mem.tokenizeScalar(u8, PATH, ':');
        var err: posix.system.E = .NOENT;
        var seen_eacces = false;

        while (it.next()) |search_path| {
            const path_len = search_path.len + file_slice.len + 1;
            if (path_expanded_buf.len < path_len + 1) break :execve .NAMETOOLONG;
            @memcpy(path_expanded_buf[0..search_path.len], search_path);
            path_expanded_buf[search_path.len] = '/';
            @memcpy(path_expanded_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
            path_expanded_buf[path_len] = 0;
            const full_path = path_expanded_buf[0..path_len :0].ptr;
            // Replace here, switch on error (any error means that replace
            // failed, but we might need to retry).
            err = posix.errno(posix.system.execve(full_path, argsZ, envp));
            switch (err) {
                .ACCES => seen_eacces = true,
                .NOENT, .NOTDIR => {},
                else => break :execve err,
            }
        }

        if (seen_eacces) break :execve .ACCES;
        break :execve err;
    };

    // If we are executing this code, the exec failed. We're in the
    // child process so there isn't much we can do. We try to output
    // something reasonable. Its important to note we MUST NOT return
    // any other error condition from here on out.
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buf);
    const stderr = &stderr_writer.interface;
    switch (err) {
        posix.system.E.NOENT => stderr.print(
            \\Requested executable not found. Please verify the command is on
            \\the PATH and try again.
            \\
        ,
            .{},
        ) catch {},

        else => |e| stderr.print(
            \\exec syscall failed with unexpected error: E{s}
            \\
        ,
            .{@tagName(e)},
        ) catch {},
    }
    stderr.flush() catch {};

    // We return a very specific error that can be detected to determine
    // we're in the child.
    return error.ExecFailedInChild;
}

/// Wrapper for the raw fork syscall. This preserves the error handling from
/// the std.posix wrapper that was removed in Zig 0.16.
fn fork() !posix.pid_t {
    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn startWindows(self: *Command, arena: Allocator) !void {
    const cwd_w = if (self.cwd) |cwd| try std.unicode.utf8ToUtf16LeAllocZ(arena, cwd) else null;

    // Pass null for lpApplicationName and put the program as the first
    // token of lpCommandLine. This lets CreateProcessW perform the
    // standard program search (parent-app dir, CWD, system dirs, PATH)
    // and append ".exe" when the name has no extension, which is what
    // users expect for bare commands like `wsl ~` or `pwsh.exe`.
    // It also preserves the child's argv[0] as written by the caller
    // rather than replacing it with the resolved absolute path.
    const command_line = if (self.args.len > 0)
        try windowsCreateCommandLine(arena, self.args)
    else
        try windowsCreateCommandLine(arena, &.{self.path});
    const command_line_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, command_line);
    const env_w = if (self.env) |env_map| try createWindowsEnvBlock(arena, env_map) else null;

    const any_null_fd = self.stdin == null or self.stdout == null or self.stderr == null;
    const null_fd = if (any_null_fd) null_fd: {
        // path = "\Device\Null"
        const path = [_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' };
        var path_unicode_string: windows.UNICODE_STRING = .init(&path);
        var attrs: windows.OBJECT_ATTRIBUTES = .{ .ObjectName = &path_unicode_string };

        var fd: windows.HANDLE = undefined;
        var io_status: windows.IO_STATUS_BLOCK = undefined; // unused
        const result = windows.exp.ntdll.NtCreateFile(
            &fd,
            .{ .GENERIC = .{ .READ = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
            &attrs,
            &io_status,
            null,
            windows.FILE_ATTRIBUTE_NORMAL,
            windows.FILE_SHARE_READ,
            windows.OPEN_EXISTING,
            windows.FILE_NON_DIRECTORY_FILE,
            null,
            0,
        );

        if (result != .SUCCESS) {
            return windows.unexpectedStatus(result);
        }

        break :null_fd fd;
    } else null;
    defer {
        if (null_fd) |fd| _ = windows.exp.kernel32.CloseHandle(fd);
    }

    // The child, and so every process it spawns, lives in a job object so
    // the whole tree can be found later. The job is assigned through
    // PROC_THREAD_ATTRIBUTE_JOB_LIST so the child is never outside of it,
    // not even for an instant.
    const job = windows.CreateJobObjectW(null, null) orelse
        return windows.unexpectedError(windows.GetLastError());
    errdefer _ = windows.exp.kernel32.CloseHandle(job);
    // Must stay alive until CreateProcessW returns, hence the arena.
    const job_list = try arena.create([1]windows.HANDLE);
    job_list.* = .{job};

    // TODO: In the case of having FDs instead of pty, need to set up
    // attributes such that the child process only inherits these handles,
    // then set bInheritsHandles below.

    const attr_count: windows.DWORD = if (self.pseudo_console != null) 2 else 1;
    var attribute_list_size: usize = undefined;
    _ = windows.exp.kernel32.InitializeProcThreadAttributeList(
        null,
        attr_count,
        0,
        &attribute_list_size,
    );

    const attribute_list = (try arena.alloc(u8, attribute_list_size)).ptr;
    if (windows.exp.kernel32.InitializeProcThreadAttributeList(
        attribute_list,
        attr_count,
        0,
        &attribute_list_size,
    ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());

    if (windows.exp.kernel32.UpdateProcThreadAttribute(
        attribute_list,
        0,
        windows.PROC_THREAD_ATTRIBUTE_JOB_LIST,
        job_list,
        @sizeOf([1]windows.HANDLE),
        null,
        null,
    ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());

    const stdin, const stdout, const stderr = if (self.pseudo_console) |pseudo_console| b: {
        if (windows.exp.kernel32.UpdateProcThreadAttribute(
            attribute_list,
            0,
            windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            pseudo_console,
            @sizeOf(windows.HPCON),
            null,
            null,
        ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());

        break :b .{ null, null, null };
    } else b: {
        const stdin = if (self.stdin) |f| f.handle else null_fd.?;
        const stdout = if (self.stdout) |f| f.handle else null_fd.?;
        const stderr = if (self.stderr) |f| f.handle else null_fd.?;
        break :b .{ stdin, stdout, stderr };
    };

    var startup_info_ex = windows.STARTUPINFOEX{
        .StartupInfo = .{
            .cb = @sizeOf(windows.STARTUPINFOEX),
            .hStdError = stderr,
            .hStdOutput = stdout,
            .hStdInput = stdin,
            // On the pseudo console path the handles stay null. Without
            // the flag the child picks up our own std handles instead of
            // the console's.
            .dwFlags = windows.STARTF_USESTDHANDLES,
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = attribute_list,
    };

    const flags: windows.DWORD = windows.CREATE_UNICODE_ENVIRONMENT |
        windows.EXTENDED_STARTUPINFO_PRESENT;

    var process_information: windows.PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(
        null,
        command_line_w.ptr,
        null,
        null,
        // The pseudo console path hands the child its console through the
        // attribute list, so it must not inherit any of our handles.
        if (self.pseudo_console != null) windows.FALSE else windows.TRUE,
        flags,
        if (env_w) |w| w.ptr else null,
        if (cwd_w) |w| w.ptr else null,
        @ptrCast(&startup_info_ex.StartupInfo),
        &process_information,
    ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());

    _ = windows.exp.kernel32.CloseHandle(process_information.hThread);
    self.job = job;
    self.pid = process_information.hProcess;
}

/// The process ids currently in the job (Windows), as many as `out` holds.
pub fn jobProcessIds(self: Command, out: []windows.DWORD) []windows.DWORD {
    const job = self.job orelse return out[0..0];

    // The list header is followed by the rest of the ids.
    var buf: extern struct {
        header: windows.JOBOBJECT_BASIC_PROCESS_ID_LIST,
        more: [127]windows.ULONG_PTR,
    } = undefined;
    @memset(std.mem.asBytes(&buf), 0);
    if (windows.QueryInformationJobObject(
        job,
        windows.JOBOBJECT_BASIC_PROCESS_ID_LIST_CLASS,
        &buf,
        @sizeOf(@TypeOf(buf)),
        null,
    ) == windows.FALSE and windows.GetLastError() != .MORE_DATA) return out[0..0];

    const ids: [*]const windows.ULONG_PTR = @ptrCast(&buf.header.ProcessIdList);
    const n = @min(buf.header.NumberOfProcessIdsInList, out.len);
    for (out[0..n], ids[0..n]) |*dst, id| dst.* = @intCast(id);
    return out[0..n];
}

/// Terminate the child (Windows). Only the direct child goes: the console
/// programs attached to its pseudo console end when the pseudo console is
/// closed, and programs with a console of their own, detached ones and GUI
/// programs keep running, as they do in Windows Terminal. Does not wait;
/// use wait afterwards to reap the child.
pub fn killChild(self: *Command) !void {
    const pid = self.pid orelse return;
    const k32 = windows.exp.kernel32;

    if (k32.TerminateProcess(pid, 0) == windows.FALSE and
        k32.WaitForSingleObject(pid, 0) != windows.WAIT_OBJECT_0)
        return windows.unexpectedError(windows.GetLastError());
}

/// Close the job (Windows). This does not stop anything running in it.
/// Safe to call repeatedly.
pub fn closeJob(self: *Command) void {
    if (self.job) |job| _ = windows.exp.kernel32.CloseHandle(job);
    self.job = null;
}

/// Close the process handle (Windows). Call once the child has been
/// waited for or has otherwise exited; `pid` is null afterwards. Safe to
/// call repeatedly.
pub fn closeProcess(self: *Command) void {
    if (comptime builtin.target.os.tag != .windows) return;
    if (self.pid) |h| _ = windows.exp.kernel32.CloseHandle(h);
    self.pid = null;
}

fn setupFd(src: File.Handle, target: i32) !void {
    const PosixCall = struct {
        fn f(func: anytype, args: anytype) !usize {
            while (true) {
                const rc = @call(.auto, func, args);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN, .ACCES => return error.Locked,
                    .BADF => unreachable,
                    .BUSY => return error.FileBusy,
                    .INVAL => unreachable, // invalid parameters
                    .PERM => return error.PermissionDenied,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NOTDIR => unreachable, // invalid parameter
                    .DEADLK => return error.DeadLock,
                    .NOLCK => return error.LockedRegionLimitExceeded,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        }
    };

    switch (builtin.target.os.tag) {
        .linux => {
            // We use dup3 so that we can clear CLO_ON_EXEC. We do NOT want this
            // file descriptor to be closed on exec since we're exactly exec-ing after
            // this.
            _ = try PosixCall.f(linux.dup3, .{ src, target, 0 });
        },
        .freebsd, .ios, .macos => {
            // Mac doesn't support dup3 so we use dup2. We purposely clear
            // CLO_ON_EXEC for this fd.
            const flags = try PosixCall.f(posix.system.fcntl, .{ src, posix.F.GETFD });
            if (flags & posix.FD_CLOEXEC != 0) {
                _ = try PosixCall.f(
                    posix.system.fcntl,
                    .{ src, posix.F.SETFD, flags & ~@as(u32, posix.FD_CLOEXEC) },
                );
            }

            _ = try PosixCall.f(posix.system.dup2, .{ src, target });
        },
        else => @compileError("unsupported platform"),
    }
}

/// Wait for the command to exit and return information about how it exited.
pub fn wait(self: Command, block: bool) !Exit {
    if (comptime builtin.target.os.tag == .windows) {
        // Block until the process exits. This returns immediately if the
        // process already exited.
        //
        // NOTE: We can use the pid directly as posix.system.pid_t is still an
        // alias for a handle under Windows. We might want to keep an eye on if
        // this changes, though.
        const result = windows.exp.kernel32.WaitForSingleObject(self.pid.?, windows.INFINITE);
        if (result == windows.WAIT_FAILED) {
            return windows.unexpectedError(windows.GetLastError());
        }

        var exit_code: windows.DWORD = undefined;
        const has_code = windows.exp.kernel32.GetExitCodeProcess(self.pid.?, &exit_code) != windows.FALSE;
        if (!has_code) {
            return windows.unexpectedError(windows.GetLastError());
        }

        return .{ .Exited = exit_code };
    }

    const status: u32 = if (block) wait_block: {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        _ = try waitPid(self.pid.?, &status, 0);
        break :wait_block @bitCast(status);
    } else wait_nohang: {
        // We specify NOHANG because its not our fault if the process we launch
        // for the tty doesn't properly waitpid its children. We don't want
        // to hang the terminal over it.
        // When NOHANG is specified, waitpid will return a pid of 0 if the process
        // doesn't have a status to report. When that happens, it is as though the
        // wait call has not been performed, so we need to keep trying until we get
        // a non-zero pid back, otherwise we end up with zombie processes.
        while (true) {
            var status: if (builtin.link_libc) c_int else u32 = undefined;
            const pid = try waitPid(self.pid.?, &status, posix.system.W.NOHANG);
            if (pid != 0) break :wait_nohang @bitCast(status);
        }
    };

    return .init(status);
}

/// Wrapper for the raw waitpid syscall. Status is only initialized on success;
/// interrupted waits are retried and all other errors are propagated.
fn waitPid(
    pid: posix.pid_t,
    status: *if (builtin.link_libc) c_int else u32,
    flags: u32,
) !posix.pid_t {
    while (true) {
        const rc = posix.system.waitpid(pid, status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .CHILD => return error.NoChildProcess,
            .INVAL => return error.InvalidWaitOptions,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Sets command->data to data.
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}

/// Returns command->data.
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const EnvMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
        @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
        env_buf[pair.key_ptr.len] = '=';
        @memcpy(env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
        envp_buf[i] = env_buf.ptr;
    }
    std.debug.assert(i == envp_count);

    return envp_buf;
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createWindowsEnvBlock(allocator: mem.Allocator, env_map: *const EnvMap) ![]u16 {
    // count bytes needed
    const max_chars_needed = x: {
        var max_chars_needed: usize = 4; // 4 for the final 4 null bytes
        var it = env_map.iterator();
        while (it.next()) |pair| {
            // +1 for '='
            // +1 for null byte
            max_chars_needed += pair.key_ptr.len + pair.value_ptr.len + 2;
        }
        break :x max_chars_needed;
    };
    const result = try allocator.alloc(u16, max_chars_needed);
    errdefer allocator.free(result);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| {
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.key_ptr.*);
        result[i] = '=';
        i += 1;
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.value_ptr.*);
        result[i] = 0;
        i += 1;
    }
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    return try allocator.realloc(result, i);
}

pub const windowsCreateCommandLine = internal_os.windows_cmdline.createCommandLine;

test "createNullDelimitedEnvMap" {
    const allocator = testing.allocator;
    var envmap = EnvMap.init(allocator);
    defer envmap.deinit();

    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try createNullDelimitedEnvMap(arena.allocator(), &envmap);

    try testing.expectEqual(@as(usize, 5), environ.len);

    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); // Environment variable not found
        }
    }
}

test "Command: os pre exec 1" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.system.exit(42);
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: os pre exec 2" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 1" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.system.exit(42);
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 2" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt post fork 1" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "sleep 1" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = (struct {
            fn do(_: *Command) PostForkError!void {
                return error.PostForkError;
            }
        }).do,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try testing.expectError(error.PostForkError, cmd.testingStart());
}

fn createTestStdout(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stdout.txt", .{ .read = true });
    if (builtin.target.os.tag == .windows) {
        if (windows.exp.kernel32.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        ) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
    }

    return file;
}

fn createTestStderr(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stderr.txt", .{ .read = true });
    if (builtin.target.os.tag == .windows) {
        if (windows.exp.kernel32.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        ) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
    }

    return file;
}

test "Command: redirect stdout to file" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var cmd: Command = if (builtin.target.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\whoami.exe",
        .args = &.{"C:\\Windows\\System32\\whoami.exe"},
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo hello" },
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expectEqual(@as(u32, 0), @as(u32, exit.Exited));

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);
    try testing.expect(contents.len > 0);
}

test "Command: custom env vars" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("VALUE", "hello");

    var cmd: Command = if (builtin.target.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "echo %VALUE%" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);

    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("hello\r\n", contents);
    } else {
        try testing.expectEqualStrings("hello\n", contents);
    }
}

test "Command: custom working directory" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var cmd: Command = if (builtin.target.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "cd" },
        .stdout = stdout,
        .cwd = "C:\\Windows\\System32",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "pwd" },
        .stdout = stdout,
        .cwd = "/tmp",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);

    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("C:\\Windows\\System32\r\n", contents);
    } else if (builtin.target.os.tag == .macos) {
        try testing.expectEqualStrings("/private/tmp\n", contents);
    } else {
        try testing.expectEqualStrings("/tmp\n", contents);
    }
}

// Test validate an execveZ failure correctly terminates when error.ExecFailedInChild is correctly handled
//
// Incorrectly handling an error.ExecFailedInChild results in a second copy of the test process running.
// Duplicating the test process leads to weird behavior
// zig build test will hang
// test binary created via -Demit-test-exe will run 2 copies of the test suite
test "Command: posix fork handles execveZ failure" {
    if (builtin.target.os.tag == .windows) {
        return error.SkipZigTest;
    }
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var stderr = try createTestStderr(testing.io, td.dir);
    defer stderr.close(testing.io);

    var cmd: Command = .{
        .path = "/not/a/binary",
        .args = &.{ "/not/a/binary", "" },
        .stdout = stdout,
        .stderr = stderr,
        .cwd = "/bin",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 1);
}

// If cmd.start fails with error.ExecFailedInChild it's the _child_ process that is running. If it does not
// terminate in response to that error both the parent and child will continue as if they _are_ the test suite
// process.
fn testingStart(self: *Command) !void {
    self.start(testing.allocator) catch |err| {
        if (err == error.ExecFailedInChild) {
            // I am a child process, I must not get confused and continue running the rest of the test suite.
            posix.system.exit(1);
        }
        return err;
    };
}

test "windows command: argv[0] with spaces is quoted" {
    const line = try windowsCreateCommandLine(testing.allocator, &.{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "--login",
        "-i",
    });
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i",
        line,
    );
}

test "windows command: empty argument and argv[0] with trailing backslash" {
    const line = try windowsCreateCommandLine(testing.allocator, &.{
        "C:\\dir with space\\",
        "",
        "x y",
    });
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("\"C:\\dir with space\\\" \"\" \"x y\"", line);
}

test "windows command: PE subsystem rejects malformed headers" {
    try testing.expectEqual(@as(?u16, null), windows.peSubsystem(""));
    try testing.expectEqual(@as(?u16, null), windows.peSubsystem("MZ"));
    try testing.expectEqual(@as(?u16, null), windows.peSubsystem(&@as([0x200]u8, @splat(0))));

    // A minimal header: PE signature at 0x80, subsystem 3 (console).
    var image: [0x200]u8 = @splat(0);
    image[0] = 'M';
    image[1] = 'Z';
    image[0x3c] = 0x80;
    @memcpy(image[0x80..][0..4], "PE\x00\x00");
    image[0x80 + 4 + 20 + 68] = 3;
    try testing.expectEqual(@as(?u16, 3), windows.peSubsystem(&image));

    // The subsystem field is past the end of what we have.
    try testing.expectEqual(@as(?u16, null), windows.peSubsystem(image[0 .. 0x80 + 4 + 20 + 68]));
    // The header offset points outside of the buffer.
    image[0x3c] = 0xff;
    image[0x3d] = 0xff;
    try testing.expectEqual(@as(?u16, null), windows.peSubsystem(&image));
}

/// A running `cmd.exe /C <script>` and open handles to the processes of its
/// job, for the tests below. Everything it started is torn down by deinit,
/// on every path, so nothing is left running (or on the desktop).
const JobTree = struct {
    const k32 = windows.exp.kernel32;
    const max = 64;

    cmd: Command,
    ids: [max]windows.DWORD = undefined,
    handles: [max]?windows.HANDLE = @splat(null),
    count: usize = 0,

    fn start(script: [:0]const u8) !JobTree {
        var tree: JobTree = .{ .cmd = .{
            .path = "C:\\Windows\\System32\\cmd.exe",
            .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", script },
            .os_pre_exec = null,
            .rt_pre_exec = null,
            .rt_post_fork = null,
            .rt_pre_exec_info = undefined,
            .rt_post_fork_info = undefined,
        } };
        try tree.cmd.start(testing.allocator);
        return tree;
    }

    fn deinit(self: *JobTree) void {
        // Kill whatever is left, GUI programs included, by hand.
        var ids: [max]windows.DWORD = undefined;
        for (self.cmd.jobProcessIds(&ids)) |id| {
            const proc = windows.OpenProcess(
                windows.SYNCHRONIZE | windows.PROCESS_TERMINATE,
                windows.FALSE,
                id,
            ) orelse continue;
            _ = k32.TerminateProcess(proc, 0);
            _ = k32.WaitForSingleObject(proc, 2000);
            _ = k32.CloseHandle(proc);
        }
        for (self.handles) |h| if (h) |handle| {
            _ = k32.TerminateProcess(handle, 0);
            _ = k32.WaitForSingleObject(handle, 2000);
            _ = k32.CloseHandle(handle);
        };
        if (self.cmd.job != null) self.cmd.killChild() catch {};
        self.cmd.closeJob();
        self.cmd.closeProcess();
    }

    /// Wait (bounded) until the job lists processes satisfying `ready`,
    /// then open a handle to each of them.
    fn gather(self: *JobTree, comptime ready: fn (*JobTree) bool) !void {
        const io = testing.io;
        const begin: std.Io.Timestamp = .now(io, .awake);
        while (true) {
            self.count = self.cmd.jobProcessIds(&self.ids).len;
            if (ready(self)) break;
            try testing.expect(begin.untilNow(io, .awake).toMilliseconds() < 8000);
            try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        }

        var opened: usize = 0;
        for (self.ids[0..self.count], 0..) |id, i| {
            self.handles[i] = windows.OpenProcess(
                windows.SYNCHRONIZE | windows.PROCESS_TERMINATE | windows.PROCESS_QUERY_LIMITED_INFORMATION,
                windows.FALSE,
                id,
            );
            if (self.handles[i] != null) opened += 1;
        }
        // A silently skipped process would turn the checks into no-ops.
        try testing.expect(opened >= 2);
        try testing.expectEqual(self.count, opened);
    }

    fn atLeastTwo(self: *JobTree) bool {
        return self.count >= 2;
    }

    /// Whether the process behind `handle` runs an image named `name`.
    fn isImage(handle: windows.HANDLE, name: []const u8) bool {
        var buf: [4096]u16 = undefined;
        var len: windows.DWORD = buf.len;
        if (windows.QueryFullProcessImageNameW(handle, 0, @ptrCast(&buf), &len) == windows.FALSE) return false;
        var path: [4096]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&path, buf[0..len]) catch return false;
        return std.ascii.endsWithIgnoreCase(path[0..n], name);
    }
};

test "windows command: killChild ends only the direct child" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    const k32 = JobTree.k32;

    // No pseudo console: the started cmd.exe gets a console of its own,
    // which the ping and the direct child (waiting for it) do not share.
    var tree = try JobTree.start("start /min cmd /k & ping -n 30 127.0.0.1 >nul");
    defer tree.deinit();
    try tree.gather(JobTree.atLeastTwo);
    // Wait for the started cmd.exe to show up next to the direct child.
    const begin: std.Io.Timestamp = .now(io, .awake);
    while (true) {
        var n: usize = 0;
        for (tree.handles[0..tree.count]) |h| {
            if (h) |handle| if (JobTree.isImage(handle, "cmd.exe")) {
                n += 1;
            };
        }
        if (n >= 2) break;
        try testing.expect(begin.untilNow(io, .awake).toMilliseconds() < 8000);
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        // Pick up processes that appeared since.
        const prev = tree.count;
        tree.count = tree.cmd.jobProcessIds(&tree.ids).len;
        for (tree.ids[prev..tree.count], prev..) |id, i| {
            tree.handles[i] = windows.OpenProcess(
                windows.SYNCHRONIZE | windows.PROCESS_TERMINATE | windows.PROCESS_QUERY_LIMITED_INFORMATION,
                windows.FALSE,
                id,
            );
        }
    }

    const child = tree.cmd.pid.?;
    try tree.cmd.killChild();
    try testing.expectEqual(
        @as(windows.DWORD, windows.WAIT_OBJECT_0),
        k32.WaitForSingleObject(child, 2000),
    );

    // The started cmd.exe (the direct child is gone) is still running.
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    var alive: usize = 0;
    for (tree.handles[0..tree.count]) |h| {
        const handle = h orelse continue;
        if (!JobTree.isImage(handle, "cmd.exe")) continue;
        if (k32.WaitForSingleObject(handle, 0) == windows.WAIT_TIMEOUT) alive += 1;
    }
    try testing.expectEqual(@as(usize, 1), alive);
}

test "windows command: closeProcess closes the handle once" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    var tree = try JobTree.start("ping -n 60 127.0.0.1 >nul");
    defer tree.deinit();
    const old = tree.cmd.pid.?;

    try tree.cmd.killChild();
    _ = try tree.cmd.wait(false);
    tree.cmd.closeProcess();
    try testing.expect(tree.cmd.pid == null);
    // The handle is gone: waiting on it is now an error.
    try testing.expectEqual(
        windows.WAIT_FAILED,
        JobTree.k32.WaitForSingleObject(old, 0),
    );
    tree.cmd.closeProcess(); // idempotent
}

test "windows command: closing the job kills nothing" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    var tree = try JobTree.start("ping -n 60 127.0.0.1 >nul");
    defer tree.deinit();
    try tree.gather(JobTree.atLeastTwo);

    tree.cmd.closeJob();
    tree.cmd.closeJob(); // idempotent
    try testing.expect(tree.cmd.job == null);
    for (tree.handles) |h| {
        const handle = h orelse continue;
        try testing.expectEqual(
            @as(windows.DWORD, windows.WAIT_TIMEOUT),
            JobTree.k32.WaitForSingleObject(handle, 200),
        );
    }
}
