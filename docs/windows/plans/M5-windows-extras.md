# M5 — Windows extras (profiles, jump lists, Explorer, shell integration, terminfo, updates, crash dumps, macOS analogs, external tmux): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Windows-only features of SPEC §17 M5 work, and every feature has a unit test plus an e2e scenario or a scripted screenshot:
- shell profiles (Git Bash, PowerShell 7, Windows PowerShell, cmd, WSL distros) in a new-tab menu, the command palette, the tray and the jump list;
- "Open Ghostty here" in Explorer;
- prompt marks for pwsh and cmd, and the Git Bash (MSYS) env fixes;
- compiled terminfo and `TERM=xterm-ghostty`;
- `+edit-config`;
- an update check against GitHub Releases;
- crash minidumps;
- Windows analogs of `secure_input`, `undo`/`redo` and `show_on_screen_keyboard`;
- the external tmux mode (`TMUX` unset, `-L`).

Exit (SPEC §17): every feature has a test or a scripted screenshot, and the update check is tested against a fake release JSON.

**Architecture:** Same pattern as M3: one skeleton task (Task 1) adds every new module shell, message id, timer id, action route, config key and `hooks.zig` fan-out line. Feature tasks then only fill their own files.
- Pure models are unit-tested headless: profile list, jump-list items, Explorer registry keys, release JSON and versions, undo stack, external tmux namespaces.
- Side effects go through injectable seams, so no test touches the owner's machine state: a `Probe` for files and the registry, a registry root `HKEY`, the fetch URL, the AUMID.
- Network, COM and dump writing run off the UI thread and post results back.
- New system DLLs (`winhttp.dll`, `dbghelp.dll`) load lazily from System32.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/shell32/advapi32/ole32), shell COM (`ICustomDestinationList`, `IShellLinkW`, `IPropertyStore`, `ITipInvocation`, `IFrameworkInputPane`), WinHTTP, DbgHelp `MiniDumpWriteDump`, Git for Windows `tic.exe` (build time), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §8.4 (ConPTY flags, closed by L1), §8.5 (M5 core changes), §10 (`TERM`, MSYS paths), §11 (crash dumps)
- §12.1 / §12.4 (external tmux mode), §13 (Explorer keys, AUMID), §17 M5, §18.4 (crash dir), §18.5–6 (per-user pipe, forwarding), §18.24 (R-M3-5 toasts), §18.27 (`open_url` policy), §18.33 (L1), §18.34 (M3 deferrals)
- DECISIONS "Features" (jump lists, shell profiles, Explorer, updates), "Release" (no auto-install), the 2026-10-27 macOS-style rule and the 2026-10-28 Windows 11 dialogs.

Contract for the external tmux mode: `docs/windows/recon/tmux.md` §5. Memory rules: style follows macOS; speed over ceremony.

**Already done; not re-planned:**
- OSC 7 translation, pwsh/cmd OSC 7 and Git Bash `pwd -W` (M3 Task 29.1).
- `.exe`-stripping shell detection and the pwsh injection (`shell_integration.zig` `exeName`, `setupPwsh`).
- The Git Bash first-keystroke fix (M3 26.4/26.4.1).
- Windows 11 dialogs (DECISIONS 2026-10-28).
- The M3 deferrals of §18.34 (`export_terminal_io` write off the UI thread, translucent capture guard, DPAPI for the e2e clipboard backup) belong to the lead's polish3 batch.
- §8.4 "ConPTY passthrough/INHERIT_CURSOR evaluated in M5" is closed by L1 (§18.33). The bundled `conpty.dll` remains an owner question outside M5.

**Starts** when M4 W5 has landed. Tasks 15, 17 and 18 wait for M4 acceptance, because they touch the tab/close paths and the tmux files M4 owns. Every other task may run alongside M4's W6/W7, provided its files are disjoint from the in-flight M4 14.n fixes. Task numbers are identities, not order: the wave table is the execution order.

## Global Constraints

Carried from M1–M4 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2.
- Pure Win32 + DWM apprt. Bindings are hand-written in `pkg/win32`: append-only, W-variants, `callconv(.winapi)`. COM interfaces list ALL vtable slots, with a slot-count test against Windows SDK 10.0.26100 headers. `src/os/*` and `src/cli/*` declare their own `extern`s (they never import `win32`).
- **UI thread owns** every HWND, tab, split tree, surface and menu. Workers (update fetch, jump-list commit, dump writer) never touch them. Hand-off only by `PostMessageW` to the message window with a heap payload freed by the receiver. Every modal dialog runs from `WM_GHOSTTY_POSTED_DIALOG`.
- **System DLLs added in M5 load lazily from System32**: `LoadLibraryExW(…, LOAD_LIBRARY_SEARCH_SYSTEM32)` on first use, never import-table entries. This covers `winhttp.dll` (Task 11) and `dbghelp.dll` (Task 12). Task 20 checks with `dumpbin /imports` that `ghostty.exe` imports neither.
- Core edits are platform-neutral or Windows-gated, and only those in "M5 core touch points" are allowed. A cause found outside them: the implementer stops with evidence, and the lead schedules an `n.1` task.
- Zig 0.17 std idioms of the touched file (`global.io()`, `std.Io`, `GetTickCount64` for deadlines). No `std.time.Timer`/`std.Thread.sleep`.
- Visual elements follow Ghostty for macOS (`macos/Sources`), except where Windows conventions require otherwise (menus, jump lists, the touch keyboard), and the task report says so. Dialogs use the M3 Windows 11 dialog (`dialogs.zig`).
- Commits: no `Co-Authored-By` or similar trailers. Never `python -` (nor `python3 -` with a heredoc).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

**Owner safety (M2–M4 rules, extended for M5).** None of these needs a per-run approval, because none touches owner state.

- **Harness.** e2e scenarios run only through `test/windows/e2e.ps1`, with the shared desktop lock, a per-scenario `class` and the sandbox env (`New-E2eSandbox`: `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA` under the sandbox). Evidence images come only from the guarded capture helpers (`Save-Evidence -Window`, `Save-WindowShot`, `Get-ScreenShot`, `Assert-CaptureRectClear`). Never a full-screen grab.
- **Registry.** No test, scenario or implementer run writes the real `HKCU`/`HKLM`.
  - Registry writers take an explicit root `HKEY`. Unit tests pass a private hive from `RegLoadAppKeyW(<sandbox>\test.hive)` and delete the file afterwards.
  - The Explorer CLI is exercised only with `--dry-run` (prints, never opens a key) or with `GHOSTTY_WIN32_TEST_HIVE=<file>`. That env makes the CLI use an app hive instead of `HKCU`; it is honoured by every build because it can only redirect writes away from the real registry.
  - The AUMID registration keeps the M3 rule: never in test mode (`notify.zig`).
  - Real installs are owner checks (exit checklist 8).
- **Jump list.**
  - Unit tests never call `ICustomDestinationList`.
  - The e2e commits only under the test AUMID `com.mitchellh.ghostty.windows-unofficial-e2e` (selected by `GHOSTTY_WIN32_TEST_IPC=1`) and calls `DeleteList` for it at exit. The scenario re-checks the `DeleteList` result through the `state` op.
- **Network.** No test reaches the internet.
  - The update URL is a compile-time constant. The override `GHOSTTY_WIN32_UPDATE_URL` is honoured only in test mode and only for `http://127.0.0.1:<port>/…`.
  - The fake server is a PowerShell `System.Net.Sockets.TcpListener` bound to `127.0.0.1` on a free port, inside the scenario, stopped in `finally`.
- **WSL.** No test starts a WSL distro: booting the VM costs gigabytes of RAM. Tests read the distro list (registry, read-only) and spawn only the cmd and pwsh profiles.
- **Crashes.**
  - The deliberate-crash IPC op exists only in test mode. Dumps land in the sandbox `LOCALAPPDATA` and are deleted by the scenario.
  - Scenarios assert that WER shows no dialog (`Find-GhosttyWindows` of `WerFault.exe` is empty).
- **Secure input.** `WDA_EXCLUDEFROMCAPTURE` blacks out captures, so the scenario asserts the affinity through the `state` op and never compares pixels while it is on.
- **Touch keyboard.** In test mode `show_on_screen_keyboard` is only recorded; it never shows the keyboard on the owner's desktop.
- **Owner files.** `+edit-config` scenarios set `EDITOR` to a sandbox fake script. The owner's `%USERPROFILE%\.config` is never opened.
- **Window behaviour.** Any task that changes window behaviour (Tasks 3, 13, 15) gets a quick GUI smoke by the lead before landing: start, the changed action, close. This is in addition to the wave batch.

Speed rules (owner 2026-10-26/28; unchanged from M4):

- **Builds and tests use `-j6`**, through the test-lock (3 slots, each checks ≥ 2 GB free). Bash timeout 600000. Prefer a focused `-Dtest-filter`; never the full suite locally.
- **Implementers run unit tests + `LOCK ZIG build -j6` only.** A task that owns a GUI scenario writes it and makes it parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```
  The lead runs scenarios in wave batches (G1–G3). Implementer-run exceptions: Task 5's `explorer-cli.ps1` and Task 7's terminfo check, which have no window.
- **Up to 3 writers in flight.** A task starts as soon as its dependencies have landed and its files do not collide with in-flight tasks.
- **Every task: unit tests + at most one e2e scenario.**
- **Review tier** (stated per task): `light` = one batched sonnet review per batch; `opus` = per-task review for concurrency, COM lifetimes, security, process lifetime or network.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (lead only, after `LOCK ZIG build -j6`)
- Test name prefixes: `win32 ` (apprt), `windows ` (`src/os`, `src/cli` Windows code), `tmux shim ` (`src/tmux_shim`), and the core module's existing prefix (`shell_integration`, `windows: …` in `shell_integration.zig`).

### M5 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/config/Config.zig` | doc comments of `auto-update`, `undo-timeout`, `macos-secure-input-indication` (Windows meaning); new Windows-only keys `windows-tmux-external`, `windows-jump-list` | 1 |
| `src/config/Config.zig` | `default_term` back to `xterm-ghostty` on Windows; its test | 8 |
| `src/termio/Exec.zig` | Windows-gated `TERM`/`TERMINFO` choice (R-M5-7) | 8 |
| `src/termio/shell_integration.zig` | `setupCmd` prompt marks; MSYS forward-slash env in `setupBash` (Windows) | 6 |
| `src/shell-integration/pwsh/ghostty.ps1` | OSC 133 | 6 |
| `src/shell-integration/bash/ghostty.bash` | only the MSYS branch, if Task 6's test needs it | 6 |
| `src/build/GhosttyResources.zig`, `src/build/Config.zig` | compiled terminfo on Windows targets (`-Dtic=`) | 7 |
| `src/cli/ghostty.zig` | actions `+install-explorer-integration`, `+uninstall-explorer-integration` (Windows; elsewhere they print "only on Windows", exit 1) | 5 |
| `src/cli/explorer_integration.zig` | new | 5 |
| `src/cli/edit_config.zig` | Windows arm | 9 |
| `src/cli/new_tab.zig` | Windows fallback when no instance answers | 4 |
| `src/crash/dir.zig` | `.dmp` files count as reports on Windows | 12 |
| `src/main.zig` | the Windows panic hook writes a dump | 12 |
| `src/main_ghostty.zig` | installs the exception filter on Windows | 12 |
| `src/os/main.zig` | exports for the new `src/os` files | 5 |
| `src/os/main.zig` | export for `windows_crash.zig` | 12 |
| `src/os/windows_shell.zig` | profile detection | 2 |
| `src/os/windows_registry.zig`, `src/os/windows_explorer.zig` | new | 5 |
| `src/os/windows_crash.zig` | new | 12 |

