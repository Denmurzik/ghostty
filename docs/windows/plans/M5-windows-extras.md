# M5 — Windows extras (profiles, jump lists, Explorer, shell integration, terminfo, updates, crash dumps, macOS analogs, external tmux): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Windows-only features of SPEC §17 M5 work, and every feature has a unit test plus an e2e scenario or a scripted screenshot:
- shell profiles (Git Bash, PowerShell 7, Windows PowerShell, cmd, WSL distros) in a new-tab menu, the command palette, the tray and the jump list;
- "Open Ghostty here" in Explorer;
- prompt marks for pwsh and cmd, and the Git Bash (MSYS) fixes;
- compiled terminfo and `TERM=xterm-ghostty`;
- `+edit-config`;
- an update check against GitHub Releases;
- crash minidumps;
- Windows analogs of `secure_input`, `undo`/`redo` and `show_on_screen_keyboard`;
- the external tmux mode (`TMUX` unset, `-L`).

Exit (SPEC §17): every feature has a test or a scripted screenshot, and the update check is tested against a fake release JSON.

**Architecture:** Same pattern as M3: one skeleton task (Task 1) adds every new module shell, message id, timer id, action route, config key and `hooks.zig` fan-out line, plus the stubs other tasks call across files. Feature tasks then fill only their own files.
- Pure models are unit-tested headless: profile list, jump-list items, Explorer registry keys, release list and versions, undo stack, external tmux namespaces.
- Side effects go through injectable seams, so no test touches the owner's machine state: a `Probe` for files and the registry, a registry root `HKEY`, the fetch URL, the AUMID.
- Network, COM and dump writing run off the UI thread and post results back.
- New system DLLs (`winhttp.dll`, `dbghelp.dll`) load from System32 without import-table entries.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/shell32/advapi32/ole32), shell COM (`ICustomDestinationList`, `IShellLinkW`, `IPropertyStore`, `ITipInvocation`, `IFrameworkInputPane`), WinHTTP, DbgHelp `MiniDumpWriteDump`, Git for Windows `tic.exe` (build time), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §8.4 (ConPTY flags, closed by L1), §8.5 (M5 core changes), §10 (`TERM`, MSYS paths), §11 (crash dumps)
- §12.1 / §12.4 (external tmux mode), §13 (Explorer keys, AUMID, release workflow), §17 M5, §18.4 (crash dir), §18.5–6 (per-user pipe, forwarding), §18.14 (close semantics), §18.24 (R-M3-5 toasts), §18.27 (`open_url` policy), §18.33 (L1), §18.34 (M3 deferrals)
- DECISIONS "Features" (jump lists, shell profiles, Explorer, updates), "Release" (no auto-install), the 2026-10-26 Windows Terminal close semantics, the 2026-10-27 macOS-style rule and the 2026-10-28 Windows 11 dialogs.

Other inputs:
- Contract for the external tmux mode: `docs/windows/recon/tmux.md` §5.
- Ledger rulings, binding: `.superpowers/sdd/M5-windows-extras/progress.md`.
- Pre-flight: `docs/windows/plans/M5-preflight-review.md` (dispositions at the end).
- Memory rules: style follows macOS; speed over ceremony.

**Revision 2 (plan-m5, 2026-10-28):** applies the pre-flight review (3 CRITICAL, 12 IMPORTANT, 22 MINOR) and the ledger rulings:
- version and tag scheme: R-M5-9a;
- no network in test mode;
- the Zig segfault handler off on Windows plus `MiniDumpFilterMemory`;
- jump-list profiles as tasks;
- undo split into 15a/15b.

The profile wiring moves from Task 1 into Task 2. The `+new-tab` fallback moves from `src/cli/new_tab.zig` into `App.performIpc`. Undo registers in `Window.zig`'s close handlers instead of the `*_actions.zig` files.

**Already done; not re-planned:**
- OSC 7 translation, pwsh/cmd OSC 7 and Git Bash `pwd -W` (M3 Task 29.1).
- `.exe`-stripping shell detection and the pwsh injection (`shell_integration.zig` `exeName`, `setupPwsh`).
- The Git Bash first-keystroke fix (M3 26.4/26.4.1).
- Windows 11 dialogs (DECISIONS 2026-10-28).
- The M3 deferrals of §18.34 (`export_terminal_io` write off the UI thread, translucent capture guard, DPAPI for the e2e clipboard backup) belong to the lead's polish3 batch.
- §8.4 "ConPTY passthrough/INHERIT_CURSOR evaluated in M5" is closed by L1 (§18.33). The bundled `conpty.dll` remains an owner question outside M5.

**Starts** when M4 W5 has landed. Tasks 15a, 15b, 17 and 18 wait for M4 acceptance, because they touch the tab/close paths and the tmux files M4 owns. Every other task may run alongside M4's W6/W7, provided its files are disjoint from the in-flight M4 14.n fixes. Task numbers are identities, not order: the wave table is the execution order.

## Global Constraints

Carried from M1–M4 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2.
- Pure Win32 + DWM apprt. Bindings are hand-written in `pkg/win32`: append-only, W-variants, `callconv(.winapi)`. COM interfaces list ALL vtable slots, with a slot-count test against Windows SDK 10.0.26100 headers. `src/os/*` and `src/cli/*` declare their own `extern`s (they never import `win32`).
- **UI thread owns** every HWND, tab, split tree, surface and menu. Workers (update fetch, jump-list commit, dump writer) never touch them and never read App state. Data reaches a worker as a heap block whose ownership moves to the worker. Hand-off back is only by `PostMessageW` to the message window, with a heap payload freed by the receiver. Every modal dialog runs from `WM_GHOSTTY_POSTED_DIALOG`.
- **System DLLs added in M5 have no import-table entry.**
  - `winhttp.dll` (Task 11) is loaded on first use with `LoadLibraryExW(…, LOAD_LIBRARY_SEARCH_SYSTEM32)`.
  - `dbghelp.dll` (Task 12) is loaded the same way, but by the dump thread at install time: loading it at crash time can deadlock on the loader lock.
  - Task 20 checks with `dumpbin /imports` that `ghostty.exe` imports neither.
- Core edits are platform-neutral or Windows-gated, and only those in "M5 core touch points" are allowed. A cause found outside them: the implementer stops with evidence, and the lead schedules an `n.1` task.
- Zig 0.17 std idioms of the touched file (`global.io()`, `std.Io`, `GetTickCount64` for deadlines). No `std.time.Timer`/`std.Thread.sleep`.
- Visual elements follow Ghostty for macOS (`macos/Sources`), except where Windows conventions require otherwise (menus, jump lists, the touch keyboard), and the task report says so. Dialogs use the M3 Windows 11 dialog (`dialogs.zig`).
- Commits: no `Co-Authored-By` or similar trailers. Never `python -` (nor `python3 -` with a heredoc).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

**Owner safety (M2–M4 rules, extended for M5).** None of these needs a per-run approval, because none touches owner state.

- **Harness.**
  - e2e scenarios run only through `test/windows/e2e.ps1`, with the shared desktop lock, a per-scenario `class` and the sandbox env (`New-E2eSandbox`: `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA` under the sandbox).
  - Every Ghostty a scenario causes to start, directly or through a CLI action, gets `--class=<scenario class>`. Such a child is found through `Win32_Process` (`ParentProcessId` = the CLI pid, command line holds the class), registered with `Register-OwnGhostty`, and stopped in `finally`.
  - Evidence images come only from the guarded capture helpers (`Save-Evidence -Window`, `Save-WindowShot`, `Get-ScreenShot`, `Assert-CaptureRectClear`). Never a full-screen grab.
- **Registry.** No test, scenario or implementer run writes the real `HKCU`/`HKLM`.
  - Registry writers take an explicit root `HKEY`. Unit tests pass a private hive from `RegLoadAppKeyW(<tmp>\test.hive)`. They close every key, then delete the hive and its `.LOG1`/`.LOG2`.
  - The Explorer CLI is exercised only with `--dry-run` (prints, never opens a key) or with `GHOSTTY_WIN32_TEST_HIVE=<file>`. That env makes the CLI use an app hive instead of `HKCU`. Every build honours it, because it can only redirect writes away from the real registry.
  - The AUMID registration keeps the M3 rule: never in test mode (`notify.zig`).
  - Real installs are owner checks (exit checklist 8).
