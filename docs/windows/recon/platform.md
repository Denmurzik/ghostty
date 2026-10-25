# Windows port recon: core platform assumptions (everything except src/apprt, src/renderer)

Scope: repo C:\D\den4ik\Ghostty, branch `windows` (upstream main, Zig `minimum_zig_version = 0.17.0`, std.Io era).
Method: static reading + grep only. `zig` is NOT on PATH in the recon shell, so nothing below was compile-verified;
items marked (UNVERIFIED) are "will probably not compile / not behave" from reading the code.
Severity: BLOCKER = no working Windows terminal without it; MAJOR = works but badly / wrong for the target setup
(Git Bash + pwsh + cmd); MINOR = polish / edge.

## 0. TL;DR (what already exists vs what is missing)

Already present in upstream core (surprisingly much):
- ConPTY `WindowsPty` (src/pty.zig:326-491), CreateProcessW + PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE (src/Command.zig:305-440),
  Windows read thread (Exec.zig:1778), kill via TerminateProcess (Exec.zig:1164), libxev IOCP backend with Process + Stream write.
- `freetype_windows` font backend = default on Windows (src/font/backend.zig:49-55, discovery.zig:965): directory-scanning
  discovery over C:\Windows\Fonts + %LOCALAPPDATA%\Microsoft\Windows\Fonts. Rendering = FreeType + HarfBuzz (already the plan).
- keycodes table has a `win` column (src/input/keycodes.zig:176, native_idx=3) with PS/2 set-1 scancodes (0xE0xx for extended).
- Windows branches in os/{homedir,xdg,hostname,pipe,file(tmp),resourcesdir,open,desktop,stderr,path}.zig, page allocator
  (terminal/page.zig VirtualAlloc), kitty-graphics Windows path checks (terminal/kitty/windows.zig), build.zig (MSVC ABI default,
  `exe.subsystem = .windows`, ghostty.rc), tests tagged for Windows.
Missing / wrong (details below): default-shell resolution (Git Bash -> pwsh -> cmd), config path (currently %LOCALAPPDATA%),
`bash.exe`/`pwsh` shell detection + no pwsh integration, MSYS-path vs Windows-path mismatch (OSC 7, cwd inheritance),
terminfo not compiled on Windows (TERM=xterm-ghostty unresolvable), font discovery ignores bold/italic/monospace and is O(files)
per query, GUI-subsystem exe has no stdout/stderr for `+actions` and logs, two likely compile errors in Exec.zig, read-thread
shutdown race, no crash reporting, `tail` required by build.

---------------------------------------------------------------------------------------------------------------------------

## 1. PTY and termio

### 1.1 Is there a Windows/ConPTY implementation?  YES (upstream).
`src/pty.zig:18-22` selects `WindowsPty` on `.windows`; `NullPty` on ios; `PosixPty` otherwise (needs `pty-c` translate-c module,
only built for freebsd/linux/macos: src/build/SharedDeps.zig:204-216).

WindowsPty.open (pty.zig:343-452):
- in: named pipe `\\.\pipe\LOCAL\ghostty-pty-<pid>-<n>` created `PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED` (server end `in_pipe`),
  client end `in_pipe_pty` opened with CreateFileW GENERIC_READ. Named pipe because libxev IOCP only does overlapped I/O.
- out: anonymous `CreatePipe` (`out_pipe` read end, `out_pipe_pty` write end) - read synchronously by a dedicated thread.
- all four handles made non-inheritable; `CreatePseudoConsole(size, in_pipe_pty, out_pipe_pty, flags=0, &hpc)`.
- `setSize` -> ResizePseudoConsole (pty.zig:473). `getProcessInfo` returns null (no foreground pid / tty name).
- `winsize` pixel fields are dropped (ConPTY only takes cols/rows).

What ConPTY needs / current gaps:
- [MAJOR] `dwFlags = 0` (pty.zig:444-450). Consider: `PSEUDOCONSOLE_INHERIT_CURSOR (0x1)` only if we answer the DSR 6n conhost
  sends (core already answers CSI 6n via stream_handler, so low risk) - needed so a new tab in a non-top row does not start with
  cursor at (0,0) semantics mismatch. `PSEUDOCONSOLE_RESIZE_QUIRK (0x2)`, `PSEUDOCONSOLE_WIN32_INPUT_MODE (0x4)` and the
  undocumented `PSEUDOCONSOLE_PASSTHROUGH_MODE (0x8)` (Win11 22H2+, what Windows Terminal uses; avoids conhost re-rendering and
  gives sane scrollback/reflow behaviour - recommended to try, with fallback to 0 if CreatePseudoConsole returns E_INVALIDARG).
  Core ignores unknown modes (?9001h from conhost win32-input-mode is harmless: conhost falls back to VT input).
- [MINOR] `Pty.deinit` closes pipe handles before `ClosePseudoConsole` (pty.zig:458-462). On pre-24H2 builds ClosePseudoConsole
  blocks until output drained; current order (close read end first) avoids the deadlock. Keep order; document it.
- [MINOR] `PosixPty` mode API (`getMode`, termios polling for password-echo detection) is absent: Exec.zig:184,243,329 correctly
  skip the termios timer on Windows. Consequence: no "password prompt / echo off" detection (only used for cosmetic secure input).

### 1.2 Spawn path (src/Command.zig startWindows, 305-440)
- `lpApplicationName = null`, program is first token of command line -> CreateProcessW does PATH search and `.exe` append. Good for
  `pwsh`, `wsl ~`. Command line built by `windowsCreateCommandLine` (Command.zig:618, copied from std; correct MS quoting).
- env: `createWindowsEnvBlock` (Command.zig:581) UTF-16, CREATE_UNICODE_ENVIRONMENT. (MINOR) Block is not sorted/case-folded;
  Windows tolerates it. EnvMap lookups for `PATH` vs `Path`: global.environMap() returns Zig EnvMap which is case-insensitive on
  Windows (std behaviour); `env.put("PATH", ...)` in Exec.zig:~700 relies on that. UNVERIFIED for the 0.17 `Environ.Map`.
- cwd: UTF-16, validated with `Dir.cwd().access` (Exec.zig:~960). Accepts only real Windows paths (see 1.6 OSC 7 problem).
- stdin/stdout/stderr = null on Windows (Exec.zig:1027-1039): ConPTY attribute supplies them. `bInheritHandles=TRUE`
  (Command.zig:427) - OK because all pty handles are non-inheritable.
- No Job object: `killCommand` = `TerminateProcess(pid, 0)` (Exec.zig:1164) kills ONLY the shell, not its children (git bash ->
  `sleep`, ssh, etc. survive). [MAJOR] Create a Job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, assign the child suspended
  (CREATE_SUSPENDED + ResumeThread) or via PROC_THREAD_ATTRIBUTE_JOB_LIST; terminate/close the job on surface close.
  (ClosePseudoConsole also kills attached clients on modern conhost, but not reliably for detached grandchildren.)
- Exit code type: `Command.Exit` is a union on Windows (Command.zig:115); `xev.Process.wait` -> `processExit` gets u32 (Exec.zig:~290).
- (MINOR) argv[0] is not resolved/validated before spawn; error `FileNotFound` from CreateProcessW surfaces as generic
  `Unexpected` via `windows.unexpectedError(GetLastError())` (Command.zig:433). Map ERROR_FILE_NOT_FOUND/ERROR_PATH_NOT_FOUND to a
  friendly "command not found" message in the surface (important for the shell fallback chain, see 3.3).
- (MINOR) Command.zig tests are all `SkipZigTest` on Windows for the POSIX cases; Windows variants exist at :840-980.

### 1.3 Exec.zig - things that will not compile / run right
- [BLOCKER] (UNVERIFIED but evident) `src/termio/Exec.zig:2003` and `:2007`:
  `try args.append(alloc, try alloc.dupeSentinel(u8, argv0), 0);` - misplaced paren: `dupeSentinel` gets 2 args and `append` 3.
  Must be `try args.append(alloc, try alloc.dupeSentinel(u8, argv0, 0));` (same for `tok`). Only analysed on Windows
  (`comptime builtin.target.os.tag == .windows` branch), so upstream never noticed.