Not touch points: `src/Surface.zig`, `src/apprt/action.zig`, `src/input/*`. Every M5 action already exists in core, and every M5 behaviour lives in the apprt.

### RAM budget (owner: low RAM)

Private Bytes, ReleaseFast, measured with `test/windows/measure-ram.ps1` (`-Tag`/`-Actions`/`-Sample`). Each gated row is the median of 3 runs, against the M4 acceptance rows re-measured the same day.

| Item | Budget | Measured by |
|---|---|---|
| default config, 1 window 1 surface, 30 s after start (jump list committed, update check not yet due) | ≤ M4 row + 1 MB | Task 20 |
| after one update check (fake server), 30 s later | ≤ pre-check + 1 MB (WinHTTP session closed, `FreeLibrary`) | Task 20 (`-Sample before@… checked@…`) |
| profile menu opened once | ≤ +0.3 MB | Task 20 |
| crash handler armed (dump thread idle) | ≤ +0.2 MB | Task 20 |
| a parked (undo) tab, then expired, 30 s idle | while parked ≤ the M2 per-tab cost; after expiry within +10 % of the pre-close value | Task 20 |
| secure input on | ≤ +0.1 MB | Task 20 |

### Latency budget

- Key echo (Ghostty-owned p95, default config, ≥ 200 samples × 3 runs): within +0.5 ms of the M4 acceptance value. No M5 code runs on the `WM_KEYDOWN` → pty write path. Secure input changes window affinity and clipboard formats only.
- Startup: time to the first frame within +10 ms of M4 (`startup` scenario). Profile detection is lazy (first menu, palette or jump-list build). The jump-list commit and the update check run on workers, 2 s and 60 s after start.
- The profile menu opens in ≤ 50 ms after right-click (Debug recorded, ReleaseFast gated): Lxss registry read plus at most 8 file probes.

## Review Focus

1. **Paths that Explorer hands to "Open Ghostty here".** `%V` can be:
   - a drive root (`C:\`), whose trailing backslash would escape the closing quote under MS-CRT rules;
   - a path with spaces, `#`, `%`, `'` or Cyrillic;
   - a long path over 260 characters;
   - a library or virtual folder (`::{GUID}`), a network share, or a mapped drive.

   Expected: a local folder opens in that folder; anything else opens home and logs one warning; nothing crashes; nothing is passed to a shell unquoted.

   Tests: Task 5 `windows explorer: command line round-trips every %V shape`; Task 2 `win32 overrides: working directory from Explorer`.
2. **`TERM=xterm-ghostty` where the entry cannot be found.**
   - WSL (`wsl.exe`, System32 `bash.exe`);
   - a portable zip whose `share` folder was moved;
   - a build without `tic.exe`;
   - Windows OpenSSH or MSYS ssh from inside Ghostty to a host without the entry. This last case matches upstream: only shell-integration `ssh-terminfo`/`ssh-env` help, and the changelog names it.

   Expected: `xterm-256color` whenever the compiled entry is missing or the target is WSL.

   Tests: Task 8 `TERM falls back without the compiled entry`, `wsl gets xterm-256color`; `term-terminfo.ps1`.
3. **Update check against a hostile or broken network.** Inputs: offline, proxy, captive portal (HTML 200), 403 rate limit, a body over 1 MiB, a JSON without `tag_name`, a non-semver tag, a draft or prerelease, an older version, the same version, an `html_url` outside the fork's releases.

   Expected: no toast and no dialog except for a newer valid release; one log line; the next try at the normal interval; the UI thread never blocks; a version is announced at most once.

   Tests: Task 10 parser, decision and state tests; Task 11 `update-check.ps1` (fake server: newer, same, garbage, 403, no server).
4. **Undo and child processes.**
   - A closed tab is parked with its shell still running. It must not appear in tmux `list-panes`, the tray count, `goto_window`, the jump list or `quit-after-last-window-closed`.
   - `quit` during the undo window ends parked surfaces at once.
   - Expiry closes with the Windows Terminal semantics (§18.14).
   - A tmux `kill-pane`, a child exit or an IPC close never becomes undoable.
   - A config reload while parked does not resurrect anything.

   Tests: Task 14 model tests; Task 15 `win32 undo: …`, `undo-close.ps1`.
5. **A crash inside the crash path.**
   - Stack overflow: the filter runs on the exhausted stack, so the dump is written by a pre-created thread.
   - Two threads crash at once: one dump, the second waits.
   - A crash during `MiniDumpWriteDump`, and `dbghelp.dll` missing.
   - The `LOCALAPPDATA` crash dir is not writable.

   Expected: at most one dump per process, never a hang longer than 10 s, never a WER dialog, the process ends.

   Tests: Task 12 `windows crash: …`, `crash-dump.ps1` (access violation and stack overflow).

## Rulings (plan-m5, 2026-10-28; lead/owner may overturn; recorded in SPEC §18 by Task 20)

- **R-M5-1 Profiles are detected, not configured.** `windows_shell.profiles(alloc, env, probe)` returns, in this order:

  | Profile | Id | Command | Condition |
  |---|---|---|---|
  | `Default` | `default` | the config `command` (or the §8.3 resolution) | always |
  | `Git Bash` | `git-bash` | `{bash, "--login", "-i"}` | `findGitBash` |
  | `PowerShell` | `pwsh` | `{pwsh, "-NoLogo"}` | `findPwsh` |
  | `Windows PowerShell` | `powershell` | `{%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe, "-NoLogo"}` | exists |
  | `Command Prompt` | `cmd` | `{%SystemRoot%\System32\cmd.exe}` | always |
  | `<distro>` | `wsl:<distro>` | `{%SystemRoot%\System32\wsl.exe, "-d", <distro>}` | each distro |

  - WSL distros come from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID}\DistributionName`, read-only. The `DefaultDistribution` comes first; the rest follow in name order; names starting with `docker-desktop` are skipped.
    - Deviation from SPEC's `wsl.exe -l -q`: no process start, no UTF-16 console output, and the WSL service is never woken.
    - Cost if wrong: one function.
  - Ids are stable ASCII. A distro name is kept only if it matches `[A-Za-z0-9._-]{1,64}`; others are skipped and logged.
  - The list is cached on the App, built on first use, and rebuilt when a profile menu opens (stale entries vanish).
  - No config key for custom profiles (YAGNI; the user's `command` is `Default`).
- **R-M5-2 `--profile=<id>`.** A new launch/IPC argument, parsed by `Overrides`, with the same weight as `--working-directory=`.
  - It is forwardable (`Overrides.forwardable`): it names a profile and never carries a command (M2 revision 2 holds).
  - The **receiving** process resolves the id against its own list. An unknown id → IPC code 1, stderr `unknown profile: <id>`; in a standalone launch, one warning and the `Default` profile.
  - `--profile` together with `-e`/`--command=` → `-e` wins and a warning is logged.
- **R-M5-3 Where profiles are offered** (style rule: macOS has no profiles, so native Windows menus, themed like `tab_menu.zig`):
  1. Right-click on the tab row's `+` opens the profile menu: "New Tab" items, a separator, then "New Window ▸" with the same items. Left click on `+` is unchanged (new tab, `Default`).
  2. Command palette entries `New Tab: <profile>` and `New Window: <profile>`, after the config entries. These are reachable with one tab, when the tab row is hidden.
  3. Tray menu: "New Window ▸ <profiles>".
  4. Jump list (R-M5-4).
- **R-M5-4 Jump list** (`ICustomDestinationList`, AUMID of `notify.aumid`).
  - Tasks: "New Window" = `ghostty.exe`; "New Tab" = `ghostty.exe +new-tab`.
  - A custom category "Profiles" holds one link per profile except `Default`, as `ghostty.exe --profile=<id>`.
  - Icons: the exe icon; WSL and the shells use the icon of their own exe (`IShellLinkW::SetIconLocation`).
  - Built 2 s after start on a worker thread (STA, released after the commit), on profile-list change and on config reload, only in the primary instance, and only when `windows-jump-list = true` (default `true`).
  - `+new-tab` on Windows: when no instance answers, it starts `ghostty.exe` with the same `--working-directory=`/`--profile=` instead of failing. A jump-list click from a closed Ghostty then opens a window.
  - Cost if wrong: two jump-list entries.
- **R-M5-5 Explorer keys.** `+install-explorer-integration` writes under `HKCU\Software\Classes`, for each of `Directory\shell\GhosttyOpenHere`, `Directory\Background\shell\GhosttyOpenHere` and `Drive\shell\GhosttyOpenHere`:
  - `(default)` = `Open Ghostty here`;
  - `Icon` = `"<exe>",0`;
  - `command\(default)` = `"<exe>" "--working-directory=%V\."`.

  The `\.` suffix keeps a drive root's backslash away from the closing quote (`C:\` → `C:\\.`, normalised by `GetFullPathNameW`).
  - `+uninstall-explorer-integration` deletes exactly these three keys, and only if `command\(default)` starts with `"` and names a file called `ghostty.exe`; a foreign key is reported and kept.
  - `--all` also deletes `HKCU\Software\Classes\AppUserModelId\<aumid>`, and the toast icon file. This is the full revert for portable users. The jump list is cleared by Ghostty itself on its next start with `windows-jump-list = false` (the CLI has no COM).
  - `--dry-run` prints every key and value it would write or delete, and opens no key.
  - Windows 11 shows the entry under "Show more options" (the classic menu). The top-level menu needs package identity, which is out of scope and noted in the changelog.
  - M6's installer writes the same keys (SPEC §13 amended by Task 20).
- **R-M5-6 Prompt marks.**
  - pwsh emits `133;A` before the prompt text, `133;B` after it, `133;C` when Enter accepts a non-empty line, and `133;D;<code>` before the next prompt. `<code>` = `$LASTEXITCODE` when the last command was native, else `0`/`1` from `$?`.
  - cmd's `PROMPT` gets `133;A` at its start and `133;B` at its end. cmd cannot report C/D; no `command_finished` for cmd is the documented gap.
  - Git Bash keeps the upstream bash marks. Task 6 proves they arrive under MSYS.