- **Jump list.**
  - Unit tests never call `ICustomDestinationList`.
  - The e2e commits only under the test AUMID `com.mitchellh.ghostty.windows-unofficial-e2e`, selected by `GHOSTTY_WIN32_TEST_IPC=1`.
  - The worker calls `DeleteList(e2e aumid)` **before** `BeginList` (a crashed run's leftover goes) and again at exit. The scenario checks both results through the `state` op.
- **Network.** No test reaches the internet (ledger ruling C3).
  - In test mode (`GHOSTTY_WIN32_TEST_IPC=1`) there is no automatic check at all.
  - A manual check fetches only from a valid loopback override `GHOSTTY_WIN32_UPDATE_URL=http://127.0.0.1:<port>/…`; without one it answers `failed: no test update URL` and opens no connection.
  - The endpoint is a compile-time constant.
  - Every fetch logs `update: fetching <url>`. `update-check.ps1` asserts that every such line names `127.0.0.1`, and Task 19 asserts that the batch logs contain no `api.github.com`.
  - The fake server is a PowerShell `System.Net.Sockets.TcpListener` bound to `127.0.0.1` on a free port. It runs in a runspace (`[powershell]::Create().BeginInvoke()`; Windows PowerShell 5.1 has no `Start-ThreadJob`) and is disposed in `finally`.
- **WSL.** No test starts a WSL distro: booting the VM costs gigabytes of RAM. Tests read the distro list (registry, read-only) and spawn only the cmd and pwsh profiles.
- **Crashes.**
  - The deliberate-crash IPC op exists only in test mode. Dumps land in the sandbox `LOCALAPPDATA` and are deleted by the scenario.
  - Scenarios assert that no `WerFault.exe` was started for the Ghostty pid.
- **Secure input.** `WDA_EXCLUDEFROMCAPTURE` blacks out captures, so the scenario asserts affinities and badges through the `state` op and never compares pixels while it is on.
- **Touch keyboard.** In test mode `show_on_screen_keyboard` is only recorded; it never shows the keyboard on the owner's desktop.
- **Owner files.** `+edit-config` scenarios set `EDITOR` to a sandbox fake script. The owner's `%USERPROFILE%\.config` is never opened.
- **Window behaviour.** Any task that changes window behaviour (Tasks 3, 13, 15a, 15b) gets a quick GUI smoke by the lead before landing: start, the changed action, close. This is in addition to the wave batch.

Speed rules (owner 2026-10-26/28; unchanged from M4):

- **Builds and tests use `-j6`**, through the test-lock (3 slots, each checks ≥ 2 GB free). Bash timeout 600000. Prefer a focused `-Dtest-filter`; never the full suite locally.
- **Implementers run unit tests + `LOCK ZIG build -j6` only.** A task that owns a GUI scenario writes it and makes it parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```
  The lead runs scenarios in wave batches (G1–G4). Implementer-run exceptions: Task 5's `explorer-cli.ps1` and Task 7's terminfo check, which have no window.
- **Up to 3 writers in flight.** A task starts as soon as its dependencies have landed and its files do not collide with in-flight tasks.
- **Every task: unit tests + at most one e2e scenario.**
- **Review tier** (stated per task): `light` = one batched sonnet review per batch; `opus` = per-task review for concurrency, COM lifetimes, security, process lifetime, network, or a wide cross-file task.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (lead only, after `LOCK ZIG build -j6`)
- Test name prefixes: `win32 ` (apprt), `windows ` (`src/os`, `src/cli` Windows code), `tmux shim ` (`src/tmux_shim`), and the core module's existing prefix (`windows: …` in `shell_integration.zig`, `Exec: …`).

### M5 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/config/Config.zig` | doc comments of `auto-update`, `undo-timeout`, `macos-secure-input-indication` (Windows meaning); new Windows-only keys `windows-tmux-external`, `windows-jump-list`; Windows default keybinds `ctrl+shift+z` = `undo`, `ctrl+shift+y` = `redo` (R-M5-12a) | 1 |
| `src/config/Config.zig` | `default_term` back to `xterm-ghostty` on Windows; its test | 8 |
| `src/termio/Exec.zig` | Windows-gated `TERM`/`TERMINFO` choice (R-M5-7) | 8 |
| `src/termio/shell_integration.zig` | `setupCmd` prompt marks, independent of `title`; MSYS forward-slash env in `setupBash` (Windows) | 6 |
| `src/shell-integration/pwsh/ghostty.ps1` | OSC 133, independent of `title` | 6 |
| `src/shell-integration/bash/ghostty.bash` | MSYS branch: skip the `path` feature | 6 |
| `src/build/GhosttyResources.zig`, `src/build/Config.zig` | compiled terminfo on Windows targets (`-Dtic=`) | 7 |
| `src/cli/ghostty.zig` | actions `+install-explorer-integration`, `+uninstall-explorer-integration` (Windows; elsewhere they print "only supported on Windows", exit 1) | 5 |
| `src/cli/explorer_integration.zig` | new | 5 |
| `src/cli/edit_config.zig` | Windows arm | 9 |
| `src/main.zig` | the Windows panic hook asks for a dump | 12 |
| `src/main_ghostty.zig` | `std_options.enable_segfault_handler = builtin.os.tag != .windows`; installs the exception filter; sets the two test/recheck hooks | 12 |
| `src/os/main.zig` | exports for the new `src/os` files | 5 |
| `src/os/main.zig` | export for `windows_crash.zig` | 12 |
| `src/os/windows_shell.zig` | profile detection | 2 |
| `src/os/windows_registry.zig`, `src/os/windows_explorer.zig` | new | 5 |
| `src/os/windows_crash.zig` | new | 12 |

Not touch points:
- `src/Surface.zig`, `src/apprt/action.zig`, `src/input/*`: every M5 action already exists in core, and every M5 behaviour lives in the apprt.
- `src/cli/new_tab.zig`: the fallback lives in `App.performIpc`.
- `src/crash/dir.zig`: its iterator already yields every file.

### RAM budget (owner: low RAM)

Private Bytes, ReleaseFast, measured with `test/windows/measure-ram.ps1` (`-Tag`/`-Actions`/`-Sample`). Each gated row is the median of 3 runs, against the M4 acceptance rows re-measured the same day.

| Item | Budget | Measured by |
|---|---|---|
| default config, 1 window 1 surface, 30 s after start (jump list committed, crash handler armed, no update check) | ≤ M4 row + 1.5 MB | Task 20 |
| crash handler armed alone (dump thread idle, `dbghelp.dll` loaded) | ≤ +0.5 MB; over → the owner decides (a dump that deadlocks is worse) | Task 20 |
| after one manual update check (fake server), 30 s later | ≤ pre-check + 1 MB | Task 20 (`-Sample before@… checked@…`) |
| profile menu opened once | ≤ +0.3 MB | Task 20 |
| a parked (undo) tab, then expired, 30 s idle | while parked ≤ the M2 per-tab cost; after expiry within +10 % of the pre-close value | Task 20 |
| secure input on | ≤ +0.1 MB | Task 20 |
| `tmux.exe` (after Task 17's new externs) | ≤ 5 MB peak private, ≤ 100 ms wall p95 (SPEC §14, unchanged) | Task 20 |

### Latency budget

- **Key echo** (Ghostty-owned p95, default config, ≥ 200 samples × 3 runs): within +0.5 ms of the M4 acceptance value. No M5 code runs on the `WM_KEYDOWN` → pty write path. Secure input changes window affinity and clipboard formats only.
- **Startup:** time to the first frame within +10 ms of M4 (`startup` scenario).
  - Profile detection is lazy (first menu, palette or jump-list build).
  - The jump-list commit runs on a worker 2 s after start, the first update check 60 s after start.
  - The dump thread's `dbghelp.dll` load runs on that thread, not on the UI thread.
- **Profile menu:** opens in ≤ 50 ms after right-click (Debug recorded, ReleaseFast gated): Lxss registry read plus at most 8 file probes.

## Review Focus

1. **Paths that Explorer hands to "Open Ghostty here".** `%V` can be:
   - a drive root (`C:\`), whose trailing backslash would escape the closing quote under MS-CRT rules;
   - a path with spaces, `#`, `%`, `'` or Cyrillic;
   - a long path over 260 characters;
   - a library or virtual folder (`::{GUID}`), a network share, or a mapped drive.

   Expected: a local folder opens in that folder; anything else opens home and logs one warning; nothing crashes; nothing is passed to a shell unquoted.

   Tests: Task 5 `windows explorer: command line round-trips every %V shape`; Task 2 `win32 overrides: working directory from Explorer`.
2. **`TERM=xterm-ghostty` where the entry cannot be found.**
   - WSL: the profile, `command = wsl`, and `wsl` typed inside a Git Bash or pwsh tab.
   - A portable zip whose `share` folder was moved.
   - A build without `tic.exe`.
   - ssh from inside Ghostty to a host without the entry. MSYS ssh has upstream's `ssh-terminfo`/`ssh-env` help; Windows OpenSSH from pwsh has none. Both go in the changelog.

   Expected: `xterm-256color` whenever the compiled entry is missing or the command is WSL.

   Tests: Task 8 `TERM falls back without the compiled entry`, `wsl gets xterm-256color`; `term-terminfo.ps1`; an owner checklist line for interop.
3. **Update check against a hostile or broken network.** Inputs:
   - offline, proxy, a captive portal (HTML 200), a 403 rate limit, a server that accepts and never answers, a body over 1 MiB;
   - an array with no `win-` tag, a malformed `win-` tag, drafts, older or equal `N`;
   - an `html_url` outside the fork's releases.

   Expected: no toast and no dialog except for a newer valid release; one log line; the next try at the normal interval; the UI thread never blocks; quit is never delayed more than 2 s; a release is announced at most once.

   Tests: Task 10 parser, decision and state tests; Task 11 `update-check.ps1` (newer, same, garbage, 403, silent server, no server).
4. **Undo and child processes.**
   - A closed tab is parked with its shell still running. It must not appear in tmux `list-panes`, the tray count, `goto_window`, the IPC `new-tab` target or `core_app.focusedSurface()`.
   - It must still receive config, theme and device-loss sweeps.
   - `quit` closes parked items before its confirmation runs.
   - Expiry closes with the Windows Terminal semantics (§18.14).
   - A tmux `kill-pane`, a child exit (also while parked) or an IPC close never becomes undoable.

   Tests: Task 14 model tests; Task 15a `win32 undo: …`, `undo-close.ps1`.
5. **A crash inside the crash path.**
   - Stack overflow: the filter runs on the exhausted stack, so a pre-created thread writes the dump.
   - Zig's vectored segfault handler would print and abort first; it is off on Windows.
   - Two threads crash at once: one dump, the second waits.
   - The crash happens under the loader lock: `dbghelp.dll` is already loaded.
   - A crash under the heap lock: bounded by the 10 s wait; a known limit.
   - `dbghelp.dll` is missing, or the crash dir is not writable.
   - A driver DLL replaced the filter.

   Expected: at most one dump per process, never a hang longer than 10 s, never a WER dialog, the process ends, and no terminal text in the dump.

   Tests: Task 12 `windows crash: …`, `crash-dump.ps1` (access violation and stack overflow, on Debug and ReleaseFast).

## Rulings (plan-m5, 2026-10-28; lead/owner may overturn; recorded in SPEC §18 by Task 20)

The ledger's owner answers (do not ask again):
- `auto-update` defaults to `check`.
- External tmux mode is opt-in.
- The profile menu opens on right-click of `+`, plus palette and tray entries.
- `+edit-config` opens a new Ghostty with the editor, else notepad.
- AUMID self-registration stays, with `--all` as the revert.
- WSL distros come from the Lxss registry, and terminfo is compiled by Git for Windows' `tic.exe`.

- **R-M5-1 Profiles are detected, not configured.** `windows_shell.profiles(alloc, env, probe, default_argv)` returns, in this order:

  | Profile | Id | Command | Condition |
  |---|---|---|---|
  | `Default` | `default` | the config `command` (or the §8.3 resolution) | always |
  | `Git Bash` | `git-bash` | `{bash, "--login", "-i"}` | `findGitBash` |
  | `PowerShell` | `pwsh` | `{pwsh, "-NoLogo"}` | `findPwsh` |
  | `Windows PowerShell` | `powershell` | `{%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe, "-NoLogo"}` | exists |
  | `Command Prompt` | `cmd` | `{%SystemRoot%\System32\cmd.exe}` | always |
  | `<distro>` | `wsl:<distro>` | `{%SystemRoot%\System32\wsl.exe, "-d", <distro>, "--cd", "~"}` | each distro |

  - WSL distros come from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID}\DistributionName`, read-only. The `DefaultDistribution` comes first; the rest follow in name order; names starting with `docker-desktop` are skipped.
  - Ids are stable ASCII. A distro name is kept only if it matches `[A-Za-z0-9._-]{1,64}`; others are skipped and logged.
  - The list is cached on the App, built on first use, and rebuilt when a profile menu opens, so stale entries vanish.
  - There is no config key for custom profiles (YAGNI); the user's `command` is `Default`.
- **R-M5-2 `--profile=<id>`.** A new launch/IPC argument, parsed by `Overrides`, with the same weight as `--working-directory=`.
  - It is forwardable (`Overrides.forwardable`): it names a profile and never carries a command, so M2 revision 2 holds.
  - The **receiving** process resolves the id against its own list. An unknown id → IPC code 1 with stderr `unknown profile: <id>`; in a standalone launch, one warning and the `Default` profile.
  - `--profile` together with `-e`/`--command=` → `-e` wins and a warning is logged.
  - `--working-directory=` values ending in `\.` (Explorer, R-M5-5) are normalised by `Overrides.parse` with `GetFullPathNameW`.
- **R-M5-3 Where profiles are offered.** macOS has no profiles, so these are native Windows menus, themed like `tab_menu.zig`:
  1. Right-click on the tab row's `+` opens the profile menu.
     - Items: "New Tab" items, a separator, then "New Window ▸" with the same items.
     - Labels carry `&` accelerators.
     - The menu follows the documented popup pattern: `SetForegroundWindow` before `TrackPopupMenuEx`, `WM_NULL` after it.
     - Left click on `+` is unchanged (new tab, `Default`).
  2. Command palette items `New Tab: <profile>` and `New Window: <profile>`, as a new `Run.profile` variant. They are reachable with one tab, when the tab row is hidden, and sorted with the other items by title.
  3. Tray menu: "New Window ▸ <profiles>".
  4. Jump list (R-M5-4).
- **R-M5-4 Jump list** (`ICustomDestinationList`, AUMID of `notify.aumid`).
  - **Tasks only, no custom category:** New Window, New Tab, a separator (`PKEY_AppUserModel_IsDestListSeparator`), then one task per profile except `Default`. Tasks survive "Show recently opened items" being off and cannot be removed by the user. The removed-items array of `BeginList` is ignored.
  - Arguments:
    - New Window = `ghostty.exe`;
    - New Tab = `ghostty.exe +new-tab --working-directory=home`;
    - a profile = `ghostty.exe --profile=<id>`.
  - Every link: `SetWorkingDirectory(%USERPROFILE%)`, icon = the profile's exe (Ghostty's for the first two).
  - Building and committing:
    - The UI thread builds `[]Item` into one heap block and hands it to a worker thread (STA, released after the commit). The worker never reads App state.
    - It is built 2 s after start, on profile-list change and on config reload, only in the primary instance, and only when `windows-jump-list = true` (default `true`). Turning the key off calls `DeleteList` once.
    - `stop` waits ≤ 2 s for the worker, otherwise leaks it with a log line: a COM call stuck in Explorer must not hang quit.
  - **`+new-tab` with no instance.** `App.performIpc`, in its `.no_server` arm for `.new_tab` only, calls `jumplist.newTabFallback`. That starts the own exe with `--class=<class>` (when given) and the forwarded `--working-directory=`/`--profile=` args, and `performIpc` returns true. A jump-list click from a closed Ghostty then opens a window.
  - Cost if wrong: two jump-list entries.
- **R-M5-5 Explorer keys.** `+install-explorer-integration` writes under `HKCU\Software\Classes`, for each of `Directory\shell\GhosttyOpenHere`, `Directory\Background\shell\GhosttyOpenHere` and `Drive\shell\GhosttyOpenHere`:
  - `(default)` = `Open Ghostty here`;
  - `Icon` = `"<exe>",0`;
  - `command\(default)` = `"<exe>" "--working-directory=%V\."`.

  The `\.` suffix keeps a drive root's backslash away from the closing quote (`C:\` becomes `C:\\.`, which `Overrides.parse` normalises).

  The CLI options:
  - `+uninstall-explorer-integration` deletes exactly these three keys, and only if `command\(default)` starts with `"` and names a file called `ghostty.exe`. A foreign key is reported and kept.
  - `--all` also deletes `HKCU\Software\Classes\AppUserModelId\<aumid>` and the toast icon file. This is the full revert for portable users. The jump list is cleared by Ghostty itself on its next start with `windows-jump-list = false` (the CLI has no COM).
  - `--dry-run` prints every key and value it would write or delete, and opens no key.

  Other points:
  - The AUMID and the toast icon name are defined once in `src/os/windows_explorer.zig`, and `notify.zig` uses them (Task 11).
  - Windows 11 shows the entry under "Show more options" (the classic menu). The top-level menu needs package identity, which is out of scope and noted in the changelog.
  - M6 hand-over (SPEC §13, Task 20): the installer writes the same keys, and its Start-menu shortcut carries `PKEY_AppUserModel_ID = <aumid>`. Without that, the jump list shows only on a pin made from a running window.
- **R-M5-6 Prompt marks** (independent of the `title` feature; only the OSC 2 writes stay gated by `title`).
  - **pwsh:**
    - The string `prompt` returns is `133;A` + the prompt text + `133;B`, because the host prints the returned string.
    - `133;C` is written after `AcceptLine` returns, by wrapping `PSConsoleHostReadLine` (the Windows Terminal pattern), not before it.
    - `133;D;<code>` is written at the start of `prompt`, never before the first prompt and never after an empty Enter.
    - `<code>`: if `$?` is false, `$LASTEXITCODE` is non-zero and has changed since the last prompt, then that code; else `0`/`1` from `$?`.
    - Without PSReadLine there is no C/D; A/B stay.
  - **cmd:** the `PROMPT` becomes `$e]133;D$e\$e]133;A$e\` + (title/OSC 7 part when `title` is on) + the user's prompt + `$e]133;B$e\`.
    - The D has no exit code: there is no `command_finished` for cmd (a documented gap), but `jump_to_prompt` and the output boundaries work.
    - The idempotency check looks at both ends.
  - **Git Bash** keeps the upstream bash marks. Task 6 proves they arrive under MSYS.
- **R-M5-7 Terminfo and `TERM`.**
  - The build compiles `ghostty.terminfo` with `tic -x` on Windows targets too. `tic` comes from `-Dtic=<path>`, else `tic` on PATH, else `%ProgramFiles%\Git\usr\bin\tic.exe` (Git for Windows ships it).
  - Output: `share/terminfo/78/{xterm-ghostty,ghostty}`, the hex layout of MSYS ncurses (`x/` too if `tic` writes it).
  - No `tic` → only the source is installed and the build prints one warning. A non-Windows host building a Windows target gets no compiled entry, by design.
  - The Windows default is `term = xterm-ghostty` (Config). Exec sets it only when the compiled entry exists; otherwise `xterm-256color` and one warning.
  - A command whose argv0 basename is `wsl`/`wsl.exe` (any directory), or whose argv0 is System32 `bash.exe`, always gets `xterm-256color`.
  - Cost if wrong: one default.
- **R-M5-8 MSYS (Git Bash).**
  - When bash integration applies on Windows, `setupBash` rewrites `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR` and `TERMINFO` from `C:\a\b` to `C:/a/b` (mixed form). `/c/a/b` is not used.
  - Under MSYS (`$OSTYPE == msys*`), the bash `path` feature is skipped. It would split `C:/…` at `:` and append garbage to `PATH`, and the exe dir is already first on PATH (M4 prepend, converted by MSYS). `"$GHOSTTY_BIN_DIR/ghostty"` keeps working with the mixed form.
- **R-M5-8b `+edit-config`.**
  - `VISUAL`, else `EDITOR`, is tokenised with the Windows rules (`windows_cmdline.zig`) and its exe resolved on PATH/PATHEXT.
  - If the resolved exe's PE subsystem is `IMAGE_SUBSYSTEM_WINDOWS_GUI` (VS Code, Notepad++), it is spawned directly with the path.
  - Otherwise a **separate** Ghostty runs it: `ghostty.exe --class=<config class> -e <tokens…> <config path>`, detached. A GUI-subsystem `ghostty.exe` cannot share the calling console with a terminal editor (§11 known limitation).
  - No editor set → `%SystemRoot%\System32\notepad.exe <path>`, detached. Upstream errors here; Windows differs and the help text says so.
  - The CLI exits 0 after spawning.
- **R-M5-9 Update check.**
  - `auto-update`: unset → `check` on Windows; `download` → `check` with one warning; `off` → never automatic.
  - **No automatic check** in Debug builds, in test mode, or when the build has no `-win.<N>` version (a local build).
  - **Endpoint** (constant): `https://api.github.com/repos/Denmurzik/ghostty/releases?per_page=20`, `Accept: application/vnd.github+json`, `User-Agent: Ghostty/<version> (Windows)`. No other header, cookie or identifier.
  - **Transport:** WinHTTP with automatic proxy, TLS only (plain `http` only for the loopback test override), body cap 1 MiB.
    - Per-phase timeouts are set with `WinHttpSetTimeouts` (10 s each).
    - A wall-clock deadline of 10 s: the request handle is kept in an atomic, and the UI thread's `update` timer closes it with `WinHttpCloseHandle` when the deadline passes. That aborts the blocking call, WPAD included.
    - `stop` closes the handle, then joins (≤ 2 s).
    - Before `FreeLibrary` the worker waits (≤ 2 s) on `WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT`; on timeout it skips `FreeLibrary` and logs.
  - **Schedule:** the first automatic check 60 s after start, then every 24 h while running, skipped while the state file says the last check was under 24 h ago. State in `%LOCALAPPDATA%\ghostty\update.json` (`{"last_check":<unix s>,"notified":<N>}`).
  - **Choice and announcement** (R-M5-9a):
    - From the array, take the non-draft releases (prereleases included) whose `tag_name` is a valid `win-<zon>-<N>`; the newest is the largest `N`.
    - A newer release gets one toast per `N`: title `Ghostty <zon>-win.<N> is available`, body `Open the release page`. The click opens `html_url`, only if it starts with `https://github.com/Denmurzik/ghostty/releases/tag/win-`.
  - **`check_for_updates`** checks now and always answers with a Windows 11 dialog:
    - "up to date";
    - "<version> available", with an "Open release page" button;
    - "local build; the newest release is <version>";
    - "could not check" (the error).
- **R-M5-9a Version and tag scheme** (ledger ruling C2; M6 must follow it).
  - `build.zig.zon` keeps upstream's version (clean upstream merges).
  - Fork releases build with `-Dversion-string=<zon>-win.<N>` (for example `1.3.2-dev-win.3`) and are tagged `win-<zon>-<N>` (for example `win-1.3.2-dev-3`). `N` is a fork-wide counter that never resets.
  - The checker reads the current `N` from `build_config.version`'s `-win.<N>` suffix and compares only `N`.
  - SPEC §13 is amended by Task 20: releases may be pre-releases, the tag scheme is as above, and `src/build/Config.zig`'s tag check must accept `win-` tags in M6.
  - Cost if wrong: re-tag before M6.
- **R-M5-10 Crash dumps** (ledger ruling C1).
  - Zig's own handler is turned off on Windows: `std_options.enable_segfault_handler = builtin.os.tag != .windows` in `src/main_ghostty.zig`. Its vectored handler would otherwise print and abort before any unhandled-exception filter runs.
  - `SetUnhandledExceptionFilter` is installed first thing in `main` on Windows (GUI and CLI paths).
  - At install, a dump thread is created (64 KiB stack). It loads `dbghelp.dll` and resolves `MiniDumpWriteDump` at once, then waits on an event. The dump path prefix `%LOCALAPPDATA%\ghostty\crash\ghostty-<pid>-` is precomputed.
  - The filter takes a one-shot gate (`InterlockedCompareExchange`); a second crashing thread waits on the done event. It stores the exception pointers and signals.
  - The thread writes `<prefix><GetTickCount64>.dmp` with `MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpFilterMemory`. `MiniDumpFilterMemory` reduces stack contents to the pointer values a stack walk needs, so the pty reader's buffer and other terminal text never reach the dump. There is no heap and no indirect memory.
  - After the dump, the filter writes one log line (code, address, path) through `windows_log` with `tryLock`. This replaces the trace Debug used to print.
  - The filter waits ≤ 10 s, then returns `EXCEPTION_EXECUTE_HANDLER` (no WER dialog).
  - At `appStarted` the filter is re-checked: if another module replaced it, it is re-installed and logged once.
  - The Zig panic path (`src/main.zig`) asks for a dump with no exception record before aborting.
  - The 10 newest dumps are kept; older ones are pruned at the next start.
  - `+crash-report` lists the `.dmp` files (unchanged code). Nothing is ever uploaded.
  - Known limit: a crash under the process heap lock times out with no dump.
- **R-M5-11 `secure_input` analog.** Windows has no API that hides keystrokes from other same-user processes, so "secure input" means:
  1. every top-level window of the UI thread gets `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`. Covered: `GhosttyWindow`s, overlay popups (palette, search, labels, badges), `GhosttyDialog`, inspector windows, the tab drag ghost. A sweep (`EnumThreadWindows`) runs on every toggle, and each creation site calls `secure_input.apply(hwnd)`;
  2. text copied while it is on carries `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0` and `CanUploadToCloudClipboard = 0`;
  3. the macOS lock badge is shown when `macos-secure-input-indication = true`: a 25 DIP `lock.shield` glyph from Segoe Fluent Icons `0xE72E`, 10 DIP from the top-right of each surface, rounded 12, 1 px grey stroke, no animated gradient.

  - It is app-wide, like macOS: `on`, `off` and `toggle` from the action. A badge click opens a Windows 11 dialog with the macOS explainer text, reworded for Windows.
  - There is no automatic secure input at password prompts, because ConPTY has no termios. This is a documented gap.
- **R-M5-12 Undo/redo** (macOS `BaseTerminalController`/`TerminalController` semantics, apprt only).
  - **Registration.** Entries are registered only in `Window.zig`'s request handlers, after any confirmation dialog has answered yes (macOS: confirm, then park):
    - `handleCloseTab` (tab `×`, middle click, tab menu, `close_tab`);
    - `handleClose` (caption `×`, Alt+F4, `close_window`);
    - `handleCloseSurface` (`close_surface`), except when `core_surface.child_exited` is true.

    `close_all_windows` and the tab-menu `others`/`right` closes push **one** grouped entry. `removeSurface`/`removeTab` keep their signatures and stay the non-undoable primitive used by tmux, IPC and expiry.
  - **Parking.** A closed tab, window or split is **parked**: HWNDs hidden, `core.focusCallback(false)` called, surfaces alive, child processes running. It expires after `undo-timeout` and then really closes with the §18.14 semantics. A parked surface's child exit drops its entry and closes it for real.
  - **Visibility.** Parked items are invisible to tmux, the tray, `goto_window`, the IPC `new-tab`/`action` lookups (`Surface.parked()`), and the last-window rule. They still get config, theme, colour-scheme and device-loss sweeps through `App.forEachWindow(include_parked = true)`. `quit` closes parked items **before** its confirmation runs.
  - **With `quit-after-last-window-closed = true`,** closing the last window quits, and that close is not undoable (the Windows default is `false`).
  - **Split into tasks.** Task 15a: close tab/window, parking, expiry, exclusions. Task 15b: close split via tree snapshot (restored only if the tab's current tree is node-for-node the tree the close produced, else the entry is dropped with a log line), undo of create (new tab, window, split), and `redo`.
- **R-M5-12a Undo default and keys** (pre-flight 9; lead/owner may overturn).
  - Windows default `undo-timeout = 5s` like macOS, with Windows-only default binds `ctrl+shift+z` = `undo` and `ctrl+shift+y` = `redo` (`performable`). `ctrl+shift+t` is already `new_tab`, and `ctrl+z` belongs to the shell.
  - Cost: for 5 s after a close, a tab's programs keep running (a dev server keeps its port), a departure from the Windows Terminal close semantics that ends at expiry.
  - Alternative: `undo-timeout = 0` on Windows, with no keys.
  - The CHANGELOG states the choice.
- **R-M5-13 `show_on_screen_keyboard`.**
  - If `IFrameworkInputPane::Location` reports an empty rect, call `ITipInvocation::Toggle(GetDesktopWindow())`; never hide it.
  - If `CoCreateInstance(CLSID_UIHostNoLaunch)` fails with `REGDB_E_CLASSNOTREG` (TabTip not running), `ShellExecuteW` `%CommonProgramFiles%\microsoft shared\ink\TabTip.exe`, then retry once.
  - In test mode, only record.
- **R-M5-14 External tmux mode is opt-in.** `windows-tmux-external = false` by default (it relaxes M2 revision 2: a same-user process may then ask Ghostty to run a command).
  - When `true`, the primary instance claims a third pipe, `\\.\pipe\ghostty-tmux-<user SID>-<session>-<class>[-admin]`, with the M2 per-user pipe's security. It serves only `op: "tmux"` with a non-null `namespace`.
  - `tmux.exe` with `-L <name>` (tmux's rule: even when `TMUX` is set) or with `TMUX` unset connects there; namespace = `<name>`, or `default` without `-L`. This changes M4's `"tmux shim run: -L without -S is not a server"` test.
  - No server → `no server running on <path>`, exit 1. Ghostty is not auto-launched.
  - Each namespace maps to one Ghostty window created by `new-session -d`. `Registry.zig` shows it with `ShowWindow(hwnd, SW_SHOWNOACTIVATE)`. Its tabs are the tmux windows, named by `-n`.
  - Commands added in external mode: `has-session`, `new-session`, `new-window`, `kill-session`, `kill-server` (closes the namespace's windows without confirmation, not undoable), plus `list-windows -F '#{window_name}'` and the `session:window-name` target form of recon §5.
  - Inside mode is unchanged.
  - `tmux.exe` is still only on PATH inside Ghostty sessions; external use needs the user to add the Ghostty dir to PATH (documented).

## Waves (parallelism)

≤ 3 tasks per wave. File sets inside a wave are strictly disjoint (checked against every `Files:` list and the hot-file chains below).

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 skeleton · 5 Explorer integration (`src/os`, CLI) · 7 compiled terminfo in the build | M4 W5 |
| W2 | 2 profile model, `--profile`, its wiring · 6 shell integration (pwsh/cmd marks, MSYS) · 8 `TERM=xterm-ghostty` | 1 (2); — (6); 1+7 (8) |
| W3 | 3 profile UI (`+` menu, palette, tray) · 10 update core (pure) · 12 crash dumps | 1+2 (3); 1 (10); 1+5 (12) |
| G1 | **Lead batch:** `E2E -Only profiles-menu,prompt-marks,term-terminfo,crash-dump,explorer-cli` (Debug), GUI smoke for Task 3 | 3, 5, 6, 8, 12 |
| W4 | 4 jump list + `+new-tab` fallback · 11 update fetch, toast, dialog, action · 13 secure input | 1+2 (4); 5+10 (11); 1 (13) |
| W5 | 9 `+edit-config` · 14 undo model (pure) · 16 on-screen keyboard | — (9); 1 (14); 1 (16) |
| G2 | **Lead batch:** `jumplist,update-check,secure-input,edit-config,osk`; GUI smoke for Task 13 | 4, 9, 11, 13, 16 |
| W6 | 15a undo: close tab/window, parking · 17 external tmux transport · 18 external tmux commands | M4 accepted; 13+14 (15a); 1 (17, 18) |
| G3 | **Lead:** GUI smoke for 15a, `undo-close`, `tmux-external` | 15a, 17, 18 |
| W7 | 15b undo: splits, create-undo, redo (alone) | G3 |
| G4 | **Lead:** Task 19 (full M5 run Debug + ReleaseFast, `E2E -Milestone all`, GUI smoke for 15b), 19.n fixes | 15b |
| W8 | 20 RAM/latency rows, docs, SPEC, acceptance (alone) | 19.* |

Hot-file chains (every file touched by more than one task; a file not listed has a single owner):
- **Skeleton first (Task 1):**
  - Task 1 only: `src/apprt/win32.zig` (test imports), `pkg/win32/main.zig`, `src/apprt/win32/actions.zig`, `messages.zig`, `test/windows/e2e.ps1` (`ValidateSet` += `M5`).
  - Chains:
    - `App.zig` 1 → 2 → 15a;
    - `ipc/ops.zig` 1 → 2;
    - `hooks.zig` 1 → 15a;
    - `Window.zig` 1 → 15a → 15b;
    - `Surface.zig` 1 → 15a.
  - Task 1 writes every shell with its final signature, and later tasks only fill them:
    - `profiles.zig` → 2; `profiles_menu.zig` → 3; `jumplist.zig` and `pkg/win32/shobjidl.zig` → 4;
    - `update/{release,state}.zig` → 10; `update/Updater.zig` and `pkg/win32/winhttp.zig` → 11;
    - `secure_input.zig` → 13; `undo.zig` → 14; `actions/undo_actions.zig` → 15a → 15b;
    - `osk.zig` and `pkg/win32/tip.zig` → 16; `tmux/namespaces.zig` → 18.
- **Config:** `src/config/Config.zig` 1 → 8.
- **`src/os`:** `src/os/main.zig` 5 → 12. `windows_shell.zig` 2 only. `windows_explorer.zig` 5 only (read by 11).
- **apprt:**
  - `Overrides.zig` 2 only; `strip_input.zig`, `CommandPalette.zig`, `tray.zig` 3 only; `notify.zig` 11 only.
  - `badges.zig`, `clipboard.zig`, `overlay.zig`, `dialog/Dialog.zig`, `inspector/Window.zig`, `drag_ghost.zig` 13 only.
  - `Tab.zig` 15a → 15b; `theme.zig`, `recovery.zig`, `actions/app_actions.zig` 15a only.
  - `tmux/Server.zig`, `ipc/protocol.zig` 17 only; `tmux/commands.zig`, `tmux/FakeHost.zig`, `tmux/Registry.zig` 18 only.
  - `src/tmux_shim/{main,run,pipe,win}.zig` 17 only; `src/tmux_shim/cli.zig` 18 only.
- **tests/docs:**
  - `test/windows/e2e/_common.ps1`: nobody (helpers live in each task's own `_m5_*.ps1` or scenario).
  - `test/windows/e2e/tmux-external.ps1` 17 → 18 (serialised inside W6: 18 appends after 17 lands).
  - `test/windows/e2e/undo-close.ps1` 15a → 15b.
  - `test/windows/README.md`, `docs/windows/{SPEC.md, feature-checklist.md, CHANGELOG.md, ram-baseline.csv, latency-baseline.csv}`: 20 (+ lead rulings).

Message and timer ids (`messages.zig`, Task 1):
- `WM_GHOSTTY_UPDATE_RESULT = WM_APP + 16` (lparam = heap `Updater.Result`, freed by the receiver).
- Toast click id `notify.update_click_id = maxInt(u32)` (no new message: it reuses `WM_GHOSTTY_NOTIFY_CLICK`).
- Message-window timers `update = 5` (schedule and the 10 s fetch deadline), `undo_expire = 6`, `jumplist_delay = 7`.
- `hooks.appMessage` chains them after `tmux_keys`.

---

### Task 1: M5 skeleton — module shells, ids, action routes, config keys, cross-file stubs

**Review:** opus (wide cross-file task, pre-flight 37).

**Files:**
- Create shells, each with a one-line `//!` naming the owner task and the final signatures below; bodies are no-op, `false` or empty:
  - `src/apprt/win32/{profiles,profiles_menu,jumplist,secure_input,undo,osk}.zig`, `src/apprt/win32/actions/undo_actions.zig`;
  - `src/apprt/win32/update/{release,state,Updater}.zig`;
  - `src/apprt/win32/tmux/namespaces.zig`;
  - `pkg/win32/{shobjidl,winhttp,tip}.zig` (empty with a `test {}`).
- Modify:
  - `src/apprt/win32.zig` (test imports), `pkg/win32/main.zig` (exports).
  - `src/apprt/win32/actions.zig`: `check_for_updates`, `show_on_screen_keyboard`, `secure_input`, `undo` and `redo` become `.implemented`. They route to `Updater.checkNow`, `osk.show`, `secure_input.perform`, `undo_actions.undo` and `undo_actions.redo`. The coverage test now expects 1 deferred action (`selection_changed`).
  - `messages.zig` (ids above).
  - `hooks.zig`:
    - `appStarted` → `jumplist.schedule`, `Updater.start`, `secure_input.appStarted`, `crash_recheck` (below);
    - `appStopping` → `undo_actions.flushAll`, `Updater.stop`, `jumplist.stop`;
    - `configChanged` → `jumplist.configChanged`, `Updater.configChanged`;
    - `appMessage` → the three timers and `WM_GHOSTTY_UPDATE_RESULT`;
    - `testState` → sections `profiles`, `jumplist`, `update`, `secure_input`, `undo`, `osk`;
    - `pub var crash_recheck: ?*const fn () void = null` (set by Task 12).
  - `App.zig`:
    - fields `profiles: profiles.Cache = .{}`, `undo: undo_actions.State = .{}`, `update: Updater.State = .{}`, `secure: secure_input.State = .{}`, `parked_windows: std.ArrayList(*Window) = .empty` (filled by 15a; `App.windows` never holds a parked window);
    - `pub fn forEachWindow(self: *App, include_parked: bool) WindowIterator` (iterates `windows`, then `parked_windows` when asked);
    - in `performIpc`, the `.no_server` arm for `.new_tab` calls `jumplist.newTabFallback(alloc, class, args)` and returns its result;
    - `deinit` closes parked windows.
  - `Window.zig`: `Window.create` calls `secure_input.apply(hwnd)`.
  - `Surface.zig`: `pub fn parked(self: *const Surface) bool` returns false (filled by 15a).
  - `ipc/ops.zig`:
    - the IPC surface lookups (`new-tab` target, the `action` op) skip `parked()` surfaces;
    - the test op `crash` with `{"kind":"av"|"stack"|"panic"}`, test mode only, calls `pub var crash_hook: ?*const fn ([]const u8) void = null`. While the hook is null it answers code 1 `crash hook not installed`; Task 12 sets it.
  - `src/config/Config.zig`:
    - keys `windows-tmux-external: bool = false` and `windows-jump-list: bool = true`, Windows only, with doc comments next to `windows-tmux-shim`;
    - Windows sentences in the docs of `auto-update`, `undo-timeout`, `macos-secure-input-indication`;
    - Windows default binds `ctrl+shift+z` → `undo`, `ctrl+shift+y` → `redo` (R-M5-12a).
  - `test/windows/e2e.ps1` (`M5`).

**Interfaces:**
- Produces (exact; later tasks fill the bodies):
  ```zig
  // profiles.zig
  pub const Cache = struct { list: ?[]const windows_shell.Profile = null, arena: std.heap.ArenaAllocator.State = .{} };
  pub fn get(app: *App) []const windows_shell.Profile;              // builds on first use
  pub fn refresh(app: *App) []const windows_shell.Profile;          // rebuilds (menu open)
  pub fn commandFor(app: *App, id: []const u8) ?configpkg.Command;  // null = unknown id
  // profiles_menu.zig
  pub fn showForStrip(window: *Window, screen_x: i32, screen_y: i32) void;
  pub fn appendTrayItems(app: *App, menu: user32.HMENU, first_id: u32) u32;   // returns next free id
  pub fn trayCommand(app: *App, id: u32) bool;
  // jumplist.zig
  pub fn schedule(app: *App) void; pub fn configChanged(app: *App, config: *const Config) void; pub fn stop(app: *App) void;
  pub fn newTabFallback(alloc: Allocator, class: ?[]const u8, args: []const [:0]const u8) bool;
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // update/Updater.zig
  pub const State = struct { worker: ?std.Thread = null, request: std.atomic.Value(usize) = .init(0), deadline_ms: u64 = 0, last: ?Result = null };   // Result: Task 11
  pub fn start(app: *App) void; pub fn stop(app: *App) void; pub fn configChanged(app: *App, config: *const Config) void;
  pub fn checkNow(app: *App, target: apprt.Target, value: void) !bool;
  pub fn onResult(app: *App, lparam: LPARAM) void; pub fn onTimer(app: *App) void;
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // secure_input.zig
  pub const State = struct { on: bool = false };
  pub fn perform(app: *App, target: apprt.Target, value: apprt.Action.SecureInput) !bool;
  pub fn appStarted(app: *App) void; pub fn apply(hwnd: HWND) void;   // no-op while off
  pub fn copying(app: *App) bool;                                   // clipboard.zig asks
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // undo.zig (pure model, Task 14)
  pub fn Stack(comptime Entry: type) type;                          // methods in Task 14
  pub const Kind = enum { close_tab, close_window, close_split, new_tab, new_window, new_split, group };
  // actions/undo_actions.zig
  pub const Entry = struct { kind: undo.Kind, expires_ms: u64, window: ?*Window = null, tab: ?*Tab = null, tree: ?Surface.Tree = null, index: usize = 0, group: []Entry = &.{} };
  pub const State = struct { stack: undo.Stack(Entry) = .{} };
  pub fn undo(app: *App, target: apprt.Target, value: void) !bool; pub fn redo(app: *App, target: apprt.Target, value: void) !bool;
  pub fn flushAll(app: *App) void; pub fn onTimer(app: *App) void;
  // osk.zig
  pub fn show(app: *App, target: apprt.Target, value: void) !bool; pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 actions: M5 actions are implemented"`: `status(.undo) == .implemented`, `status(.check_for_updates) == .implemented`, and the deferred count is 1.
  - `"windows config: undo binds on windows"`: the default keybind set maps `ctrl+shift+z` to `undo` on Windows only.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 actions"` and `"windows config"` → FAIL.
- [ ] **Step 3: Implement** the shells, routes, ids, hooks, fields, stubs, keys and the e2e milestone.
- [ ] **Step 4: Verify** that both filters pass; `"win32 messages"` and `"win32 ipc"` pass; `LOCK ZIG build -j6` passes.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M5 skeleton — module shells, ids, action routes, config keys, cross-file stubs"`

### Task 2: Profile model, `--profile` and its wiring

**Review:** opus (what another process may ask for, R-M5-2).

**Files:**
- Modify `src/os/windows_shell.zig`: `Profile`, `profiles`, the probe's Lxss reader.
- Modify (fill) `src/apprt/win32/profiles.zig`.
- Modify `src/apprt/win32/Overrides.zig`: `profile` field, `--profile=` parse, `forwardable`, `resolve`, the `\.` normalisation.
- Modify `src/apprt/win32/ipc/ops.zig`: new-window/new-tab call `resolve` after `parse`; `error.UnknownProfile` → code 1 `unknown profile: <id>`.
- Modify `src/apprt/win32/App.zig`: the launch path calls `resolve`; on error, one warning and `Default`.

**Interfaces:**
- Consumes: Task 1 `profiles.*` signatures.
- Produces:
  ```zig
  // windows_shell.zig
  pub const Profile = struct { id: []const u8, name: []const u8, kind: enum { default, git_bash, pwsh, powershell, cmd, wsl }, argv: []const [:0]const u8, icon: []const u8 };
  pub fn profiles(alloc: Allocator, env: *const std.process.Environ.Map, probe: Probe, default_argv: ?[]const [:0]const u8) ![]Profile;
  pub const WslDistro = struct { name: []const u8, default: bool };
  // Probe gains:  wslDistros: *const fn (ctx: ?*anyopaque, alloc: Allocator) []const WslDistro = noDistros,
  //   defaulted, so MockProbe and every systemProbe() caller (Exec's default-shell path, M1 tests) compile unchanged
  // Overrides.zig
  profile: ?[:0]const u8 = null,
  pub const ProfileResolver = struct { ctx: *anyopaque, commandFor: *const fn (ctx: *anyopaque, id: []const u8) ?configpkg.Command };
  pub fn resolve(self: *Overrides, arena: Allocator, r: ProfileResolver) error{ UnknownProfile, OutOfMemory }!void;
      // profile set and command null → command = the profile's (cloned into arena); command set → keep it, log "-e beats --profile"
  // profiles.zig
  pub fn resolver(app: *App) Overrides.ProfileResolver;
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows shell profiles: order and ids"`: a fake probe with Git, pwsh, two distros (`Ubuntu` default, `Debian`) and `docker-desktop` → ids `default git-bash pwsh powershell cmd wsl:Ubuntu wsl:Debian`; the `wsl:Ubuntu` argv ends with `--cd ~`.
  - `"windows shell profiles: odd distro names skipped"`: `"a b"`, `"Ü"` and a 65-char name are skipped.
  - `"windows shell profiles: no git, no pwsh"` → `default powershell cmd`.
  - `"windows shell profiles: default probe has no distros"`: `systemProbe()` with no override compiles and returns none in the mock.
  - `"win32 overrides: --profile is forwardable"`: `{"--profile=pwsh","--working-directory=C:\\x"}` → true; `{"--profile=pwsh","-e","x"}` → false.
  - `"win32 overrides: unknown profile"`: `resolve` with a resolver returning null → `error.UnknownProfile`.
  - `"win32 overrides: -e beats --profile"`.
  - `"win32 overrides: working directory from Explorer"`: `--working-directory=C:\.`, `D:\a b\.` and `C:\Users\Анна\#x\.` → `C:\`, `D:\a b`, `C:\Users\Анна\#x`.
  - `"win32 ipc: new-tab with an unknown profile"`: code 1, stderr `unknown profile: nope`.
- [ ] **Step 2: Run** `-Dtest-filter="windows shell profiles"`, `"win32 overrides"` and `"win32 ipc"` → FAIL.
- [ ] **Step 3: Implement.** The real probe reads `HKCU\…\Lxss` with `RegGetValueW` (read-only, `KEY_READ`).
- [ ] **Step 4: Verify** the filters pass; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): shell profiles (Git Bash, pwsh, Windows PowerShell, cmd, WSL) and --profile"`

### Task 3: Profile menu, palette entries, tray submenu

**Review:** light. **Lead GUI smoke before landing.**

**Files:** Modify (fill) `src/apprt/win32/profiles_menu.zig`; Modify `src/apprt/win32/strip_input.zig` (right-click on `.new_tab`), `src/apprt/win32/CommandPalette.zig` (`Run.profile` items), `src/apprt/win32/tray.zig` (submenu). Create `test/windows/e2e/profiles-menu.ps1`.

**Interfaces:**
- Consumes: `profiles.get/refresh` (Task 2), `Tab`/`Window` creation with `Overrides{ .profile = id }` + `resolve`.
- Produces:
  - palette item titles exactly `New Tab: <name>` and `New Window: <name>`, with `Run.profile: struct { id: []const u8, window: bool }`;
  - menu labels with `&` accelerators (`&Command Prompt`, `Windows &PowerShell`, …; unique per menu);
  - command ids `0x5000 + 2*i` (tab) and `0x5001 + 2*i` (window).
- [ ] **Step 1: Failing tests:**
  - `"win32 profiles menu: items, ids and unique accelerators"`: pure `buildItems(profiles)` → labels, ids, the separator before the "New Window" submenu, and no accelerator letter used twice.
  - `"win32 palette: profile entries are listed and run their profile"`: the items appear among the sorted items, and running one yields `Run.profile` with the right id and `window` flag.
  - `"win32 tray: profile submenu ids do not collide"`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 profiles menu"`, `"win32 palette"` and `"win32 tray"` → FAIL.
- [ ] **Step 3: Implement.** The menu is `CreatePopupMenu` + `SetForegroundWindow` + `TrackPopupMenuEx(TPM_RETURNCMD)` + `PostMessageW(WM_NULL)`, themed like `tab_menu.zig`. It runs from `WM_RBUTTONUP` on the strip, never inside `performAction`.
- [ ] **Step 4: Scenario** `profiles-menu.ps1` (M5):
  - opens 2 tabs, posts `WM_RBUTTONUP` to the `+` rect from `state.windows[0].strip.new_tab`, and sends only the accelerator letter of `Command Prompt` (`Send-RealKeys`, no Enter);
  - asserts a third tab whose shell is `cmd.exe` (`Get-ShellProcess`);
  - repeats with the palette entry `New Tab: Windows PowerShell` → `powershell.exe`;
  - asserts that `state.profiles` lists the expected ids, and never selects a `wsl:` item;
  - saves `profiles-menu.png` (guarded capture, menu open).
- [ ] **Step 5: Verify** the filters pass, the scenario parses, `LOCK ZIG build -j6`. **Commit** `git commit -m "feat(win32): profile menu on the + button, palette and tray entries"`

### Task 4: Jump list and the `+new-tab` fallback

**Review:** opus (COM on a worker thread, lifetimes).

**Files:**
- Modify (fill) `pkg/win32/shobjidl.zig`: `ICustomDestinationList`, `IShellLinkW`, `IObjectCollection`, `IObjectArray`, `IPropertyStore`, `PKEY_AppUserModel_IsDestListSeparator`, `CLSID_DestinationList`, `CLSID_ShellLink`, `CLSID_EnumerableObjectCollection`, all with slot-count tests. There is no `AppendCategory` caller and no `PKEY_Title`.
- Modify (fill) `src/apprt/win32/jumplist.zig`.
- Create `test/windows/e2e/jumplist.ps1`.

**Interfaces:**
- Consumes: `profiles.get`, `notify.aumid`, Task 1's `newTabFallback` call site in `App.performIpc`.
- Produces:
  ```zig
  pub const Item = struct { kind: enum { task, separator }, title: []const u8, args: []const u8, icon_path: []const u8, icon_index: i32 };
  pub fn buildItems(alloc: Allocator, exe: []const u8, profiles: []const windows_shell.Profile) ![]Item;   // pure; one heap block handed to the worker
  pub fn aumidForRun() [:0]const u16;          // notify.aumid, or the e2e AUMID in test mode
  pub fn fallbackArgv(alloc: Allocator, exe: []const u8, class: ?[]const u8, args: []const [:0]const u8) ![]const []const u8;   // pure
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 jumplist: tasks, separator, profile tasks"`: titles `New Window`, `New Tab`, separator, then the profiles without `Default`; args `""`, `"+new-tab --working-directory=home"`, `"--profile=wsl:Ubuntu"`.
  - `"win32 jumplist: args need no quoting"` (R-M5-1 charset).
  - `"win32 jumplist: fallback keeps class, cwd and profile"`: `fallbackArgv(exe, "x.e2e", {"--working-directory=home","--profile=cmd"})` → `{exe, "--class=x.e2e", "--working-directory=home", "--profile=cmd"}`; without a class, no `--class=`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 jumplist"` → FAIL.
- [ ] **Step 3: Implement** R-M5-4.
  - **Worker sequence:** `CoInitializeEx(COINIT_APARTMENTTHREADED)`; in test mode `DeleteList(e2e aumid)` first; `SetAppID`, `BeginList`, `AddUserTasks` (one `IObjectCollection` with links and the separator), `CommitList`; release everything.
  - **Results:** `hr_delete`, `hr_begin` and `hr_commit` go in atomics for `testState`.
  - **Links:** each one sets `SetWorkingDirectory(%USERPROFILE%)`.
  - **`newTabFallback`:** `CreateProcessW` of the own exe with `fallbackArgv`, detached.
- [ ] **Step 4: Scenario** `jumplist.ps1`:
  - `state.jumplist` shows `hr_begin = 0`, `hr_commit = 0` and the expected titles;
  - quit through the test `action` op; the exit log line `jumplist: deleted e2e list hr=0x0`;
  - with no instance, `ghostty.exe +new-tab --class=<scenario class>` → a window appears with that class; the scenario registers it (`Win32_Process`, `Register-OwnGhostty`) and quits it in `finally`.
- [ ] **Step 5: Verify** filters, `LOCK ZIG build -j6`, scenario parses. **Commit** `git commit -m "feat(win32): taskbar jump list (new window, new tab, profiles as tasks); +new-tab starts Ghostty when none runs"`

### Task 5: Explorer "Open Ghostty here" (`src/os` + CLI)

**Review:** opus (registry writes, quoting).

**Files:**
- Create:
  - `src/os/windows_registry.zig` (root-injectable writer and reader, `RegLoadAppKeyW` test hive helper);
  - `src/os/windows_explorer.zig` (pure key model, the shared AUMID and toast-icon constants);
  - `src/cli/explorer_integration.zig`;
  - `test/windows/e2e/explorer-cli.ps1`.
- Modify `src/os/main.zig`, `src/cli/ghostty.zig`.

**Interfaces:**
- Produces:
  ```zig
  // windows_explorer.zig — pure
  pub const aumid = if (builtin.mode == .debug) "com.mitchellh.ghostty.windows-unofficial-debug" else "com.mitchellh.ghostty.windows-unofficial";
  pub const toast_icon_name = "toast-icon.png";          // under %LOCALAPPDATA%\ghostty
  pub const Write = struct { subkey: []const u8, name: ?[]const u8, value: []const u8 };   // name null = (default)
  pub const verbs_root = "Software\\Classes";
  pub const key_names = [_][]const u8{ "Directory\\shell\\GhosttyOpenHere", "Directory\\Background\\shell\\GhosttyOpenHere", "Drive\\shell\\GhosttyOpenHere" };
  pub fn installWrites(alloc: Allocator, exe_path: []const u8) ![]Write;
  pub fn commandLine(alloc: Allocator, exe_path: []const u8) ![]u8;        // "\"<exe>\" \"--working-directory=%V\\.\""
  pub fn ownsCommand(command: []const u8) bool;                             // starts with '"', file name ghostty.exe (case-insensitive)
  // windows_registry.zig
  pub const Root = std.os.windows.HKEY;
  pub fn setString(root: Root, subkey: []const u8, name: ?[]const u8, value: []const u8) !void;
  pub fn getString(alloc: Allocator, root: Root, subkey: []const u8, name: ?[]const u8) !?[]u8;
  pub fn deleteTree(root: Root, subkey: []const u8) !void;
  pub fn openTestHive(path: []const u8) !Root;                              // RegLoadAppKeyW, KEY_ALL_ACCESS
  // explorer_integration.zig
  pub fn runInstall(alloc: Allocator) !u8; pub fn runUninstall(alloc: Allocator) !u8;   // --dry-run; --all (uninstall)
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows explorer: install writes"`: 9 writes (3 keys × default, Icon, command) with exact values for `C:\Program Files\Ghostty\ghostty.exe`.
  - `"windows explorer: command line round-trips every %V shape"`: substitute `%V` with `C:\`, `C:\a b`, `D:\x#%'y`, `C:\Users\Анна`, a 300-char path and `\\srv\share\x`. Tokenising with `windows_cmdline` must give `--working-directory=` + the input + `\.`, and the trailing quote is never swallowed.
  - `"windows explorer: ownsCommand"`: a foreign `"C:\x\code.exe" "%V"` → false.
  - `"windows explorer: aumid matches the R-M3-5 value"`.
  - `"windows registry: app hive round trip"`: `openTestHive(<tmp>\t.hive)`, install writes, `getString`, uninstall, the keys are gone; after the last `RegCloseKey`, the hive and its `.LOG1`/`.LOG2` are deleted.
- [ ] **Step 2: Run** `-Dtest-filter="windows explorer"` and `"windows registry"` → FAIL.
- [ ] **Step 3: Implement.**
  - The CLI runs with `GHOSTTY_WIN32_TEST_HIVE` → root = that hive, else `HKEY_CURRENT_USER`.
  - `--dry-run` prints `set <subkey>\<name> = <value>` / `delete <subkey>`, one line each, and opens nothing.
  - `--all` (uninstall) also prints or deletes the AUMID key and `%LOCALAPPDATA%\ghostty\toast-icon.png`, with no `win32` import and no COM.
  - On non-Windows targets both actions print `only supported on Windows` and exit 1.
  - The help text names the Windows 11 "Show more options" location.
- [ ] **Step 4: Scenario** `explorer-cli.ps1` (no window; implementer-run with `E2E -Only explorer-cli`):
  - `+install-explorer-integration --dry-run` output equals the expected 9 lines;
  - with `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\x.hive`, install then uninstall → exit 0 both;
  - `reg.exe query HKCU\Software\Classes\Directory\shell\GhosttyOpenHere` (read-only) shows the real key does not exist before and after;
  - at the end the sandbox holds no `*.hive*`.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): +install/+uninstall-explorer-integration (Open Ghostty here), sandboxed registry writer"`

### Task 6: Shell integration — pwsh/cmd prompt marks, MSYS fixes

**Review:** light.

**Files:** Modify `src/shell-integration/pwsh/ghostty.ps1`, `src/termio/shell_integration.zig` (`setupCmd`, `setupBash` Windows branch), `src/shell-integration/bash/ghostty.bash` (MSYS branch: skip `path`). Create `test/windows/e2e/prompt-marks.ps1`.

**Interfaces:**
- Produces:
  - cmd `PROMPT` = `$e]133;D$e\$e]133;A$e\` + (`$e]2;$P$e\$e]7;kitty-shell-cwd:///$P$e\` when `title` is on) + user prompt + `$e]133;B$e\`;
  - `fn msysPath(alloc, path) ![]u8` (backslash → slash, nothing else).
- [ ] **Step 1: Failing tests** (in `shell_integration.zig`):
  - `"windows: cmd prompt marks"`: the PROMPT starts with D and A and ends with B; re-applying does not double either end.
  - `"windows: cmd marks without the title feature"`: `GHOSTTY_SHELL_FEATURES=cursor` still gets D/A/B, with no OSC 2/7.
  - `"windows: bash on msys gets forward-slash paths"`: env `GHOSTTY_RESOURCES_DIR=C:\g\share\ghostty` → `C:/g/share/ghostty`, likewise `TERMINFO`/`GHOSTTY_BIN_DIR`; a non-Windows-path value is unchanged.
  - `"windows: pwsh integration script carries OSC 133"`: the script text contains `]133;A`, `]133;B`, `]133;C`, `]133;D;` and `PSConsoleHostReadLine`, and the `title` gate no longer guards the whole script (searched by markers, so reformatting stays green).
- [ ] **Step 2: Run** `-Dtest-filter="windows: "` → FAIL.
- [ ] **Step 3: Implement** R-M5-6 and R-M5-8. `ghostty.bash`: under `$OSTYPE == msys*`, the `path` feature block is skipped.
- [ ] **Step 4: Scenario** `prompt-marks.ps1`. For Git Bash, pwsh and cmd each:
  - run two commands, `echo a` and a failing one (`false` / `cmd /c exit 3` / `cmd /c exit 3`);
  - `jump_to_prompt:-1` via the test `action` op moves the viewport (the `state` viewport row changes);
  - for bash and pwsh, `state.m3.notify` records `command_finished` with exit 3 when the scenario config has `notify-on-command-finish = always`.

  Also: no `unknown OSC 133` lines in the Debug log; in Git Bash, `echo "$PATH" | tr : '\n' | grep -cx C` → `0` after a nested `bash -i`.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(shell-integration): OSC 133 prompt marks for pwsh and cmd; MSYS path fixes for bash"`

### Task 7: Compiled terminfo in the Windows build

**Review:** light.

**Files:** Modify `src/build/GhosttyResources.zig` (Windows arm: `tic -x -o`, no `infocmp`/termcap), `src/build/Config.zig` (`-Dtic=<path>` option).

- [ ] **Step 1:** Write the check first:
  ```
  "C:/Program Files/Git/usr/bin/infocmp.exe" -x -A zig-out/share/terminfo xterm-ghostty
  ```
  Expected now: FAIL (`couldn't open terminfo file`).
- [ ] **Step 2: Implement.**
  - `tic` resolution as in R-M5-7 (build-time `std.Build` lookup; Windows host only).
  - Install `share/terminfo/<hexdir or letter>/{xterm-ghostty,ghostty}` exactly as `tic` writes them.
  - Missing `tic`: one warning, source only.
  - Non-Windows targets are unchanged.
- [ ] **Step 3: Verify:**
  - `LOCK ZIG build -j6`;
  - the infocmp command prints `xterm-ghostty|ghostty|Ghostty` and the `Smulx`/`Setulc` extended caps;
  - `ls zig-out/share/terminfo` shows `78`;
  - `LOCK ZIG build -j6 -Dtic=C:/nope/tic.exe` → the build succeeds with the warning and no compiled entry.
- [ ] **Step 4: Commit** `git commit -m "build(windows): compile the xterm-ghostty terminfo with tic from Git for Windows"`

### Task 8: `TERM=xterm-ghostty` on Windows

**Review:** light.

**Files:** Modify `src/config/Config.zig` (`default_term` and its test), `src/termio/Exec.zig` (Windows-gated choice). Create `test/windows/e2e/term-terminfo.ps1`.

**Interfaces:**
- Produces: `fn windowsTerm(cfg_term: []const u8, terminfo_dir: ?[]const u8, argv0: []const u8, exists: *const fn ([]const u8) bool) struct { term: []const u8, terminfo: ?[]const u8 }` (pure, in Exec.zig, tested).
- [ ] **Step 1: Failing tests:**
  - `"windows config: TERM defaults to xterm-ghostty"` (replaces the M1 test).
  - `"Exec: windows TERM falls back without the compiled entry"`: `exists` → false → `xterm-256color`, no `TERMINFO`.
  - `"Exec: windows TERM keeps a user-set term"`: `term = foo` → `foo`.
  - `"Exec: wsl gets xterm-256color"`: argv0 `C:\Windows\System32\wsl.exe`, `wsl`, `WSL.EXE`, `D:\tools\wsl.exe` and `c:/windows/sysnative/bash.exe` → `xterm-256color`.
  - `"Exec: windows TERMINFO points at the share dir"`.
- [ ] **Step 2: Run** `-Dtest-filter="windows config: TERM"` and `"Exec: w"` → FAIL.
- [ ] **Step 3: Implement.** The existence probe is `<resources>\..\terminfo\78\xterm-ghostty` or `x\xterm-ghostty`.
- [ ] **Step 4: Scenario** `term-terminfo.ps1`:
  - Git Bash: `echo $TERM`; `tput colors` (256); `tput Smulx` non-empty (skip if `tput` is missing); `vim -u NONE -c q` exits 0 with no `E558`;
  - pwsh: `$env:TERM` = `xterm-ghostty`;
  - `TERMINFO` begins with `C:/` in bash (Task 6's rewrite).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): TERM=xterm-ghostty when the compiled terminfo ships; WSL keeps xterm-256color"`

### Task 9: `+edit-config` on Windows

**Review:** light.

**Files:** Modify `src/cli/edit_config.zig`. Create `test/windows/e2e/edit-config.ps1`.

**Interfaces:**
- Produces:
  ```zig
  fn windowsEditorArgv(alloc: Allocator, exe: []const u8, class: ?[]const u8, visual: ?[]const u8, editor: ?[]const u8,
      path: []const u8, system_root: []const u8, isGui: *const fn ([]const u8) bool) ![]const []const u8;
  // → {editor_exe, tokens[1..]…, path} for a GUI editor; {exe, "--class=<c>", "-e", tokens…, path} for a console editor
  //   (no "--class=" when class is null); {<root>\System32\notepad.exe, path} without an editor
  fn peIsGui(path: []const u8) bool;   // reads the PE optional header's Subsystem
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows edit-config: VISUAL beats EDITOR"`.
  - `"windows edit-config: quoted editor path"`: `"C:\Program Files\Vim\vim.exe" -u NONE` → tokens kept, path last, `--class=` from the config.
  - `"windows edit-config: GUI editor is spawned directly"`: `isGui` → true → no `ghostty.exe` in the argv.
  - `"windows edit-config: no editor uses notepad"`.
  - `"windows edit-config: empty EDITOR counts as unset"`.
  - `"windows edit-config: peIsGui"` on `notepad.exe` (GUI) and `cmd.exe` (console).
- [ ] **Step 2: Run** `-Dtest-filter="windows edit-config"` → FAIL.
- [ ] **Step 3: Implement.** Spawn detached (no wait, std handles closed), print the path, exit 0. The help text documents R-M5-8b.
- [ ] **Step 4: Scenario** `edit-config.ps1`:
  - `EDITOR=<sandbox>\fake-editor.cmd` (writes `%*` to a marker file); the sandbox config sets `class` and `wait-after-command = false`;
  - run `ghostty.exe +edit-config`;
  - find the child Ghostty through `Win32_Process`, assert its `--class=`, and `Register-OwnGhostty` it;
  - the marker holds the sandbox config path, and the child exits after the script; `finally` stops it if not.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): +edit-config opens VISUAL/EDITOR (console editors in a new Ghostty), notepad otherwise"`

### Task 10: Update check — pure core (release list, versions, schedule, state file)

**Review:** light.

**Files:** Modify (fill) `src/apprt/win32/update/release.zig`, `src/apprt/win32/update/state.zig`. Create `src/apprt/win32/update/testdata/{newer,same,older,draft-only,no-win-tags,bad-tag,foreign-url,html,prerelease-newer}.json`. These are arrays shaped like `/releases`, with tags in the R-M5-9a form; `bad-tag.json` carries upstream's `v1.3.2` form and a `win-x-y`.

**Interfaces:**
- Produces:
  ```zig
  // release.zig
  pub const Release = struct { n: u32, version: []const u8, tag: []const u8, html_url: []const u8 };   // version = "<zon>-win.<N>"
  pub const ParseError = error{ NotJson, NoRelease, OutOfMemory };
  pub fn newest(arena: Allocator, body: []const u8) ParseError!Release;     // non-draft, valid win- tag, url prefix ok, max N
  pub fn parseTag(tag: []const u8) ?struct { zon: []const u8, n: u32 };  // "win-<zon>-<N>"
  pub fn currentN(version: []const u8) ?u32;                               // "<zon>-win.<N>" → N; null = local build
  pub const release_prefix = "https://github.com/Denmurzik/ghostty/releases/tag/win-";
  pub const endpoint = "https://api.github.com/repos/Denmurzik/ghostty/releases?per_page=20";
  // state.zig
  pub const State = struct { last_check: i64 = 0, notified: u32 = 0 };
  pub fn load(arena: Allocator, json: []const u8) State;                          // garbage → default
  pub fn save(w: *std.Io.Writer, s: State) !void;
  pub const Mode = enum { off, check };
  pub fn modeFor(cfg: ?configpkg.Config.AutoUpdate, debug: bool, test_mode: bool, current_n: ?u32) Mode;   // R-M5-9
  pub fn due(s: State, now_s: i64) bool;                                          // ≥ 24 h
  pub fn shouldAnnounce(s: State, r: Release, current_n: u32) bool;              // r.n > current_n and r.n > s.notified
  ```
- [ ] **Step 1: Failing tests** `"win32 update: …"`, one per testdata file plus the pure functions:
  - `newer` → `n = 4`;
  - `prerelease-newer` → chosen (pre-releases count);
  - `draft-only`, `no-win-tags` → `NoRelease`;
  - `bad-tag` → the bad entries are skipped;
  - `foreign-url` → that entry is skipped;
  - `html` → `NotJson`;
  - `parseTag("win-1.3.2-dev-3")` → `{1.3.2-dev, 3}`;
  - `currentN("1.3.2-dev-win.3") = 3`, `currentN("1.3.2-dev") = null`;
  - `modeFor`:
    - `(null, false, false, 3) = check`;
    - `(.download, false, false, 3) = check`;
    - `(null, true, false, 3) = off`;
    - `(null, false, true, 3) = off`;
    - `(null, false, false, null) = off`;
  - `due` at 23 h 59 m → false;
  - `shouldAnnounce` twice for the same `N` → false the second time;
  - a garbage state file → default.
- [ ] **Step 2: Run** `-Dtest-filter="win32 update"` → FAIL.
- [ ] **Step 3: Implement** with `std.json` (`.ignore_unknown_fields`). The caller already caps the body length.
- [ ] **Step 4: Verify**, **Commit** `git commit -m "feat(win32): update check core — release list, win-N versions, schedule and state"`

### Task 11: Update check — WinHTTP fetch, toast, dialog, `check_for_updates`

**Review:** opus (network, worker thread, untrusted input).

**Files:**
- Modify (fill) `pkg/win32/winhttp.zig`: the WinHTTP subset as function-pointer types for `GetProcAddress`, including `WinHttpSetOption` and `WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT`.
- Modify (fill) `src/apprt/win32/update/Updater.zig`.
- Modify `src/apprt/win32/notify.zig`:
  - an app-level toast with `update_click_id`; a click → `Updater.openReleasePage`;
  - `aumid` and the icon name come from `windows_explorer`.
- Create `test/windows/e2e/update-check.ps1`, `test/windows/e2e/_m5_fakeserver.ps1`.

**Interfaces:**
- Consumes: Task 10 API; `dialogs.zig` (Windows 11 dialog, from `WM_GHOSTTY_POSTED_DIALOG`); `link.zig` open for the release page.
- Produces:
  ```zig
  pub const Result = struct { manual: bool, outcome: union(enum) { newer: release.Release, current, local: release.Release, failed: []const u8 } };   // heap, posted
  pub fn fetch(arena: Allocator, url: []const u8, max_body: usize, handle_out: *std.atomic.Value(usize)) ![]u8;   // worker only
  pub fn urlForRun(env_url: ?[]const u8, test_mode: bool) ?[]const u8;   // null = no fetch (test mode without a valid loopback override)
  pub fn currentNForRun(build_version: []const u8, env_n: ?[]const u8, test_mode: bool) ?u32;   // env only in test mode
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 update: test mode without override never fetches"`: `urlForRun(null, true) == null`; `urlForRun("http://example.com/", true) == null`.
  - `"win32 update: url override only in test mode and only loopback http"`:
    - `http://127.0.0.1:5000/x` is accepted in test mode;
    - `https://127.0.0.1/` and `http://127.0.0.1.evil/` → null in test mode;
    - outside test mode the override is ignored → the endpoint;
    - `currentNForRun("1.3.2-dev", "3", true) = 3`, `currentNForRun("1.3.2-dev", "3", false) = null`.
  - `"win32 update: result handling"`: a fake `Result` posted to `onResult` decides toast / dialog / nothing per manual × outcome, against the recorded-notification ring (test mode).
  - `"win32 update: deadline closes the request"`: `onTimer` with a stored fake handle and a passed deadline calls the injected close function once.
- [ ] **Step 2: Run** `-Dtest-filter="win32 update"` → FAIL.
- [ ] **Step 3: Implement** R-M5-9.
  - The worker is started per check; it logs `update: fetching <url>` before connecting.
  - WinHTTP: `LoadLibraryExW("winhttp.dll", SYSTEM32)`; `WinHttpOpen(…, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY)`; `WinHttpSetTimeouts` (10 s each); `WINHTTP_FLAG_SECURE` unless the override is http.
  - The request handle goes into `State.request`; the read loop is capped at 1 MiB.
  - Shutdown: close the handles, wait on the unload-notify event (≤ 2 s) before `FreeLibrary`, then post `WM_GHOSTTY_UPDATE_RESULT`.
  - The UI thread enforces the 10 s deadline from the `update` timer. It writes the state file through a temp file + `MoveFileExW(REPLACE_EXISTING)` and announces.
- [ ] **Step 4: Scenario** `update-check.ps1`.
  - Setup:
    - `_m5_fakeserver.ps1` serves `Start-FakeRelease -Body <file> -Status <code> [-Silent]` on `127.0.0.1:<free port>` from a runspace;
    - Ghostty runs in test mode with `GHOSTTY_WIN32_UPDATE_URL`;
    - every case runs `check_for_updates` via the test `action` op;
    - the Debug build's version has no `-win.N`, so one case without `GHOSTTY_WIN32_TEST_CURRENT_N` expects the "local build" outcome. The other cases set `GHOSTTY_WIN32_TEST_CURRENT_N=3`, which `Updater` honours only in test mode (`fn currentNForRun(build_version, env, test_mode) ?u32`, unit-tested with the `urlForRun` tests).
  - Cases:
    - `newer.json` with current 3 → `state.update.last = newer 4`, one recorded toast; a second check → no second toast; the manual dialog (`GhosttyDialog`) is dismissed with `WM_USER + 102`;
    - `same.json` → "up to date";
    - `html.json` with 200 → `failed`, no toast;
    - status 403 → `failed`;
    - `-Silent` (accepts, never replies) → `failed` within 11 s, and a quit right after a new silent check completes in ≤ 2 s;
    - server stopped → `failed`;
    - a test-mode Ghostty without the override, after 70 s → no `update: fetching` line at all.
  - Final assertion: every `update: fetching` line in the log names `127.0.0.1`.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): update check via WinHTTP (win-N releases), toast, check_for_updates dialog"`