- [BLOCKER?] (UNVERIFIED) HANDLE-vs-fd typing: `threadEnter` stores `internal_os.pipe()` results (Windows `HANDLE`s) in
  `posix.fd_t`-typed fields (`read_thread_pipe`, `read_thread_fd`, Exec.zig:537-538) and calls
  `posix.system.close(pipe[0])` / `posix.system.write(exec.read_thread_pipe, "x", 1)` + `posix.errno` (Exec.zig:127-128,206,550,1781).
  On Windows `posix.fd_t` is `HANDLE` in std, but `posix.system.write/close` may not exist for the windows target in Zig 0.17
  (std.os.windows is being gutted - see the NOTE at top of src/os/windows.zig). Replace with `windows.exp.kernel32.WriteFile/CloseHandle`
  (or an auto-reset Event, see next item).
- [MAJOR] Read-thread shutdown race (Exec.zig:213-229, 1778-1829): `threadExit` writes "x" to quit pipe then `CancelIoEx(read_fd, null)`.
  If the cancel lands while the thread is inside `processOutput` (not in `ReadFile`), the cancel is lost, the thread re-enters
  `ReadFile` and blocks forever, so `read_thread.join()` hangs -> surface/app hang on close. Also the quit check (`PeekNamedPipe`) only
  runs after an `OPERATION_ABORTED`. Fix: overlapped `ReadFile` on `out_pipe` is impossible (anonymous pipe) - instead create the
  out pipe as a named overlapped pipe too (as already done for in_pipe) and `WaitForMultipleObjects({read_event, quit_event})`;
  or loop `CancelSynchronousIo(thread_handle)` + short sleep until join succeeds.
- [MAJOR] Windows read loop is the old single-stage loop with a 1 KiB buffer (Exec.zig:1792 `buf: [1024]u8`) and no gather/reader
  pipeline (POSIX has the 2-thread batched pipeline, Exec.zig:1284-1760). Throughput under `cat bigfile` will be poor. Use >=64 KiB buffer
  (ConPTY delivers whatever conhost batches) and consider porting the gather/process split with an Event instead of poll().
- [MAJOR] After child exit the out pipe does NOT EOF (conhost holds the write end until ClosePseudoConsole). Current design relies on
  xev.Process exit -> `child_exited` -> surface close -> `threadExit` -> CancelIoEx. Trailing output written just before exit may be
  dropped if the surface closes immediately; ConPTY docs recommend: on child exit, ClosePseudoConsole (async on a helper thread) then
  drain the pipe until EOF. Needed for `wait-after-command` correctness and for short-lived `cmd /c` commands.
- [MINOR] `TERMIOS_POLL_MS` timer + `focusGained` skip on Windows (Exec.zig:243) fine. `termiosTimer` panics on Windows (Exec.zig:329) -
  guarded by never starting it.
- [MINOR] Writes: `xev.Stream.initFd(pty_fds.write)` with the overlapped named pipe `in_pipe` (Exec.zig:~121). libxev IOCP associates
  the handle with its completion port; ok. Input larger than the 4096-byte pipe buffer is fine (async).
- [MINOR] `Subprocess.start` flatpak/`/dev/null`/`/bin/sh` branches are runtime-guarded by `internal_os.isFlatpak()` (false on Windows).

### 1.4 Child environment (Exec.zig Subprocess.init, 625-770)
- [MAJOR] `TERM`: `cfg.term` default `xterm-ghostty` (Config.zig:3935). Resources dir exists on Windows so `TERM=xterm-ghostty`,
  `COLORTERM=truecolor`, `TERMINFO=<share>/terminfo` (Exec.zig:~645-659). But GhosttyResources skips `tic` on Windows
  (src/build/GhosttyResources.zig:57) and only installs the terminfo SOURCE `share/terminfo/ghostty.terminfo`. Git Bash (msys ncurses),
  vim, less, htop etc. will print "unknown terminal type xterm-ghostty". Options: (a) on Windows default `term` to `xterm-256color` unless
  a compiled db is present; (b) write the compiled (binary) terminfo entry from `src/terminfo/Source.zig` in `main_build_data.zig`
  (no external `tic` needed) into `share/terminfo/{g,x}/...` and optionally copy into Git's `usr/share/terminfo`; (c) both.
  Recommended: (a) now, (b) later.
- [MINOR] Exec.zig:~660-700 appends `exe_dir` to PATH with `;` (delimiter is platform-correct) and sets `GHOSTTY_BIN_DIR`. Fine.
  The macOS-only `XDG_DATA_DIRS`/`MANPATH` block is correctly skipped.
- [MINOR] `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`: fine. `PWD` env set to cwd (Exec.zig:~880) - harmless on Windows.
- [MAJOR for Git Bash] A login msys bash `cd`s to `$HOME` unless `CHERE_INVOKING=1`. When the default shell is Git Bash with
  `working-directory = inherit/path`, set `CHERE_INVOKING=1` in the child env (Windows only) or the cwd is lost. Also `MSYSTEM`
  defaults are set by /etc/profile when `--login` is used.
- [MINOR] `LANG`/locale: os/locale.zig:35 early-returns on Windows after `setlocale(LC_ALL,"")`; child shells (Git Bash) choose UTF-8
  themselves. Consider `LANG=en_US.UTF-8`-style default only for msys bash if mojibake seen. ConPTY itself is UTF-8.

### 1.5 Signals, process lifecycle
- No SIGCHLD/SIGUSR2/SIGHUP in core: `global.initSignals` is a no-op on Windows (global.zig:411); SIGUSR2 config reload is not in
  core at all (GTK-only). `killPid`/`getpgid`/`killpg`/`waitpid` (Exec.zig:1180-1250) are POSIX only (not analysed on Windows).
  Windows equivalent of "SIGHUP the process group" = job object / ClosePseudoConsole (see 1.2).
