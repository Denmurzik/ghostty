# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## GUI scripts and the safety harness

Scripts that start Ghostty, send input, switch keyboard layouts or capture
windows run on a real desktop, so they all import `lib/Harness.psm1`:

- `Invoke-GuiScenario -Name <n> -ScriptBlock {...}` prints and records
  `PASS|FAIL <n>` or `SKIP <n>: <reason>` in `%TEMP%\ghostty-e2e\results.txt`.
  A locked, non-interactive or foreground-less session is a SKIP, never a
  FAIL.
- `Save-KeyboardLayouts` / `Restore-KeyboardLayouts` diff
  `GetKeyboardLayoutList`: only layouts added during the run are unloaded
  and the original layout is re-activated. `Invoke-GuiScenario` does this
  around every scenario.
- `Stop-OwnGhostty` kills only the processes registered by this run
  (`launch.ps1` registers its own), and their children.
- `Set-ForegroundSafe -Hwnd` and `Switch-GhosttyLayout -Hwnd -Klid` are the
  only sanctioned ways to take focus and change layouts.

### The desktop lock (one GUI run at a time)

Ghostty windows take the foreground and the keyboard layout, which breaks any
other GUI test running on the same desktop. Every GUI run therefore holds
`%TEMP%\gui-e2e.lock` while it uses the desktop. Any session (Claude or
human) that starts windows or sends input must follow this protocol:

- **Acquire** atomically: create the file with `CreateNew` and no sharing
  (`[IO.File]::Open($path, 'CreateNew', 'Write', 'None')`). If that throws an
  `IOException`, someone holds it: wait (poll every few seconds) and try
  again; give up after about 30 minutes.
- **Format**: text lines `id=<GUID>`, `pid=<pid of the holder>`,
  `owner=<free text>`, `time=<ISO time>`.
- **Stale rule**: the lock is stale, and may be deleted by a waiter, when the
  file has not been written for 20 minutes or the `pid` process is gone.
  Holders running longer than a few minutes rewrite the file (new `time`)
  between steps. The test runner does this between scenarios.
- **Release**: delete the file only if it still contains your own `id`.
- Acquire immediately before the `try` whose `finally` releases it.

`Enter-GuiLock`, `Update-GuiLock` and `Exit-GuiLock` in `lib/Harness.psm1`
implement this; `Invoke-GuiScenario` takes the lock itself (a held lock is a
SKIP after the wait). `e2e.ps1` takes it once for the whole run and hands
its id to the scenarios in `GHOSTTY_E2E_LOCK_ID`, so they do not wait on it.

### The e2e runner and scenario headers

```
powershell -NoProfile -File test/windows/e2e.ps1 -Milestone M1 [-Only a,b] [-EvidenceDir d]
```

`e2e.ps1` discovers `e2e/*.ps1` (scripts starting with `_` are helpers). The
first `# e2e:` line of the leading comment block is the header:

```
# e2e: milestone=M1 timeout=150 order=30 [surfaces=N]
```

Scenarios run in `order`; `timeout` (seconds) kills the scenario and its
process tree. `surfaces` > 4 makes the runner check `Assert-FreeRam 2.5`
first (SKIP when less is free) and, for a Debug exe, run the scenario under
the team's `test-lock` (`GHOSTTY_TEST_LOCK` overrides its path). Exit code:
`0` no FAIL and at least one PASS, `1` any FAIL, `2` every scenario SKIPped.
`e2e-m1.ps1` is `e2e.ps1 -Milestone M1`.

Every `Start-E2eGhostty` writes its config through `New-GhosttyConfigText`
(`lib/Harness.psm1`), which always adds `class = ghostty-e2e-<8 hex>` (also
`$G.Class`): a test instance has an identity of its own and cannot reach
another instance or the owner's. It also adds
`quit-after-last-window-closed = true` (`-KeepDefaultQuit` omits it), sets
`GHOSTTY_WIN32_TEST_IPC=1` (`-NoTestIpc` omits it), and finds the window
by class `GhosttyWindow` plus pid. Frame dumps are
`surface-<surface id>.bmp` (`$G.Dump` is surface 1, `Get-DumpPath $G <id>`).
A frame of the same size within 250 ms of the last dump may be skipped (an
idle terminal draws no further frame), so a scenario that needs a final
frame waits at least 250 ms and triggers a repaint; a new size is always
dumped. The class also goes on the command line (`--class=<class>`), even
with `-NoConfig`, and `Start-E2eGhostty` checks the process command line.