### Task 12: Crash minidumps

**Review:** opus (crash path, threads).

**Files:** Create `src/os/windows_crash.zig`, `test/windows/e2e/crash-dump.ps1`. Modify:
- `src/os/main.zig` (export);
- `src/main_ghostty.zig`:
  - `std_options.enable_segfault_handler = builtin.os.tag != .windows`;
  - `windows_crash.install(...)` first on Windows;
  - on the win32 runtime, `ops.crash_hook = windows_crash.testCrash` and `hooks.crash_recheck = windows_crash.ensureInstalled`;
- `src/main.zig` (panic → `windows_crash.dumpNow()`).

**Interfaces:**
- Produces:
  ```zig
  pub fn install(local_app_data: []const u8) void;     // idempotent; starts the dump thread (dbghelp loaded there); failures logged, never fatal
  pub fn ensureInstalled() void;                       // re-installs if another module replaced the filter; logs once
  pub fn dumpNow() void;                               // from the panic path, no exception record
  pub fn testCrash(kind: []const u8) void;             // "av" | "stack" | "panic"; reached only through the test op
  pub fn pruneKeep(alloc: Allocator, dir: []const u8, keep: usize) !usize;
  pub fn dumpPath(buf: []u16, prefix: []const u16, tick: u64) [:0]const u16;    // pure
  pub const dump_type: u32;                            // Normal | WithThreadInfo | WithUnloadedModules | FilterMemory
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows crash: segfault handler is off on windows"`: a comptime check of `std.options.enable_segfault_handler` in the root of `main_ghostty`.
  - `"windows crash: dump type filters memory"`: `dump_type & MiniDumpFilterMemory != 0`, and no `WithFullMemory`/`WithIndirectlyReferencedMemory` bit.
  - `"windows crash: dump path"`.
  - `"windows crash: prune keeps the 10 newest"` (a tmp dir with 13 files, mtimes set).
  - `"windows crash: install twice is a no-op"`.
