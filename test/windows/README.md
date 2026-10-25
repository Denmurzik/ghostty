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