### launch.ps1

```
zig build
powershell -NoProfile -File test/windows/launch.ps1 -Config test/windows/configs/cmd.ghostty
```

Copies the config to a temporary `XDG_CONFIG_HOME` (the user's real config
is never read), optionally sets `GHOSTTY_D3D11_DRIVER` (`-Driver warp`) and
`GHOSTTY_D3D11_DUMP` (`-DumpDir <dir>`), starts `zig-out\bin\ghostty.exe`,
waits up to 10 s for its main window and prints `pid=<n> hwnd=<0x...>`.
Run standalone, the process keeps running: stop it yourself.

`configs/cmd.ghostty` runs `cmd.exe` directly, which makes the child
process easy to find with
`Get-CimInstance Win32_Process -Filter 'ParentProcessId=<pid>'`.

### Timing-sensitive scenarios: use a ReleaseFast exe

`resize-while-streaming` (and any scenario with a response-time limit)
gets its acceptance timing from a **ReleaseFast** build:

```
zig build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf
$env:GHOSTTY_E2E_EXE = "$PWD\zig-out-rf\bin\ghostty.exe"
powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only resize-while-streaming
```

A Debug build is reference only. Upstream's `slow_runtime_safety`
(`Page.assertIntegrity`) makes terminal parsing orders of magnitude slower
there, so the terminal lock is held much longer and the UI thread (mouse
callbacks wait for that lock) answers slowly. Measured: ReleaseFast
200 resizes in under 1 s with WM_NULL answered in 1-3 ms; Debug 10-30 s and
WM_NULL answers of 0.6-1.5 s.

### stream-integrity: is every byte of a large output kept?

`e2e/stream-integrity.ps1` checks the whole output path (ConPTY, the pty
read thread, the VT parser, the scrollback) with what the terminal really
holds, not with pixels:

1. `e2e/_stream.ps1` (`New-CheckedStream`) writes a file of numbered lines
   (`00000042 <printable ASCII payload> <CRC-32>`, at most 78 characters,
   line `i` is a function of `i` alone) into the sandbox `TEMP`:
   50 MB by default, `GHOSTTY_E2E_STREAM_MB` to change it.
2. Git Bash writes it to the terminal with `cmd //c type`, then prints an
   end marker.
3. `ctrl+shift+f12` is bound to `write_screen_file:paste`
   (`configs/stream-integrity.ghostty`, with `scrollback-limit-bytes =
   unlimited`): Ghostty writes the screen and scrollback as plain text to a
   `screen.txt` in the sandbox `TEMP`.
4. `Test-CheckedStream` regenerates every line and reports each missing,
   changed or extra line with its line number and the first column that
   differs; any of them, or a missing end marker, FAILs.

The throughput is reported as an INFO line; it is the writer's (`type`
writes slowly, about 1 MB/s) rather than the terminal's. Run it on a
ReleaseFast build (a Debug build parses far too slowly for 50 MB; use
`GHOSTTY_E2E_STREAM_MB=2` there):

```
$env:GHOSTTY_E2E_EXE = "$PWD\zig-out-rf\bin\ghostty.exe"
powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only stream-integrity
```

**Why not `cat`:** Git Bash's own programs lose data on the way to the
console (measured here through a pseudo console; per the msys2-runtime
source, this affects any console host). msys2-runtime (3.6.9 here) converts a run of up to 32768 bytes for
`WriteConsoleW` into a 32768-character buffer, and its `_sys_mbstowcs`
keeps the last slot for a NUL, so the last byte of every full 32 KiB run is
dropped, and the run is still counted as written
(`fhandler_console::write_normal` / `CONVERT_LIMIT`). `cat` writes 128 KiB
at a time, so a `cat` of 50 MB loses exactly one byte per 32 KiB: 1600
bytes at stream offsets 32767, 65535, ... The raw pseudo console output
already lacks them, while `type` and PowerShell writing in the same 32 KiB
chunks (`WriteFile` and `WriteConsoleW`) arrive intact. This was the
"quick brow fox" seen after a Task 30 throughput run.
`GHOSTTY_E2E_STREAM_WRITER=cat` runs the scenario with `cat` anyway: losses
with exactly that signature are reported as INFO and pass, any other damage
fails. `cat` also gives the end-to-end throughput (about 9 MB/s on
ReleaseFast).