- [ ] **Step 2: Run** `-Dtest-filter="windows crash"` → FAIL.
- [ ] **Step 3: Implement** R-M5-10. The filter uses no allocator and no locks except the one gate. The log line goes through `windows_log` with `tryLock`.
- [ ] **Step 4: Scenario** `crash-dump.ps1`, run by the lead on **Debug and ReleaseFast**:
  - cases `av` and `stack` via the `crash` test op;
  - the process exits within 15 s;
  - exactly one new `.dmp` lands in `<sandbox LOCALAPPDATA>\ghostty\crash`, with size > 0 and < 64 MB;
  - no `WerFault.exe` was started for the pid;
  - the log has the `crash dump written to` line;
  - `ghostty.exe +crash-report` with the sandbox env lists the `.dmp`;
  - a pty marker string typed before the crash (`echo M5SECRETMARK`) does **not** occur in the dump bytes;
  - dumps are deleted at the end.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): crash minidumps (filtered memory) in %LOCALAPPDATA%\\ghostty\\crash"`

### Task 13: `secure_input` analog

**Review:** light. **Lead GUI smoke before landing.**

**Files:**
- Modify (fill) `src/apprt/win32/secure_input.zig`.
- Modify:
  - `src/apprt/win32/badges.zig`: the lock badge, macOS geometry from `SecureInputOverlay.swift`;
  - `src/apprt/win32/clipboard.zig`: the three formats when `secure_input.copying`;
  - `overlay.zig` (popup creation), `dialog/Dialog.zig` (window creation), `inspector/Window.zig`, `drag_ghost.zig`: one `secure_input.apply(hwnd)` call each.