- **R-M5-7 Terminfo and `TERM`.**
  - The build compiles `ghostty.terminfo` with `tic -x` on Windows targets too. `tic` comes from `-Dtic=<path>`, else `tic` on PATH, else `%ProgramFiles%\Git\usr\bin\tic.exe`. Git for Windows ships it, and its MSYS ncurses reads what it writes (hex directory layout `78/`).
  - Output: `share/terminfo/78/xterm-ghostty` and `78/ghostty` (and `x/` too if `tic` writes it).
  - No `tic` → only the source is installed, the build prints one warning, and runtime falls back.
  - Windows default `term = xterm-ghostty` (Config). Exec sets it only when the compiled entry exists; otherwise `xterm-256color` and one warning.
  - Commands whose exe is `%SystemRoot%\System32\wsl.exe` or System32 `bash.exe` always get `xterm-256color`.
  - Cost if wrong: one default.
- **R-M5-8 MSYS env paths.** When bash integration applies on Windows, `setupBash` rewrites `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR` and `TERMINFO` from `C:\a\b` to `C:/a/b` (mixed form: MSYS and Windows programs both read it). `/c/a/b` is not used.
- **R-M5-8b `+edit-config`.**
  - `VISUAL`, else `EDITOR`, tokenised with the Windows rules (`windows_cmdline.zig`), starts a **separate** Ghostty: `ghostty.exe -e <tokens…> <config path>`, detached, and the CLI exits 0.
  - Why: a GUI-subsystem `ghostty.exe` cannot share the calling console with a terminal editor (§11 known limitation).
  - No editor set → `%SystemRoot%\System32\notepad.exe <path>`, detached.
  - Upstream errors without an editor; Windows differs and the help text says so.
- **R-M5-9 Update check.**
  - `auto-update`: unset → `check` on Windows; `download` → `check` with one warning; `off` → never automatic.
  - Debug builds never check automatically.
  - Endpoint (constant): `https://api.github.com/repos/Denmurzik/ghostty/releases/latest`, `Accept: application/vnd.github+json`, `User-Agent: Ghostty/<version> (Windows)`. No other header, cookie or identifier.
  - WinHTTP with automatic proxy, 10 s total timeout, body cap 1 MiB, TLS only (plain `http` only for the test override).
  - First automatic check 60 s after start, then every 24 h while running, and skipped while the state file says the last check was under 24 h ago.
  - State in `%LOCALAPPDATA%\ghostty\update.json` (`{"last_check":<unix s>,"notified":"<version>"}`).
  - Newer = semver of `tag_name` without a leading `v` > `build_config.version`. Drafts and prereleases are ignored; build metadata is ignored.
  - A newer version gets one toast per version (title `Ghostty <ver> is available`, body `Open the release page`). The click opens `html_url` only if it starts with `https://github.com/Denmurzik/ghostty/releases/`.
  - The `check_for_updates` action checks now and always answers with a Windows 11 dialog: "up to date", "<ver> available" (with an "Open release page" button), or "could not check" (the error).
  - M6 must keep release tags semver (noted for M6).
- **R-M5-10 Crash dumps.**
  - `SetUnhandledExceptionFilter` is installed first thing in `main` on Windows (GUI and CLI paths).
  - At install, a dump thread is created (64 KiB stack, waits on an event) and the dump path prefix is precomputed: `%LOCALAPPDATA%\ghostty\crash\ghostty-<pid>-`.
  - The filter stores the exception pointers and signals; the thread writes `<prefix><GetTickCount64>.dmp` with `MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules`. No heap and no indirect memory: terminal text must not leak into dumps.
  - The filter waits ≤ 10 s and returns `EXCEPTION_EXECUTE_HANDLER` (no WER dialog).
  - The Zig panic path (`src/main.zig`) asks for a dump with no exception record before aborting.
  - The 10 newest dumps are kept; older ones are pruned at the next start.
  - `+crash-report` lists `.dmp` files. Nothing is ever uploaded.
- **R-M5-11 `secure_input` analog.** Windows has no API that hides keystrokes from other same-user processes, so "secure input" means:
  1. every Ghostty window gets `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`;
  2. text copied while it is on carries `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0` and `CanUploadToCloudClipboard = 0`;
  3. the macOS lock badge (25 DIP `lock.shield` glyph from Segoe Fluent Icons `0xE72E`, 10 DIP from the top-right of each surface, rounded 12, 1 px grey stroke; no animated gradient) is shown when `macos-secure-input-indication = true`.

  - It is app-wide, like macOS: `on`, `off` and `toggle` from the action. A badge click opens a Windows 11 dialog with the macOS explainer text, reworded for Windows.
  - No automatic secure input at password prompts: ConPTY has no termios. This is a documented gap.
- **R-M5-12 Undo/redo** (macOS `BaseTerminalController`/`TerminalController` semantics, apprt only).
  - Undoable: user-initiated close tab, close window, close split (`close_surface`), and new tab, new window, new split.
  - Not undoable: tmux, IPC, child exit and quit.
  - A closed tab, window or split is **parked**: HWNDs hidden, surfaces alive, child processes running. It expires after `undo-timeout` (default 5 s; `0` disables undo) and then really closes with the §18.14 semantics.
  - `undo` restores the most recent unexpired entry. A split close is restored by putting back the saved `SplitTree` snapshot, only if the tab's current tree is identical (node-for-node) to the tree the close produced; otherwise the entry is dropped with a log line. Tab and window closes restore at the old index or position.
  - Undo of a create parks the created item; `redo` reverses the last undo.
  - Parked items are invisible to tmux, the tray, `goto_window`, the jump list and the last-window rule. `quit` closes parked items at once.