Below the GUI, the `windows exec:` tests in `src/termio/Exec.zig` cover
the same path in parts: the 2 KiB slicing of a read, a 50 MB stream of
random write sizes through the overlapped pipe read loop, and checked lines
from `cmd /c type` through a pseudo console into a terminal.

## M2 additions

### Test IPC and `lib/GhosttyIpc.psm1`

A Ghostty started with `GHOSTTY_WIN32_TEST_IPC=1` (`Start-E2eGhostty` sets it)
answers four test-only ops on its named pipe
`ghostty-<sid>-<session>-<u|a>-<class>`, next to the product ops
(`new-window`, `new-tab`): `state` (windows, tabs, surfaces, rects, dpi,
strip bounds, flags as JSON), `action` (runs a keybind action by name, e.g.
`new_split:right`, answers `performed`), `dpi` (simulates a per-monitor DPI
change) and `color-scheme` (simulates the system light/dark scheme). The
module wraps them: `Invoke-GhosttyIpc`, `Get-GhosttyState`,
`Invoke-GhosttyAction`, `Wait-GhosttyState`. Scenarios drive tabs, splits and
windows through these ops, never through keybind `SendInput`. The module is
ASCII only (Windows PowerShell 5.1 reads a BOM-less file as ANSI).

### `lib/MouseInput.psm1`

Real mouse input for the strip, divider, tab-drag and drop scenarios
(`Send-MouseClick`, `Send-MouseMove`, `Send-MouseDown/Up`, `Send-MouseDrag`,
`Convert-ClientToScreen`). The thread is made per-monitor-aware (V2) so the
physical-pixel coordinates the `state` op reports hit the right pixel at any
scaling (the test powershell.exe itself is DPI-unaware). Only used inside a
scenario, i.e. under the desktop lock.

### M2 scenarios

`e2e.ps1 -Milestone M2` (orders 200..495): `ipc-state`, `tabs-basic`,
`tabs-keys`, `splits-basic`, `split-close`, `split-many` (16 panes; a Debug
exe runs it under the test-lock), `theme`, `config-reload`,
`split-divider-drag`, `frame-hittest`, `chrome-paint`, `tab-strip-mouse`,
`tab-rename`, `single-instance`, `ipc-cli`, `windows-multi`, `dpi-sim`,
`resize-overlay`, `scrollbar`, `maximize-fullscreen`, `bell-progress`,
`close-confirm`, `tray`, `quit-after-last`, `tab-close-tree`, `tab-drag`,
`drop-files`, `device-lost` (needs a Debug exe, SKIP otherwise),
`background-focus`, `m2-acceptance` (idle CPU and the screenshot set), and
the latency scenarios `input-latency`, `tui-latency`, `output-latency`.

- `tray`: the process stays resident after the last window closes (Windows
  default `quit-after-last-window-closed = false`); the tray icon is driven
  through its message window, not clicked.
- `tab-close-tree` / `close-tree`: closing a tab (or window) ends the shell
  and its console tree; a `start cmd` GUI child survives a tab close as in
  Windows Terminal.
- `drop-files`: a real OLE drag from a helper (`_drop.ps1`) into the pane;
  the paths arrive quoted for the shell actually running (Git Bash, pwsh,
  cmd); there is no drop highlight (as on macOS).
- Latency (`_latency.ps1`): stage tables of the key echo, TUI keys, TUI wheel
  and output path from the std-only tracer; gates (ReleaseFast): Ghostty-owned
  stages <= 6 ms p95, whole path <= 16 ms p95 with cmd, burst <= 50 ms.
  Gates are judged on the median of three ReleaseFast runs, and need a quiet
  machine: with another process using 15-20 % CPU the Ghostty-owned p95
  rises to about 15 ms (renderer-thread wake). `bg-cpu` in the INFO line is
  the background load during the run. `GHOSTTY_LAT_RECORD_BASELINE=1`
  appends the rows to `docs/windows/latency-baseline.csv`. Debug is recorded
  with looser gates.
- `stream-integrity` on a Debug exe: use `GHOSTTY_E2E_STREAM_MB=2` (50 MB does
  not finish in 600 s there).

## measure-ram.ps1

```
zig build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf
powershell -NoProfile -File test/windows/measure-ram.ps1 [-Driver hardware|warp] [-Scenario one-surface|scrollback|tabs|splits|windows|close-10|zero-windows] [-Optimize ReleaseFast|Debug]
    [-ExtraConfig <text>] [-Actions <op:arg,...>] [-Tag <name>] [-Sample <label@op,...>]
```

