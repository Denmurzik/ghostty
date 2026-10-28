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

- All Ghostty dialogs (close, paste, link, config errors) are in the Windows 11 look (rounded, Mica, dark/light, per-monitor
  DPI) instead of the Vista-style TaskDialog; `MessageBox` is only the fallback. "Allow" has no keyboard accelerator.

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
- `src/termio/Exec.zig` (Windows arms): the resize prime (Task 26.4); `PWD` is no longer exported to children; a
  `ReadFile` that completes synchronously takes its byte count from `GetOverlappedResult`.
- `src/termio/stream_handler.zig`: OSC 7 on Windows is translated through `pwd_path`, and a non-local path resets the
  pwd. The `resetPwd` refactor touches every platform.
- `src/os/hostname.zig`: NetBIOS and DNS names are accepted, compared case-insensitively. `src/os/pwd_path.zig` is new.
- `src/renderer/Thread.zig`: `recoverDevice` runs on every render callback, and animation `.draw` ticks call
  `waitFrameSlot`; both are no-ops off D3D11. `generic.zig` also stores `has_custom_shaders` atomically.
- `src/config/Config.zig`: `background-blur` defaults to `true` on Windows, and `shell-integration` gains `pwsh` and
  `cmd` (comptime-gated).
- `src/font/face/freetype.zig`: names on the Unicode platform (`TT_PLATFORM_APPLE_UNICODE`) are decoded as UTF-16BE.
  This changes behaviour on every platform and is an upstream candidate.

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
  0 of 36 (window, split, tab) after; cmd.exe and pwsh unchanged. Under heavy load (one run lost 2 of 36) the
  window now starts at conhost's first output after the resize (cap 2 s): 36/36 under 12 CPU-burner threads. Root cause in MSYS2/conhost not proven; an msys2-runtime report is
  a follow-up.
- Over or at the RAM budget (owner to decide, see `docs/windows/m3/acceptance.md`): custom shader (+1.3 MB at the
  default size), quick terminal (+10.1 MB first toggle). After Task 26.5 the inspector after close is borderline (about
  +1.9 MB mean over the pre-open value, 2 of 5 samples over +2) and the overlays pass when the shared text state is
  warm (+0.4 MB); the first paint of a cold window still costs about +2 MB.
- The latency gates are relative (+0.5 ms): the absolute 6 ms Ghostty-owned p95 is not reached while the machine has
  10 % background CPU, see the acceptance record.
- Ligatures, the Kitty keyboard protocol end to end, `open_config`, IME composition and the real toast have no
  automated evidence (owner checks).

### Acceptance

See `docs/windows/m3/acceptance.md` (RAM and latency rows, screenshots, exit checklist).


## M4 — tmux shim for Claude Code agent teams

### What works

- `tmux.exe` ships next to `ghostty.exe` (a small console exe, no libc, about 0.6 MB private per call). Every pane gets `TMUX`,
  `TMUX_PANE` and the exe directory first on `PATH`, so programs that drive tmux (Claude Code's agent teams with
  `teammateMode: "tmux"`) open their panes as Ghostty splits in the window they run in: `split-window`, `respawn-pane`,
  `kill-pane`, `select-layout main-vertical`/`tiled`, `resize-pane`, `select-pane -T`, `set-option`, `show-options`,
  `display-message`, `list-panes`/`list-windows`, `show-environment`, `load-buffer` (`-w` fills the clipboard), `send-keys` and
  `capture-pane` (visible screen).
- A teammate pane keeps its title and shows a coloured label in its corner when the tmux options ask for it
  (`pane-border-status`, `pane-border-format`, `pane-border-style`). `remain-on-exit` works for panes the shim created.
- The tmux pipe is private to your user (`\\.\pipe\ghostty-tmux-<pid>-<nonce>`, remote clients rejected); `tmux.exe` refuses any
  other path.
- It also works without Claude: `tmux split-window -h` and `tmux kill-pane` in a Git Bash pane act on the Ghostty window.

### Config

- `windows-tmux-shim = true|false` (default `true`, Windows only, app-wide, read when a surface starts). `false` leaves
  `TMUX`/`TMUX_PANE` and `PATH` as they were: an MSYS2 tmux you installed works as before.
- Debugging: `GHOSTTY_TMUX_TRACE=<file>` makes `tmux.exe` append one JSON line per call; `GHOSTTY_TMUX_STATS=1` prints its peak
  memory and wall time.

### Known limitations (gaps)

- External mode (`TMUX` unset, `-L`) and `new-session`/`attach`/`has-session`/`kill-server` are M5.
- `select-layout` other than `main-vertical` and `tiled` is accepted and does nothing; `capture-pane` covers the visible screen only.
- Creates from the profile menu, the tray ("New Window") and jump-list tasks are not undoable.
- An external-mode tmux tab brought back by undo may be gone from its client's session listing (its `%N` still works).
- DCS `tmux;` passthrough: core unwraps it, but the inbox ConPTY drops an ST-terminated inner sequence (an OSC 9 with a
  BEL terminator arrives); Claude notifications that use ST are lost while `TMUX` is set.