- Create `test/windows/e2e/secure-input.ps1`.

- [ ] **Step 1: Failing tests:**
  - `"win32 secure input: toggle state machine"` (`on`, `off`, `toggle` × start state);
  - `"win32 secure input: badge geometry"` (25 DIP + 2×5 padding, 10 DIP inset at 96/144/192 dpi);
  - `"win32 clipboard: secure copy adds exclusion formats"` (format list builder, pure).
- [ ] **Step 2: Run** `-Dtest-filter="win32 secure input"` and `"win32 clipboard"` → FAIL.
- [ ] **Step 3: Implement** R-M5-11. `perform` sweeps `EnumThreadWindows(ui thread)`. A badge click opens the explainer dialog (posted). `testState` reports the affinity of every top-level HWND of the UI thread and the badge popups (visible, rect).
- [ ] **Step 4: Scenario** `secure-input.ps1`:
  - open the palette, then `toggle_secure_input` via the test `action` op → `state.secure_input.on = true` and every listed top-level HWND (window and palette popup) has affinity `0x11`;
  - `state.secure_input.badges[]` shows one visible badge per surface;
  - copy a selection → the clipboard format list includes `ExcludeClipboardContentFromMonitorProcessing` (read with a helper that lists formats, not content);
  - toggle off → every affinity is 0;
  - one guarded capture **after** turning it off (`secure-badge-off.png`). There is no pixel oracle for the badge while it is on.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): secure input analog — capture exclusion for every window, clipboard history exclusion, lock badge"`