- **R-M5-13 `show_on_screen_keyboard`.** If `IFrameworkInputPane::Location` reports an empty rect, call `ITipInvocation::Toggle(GetDesktopWindow())`; never hide it. In test mode, only record.
- **R-M5-14 External tmux mode is opt-in.** `windows-tmux-external = false` by default. This needs an owner answer, because it relaxes M2 revision 2: a same-user process may then ask Ghostty to run a command.
  - When `true`, the primary instance claims a third pipe, `\\.\pipe\ghostty-tmux-<user SID>-<session>-<class>[-admin]`, with the same security as the M2 per-user pipe. It serves only `op: "tmux"` with a `namespace` field.
  - `tmux.exe` with `TMUX` unset connects there. `-L <name>` → namespace `<name>`; no `-L` → `default`. No server → `no server running on <path>`, exit 1. Ghostty is not auto-launched.
  - Each namespace maps to one Ghostty window created by `new-session -d` and shown without activation (`SW_SHOWNOACTIVATE`). Its tabs are the tmux windows, with names from `-n`.
  - Commands added: `has-session`, `new-session`, `new-window`, `kill-session`, `kill-server` (closes the namespace's windows without confirmation), plus `list-windows -F '#{window_name}'` and the `session:window-name` target form of recon §5.
  - Inside mode is unchanged.
  - `tmux.exe` is still only on PATH inside Ghostty sessions. External use needs the user to add the Ghostty dir to PATH (documented).

## Waves (parallelism)

≤ 3 tasks per wave. File sets inside a wave are strictly disjoint (checked against every `Files:` list and the hot-file chains below).

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 skeleton · 5 Explorer integration (`src/os`, CLI) · 7 compiled terminfo in the build | M4 W5 |
| W2 | 2 profile model + `--profile` · 6 shell integration (pwsh/cmd marks, MSYS env) · 8 `TERM=xterm-ghostty` | 1 (2); — (6); 1+7 (8) |
| W3 | 3 profile UI (`+` menu, palette, tray) · 10 update core (pure) · 12 crash dumps | 1+2 (3); 1 (10); 1+5 (12: `ops.crash_hook`, `src/os/main.zig`) |
| G1 | **Lead batch:** `E2E -Only profiles-menu,prompt-marks,term-terminfo,crash-dump,explorer-cli` (Debug), GUI smoke for Task 3 | 3, 5, 6, 8, 12 |
| W4 | 4 jump list + `+new-tab` fallback · 11 update fetch, toast, dialog, action · 13 secure input | 1+2 (4); 10 (11); 1 (13) |
| W5 | 9 `+edit-config` · 14 undo model (pure) · 16 on-screen keyboard | — (9); 1 (14); 1 (16) |
| G2 | **Lead batch:** `jumplist,update-check,secure-input,edit-config,osk`; GUI smoke for Task 13 | 4, 9, 11, 13, 16 |
| W6 | 15 undo integration · 17 external tmux transport · 18 external tmux commands | M4 accepted; 14 (15); 1 (17, 18) |
| G3 | **Lead:** Task 19 (full M5 run Debug + ReleaseFast, `E2E -Milestone all`, GUI smoke for Task 15), 19.n fixes | 15, 17, 18 |
| W7 | 20 RAM/latency rows, docs, SPEC, acceptance (alone) | 19.* |

Hot-file chains (every file touched by more than one task; a file not listed has a single owner):
- **Skeleton-only (Task 1):**
  - `src/apprt/win32.zig` (test imports), `pkg/win32/main.zig`, `src/apprt/win32/actions.zig`, `messages.zig`, `hooks.zig`, `App.zig`, `ipc/ops.zig`, `test/windows/e2e.ps1` (`ValidateSet` += `M5`).
  - Task 1 writes every shell with its final signature, and later tasks only fill them:
    - `profiles.zig` → 2; `profiles_menu.zig` → 3; `jumplist.zig` and `pkg/win32/shobjidl.zig` → 4;
    - `update/{release,state}.zig` → 10; `update/Updater.zig` and `pkg/win32/winhttp.zig` → 11;
    - `secure_input.zig` → 13; `undo.zig` → 14; `actions/undo_actions.zig` → 15;
    - `osk.zig` and `pkg/win32/tip.zig` → 16; `tmux/namespaces.zig` → 18.
- **Config:** `src/config/Config.zig` 1 → 8.
- **`src/os`:** `src/os/main.zig` 5 → 12. `windows_shell.zig` 2 only.
- **apprt:**
  - `Overrides.zig` 1 → 2; `strip_input.zig`, `CommandPalette.zig`, `tray.zig` 3 only; `notify.zig` 11 only; `badges.zig`, `clipboard.zig` 13 only.
  - `Tab.zig`, `Window.zig`, `actions/{tab,window,split}_actions.zig` 15 only.
  - `tmux/Server.zig`, `ipc/protocol.zig` 17 only; `tmux/commands.zig`, `tmux/FakeHost.zig`, `tmux/Registry.zig` 18 only.
  - `src/tmux_shim/{main,run,pipe}.zig` 17 only; `src/tmux_shim/cli.zig` 18 only.
- **tests/docs:** `test/windows/e2e/_common.ps1`: nobody (helpers live in each task's own `_m5_*.ps1` or scenario). `test/windows/README.md`, `docs/windows/{SPEC.md, feature-checklist.md, CHANGELOG.md, ram-baseline.csv, latency-baseline.csv}`: 20 (+ lead rulings).

Message and timer ids (`messages.zig`, Task 1):
- `WM_GHOSTTY_UPDATE_RESULT = WM_APP + 16` (lparam = heap `update.Result`, freed by the receiver).
- Toast click id `notify.update_click_id = maxInt(u32)` (no new message: it reuses `WM_GHOSTTY_NOTIFY_CLICK`).
- Message-window timers `update = 5`, `undo_expire = 6`, `jumplist_delay = 7`.
- `hooks.appMessage` chains them after `tmux_keys`.

---

### Task 1: M5 skeleton — module shells, ids, action routes, config keys, state fan-out

**Review:** light.

**Files:**
- Create (shells with a one-line `//!` naming the owner task and the final signatures below; bodies no-op/`false`/empty):
  - `src/apprt/win32/{profiles,profiles_menu,jumplist,secure_input,undo,osk}.zig`, `src/apprt/win32/actions/undo_actions.zig`;
  - `src/apprt/win32/update/{release,state,Updater}.zig`;
  - `src/apprt/win32/tmux/namespaces.zig`;
  - `pkg/win32/{shobjidl,winhttp,tip}.zig` (empty with a `test {}`).
- Modify:
  - `src/apprt/win32.zig` (test imports), `pkg/win32/main.zig` (exports);
  - `src/apprt/win32/actions.zig`: `check_for_updates`, `show_on_screen_keyboard`, `secure_input`, `undo`, `redo` become `.implemented` and route to `update.Updater.checkNow`, `osk.show`, `secure_input.perform`, `undo_actions.undo`, `undo_actions.redo`. The coverage test is updated to 1 deferred (`selection_changed`).
  - `messages.zig` (ids above);
  - `hooks.zig`: `appStarted` → `jumplist.schedule`, `Updater.start`, `secure_input.appStarted`; `appStopping` → `undo_actions.flushAll`, `Updater.stop`, `jumplist.stop`; `configChanged` → `jumplist.configChanged`, `Updater.configChanged`; `appMessage` → the timers and `WM_GHOSTTY_UPDATE_RESULT`; `testState` → sections `profiles`, `jumplist`, `update`, `secure_input`, `undo`, `osk`.
  - `App.zig`: fields `profiles: profiles.Cache = .{}`, `undo: undo_actions.State = .{}`, `update: Updater.State = .{}`, `secure: secure_input.State = .{}` and `parked_windows: std.ArrayList(*Window) = .empty` (Task 15 fills it; `App.windows` never holds a parked window). `deinit` closes the parked windows.
  - `ipc/ops.zig`: test op `crash` with `{"kind":"av"|"stack"|"panic"}` (test mode only) → calls `ops.crash_hook: ?*const fn ([]const u8) void = null`, answering code 1 `crash hook not installed` while it is null. Task 12 sets the hook from `src/main_ghostty.zig`; `src/os/main.zig` belongs to Tasks 5 → 12, so Task 1 does not import `windows_crash`.
  - `Overrides.zig`: the `profile` field, the `ProfileResolver` type and a no-op `resolve` (signatures in Task 2), and the calls to it: `ops.zig` new-window/new-tab call `resolve` after `parse` and map `error.UnknownProfile` to code 1 `unknown profile: <id>`; the launch path in `App.zig` calls it and on error logs one warning and keeps `Default`. `profiles.zig` gets `pub fn resolver(app: *App) Overrides.ProfileResolver`.
  - `src/config/Config.zig`: keys `windows-tmux-external: bool = false` and `windows-jump-list: bool = true` (both Windows only, doc comments next to `windows-tmux-shim`); Windows sentences in the docs of `auto-update`, `undo-timeout`, `macos-secure-input-indication`.
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
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // update/Updater.zig
  pub const State = struct { worker: ?std.Thread = null, last: ?Result = null, stopping: std.atomic.Value(bool) = .init(false) };   // Result: Task 11
  pub fn start(app: *App) void; pub fn stop(app: *App) void; pub fn configChanged(app: *App, config: *const Config) void;
  pub fn checkNow(app: *App, target: apprt.Target, value: void) !bool;
  pub fn onResult(app: *App, lparam: LPARAM) void; pub fn onTimer(app: *App) void;
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // secure_input.zig
  pub const State = struct { on: bool = false };
  pub fn perform(app: *App, target: apprt.Target, value: apprt.Action.SecureInput) !bool;
  pub fn appStarted(app: *App) void; pub fn windowCreated(window: *Window) void;
  pub fn copying(app: *App) bool;                                   // clipboard.zig asks
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  // undo.zig (pure model, Task 14)
  pub fn Stack(comptime Entry: type) type;                          // see Task 14
  // actions/undo_actions.zig
  pub const Entry = struct { kind: undo.Kind, expires_ms: u64, window: ?*Window, tab: ?*Tab, tree: ?Surface.Tree, index: usize };   // Task 15 may add fields
  pub const State = struct { stack: undo.Stack(Entry) = .{} };
  pub fn undo(app: *App, target: apprt.Target, value: void) !bool; pub fn redo(app: *App, target: apprt.Target, value: void) !bool;
  pub fn flushAll(app: *App) void; pub fn onTimer(app: *App) void;
  // osk.zig
  pub fn show(app: *App, target: apprt.Target, value: void) !bool; pub fn testState(app: *App, jw: *std.json.Stringify) !void;
  ```
- [ ] **Step 1: Failing test.** `"win32 actions: M5 actions are implemented"`: `status(.undo) == .implemented`, `status(.check_for_updates) == .implemented`, and the deferred count is 1.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 actions"` → FAIL.
- [ ] **Step 3: Implement** the shells, routes, ids, hooks, fields, keys and the e2e milestone.
- [ ] **Step 4: Verify** that filter passes; `"win32 messages"` passes; `LOCK ZIG build -j6` passes; `ZIG build test -Dtest-filter="config"` passes.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M5 skeleton — module shells, ids, action routes, config keys"`

### Task 2: Profile model and `--profile`

**Review:** opus (what another process may ask for, R-M5-2).

**Files:**
- Modify `src/os/windows_shell.zig`: `Profile`, `profiles`, the probe's Lxss reader.
- Modify (fill) `src/apprt/win32/profiles.zig`.
- Modify `src/apprt/win32/Overrides.zig`: parse `--profile=`, `forwardable`, fill `resolve` (Task 1 wrote the field, the type and the call sites).

**Interfaces:**
- Consumes: Task 1 `profiles.*` signatures.
- Produces:
  ```zig
  // windows_shell.zig
  pub const Profile = struct { id: []const u8, name: []const u8, kind: enum { default, git_bash, pwsh, powershell, cmd, wsl }, argv: []const [:0]const u8, icon: []const u8 };
  pub fn profiles(alloc: Allocator, env: *const std.process.Environ.Map, probe: Probe, default_argv: ?[]const [:0]const u8) ![]Profile;
  // Probe gains:  wslDistros: *const fn (ctx: ?*anyopaque, alloc: Allocator) []const WslDistro   (default first)
  pub const WslDistro = struct { name: []const u8, default: bool };
  // Overrides.zig
  profile: ?[:0]const u8 = null,                    // Task 1
  pub const ProfileResolver = struct { ctx: *anyopaque, commandFor: *const fn (ctx: *anyopaque, id: []const u8) ?configpkg.Command };   // Task 1
  pub fn resolve(self: *Overrides, arena: Allocator, r: ProfileResolver) error{ UnknownProfile, OutOfMemory }!void;
      // profile set and command null → command = the profile's (cloned into arena); command set → keep it, log "-e beats --profile"
      // `apply(config)` is unchanged: it already applies `command`.
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows shell profiles: order and ids"`: a fake probe with Git, pwsh, two distros (`Ubuntu` default, `Debian`) and `docker-desktop` → ids `default git-bash pwsh powershell cmd wsl:Ubuntu wsl:Debian`.
  - `"windows shell profiles: odd distro names skipped"`: `"a b"`, `"Ü"` and a 65-char name are skipped.
  - `"windows shell profiles: no git, no pwsh"` → `default powershell cmd`.
  - `"win32 overrides: --profile is forwardable"`: `{"--profile=pwsh","--working-directory=C:\\x"}` → true; `{"--profile=pwsh","-e","x"}` → false.
  - `"win32 overrides: unknown profile"`: `resolve` with a resolver returning null → `error.UnknownProfile`.
  - `"win32 overrides: -e beats --profile"`.
  - `"win32 overrides: working directory from Explorer"`: `--working-directory=C:\.`, `D:\a b\.` and `C:\Users\Анна\#x\.` → absolutised `C:\`, `D:\a b`, `C:\Users\Анна\#x`.
- [ ] **Step 2: Run** `-Dtest-filter="windows shell profiles"` and `"win32 overrides"` → FAIL.
- [ ] **Step 3: Implement.**
  - The real probe reads `HKCU\…\Lxss` with `RegGetValueW` (read-only, `KEY_READ`).
  - `profiles.resolver(app)` wraps `profiles.commandFor`. The call sites and the code-1 reply already exist (Task 1); `ops.zig` and `App.zig` are not edited.
- [ ] **Step 4: Verify** the filters pass; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): shell profiles (Git Bash, pwsh, Windows PowerShell, cmd, WSL) and --profile"`

### Task 3: Profile menu, palette entries, tray submenu

**Review:** light. **Lead GUI smoke before landing.**

**Files:** Modify (fill) `src/apprt/win32/profiles_menu.zig`; Modify `src/apprt/win32/strip_input.zig` (right-click on `.new_tab`), `src/apprt/win32/CommandPalette.zig` (profile items after the config entries), `src/apprt/win32/tray.zig` (submenu). Create `test/windows/e2e/profiles-menu.ps1`.

**Interfaces:**
- Consumes: `profiles.get/refresh` (Task 2), `Tab`/`Window` creation with `Overrides{ .profile = id }`.
- Produces: palette item titles exactly `New Tab: <name>` and `New Window: <name>`. Menu command ids `0x5000 + 2*i` (tab) and `0x5001 + 2*i` (window).
- [ ] **Step 1: Failing tests:**
  - `"win32 profiles menu: items and ids"`: pure `buildItems(profiles)` → labels, ids, and a separator before the "New Window" submenu.
  - `"win32 palette: profile entries follow config entries"`.
  - `"win32 tray: profile submenu ids do not collide"`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 profiles menu"`, `"win32 palette"` and `"win32 tray"` → FAIL.
- [ ] **Step 3: Implement.** The menu is `CreatePopupMenu` + `TrackPopupMenuEx(TPM_RETURNCMD)`, themed like `tab_menu.zig`, and runs from `WM_RBUTTONUP` on the strip, never inside `performAction`.
- [ ] **Step 4: Scenario** `profiles-menu.ps1` (M5):
  - opens 2 tabs; posts `WM_RBUTTONUP` to the `+` rect from `state.windows[0].strip.new_tab`, then, while the menu is open, selects the `Command Prompt` item with keyboard input to the menu (`Send-RealKeys` of its first letter + Enter). No test-only action is added;
  - asserts a third tab whose shell is `cmd.exe` (`Get-ShellProcess`);
  - repeats with the palette entry `New Tab: Windows PowerShell` → `powershell.exe`;
  - asserts that `state.profiles` lists the expected ids, and never selects a `wsl:` item;
  - saves `profiles-menu.png` (guarded capture).
- [ ] **Step 5: Verify** the filters pass, the scenario parses, `LOCK ZIG build -j6`. **Commit** `git commit -m "feat(win32): profile menu on the + button, palette and tray entries"`

### Task 4: Jump list and the `+new-tab` fallback

**Review:** opus (COM on a worker thread, lifetimes).

**Files:** Modify (fill) `pkg/win32/shobjidl.zig`: `ICustomDestinationList`, `IShellLinkW`, `IObjectCollection`, `IObjectArray`, `IPropertyStore`, `PKEY_Title`, `PKEY_AppUserModel_IsDestListSeparator`, `CLSID_DestinationList`, `CLSID_ShellLink`, `CLSID_EnumerableObjectCollection`, all with slot-count tests. Also fill `src/apprt/win32/jumplist.zig`. Modify `src/cli/new_tab.zig` (Windows fallback). Create `test/windows/e2e/jumplist.ps1`.

**Interfaces:**
- Consumes: `profiles.get`, `notify.aumid`.
- Produces:
  ```zig
  pub const Item = struct { kind: enum { task, profile }, title: []const u8, args: []const u8, icon_path: []const u8, icon_index: i32 };
  pub fn buildItems(alloc: Allocator, profiles: []const windows_shell.Profile) ![]Item;   // pure
  pub fn aumidForRun() [:0]const u16;   // notify.aumid, or the e2e AUMID in test mode
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 jumplist: tasks and profile links"`: args `""`, `"+new-tab"` and `"--profile=wsl:Ubuntu"`; the `Default` profile is absent.
  - `"win32 jumplist: args are quoted"`: a distro id needs no quoting (R-M5-1 charset) and the `+new-tab` args are verbatim.
  - `"windows cli new-tab: no instance starts the app"`: the decision function `fallbackArgv(exe, args)` → `{exe, "--working-directory=…", "--profile=…"}`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 jumplist"` and `"windows cli new-tab"` → FAIL.
- [ ] **Step 3: Implement.**
  - On `jumplist_delay` (2 s), a worker thread runs `CoInitializeEx(COINIT_APARTMENTTHREADED)`, `SetAppID(aumidForRun())`, `BeginList`, `AddUserTasks`, `AppendCategory("Profiles")`, `CommitList`, releases everything and posts nothing. It logs the HRESULTs and stores them in an atomic for `testState`.
  - `stop` joins the worker. In test mode `stop` also calls `DeleteList(e2e aumid)` and records the result.
  - The commit is skipped when `windows-jump-list = false` (which also calls `DeleteList` once) or when the process is not the pipe owner.
- [ ] **Step 4: Scenario** `jumplist.ps1`:
  - asserts `state.jumplist = {committed: true, hr: 0, items: [...]}` with the expected titles;
  - quits through the test `action` op and checks the exit log line `jumplist: deleted e2e list hr=0x0`;
  - runs `ghostty.exe +new-tab --class=<scenario class>` with no instance → a window appears; quit.
- [ ] **Step 5: Verify** filters, `LOCK ZIG build -j6`, scenario parses. **Commit** `git commit -m "feat(win32): taskbar jump list (new window, new tab, profiles); +new-tab starts Ghostty when none runs"`

### Task 5: Explorer "Open Ghostty here" (`src/os` + CLI)

**Review:** opus (registry writes, quoting).

**Files:** Create `src/os/windows_registry.zig` (root-injectable writer and reader, `RegLoadAppKeyW` test hive helper), `src/os/windows_explorer.zig` (pure key model), `src/cli/explorer_integration.zig`, `test/windows/e2e/explorer-cli.ps1`. Modify `src/os/main.zig`, `src/cli/ghostty.zig`.

**Interfaces:**
- Produces:
  ```zig
  // windows_explorer.zig — pure
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
  pub fn runInstall(alloc: Allocator) !u8; pub fn runUninstall(alloc: Allocator) !u8;   // --dry-run, --all (uninstall)
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows explorer: install writes"`: 9 writes (3 keys × default, Icon, command), exact values for `C:\Program Files\Ghostty\ghostty.exe`.
  - `"windows explorer: command line round-trips every %V shape"`: substitute `%V` with `C:\`, `C:\a b`, `D:\x#%'y`, `C:\Users\Анна`, a 300-char path and `\\srv\share\x`. Tokenise with `windows_cmdline` → `--working-directory=` + the input + `\.`, with the trailing quote never swallowed.
  - `"windows explorer: ownsCommand"`: a foreign `"C:\x\code.exe" "%V"` → false.
  - `"windows registry: app hive round trip"`: `openTestHive(<tmp>\t.hive)`, install writes, `getString`, uninstall, the keys are gone, and the hive file is deleted.
- [ ] **Step 2: Run** `-Dtest-filter="windows explorer"` and `"windows registry"` → FAIL.
- [ ] **Step 3: Implement.**
  - The CLI runs with `GHOSTTY_WIN32_TEST_HIVE` → root = that hive, else `HKEY_CURRENT_USER`.
  - `--dry-run` prints `set <subkey>\<name> = <value>` / `delete <subkey>`, one line each, and opens nothing.
  - `--all` (uninstall) also prints or deletes the AUMID key and `%LOCALAPPDATA%\ghostty\toast-icon.png`. No `win32` import and no COM.
  - On non-Windows targets both actions print `only supported on Windows` and exit 1.
  - Help text names the Windows 11 "Show more options" location.
- [ ] **Step 4: Scenario** `explorer-cli.ps1` (no window; implementer-run with `E2E -Only explorer-cli`):
  - `+install-explorer-integration --dry-run` output equals the expected 9 lines;
  - `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\x.hive` install then uninstall → exit 0 both;
  - asserts with `reg.exe query HKCU\Software\Classes\Directory\shell\GhosttyOpenHere` that the real key does not exist before and after (read-only).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): +install/+uninstall-explorer-integration (Open Ghostty here), sandboxed registry writer"`