- Images stay disabled under `TMUX` (XTVERSION is not spoofed, SPEC 12.4).
- A config reload drops a shim pane's `wait-after-command`: after a reload a teammate that exits non-zero closes instead of staying.
- A split answered after its client timed out (a UI stall past about 10 s) leaves an `__idle` pane.
- `send-keys` is held back for 300 ms after a split (150 ms after the last layout change): scripted keys never get lost, at a
  small latency cost.
- `tmux.exe display-message` measures p95 32.2 ms (process start to exit, ReleaseFast, idle machine) against a 30 ms goal;
  the process-creation floor here is about 21 ms. `load-buffer -w` was not run against the real clipboard in the acceptance
  (it needs a text clipboard; unit-tested).

### Acceptance

| Check | Result |
| --- | --- |
| Unit: `test-tmux-shim`, `tmux shim `, `win32 tmux ` (3 runs), `SplitTree`, `stream: tmux` (lib-vt), `win32 ipc` | pass (33, 106, 159 on the first of three runs (the other two exit 0), 104, 73, 104 tests; 1 skipped in four of them as before) |
| Builds | Debug, ReleaseFast, `-Demit-lib-vt`, Linux recipe, `aarch64-windows-gnu`: pass |
| e2e `-Milestone M4` (tmux-cli, tmux-env, tmux-replay, tmux-send-keys, tmux-labels) | 5 of 5 on Debug and on ReleaseFast |
| Real Claude Code 2.1.312 agent-team run (`test/windows/claude-team.ps1`, sonnet) | 2 of 2 passed (3 panes, leader 30.0 %, titles, inbox messages, clean exit, trace equals the fixture) |
| RAM (ReleaseFast): one surface; team; 30 s after killing the team | 72.0 MB (M3 acceptance build, same day: 72.1); 84.1 MB; 78.2 MB (+5.9 %) |
| `tmux.exe` peak private: `display-message` / `load-buffer` 512 KiB / `__idle` | 0.6 MB / 3.9 MB / 0.5 MB |
| `tmux.exe` process wall p95: display-message / split-window / respawn-pane | 32.2 ms (goal 30) / 35.5 ms / 114.6 ms |
| Key-echo (Ghostty-owned p95, 6 interleaved runs each) | 2.14 ms median against 1.63 ms for the M3 acceptance build (+0.5 ms; single runs 1.3-11.6 ms under 7-13 % background load) |


## M5 — Windows extras

### What works

- **Profiles.** Ghostty detects Git Bash, PowerShell 7, Windows PowerShell, Command Prompt and your WSL distros (read from the
  registry, no distro is started to list them). Right-click the `+` of the tab row for a menu of "New Tab" and "New Window"
  items; the command palette has `New Tab: <profile>` / `New Window: <profile>` (also with one tab) and the tray has a
  "New Window" submenu. `ghostty.exe --profile=<id>` opens one (`git-bash`, `pwsh`, `powershell`, `cmd`, `wsl:<distro>`). Your
  `command` is the `Default` profile; there is no key for custom profiles.
- **Jump list.** Right-click the taskbar icon: New Window, New Tab and one task per profile. `+new-tab` starts Ghostty when
  none is running. Key `windows-jump-list = true|false` (default `true`); `false` clears the list at the next start.
- **Explorer.** `ghostty.exe +install-explorer-integration` adds "Open Ghostty here" for folders, folder backgrounds and drives
  (HKCU only). `+uninstall-explorer-integration` removes it; `--all` also removes the toast registration and its icon file;
  `--dry-run` prints what would change.
- **Shell integration.** OSC 133 prompt marks for pwsh (7 and Windows PowerShell 5.1) and cmd, so `jump_to_prompt`, the output
  boundaries and (pwsh, Git Bash) `command_finished` work. Git Bash path fixes for MSYS.
- **Terminfo and `TERM`.** The build compiles `xterm-ghostty` with Git for Windows' `tic.exe` (`-Dtic=<path>` overrides); `TERM`
  defaults to `xterm-ghostty` when the compiled entry ships, `xterm-256color` otherwise (and always for `wsl.exe`).
- **`+edit-config`.** Opens the config in `VISUAL` / `EDITOR` (a console editor runs in a new Ghostty window, a GUI editor
  directly), else in Notepad. Upstream errors without an editor; Windows does not.
- **Update check.** `auto-update` defaults to `check` on Windows: one anonymous GET of the GitHub releases list 60 s after
  start and then daily, one toast per new release, never an install or a download. `off` disables it; `download` is treated as
  `check` with a warning. No automatic check in Debug builds or in a local build without a `-win.<N>` version. The
  `check_for_updates` action always answers with a dialog. Release tags are `win-<zon>-<N>` (pre-releases included).