### Task 14: Undo stack (pure model)

**Review:** light.

**Files:** Modify (fill) `src/apprt/win32/undo.zig`.

**Interfaces:**
- Produces:
  ```zig
  pub fn Stack(comptime Entry: type) type {   // Entry has `expires_ms: u64`
      return struct {
          pub fn push(self: *@This(), gpa: Allocator, e: Entry) !void;          // clears redo
          pub fn popUndo(self: *@This(), now_ms: u64) ?Entry;                   // never returns an expired entry
          pub fn pushRedo(self: *@This(), gpa: Allocator, e: Entry) !void;
          pub fn popRedo(self: *@This(), now_ms: u64) ?Entry;
          pub fn takeExpired(self: *@This(), now_ms: u64, out: *std.ArrayList(Entry), gpa: Allocator) !void;
          pub fn takeAll(self: *@This(), out: *std.ArrayList(Entry), gpa: Allocator) !void;   // quit
          pub fn removeIf(self: *@This(), ctx: anytype, pred: fn (@TypeOf(ctx), *const Entry) bool, out: *std.ArrayList(Entry), gpa: Allocator) !void;   // child exit while parked
          pub fn nextExpiry(self: *const @This()) ?u64;                         // timer scheduling
      };
  }
  ```
- [ ] **Step 1: Failing tests** `"win32 undo stack: …"`:
  - LIFO order;
  - a push clears redo;
  - an expired entry is never returned and lands in `takeExpired`;
  - `nextExpiry` is the minimum;
  - `takeAll` empties both stacks;
  - `removeIf` takes only the matching entries;
  - a timeout of 0 pushes an already expired entry (the caller closes at once).