### Task 6: Shell integration — pwsh/cmd prompt marks, MSYS env paths

**Review:** light.

**Files:** Modify `src/shell-integration/pwsh/ghostty.ps1`, `src/termio/shell_integration.zig` (`setupCmd`, `setupBash` Windows branch), `src/shell-integration/bash/ghostty.bash` (MSYS branch, only if Step 4 shows a gap). Create `test/windows/e2e/prompt-marks.ps1`.

**Interfaces:**
- Produces: `PROMPT` prefix exactly `$e]133;A$e\$e]2;$P$e\$e]7;kitty-shell-cwd:///$P$e\`, with `$e]133;B$e\` appended at the end. The env rewrite `fn msysPath(alloc, path) ![]u8` (backslash → slash, nothing else).
- [ ] **Step 1: Failing tests** (in `shell_integration.zig`):
  - `"windows: cmd prompt marks"`: the PROMPT has A first and B last; re-applying does not double them.
  - `"windows: bash on msys gets forward-slash paths"`: env `GHOSTTY_RESOURCES_DIR=C:\g\share\ghostty` → `C:/g/share/ghostty`, likewise `TERMINFO`/`GHOSTTY_BIN_DIR`; a non-Windows-path value is unchanged.
  - `"windows: pwsh integration script carries OSC 133"`: the embedded script text contains `]133;A`, `]133;B`, `]133;C`, `]133;D;` (a static check that stays green if the script is reformatted, by searching for the four markers).
- [ ] **Step 2: Run** `-Dtest-filter="windows: "` → FAIL.
- [ ] **Step 3: Implement** R-M5-6 and R-M5-8. pwsh: D comes from `$?`/`$LASTEXITCODE` captured first thing in `prompt`; C goes in the existing Enter handler; without PSReadLine there is no C/D, and A/B stay.
- [ ] **Step 4: Scenario** `prompt-marks.ps1`, for Git Bash, pwsh and cmd each:
  - run two commands (`echo a`, then a failing one: `false` / `cmd /c exit 3` / `exit /b 3` in a child `cmd /c`);
  - `jump_to_prompt:-1` via the test `action` op moves the viewport (`state` viewport row changes);
  - for bash and pwsh, `state.m3.notify` records `command_finished` with exit 3 when `notify-on-command-finish = always` is in the scenario config.
  - Debug log check: no `unknown OSC 133` lines.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(shell-integration): OSC 133 prompt marks for pwsh and cmd; forward-slash Ghostty paths for MSYS bash"`

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
  - Missing `tic`: `std.log.warn` once, source only.
  - Non-Windows targets are unchanged.
- [ ] **Step 3: Verify** `LOCK ZIG build -j6`; the infocmp command prints `xterm-ghostty|ghostty|Ghostty` and the `Smulx`/`Setulc` extended caps; `ls zig-out/share/terminfo` shows `78`. Also `LOCK ZIG build -j6 -Dtic=C:/nope/tic.exe` → build succeeds with the warning and no compiled entry.
- [ ] **Step 4: Commit** `git commit -m "build(windows): compile the xterm-ghostty terminfo with tic from Git for Windows"`

### Task 8: `TERM=xterm-ghostty` on Windows

**Review:** light.

**Files:** Modify `src/config/Config.zig` (`default_term` and its test), `src/termio/Exec.zig` (Windows-gated choice). Create `test/windows/e2e/term-terminfo.ps1`.

**Interfaces:**
- Produces: `fn windowsTerm(cfg_term: []const u8, terminfo_dir: ?[]const u8, argv0: []const u8, exists: *const fn ([]const u8) bool) struct { term: []const u8, terminfo: ?[]const u8 }` (pure, in Exec.zig, tested).
- [ ] **Step 1: Failing tests:**
  - `"windows config: TERM defaults to xterm-ghostty"` (replaces the M1 test).
  - `"Exec: windows TERM falls back without the compiled entry"`: exists → false → `xterm-256color`, no `TERMINFO`.
  - `"Exec: windows TERM keeps a user-set term"`: `term = foo` → `foo`.
  - `"Exec: wsl gets xterm-256color"`: argv0 `C:\Windows\System32\wsl.exe` and `c:/windows/sysnative/bash.exe` → `xterm-256color`.
  - `"Exec: windows TERMINFO points at the share dir"`.
