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

## Latency probes: options

`input-latency.ps1` takes `-ExtraConfig "k = v;k = v"` (config lines appended to
the shell's config) and `-Splits N` (type into the focused one of N panes),
or `GHOSTTY_LAT_EXTRA_CONFIG` / `GHOSTTY_LAT_SPLITS` under the runner. Name such
runs with `GHOSTTY_LAT_BUILD_VARIANT` so they never read as baseline rows.

`GHOSTTY_E2E_VARIANT=opacity` selects the `opacity` variant of `device-recover.ps1` (scenarios take no parameters).
