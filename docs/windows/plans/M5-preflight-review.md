# M5 pre-flight review

Plan: `docs/windows/plans/M5-windows-extras.md` (20 tasks, W1–W7 + G1–G3). This is a read-only review against
DECISIONS, SPEC §8.5/§10/§11/§12/§13/§17/§18, recon `tmux.md` §2/§5, the lead's ledger
(`.superpowers/sdd/M5-windows-extras/progress.md`), and the code at `9f0d79d8e`. No builds or GUI runs were done.

Code read: `actions.zig`, `messages.zig`, `hooks.zig`, `App.zig` (window list, quit rule, `performIpc`),
`Window.zig` (close handlers), `Surface.zig` (`close`), `Overrides.zig`, `ipc/ops.zig`, `notify.zig`, `badges.zig`,
`overlay.zig`, `clipboard.zig`, `CommandPalette.zig`, `strip_input.zig`, `tray.zig`, `src/Surface.zig` (close and
undo paths), `src/App.zig`, `src/config/Config.zig` (`term`, `undo-timeout`, `auto-update`, keybinds),
`src/termio/Exec.zig` (`TERM`, read loop), `src/termio/shell_integration.zig`, `pwsh/ghostty.ps1`, `bash/ghostty.bash`,
`src/build/GhosttyResources.zig`, `src/build/Config.zig` (version), `src/cli/{new_tab,edit_config,crash_report}.zig`,
`src/crash/dir.zig`, `src/os/{windows,windows_shell,desktop}.zig`, `src/main.zig`, `src/main_ghostty.zig`,
`src/tmux_shim/{run,main,pipe}.zig`, Zig 0.17 `lib/std/debug.zig`, `test/windows/e2e.ps1`, `e2e/_common.ps1`.

Totals: **3 CRITICAL, 12 IMPORTANT, 22 MINOR.**

## CRITICAL

**1. No dump is ever written in Debug or ReleaseSafe: Zig's vectored handler runs before the filter (Task 12, G1).**
Zig 0.17's `std.debug.attachSegfaultHandler` installs a vectored exception handler (`RtlAddVectoredExceptionHandler`,
`debug.zig:1575`) whenever `std.options.enable_segfault_handler` is set. It defaults to `runtime_safety`, so it is on in
Debug. `start.zig` calls it before `main`. For an access violation, an illegal instruction or a stack overflow, that
handler prints a trace and aborts (`handleSegfaultWindows` → `defaultHandleSegfault`, `debug.zig:1655`). Vectored handlers
run before any `SetUnhandledExceptionFilter` filter, so the R-M5-10 filter never sees the exception.
- G1 runs `crash-dump.ps1` on a Debug build, so both cases fail.
- In a stack overflow, Zig's handler also walks and prints a stack trace on the exhausted stack. That is the double fault
  that Review Focus 5 wants to avoid.

Fix:
- Task 12 adds `.enable_segfault_handler = builtin.os.tag != .windows` to `std_options` in `src/main_ghostty.zig`. The file
  is already Task 12's touch point; note it in the touch-point row.
- The filter writes one log line (code and address) through `windows_log` with `tryLock`, after the dump. This replaces
  the trace Debug loses.
- Do not use the `root.debug.handleSegfault` override instead: it receives no `EXCEPTION_POINTERS`, so the dump would
  have no exception record.
- New unit test `"windows crash: segfault handler is off on windows"`: a comptime check of `std.options`.

**2. The update check cannot announce any fork release as specified (R-M5-9, Tasks 10/11, M6).**
- SPEC §13 has the release workflow upload the zip and installer "as a GitHub **pre-release**". `/releases/latest` never
  returns a pre-release, and R-M5-9 ignores pre-releases anyway. The check would always answer 404 → "could not check",
  or announce nothing.
- `build_config.version` is upstream's (`build.zig.zon` `1.3.2-dev`). `src/build/Config.zig:330` panics unless a tagged
  build's tag is exactly `v<build.zig.zon version>`. So the fork cannot cut `v1.0.0` (the DECISIONS "v1.0 gate") or a
  second Windows release on the same upstream base. If it uses `-Dversion-string`, nothing defines the scheme that
  `isNewer` compares.
- "M6 must keep release tags semver" is not enough. Release 1 of the fork is the first thing this feature must see.

Fix: lead/owner ruling now, recorded as R-M5-9a, before Task 10 starts:
- (a) The version scheme. Recommended: M6 builds with `-Dversion-string=<fork semver>` from the tag (e.g. `1.0.0`, then
  `1.0.1`), and `isNewer` compares against that value. Upstream's version moves to `+upstream.1.3.2` build metadata,
  which `isNewer` ignores.
