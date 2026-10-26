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
SKIP after the wait). `e2e-m1.ps1` takes it once for the whole run and hands
its id to the scenarios in `GHOSTTY_E2E_LOCK_ID`, so they do not wait on it.

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
2. Git Bash runs `cat` on it, then prints an end marker.
3. `ctrl+shift+f12` is bound to `write_screen_file:paste`
   (`configs/stream-integrity.ghostty`, with `scrollback-limit-bytes =
   unlimited`): Ghostty writes the screen and scrollback as plain text to a
   `screen.txt` in the sandbox `TEMP`.
4. `Test-CheckedStream` regenerates every line and reports each missing,
   changed or extra line with its line number and the first column that
   differs; any of them, or a missing end marker, FAILs.

The throughput of the `cat` is reported as an INFO line. Run it on a
ReleaseFast build (a Debug build parses far too slowly for 50 MB; use
`GHOSTTY_E2E_STREAM_MB=2` there):

```
$env:GHOSTTY_E2E_EXE = "$PWD\zig-out-rf\bin\ghostty.exe"
powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only stream-integrity
```

Below the GUI, the `windows exec:` tests in `src/termio/Exec.zig` cover
the same path in parts: the 2 KiB slicing of a read, a 50 MB stream of
random write sizes through the overlapped pipe read loop, and checked lines
from `cmd /c type` through a pseudo console into a terminal.

## measure-ram.ps1

```
zig build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf
powershell -NoProfile -File test/windows/measure-ram.ps1 [-Driver hardware|warp] [-Scenario one-surface|scrollback] [-Optimize ReleaseFast|Debug]
```

Starts `ghostty.exe` (`zig-out-rf\bin\ghostty.exe` for ReleaseFast, `zig-out\bin\ghostty.exe` for
Debug; `-Exe` overrides) in a sandbox with `command = direct:cmd.exe /k`,
idles 10 s and appends one row to `docs/windows/ram-baseline.csv`:
`date,commit,optimize,adapter,scenario,private_mb,ws_mb`. Only ghostty.exe is
measured (Private Bytes is the budgeted number). `scrollback` first runs
`for /L %i in (1,1,200000) do @echo %i` in the surface, so it types into the
window and needs a usable foreground. The run holds the desktop lock. Only
`-Optimize ReleaseFast` rows are gated (M1: one surface <= 110 MB); a Debug
build also logs `private usage after Device.init / first surface / first
frame` (`-LogCopy <file>` keeps the log), and logs `d3d11 adapter=` at info.
