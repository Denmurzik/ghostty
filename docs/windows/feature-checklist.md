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
| SGR 58: underline colour | M1 | vt-smoke/underline-colors (case needs L1; the inbox ConPTY drops it) | gap (L1, see notes) |
| OSC 8 hyperlinks (sequence arrives, text intact) | M1 | vt-smoke/osc8-link | done |
| OSC 52 clipboard (write, read, confirmation, escaping) | M1 | unit: clipboard.zig | done |
| Kitty keyboard protocol | M1 | core encoder: upstream `input` tests; no Windows end-to-end check | manual |
| Kitty graphics protocol | M3 | vt-smoke/kitty-image (case needs L1; the inbox ConPTY drops APC) | gap (L1, see notes) |
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
| Shell integration (OSC 133 / OSC 7) | M3 / M5 | OSC 7 (pwd, Git Bash, pwsh, cmd): e2e/pwd-osc7 done in M3; OSC 133 prompt marks and pwsh integration: M5 | pending -> M5 |
| Live resize and close while streaming | M1 | e2e/resize, e2e/resize-while-streaming | done |
| Input and output latency gates | M2 | e2e/input-latency, e2e/output-latency, e2e/tui-latency | done |
| RAM budget (one surface, per tab / split / window) | M2 | `docs/windows/ram-baseline.csv`, measure-ram.ps1 | done |
| Window chrome: custom frame, Mica, snap layouts, macOS-style title and tab rows, proxy icon | M2 / M3 | e2e/frame-hittest, e2e/chrome-paint, e2e/chrome-macos, e2e/chrome-proxy-icon | done |
| Owned popups follow the window (overlay host) | M3 | e2e/overlay-follow | done |
| Export terminal IO (`export_terminal_io`) | M3 | e2e/export-io; the real save dialog is the owner's check | done |
| tmux shim + Claude Code agent teams | M4 | none yet | pending -> M4 |

## Notes

- **Kitty graphics (gap, provisional, owner-approved).** The inbox ConPTY drops APC sequences, so the Kitty graphics
  APC never reaches the terminal (L1 ruling, M3 Task 28 probe). The `kitty-image` case exists and SKIPs until a
  reference PNG can be produced; the reference step is dropped for now. The gap closes if L1 enables
  a newer bundled `conpty.dll` + OpenConsole (flag 8 does not rescue it, SPEC 18.33).
- **SGR 58 (gap under L1).** The first vt-smoke run showed that underline colours (`CSI 58`) are lost or mangle the
  style on the inbox ConPTY: `4:1;58;2;r;g;b` produced no underline at all, `4:3;58;5;196` a white one. The case
  `underline-colors` waits for L1 like `kitty-image`.
- **OSC 8 arrives** through ConPTY (the `osc8-link` case shows the text intact and no stray bytes); hover underline
  and opening are covered by `e2e/link-hover-open`.
- **Manual rows (owner checks, no automation).** Ligatures (core shaper, no Windows path), the Kitty keyboard protocol end
  to end, `open_config`, IME composition, the real toast and its click (needs the HKCU AUMID key, owner-approval-gated), the
  real export save dialog, a real GPU reset (TDR), and the translucent look with "Transparency effects" off.
- **Git Bash input loss (known issue; PLACEHOLDER until the Task 26.4 verdict).** Git Bash can lose the first byte typed after its pty was
  resized or after a tab switch (cmd.exe does not). It affects the `background-focus` and `device-recover` scenarios
  (they re-send) and typing right after such a change.
