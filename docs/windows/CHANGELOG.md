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

## M3 — feature parity

(M2 is recorded in `docs/windows/m2/acceptance.md`.)

### What works

- Window chrome like Ghostty for macOS: a title row (focused surface title, proxy folder icon for its working directory)
  and a tab row with two or more tabs (equal-width tabs with the `goto_tab` shortcut, close button on hover, animations),
  Windows caption buttons on the right, tab context menu and full-title tooltip, overlay scrollbar.
- Quick terminal (`toggle_quick_terminal`, `+toggle-quick-terminal`, slide animation, top/bottom/left/right/center),
  global keybinds (`global:` through `RegisterHotKey`), `toggle_visibility`.
- Command palette, search bar, key-sequence / key-table indicator, read-only badge, link label under the pointer, copy
  toast, renderer-health bar. Overlays are owned popups that follow the window.
- Links: OSC 8 and detected URLs open through a validated policy (http, https, mailto, ftp open; local files open
  unless they are executable types, which are revealed in Explorer; UNC, device paths and unknown schemes are refused
  or ask first).
- Desktop notifications: OSC 9 / OSC 777 and `notify-on-command-finish` show Windows toasts (clicking one presents the
  surface); `FlashWindowEx` is the fallback.
- Inspector (imgui, own window), configuration-errors dialog, export of terminal contents from the inspector.
- Custom shaders (`custom-shader`, GLSL converted to HLSL), background image, unfocused-split dimming, bell border.
- Transparency: `background-opacity` and `background-blur` (Acrylic, stays frosted while inactive),
  `toggle_background_opacity`.
- Fonts: DirectWrite discovery and fallback (CJK, symbols); emoji still use the embedded Noto Color Emoji.
- GPU device loss is recovered: every window redraws after a short "Rendering paused" bar (three failed recoveries
  switch to the WARP software device).
- Text drag-and-drop goes through the paste path (bracketed paste and the unsafe-paste prompt apply).
- OSC 7 working directory: Git Bash, PowerShell and cmd tabs and splits start in the current directory (Git Bash
  integration reports it with `pwd -W`).
- Bash integration on Git Bash sets `bell-style audible` (unless your `inputrc` sets one) so that backspace at an empty
  prompt no longer flashes the window.
- `+toggle-quick-terminal --class=<class>` now honours `--class` (also on Linux).
- `+list-fonts` prints readable family names on Windows.
- Test harness: `vt-smoke` screenshot checks, the M3 e2e scenarios, a capture guard that never saves windows that are
  not Ghostty, `measure-ram.ps1 -ExtraConfig/-Actions/-Tag/-Sample`, `docs/windows/feature-checklist.md`.

### Changes you may notice

- The app now sets an explicit AppUserModelID. Taskbar pins made with M1 and M2 builds are no longer grouped with the
  running window: unpin and pin again. The first toast registers
  `HKCU\Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial` and writes
  `%LOCALAPPDATA%\ghostty\toast-icon.png`; both stay after an uninstall.
- A window that starts opaque stays opaque after you reload the config to a translucent one (restart, like macOS).
- The native scrollbar is replaced by an overlay scroller (macOS look). `scrollbar = never` hides it.

### Core changes outside Windows-only code

- `src/Surface.zig`, `src/renderer/*`: a platform-neutral `redraw` message and image-texture re-upload after a backend
  reports a new device generation (no-op elsewhere).
- `generic.zig`: custom shaders are active only when a post pipeline exists (also fixes a latent Metal/OpenGL case where
  a failing post shader sent frames to the back texture).
- `src/cli/toggle_quick_terminal.zig`: parses its options (fixes `--class` on every platform).
- FreeType `Face.name`: UTF-16 family names are converted (Windows `+list-fonts`).
- `src/font/*`, `pkg/spirv-cross`, `pkg/dcimgui`: Windows-gated additions (DirectWrite discovery, HLSL backend, imgui
  Win32/DX11 backends).

### Known limitations

- Kitty graphics and SGR 58 (underline colour) do not work: the inbox ConPTY drops them (flag 8, passthrough mode,
  does not help). They need a bundled newer `conpty.dll` + OpenConsole (owner decision pending).
- A toast clicked in the Action Center after Ghostty exited does nothing.
- COLRv1 emoji (Segoe UI Emoji) are not used; the embedded Noto Color Emoji is.
- Global hotkeys are not re-registered when the keyboard layout changes (they are on every config reload).
- The quick terminal cannot be resized by the user.
- With `background-blur` the system Acrylic needs "Transparency effects" on in Windows settings; with it off the window
  is solid. The window owner of a message box and a second blurred window are drawn active too.
- Git Bash: the first key typed after a pty resize (window drag, split, tab strip) could be lost: MSYS2 sometimes takes
  in conhost's window-size event only with the next input record and drops that record (`exit` ran as `xit`). Fixed
  with a workaround (Task 26.4): the first pty write after a grid change starts with a win32-input-mode Shift key-up,
  which absorbs the loss and which readers ignore; it is armed only after the pseudo console asked for
  win32-input-mode (`CSI ? 9001 h`), so an older conhost never gets it. `e2e/resize-input`: 9 of 20 lines lost before,
  0 of 36 (window, split, tab) after; cmd.exe and pwsh unchanged. Residual: one run on a heavily loaded machine
  (a shell taking ~1 s per command) still lost 2 of 36. Root cause in MSYS2/conhost not proven; an msys2-runtime report is
  a follow-up.
- Over the RAM budget (owner to decide, see `docs/windows/m3/acceptance.md`): custom shader (+1.3 MB at the default
  size), overlays (+1.1 MB), inspector memory after close (+1.6 MB), quick terminal (+10.1 MB first toggle).
- The latency gates are relative (+0.5 ms): the absolute 6 ms Ghostty-owned p95 is not reached while the machine has
  10 % background CPU, see the acceptance record.
- Ligatures, the Kitty keyboard protocol end to end, `open_config`, IME composition and the real toast have no
  automated evidence (owner checks).

### Acceptance

See `docs/windows/m3/acceptance.md` (RAM and latency rows, screenshots, exit checklist).
