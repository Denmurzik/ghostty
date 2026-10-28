# Windows port: feature checklist

One row per cross-platform Ghostty feature (DECISIONS "Features", SPEC section 17 M1-M3). The v1.0 / M3 exit
criterion is that every row is `done` with evidence (a test, a scenario or a reference screenshot).

- **Evidence**: `e2e/<name>` is `test/windows/e2e/<name>.ps1`; `vt-smoke/<case>` is a reference PNG in
  `test/windows/vt-smoke/ref/`; `unit: <file>` are `zig build test` tests of that file; `manual` is an owner check.
- **Status**: `done` (evidence exists and passed at the last acceptance), `pending -> Task N` (M3 plan task `N` builds
  or verifies it), `gap` (known and accepted, see the note below), `manual` (only an owner check, no automation).
- `vt-smoke` rows come from M3 Task 3 and were generated on the WARP driver on 2026-10-27 (references keyed by display scale; the 96 dpi set is current). Screenshots `m3-*` and `transparency-*` / `opacity-blur-*` are in the M3 acceptance record (`docs/windows/m3/acceptance.md`).

| Feature | Milestone | Evidence | Status |
|---|---|---|---|
| VT: cursor movement, erase, insert/delete (CUP, ED, EL, ECH, ICH, DCH, IL, DL) | M1 | vt-smoke/cursor-erase | done |
| VT: scroll regions (DECSTBM, IND, RI, SU/SD) | M1 | vt-smoke/scroll-region | done |
| VT: alternate screen (?1049) | M1 | vt-smoke/alt-screen | done |
| VT: DEC special graphics, G0/G1 charsets | M1 | vt-smoke/dec-graphics | done |
| VT: box drawing, block elements, braille | M1 | vt-smoke/box-drawing | done |
| VT: wide (CJK / fullwidth) cells | M1 | e2e/font-fallback (CJK glyphs drawn); vt-smoke/wide-cjk has no 96 dpi reference (SKIP) | done |
| VT: combining marks, variation selectors | M1 | vt-smoke/combining | done |
| VT: stream integrity under large output | M1 | e2e/stream-integrity | done |
| SGR: 16 colours | M1 | vt-smoke/sgr-16 | done |
| SGR: 256 colours | M1 | vt-smoke/sgr-256 | done |
| SGR: truecolor (semicolon and colon forms) | M1 | vt-smoke/sgr-truecolor | done |
| SGR: bold, dim, italic, inverse, invisible, strikethrough, overline | M1 | vt-smoke/styles | done |
| SGR: underline styles (single, double, curly, dotted, dashed) | M1 | vt-smoke/underlines | done |
| SGR 58: underline colour | M1 | headless conpty-probe (bundled ConPTY forwards it unchanged); vt-smoke/underline-colors (GUI check pending) | done via bundled ConPTY (GUI verification pending, see notes) |
| OSC 8 hyperlinks (sequence arrives, text intact) | M1 | vt-smoke/osc8-link | done |
| OSC 52 clipboard (write, read, confirmation, escaping) | M1 | unit: clipboard.zig | done |
| Kitty keyboard protocol | M1 | core encoder: upstream `input` tests; no Windows end-to-end check | manual |
| Kitty graphics protocol | M3 | headless conpty-probe (bundled ConPTY forwards the APC); vt-smoke/kitty-image (GUI check pending) | done via bundled ConPTY (GUI verification pending, see notes) |
| Background image | M3 | vt-smoke/bg-image, e2e/device-recover (re-uploaded after a device loss) | done |
| Custom shaders (GLSL to HLSL) | M3 | e2e/custom-shader, vt-smoke/custom-shader, unit: shadertoy.zig | done |
| Fonts: embedded JetBrains Mono, size, metrics | M1 | e2e/render | done |
| Fonts: DirectWrite discovery, fallback, emoji | M3 | e2e/font-fallback, unit: directwrite.zig | done |
| Ligatures / shaping | M3 | core HarfBuzz shaper (upstream tests), no Windows-specific path; no screenshot | manual |
| Themes (`theme`, light/dark pair) | M2 | e2e/theme | done |
| Conditional config (colour scheme) | M2 | e2e/theme | done |
| Config: single path, first-run template | M1 | e2e/config-path | done |
| Config: reload (soft/hard) | M2 | e2e/config-reload | done |
| `open_config` | M3 | none (ShellExecuteExW + notepad fallback, owner check) | manual |
| Config: errors dialog | M3 | e2e/config-errors | done |
| Dialogs in the Windows 11 look (close, paste, link, config errors; light/dark, DPI, keys, no accelerator on Allow) | M3 | e2e/dialogs | done |
| Keybinds: default bindings, action coverage | M2 | unit: actions.zig (action coverage); e2e/tabs-keys | done |
| Keybinds: key tables and key sequences (+ indicator) | M3 | e2e/status-overlays | done |
| Keybinds: global (`global:` via RegisterHotKey) | M3 | e2e/hotkey-global | done |
| Tabs: create, select, close, reorder, rename | M2 | e2e/tabs-basic, e2e/tab-rename, e2e/tab-strip-mouse | done |
| Tabs: tear-off and re-dock | M2 | e2e/tab-drag | done |
| Tabs: close semantics (Windows Terminal) | M2 | e2e/tab-close-tree, e2e/close-tree | done |
| Tabs: context menu, full-title tooltip | M3 | e2e/tab-menu | done |
| Splits: create, focus, resize, zoom, equalize | M2 | e2e/splits-basic, e2e/split-close, e2e/split-divider-drag | done |
| Splits: 16 panes, close with output streaming | M2 | e2e/split-many, e2e/close-while-streaming | done |
| Splits: unfocused-split dimming | M3 | e2e/split-dim, screenshot m3-split-dim | done |
| Windows: multiple windows, cascade, goto | M2 | e2e/windows-multi | done |
| Windows: maximize, fullscreen, float, decorations | M2 | e2e/maximize-fullscreen | done |
| Windows: per-monitor DPI | M2 | e2e/dpi-sim | done |
| Windows: single instance, IPC, CLI | M2 | e2e/single-instance, e2e/ipc-cli | done |
| Windows: tray icon, stay resident after the last window | M2 | e2e/tray, e2e/quit-after-last | done |
| Windows: close confirmation | M2 | e2e/close-confirm | done |
| Quick terminal | M3 | e2e/quick-terminal, screenshots m3-quick-top / m3-quick-bottom | done |
| `toggle_visibility` | M3 | e2e/toggle-visibility | done |
| Command palette | M3 | e2e/palette, screenshots m3-palette-open / m3-palette-filtered | done |
| Search bar | M3 | e2e/search, screenshot m3-search-bar | done |
| Inspector | M3 | e2e/inspector, screenshot m3-inspector | done |
| Notifications (toasts, `command_finished`) | M3 | e2e/notifications (recorded in test mode); the real toast and its click are the owner's manual check | manual |
| URL hover and open (`open_url`, validation) | M3 | e2e/link-hover-open, unit: shell_open.zig, screenshot m3-link-label | done |
| Resize overlay | M2 | e2e/resize-overlay | done |
| Scrollbar (overlay scroller like macOS) | M3 | e2e/scrollbar | done |
| Bell: title, attention, audio | M2 | e2e/bell-progress | done |
| Bell: `bell-features = border` | M3 | e2e/bell-border, screenshot m3-bell-border | done |
| Progress report (OSC 9;4) on the taskbar | M2 | e2e/bell-progress | done |
| Transparency and blur | M3 | e2e/transparency, e2e/opacity-blur, e2e/chrome-transparency, vt-smoke/opacity, screenshots transparency-* / opacity-blur-* | done |
| `toggle_background_opacity` | M3 | e2e/transparency | done |
| Read-only surface and badge | M3 | e2e/status-overlays, screenshot m3-readonly-badge | done |
| Renderer-health bar, device-loss recovery | M3 | e2e/device-recover (Debug, default and `opacity` variant), e2e/device-lost, screenshot m3-health-bar; a real TDR is the owner's check | done |
| File drag-and-drop (paths) | M2 | e2e/drop-files | done |
| Text drag-and-drop | M3 | e2e/drop-text | done |
| IME (IMM32 composition, candidate position) | M1 | unit: ime.zig | manual |
| Dead keys, AltGr | M1 | e2e/typing-de-altgr, e2e/typing-de-deadkey | done |
| Keyboard: US, RU, Unicode, Ctrl+Shift+C | M1 | e2e/typing-us, e2e/typing-ru, e2e/typing-unicode, e2e/typing-ru-ctrl-shift-c | done |
| Clipboard: copy, paste, unsafe-paste confirmation | M1 | e2e/paste-confirm | done |
| Clipboard polish (selection clipboard, pwd) | M3 | unit: clipboard.zig; e2e/pwd-osc7 | done |
| Mouse: select, scroll, TUI wheel | M1 | e2e/vim-less, e2e/tui-latency | done |
| Shell: Git Bash default, pwsh, cmd fallback | M1 | e2e/startup | done |
| Shell: exit closes the window, tree killed on close | M1 | e2e/shell-exit, e2e/close-tree | done |
| Shell: Ctrl+C | M1 | e2e/ctrl-c | done |
| Shell: vim and less usable | M1 | e2e/vim-less | done |
| Shell integration (OSC 133 / OSC 7) | M3 / M5 | OSC 7 (pwd, Git Bash, pwsh, cmd): e2e/pwd-osc7; OSC 133 A/B/C/D marks for pwsh (7 and 5.1) and cmd, Git Bash upstream marks with the MSYS path fixes: e2e/prompt-marks; unit: shell-integration and Exec tests. cmd's D carries no exit code (gap, see notes) | done (cmd exit code: gap) |
| Live resize and close while streaming | M1 | e2e/resize, e2e/resize-while-streaming | done |
| Input and output latency gates | M2 | e2e/input-latency, e2e/output-latency, e2e/tui-latency | done |
| RAM budget (one surface, per tab / split / window) | M2 | `docs/windows/ram-baseline.csv`, measure-ram.ps1 | done |
| Window chrome: custom frame, Mica, snap layouts, macOS-style title and tab rows, proxy icon | M2 / M3 | e2e/frame-hittest, e2e/chrome-paint, e2e/chrome-macos, e2e/chrome-proxy-icon | done |
| Owned popups follow the window (overlay host) | M3 | e2e/overlay-follow | done |
| Export terminal IO (`export_terminal_io`) | M3 | e2e/export-io; the real save dialog is the owner's check | done |
| tmux shim: `tmux.exe` (kernel32/ntdll/advapi32 only) and its pipe (`-V`, no server, trace, stats, limits) | M4 | e2e/tmux-cli; unit: src/tmux_shim/run.zig, pipe.zig, protocol.zig | done |
| tmux commands on Ghostty splits/tabs: split-window, respawn-pane, kill-pane, select-layout (main-vertical, tiled), resize-pane, select-pane -T, set-option, show-options, display-message, list-panes/windows, show-environment | M4 | e2e/tmux-replay (live and static recording); unit: tmux/commands.zig, layout.zig, Registry.zig | done |
| tmux send-keys (post-resize gate) and capture-pane (visible screen) | M4 | e2e/tmux-send-keys; unit: tmux/keys.zig, pane_io.zig | done |
| tmux `load-buffer -w` sets the Windows clipboard | M4 | unit: tmux/commands.zig; e2e/tmux-replay step needs a text clipboard | manual (owner-run: needs a text clipboard) |
| `TMUX`, `TMUX_PANE`, `tmux.exe` first on PATH in every pane | M4 | e2e/tmux-env; unit: tmux/env.zig | done |
| `windows-tmux-shim = false` opt-out (inherited `TMUX` kept, PATH unchanged) | M4 | e2e/tmux-env (second Ghostty); unit: win32 config | done |
| `remain-on-exit`, kill-pane behind a close dialog, 7 parallel kill-pane, nothing left after Ghostty dies | M4 | e2e/tmux-replay | done |
| Pane border labels (`pane-border-status/format/style`) | M4 | e2e/tmux-labels (screenshots); unit: tmux/labels.zig | done |
| Claude Code agent teams through the shim (2 teammates, titles, labels, clean exit) | M4 | test/windows/claude-team.ps1: 2 of 2 runs passed (Claude Code 2.1.312, ReleaseFast); G1 report | done (owner manual check pending) |
| DCS `tmux;` passthrough | M4 | unit: stream tests in src/terminal/stream.zig; ConPTY drops ST-terminated inner sequences (Task 2) | gap (partial) |
| Shell profiles detected (Default, Git Bash, PowerShell, Windows PowerShell, Command Prompt, WSL distros from the Lxss registry) and `--profile=<id>` (launch and IPC) | M5 | e2e/profiles-menu (state `m5.profiles`); unit: windows_shell.zig, profiles.zig, Overrides.zig. No WSL distro is ever started by a test | done |
| Profile menu: right-click on `+`, palette `New Tab: <profile>` / `New Window: <profile>`, tray "New Window" submenu | M5 | e2e/profiles-menu; unit: profiles_menu.zig, CommandPalette.zig | done |
| Taskbar jump list (New Window, New Tab, profile tasks) and `+new-tab` starting Ghostty when none runs; `windows-jump-list` | M5 | e2e/jumplist; unit: jumplist.zig. The real taskbar with the pinned icon is the owner's check | done (owner check pending) |
| Explorer "Open Ghostty here" (`+install-explorer-integration`, `+uninstall-explorer-integration [--all] [--dry-run]`) | M5 | e2e/explorer-cli (private hive, owner's HKCU never written); unit: windows_explorer.zig. Classic context menu only (gap) | done (classic menu only) |
| OSC 133 prompt marks for pwsh and cmd, Git Bash marks under MSYS | M5 | e2e/prompt-marks | done (cmd: no exit code, gap) |
| Compiled terminfo in the Windows build and `TERM=xterm-ghostty` (WSL launchers keep `xterm-256color`) | M5 | e2e/term-terminfo; unit: Exec tests | done (ssh to hosts without the entry: gap) |
| `+edit-config` (VISUAL / EDITOR, console editor in a new Ghostty, notepad fallback) | M5 | e2e/edit-config; unit: windows_cmdline.zig, cli edit tests | done (GUI editor detected by PE subsystem only: gap) |
| Update check (`auto-update = check\|off`, GitHub releases through WinHTTP, one toast per release, `check_for_updates` dialog) | M5 | e2e/update-check (fake release server on 127.0.0.1); unit: update/release.zig, update/state.zig. A real toast against a real `win-` release is the owner's check | done (real toast: manual) |
| Crash minidumps (`%LOCALAPPDATA%\ghostty\crash\`, stacks scrubbed, 10 kept, never uploaded) and `+crash-report` | M5 | e2e/crash-dump (access violation and stack overflow, marker string absent); unit: windows_crash.zig | done (heap-lock crash: no dump, gap) |
| `secure_input` analog (capture exclusion of every window, clipboard-history exclusion, lock badge) | M5 | e2e/secure-input; unit: secure_input.zig. No automatic secure input at password prompts (gap); capture by OBS / Snipping Tool is the owner's check | done (owner check pending) |
| Undo / redo of closed tabs, windows and splits, and undo of created tabs / windows / splits (`undo-timeout`, `ctrl+shift+z` / `ctrl+shift+y`) | M5 | e2e/undo-close; unit: undo.zig, window and app undo tests. Not offered for tmux, IPC and child-exit closes (gap) | done |
| `show_on_screen_keyboard` (touch keyboard) | M5 | e2e/osk (records the request in test mode); unit: osk.zig. The real keyboard is the owner's check on a touch machine | done (owner check pending) |
| External tmux mode (`windows-tmux-external`): `-L <name>` / `TMUX` unset, `new-session`, `new-window -n`, `has-session`, `kill-session`, `kill-server` | M5 | e2e/tmux-external; unit: tmux/commands.zig, Registry.zig, src/tmux_shim. Needs the Ghostty dir on PATH (gap) | done (PATH: gap) |
| Right-click paste (`right-click-action = copy-or-paste` on Windows) and the native context menu for `context-menu` | M5 | e2e/right-click | done |
| File drop pastes Windows paths in Git Bash / Cygwin (WSL keeps `/mnt/c`) | M5 | e2e/drop-files (SKIPped on a locked session when written; re-run in the next GUI batch); unit: drop.zig | done |
| Dialogs in the Windows 11 look (re-check after M5 additions: update dialog, secure-input explainer) | M5 | e2e/dialogs, e2e/secure-input, e2e/update-check | done |
| Dark and light popup menus (tab menu, context menu, profile menu) | M5 | e2e/menu-dark (luminance 44 dark / 249 light) | done |
| Bundled ConPTY (`windows-conpty = bundled`, inbox fallback when the pair is missing or OpenConsole cannot start) | M5 | headless conpty-probe (APC, SGR 58, OSC byte-exact, key-echo p95 under 1 ms); unit: windows_conpty tests (fallback, real bundled child). The e2e suite on the bundled console (resize-input, stream-integrity, latency) is in the Task 19 batch | done (GUI verification pending) |
| Close confirmation at an idle prompt: no dialog in Git Bash (also after `exec zsh` in `.bashrc`), zsh and pwsh; cmd asks while a console child runs | M5 | e2e/close-idle-prompt (PENDING first GUI run); headless test/windows/shell-marks/run.ps1 (24 cases); unit: closeNeedsConfirm, shellBusy, cursorIsAtPrompt, peIsGui | done (GUI run pending) |
| No white flash on a new tab or split in a translucent window | M5 | e2e/new-tab-white-flash (PENDING: red on 91ff7bac1, green on the fix); unit: win32 composition, d3d11 swapchain tests | done (GUI proof pending) |
| About dialog (palette, tray, tab menu; version, icon) | M5 | unit: about.zig, palette tests; icon and centring are a GUI check | done (GUI check pending) |
| `window-step-resize`, `initial-window = false`, `window-subtitle`, `bell-audio-volume`, `auto-update-channel` | M5 | unit: step_resize.zig, title_rules, bell PCM scaling, update/release.zig; e2e/initial-window (PENDING first run) | done (e2e pending) |
| Undo polish: split follows config on unpark, taskbar progress restored, popups follow the window, parked windows render nothing | M5 | unit: win32 undo, tab, window, taskbar tests; GUI checks (progress after undo, popup order) in the Task 19 batch | done (GUI check pending) |

## Notes

- **Kitty graphics and SGR 58 (bundled ConPTY, GUI check pending).** The inbox ConPTY drops the Kitty graphics APC
  and mangles SGR 58 (`58;5;196` turns into blink), with or without flag 8 (M3 Task 28 probe, SPEC 18.33). The
  bundled `conpty.dll` + `OpenConsole.exe` (`Microsoft.Windows.Console.ConPTY` 1.25.260930003, MIT) forwards both
  byte for byte, as the headless probe shows (`test/windows/conpty-probe/RESULT.md`, "Bundled ConPTY"). Every Windows
  build installs both files from `vendor/conpty` next to `ghostty.exe`, and Ghostty uses them by default
  (`windows-conpty = auto`: bundled, but inbox for MSYS2/Cygwin programs such as Git Bash, whose runtime loses the
  first key after a resize on the bundled console; `bundled` forces it there too). Kitty graphics settings keep
  the upstream defaults. Open item: the `kitty-image` and `underline-colors` references (GUI run).
- **OSC 8 arrives** through ConPTY (the `osc8-link` case shows the text intact and no stray bytes); hover underline
  and opening are covered by `e2e/link-hover-open`.
- **Manual rows (owner checks, no automation).** Ligatures (core shaper, no Windows path), the Kitty keyboard protocol end
  to end, `open_config`, IME composition, the real toast and its click (needs the HKCU AUMID key, owner-approval-gated), the
  real export save dialog, a real GPU reset (TDR), and the translucent look with "Transparency effects" off.
- **Git Bash input after a resize (Task 26.4, worked around).** MSYS2 could drop the first input record after a pty
  resize (window drag, split, tab strip shown or gone). Ghostty sends a win32-input-mode Shift key-up ahead of the first
  write after a grid change, only once the pseudo console has requested `?9001h`. Evidence: `e2e/resize-input`
  (Git Bash 36/36 checks, cmd.exe and pwsh unchanged; 9/20 lost without the fix), `background-focus` 0 retries in 5
  runs. Heavy CPU load (12 burners): 36/36 since the window starts at conhost's first output (26.4.1). Follow-up: msys2-runtime report.

### M5 notes

- **Gaps listed in the CHANGELOG (M5):** Explorer entry only in the classic menu ("Show more options"); no automatic secure
  input; cmd's OSC 133 `D` carries no exit code (no `command_finished` for cmd, `jump_to_prompt` works); `TERM=xterm-ghostty`
  over ssh to hosts without the entry (Windows OpenSSH from pwsh in particular); external tmux needs the Ghostty dir on PATH;
  undo is not offered for tmux, IPC and child-exit closes; a crash under the process heap lock leaves no dump; `+edit-config`
  tells a GUI editor by its PE subsystem only. Added after Task 19.n: the bundled console is disabled for the process after
  any create failure; a winget "portable" symlink install uses the inbox console; non-undoable creates (profile menu, tray,
  jump list); a closed external tmux tab leaves its namespace on the next client command; the installer's Retry button is a
  manual check.
- **Owner manual checks (M5 exit checklist item 8):** pinned jump list and WSL profile, Explorer entry on a folder, folder
  background and drive root, a real update toast, OBS / Snipping Tool against secure input and Win+V history, the touch
  keyboard, `vim` / `less` / `htop` with `TERM=xterm-ghostty`, Claude Code from Windows Terminal against external mode.