- [ ] **Step 2: Run** `-Dtest-filter="windows config: TERM"` and `"Exec: w"` → FAIL.
- [ ] **Step 3: Implement.** The existence probe is `<resources>\..\terminfo\78\xterm-ghostty` or `x\xterm-ghostty`.
- [ ] **Step 4: Scenario** `term-terminfo.ps1`:
  - Git Bash: `echo $TERM`, `tput colors` (256), `tput Smulx` non-empty (skip if `tput` is missing), `vim -u NONE -c q` exits 0 with no `E558`;
  - pwsh: `$env:TERM` = `xterm-ghostty`;
  - asserts `TERMINFO` begins `C:/` in bash (Task 6's rewrite).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): TERM=xterm-ghostty when the compiled terminfo ships; WSL keeps xterm-256color"`

### Task 9: `+edit-config` on Windows

**Review:** light.

**Files:** Modify `src/cli/edit_config.zig`. Create `test/windows/e2e/edit-config.ps1`.

**Interfaces:**
- Produces: `fn windowsEditorArgv(alloc, exe: []const u8, visual: ?[]const u8, editor: ?[]const u8, path: []const u8, system_root: []const u8) ![]const []const u8` (pure). It returns the `{exe, "-e", tokens…, path}` or `{<root>\System32\notepad.exe, path}` argv.
- [ ] **Step 1: Failing tests:**
  - `"windows edit-config: VISUAL beats EDITOR"`.
  - `"windows edit-config: quoted editor path"`: `"C:\Program Files\Vim\vim.exe" -u NONE` → tokens kept, path last.
  - `"windows edit-config: no editor uses notepad"`.
  - `"windows edit-config: empty EDITOR counts as unset"`.
- [ ] **Step 2: Run** `-Dtest-filter="windows edit-config"` → FAIL.
- [ ] **Step 3: Implement.** Spawn detached (`std.process.spawn`, no wait, std handles closed), print the path, exit 0. The help text documents R-M5-8b.
- [ ] **Step 4: Scenario** `edit-config.ps1`:
  - `EDITOR=<sandbox>\fake-editor.cmd` (writes `%*` to a marker file), `XDG_CONFIG_HOME` sandboxed;
  - run `ghostty.exe +edit-config` with the scenario class in the env → the marker holds the sandbox config path;
  - the separate Ghostty closes after the script exits (`wait-after-command = false` in the sandbox config).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): +edit-config opens VISUAL/EDITOR in a new Ghostty, notepad otherwise"`

### Task 10: Update check — pure core (release JSON, versions, schedule, state file)

**Review:** light.

**Files:** Modify (fill) `src/apprt/win32/update/release.zig`, `src/apprt/win32/update/state.zig`. Create `src/apprt/win32/update/testdata/{newer,same,older,draft,prerelease,no-tag,bad-tag,foreign-url,html}.json`.

**Interfaces:**
- Produces:
  ```zig
  // release.zig
  pub const Release = struct { version: std.SemanticVersion, tag: []const u8, html_url: []const u8 };
  pub const ParseError = error{ NotJson, NoTag, BadVersion, Draft, Prerelease, ForeignUrl, OutOfMemory };
  pub fn parse(arena: Allocator, body: []const u8) ParseError!Release;            // validates html_url prefix
  pub const release_prefix = "https://github.com/Denmurzik/ghostty/releases/";
  pub const endpoint = "https://api.github.com/repos/Denmurzik/ghostty/releases/latest";
  pub fn isNewer(current: std.SemanticVersion, candidate: std.SemanticVersion) bool;  // build metadata ignored
  // state.zig
  pub const State = struct { last_check: i64 = 0, notified: ?[]const u8 = null };
  pub fn load(arena: Allocator, json: []const u8) State;                          // garbage → default
  pub fn save(w: *std.Io.Writer, s: State) !void;
  pub const Mode = enum { off, check };
  pub fn modeFor(cfg: ?configpkg.Config.AutoUpdate, debug: bool) Mode;           // R-M5-9
  pub fn due(s: State, now_s: i64) bool;                                          // ≥ 24 h
  pub fn shouldAnnounce(s: State, r: Release, current: std.SemanticVersion) bool;  // newer and not already notified
  ```
- [ ] **Step 1: Failing tests** `"win32 update: …"`, one per testdata file:
  - `newer` → Release `1.1.0`; `same`/`older` → not newer; `draft`/`prerelease`/`no-tag`/`bad-tag`/`foreign-url`/`html` → the matching error;
  - a leading `v` is stripped; `1.0.0+abc` = `1.0.0`; `1.0.0-rc.1` < `1.0.0`;
  - `modeFor(null,false) = check`, `modeFor(.download,false) = check`, `modeFor(null,true) = off`;
  - `due` at 23 h 59 m → false;
  - `shouldAnnounce` twice for the same version → false the second time;
  - a garbage state file → default.
- [ ] **Step 2: Run** `-Dtest-filter="win32 update"` → FAIL.
- [ ] **Step 3: Implement** with `std.json` (`.ignore_unknown_fields`), body length already capped by the caller.
- [ ] **Step 4: Verify**, **Commit** `git commit -m "feat(win32): update check core — release JSON, version compare, schedule and state"`

### Task 11: Update check — WinHTTP fetch, toast, dialog, `check_for_updates`

**Review:** opus (network, worker thread, untrusted input).

**Files:** Modify (fill) `pkg/win32/winhttp.zig` (the WinHTTP subset as function-pointer types for `GetProcAddress`), `src/apprt/win32/update/Updater.zig`; Modify `src/apprt/win32/notify.zig` (app-level toast with `update_click_id`, click → `Updater.openReleasePage`). Create `test/windows/e2e/update-check.ps1`, `test/windows/e2e/_m5_fakeserver.ps1`.

**Interfaces:**
- Consumes: Task 10 API; `dialogs.zig` (Windows 11 dialog, from `WM_GHOSTTY_POSTED_DIALOG`); `link.zig` open for the release page.
- Produces:
  ```zig
  pub const Result = struct { manual: bool, outcome: union(enum) { newer: release.Release, current, failed: []const u8 } };   // heap, posted
  pub fn fetch(arena: Allocator, url: []const u8, timeout_ms: u32, max_body: usize) ![]u8;   // worker only
  pub fn urlForRun(env_url: ?[]const u8, test_mode: bool) []const u8;                      // R-M5-9 override rule
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 update: url override only in test mode and only loopback http"`: `http://127.0.0.1:5000/x` accepted in test mode; `http://example.com/`, `https://127.0.0.1/`, `http://127.0.0.1.evil/` and anything outside test mode → the endpoint.
  - `"win32 update: result handling"`: a fake `Result` posted to `onResult` decides toast / dialog / nothing per manual × outcome, against a recorded-notification ring (test mode).
- [ ] **Step 2: Run** `-Dtest-filter="win32 update"` → FAIL.
- [ ] **Step 3: Implement.**
  - The worker thread is started per check and joined in `stop`.
  - `LoadLibraryExW("winhttp.dll", SYSTEM32)`, then `WinHttpOpen(…, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY)`, `WinHttpSetTimeouts` (10 s), and `WINHTTP_FLAG_SECURE` unless the override is http. The read loop is capped at 1 MiB.
  - Close all handles, `FreeLibrary`, post `WM_GHOSTTY_UPDATE_RESULT`.
  - The UI thread updates the state file (`%LOCALAPPDATA%\ghostty\update.json`, written atomically through a temp file + `MoveFileExW(REPLACE_EXISTING)`) and announces.
  - Timers: `update` fires at 60 s, then every 24 h.
- [ ] **Step 4: Scenario** `update-check.ps1`:
  - `_m5_fakeserver.ps1` serves `Start-FakeRelease -Body <file> -Status <code>` on `127.0.0.1:<free port>`.
  - The scenario runs Ghostty in test mode with `GHOSTTY_WIN32_UPDATE_URL`.
  - Cases (`check_for_updates` via the test `action` op):
    - `newer.json` → `state.update.last = newer 1.1.0`, one recorded toast; a second check → no second toast; the manual dialog (`GhosttyDialog` class) shows, is dismissed with `WM_USER + 102`.
    - `same.json` → "up to date" dialog.
    - `html.json` with 200 → `failed`, no toast.
    - Status 403 → `failed`.
    - Server stopped → `failed` within 11 s.
  - Finally asserts that the scenario process made no connection other than to the loopback port (`Get-NetTCPConnection -OwningProcess <ghostty pid>` shows only `127.0.0.1`).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): update check via WinHTTP with a toast for new releases and check_for_updates"`

### Task 12: Crash minidumps

**Review:** opus (crash path, threads).

**Files:** Create `src/os/windows_crash.zig`, `test/windows/e2e/crash-dump.ps1`. Modify:
- `src/os/main.zig` (export);
- `src/main_ghostty.zig`: `windows_crash.install(...)` first on Windows, and on the win32 runtime `ops.crash_hook = windows_crash.testCrash` (the op itself answers only in test mode);
- `src/main.zig` (panic → `windows_crash.dumpNow()`);
- `src/crash/dir.zig` (`.dmp`).

**Interfaces:**
- Produces:
  ```zig
  pub fn install(local_app_data: []const u8) void;     // idempotent; failures logged, never fatal
  pub fn dumpNow() void;                               // from the panic path, no exception record
  pub fn testCrash(kind: []const u8) void;             // "av" | "stack" | "panic"; only reached through the test op
  pub fn pruneKeep(alloc: Allocator, dir: []const u8, keep: usize) !usize;      // pure-ish, tested on a tmp dir
  pub fn dumpPath(buf: []u16, prefix: []const u16, tick: u64) [:0]const u16;    // pure
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows crash: dump path"`;
  - `"windows crash: prune keeps the 10 newest"` (tmp dir with 13 files, mtimes set);
  - `"windows crash: install twice is a no-op"`;
  - `"crash dir: windows lists .dmp"` (`src/crash/dir.zig`).
- [ ] **Step 2: Run** `-Dtest-filter="windows crash"` and `"crash dir"` → FAIL.
- [ ] **Step 3: Implement** R-M5-10.
  - `dbghelp.dll` loads in the dump thread at first need (`LOAD_LIBRARY_SEARCH_SYSTEM32`).
  - The filter uses no allocator and no locks except the one `InterlockedCompareExchange` gate; a second crashing thread waits on the done event.
  - One log line through `windows_log` after the dump: `crash dump written to <path>`. The log sink's mutex is skipped if held: `tryLock`.