- (b) Releases are published as full releases, or the checker reads `/releases?per_page=5` and takes the newest
  non-draft entry whose `prerelease` flag matches the build. Recommended: full releases. SPEC §13 then changes
  "pre-release" to "release (pre-release only for `-rc` tags)".
- Task 10 testdata uses the chosen tag shape. `bad-tag.json` gets a tag in upstream's form.

**3. Test-mode runs can reach `api.github.com`, and the "no non-loopback connection" oracle cannot see it (R-M5-9, Task 11, exit checklist 5).**
- "Debug builds never check automatically" is the only gate. Task 19 runs `E2E -Milestone M5` and `-Milestone all` on
  ReleaseFast with a fresh sandbox `LOCALAPPDATA` (no state file, so the check is due).
  - Every scenario that keeps Ghostty up for more than 60 s does a real GET.
  - So does any scenario that opens the palette and runs "Check for Updates".
- `urlForRun(env_url, test_mode)` returns the real endpoint whenever the override is missing or rejected, even in test
  mode.
- `Get-NetTCPConnection -OwningProcess` lists live sockets only. A request that finished, or one in TIME_WAIT (owner
  pid 0), is invisible.

Fix:
- R-M5-9: in test mode (`GHOSTTY_WIN32_TEST_IPC=1`) automatic checks are off. A manual check without a valid loopback
  override does no fetch; it answers `failed: "no test update URL"`.
- `urlForRun` returns `?[]const u8` (null = no fetch). Test `"win32 update: test mode without override never fetches"`.
- The Updater logs one `update: fetching <url>` line per request. `update-check.ps1` asserts that every such line names
  `127.0.0.1`, and that the M5 batch log has no `api.github.com`. This replaces the `Get-NetTCPConnection` oracle.

## IMPORTANT

**4. Jump list: the "Profiles" custom category fails for users who turned off recent items, and the e2e writes outside the sandbox (R-M5-4, Task 4).**
- `ICustomDestinationList::AppendCategory` returns `E_ACCESSDENIED` when "Show recently opened items in Start, Jump Lists
  and File Explorer" is off (`Start_TrackDocs = 0`).
  - The owner's machine may well have it off, so the scenario's `hr: 0` is not portable.
  - The profiles also vanish for those users.
  - Items the user removed from a custom category (`BeginList`'s removed array) make `AppendCategory` fail too.
- Windows Terminal puts its profiles in **Tasks**, separated by `PKEY_AppUserModel_IsDestListSeparator`. Tasks cannot be
  removed by the user and do not depend on that setting.
- The committed list lives in the user's `Recent\CustomDestinations\<hash>.customDestinations-ms`. It is not certain the
  sandbox `APPDATA` redirects it, and a crashed scenario leaves the e2e list behind.

Fix:
- R-M5-4: the profiles are tasks after a separator (New Window, New Tab, separator, profiles). No custom category, and
  `IObjectArray` of removed items is ignored. This drops `AppendCategory` and `PKEY_Title` from Task 4's binding list.
- In test mode, the worker calls `DeleteList(e2e aumid)` **before** `BeginList`, so a leftover from a crashed run goes.
- `jumplist.ps1` asserts that `state.jumplist.hr_delete` is 0 at exit (already planned), and that `hr_begin`/`hr_commit`
  are 0.

**5. The `+new-tab` fallback cannot live in `src/cli/new_tab.zig`, and the jump list's New Tab would open in System32 (R-M5-4, Task 4).**
- `App.performIpc` (`App.zig:564`) maps `.no_server`, `.not_our_server` and `.failed` all to `error.IPCFailed`. So
  `new_tab.zig` cannot tell "no instance" apart from "refused". It may not import `win32`, and `apprt.ipc.Errors` is
  core.
- `new_tab.zig` always inserts `--working-directory=<cwd>` when none is given (`new_tab.zig:229`). The process cwd of a
  jump-list task is the link's working directory. Unset, that is Explorer's (`C:\Windows\System32`).
- `fallbackArgv` drops `--class=`, so a test fallback starts on the default class (see 6).

Fix:
- Task 1 adds the shell `jumplist.newTabFallback(alloc, class: ?[]const u8, args) bool` and calls it from
  `App.performIpc` in the `.no_server` arm for `.new_tab` only. If it returns true, `performIpc` returns true.
  `new_tab.zig` drops out of the touch-point list.
- Task 4 fills it: `CreateProcessW` of the own exe with `--class=<class>` (when given) plus the forwarded args.
  `fallbackArgv(exe, class, args)` stays pure and tested.
- The jump-list links set `IShellLinkW::SetWorkingDirectory(%USERPROFILE%)`. The New Tab task's args become
  `+new-tab --working-directory=home` (passed through verbatim, `new_tab.zig:80`).
- The test asserts both.

**6. Two scenarios start a Ghostty on the default class, which the harness forbids (Tasks 9, 4).**
`Start-E2eGhostty` throws if a Ghostty runs without `--class=` (`_common.ps1:418`), because a default-class Ghostty
claims the owner's real pipe.
- `+edit-config` spawns `ghostty.exe -e …` with no class ("with the scenario class in the env": no such env exists).
- The `+new-tab` fallback (5) has the same gap.

Neither child is registered (`Register-OwnGhostty`), so the scenarios' `finally` does not kill it.

Fix:
- `windowsEditorArgv` gains `class: ?[]const u8`. The CLI passes `config.class` (the sandbox config already sets
  `class`), producing `{exe, "--class=<c>", "-e", tokens…, path}`. Tests are updated.
- Both scenarios find the child through `Win32_Process` (`ParentProcessId` = CLI pid, command line contains the class).
  They `Register-OwnGhostty` it, assert the class, and stop it in `finally`.

**7. Undo registration points miss the most common closes, and "origin" cannot be passed where the plan puts it (R-M5-12, Task 15).**
- The tab's `×`, middle click and the tab context menu post `WM_GHOSTTY_CLOSE_TAB` directly (`strip_input.zig:598`,
  `tab_menu.zig:106`). The caption `×`/Alt+F4 reaches `Window.handleClose` through `WM_CLOSE`. None of these pass through
  `actions/{tab,window}_actions.zig`.
