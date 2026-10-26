# Windows port changelog

## M1 — core + single-window terminal

### What works

- Native Win32 application runtime (`-Dapp-runtime=win32`) with a Direct3D 11
  renderer (`-Drenderer=d3d11`); no third-party UI toolkit.
- One top-level window hosting one terminal surface: ConPTY, VT parsing,
  scrollback, selection, mouse, keyboard (including non-Latin layouts, AltGr
  and IME), clipboard (with confirmation prompts for unsafe paste and OSC 52),
  per-monitor DPI. (Config reload arrives in M2.)
- Shell: Git Bash by default, `cmd.exe` and PowerShell via `command`. A
  `direct:` command is parsed with MS C runtime quoting rules. `TERM` is
  `xterm-256color`.
- Config at `%USERPROFILE%\.config\ghostty\config.ghostty` (XDG layout).
- Process lifetime: the child and the console processes it started die with
  the surface (job object, GUI programs it launched are left alone). Closing
  a window, or the `quit` action (Ctrl+Shift+Q), asks for confirmation while a
  process is running, as `confirm-close-surface` says.
- Fonts: DirectWrite-independent discovery of installed fonts via FreeType,
  including colour glyphs (COLRv0).
- Safe GUI end-to-end harness in `test/windows` (desktop lock, sandboxed
  profile, clipboard backup).

### Core changes outside Windows-only code

- FreeType: COLRv0 glyphs in colour-capable faces now render as colour. This
  also applies on Linux (before, the outline path produced `WrongAtlas`).
- All other core edits are comptime-gated on Windows or widen a `.none`
  runtime/renderer case; Linux behaviour is unchanged.

### Known limitations

- Reading output from some msys2 programs (for example `cat` on a large file)
  can lose bytes when the console is the host's; per its source this applies
  to other hosts as well. Not measured further.
- Debug builds are slow (the 50 MB stream test in particular); use
  ReleaseFast for anything performance related.
- `aarch64-windows-msvc` is not verified. macOS cannot be cross-built from
  this machine; the macOS compile check waits for CI (M6).
- A lost Direct3D device (driver reset or update) is terminal: the surface
  stops drawing until the app is restarted.
- Closing the last tab or window semantics change in M2 (tabs, splits, tray);
  today closing the window ends the process.
- Single window and single surface only.

### Acceptance

| Check | Result |
| --- | --- |
| GUI e2e (`test/windows/e2e-m1.ps1`) | 18/18 pass in ReleaseFast and in Debug |
| RAM, one surface (`docs/windows/ram-baseline.csv`) | 105.8 MB private bytes, ReleaseFast |
| Output throughput | 9.1 MB/s |
| Linux cross-compile (`-Dtarget=x86_64-linux-gnu -Dapp-runtime=none`, also with `-Demit-lib-vt`) | builds; `ghostty-internal` and `libghostty-vt` produced. Test binary not run (no Linux host) |
| macOS compile | not checked (no SDK here; waits for CI) |