- [ ] **Step 2–4:** Run → FAIL; implement; run → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): undo/redo stack with expiry"`

### Task 15a: Undo — park and restore closed tabs and windows

**Review:** opus (process lifetime, HWND ownership). **Lead GUI smoke before landing.**

**Files:** Modify:
- (fill) `src/apprt/win32/actions/undo_actions.zig`: tab/window entries, groups, `undo`, expiry, `flushAll`;
- `src/apprt/win32/Window.zig`:
  - registration in `handleCloseTab`, `handleClose` and `handleCloseSurface` (the last only to drop an entry on a parked child exit);
  - `park`/`unpark`;
  - `parked_tabs`;
- `src/apprt/win32/Tab.zig` (`park`/`unpark` of a tab container);
- `src/apprt/win32/Surface.zig` (`parked()`);
- `src/apprt/win32/App.zig` (`parked_windows` moves; the quit path flushes before confirming);
- `hooks.zig` (`configChanged` uses `forEachWindow(true)`);
- `theme.zig`, `recovery.zig`, `actions/app_actions.zig` (their app-wide sweeps use `forEachWindow(true)`).

Create `test/windows/e2e/undo-close.ps1`.

**Interfaces:**
- Consumes: Task 14 `Stack`; config `undo-timeout`; Task 1 stubs (`parked()`, `forEachWindow`, `parked_windows`).
- Produces:
  - `Window.parked: bool`, `Tab.parked: bool`;
  - a parked window lives in `App.parked_windows`, a parked tab in `Window.parked_tabs`. So the M4 `Registry` lookups, the tray, `goto_window` and the last-window rule, which iterate `App.windows`/`Window.tabs`, need no change;
  - `state` reports `parked` counts.
- [ ] **Step 1: Failing tests** `"win32 undo: …"` with headless windows (the M2 test-window helpers):
  - `close tab then undo restores index and title`;
  - `close window then undo restores the rect`;
  - `close-others pushes one grouped entry`;
  - `expiry closes for real` (the surface's `deinit` ran, the process-kill path called);
  - `quit flushes parked before the confirmation` (`needsConfirmQuit` sees no parked surface);
  - `child exit is not undoable` (`child_exited = true` → no entry);
  - `child exit while parked closes it`;
  - `parked surface is not the focused surface`;
  - `config change reaches a parked window`;
  - `removeTab from tmux is not undoable`;
  - `undo-timeout 0 disables`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 undo"` → FAIL.
- [ ] **Step 3: Implement** R-M5-12 for tabs and windows. The `undo_expire` timer is set to `nextExpiry`.
- [ ] **Step 4: Scenario** `undo-close.ps1`:
  1. A Git Bash tab running `sleep 30`.
  2. Close it with the tab's `×` (posted click) → `state.parked.tabs = 1`, and the `sleep` process is alive.
  3. `undo` within 2 s (`ctrl+shift+z`, via `Send-RealKeys`) → the tab is back with the same `Surface.id`, and the process has the same pid.
  4. Close again, wait 6 s → the process is gone (`Get-ProcessTree`).
  5. Window close (Alt+F4) → `undo` → the window is back at the same rect.
  6. The palette lists "Undo".
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): undo for closed tabs and windows (undo-timeout), parked items hidden from tmux, tray and IPC"`

### Task 15b: Undo — splits, undo of create, redo

**Review:** opus. **Lead GUI smoke before landing.**

**Files:** Modify `src/apprt/win32/actions/undo_actions.zig`, `src/apprt/win32/Window.zig` (split close registration in `handleCloseSurface`; create registration in the new-tab/new-window/new-split request paths of `Window.zig`), `src/apprt/win32/Tab.zig` (tree snapshot and restore), `test/windows/e2e/undo-close.ps1` (split and redo steps).

- [ ] **Step 1: Failing tests** `"win32 undo: …"`:
  - `close split then undo restores the exact tree`;
  - `undo after a later split change drops the entry`;
  - `new tab then undo parks it, redo restores`;
  - `redo after undo of close closes again`;
  - `tmux kill-pane is not undoable`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 undo"` → FAIL.
- [ ] **Step 3: Implement** the rest of R-M5-12.
- [ ] **Step 4: Scenario** steps appended to `undo-close.ps1`:
  - split → close the split → undo → 2 leaves with the old ratio;
  - new tab → undo → the tab is parked → `ctrl+shift+y` → the tab is back.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): undo for closed splits and created tabs/windows/splits; redo"`

### Task 16: On-screen keyboard

**Review:** light.

**Files:** Modify (fill) `pkg/win32/tip.zig` (`ITipInvocation`, `IFrameworkInputPane`, CLSIDs, slot tests), `src/apprt/win32/osk.zig`. Create `test/windows/e2e/osk.ps1`.

- [ ] **Step 1: Failing tests** `"win32 osk: …"`:
  - `decision`: an empty rect → toggle; a non-empty rect → nothing; test mode → record only;
  - `class not registered launches TabTip`: `REGDB_E_CLASSNOTREG` → launch, then one retry.
- [ ] **Step 2–3:** Run → FAIL; implement R-M5-13. COM runs on the UI thread, which is already STA for OLE drops.
- [ ] **Step 4: Scenario** `osk.ps1`: `show_on_screen_keyboard` via the test `action` op → `state.osk.requests = 1`, and no `TabTip.exe` was started.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): show_on_screen_keyboard opens the touch keyboard"`

### Task 17: External tmux mode — transport and opt-in pipe

**Review:** opus (pipe security, R-M5-14).

**Files:** Modify:
- `src/apprt/win32/ipc/protocol.zig`: `namespace: ?[]const u8` on `op: "tmux"`; `tmuxUserPipeName(sid, session, class, admin)`;
- `src/apprt/win32/tmux/Server.zig`: claim the third pipe when `windows-tmux-external` is true; release it on a reload to false;
- `src/tmux_shim/{main,run,pipe}.zig`: `-L` or `TMUX` unset → user pipe;
- `src/tmux_shim/win.zig`: new externs `GetTokenInformation`, `ConvertSidToStringSidW`, `ProcessIdToSessionId`, `LocalFree` and the elevation check.

Create `test/windows/e2e/tmux-external.ps1`.

**Interfaces:**
- Consumes: M4 `ipc.Server` instance fields (`post_tag` 1, the tmux limits); the M2 per-user pipe security (`instance.claim`).
- Produces:
  - a request on the user pipe carries a non-null `namespace`; a request on the per-process pipe never does, and the server drops a non-null one with code 2;
  - `commands.Context.namespace: ?[]const u8`, consumed by Task 18.
- [ ] **Step 1: Failing tests:**
  - `"tmux shim external: pipe name"` (class sanitising and `-admin` as in the M2 name);
  - `"tmux shim external: -L sets the namespace, no -L is default"`;
  - `"tmux shim external: -L wins over TMUX"`, which replaces M4's `"tmux shim run: -L without -S is not a server"`;
  - `"win32 tmux: per-process pipe refuses a namespace"`.
- [ ] **Step 2: Run** `-Dtest-filter="tmux shim external"`, `"tmux shim run"` and `"win32 tmux"` → FAIL.
- [ ] **Step 3: Implement.** The shim never launches Ghostty. The server claims the pipe only in the primary instance and only when the key is true.
- [ ] **Step 4: Scenario** `tmux-external.ps1`:
  - with `windows-tmux-external = true` in the sandbox config, `tmux.exe -L claude-swarm-1 has-session -t claude-swarm` (`Invoke-Tmux` removes `TMUX`) → exit 1 `can't find session: claude-swarm`;
  - with the key false → `no server running on …`, exit 1.
- [ ] **Step 5: Verify** (also `test-tmux-shim`), **Commit** `git commit -m "feat(tmux): opt-in external mode pipe (TMUX unset or -L namespaces)"`

### Task 18: External tmux mode — sessions, windows by name, replay of recon §5

**Review:** opus.

**Files:**
- Modify (fill) `src/apprt/win32/tmux/namespaces.zig`.
- Modify:
  - `src/tmux_shim/cli.zig`: accept `has-session new-session new-window kill-session kill-server` in external mode, with the `-s -n -A -d -x -y` templates of tmux 3.5a;
  - `src/apprt/win32/tmux/commands.zig`, `tmux/FakeHost.zig`;
  - `tmux/Registry.zig`: namespace windows shown with `ShowWindow(hwnd, SW_SHOWNOACTIVATE)`; no `Window.zig` edit.
- Create `src/apprt/win32/tmux/testdata/claude-external.jsonl`, hand-written from the recon §5 rows, ids `%1…`.
- Append the fake-teammate steps to `test/windows/e2e/tmux-external.ps1` after Task 17 lands.

**Interfaces:**
- Consumes: `Context.namespace` (Task 17); the M4 `Host` contract.
- Produces:
  ```zig
  // namespaces.zig
  pub const Namespace = struct { name: []const u8, session: ?[]const u8, window_id: ?u32, tab_names: std.StringArrayHashMapUnmanaged(u32) };
  pub const Table = struct { pub fn get(self: *Table, name: []const u8) ?*Namespace; pub fn ensure(...) !*Namespace; pub fn drop(self: *Table, name: []const u8) void };
  // Host gains: newSessionWindow(ns, cwd, cmd) !PaneId; newTabIn(window_id, name, cwd, cmd) !PaneId; closeNamespace(ns) void
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 tmux external: replay of the recon §5 sequence"`: FakeHost; outputs and exit codes match the fixture; the final tree is tiled with 3 panes.
  - `"win32 tmux external: has-session before and after new-session"`.
  - `"win32 tmux external: session:window-name target"`.
  - `"win32 tmux external: kill-server closes only its namespace"`.
  - `"tmux shim cli: external commands parse"`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 tmux external"` and `"tmux shim cli"` → FAIL.
- [ ] **Step 3: Implement** R-M5-14. In inside mode these commands keep answering `unknown command: <name>` (R-M4-4), so the M4 replay stays green.
- [ ] **Step 4: Scenario.** The appended steps run the fixture's argv with fake teammates. A new window appears without activation (`GetForegroundWindow` unchanged), with 3 panes, and `kill-server` closes it.
- [ ] **Step 5: Verify** (also `-Dtest-filter="win32 tmux "` for M4 regressions), **Commit** `git commit -m "feat(tmux): external mode sessions and named windows (Claude Code without TMUX)"`

### Task 19: M5 end-to-end run (lead) and 19.n fixes

**Files:** none planned; bug notes only. Each 19.n touches exactly the files its note names (≤ 3 in flight, disjoint).

- [ ] **Step 1:** In order:
  1. `LOCK ZIG build -j6`, then `E2E -Milestone M5` (Debug).
  2. The ReleaseFast build `--prefix zig-out-rf` with `GHOSTTY_E2E_EXE`, then `E2E -Milestone M5`.
  3. `E2E -Milestone all` once (TERM change, close paths, tray).
  4. GUI smoke for 15b.
  5. `grep -l "api.github.com" <every batch log>` → none.
- [ ] **Step 2:** For every FAIL, a bug note: scenario, build, symptom, log excerpt, evidence path. Unit counts:
  - `-Dtest-filter="win32 "` 3× in a row;
  - `"windows "`, `"tmux shim "`, `"Exec: w"`;
  - `test-tmux-shim`.
- [ ] **Step 3 (19.n template):** reproduce; a pure-logic bug gets a failing unit test first; fix; the lead re-runs the scenario in the next batch; commit `git commit -m "fix(win32): <bug summary>"`.

### Task 20: RAM and latency rows, docs, SPEC, M5 acceptance

**Review:** lead.

**Files:** Modify:
- `docs/windows/ram-baseline.csv`, `docs/windows/latency-baseline.csv`.
- `docs/windows/feature-checklist.md`: one row per M5 feature; the shell-integration row → done or gap.
- `docs/windows/CHANGELOG.md`: M5 section, with the keys `windows-jump-list`, `windows-tmux-external`, the undo binds and the `undo-timeout` choice. The gaps:
  - classic context menu only;
  - no auto secure input;
  - cmd has no exit code in its marks;
  - `TERM` over ssh to hosts without the entry, especially Windows OpenSSH from pwsh;
  - external tmux needs PATH;
  - undo is not offered for tmux/IPC/child-exit closes;
  - a crash under the heap lock leaves no dump;
  - a GUI editor in `+edit-config` is detected by PE subsystem only.
- `test/windows/README.md`: the M5 scenarios and the safety rules above.
- `docs/windows/SPEC.md`:
  - §8.5 / §10 as built;
  - §11 crash (R-M5-10);
  - §12.1 / §12.4 external mode (R-M5-14);
  - §13: the Explorer key names and command line (R-M5-5); the release tag scheme and pre-releases (R-M5-9a); the installer's Start-menu shortcut AUMID; the tag check in `src/build/Config.zig` for M6;
  - §17 M5 done with the commit;
  - §18 rulings R-M5-1…14 (with 9a, 12a).

- [ ] **Step 1: RAM rows** per § RAM budget (median of 3). Over → DONE_WITH_CONCERNS with numbers; the owner decides.
- [ ] **Step 2: Latency, startup and `tmux.exe` rows** per the budgets.
- [ ] **Step 3:** `dumpbin /imports zig-out-rf\bin\ghostty.exe` → no `winhttp.dll`, no `dbghelp.dll`. Record.
- [ ] **Step 4:** ARM64 cross-build `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j6` → record.
- [ ] **Step 5:** Record the exit checklist. Commit `git commit -m "docs(windows): M5 acceptance — Windows extras"`.

## M5 exit checklist