- [ ] **Step 4: Scenario** `crash-dump.ps1`:
  - Cases `av` and `stack` via the `crash` test op → the process exits ≤ 15 s; exactly one new `.dmp` in `<sandbox LOCALAPPDATA>\ghostty\crash`; size > 0 and < 64 MB; no `WerFault.exe` child or window.
  - `ghostty.exe +crash-report` with the sandbox env lists it.
  - Dumps deleted at the end.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(windows): crash minidumps in %LOCALAPPDATA%\\ghostty\\crash; +crash-report lists them"`

### Task 13: `secure_input` analog

**Review:** light. **Lead GUI smoke before landing.**

**Files:** Modify (fill) `src/apprt/win32/secure_input.zig`. Modify `src/apprt/win32/badges.zig` (lock badge, macOS geometry from `SecureInputOverlay.swift`), `src/apprt/win32/clipboard.zig` (the three formats when `secure_input.copying`). Create `test/windows/e2e/secure-input.ps1`.

- [ ] **Step 1: Failing tests:**
  - `"win32 secure input: toggle state machine"` (`on`, `off`, `toggle` × start state);
  - `"win32 secure input: badge geometry"` (25 DIP + 2×5 padding, 10 DIP inset at 96/144/192 dpi);
  - `"win32 clipboard: secure copy adds exclusion formats"` (format list builder, pure).
- [ ] **Step 2: Run** `-Dtest-filter="win32 secure input"` and `"win32 clipboard"` → FAIL.
- [ ] **Step 3: Implement** R-M5-11. `windowCreated` applies the affinity to new windows while on. The badge click → explainer dialog (posted).
- [ ] **Step 4: Scenario** `secure-input.ps1`:
  - `toggle_secure_input` via the test `action` op → `state.secure_input = {on: true, affinity: 0x11}` for every window, and the badge visible in `state` badges;
  - copy a selection → `state` clipboard formats include `ExcludeClipboardContentFromMonitorProcessing` (read via a test helper that lists formats, no content);
  - toggle off → affinity 0;
  - one guarded capture **after** turning it off (`secure-badge-off.png`). The badge-on evidence is the `state` op plus a frame dump (`Wait-Dump`; the dump comes from the renderer, so affinity does not black it out).
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): secure input analog — capture exclusion, clipboard history exclusion, lock badge"`

### Task 14: Undo stack (pure model)

**Review:** light.

**Files:** Modify (fill) `src/apprt/win32/undo.zig`.

**Interfaces:**
- Produces:
  ```zig
  pub fn Stack(comptime Entry: type) type {   // Entry: { kind: Kind, expires_ms: u64, ... payload }
      return struct {
          pub fn push(self: *@This(), gpa: Allocator, e: Entry) !void;          // clears redo
          pub fn popUndo(self: *@This(), now_ms: u64) ?Entry;                   // skips and returns-nothing for expired
          pub fn pushRedo(self: *@This(), gpa: Allocator, e: Entry) !void;
          pub fn popRedo(self: *@This(), now_ms: u64) ?Entry;
          pub fn takeExpired(self: *@This(), now_ms: u64, out: *std.ArrayList(Entry), gpa: Allocator) !void;
          pub fn takeAll(self: *@This(), out: *std.ArrayList(Entry), gpa: Allocator) !void;   // quit
          pub fn nextExpiry(self: *const @This()) ?u64;                         // timer scheduling
      };
  }
  pub const Kind = enum { close_tab, close_window, close_split, new_tab, new_window, new_split };
  ```
- [ ] **Step 1: Failing tests** `"win32 undo: …"`:
  - LIFO order;
  - a push clears redo;
  - an expired entry is never returned and lands in `takeExpired`;
  - `nextExpiry` is the minimum;
  - `takeAll` empties both stacks;
  - a timeout of 0 means entries are pushed already expired (the caller closes at once).
- [ ] **Step 2–4:** Run → FAIL; implement; run → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): undo/redo stack with expiry"`

### Task 15: Undo/redo integration — park and restore tabs, windows, splits

**Review:** opus (process lifetime, HWND ownership). **Lead GUI smoke before landing.**

**Files:** Modify (fill) `src/apprt/win32/actions/undo_actions.zig`; Modify `src/apprt/win32/Tab.zig` (`park`/`unpark` of a tab container, tree snapshot/restore), `src/apprt/win32/Window.zig` (`park`/`unpark` window, exclusion from counts), `src/apprt/win32/actions/tab_actions.zig`, `window_actions.zig`, `split_actions.zig` (register entries on user-initiated close/create). Create `test/windows/e2e/undo-close.ps1`.

**Interfaces:**
- Consumes: Task 14 `Stack`; config `undo-timeout`.
- Produces: `Window.parked: bool`, `Tab.parked: bool`. Every enumerator that counts or lists windows/tabs/panes (tray, `goto_window`, the quit rule, the tmux `Registry` lookups, the jump list, `state`) skips parked items. `state` reports `parked` counts.
  - The tmux files are M4's and are not edited. `Registry` lookups go through `App.windows`, where a parked window is moved into `App.parked_windows` (a separate list, so the M4 code needs no change). Parked tabs leave `Window.tabs` for `Window.parked_tabs`.
- [ ] **Step 1: Failing tests** `"win32 undo: …"` with headless windows (the M2 test-window helpers):
  - `close tab then undo restores index and title`;
  - `close split then undo restores the exact tree`;
  - `undo after a later split change drops the entry`;
  - `new tab then undo parks it, redo restores`;
  - `expiry closes for real` (the surface's `deinit` ran, the process-kill path called);
  - `quit flushes parked`;
  - `tmux kill-pane is not undoable` (a close with origin `.tmux` pushes nothing);
  - `undo-timeout 0 disables`.
- [ ] **Step 2: Run** `-Dtest-filter="win32 undo"` → FAIL.
- [ ] **Step 3: Implement** R-M5-12.
  - Each close/create path gets an `origin: enum { user, tmux, ipc, child_exit }` parameter. Only `.user` pushes an entry.
  - The `undo_expire` timer is set to `nextExpiry`.
- [ ] **Step 4: Scenario** `undo-close.ps1`:
  - Git Bash tab running `sleep 30`;
  - close the tab (test action) → `state.parked.tabs = 1` and the `sleep` process is alive;
  - `undo` within 2 s → the tab is back with the same `Surface.id` and the process the same pid;
  - close again and wait 6 s → the process is gone (`Get-ProcessTree`);
  - split → close split → undo → 2 leaves; window close → undo → the window is back at the same rect.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): undo/redo for closing and creating tabs, windows and splits (undo-timeout)"`

### Task 16: On-screen keyboard

**Review:** light.

**Files:** Modify (fill) `pkg/win32/tip.zig` (`ITipInvocation`, `IFrameworkInputPane`, CLSIDs, slot tests), `src/apprt/win32/osk.zig`. Create `test/windows/e2e/osk.ps1`.

- [ ] **Step 1: Failing tests:** `"win32 osk: decision"`: an empty rect → toggle; a non-empty rect → nothing; test mode → record only.
- [ ] **Step 2–3:** Run → FAIL; implement R-M5-13 (COM on the UI thread, which is already STA for OLE drops).
- [ ] **Step 4: Scenario** `osk.ps1`: `show_on_screen_keyboard` via the test `action` op → `state.osk.requests = 1` and no `TextInputHost` window change.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(win32): show_on_screen_keyboard opens the touch keyboard"`

### Task 17: External tmux mode — transport and opt-in pipe

**Review:** opus (pipe security, R-M5-14).

**Files:** Modify `src/apprt/win32/ipc/protocol.zig` (`namespace: ?[]const u8` on `op: "tmux"`; `tmuxUserPipeName(sid, session, class, admin)`), `src/apprt/win32/tmux/Server.zig` (claim the third pipe when `windows-tmux-external` is true; release on reload to false), `src/tmux_shim/{main,run,pipe}.zig` (`TMUX` unset → user pipe; `-L`). Create `test/windows/e2e/tmux-external.ps1`.

**Interfaces:**
- Consumes: M4 `ipc.Server` instance fields (`post_tag` 1, the tmux limits); the M2 per-user pipe security (`instance.claim`).
- Produces: a request on the user pipe carries `namespace` (non-null); a request on the per-process pipe never does (the server drops a non-null one with code 2). `commands.Context.namespace: ?[]const u8` is consumed by Task 18.
- [ ] **Step 1: Failing tests:**
  - `"tmux shim external: pipe name"` (class sanitising and `-admin` as in the M2 name);
  - `"tmux shim external: -L sets the namespace, no -L is default"`;
  - `"tmux shim external: TMUX set ignores -L for the pipe"` (inside mode wins; `-L` is passed through as the namespace and ignored by inside commands);
  - `"win32 tmux: per-process pipe refuses a namespace"`.
- [ ] **Step 2: Run** `-Dtest-filter="tmux shim external"` and `"win32 tmux"` → FAIL.
- [ ] **Step 3: Implement.** The shim never launches Ghostty. The server claims the pipe only in the primary instance and only when the key is true.
- [ ] **Step 4: Scenario** `tmux-external.ps1`:
  - with `windows-tmux-external = true` in the sandbox config, `tmux.exe -L claude-swarm-1 has-session -t claude-swarm` (TMUX removed by `Invoke-Tmux`) → exit 1 `can't find session: claude-swarm`;
  - with the key false → `no server running on …`, exit 1.
  - Full sequence: Task 18 adds its own steps here after it lands. This file is Task 17's; Task 18 appends in W6 only after 17 has landed, so they are serialised.
- [ ] **Step 5: Verify**, **Commit** `git commit -m "feat(tmux): opt-in external mode pipe (TMUX unset, -L namespaces)"`

### Task 18: External tmux mode — sessions, windows by name, replay of recon §5

**Review:** opus.

**Files:** Modify (fill) `src/apprt/win32/tmux/namespaces.zig`; Modify `src/tmux_shim/cli.zig` (accept `has-session new-session new-window kill-session kill-server` in external mode; `-s -n -A -d -x -y` templates per tmux 3.5a), `src/apprt/win32/tmux/commands.zig`, `tmux/FakeHost.zig`, `tmux/Registry.zig`. Create `src/apprt/win32/tmux/testdata/claude-external.jsonl` (hand-written from recon §5 rows, ids `%1…`).

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
- [ ] **Step 4:** Append to `tmux-external.ps1` the fake-teammate run of the fixture's argv: a new window appears without activation (`GetForegroundWindow` unchanged), 3 panes, and `kill-server` closes it.
- [ ] **Step 5: Verify** (also `-Dtest-filter="win32 tmux "` for M4 regressions), **Commit** `git commit -m "feat(tmux): external mode sessions and named windows (Claude Code without TMUX)"`

### Task 19: M5 end-to-end run (lead) and 19.n fixes

**Files:** none planned; bug notes only. Each 19.n touches exactly the files its note names (≤ 3 in flight, disjoint).