- Core's `close_surface` (`src/Surface.zig:5698`) and the child-exit close (`:1410`, `:2988`) both call
  `rt_surface.close(process_active)` → `WM_GHOSTTY_CLOSE_SURFACE`. The apprt cannot be handed an `origin` there.
- An `origin` parameter on `removeSurface`/`removeTab` would change the signatures that M4's `tmux/Registry.zig` calls.
  That file belongs to Task 18, which runs in the same wave (W6).

Fix:
- Register undo entries only in `Window.zig`'s request handlers: `handleCloseTab`, `handleClose` and
  `handleCloseSurface`. All three are user requests, except a surface close whose `core_surface.child_exited` is true,
  which is not undoable.
- Do this after the confirmation dialog answers yes, as macOS does (confirm, then park).
- `removeSurface`/`removeTab` keep their signatures and stay the non-undoable primitive that tmux, IPC and expiry use.
  Drop the `origin` enum and the `*_actions.zig` edits from Task 15's Files.
- `close_all_windows` and the `others`/`right` close modes push **one** grouped entry.
- Test `"win32 undo: child exit is not undoable"` (`child_exited = true` → no entry).

**8. Parked items are still reachable through core, and they miss app-wide updates (R-M5-12, Task 15).**
- **Core still knows them.** `core_app.focusedSurface()` and `findSurfaceByID` still return a parked surface.
  - `ops.newTab` with `surface_id = 0` (every `+new-tab`, including the jump list's) can add a tab to a hidden window.
  - The test `action` op can target one.
  - Example: close the last focused window while another app has focus, then use the jump list's New Tab.
- **App-wide sweeps skip them.** More than 50 sites iterate `app.windows` (`theme`, `decor`, `composition`, `recovery`,
  `overlay`, `notify`, …). A parked window then misses `config_change`, theme and colour-scheme changes, and the
  renderer's device-lost recovery. An unpark after a GPU reset shows a dead surface.
- **The child may exit while parked.** That posts `WM_GHOSTTY_CLOSE_SURFACE` to the hidden window. `handleCloseSurface`
  then searches `app.windows` and the tab for the id; a parked tab (in `parked_tabs`) is not found, and the close is
  lost.
- **Quit confirmation.** `needsConfirmQuit` counts parked surfaces whose process is still running.

Fix:
- Parking calls `core.focusCallback(false)`.
- The IPC `new-tab`/`action` lookups ignore parked surfaces (`Surface.parked()`). `ops.zig` belongs to Task 1, so Task 1
  writes the check against a stub `parked()` that returns false, and Task 15 fills it.
- `App.forEachWindow(include_parked)`, written by Task 1 and used by the config, theme and recovery paths: these walk
  parked windows too.
- A parked surface's child exit drops its undo entry and closes it for real.
- `quit` flushes parked items **before** the confirmation runs.
- Tests: `"win32 undo: parked surface is not the focused surface"`, `"win32 undo: config change reaches a parked
  window"`, `"win32 undo: child exit while parked closes it"`.

**9. Undo has no key on Windows, and parking changes what closing a tab means (R-M5-12, Config).**
- The default `undo`/`redo` bindings are Darwin-only (`Config.zig:7225`). The `cmd+shift+t` analogue `ctrl+shift+t` is
  already `new_tab` on Windows/Linux, and `ctrl+z` belongs to the shell. As planned, undo is reachable only through a
  user keybind or the palette.
- With `undo-timeout = 5s`, closing a tab no longer stops its programs for 5 s: a dev server keeps its port and files
  stay locked. That departs from the owner's Windows Terminal close semantics (DECISIONS 2026-10-26).

Fix: owner question with a recommendation:
- (a) Default `undo-timeout` on Windows = 5 s like macOS. Bind `undo` to `ctrl+shift+z` and `redo` to
  `ctrl+shift+y`, both `performable`, Windows only, in `Config.zig`; that adds a touch point to Task 15 or Task 1.
- (b) Default `undo-timeout = 0` on Windows (feature opt-in), with no keys.

Either way: CHANGELOG line, a "Undo Close" palette check in `undo-close.ps1`, and the decision recorded as R-M5-12a.

**10. Secure input: the badge-on oracle cannot work, and capture exclusion misses Ghostty's popups (R-M5-11, Task 13).**
- Badges are `overlay.Popup` windows: owned top-level `WS_POPUP`s (`overlay.zig:299`). They are not drawn by the renderer.
  `Wait-Dump` (the D3D11 frame dump of the surface) never contains the lock badge.
- `WDA_EXCLUDEFROMCAPTURE` applies per top-level HWND. `windowCreated(window: *Window)` covers only `GhosttyWindow`s.
  These still show in captures:
  - the palette, search bar, URL hover and status labels (overlay popups);
  - `GhosttyDialog`;
  - the inspector windows;
  - the tab drag ghost.
- There is no `.created` `WindowChange`, and Task 1's hooks list has no call site for `windowCreated`.

Fix:
- The badge oracle is `state.secure_input.badges[]` (popup HWND visible, rect) only.
- `secure_input.apply(hwnd)` is called from `overlay` popup creation, `dialog` window creation, the inspector and the
  drag ghost, and `perform` sweeps `EnumThreadWindows(ui thread)`.
- `state` reports the affinity of every top-level HWND of the thread. The scenario asserts all are `0x11`.
- Task 1 adds the call in `Window.create`; this adds the hot-file chain `Window.zig` 1 → 15. If the dialog and overlay
  call sites are too wide for Task 13, the sweep alone (on toggle and on `WM_GHOSTTY_*` creation) is acceptable.

**11. R-M5-8's `C:/a/b` form breaks the bash `path` feature under MSYS (Task 6).**
`ghostty.bash:83-85` runs `export PATH="$PATH:$GHOSTTY_BIN_DIR"`. MSYS bash splits `PATH` at `:`, so `C:/g/bin` becomes
the entries `C` and `/g/bin`. The `":$PATH:"` membership test never matches, so every nested shell appends the garbage
again.

The append is redundant on Windows: M4 already **prepends** the exe dir to the Windows `PATH`, which MSYS converts to
`/c/...` at startup.

Fix: R-M5-8 adds: "Under MSYS (`$OSTYPE == msys*`), the bash `path` feature is skipped (the exe dir is already on PATH),
and `"$GHOSTTY_BIN_DIR/ghostty"` keeps working with the mixed form."
- Task 6 then owns the MSYS branch of `ghostty.bash` unconditionally, not "only if Step 4 shows a gap".
- Scenario check: `echo "$PATH" | tr : '\n' | grep -cx C` → 0.

**12. Dumps contain terminal output: thread stacks are in `MiniDumpNormal` (R-M5-10, Task 12).**
R-M5-10 says "no heap, no indirect memory: terminal text must not leak". But `MiniDumpNormal` writes every thread's
stack, and each pty reader thread keeps a 64 KiB `buf` of raw pty output on its stack (`Exec.zig:1981`). The renderer
and IO threads also hold text slices on their stacks.

Fix (choose one, recommended first):
- A `MINIDUMP_CALLBACK_INFORMATION` whose `IncludeThreadCallback` clears `ThreadWriteStack` for the threads that
  registered as pty readers, keeping their context and registers. `windows_crash.registerSensitiveThread()` is called
  from `readLoopWindows`.
  - That is a core touch point in `Exec.zig`, Windows-gated.
  - Test `"windows crash: sensitive threads lose their stack"` on the callback's decision function.
- Or reword R-M5-10 and the CHANGELOG: "dumps may contain fragments of recent terminal output; they never leave the
  machine".

**13. `dbghelp.dll` loaded at crash time can deadlock the dump thread (R-M5-10, Task 12).**
`LoadLibraryExW` takes the loader lock. A crash inside `DllMain`, inside `LoadLibrary`, or under the loader lock (driver
DLL init on the render thread is a realistic case) blocks the dump thread until the 10 s wait expires, and there is no
dump. `MiniDumpWriteDump` also allocates from the process heap, so a crash under the heap lock blocks it as well (known,
bounded by the 10 s).

Fix:
- The dump thread loads `dbghelp.dll` and resolves `MiniDumpWriteDump` when it starts, at install time, off the UI
  thread.
- Task 20 measures it against the "crash handler armed ≤ +0.2 MB" row. If it is over, raise the row (the owner decides),
  since a dump that deadlocks is worse.
- `dumpbin /imports` still shows no `dbghelp.dll`.
- Document the heap-lock case as a known limit.

**14. WinHTTP: unloading after each check is unsafe, the 10 s bound is not a single timeout, and `stop` can hang quit (R-M5-9, Task 11).**
- WinHTTP keeps internal worker threads after `WinHttpCloseHandle`. `FreeLibrary` right away can unload code those
  threads still run. `WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT` exists for exactly this.
- `WinHttpSetTimeouts` sets four separate timeouts (resolve, connect, send, receive). WPAD auto-proxy discovery
  (`AUTOMATIC_PROXY`) is not covered by them, so "10 s total" is not guaranteed.
- `Updater.stop` joins the worker, so a quit during a slow check waits for it.

Fix:
- The worker sets `WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT` on the session and waits for it (≤ 2 s) before `FreeLibrary`;
  on timeout it skips `FreeLibrary` and logs.
- A wall-clock deadline: the request handle is kept in an atomic, and the UI thread's `update` timer (or `stop`) calls
  `WinHttpCloseHandle` on it after 10 s, which aborts the blocking call.
- `stop` = close the handle, then join.
- Test `"win32 update: stop aborts a hanging fetch"` with the fake server accepting and never answering (scenario case
  "server accepts, never replies → failed ≤ 11 s; quit ≤ 2 s").

**15. Task 15 is the riskiest task and also carries optional scope (Task 15, R-M5-12).**
Task 15 has to:
- park and unpark tabs, windows and splits;
- restore split-tree snapshots;
- undo creates, plus redo;
- add counting exclusions everywhere;
- do all of 7 and 8 above.

That is in one opus task, alongside M4-owned files in the same wave. Undo of *create* and `redo` add little on
Windows: closing what you just created is the same keystroke.

Fix: split into
- **15a**: close-tab and close-window park/undo/expiry and the exclusions (7, 8);
- **15b** (W7 or a later wave): close-split with the tree snapshot, plus create-undo and redo.

If the lead prefers to keep scope, keep the split anyway. 15b then waits for 15a's GUI smoke. Update the waves table
(W6: 15a, 17, 18; then 15b alone).

## MINOR

16. **pwsh/cmd marks are gated by the `title` feature** (`ghostty.ps1:9`, `setupCmd` `shell_integration.zig:463`). The
    marks must not depend on `title`. Only the OSC 2 writes stay gated. Test: `GHOSTTY_SHELL_FEATURES=cursor` still gets
    the A/B markers in `PROMPT`.
17. **pwsh mark placement.**
    - `133;B` must be appended to the string `prompt` **returns** (the host prints it after the function).
    - `133;C` must come after `AcceptLine` (the Windows Terminal pattern wraps `PSConsoleHostReadLine`), not before it
      in the Enter handler: written before it, it lands at the end of the input line.
    - No `133;D` before the first prompt, nor after an empty Enter.
    - State the native-vs-cmdlet rule as: `$?` false and `$LASTEXITCODE` non-zero and changed since the last prompt →
      that code, else `$?` → 0/1.
18. **cmd can close the previous region:** prefix `$e]133;D$e\` before `133;A` (Windows Terminal's cmd recipe). It has no
    exit code, but `jump_to_prompt` and the output-selection boundaries work. The idempotency check must look at both
    ends (prefix and the B suffix); the current check is `startsWith(prefix)` only (`:477`).
19. **`src/crash/dir.zig` needs no change.** `ReportIterator.next` already yields every file
    (`dir.zig:44`), so `"crash dir: windows lists .dmp"` passes before the change (not a failing test). Drop the touch
    point; keep an assertion in `crash-dump.ps1` that `+crash-report` lists the `.dmp`.
20. **`Probe` gains a non-defaulted fn field.** That breaks `MockProbe` and every `systemProbe()` caller
    (`windows_shell.zig:219`, `:263`). Give `wslDistros` a default (`noDistros`) so the Exec default-shell path and M1
    tests compile unchanged.
21. **The palette is sorted by title** (`CommandPalette.zig:521`, `itemLess`). "Profile entries follow config entries"
    is not how it orders. Task 3 adds `Run.profile: struct { id, window: bool }` (a profile is no binding action).
    Rename the test to `"win32 palette: profile entries are listed and run their profile"`.
22. **Menu by keyboard in `profiles-menu.ps1`.**
    - Without `&` accelerators, typing a unique first letter **executes** the item, and the Enter after it goes into the
      new cmd tab.
    - Use `&` accelerators in the labels (`&Command Prompt`) and send only the letter.
    - Call `SetForegroundWindow(window)` before `TrackPopupMenuEx`, and post `WM_NULL` after it (documented pattern),
      otherwise the menu does not take keys or dismiss.
23. **Task 1's file list lacks `Window.zig`** for the `secure_input.windowCreated` call (item 10). Add the hot-file chain
    `Window.zig` 1 → 15.
24. **Task 17 also needs `src/tmux_shim/win.zig`.** The SID (`GetTokenInformation`/`ConvertSidToStringSidW`), the session
    id (`ProcessIdToSessionId`) and the elevation check are new externs there. Keep the `tmux.exe` ≤ 5 MB / ≤ 100 ms rows
    in Task 20's re-measure.
25. **`-L` with `TMUX` set.** M4 answers `no server running on <name>` (`run.zig:72`, test `"tmux shim run: -L without -S
    is not a server"`). Real tmux lets `-L` select the socket even inside. Task 17's "TMUX set ignores -L" deviates from
    both. Choose tmux's rule (`-L` → external pipe and namespace, even with `TMUX` set) and say in Task 17 that the M4
    test changes.
26. **Task 18 shows the namespace window without activation, but `Window.zig` is Task 15's in the same wave.** Use
    `ShowWindow(hwnd, SW_SHOWNOACTIVATE)` from the host in `Registry.zig`, or have Task 1 add `Window.showNoActivate()`.
27. **The fake release server must not block the scenario thread.** Windows PowerShell 5.1 has no `Start-ThreadJob`.
    `_m5_fakeserver.ps1` runs the `TcpListener` loop in a runspace (`[powershell]::Create().BeginInvoke()`) and disposes
    it in `finally`.
28. **`RegLoadAppKeyW` creates `<hive>.LOG1`/`.LOG2`** and keeps the file locked until the last `RegCloseKey`. The unit test
    closes, then deletes all three. `explorer-cli.ps1` checks that the sandbox holds no `*.hive*` at the end.
29. **WSL profile cwd.** `wsl.exe -d <name>` started with Ghostty's home cwd lands in `/mnt/c/Users/<x>`; Windows
    Terminal's profiles use `--cd ~`. Recommend `{wsl.exe, "-d", name, "--cd", "~"}`, and add it to the order-and-ids test.
30. **`TERM` reaching WSL and ssh.**
    - `wsl` typed in a Git Bash or pwsh tab inherits `TERM=xterm-ghostty`, and whether WSL interop copies `TERM` into the
      distro is unverified (R-M5-7 only matches the profile's argv0). Add an owner checklist line
      (`wsl -e sh -c 'echo $TERM; tput colors'` from Git Bash).
    - The ssh gap applies to pwsh users with Windows OpenSSH, where no `ssh-env` wrapper exists. Add it to the CHANGELOG
      gap list.
    - Make `windowsTerm`'s WSL check by basename (`wsl`/`wsl.exe`, any dir) as well, since `command = wsl` is common.
31. **`+edit-config` with a GUI editor** (`EDITOR=code --wait`, Notepad++) opens an empty Ghostty terminal around it.
    Cheap guard: read the PE subsystem of the resolved exe. For `IMAGE_SUBSYSTEM_WINDOWS_GUI`, spawn it directly. Add a
    test in `windowsEditorArgv`.
32. **The jump-list worker must not read `app.profiles`.** The UI thread builds `[]Item` into a heap block and hands
    ownership to the worker. `stop` waits ≤ 2 s for the worker and otherwise leaks it with a log line: a COM call stuck
    in Explorer must not hang quit.
33. **Undo with `quit-after-last-window-closed = true`.** Parking the last window triggers `lastWindowCheck` → quit, and
    the undo is lost. Say so in R-M5-12, or let `lastWindowCheck` count parked windows until they expire. Recommended:
    say so; the Windows default is `false`.
34. **OSK.**
    - `CoCreateInstance(CLSID_UIHostNoLaunch)` fails with `REGDB_E_CLASSNOTREG` when `TabTip.exe` is not running.
      Fall back to `ShellExecuteW` of `%CommonProgramFiles%\microsoft shared\ink\TabTip.exe`, then retry once.
    - Add `"win32 osk: class not registered launches TabTip"` to the decision test.
35. **The exception filter can be replaced** by a driver or overlay DLL that calls `SetUnhandledExceptionFilter` later.
    Re-check at `appStarted`: if the current filter is not ours, re-install it and log once.
36. **M6 note for jump lists.** The installer's Start-menu shortcut must carry `PKEY_AppUserModel_ID = notify.aumid`,
    otherwise the jump list shows only on a pin made from a running window. Add it to the M6 hand-over in Task 20
    (SPEC §13).
37. **Task 1 is very wide for a light review.** It writes 14 shells, 5 routes, the Overrides call sites, the crash op, 2
    config keys, the `newTabFallback` shell (5), the `forEachWindow` and `parked()` stubs (8) and the e2e milestone.
    Keep it, but run Task 1's review as opus, or move the Overrides/`ops.zig`/`App.zig` profile wiring into Task 2,
    which already owns `Overrides.zig`. The chains `ops.zig` 1 → 2 and `App.zig` 1 → 2 then become sequential.

## Cross-task table

One row per pair of tasks that share a file or an interface, then one self-consistency row per task. "OK" means the
contract is consistent as written.

| Pair | Shared file or interface | Verdict |
|---|---|---|
| 1 ↔ 2 | `Overrides.{profile, ProfileResolver, resolve}`; call sites in `ops.zig`/`App.zig`; `profiles.resolver` | OK. Explorer path normalisation (`C:\.` → `C:\`) is Task 2's (in `parse` or `apply`); say which. Optionally move the wiring to 2 (37). |
| 1 ↔ 3 | `profiles_menu.{showForStrip, appendTrayItems, trayCommand}` | OK. The palette needs a `Run` variant (21). |
| 1 ↔ 4 | `jumplist.{schedule, configChanged, stop, testState}`; timer `jumplist_delay` | Missing `newTabFallback` shell in `App.performIpc` (5). |
| 1 ↔ 8 | `Config.zig` (keys, then `default_term`) | OK (W1 → W2). |
| 1 ↔ 10, 11 | `Updater.{State, start, stop, checkNow, onResult, onTimer}`; `WM_GHOSTTY_UPDATE_RESULT = WM_APP + 16` (free: `messages.zig:47`); timer 5; `update_click_id` | OK. Test-mode gate (3). `stop` semantics (14). |
| 1 ↔ 12 | `ops.crash_hook`, test op `crash` | OK (test-mode only via `isTest`). |
| 1 ↔ 13 | `secure_input.{perform, appStarted, windowCreated, copying}` | The `windowCreated` call site needs `Window.zig` (10, 23). |
| 1 ↔ 14, 15 | `undo_actions.{State, Entry, undo, redo, flushAll, onTimer}`; `App.parked_windows`; timer 6 | Needs `App.forEachWindow` and `Surface.parked()` stubs (8). `Entry` lacks a group/count for multi-close (7). |
| 1 ↔ 16 | `osk.{show, testState}` | OK. |
| 1 ↔ 18 | `namespaces` shell | OK. |
| 2 ↔ 3 | `profiles.get/refresh`, `Profile.name` | OK. |
| 2 ↔ 4 | `Profile.{id, argv, icon}`; id charset (no quoting) | OK. Links need a working dir (5). |
| 2 ↔ 5 | `--working-directory=%V\.` → Overrides | OK. Task 2's test covers the drive-root and Cyrillic shapes. |
| 2 ↔ 8 | WSL detection: Profile `kind = wsl` vs `windowsTerm` argv0 | Match by basename too (30). |
| 4 ↔ 11 | `notify.aumid` (read by 4, `notify.zig` edited by 11, same wave W4) | OK: a `pub const`, and 4 does not edit `notify.zig`. |
| 5 ↔ 12 | `src/os/main.zig` | OK (W1 → W3). |
| 5 ↔ notify | `--all` deletes `AppUserModelId\<aumid>` and `toast-icon.png`; `src/cli` cannot import `notify.zig` | Duplicated constants: put `aumid` and the icon file name in `src/os/windows_explorer.zig` and have `notify.zig` (Task 11, W4) import them, or add a test that compares both. |
| 6 ↔ 8 | `TERMINFO` set by Exec, rewritten by `setupBash`; `term-terminfo.ps1` asserts `C:/` | OK (same wave, checked in G1). |
| 6 ↔ bash script | `GHOSTTY_BIN_DIR` in `PATH` | Broken under MSYS (11). |
| 7 ↔ 8 | `share/terminfo/78/xterm-ghostty` layout, `-Dtic` | OK. The probe also accepts `x/`. |
| 9 ↔ harness | `--class` on spawned Ghostty | (6). |
| 10 ↔ 11 | `release.{parse, isNewer, endpoint}`, `state.{load, save, due, shouldAnnounce, modeFor}`, `Updater.Result` | OK as an API. Semantics depend on (2). |
| 12 ↔ main | `std_options`, panic hook → `dumpNow` | (1). |
| 13 ↔ overlay/dialog | affinity on popups | (10). |
| 14 ↔ 15 | `undo.Stack(Entry)`, `Kind`, `nextExpiry`, `takeExpired`, `takeAll` | OK. If create-undo/redo moves to 15b, `Kind` keeps all six values. |
| 15 ↔ 18 | `Tab.removeSurface`, `Window.removeTab`, window show/close used by `Registry` (same wave W6) | Signatures must not change (7). No-activate show (26). |
| 15 ↔ 3 | tray and palette counts iterate `app.windows` | OK: parked windows are moved out. |
| 15 ↔ 4 | parked items invisible to the jump list | OK (the jump list lists profiles, not windows). |
| 17 ↔ 18 | `Context.namespace`, `tmux-external.ps1` | OK (serialised). `-L` rule (25). |
| 17 ↔ M4 shim | `run.zig` `-L` test, `win.zig` | (24, 25). |
| 19 ↔ all | ReleaseFast M5 run | Must not reach the network (3). |
| 20 ↔ 12, 11 | RAM rows "crash handler armed", "after one update check" | Rows change with (13) and (14). |
| Task 1 | — | Width (37); missing `Window.zig`, `newTabFallback`, `forEachWindow`, `parked()` (5, 8, 10). |
| Task 2 | — | `Probe` default (20); WSL `--cd ~` (29). |
| Task 3 | — | Palette sort (21); menu keys (22). |
| Task 4 | — | Category → tasks, leftovers (4); fallback location, cwd, class (5, 6); worker data and hang (32). |
| Task 5 | — | Hive logs (28); shared constants (row 5 ↔ notify). Otherwise sound: the `\.` suffix, `ownsCommand`, `--dry-run`, test-hive env (scrubbed from children by the `GHOSTTY_WIN32_` prefix). |
| Task 6 | — | Feature gating (16); pwsh placement (17); cmd D (18); MSYS PATH (11). |
| Task 7 | — | OK. Note: a non-Windows host building a Windows target gets no compiled entry, by design. |
| Task 8 | — | WSL basename, interop note (30). |
| Task 9 | — | Class (6); GUI editors (31). |
| Task 10 | — | Version and pre-release scheme (2). |
| Task 11 | — | Test-mode gate (3); unload, deadline, stop (14); fake server (27). |
| Task 12 | — | VEH (1); stacks (12); dbghelp preload (13); filter replaced (35); `dir.zig` drop (19). |
| Task 13 | — | Oracle and popups (10). |
| Task 14 | — | OK. |
| Task 15 | — | Registration points (7); parked reachability (8); keys and default (9); split (15); last window (33). |
| Task 16 | — | TabTip fallback (34). |
| Task 17 | — | `win.zig` (24); `-L` (25). |
| Task 18 | — | Show without activation (26). |
| Task 19 | — | Network gate (3). |
| Task 20 | — | M6 AUMID shortcut note (36); RAM rows (13, 14). |

Waves: the file sets are disjoint per wave as claimed, with at most 3 writers per wave. After the fixes:
- `new_tab.zig` leaves Task 4.
- `App.zig` gains the `newTabFallback`, `forEachWindow` and `parked()` stubs in Task 1.
- `Window.zig` becomes the chain 1 → 15.
- `crash/dir.zig` leaves Task 12, and `main_ghostty.zig` (`std_options`) stays in Task 12.
- `ghostty.bash` becomes Task 6's unconditionally.
- Task 15 splits into 15a (W6) and 15b (its own wave after 15a's smoke).