- **Crash dumps.** An unhandled exception or panic writes a minidump to `%LOCALAPPDATA%\ghostty\crash\` (10 newest kept) with
  stack contents reduced to the pointers a stack walk needs, so terminal text does not reach the file. `+crash-report` lists
  them. Nothing is uploaded.
- **Secure input analog.** `toggle_secure_input` (and `macos-secure-input-indication`) excludes every Ghostty window from screen
  capture, keeps copied text out of Win+V history and cloud clipboard, and shows the lock badge.
- **Undo / redo.** Closing a tab, a window or a split, and creating one, can be undone: the item is hidden, not closed, and
  its programs keep running until `undo-timeout`. Details below.
- **On-screen keyboard.** `show_on_screen_keyboard` opens the touch keyboard (never hides it).
- **External tmux mode.** With `windows-tmux-external = true`, `tmux.exe` outside Ghostty (`TMUX` unset, or `-L <name>`)
  drives a Ghostty window per tmux server name: `new-session -d`, `new-window -n`, `has-session`, `kill-session`,
  `kill-server`, `list-windows -F '#{window_name}'` and `session:window-name` targets. Claude Code started in Windows
  Terminal then opens its teammates in Ghostty.
- **Also in this milestone.** Right-click pastes by default (`right-click-action = copy-or-paste`, like Windows Terminal; a
  selection is copied instead), with a native context menu for `context-menu`. File drops paste Windows paths in Git Bash and
  Cygwin (WSL keeps `/mnt/c/...`). Popup menus follow the dark and light theme. All dialogs, including the update and
  secure-input ones, use the Windows 11 look.

### Config

- `windows-jump-list = true|false` (default `true`, Windows only).
- `windows-tmux-external = true|false` (default `false`, Windows only, needs a restart). It opens a second private pipe that
  any process of your user can ask to run tmux commands, which relaxes the M2 rule that nothing but Ghostty's own CLI may do
  so; enable it only for a tool that needs it. Put the Ghostty folder on `PATH` so `tmux.exe` is found outside Ghostty.
- `undo-timeout`: default `5s` on Windows, like macOS. The default binds are `ctrl+shift+z` = `undo` and `ctrl+shift+y` =
  `redo` (`ctrl+shift+t` is already `new_tab` and `ctrl+z` belongs to the shell). The cost: for 5 s after a close, the
  closed tab's programs keep running (a dev server keeps its port), unlike Windows Terminal where they end at once. Set
  `undo-timeout = 0` to turn undo off.
- `auto-update = check|off` (Windows default `check`).
- `right-click-action` default on Windows is `copy-or-paste`.

### Known limitations (gaps)

- The Explorer entry is in the classic context menu only ("Show more options"); the top-level Windows 11 menu needs package
  identity, which is out of scope.
- No automatic secure input at password prompts (ConPTY has no termios); toggle it yourself.
- cmd's prompt marks have no exit code: no `command_finished` for cmd. `jump_to_prompt` and the output boundaries work.
- `TERM=xterm-ghostty` over ssh to a host without the entry (Windows OpenSSH from pwsh in particular) breaks full-screen
  programs; set `TERM=xterm-256color` there. Cygwin would need `/cygdrive/c/...` for `TERMINFO` (not done).
- External tmux mode needs the Ghostty directory on `PATH`; `tmux.exe` is on `PATH` automatically only inside Ghostty
  sessions.
- Undo is not offered for closes caused by tmux, IPC or a child exiting by itself, nor for closing the last window with
  `quit-after-last-window-closed = true`.
- A crash while the process heap lock is held leaves no dump (the dump thread times out after 10 s).
- `+edit-config` tells a GUI editor from a console editor by the PE subsystem of its exe only; a console-subsystem editor
  that opens its own window still runs inside a new Ghostty window.
- Crash dump stack scrubbing: `MiniDumpFilterMemory` alone is not enough, so after the dump is written Ghostty zeroes every
  8-byte word of every thread stack that is not zero and does not look like a user-mode pointer (a dump that cannot be
  parsed is kept as written and logged). A pointer-shaped value is kept by design, and module names, thread ids and register values stay in the file. Check a dump before sending
  it to anyone.

#### Undo: known limits (Task 15b)

- A parked split misses device-loss and colour-scheme refreshes for up to `undo-timeout`.
- Redo of a close gives the item a fresh timeout, so a closed tab can live up to twice `undo-timeout` in total.
- Undo of `new_window` for the only window of an app that is quitting is refused (the entry is dropped).
- A split close is restored only if the tab's tree is node for node the tree the close produced; otherwise the entry is
  dropped with a log line.
- Unit tests do not drive a live window for the flip itself; `e2e/undo-close` does.

### Core changes outside Windows-only code

- Windows arms only: `src/os/windows_*.zig`, `src/apprt/win32`, `src/tmux_shim`, `src/config/Config.zig` (the keys above, comptime
  defaults for Windows), `src/termio/Exec.zig` (TERM, MSYS paths), `src/shell-integration` (pwsh, cmd), `src/main_ghostty.zig`
  (crash filter; Zig's segfault handler is off on Windows), `src/build` (tic).

### Acceptance

See `docs/windows/plans/M5-windows-extras.md` ("M5 exit checklist"). RAM and latency rows, the import check and the ARM64
cross-build are recorded by the M5 acceptance commit.