Starts `ghostty.exe` (`zig-out-rf\bin\ghostty.exe` for ReleaseFast, `zig-out\bin\ghostty.exe` for
Debug; `-Exe` overrides) in a sandbox with `command = direct:cmd.exe /k`,
idles 10 s and appends one row to `docs/windows/ram-baseline.csv`:
`date,commit,optimize,adapter,scenario,private_mb,ws_mb`. Only ghostty.exe is
measured (Private Bytes is the budgeted number). `scrollback` first runs
`for /L %i in (1,1,200000) do @echo %i` in the surface, so it types into the
window and needs a usable foreground. `tabs` (10 x `new_tab`), `splits`
(10 x `new_split`), `windows` (4 x `new_window`) and `close-10` (open 10 tabs,
close them, idle 30 s; rows `close-10-before` and `close-10`) are driven by the
test IPC `action` op; `zero-windows` leaves the process resident in the tray.
Per-tab / per-split / per-extra-window cost = (row - one-surface) / 10, 10, 4.
The run holds the desktop lock. Only
`-Optimize ReleaseFast` rows are gated (M1: one surface <= 110 MB); a Debug
build also logs `private usage after Device.init / first surface / first
frame` (`-LogCopy <file>` keeps the log), and logs `d3d11 adapter=` at info.

Feature rows (M3): `-ExtraConfig "background-image = ..."` appends config
lines (alias `-ConfigExtra`), `-Actions new_split:right,toggle_readonly` runs
actions through the test IPC after the scenario's setup (implies
`GHOSTTY_WIN32_TEST_IPC=1`), `-Tag <name>` replaces the `scenario` column, and
`-Sample a@wait:5,b@toggle_readonly` samples several points in one run: after
each op (an action or `wait:<seconds>`) one row `<tag>:<label>` is written
instead of the single idle-then-sample row. Write feature rows to a CSV of
their own (`-Csv`) or tag them; they are not baseline rows.

## vt-smoke (M3)

Screenshot checks of the VT emulation, see `vt-smoke/README.md`:

```
powershell -NoProfile -File test/windows/vt-smoke.ps1 [-Only a,b] [-Update] [-Driver warp|hardware] [-EvidenceDir d]
powershell -NoProfile -File test/windows/vt-smoke/selftest.ps1      # Compare-Image self-test, no GUI
```

`e2e/vt-smoke.ps1` runs it inside the e2e runner (`-Milestone M3`, order 700).
`lib/ImageCompare.psm1` (`Compare-Image -Actual -Reference [-Tolerance 24]
[-MinMatch 0.995]`) is the per-channel image comparison.

## M3 scenarios and owner-safety additions

`e2e.ps1 -Milestone M3` (orders 395..900): `chrome-macos`, `chrome-proxy-icon`, `scrollbar` (overlay scroller),
`split-dim`, `bell-border`, `custom-shader`, `overlay-follow`, `font-fallback`, `hotkey-global`, `toggle-visibility`,
`link-hover-open`, `status-overlays` (key-state label, read-only badge, copy toast), `search`, `palette`,
`quick-terminal`, `notifications`, `inspector`, `config-errors`, `export-io`, `transparency`, `opacity-blur`,
`chrome-transparency`, `tab-menu`, `drop-text`, `pwd-osc7`, `device-recover` (Debug exe, SKIP otherwise; the
`opacity` variant through `GHOSTTY_E2E_VARIANT=opacity`), `vt-smoke` (order 700) and `m3-shots` (order 900, the
acceptance screenshot set). The test IPC (`lib/GhosttyIpc.psm1`) `state` answer carries an `m3` object (overlay, decor, notify, quick, search,
palette, composition, hotkeys, health, opened, inspector, export_io, config_errors) that these scenarios read.

- `m3-shots`: one PNG per feature into the evidence dir (`m3-search-bar`, `m3-palette-open`, `m3-palette-filtered`,
  `m3-key-state`, `m3-readonly-badge`, `m3-link-label`, `m3-quick-top`, `m3-quick-bottom`, `m3-inspector`,
  `m3-health-bar` (Debug only), `m3-split-dim`, `m3-bell-border`, `m3-custom-shader`) plus `m3-shots-results.txt`.
  Every shot is a `Save-WindowShot` crop of one Ghostty window; a phase that meets a foreign window is recorded as
  SKIP and the others go on. The transparency shots over the magenta/striped backdrop come from `transparency` and
  `opacity-blur` (`*-screen.png`). Run it through `e2e.ps1 -Only m3-shots -EvidenceDir <dir>`.