1. **Builds and unit tests.** Debug and ReleaseFast build, both with the compiled terminfo installed. These pass: `-Dtest-filter="win32 "` 3× in a row; `"windows "`; `"tmux shim "`; `"Exec: w"`; `test-tmux-shim`. `-Demit-lib-vt` and the Linux recipe build. ARM64 compiles (recorded).
2. **e2e.** `E2E -Milestone M5` is green on Debug and ReleaseFast: `profiles-menu`, `jumplist`, `explorer-cli`, `prompt-marks`, `term-terminfo`, `edit-config`, `update-check`, `crash-dump`, `secure-input`, `undo-close`, `osk`, `tmux-external`. `E2E -Milestone all` has no new failures.
3. **Every M5 feature has evidence.** A unit test plus a scenario or a scripted screenshot (SPEC §17). The update check passed against the fake release JSON (Task 11).
4. **Budgets.** RAM rows within § RAM budget; key echo within +0.5 ms of M4; startup within +10 ms. `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll`.
5. **Owner safety.**
   - No scenario wrote the real registry (`explorer-cli` asserts it).
   - No log of the M5 batches names `api.github.com`, and every `update: fetching` line names `127.0.0.1`.
   - No WSL distro was started.
   - No dump holds the pty marker string.
6. **Feature checklist.** Every M5 row is `done`, `manual` or a documented gap; the shell-integration row is closed.
7. **SPEC.** §17 M5 marked done; §18 has R-M5-1…14 with 9a and 12a; §8.5, §10, §11, §12, §13 amended (with the M6 hand-over).
8. **Owner manual checklist** (PASS/FAIL per line):
   - `ghostty.exe +install-explorer-integration`; right-click a folder, a folder background and `C:\` → "Show more options" → "Open Ghostty here" opens there; `+uninstall-explorer-integration --all` removes everything.
   - Right-click the pinned taskbar icon: the jump list shows New Window, New Tab and the profiles, also with "Show recently opened items" off; a WSL profile opens the distro in `~`.
   - Right-click `+` → pwsh and a WSL distro open; the palette entries work with one tab.
   - A real update toast against a test `win-…-N` release (or `auto-update = off` respected); its click opens the release page.
   - Secure input on: OBS or Snipping Tool shows the window and the palette black; a copy does not appear in Win+V history.
   - `ctrl+shift+z` after closing a tab by mistake brings it back with its shell.
   - The touch keyboard appears on a touch or tablet-mode machine (or N/A).
   - With `TERM=xterm-ghostty` in Git Bash, `vim`, `less` and `htop` look right. From Git Bash, `wsl -e sh -c 'echo $TERM; tput colors'` shows a usable TERM inside the distro.
   - With `windows-tmux-external = true` and the Ghostty dir on PATH, Claude Code started in Windows Terminal opens its teammates in a Ghostty window.
9. **Changelog** with the keys and the gaps of Task 20.

## Self-review

- **Spec coverage:**

  | Requirement | Tasks |
  |---|---|
  | Jump lists (new window/tab, profiles) | 4 (R-M5-4: profiles as tasks), 2, fallback in `App.performIpc` |
  | Shell-profiles dropdown incl. WSL distros | 2 (R-M5-1: registry instead of `wsl.exe -l -q`), 3 |
  | Explorer "Open Ghostty here" + installer | 5 (installer keys and shortcut AUMID handed to M6 via SPEC §13) |
  | pwsh integration (OSC 133/7/title) | 6 (133); 7/title done in M1/M3 |
  | Git Bash integration fixes | 6 (MSYS env paths, `path` feature, marks verified), 8 (`TERMINFO`) |
  | OSC 7 translation | done (M3 29.1) |
  | Compiled terminfo + `TERM=xterm-ghostty` | 7, 8 |
  | `+edit-config` | 9 |
  | Update check (`auto-update`, WinHTTP, toast) | 10, 11 (R-M5-9a tags) |
  | Crash minidumps | 12 |
  | External tmux mode, `claude-swarm` namespace | 17, 18 |
  | `secure_input`, `undo`/`redo` analogs | 13, 14, 15a, 15b |
  | On-screen keyboard | 16 |
  | §8.4 ConPTY flags | closed by L1 (§18.33) |
  | §10 MSYS forward slashes | 6 |
  | Exit: test or screenshot per feature; fake release JSON | every task; 11 |
- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | shells, `win32.zig`, `pkg/win32/main.zig`, `actions.zig`, `messages.zig`, `hooks.zig`, `App.zig`, `Window.zig`, `Surface.zig`, `ops.zig`, `Config.zig`, `e2e.ps1` |
  | W1 | 5 | `windows_registry.zig`, `windows_explorer.zig`, `src/os/main.zig`, `src/cli/{ghostty,explorer_integration}.zig`, `explorer-cli.ps1` |
  | W1 | 7 | `GhosttyResources.zig`, `src/build/Config.zig` |
  | W2 | 2 | `windows_shell.zig`, `profiles.zig`, `Overrides.zig`, `ops.zig`, `App.zig` |
  | W2 | 6 | `shell_integration.zig`, `ghostty.ps1`, `ghostty.bash`, `prompt-marks.ps1` |
  | W2 | 8 | `Config.zig`, `Exec.zig`, `term-terminfo.ps1` |
  | W3 | 3 | `profiles_menu.zig`, `strip_input.zig`, `CommandPalette.zig`, `tray.zig`, `profiles-menu.ps1` |
  | W3 | 10 | `update/{release,state}.zig`, testdata |
  | W3 | 12 | `windows_crash.zig`, `src/os/main.zig`, `main_ghostty.zig`, `main.zig`, `crash-dump.ps1` |
  | W4 | 4 | `shobjidl.zig`, `jumplist.zig`, `jumplist.ps1` |
  | W4 | 11 | `winhttp.zig`, `Updater.zig`, `notify.zig`, `update-check.ps1`, `_m5_fakeserver.ps1` |
  | W4 | 13 | `secure_input.zig`, `badges.zig`, `clipboard.zig`, `overlay.zig`, `dialog/Dialog.zig`, `inspector/Window.zig`, `drag_ghost.zig`, `secure-input.ps1` |
  | W5 | 9 | `edit_config.zig`, `edit-config.ps1` |
  | W5 | 14 | `undo.zig` |
  | W5 | 16 | `tip.zig`, `osk.zig`, `osk.ps1` |
  | W6 | 15a | `undo_actions.zig`, `Window.zig`, `Tab.zig`, `Surface.zig`, `App.zig`, `hooks.zig`, `theme.zig`, `recovery.zig`, `app_actions.zig`, `undo-close.ps1` |
  | W6 | 17 | `protocol.zig`, `tmux/Server.zig`, `tmux_shim/{main,run,pipe,win}.zig`, `tmux-external.ps1` |
  | W6 | 18 | `namespaces.zig`, `tmux_shim/cli.zig`, `tmux/{commands,FakeHost,Registry}.zig`, testdata (+ `tmux-external.ps1` after 17 lands) |
  | W7 | 15b | `undo_actions.zig`, `Window.zig`, `Tab.zig`, `undo-close.ps1` |

  Cross-wave chains: `Config.zig` 1 → 8; `src/os/main.zig` 5 → 12; `App.zig` 1 → 2 → 15a; `ops.zig` 1 → 2; `Window.zig` 1 → 15a → 15b; `Surface.zig` and `hooks.zig` 1 → 15a.

  Within a wave, the only shared file is `tmux-external.ps1` (17 → 18), which is serialised. The M4 file `Registry.zig` (Task 18) does not collide with Task 15a: parked items move out of the lists `Registry` iterates, and no signature changes.
- **Type names defined once:**

  | Task | Names |
  |---|---|
  | 1 | all shell signatures; `ops.crash_hook`, `hooks.crash_recheck`, `App.forEachWindow`, `Surface.parked`, `undo.Kind`, `undo_actions.{Entry,State}`, `Updater.State` |
  | 2 | `windows_shell.{Profile,WslDistro,profiles}`, `Overrides.{profile,ProfileResolver,resolve}`, `profiles.resolver` |
  | 4 | `jumplist.{Item,buildItems,aumidForRun,fallbackArgv}` |
  | 5 | `windows_explorer.*` (incl. `aumid`, `toast_icon_name`), `windows_registry.*` |
  | 8 | `windowsTerm` |
  | 9 | `windowsEditorArgv`, `peIsGui` |
  | 10 | `release.*`, `state.*` |
  | 11 | `Updater.{Result,fetch,urlForRun}` |
  | 12 | `windows_crash.*` |
  | 14 | `undo.Stack` |
  | 18 | `namespaces.*` |
- **Review Focus → tests:** 1 → Tasks 5, 2; 2 → Task 8; 3 → Tasks 10, 11; 4 → Tasks 14, 15a; 5 → Task 12.
- **Proportion:** the code blocks are signatures and test names only.

### Open questions → recommended answers (lead/owner)

1. *R-M5-12a: undo on by default (5 s, `ctrl+shift+z`/`ctrl+shift+y`), at the cost of a tab's programs running 5 s after its close?* → yes, like macOS. The alternative is `undo-timeout = 0` on Windows with no keys.

The ledger has answered every other question (rulings preamble).

## Pre-flight dispositions

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | CRITICAL | Zig's vectored segfault handler preempts the filter | Applied: `enable_segfault_handler` off on Windows (Task 12, touch point), log line after the dump, comptime test, both builds in the scenario. |
| 2 | CRITICAL | Update check cannot see fork releases | Applied per ledger C2: R-M5-9a (`-win.<N>` version, `win-<zon>-<N>` tags, `/releases` list incl. pre-releases, compare `N`); Task 10 testdata; SPEC §13 and M6 hand-over in Task 20. |
| 3 | CRITICAL | Test-mode runs can reach `api.github.com` | Applied per ledger C3: no automatic check in test mode, `urlForRun` → `?[]const u8`, fetch log line oracle, Task 19 grep; `Get-NetTCPConnection` dropped. |
| 4 | IMPORTANT | Custom category fails with recent items off; leftovers | Applied per ledger: profiles as tasks after a separator, `DeleteList` before `BeginList` in test mode, `hr_*` asserted. |
| 5 | IMPORTANT | `+new-tab` fallback location, cwd, class | Applied: `jumplist.newTabFallback` from `App.performIpc` (Task 1 shell, Task 4 body), links' working dir, `--working-directory=home`, `fallbackArgv` keeps `--class`; `new_tab.zig` dropped. |
| 6 | IMPORTANT | Default-class Ghostty from two scenarios | Applied: `--class=` in `windowsEditorArgv` and `fallbackArgv`; the harness rule to find, register and stop such children. |
| 7 | IMPORTANT | Undo registration points and `origin` | Applied: registration in `Window.zig` handlers after confirmation, no `origin`, grouped entries, child-exit test; `*_actions.zig` dropped from 15a/15b. |
| 8 | IMPORTANT | Parked items reachable through core; missed sweeps | Applied: `focusCallback(false)`, `Surface.parked()` stub used by `ops.zig`, `App.forEachWindow(true)` in config/theme/recovery sweeps, child exit while parked, quit flush first; tests added. |
| 9 | IMPORTANT | Undo has no key; close semantics change | Applied as R-M5-12a with the macOS-like recommendation; the one open question left for the owner. |
| 10 | IMPORTANT | Badge oracle impossible; popups not excluded | Applied: `state` oracle only, `apply(hwnd)` at every creation site plus the `EnumThreadWindows` sweep, `Window.create` call in Task 1. |
| 11 | IMPORTANT | `C:/` breaks the bash `path` feature | Applied: R-M5-8 skips `path` under MSYS; Task 6 owns `ghostty.bash`; the PATH check is in the scenario. |
| 12 | IMPORTANT | Dumps contain terminal output | Applied per ledger C1: `MiniDumpFilterMemory`; test on `dump_type`; scenario checks a marker string is absent. No `Exec.zig` touch needed. |
| 13 | IMPORTANT | `dbghelp` load at crash time can deadlock | Applied: loaded by the dump thread at install; RAM row raised to +0.5 MB; heap-lock case documented. |
| 14 | IMPORTANT | WinHTTP unload, total timeout, `stop` hang | Applied: unload-notify event, UI-thread deadline closing the handle, `stop` = close then join; silent-server case and test. |
| 15 | IMPORTANT | Task 15 too large | Applied per ledger: 15a (W6) and 15b (W7, after 15a's smoke). |
| 16 | MINOR | Marks gated by `title` | Applied (R-M5-6, Task 6 test). |
| 17 | MINOR | pwsh mark placement | Applied (R-M5-6). |
| 18 | MINOR | cmd `133;D`, both-ends idempotency | Applied. |
| 19 | MINOR | `crash/dir.zig` needs no change | Applied: touch point dropped; the scenario asserts `+crash-report`. |
| 20 | MINOR | `Probe` field breaks callers | Applied: defaulted `wslDistros = noDistros`, test added. |
| 21 | MINOR | Palette is sorted | Applied: `Run.profile`, renamed test. |
| 22 | MINOR | Menu keyboard and foreground | Applied: `&` accelerators, letter only, `SetForegroundWindow` + `WM_NULL`. |
| 23 | MINOR | Task 1 lacks `Window.zig` | Applied (chain 1 → 15a → 15b). |
| 24 | MINOR | Task 17 needs `win.zig` | Applied; `tmux.exe` rows kept in Task 20. |
| 25 | MINOR | `-L` with `TMUX` set | Applied: tmux's rule; the M4 test is replaced. |
| 26 | MINOR | Show without activation needs `Window.zig` | Applied: `ShowWindow(SW_SHOWNOACTIVATE)` from `Registry.zig`. |
| 27 | MINOR | Fake server blocks the scenario | Applied: runspace. |
| 28 | MINOR | Hive log files and lock | Applied (unit test and scenario). |
| 29 | MINOR | WSL profile cwd | Applied: `--cd ~`. |
| 30 | MINOR | `TERM` into WSL and ssh | Applied: basename check, owner checklist line, CHANGELOG gap. |
| 31 | MINOR | GUI editors | Applied: `peIsGui`, direct spawn, tests. |
| 32 | MINOR | Jump-list worker data and hang | Applied: owned heap `[]Item`, `stop` ≤ 2 s then leak with a log line. |
| 33 | MINOR | Undo with `quit-after-last-window-closed = true` | Applied: stated in R-M5-12 (not undoable). |
| 34 | MINOR | OSK class not registered | Applied: TabTip launch and retry, test. |
| 35 | MINOR | Filter replaced later | Applied: `ensureInstalled` at `appStarted` via `hooks.crash_recheck`. |
| 36 | MINOR | M6 Start-menu shortcut AUMID | Applied: R-M5-5 and Task 20 SPEC §13 hand-over. |
| 37 | MINOR | Task 1 too wide | Applied both: profile wiring moved to Task 2 (chains `ops.zig`/`App.zig` 1 → 2), Task 1 review is opus. |