- [ ] **Step 1:** In order:
  - `LOCK ZIG build -j6`, then `E2E -Milestone M5` (Debug).
  - The ReleaseFast build `--prefix zig-out-rf` with `GHOSTTY_E2E_EXE`, then `E2E -Milestone M5`.
  - `E2E -Milestone all` once (TERM change, close paths, tray).
  - GUI smoke for Task 15 (close/undo by hand-driven test actions; one guarded screenshot).
- [ ] **Step 2:** For every FAIL, a bug note: scenario, build, symptom, log excerpt, evidence path. Unit counts: `-Dtest-filter="win32 "` 3× in a row, `"windows "`, `"tmux shim "`, `"Exec: w"`.
- [ ] **Step 3 (19.n template):** reproduce; a pure-logic bug gets a failing unit test first; fix; the lead re-runs the scenario in the next batch; commit `git commit -m "fix(win32): <bug summary>"`.

### Task 20: RAM and latency rows, docs, SPEC, M5 acceptance

**Review:** lead.

**Files:** Modify:
- `docs/windows/ram-baseline.csv`, `docs/windows/latency-baseline.csv`;
- `docs/windows/feature-checklist.md`: rows for each M5 feature, plus the shell-integration row → done or gap;
- `docs/windows/CHANGELOG.md`: M5 section, the keys `windows-jump-list` and `windows-tmux-external`, and the gaps:
  - classic context menu only;
  - no auto secure input;
  - cmd has no C/D marks;
  - `TERM` over ssh to hosts without the entry;
  - external tmux needs PATH;
  - undo is not offered for tmux/IPC closes;
- `test/windows/README.md`: M5 scenarios and the safety rules above;
- `docs/windows/SPEC.md`: §8.5 / §10 as built; §13 key names and command line (R-M5-5); §12.1/§12.4 external mode (R-M5-14); §11 crash (R-M5-10); §17 M5 done with the commit; §18 rulings R-M5-1…14.
- [ ] **Step 1: RAM rows** per § RAM budget (median of 3). Over → DONE_WITH_CONCERNS with numbers; the owner decides.
- [ ] **Step 2: Latency and startup rows** per § Latency budget.
- [ ] **Step 3:** `dumpbin /imports zig-out-rf\bin\ghostty.exe` → no `winhttp.dll`, no `dbghelp.dll`. Record.
- [ ] **Step 4:** ARM64 cross-build `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j6` → record.
- [ ] **Step 5:** Record the exit checklist. Commit `git commit -m "docs(windows): M5 acceptance — Windows extras"`.

## M5 exit checklist

1. **Builds and unit tests.** Debug and ReleaseFast build, both with the compiled terminfo installed. These pass: `-Dtest-filter="win32 "` 3× in a row; `"windows "`; `"tmux shim "`; `"Exec: w"`; `"crash dir"`; `test-tmux-shim`. `-Demit-lib-vt` and the Linux recipe build. ARM64 compiles (recorded).
2. **e2e.** `E2E -Milestone M5` is green on Debug and ReleaseFast: `profiles-menu`, `jumplist`, `explorer-cli`, `prompt-marks`, `term-terminfo`, `edit-config`, `update-check`, `crash-dump`, `secure-input`, `undo-close`, `osk`, `tmux-external`. `E2E -Milestone all` has no new failures.
3. **Every M5 feature has evidence.** A unit test plus a scenario or a scripted screenshot (SPEC §17). The update check passed against the fake release JSON (Task 11).
4. **Budgets.** RAM rows within § RAM budget, key echo within +0.5 ms of M4, startup within +10 ms. `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll`.
5. **Owner safety.** No scenario wrote the real registry (`explorer-cli` asserts it); no test made a non-loopback connection (`update-check` asserts it); no WSL distro was started.
6. **Feature checklist.** Every M5 row is `done`, `manual` or a documented gap; the shell-integration row is closed.
7. **SPEC.** §17 M5 marked done; §18 has R-M5-1…14; §8.5, §10, §11, §12, §13 amended.
8. **Owner manual checklist** (PASS/FAIL per line):
   - `ghostty.exe +install-explorer-integration`; right-click a folder, a folder background and `C:\` → "Show more options" → "Open Ghostty here" opens there; `+uninstall-explorer-integration --all` removes everything.
   - Right-click the pinned taskbar icon: the jump list shows New Window, New Tab and the profiles; a WSL profile opens the distro.
   - Right-click `+` → pwsh and a WSL distro open; the palette entries work with one tab.
   - A real update toast against a test release (or `auto-update = off` respected); its click opens the release page.
   - Secure input on: OBS or Snipping Tool shows the window black; a copy does not appear in Win+V history.
   - Undo after closing a tab by mistake (Ctrl+Z binding of the owner's choice) brings it back with its shell.
   - The touch keyboard appears on a touch or tablet-mode machine (or N/A).
   - `vim`, `less`, `htop` (WSL keeps `xterm-256color`) look right with `TERM=xterm-ghostty` in Git Bash.
   - With `windows-tmux-external = true` and the Ghostty dir on PATH, Claude Code started in Windows Terminal opens its teammates in a Ghostty window.
9. **Changelog** with the keys and the gaps of Task 20.

## Self-review

- **Spec coverage:**

  | Requirement | Tasks |
  |---|---|
  | Jump lists (new window/tab, profiles) | 4 (R-M5-4), 2 |
  | Shell-profiles dropdown incl. WSL distros | 2 (R-M5-1: registry instead of `wsl.exe -l -q`), 3 |
  | Explorer "Open Ghostty here" + installer | 5 (installer keys handed to M6 via SPEC §13) |
  | pwsh integration (OSC 133/7/title) | 6 (133); 7/title done in M1/M3 |
  | Git Bash integration fixes | 6 (MSYS env paths, marks verified), 8 (`TERMINFO`) |
  | OSC 7 translation | done (M3 29.1) |
  | Compiled terminfo + `TERM=xterm-ghostty` | 7, 8 |
  | `+edit-config` | 9 |
  | Update check (`auto-update`, WinHTTP, toast) | 10, 11 |
  | Crash minidumps | 12 |
  | External tmux mode, `claude-swarm` namespace | 17, 18 |
  | `secure_input`, `undo`/`redo` analogs | 13, 14, 15 |
  | On-screen keyboard | 16 |
  | §8.4 ConPTY flags | closed by L1 (§18.33) |
  | §10 MSYS forward slashes | 6 |
  | Exit: test or screenshot per feature; fake release JSON | every task; 11 |
- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | shells, `win32.zig`, `pkg/win32/main.zig`, `actions.zig`, `messages.zig`, `hooks.zig`, `App.zig`, `ops.zig`, `Overrides.zig`, `Config.zig`, `e2e.ps1` |
  | W1 | 5 | `windows_registry.zig`, `windows_explorer.zig`, `src/os/main.zig`, `src/cli/{ghostty,explorer_integration}.zig`, `explorer-cli.ps1` |
  | W1 | 7 | `GhosttyResources.zig`, `src/build/Config.zig` |
  | W2 | 2 | `windows_shell.zig`, `profiles.zig`, `Overrides.zig` |
  | W2 | 6 | `shell_integration.zig`, `ghostty.ps1`, `ghostty.bash`, `prompt-marks.ps1` |
  | W2 | 8 | `Config.zig`, `Exec.zig`, `term-terminfo.ps1` |
  | W3 | 3 | `profiles_menu.zig`, `strip_input.zig`, `CommandPalette.zig`, `tray.zig`, `profiles-menu.ps1` |
  | W3 | 10 | `update/{release,state}.zig`, testdata |
  | W3 | 12 | `windows_crash.zig`, `src/os/main.zig`, `main_ghostty.zig`, `main.zig`, `crash/dir.zig`, `crash-dump.ps1` |
  | W4 | 4 | `shobjidl.zig`, `jumplist.zig`, `new_tab.zig`, `jumplist.ps1` |
  | W4 | 11 | `winhttp.zig`, `Updater.zig`, `notify.zig`, `update-check.ps1`, `_m5_fakeserver.ps1` |
  | W4 | 13 | `secure_input.zig`, `badges.zig`, `clipboard.zig`, `secure-input.ps1` |
  | W5 | 9 | `edit_config.zig`, `edit-config.ps1` |
  | W5 | 14 | `undo.zig` |
  | W5 | 16 | `tip.zig`, `osk.zig`, `osk.ps1` |
  | W6 | 15 | `undo_actions.zig`, `Tab.zig`, `Window.zig`, `actions/{tab,window,split}_actions.zig`, `undo-close.ps1` |
  | W6 | 17 | `protocol.zig`, `tmux/Server.zig`, `tmux_shim/{main,run,pipe}.zig`, `tmux-external.ps1` |
  | W6 | 18 | `namespaces.zig`, `tmux_shim/cli.zig`, `tmux/{commands,FakeHost,Registry}.zig`, testdata (+ `tmux-external.ps1` after 17 lands) |

  `Config.zig` (1 → 8) and `src/os/main.zig` (5 → 12) are in different waves. No file appears in two tasks of one wave, except `tmux-external.ps1` (17 → 18), which is serialised.
- **Type names defined once:**

  | Task | Names |
  |---|---|
  | 1 | all shell signatures; `ops.crash_hook` |
  | 2 | `windows_shell.{Profile,WslDistro,profiles}`, `Overrides.{profile,ProfileResolver}` |
  | 4 | `jumplist.{Item,buildItems,aumidForRun}` |
  | 5 | `windows_explorer.*`, `windows_registry.*` |
  | 8 | `windowsTerm` |
  | 9 | `windowsEditorArgv` |
  | 10 | `release.*`, `state.*` |
  | 11 | `Updater.{Result,fetch,urlForRun}` |
  | 12 | `windows_crash.*` |
  | 14 | `undo.{Stack,Kind}` |
  | 18 | `namespaces.*` |
- **Review Focus → tests:** 1 → Tasks 5, 2; 2 → Task 8; 3 → Tasks 10, 11; 4 → Tasks 14, 15; 5 → Task 12.
- **Proportion:** the code blocks are signatures and test names only.

### Open questions → recommended answers (lead/owner)

1. *`auto-update` default on Windows?* → `check` (DECISIONS lists the update check as a feature). Daily, a single anonymous GET; `off` is one line.
2. *External tmux mode on by default?* → **off** (`windows-tmux-external = false`). It relaxes M2 revision 2, and it only matters with the Ghostty dir on PATH.
3. *Profile menu trigger?* → right-click on `+`, plus palette and tray entries; the macOS look stays. The alternative is a Windows Terminal chevron next to `+`.
4. *`+edit-config` with `EDITOR` set?* → a new Ghostty window running the editor, because a GUI exe cannot share the caller's console.
5. *AUMID self-registration* (R-M3-5) *stays implicit?* → yes, with the full revert `+uninstall-explorer-integration --all`. Making it opt-in would cost toasts for portable users.