- Ctrl+C: with ConPTY, a `0x03` byte written to the input pipe makes conhost raise CTRL_C_EVENT for the attached console processes.
  No special handling in core required (Ghostty's key encoder emits 0x03 for ctrl+c). Ctrl+Break (`ctrl+pause`) maps to CSI sequence -
  verify in key_encode; MINOR.

### 1.6 Working directory / OSC 7 (stream_handler.zig:1533-1603)
- [MAJOR] OSC 7 `file://host/C:/Users/x` is parsed into `path = "/C:/Users/x"` and stored as terminal pwd verbatim
  (stream_handler.zig:1589-1591). Surface.pwd() (Surface.zig:2180) hands it to "new tab/window inherits cwd" -> `Dir.access("/C:/Users/x")`
  fails -> falls back to inherit (Exec.zig:~960 warns). Also Git Bash's shell integration emits MSYS paths
  `kitty-shell-cwd://HOST/c/Users/x` (bash/ghostty.bash:196 uses `$PWD`). Fix in core: after `toRawMaybeAlloc`, on Windows
  (a) strip leading `/` before a drive letter, (b) translate `/c/foo` (single-letter first component) to `C:\foo`, (c) normalise `/`->`\`.
  Better: in the bash integration use `cygpath -m "$PWD"` when `OSTYPE` is msys/cygwin, and in pwsh integration emit `file:///C:/...`.
- [MINOR] hostname check: `os/hostname.zig:21-27` uses `GetComputerNameA` and byte-exact compare; Windows NetBIOS names are upper case while
  `$HOSTNAME` in msys is usually lower case, and PowerShell `[Environment]::MachineName` upper. Make the Windows branch case-insensitive
  (`std.ascii.eqlIgnoreCase`). Currently OSC 7 from Git Bash may be rejected as non-local. (MAJOR if hit; trivial fix.)
- Surface.zig:5868 scrollback temp files already handle Windows (no mode bits).

---------------------------------------------------------------------------------------------------------------------------

## 2. src/os/ (file by file)

| file | Windows status | notes / proposed approach |
|---|---|---|
| main.zig | ok | exports everything; test block fine. |
| windows.zig (378 lines) | HAS | hand-declared kernel32/ntdll externs + consts (CreatePseudoConsole, ResizePseudoConsole, ClosePseudoConsole, InitializeProcThreadAttributeList, UpdateProcThreadAttribute, CreateNamedPipeW, CancelIoEx, PeekNamedPipe, VirtualAlloc, GetComputerNameA, GetTempPathW...). Header comment: std.os.windows is being stripped, this is the bridge. Add what we need: Job objects, GetUserProfileDirectoryW / SHGetKnownFolderPath, AttachConsole, SetStdHandle, OutputDebugStringW, WaitForMultipleObjects, CreateEventW, CancelSynchronousIo, MiniDump*. [MINOR] |
| homedir.zig | HAS (weak) | `homeWindows` = `HOMEDRIVE`+`HOMEPATH` (homedir.zig:~100). Should be `USERPROFILE` first (HOMEPATH is wrong under roaming profiles / when launched from some contexts; unset in services), then HOMEDRIVE+HOMEPATH, then `SHGetKnownFolderPath(FOLDERID_Profile)`. `expandHome` on Windows returns the path UNCHANGED (homedir.zig:~118: "`~/` is not an idiom on Windows"), so `~/foo` in config is never expanded. [MAJOR] Implement `~/` and `~\` expansion via the fixed `home`. |
| xdg.zig | HAS (wrong target) | See section 3.1: config/cache/state use `XDG_*_HOME` else `%LOCALAPPDATA%` (xdg.zig:24-47, 76-80), only falling back to home when LOCALAPPDATA is unset. Does NOT resolve to `%USERPROFILE%\.config`. [MAJOR] |
| open.zig | HAS | `rundll32 url.dll,FileProtocolHandler <url>` (open.zig:38). Works for http(s) and files; fails for URLs with `&`? (argv is passed through CreateProcess quoting; ok). Prefer `ShellExecuteW` in apprt (apprt does its own open_url). [MINOR] |
| passwd.zig | NONE (by design) | `@compileError` on Windows (passwd.zig:25-27) and `posix_c` import is `void`. Callers already branch: Config.zig:4843 (.windows branch uses `internal_os.home`), Exec.zig execCommand passes `internal_os.passwd` only used on Darwin. OK. For default-shell lookup do NOT use passwd; see 3.3. |
| path.zig (`expand`) | HAS (buggy on Windows) | `expand()` returns cmd as-is if it contains `'/'` (path.zig:16) - Windows `\` and `C:\` are not detected; searches PATH only for the literal name (no PATHEXT: `pwsh` -> needs `pwsh.exe`); `isExecutable` always true on Windows (path.zig:64). Not used by Exec on Windows (CreateProcess searches). Needed by our shell-resolution code: add `expandWindows` (PATHEXT, `\`, drive letters, skip `C:\Windows\System32\bash.exe` = WSL launcher). [MAJOR] for the shell fallback chain. |
| resourcesdir.zig | HAS | sentinel `terminfo/ghostty.terminfo` on Windows (resourcesdir.zig:~60), climbs from exe dir looking for `<dir>/share/terminfo/ghostty.terminfo`, returns `<dir>/share/ghostty`. `GHOSTTY_RESOURCES_DIR` honored in non-debug. `maybeDir` builds paths with `/` separators (works on Win32 APIs). Needs `-Demit-terminfo` (default true on Windows, Config.zig:535). Portable-zip layout `ghostty.exe` + `share\...` works. [OK] Debug builds ignore the env var first; documented. |
| desktop.zig | HAS | `launchedFromDesktop` = false, `desktopEnvironment` = .windows (desktop.zig:59,84). Affects `probableCliEnvironment` (Config.zig:5350 returns false on Windows) -> SHELL env var ignored, default cwd `.home`. Fine for GUI app. [OK] |
| file.zig | HAS | `allocTmpDir` via GetTempPathW (file.zig:68); `fixMaxFiles/restoreMaxFiles` posix getrlimit (guarded? `posix.getrlimit` call at file.zig:18 - only called on non-Windows from global.zig; verify guard) [MINOR]. `randomTmpPath` ok. |
| stderr.zig | HAS | raw NtWriteFile to `PEB.ProcessParameters.hStdError` (stderr.zig:20). With `subsystem = .windows` that handle is NULL unless redirected -> logs vanish. See section 7.1. [MAJOR] |
| locale.zig / i18n.zig | stubs | locale: `setlocale` then early return (locale.zig:35). i18n: returns immediately (i18n.zig:33); `-Di18n` default false on Windows (Config.zig:268-276). No translations. [MINOR] Later: use `GetUserPreferredUILanguages` + bundled .mo via gettext-less loader. |
| pipe.zig | HAS | anonymous CreatePipe (non-overlapped). Used only for the read-thread quit pipe. See 1.3. |
| hostname.zig | HAS | case-sensitive compare, see 1.6. |
| mouse.zig | NONE | `clickInterval()` returns null except macOS (mouse.zig:25). apprt win32 should supply `GetDoubleClickTime()` (core falls back to 500 ms). [MINOR] |
| kernel_info.zig | Linux-only | returns null elsewhere (kernel_info.zig:7). Used by `+version`/crash info. Optional: `RtlGetVersion` build number. [MINOR] |
| cgroup.zig, systemd.zig, dbus.zig, flatpak.zig | Linux-only | not referenced on Windows paths (all gated by `builtin.os.tag == .linux` or `isFlatpak()`); `flatpak.zig` still compiled (`FlatpakHostCommand` exported from main.zig:51); compiles on Windows upstream? UNVERIFIED. [MINOR] |
| mach.zig, macos.zig, cf_release_thread.zig | macOS | `macos.appSupportDir` referenced from file_load.zig:78-84 but only called under `.macos` comptime. |
| edit.zig | POSIX-flavoured | `getConfigEditCommand` defaults to `vi`/`nano` and shell-escapes with POSIX single quotes (edit.zig:60-65, shell.zig). For Windows: default editor `notepad` (or `ShellExecute open`), no POSIX escaping. [MAJOR] for `+edit-config`/"open config" action. |
| shell.zig (`ShellEscapeWriter`) | POSIX | POSIX single-quote escaping; used by edit.zig, ssh and `drag-drop paste` in apprt. Need a Windows/pwsh/cmd-aware variant (apprt decides by current shell). [MINOR] |
| uri.zig | portable | `std.Uri` based; MAC-address hack irrelevant. See OSC 7 note 1.6. |

---------------------------------------------------------------------------------------------------------------------------

## 3. Configuration

### 3.1 Required decision: ONE config path `%USERPROFILE%\.config\ghostty\config.ghostty` (XDG_CONFIG_HOME replaces the base if set; no legacy `config` fallback on Windows)

Answer to the coordinator's question: **No, `internal_os.xdg` does NOT resolve to %USERPROFILE% on Windows today.**
Current behaviour (xdg.zig `dir()`, lines 62-104):
1. if `opts.home` is passed -> `home/.config/<subdir>` (XDG env ignored; no caller passes it today);
2. else `XDG_CONFIG_HOME`, **else `%LOCALAPPDATA%`** (xdg.zig:24-30, 78-81) -> so config is currently
   `%LOCALAPPDATA%\ghostty\config.ghostty` (note: no `.config`);
3. only if both env vars are unset: `homedir.home()` -> `HOMEDRIVE+HOMEPATH` + `.config` (not USERPROFILE).
`~` is not involved in xdg at all; `internal_os.expandHome` is an identity function on Windows (homedir.zig:~118) and
`config/path.zig:165` skips `~/` expansion on Windows.

Required changes (all small):
- `src/os/xdg.zig`: remove the `windows_env = "LOCALAPPDATA"` fallback for `config()` (keep `LOCALAPPDATA` for `cache()`/`state()` -
  recommended: crash dir, ssh-cache, sentry cache are machine-local data; decision for coordinator, see 3.5).
  Result: `XDG_CONFIG_HOME` (if non-empty) else `<home>\.config`.
- `src/os/homedir.zig` `homeWindows`: `USERPROFILE` first (then HOMEDRIVE+HOMEPATH, then SHGetKnownFolderPath). Make `xdg.dir` use it
  (it already calls `homedir.home` at xdg.zig:92). Also fix `expandHome` to expand `~/` and `~\`.
- `src/config/file_load.zig`: `defaultXdgPath` (:12-20) already yields `ghostty/config.ghostty` via `xdg.config(... .subdir="ghostty/config.ghostty")`.
  Note `.subdir` contains `/`; `std.fs.path.join` on Windows keeps `/` inside the string -> mixed separators
  (`C:\Users\x\.config\ghostty/config.ghostty`). Works with Win32 but `assert(std.fs.path.isAbsolute)` in `open()` (:121) is fine; for
  display and comparison normalise with `std.fs.path.join` per component ("ghostty","config.ghostty"). [MINOR]
- Legacy `config` filename must NOT be read on Windows:
  - `src/config/Config.zig:4245-4262` `loadDefaultFiles` unconditionally loads `legacyDefaultXdgPath` first -> gate with
    `if (comptime builtin.target.os.tag != .windows)`.
  - `src/config/file_load.zig:34-58` `preferredXdgPath` tries legacy path -> skip on Windows.
  - `src/config/edit.zig:132-133` `configPathCandidates` appends legacy -> skip on Windows.
  - `src/config/Config.zig:4328` first-run template: `else` branch already writes `config-template` to `xdg_path` and creates parents
    (`writeConfigTemplate`, :4220: `createDirPath`) when nothing was loaded -> gives "created there on first run" for free.
- `src/config/theme.zig:35` user themes dir = `xdg.config(... "ghostty/themes")` -> follows the new base automatically
  (`%USERPROFILE%\.config\ghostty\themes`); resources themes at `<share>/ghostty/themes` need `-Demit-themes` (default false; set true
  for Windows release packaging, Config.zig:551).
- `config-file = ~/x` and `working-directory = ~/x` need the `~` expansion fix above (Config.zig:4631 `expandHome`, path.zig:165).

### 3.2 CLI actions (src/cli/) that are POSIX-only or need console
- [MAJOR] `+edit-config`: hard-fails on Windows (cli/edit_config.zig:87-95, uses `execve`). Implement: resolve editor
  (`%VISUAL%`/`%EDITOR%`, else `notepad.exe`; or `ShellExecuteW "open"`/`edit` verb on the config path), spawn detached, return 0.
- [MAJOR] GUI subsystem exe -> `+help`, `+version`, `+list-fonts`, `+list-themes`, `+show-config`, `+validate-config`, `+boo`... print nothing
  from a terminal (see 7.1). cli/Pager.zig spawns `less` (cli/Pager.zig:54-68) only if stdout is a TTY: on Windows `less` is usually absent
  (Git Bash's less not on cmd PATH) -> falls through to direct stdout on spawn failure? check (initPager returns null on error). [MINOR]
- `cli/tui.zig` / `list_themes` / `list_colors` / `list_keybinds` use libvaxis (vaxis.Tty); list_colors.zig:96 and list_keybinds.zig:242 have
  `.windows` branches (can_pretty_print). vaxis has a Windows tty backend; UNVERIFIED with this Zig version. [MINOR]
- `cli/list_fonts.zig:105`: comment says the Windows backend opens candidate font files; ok.
- `cli/ssh.zig`, `cli/ssh_cache.zig`: spawn `ssh` via std.process; DiskCache perms guarded (`mode_t != u0`). ssh.exe from Windows OpenSSH works. [OK]
- `+new-window`, `+toggle-quick-terminal`: need apprt IPC (apprt/ipc.zig is GTK DBus only) -> unsupported on win32 unless a named-pipe IPC
  is added. [MINOR]
- `+crash-report` relies on sentry dir (see 7.5). [MINOR]

### 3.3 Default command/shell resolution - where Git Bash -> pwsh -> cmd hooks in
Current: `Config.finalize()` (Config.zig:4805-4850):
- `.windows` branch (Config.zig:4843-4858): if `command == null` -> logs "no default shell found, will default to using cmd" and sets
  `.shell = "cmd.exe"`; if `working-directory == .home` -> `internal_os.home()`.
- Exec.zig:~765 has a second default (`.windows => "cmd.exe"`), and `execCommand` (Exec.zig:1977-2010) resolves bare `cmd.exe` through `%COMSPEC%`
  and splits `.shell` values on whitespace (no quoting - a Git Bash path under `C:\Program Files\Git\bin\bash.exe` MUST be configured as
  `.direct` or the whitespace split breaks it). [BLOCKER for Git Bash default]

Proposed hook (single place): replace the `.windows` arm at Config.zig:4843 with a call to a new `internal_os.shell_resolve.defaultWindowsShell(alloc, environ_map)`
that returns a `Command` (prefer `.direct` argv so spaces survive):
1. Git Bash: candidates in order - `%ProgramFiles%\Git\bin\bash.exe`, `%ProgramFiles(x86)%\Git\bin\bash.exe`, `%LOCALAPPDATA%\Programs\Git\bin\bash.exe`,
   registry `HKLM\SOFTWARE\GitForWindows\InstallPath` (+HKCU), or `git.exe` found on PATH -> `..\..\bin\bash.exe`. Do NOT accept `bash` from PATH blindly:
   `C:\Windows\System32\bash.exe` is the WSL launcher. Argv: `{bash.exe, "--login", "-i"}`; env `CHERE_INVOKING=1` (keeps cwd); prefer `bin\bash.exe`
   (launcher) over `usr\bin\bash.exe`. Optionally `MSYSTEM=MINGW64` explicit.
2. pwsh: `pwsh.exe` via PATH/PATHEXT, `%ProgramFiles%\PowerShell\7\pwsh.exe`, WindowsApps alias `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`
   (reparse point: `Dir.access` works, CreateProcess works). Argv `{pwsh.exe, "-NoLogo"}` (plus `-NoExit -Command ...` when injecting integration, see 6).
3. cmd: `%COMSPEC%` else `C:\Windows\System32\cmd.exe`.
Log which one was chosen. The resolution is cheap (stat calls) but run it only when `command == null`. If the chosen exe later fails to spawn, Exec should
fall back to the next candidate (needs a small retry loop in `Subprocess.start`/surface init, otherwise a stale registry entry kills the window). [MAJOR]

Related:
- `SHELL` env is ignored on Windows (`probableCliEnvironment() == false`, Config.zig:5350). When the user launches Ghostty from Git Bash, `SHELL=/usr/bin/bash`
  is an msys path - good that it's ignored.
- `command` config parsing (config/command.zig): `shell:` vs `direct:` prefix; whitespace-split in Exec.zig means Windows users with spaces need `direct:`.
  Consider a Windows-aware tokenizer honoring double quotes for `.shell` (Exec.zig:2005-2009). [MAJOR]
- shell-integration detection: see section 6.

### 3.4 Other config defaults with platform switches (Config.zig)
- `font-size` 12 (:271), `copy-on-select` none (:2543; `true` -> `.clipboard`, :5141), `alpha-blending` `linear-corrected` (:409), `quit-after-last-window-closed`
  linux-only (:2637), `quick-terminal-autohide` false (:2858). Windows default keybinds: non-Darwin set (ctrl+shift+c/v copy/paste etc., Config.zig:6685-7128);
  `super` = Win key (OS-reserved: apprt must not expect it). `linux-cgroup` only linux (:3719). [OK]

### 3.5 Decision flags for the coordinator
- cache/state/crash dirs: left at `%LOCALAPPDATA%` (xdg.zig `windows_env`) vs moving to `%USERPROFILE%\.cache` / `.local\state`. Recommend LOCALAPPDATA for those two,
  USERPROFILE\.config for config only (needs a per-kind flag in xdg.zig `InternalOptions`).

---------------------------------------------------------------------------------------------------------------------------

## 4. Fonts (src/font/)

Backends (font/backend.zig): freetype, **freetype_windows (default on Windows)**, fontconfig_freetype, coretext*, web_canvas. Shaper: harfbuzz for freetype*
(backend.hasHarfbuzz). Face: freetype.zig. So rendering = FreeType + HarfBuzz already; fontconfig explicitly avoided on Windows (libxml2 symlink issue noted in backend.zig:49).

### 4.1 What discovery does today (discovery.zig:965-1150, `Windows`)
- `discover()`: iterate `%SYSTEMROOT%\Fonts` then `%LOCALAPPDATA%\Microsoft\Windows\Fonts`; for every `.ttf/.ttc/.otf` open with FreeType (`Face.initFile`, up to 16 faces per .ttc) and
  match: `family` vs FT `family_name` or SFNT name (`familyMatches`, case-insensitive), `codepoint` via `glyphIndex`. `discoverFallback` = `discover`.
- Result `DeferredFace.win` (font/DeferredFace.zig:66) keeps path, face index, variations and an open "peek" FreeType face; `load()` reopens at requested size.
- Gaps (all consequences of directory scanning):
  - [MAJOR] **bold/italic/style/monospace/size in `Descriptor` are ignored** (discovery.zig:1085-1095 only family+codepoint). SharedGridSet asks for regular/bold/italic/bold-italic
    separately and takes the FIRST hit (SharedGridSet.zig:196-203). With `font-family = "Consolas"`, all four styles resolve to whichever Consolas file appears first in
    directory order -> wrong or synthesized-over styles. Must filter/rank on weight (OS/2 usWeightClass), italic (macStyle/fsSelection), style name (`desc.style`), variable axes.
  - [MAJOR] **Cost**: each query opens every font file in C:\Windows\Fonts (~300+ files) via FT_New_Face; fallback queries (one per uncovered codepoint, CodepointResolver.zig:175)
    repeat the full scan -> UI stalls when printing CJK/emoji/symbols. Needs an index built once (name table family/style/weight/italic + cmap coverage bitset lazily) or DirectWrite.
  - [MAJOR] **Fallback quality**: codepoint-only search returns the first file that has the glyph (alphabetical/dir order), not a sensible face (e.g. Arial Unicode vs Segoe UI Symbol/Emoji,
    Yu Gothic/Meiryo/Malgun). No emoji preference: `Descriptor` carries no presentation; Segoe UI Emoji (COLR v0, supported by FreeType) never preferred over embedded Noto Color Emoji.
    Note Windows also has `emoji` handled by the embedded Noto fonts (SharedGridSet.zig:377-415, non-Darwin path), so emoji works but is stylistically non-native.
  - [MINOR] Fonts installed system-wide are enumerated from the registry (`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`), per-user from `HKCU\...\Fonts` - file location can be
    outside the two directories (per-user installs go to LOCALAPPDATA dir, covered; but "Fonts" registry entries may point to arbitrary paths, and Win11 "cloud fonts"/MS Store fonts
    live under `%ProgramFiles%\WindowsApps\...` or C:\Windows\Fonts with `.fon/.fnt/.ttc/.otc` ... `.otc` not matched).
  - [MINOR] Aliases: "monospace", "Consolas" vs "Consolas Regular" full names, localized family names (SFNT name IDs 1/16/21), `font-family = "Cascadia Code"` works by FT family_name.
  - [MINOR] Default font when `font-family` unset: embedded JetBrains Mono (font/embedded.zig:12-14 `variable`, `variable_italic`) + Symbols Nerd Font (:17) + Noto Color Emoji/Noto Emoji
    (:25-26) - no discovery needed, works on Windows as-is. These are embedded only if referenced (they are). Embedded set is enough for first run. [OK]

### 4.2 DirectWrite discovery backend: what it must implement (recommended for discovery/fallback ONLY; keep FreeType+HarfBuzz for rasterisation+shaping)
Interface contract (taken from discovery.zig `Fontconfig`/`CoreText`/`Windows` + DeferredFace.zig; `font/main.zig`/`face.zig`/`library.zig`/`shape.zig` backend switches must learn the new tag,
e.g. `directwrite_freetype`, mirroring how `freetype_windows` was threaded: backend.zig:13,69,91,103,116; face.zig:13; library.zig:13; shape.zig:22; DeferredFace.zig:30,131,147,177,213,350):
```
pub const DirectWrite = struct {
    pub fn init(lib: Library) DirectWrite
    pub fn deinit(self: *DirectWrite) void
    pub fn discover(self: *const DirectWrite, alloc, desc: Descriptor) !DiscoverIterator
    pub fn discoverFallback(self: *const DirectWrite, alloc, collection: *Collection, desc: Descriptor) !DiscoverIterator
    // optional: discoverExactFamily (SharedGridSet.zig:347 uses @hasDecl; only Darwin path)
    pub const DiscoverIterator = struct { pub fn next(self) !?DeferredFace; pub fn deinit(self) void };
};
```
DeferredFace payload (extend `.win`): file path OR in-memory font bytes + face index, variations, presentation, family/full name (for `familyName()`/`name()`),
cheap `hasCodepoint(cp, presentation)` (use `IDWriteFontFace::GetGlyphIndices` or retain a FreeType peek), `load(lib, opts)` -> `Face.initFile` / `Face.init(memory)`.
Implementation notes:
- COM from Zig: hand-declare vtables for IDWriteFactory3/5 (`DWriteCreateFactory(SHARED, IID_IDWriteFactory3)`), IDWriteFontCollection1 (system), IDWriteFontFamily,
  IDWriteFont/IDWriteFontFace3, IDWriteFontFallback (factory2 `GetSystemFontFallback`, `MapCharacters`), IDWriteLocalizedStrings, IDWriteFontFile/IDWriteLocalFontFileLoader
  (`GetFilePathFromKey`). Needs `CoInitializeEx(COINIT_MULTITHREADED)` on the thread (font discovery runs on the render/surface init thread - see SharedGridSet.discover()).
- `discover()`: `FindFamilyName(family)`; if not found, try full-name / fallback to localized names; build style-matched list with
  `GetFirstMatchingFont(weight, stretch, style)` for bold/italic; honor `desc.monospace` (IDWriteFontFace1 `IsMonospacedFont`) and `desc.codepoint` (`HasCharacter`); emit in best-match order.
- `discoverFallback()`: `IDWriteFontFallback::MapCharacters` with the text of the codepoint (+ base family from `collection`'s primary) gives the OS-chosen fallback (Segoe UI Emoji, Segoe UI Symbol,
  Yu Gothic UI, Microsoft YaHei...) - this is the main quality win.
- Fonts with non-file loaders (rare: remote/cloud fonts, `IDWriteFontFileStream`) -> read stream fully and use `FT_New_Memory_Face` (lifetime owned by DeferredFace).
- Variable fonts: DWrite named instances vs FreeType `setVariations` (existing `Variation` list) - keep FreeType path.
- DirectWrite DLL is system (`dwrite.dll`); link via import lib in zig (`exe.linkSystemLibrary("dwrite")`) - note build must add it (`SharedDeps.zig` windows section ~:974 area).
- Cheaper intermediate step if DWrite is deferred: in the existing `Windows` backend add (1) a one-time name-table index of the font directories (family, subfamily, weight, italic, ttc index; cmap
  coverage cached lazily), (2) style filtering/ranking, (3) a hard-coded Windows fallback list (Segoe UI Emoji, Segoe UI Symbol, Cascadia Mono, Consolas, Yu Gothic, Malgun Gothic, Microsoft YaHei, SimSun) tried before full scan.

### 4.3 Other font notes
- `face.default_dpi = 96` on non-macOS (font/face.zig:29) - correct; apprt provides content scale (`apprt.ContentScale`).
- Freetype/harfbuzz/zlib/libpng build for `x86_64-windows-msvc`: existing `pkg/*` build.zig files; SharedDeps.zig:975 disables ubsan for Windows C objects. The zig-out contains `ghostty-vt.dll` so libs build. [OK]
- Sprite/box-drawing, Nerd Font attributes, atlas: platform independent.
- Nerd symbols patched fonts + Cascadia Code/Mono (ships with Windows Terminal, not always installed) - default stays embedded JetBrains Mono. [OK]

---------------------------------------------------------------------------------------------------------------------------

## 5. Input (src/input/ + what Win32 apprt must translate)

Core contract (src/input/key.zig `KeyEvent`): `key` (physical, W3C `Key` enum), `mods` (+ `sides`, caps/num lock), `consumed_mods`, `composing`, `utf8`, `unshifted_codepoint`, action press/release/repeat.
- Keymap: `src/input.zig:41-43`: `Keymap` = `KeymapDarwin` on macOS else `KeymapNoop` (translate returns empty text). Not used by GTK/win32; the apprt must produce utf8 itself. No work in core. [OK]
- keycodes: `input/keycodes.zig` `entries` for `.windows` use column 3 (`native`). Table values are Chromium `dom_code_data.inc` "win" scancodes = set-1 make codes with `0xE0xx` for extended keys
  (e.g. ArrowUp 0xE048, Insert 0xE052, NumpadEnter 0xE01C, ControlRight 0xE01D, AltRight 0xE038, MetaLeft 0xE05B, PrintScreen 0xE037; Pause = 0x0045, NumLock = 0xE045).
  Win32 mapping recipe: `scancode = (lParam >> 16) & 0xFF; if (lParam & (1<<24)) scancode |= 0xE000;` then look up `keycodes.entries` by `.native`. Special cases the table does NOT solve:
  - Pause/Break vs NumLock: table has Pause=0x0045, NumLock=0xE045 (keycodes.zig:316,330); Win32 reports them inconsistently, so disambiguate by VK.
  - Numpad with NumLock off arrives as navigation VKs with extended=false and scancode of numpad keys (0x47-0x53); table maps these to Numpad* entries (OK by scancode).
  - Shift-extended-fake events: left-shift fake `0xE02A` events on Insert/Delete/arrows with NumLock on: ignore scancodes 0xE02A/0xE036.
  - IntlBackslash 0x56, IntlYen 0x7D, IntlRo 0x73, Lang1/Lang2 (Hangul/Hanja 0x72/0x71), Convert/NonConvert/KanaMode: present in table.
  - [MAJOR] A reverse map physical-key -> VK is not provided (needed for `MapVirtualKeyW` text translation); apprt must compute.
- Kitty keyboard protocol needs the physical key (`event.key`) + `unshifted_codepoint` + `consumed_mods` + `utf8`: all supplied by the apprt, scancode table exists, so protocol support is feasible. Key
  release events need `action=.release` (WM_KEYUP/WM_SYSKEYUP); repeat = bit 30 of lParam.
- Text generation (apprt responsibility, `ToUnicodeEx`): call with the key state minus Ctrl (so Ctrl+letter yields the letter; core generates control codes from `key`+`mods`, see key_encode.zig:152-231),
  flag 0x4 (don't alter keyboard state) to avoid consuming dead keys, `unshifted_codepoint` via ToUnicodeEx with no shift/caps.
- Dead keys: handle `WM_DEADCHAR`/`WM_SYSDEADCHAR` + `WM_KEYDOWN` returning no text with `composing=true` when the layout has a pending dead key; send preedit as `utf8` with `composing=true`
  (key_encode.zig:152-165 ignores composing keys except modifiers). Use ToUnicodeEx's negative return value to detect dead key.
- AltGr: Windows reports AltGr as LCtrl+RAlt (fake LCtrl scancode 0x1D immediately before RAlt, same timestamp). Apprt must detect (GetKeyState(VK_RMENU)+VK_LCONTROL with `GetMessageTime` equality or
  keyboard-layout `AltGr` flag via `VkKeyScanEx` shift state bit 6) and, when the resulting text is non-empty, set `consumed_mods = ctrl|alt` and strip both from `mods`, otherwise
  `Ctrl+Alt+<letter>` text (e.g. `@`, `\` on DE/PL/RU layouts) is sent as ESC-prefixed control codes. [MAJOR - affects non-US users, e.g. user locale ru/en].
- Alt/Meta: core non-macOS: Alt always prevents associated text and ESC-prefixes (key_encode.zig:300-312, 402). Good for Git Bash/readline.
- Mods: caps_lock/num_lock must be set from `GetKeyState(VK_CAPITAL/VK_NUMLOCK) & 1`; `sides.*` from separate L/R VKs (GetKeyState(VK_LSHIFT...)).
- IME: core accepts preedit via `composing` + `apprt.IMEPos` (apprt/structs.zig) for candidate window placement (Surface `imePoint`). Win32 apprt needs TSF or IMM32 (`WM_IME_STARTCOMPOSITION/COMPOSITION/ENDCOMPOSITION`,
  `ImmSetCandidateWindow`/`ImmSetCompositionWindow` at cursor from `imePoint`); commit string arrives as `GCS_RESULTSTR` -> utf8 (no key). Core has no IME-specific code to port. [MAJOR for CJK users, not blocking]
- Keybinding defaults: non-Darwin; Win key (`super`) is swallowed by shell for Win+X combos; Windows-reserved: Alt+F4, Alt+Space, Ctrl+Alt+Del. Ctrl+Shift+C/V copy/paste default is right for terminals; `ctrl+c` must stay SIGINT-ish.
- [MINOR] `ctrl+backspace`, `ctrl+enter`, `shift+enter`: legacy encoding conventions are same as Linux; conhost (VT input) receives bytes as-is, but ConPTY input translation turns some sequences into key events;
  `CSI u`/kitty sequences are NOT understood by conhost's input parser unless passthrough mode; Win32-input-mode (CSI ?9001h) would let conhost-attached console apps see real key events
  (needed for native console apps like `far`, `edit.exe`, some TUIs; works only if Ghostty answers/uses win32-input-mode sequences `CSI Vk;Sc;Uc;Kd;Cs;Rc _`). Core does not implement 9001. [MAJOR for native Windows TUIs]

---------------------------------------------------------------------------------------------------------------------------

## 6. Shell integration (src/shell-integration/ + src/termio/shell_integration.zig)

Shipped scripts: bash/ghostty.bash (+ bash-preexec.sh), zsh/.zshenv + ghostty-integration, fish/vendor_conf.d/*.fish, elvish/lib/ghostty-integration.elv, nushell/vendor/autoload/ghostty.nu.
**No pwsh/PowerShell or cmd integration exists.** `Shell` enum (shell_integration.zig:14-20) and config enum `ShellIntegration` (Config.zig:8882) = none/detect/bash/elvish/fish/nushell/zsh.

Detection (`detectShell`, shell_integration.zig:134-165): `std.fs.path.basename(arg0)` compared to `"bash"`, `"elvish"`, `"fish"`, `"nu"`, `"zsh"` exact.
- [BLOCKER for auto-injection] `C:\Program Files\Git\bin\bash.exe` basename = `bash.exe` -> not detected -> NO shell integration. Fix: strip `.exe` (case-insensitive) on Windows before compare;
  the whitespace-tokenised command (`argIterator`) handles quotes via config.Command (see 3.3 for paths with spaces).
- Bash injection (`setupBash`, shell_integration.zig:298-410): spawns `bash --posix`, sets `ENV=<resources>/shell-integration/bash/ghostty.bash`, `GHOSTTY_BASH_INJECT`, `HISTFILE=<home>/.bash_history`.
  Findings for Git Bash (msys2 bash 5.x): `--posix` + `ENV` works on msys bash; ghostty.bash then sources `/etc/profile` and `~/.bash_profile|.bash_login|.profile` itself (ghostty.bash:~45-80),
  and `bash-preexec.sh`. Concerns:
  - [MAJOR] `ENV` path is built as `{resource_dir}/shell-integration/bash/ghostty.bash` with a Windows `resource_dir` (`C:\Users\...\share\ghostty`) -> mixed separators and backslashes inside
    a `[ -r ... ]`/`source` in bash are interpreted as escapes if unquoted by bash internals. msys bash accepts `C:/...` forward-slash paths and cygwin path conversion for env vars happens only for
    known vars (PATH, HOME, TMP...) - `ENV`/`GHOSTTY_RESOURCES_DIR` are not converted. Normalise to forward slashes (`C:/Users/...`) for any path put in env for MSYS shells (ENV, GHOSTTY_RESOURCES_DIR, GHOSTTY_BIN_DIR, HISTFILE).
  - [MAJOR] `--login`/`-i` passthrough: unknown args are forwarded (setupBash, "else" branch); `-c` aborts injection (good). Verify `bash.exe --posix --login -i` still reads ENV (bash reads ENV in posix interactive mode; ghostty.bash handles profile sourcing).
  - [MAJOR] OSC 7 payload uses `$PWD` = `/c/Users/me` (MSYS style) (ghostty.bash:196) -> see 1.6.
  - [MINOR] `HISTFILE` computed from `homedir.home` = Windows path; bash on msys interprets `C:\Users\x/.bash_history` badly; use forward slashes or leave HISTFILE unset on Windows.
  - [MINOR] sudo/ssh wrappers inside script irrelevant for Git Bash (`GHOSTTY_SHELL_FEATURES` includes `sudo`: wrapper exists only if `sudo` present).
  - Feature flags: `cursor`, `title`, `path` (adds GHOSTTY_BIN_DIR to PATH inside shell), `ssh-env`, `ssh-terminfo` - ok; `ssh-terminfo` needs `infocmp`/terminfo db (not on Windows hosts) -> disable by default on Windows.
- zsh/fish/elvish/nushell: only reachable via msys2/WSL/native nushell. Nushell native (`nu.exe`) works if detection strips `.exe`; `setupXdgDataDirs` uses `std.fs.path.delimiter` (`;` on Windows, shell_integration.zig:692) which elvish/fish
  under MSYS expect as `:` -> irrelevant for Windows-native shells. [MINOR]
- Required new work:
  1. [BLOCKER for pwsh parity] PowerShell integration: new `src/shell-integration/pwsh/ghostty.ps1` + `Shell.pwsh` + config enum value + `setupPwsh`. Mechanism: launch `pwsh -NoLogo -NoExit -Command ". '<resources>/shell-integration/pwsh/ghostty.ps1'"`
     (works for PowerShell 7 and Windows PowerShell 5.1; do not use `-File`). Script: wraps `prompt` function to emit OSC 133;A / B (prompt start/end), 133;C via PSReadLine `AddToHistoryHandler` or
     `PSConsoleHostReadLine` wrapper, 133;D;exitcode (use `$?`/`$LASTEXITCODE`), OSC 7 `file://$env:COMPUTERNAME/C:/...` using `$PWD.ProviderPath` (FileSystem provider only), OSC 2 title when `title` feature, cursor shape via OSC (DECSCUSR) for
     `cursor` feature, `GHOSTTY_SHELL_FEATURES` gating; must preserve user `$PROFILE` (do NOT use `-NoProfile`), and handle `Set-PSReadLineOption -PredictionSource` render interplay. Detection: `pwsh`, `pwsh.exe`, `powershell`, `powershell.exe`.
  2. cmd.exe: optional minimal integration through the `PROMPT` env var (`$E]133;A$E\$P$G$E]133;B$E\` and OSC 7 via `$E]7;file://%COMPUTERNAME%/$P$E\` where `$P` includes drive + backslashes - acceptable) - no preexec/133;C/D. [MINOR]
  3. Git Bash: detection fix + forward-slash env paths + MSYS->Windows path translation (1.6).
- Resources layout: `src/shell-integration` installed to `share/ghostty/shell-integration` excluding `*.md` (GhosttyResources.zig:~100-110) - add pwsh dir automatically.

---------------------------------------------------------------------------------------------------------------------------

## 7. Everything else

### 7.1 Startup, console, logging (src/main_ghostty.zig, global.zig)
- [MAJOR] `exe.subsystem = .windows` (src/build/GhosttyExe.zig:45) => no console. `ghostty.exe +version`, `+list-fonts`, `+show-config`, usage errors (main_ghostty.zig:24-47) print to a NULL stdout/stderr when started from cmd/pwsh/Git Bash;
  `std.log` goes to stderr (main_ghostty.zig `logFn`, `os/stderr.zig`) -> invisible. Options: (a) when `global.action() != null` (or `--help`), call `AttachConsole(ATTACH_PARENT_PROCESS)` early in `main`, then
  `SetStdHandle` to `CONOUT$/CONIN$` (the PEB handles are NOT updated by AttachConsole), (b) ship a console-subsystem twin `ghostty-cli.exe`/`ghostty.com` (as VS Code/Windows Terminal do), (c) always: add file logging
  `%LOCALAPPDATA%\Ghostty\logs\ghostty.log` + `OutputDebugStringW` sink in `logFn`. `global.logging()` struct has `stderr`/`macos` flags (global.zig:~299): add `file`/`debugger`. Recommended: (a)+(c).
- [MAJOR] `main_ghostty.zig:63-73`: the `app_runtime == .none` branch uses `std.io.getStdOut()` (removed API) - compile error if the Windows exe is built with runtime `.none` (the default for Windows: apprt/runtime.zig:21 `else => .none`).
  There is no `win32` entry in `apprt.Runtime` (apprt/runtime.zig:8-14), `apprt.zig` switch (:46-50) - being handled by the apprt worker; core needs `build_config.app_runtime == .win32` plumbing only.
- `global.init` (global.zig:55-250): C API arg handling `error.UnsupportedOSForCApi` on Windows (global.zig:75) - matters only for libghostty C API. `syncEnviron` no-op on Windows (global.zig:309). `rlimit`/`fixMaxFiles` skip.
- High-DPI/manifest: `dist/windows/ghostty.manifest` + `.rc` exist (embedded via `addWin32ResourceFile`, GhosttyExe.zig:46). Verify it declares `PerMonitorV2` dpiAwareness, UTF-8 active code page (`<activeCodePage>UTF-8</activeCodePage>`, helps `setlocale`/CRT calls from libc deps), long paths. [MINOR]

### 7.2 libxev (vendored via build.zig.zon `libxev` 819ffa18..., fetched into zig-pkg/)
- IOCP backend `src/backend/iocp.zig` (2421 lines) is selected on Windows (main.zig:124). Supported: Loop, Completion, Timer, Async (used extensively: mailbox wakeups across renderer/termio/search threads), **Process**
  (`watcher/process.zig` `ProcessIocp`: DuplicateHandle + Job object + `JOBOBJECT_ASSOCIATE_COMPLETION_PORT` -> exit notification with exit code), **Stream/File read+write** (iocp requires handles opened `FILE_FLAG_OVERLAPPED`).
- NOT supported on IOCP: `stream.Poll` (watcher/stream.zig:225 returns empty struct; `PollEvent` invalid) - core does not use poll on the termio path. [OK]
- `xev.Process` creates its own job and assigns the child to it: as a side effect the child IS in a job object. If we add our own KILL_ON_JOB_CLOSE job (1.2) we must assign the process to ours first
  (Windows 8+ supports nested jobs) or reuse theirs. [MINOR]
- Used in core by: termio/Thread.zig (loop, timers, async), termio/Exec.zig (Process, Stream, Timer), renderer/Thread.zig (apprt-independent), terminal/search/Thread.zig, os/cf_release_thread (mac). All platform-neutral APIs. [OK]

### 7.3 `std.posix` / POSIX-only code remaining in core (all outside Windows paths unless noted)
- terminal/page.zig:30-70: Windows `VirtualAlloc` allocator already; terminal/mem.zig (`madvise` for page discard): only Linux/Darwin branches, other OS falls through to memset path - verify Windows branch compiles (mem.zig:95-210). [MINOR]
- terminal/kitty/graphics_image.zig: shared-memory transmission (`t=s`) uses `shm_open/mmap` (:229-277) and is explicitly disabled on Windows (:205-208 `windows is currently unsupported, does it support shm?`). Windows could support `t=s` via `OpenFileMappingW/MapViewOfFile` (kitty spec names). [MINOR]
  File-based (`t=f/t=t`) has Windows path validation (terminal/kitty/windows.zig). Temp-file medium requires `tty-graphics-protocol` in name and `/dev/shm` special cases (:482-509) irrelevant on Windows.
- lib/compat/fd.zig (pipe2, fcntl): POSIX; only reached from `os/pipe.zig` non-Windows arm. [OK]
- cli/edit_config.zig:140 execve (see 3.2). main_c.zig `posix.system.exit` (C API; irrelevant).
- global.zig initSignals SIGPIPE ignore: guarded. `Surface.zig` has no signals.
- src/Command.zig POSIX arms `startPosix`, `getEnvMap`... guarded by `switch (builtin.os.tag)`.
- `std.fs.path.sep`/`/` literal assumptions: Exec.zig:~655 `"{s}/terminfo"`, shell_integration.zig:371 `"{s}/shell-integration/bash/ghostty.bash"`, resourcesdir `maybeDir` `"{s}/{s}/{s}"`, theme lookups `std.fs.path.join`. Win32 accepts `/`, but
  strings exported to MSYS shells and logged paths look mixed; centralise a `normalizeForShell` helper. [MINOR]

### 7.4 terminfo and resources install (src/build/GhosttyResources.zig)
- Windows: only `share/terminfo/ghostty.terminfo` (source) is emitted (`emit_terminfo` default true for Windows, Config.zig:531-538); `infotocap`/`tic` skipped (:57) (as there is no ncurses). See 1.4 for TERM implications.
- [MAJOR] **Build requires POSIX `tail`**: GhosttyResources.zig:353 `b.addSystemCommand(&.{ "tail", "-n", "+2" })` for the cmake-template processing is executed for ALL targets including the Linux-only desktop/DBus/systemd/metainfo templates
  (templates list at :280-325 is unconditional on OS). On a plain Windows host without Git's `usr\bin` on PATH the install step fails. Fix: skip these templates (Linux-only files) when `target.os.tag != .linux/freebsd`, or strip the header line in Zig (e.g. in `ghostty-build-data`).
- `pandoc` (docs, optional: Config.zig:524 detection), `msgfmt`/`xgettext` (i18n off by default on Windows), `git` (GhosttyDist, version string from `GitVersion.zig`; falls back if git missing? check), `tar` (distcheck), `cmake` (dist test) - POSIX-ish/optional.
- `-Demit-themes` default false (Config.zig:551) -> theme list empty at runtime unless enabled; iterm2_themes is a lazy dependency (download at build). Recommend enabling in the Windows release recipe.
- `-Dfont-backend` default `.freetype_windows` (build/Config.zig:196-200); renderer default `.opengl` (Config.zig:27,208) -> must be overridden to the D3D11 backend by the renderer worker (backend enum in src/renderer/backend.zig).
- MSVC ABI default for Windows targets (build/Config.zig:110-117), ubsan disabled for C/C++ on Windows (SharedDeps.zig:970-975), CombineArchivesStep Windows handling (:42). Dist list includes `dist/windows` (GhosttyDist.zig:191).
  Missing: installer/portable-zip packaging step, `ghostty.exe` version resource fields from `build_config.version` (ghostty.rc is static) [MINOR].

### 7.5 Crash reporting
- Sentry is hard-disabled on Windows: `crash/sentry.zig:66-70` ("Not supported on Windows currently, doesn't build"), `deinit` :215. `crash/dir.zig` still resolves `xdg.state/ghostty/crash` (LOCALAPPDATA-based).
  `pkg/sentry` uses sentry-native; pkg/breakpad vendored (Linux/mac). [MINOR] Proposal: first-class minimal handler: `SetUnhandledExceptionFilter` + `MiniDumpWriteDump` into `%LOCALAPPDATA%\ghostty\crash\*.dmp` and
  a Zig panic hook writing the message + stack to the log file; revisit sentry-native Windows build later (needs `dbghelp`, `winhttp` transport stubs).

### 7.6 Misc
- WSL: `command = wsl.exe ~` works through ConPTY; shell integration for WSL bash needs path translation (OSC 7 `/mnt/c/...`, `wslpath`); `\\wsl$` cwd. [MINOR]
- Environment variable `GHOSTTY_RESOURCES_DIR` is passed to the child; MSYS shells see the raw Windows path (see 6).

---------------------------------------------------------------------------------------------------------------------------

## 8. Prioritised punch list (suggested order of work)

BLOCKERS (nothing ships without these)
1. Exec.zig:2003/2007 `dupeSentinel`/`append` arity bug (compile error on Windows).
2. Exec.zig HANDLE vs `posix.system.close/write/fd_t` for the quit pipe (compile or runtime) + read-thread shutdown race (hang on close) - switch to Event-based wake-up (named overlapped out pipe + WaitForMultipleObjects).
3. Default shell resolution Git Bash -> pwsh -> cmd with `.direct` argv, `--login -i`, `CHERE_INVOKING=1` (hook: Config.zig:4843 `.windows` arm + new resolver; Exec.zig:~765 and 1977-2010 whitespace splitting).
4. `main_ghostty.zig` `app_runtime == .none` branch (`std.io.getStdOut` gone) and console attach/log sink for GUI subsystem (coordinate with apprt worker for `.win32` runtime).
5. Config path = `%USERPROFILE%\.config\ghostty\config.ghostty` only (xdg.zig, homedir.zig `USERPROFILE`, drop legacy on Windows in Config.zig:4247, file_load.zig:36, edit.zig:133).
6. `TERM` handling: default `xterm-256color` on Windows until a compiled terminfo is shipped (or generate binary terminfo in build_data).

MAJOR
7. Shell detection of `.exe` names (+ add `pwsh` integration script and enum value); forward-slash env paths for MSYS shells; OSC 7 path translation (`/c/...`, `/C:/...` -> `C:\...`) in stream_handler.zig:1589; case-insensitive hostname compare.
8. Job object for child tree kill; ClosePseudoConsole + drain on child exit; PSEUDOCONSOLE flags (INHERIT_CURSOR, passthrough/win32-input-mode decisions).
9. Font discovery: style/bold/italic/monospace filtering + index cache (then DirectWrite for discovery + MapCharacters fallback; keep FreeType+HarfBuzz).
10. `~` expansion on Windows (`expandHome`), `+edit-config` Windows implementation (notepad / ShellExecute), Windows-aware `path.expand` (PATHEXT) and editor escaping.
11. Build: remove `tail` dependency for non-Linux (GhosttyResources.zig:353), enable themes in the Windows recipe, wire font/renderer/apprt options.
12. Input: AltGr consumed_mods, dead keys/composing, Pause/NumLock scancode disambiguation, win32-input-mode decision for native console TUIs (apprt + small core parts).
13. Windows read loop buffer size (1 KiB) / throughput.

MINOR
14. Crash handler (minidump), kitty shm on Windows, kernel/OS version info, i18n, single-instance IPC, mouse click interval, `Pty.getProcessInfo`, WSL cwd mapping, manifest/version resources.