- Owner safety: every screen capture goes through `Get-ScreenShot` / `Save-WindowShot` (`e2e/_common.ps1`). They check
  the exact z-order and a `WindowFromPoint` grid over the capture rect and, when a window that is not ours is there,
  retry three times and then throw `E2E-SKIP: desktop busy`; nothing is saved. Images are cropped to the Ghostty window
  (a margin only over a scenario's own backdrop). `Save-Evidence -Window` uses PrintWindow of the Ghostty HWND (it does
  not show owned popups). Never add a capture that bypasses these, and delete any image that shows anything but Ghostty
  or the test backdrops.
- Known flake: Git Bash loses the first byte typed after its pty resized or after a tab switch (cmd.exe does not), so
  scenarios that type right after such a change re-send (`background-focus`, `device-recover`).
- RAM rows of the M3 features: `measure-ram.ps1 -Tag m3-<feature> [-ExtraConfig ...] [-Actions ...] [-Sample ...]` (see
  the section below); the acceptance numbers and method are in `docs/windows/m3/acceptance.md`.

## M4 scenarios, the tmux helpers and the real-run driver

`e2e.ps1 -Milestone M4` (orders 700..740), all through the real `tmux.exe` from `zig-out\bin` (or next to
`GHOSTTY_E2E_EXE`) and the pipe of the scenario's own Ghostty:

- `tmux-cli` (700, no window): `-V`, "no server", 50 x `-V` with `GHOSTTY_TMUX_STATS=1` (own wall p95 and peak
  private), the import table is exactly a subset of kernel32/ntdll/advapi32 (advapi32 since M5 Task 17), `GHOSTTY_TMUX_TRACE` lines are whole under 8
  parallel runs.
- `tmux-replay` (720): the recorded Claude Code calls (`src/apprt/win32/tmux/testdata/claude-spawn.jsonl`, the live
  recording; `GHOSTTY_E2E_TMUX_FIXTURE=static` picks `claude-spawn.static.jsonl`, which also carries the expected
  stdout) with fake teammates, 30 % leader, titles, leader typing (no lost line), a minimized window, `remain-on-exit
  failed`, `kill-pane` behind the close dialog, 7 parallel kills, `load-buffer -w` (needs a text clipboard: the
  clipboard steps are skipped when it holds anything else; the owner's clipboard is saved and restored in a
  `finally`), and nothing left after Ghostty is killed.
- `tmux-env` (710), `tmux-send-keys` (730, the R-M4-6 gate: 20 rounds of `split-window` + `send-keys`), `tmux-labels` (740).
- Helpers: `e2e/_tmux.ps1` (`Invoke-Tmux`, `Start-TmuxProc`/`Wait-TmuxProc`, `Get-TmuxPanes`, `ConvertTo-MsysPath`).
  `Invoke-Tmux` removes `TMUX`, `TMUX_PANE`, `GHOSTTY_TMUX_TRACE` and `GHOSTTY_TMUX_STATS` from the environment it
  passes, always passes `-S` with the pipe of the scenario's own Ghostty and never puts `tmux.exe` on `PATH`. A pane
  gets the client's environment (tmux semantics), so name files by their sandbox path, not by `$TEMP`. The pipe
  adds a 3 byte BOM to a redirected stdin: stay under the 512 KiB cap by a few bytes.
- `lib/ClaudeRun.psm1` and `claude-team.ps1` (not an e2e scenario): real Claude Code agent-team runs (SPEC 15.6b),
  `-Runs 2` in a row. Owner safety: the driver starts one Ghostty with the REAL `USERPROFILE`/`HOME` (Claude finds the
  owner's login), `XDG_CONFIG_HOME`/`APPDATA`/`LOCALAPPDATA` stay sandboxed, credentials are never copied or read,
  `CLAUDE_*` session variables are removed from the child, the model is `sonnet`, the time box is 10 minutes and the
  run stops at the first auth error. `Stop-ClaudeRun` deletes only the files this run created under
  `~/.claude/projects/<key of the work dir>`; the `~/.claude/tasks/<team>` dir and the `~/.claude.json` entry of the
  work dir are reported as residue (the script removes the former). Pass: 3 panes with the leader at 30 %, titles,
  teammates' messages in the inbox files, only the leader after `/exit`, no stray processes, trace shapes equal to
  the fixture. Never run it unattended against a login that must not be used.
- `measure-tmux.ps1`: RAM and latency rows of the shim (`-Part team-ram|tmux-exe|latency|all`, `-Record` appends to
  the tracked CSVs; ReleaseFast build). Rows `m4-tmux-*` in `ram-baseline.csv`, `m4-tmux` rows in
  `latency-baseline.csv`. Latency is `tmux.exe`'s process wall (kernel start to exit) next to the driver's own stopwatch
  (which includes the PowerShell process spawn); background CPU load matters, it is printed.

## Latency probes: options

`input-latency.ps1` takes `-ExtraConfig "k = v;k = v"` (config lines appended to
the shell's config) and `-Splits N` (type into the focused one of N panes),
or `GHOSTTY_LAT_EXTRA_CONFIG` / `GHOSTTY_LAT_SPLITS` under the runner. Name such
runs with `GHOSTTY_LAT_BUILD_VARIANT` so they never read as baseline rows.

`GHOSTTY_E2E_VARIANT=opacity` selects the `opacity` variant of `device-recover.ps1` (scenarios take no parameters).

## M5 scenarios and safety rules

`e2e.ps1 -Milestone M5` runs these scenarios (header `milestone=M5`, with their orders): `right-click` (116), `menu-dark` (640),
`prompt-marks` (700), `secure-input` (870), `undo-close` (880), `osk` (900), `jumplist` (910), `explorer-cli` (965),
`term-terminfo` (966), `edit-config` (966), `update-check` (968), `profiles-menu` (970), `tmux-external` (975) and `crash-dump`
(Task 12), plus the pending `close-idle-prompt`, `new-tab-white-flash` and `initial-window`. `drop-files` (M2) also covers the Windows-path paste of M5. Helpers and self-tests: `e2e/_m5_fakeserver.ps1` (the
loopback release server), `e2e/_selftest-clipboard.ps1` (clipboard save and restore, no scenario) and
`e2e/_selftest-capture.ps1` (the capture guard's pure part, no GUI).

- `profiles-menu`: right-click on `+` opens the profile menu, the accelerator of "Command Prompt" opens a tab, the palette
  entry `New Tab: Windows PowerShell` opens another; `state.m5.profiles` lists the ids. No WSL profile is ever chosen, so no
  distro starts.
- `jumplist`: the list is built with New Window, New Tab, a separator and the profile tasks (HRESULTs 0); quitting deletes the
  list of the test AUMID; `+new-tab --class=<c>` with no instance starts one.
- `explorer-cli`: `--dry-run` prints the writes and opens no key; install and uninstall run against a private application hive
  (`GHOSTTY_WIN32_TEST_HIVE`); a read-only `reg query` of the owner's real keys gives the same answer before and after.
- `prompt-marks`: OSC 133 from Git Bash, pwsh and cmd; `jump_to_prompt`; exit codes (cmd has none).
- `term-terminfo`: `TERM`, `tput`, `infocmp` and `vim` from Git Bash, pwsh and cmd with the compiled entry.
- `edit-config`: a fake GUI-style editor runs detached with the config path; a console editor runs in a new Ghostty window;
  no editor opens Notepad (never started: the scenario only checks the command).
- `update-check`: a fake release server on `127.0.0.1` (`GHOSTTY_WIN32_UPDATE_URL`, honoured in test mode only); newer,
  same, HTML body, HTTP 403, a redirect (not followed), a server that never answers, a toast count of one per release.
- `crash-dump`: an access violation and a stack overflow produce a dump, no WerFault dialog, a log line, `+crash-report`
  lists it, and the marker string typed into the pty is absent from the file.
- `secure-input`: every top-level window of the UI thread reports `WDA_EXCLUDEFROMCAPTURE`; the clipboard exclusion formats
  are read as a format list, never as content.
- `undo-close`: close, undo and expiry of tabs, windows and splits, undo and redo of created tabs and splits, with `ping`
  as the witness that the child lives; `undo-timeout` is 12 s in the scenario.
- `osk`: `show_on_screen_keyboard` is only recorded in test mode (`state.osk.requests`); TabTip is never started.
- `tmux-external`: `windows-tmux-external = true`, `tmux.exe -L <name>` with `TMUX` removed and `GHOSTTY_TMUX_CLASS` naming the
  sandbox instance; `has-session`, `new-session`, `new-window -n`, `kill-session`, `kill-server`.
- `right-click`: the three `right-click-action` behaviours in Git Bash, with the owner's clipboard saved and restored.
- `menu-dark`: median background luminance of the tab menu under the simulated dark and light scheme.
- `close-idle-prompt` (425, PENDING first GUI run): with `confirm-close-surface = true`, `WM_CLOSE` at an idle Git Bash prompt,
  at a Git Bash whose rc file runs `exec zsh`, and in cmd asks nothing; a running `ping -t` in cmd asks. Headless counterpart:
  `shell-marks/run.ps1` (below).
- `new-tab-white-flash` (312, PENDING): translucent window (0.85, no blur) over a white backdrop window of our own; a capture
  thread counts near-white frames in the terminal area during bursts of `new_tab`, `new_split` and `new_window`, and again with
  a light/dark theme pair; the expected count is 0. Run it against a build of `91ff7bac1` (red) and the fix (green) through
  `GHOSTTY_E2E_EXE`; it SKIPs when a foreign window overlaps the capture rectangle.
- `initial-window` (990, PENDING): `initial-window = false` starts the process and the tray with no window; a second launch
  opens the first window. The harness knows `AllowNoWindow`.
- `crash-dump` (980): see above; Debug and ReleaseFast both, with the stack-overflow case.
- `package-portable` (milestone M6, order 1000): the release zip, with Mark-of-the-Web on the zip and every extracted file, runs
  from a path with a space and a Cyrillic letter. Input: `GHOSTTY_E2E_PACKAGE=<zip>`. It checks `+version`, `+list-themes`, a cmd
  session with the folder's resources, `TERM` and `tmux.exe`, the bundled `OpenConsole.exe` running from the folder, a clean close,
  a moved `share\` (TERM falls back with one warning) and no writes into the folder. A SKIP counts as a FAIL here.
- `installer-test` (milestone M6, M6 Task 7, in progress): installs the per-user Inno Setup test variant into a sandbox and
  checks files, shortcut, uninstall and the running-Ghostty guard. Not in the tree at the time of writing; the Retry button of the
  guard is a manual check.

### Headless shell integration check (`shell-marks/run.ps1`)

No window and no desktop: each case runs a shell in a pseudoconsole with Ghostty's integration environment and a sandbox
`HOME`, and reads the raw output. A prompt is marked when a `133;B` follows the last `133;A`. Cases: Git Bash, `ZDOTDIR`
handling around `exec zsh` (environment, rc file, leak, trap removed, chained user trap, `$_`), zsh from a drive path and a
backslash path, the zsh `path` feature, and cmd while a command runs (`cmd-busy`). 15 cases pass. It never reads the owner's
rc files.

### Safety rules (binding for every M5 scenario)

- **Desktop lock.** Every GUI run holds `%TEMP%\gui-e2e.lock` (see "The desktop lock" above); `e2e.ps1` takes it for the whole
  run. A busy or locked desktop is a SKIP, never a FAIL. Builds and unit tests run under the team's `test-lock` (two slots);
  GUI runs are not wrapped in it.
- **Clipboard.** A scenario that touches the clipboard first saves every format (`lib/Clipboard.psm1`, DPAPI-protected
  backup) and restores it in a `finally`; the restore is all-or-nothing and guarded by the clipboard sequence
  number. Secure-input checks read the list of formats only.
- **No HKCU.** No scenario writes the owner's real registry. Registry writes go through the opt-in `+install-explorer-integration`
  against the private hive (`GHOSTTY_WIN32_TEST_HIVE`); `explorer-cli` asserts the real keys are unchanged. The jump list
  and toast registration use a test AUMID.
- **No network except loopback.** In test mode Ghostty does no network I/O unless `GHOSTTY_WIN32_UPDATE_URL` points at
  `127.0.0.1`. No scenario log may name `api.github.com`, and every `update: fetching` line names `127.0.0.1`.
- **Screenshots only of Ghostty windows.** All captures go through `Get-ScreenShot` / `Save-WindowShot`, which refuse (SKIP
  "desktop busy") when a foreign window overlaps. Delete any image that shows anything else.
- **No distro, no touch keyboard.** No WSL distro is started; `osk` never starts TabTip; dumps are checked for the pty
  marker string; processes are killed only if the run started them.
