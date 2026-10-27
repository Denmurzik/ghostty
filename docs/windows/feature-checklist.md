# Windows port: feature checklist

One row per cross-platform Ghostty feature (DECISIONS "Features", SPEC section 17 M1-M3). The v1.0 / M3 exit
criterion is that every row is `done` with evidence (a test, a scenario or a reference screenshot).

- **Evidence**: `e2e/<name>` is `test/windows/e2e/<name>.ps1`; `vt-smoke/<case>` is a reference PNG in
  `test/windows/vt-smoke/ref/`; `unit: <file>` are `zig build test` tests of that file; `manual` is an owner check.
- **Status**: `done` (evidence exists and passed at the last acceptance), `pending -> Task N` (M3 plan task `N` builds
  or verifies it), `gap` (known and accepted, see the note below), `manual` (only an owner check, no automation).
- `vt-smoke` rows come from M3 Task 3 and were generated on the WARP driver on 2026-10-27.

| Feature | Milestone | Evidence | Status |
|---|---|---|---|
| VT: cursor movement, erase, insert/delete (CUP, ED, EL, ECH, ICH, DCH, IL, DL) | M1 | vt-smoke/cursor-erase | done |
| VT: scroll regions (DECSTBM, IND, RI, SU/SD) | M1 | vt-smoke/scroll-region | done |
| VT: alternate screen (?1049) | M1 | vt-smoke/alt-screen | done |
| VT: DEC special graphics, G0/G1 charsets | M1 | vt-smoke/dec-graphics | done |
| VT: box drawing, block elements, braille | M1 | vt-smoke/box-drawing | done |
| VT: wide (CJK / fullwidth) cells | M1 | vt-smoke/wide-cjk (case needs T5, no reference yet) | pending -> Task 5 |
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
| Kitty keyboard protocol | M1 | core encoder: upstream `input` tests; no Windows end-to-end check yet | pending -> Task 25 |
| Kitty graphics protocol | M3 | vt-smoke/kitty-image (case needs L1; the inbox ConPTY drops APC) | gap (L1, see notes) |
| Background image | M3 | vt-smoke/bg-image | done |
| Custom shaders (GLSL to HLSL) | M3 | unit: shadertoy.zig (Task 4); D3D11 pipeline pending | pending -> Task 7 |
| Fonts: embedded JetBrains Mono, size, metrics | M1 | e2e/render | done |
| Fonts: DirectWrite discovery, fallback, emoji | M3 | vt-smoke/wide-cjk | pending -> Task 5 |
| Ligatures / shaping | M3 | none yet | pending -> Task 5 |
| Themes (`theme`, light/dark pair) | M2 | e2e/theme | done |
| Conditional config (colour scheme) | M2 | e2e/theme | done |
| Config: single path, first-run template | M1 | e2e/config-path | done |
| Config: reload (soft/hard) | M2 | e2e/config-reload | done |
| `open_config` | M3 | none yet (ShellExecuteExW) | pending -> Task 10 |
| Config: errors dialog | M3 | none yet | pending -> Task 20 |
| Keybinds: default bindings, action coverage | M2 | unit: actions.zig (action coverage); e2e/tabs-keys | done |
| Keybinds: key tables and key sequences (+ indicator) | M3 | none yet | pending -> Task 11 |
| Keybinds: global (`global:` via RegisterHotKey) | M3 | e2e/hotkey-global | pending -> Task 16 |
| Tabs: create, select, close, reorder, rename | M2 | e2e/tabs-basic, e2e/tab-rename, e2e/tab-strip-mouse | done |
| Tabs: tear-off and re-dock | M2 | e2e/tab-drag | done |
| Tabs: close semantics (Windows Terminal) | M2 | e2e/tab-close-tree, e2e/close-tree | done |
| Tabs: context menu, full-title tooltip | M3 | none yet | pending -> Task 21 |
| Splits: create, focus, resize, zoom, equalize | M2 | e2e/splits-basic, e2e/split-close, e2e/split-divider-drag | done |
| Splits: 16 panes, close with output streaming | M2 | e2e/split-many, e2e/close-while-streaming | done |
| Splits: unfocused-split dimming | M3 | e2e/split-dim | pending -> Task 6 |
| Windows: multiple windows, cascade, goto | M2 | e2e/windows-multi | done |
| Windows: maximize, fullscreen, float, decorations | M2 | e2e/maximize-fullscreen | done |
| Windows: per-monitor DPI | M2 | e2e/dpi-sim | done |
| Windows: single instance, IPC, CLI | M2 | e2e/single-instance, e2e/ipc-cli | done |
| Windows: tray icon, stay resident after the last window | M2 | e2e/tray, e2e/quit-after-last | done |
| Windows: close confirmation | M2 | e2e/close-confirm | done |
| Quick terminal | M3 | none yet | pending -> Task 17 |
| `toggle_visibility` | M3 | e2e/toggle-visibility | pending -> Task 16 |
| Command palette | M3 | none yet | pending -> Task 13 |
| Search bar | M3 | none yet | pending -> Task 12 |
| Inspector | M3 | none yet | pending -> Task 19 |
| Notifications (toasts, `command_finished`) | M3 | none yet | pending -> Task 18 |
| URL hover and open (`open_url`, validation) | M3 | none yet | pending -> Task 10 |
| Resize overlay | M2 | e2e/resize-overlay | done |
| Scrollbar (native, always visible interim) | M2 | e2e/scrollbar | done |
| Bell: title, attention, audio | M2 | e2e/bell-progress | done |
| Bell: `bell-features = border` | M3 | e2e/bell-border | pending -> Task 6 |
| Progress report (OSC 9;4) on the taskbar | M2 | e2e/bell-progress | done |
| Transparency and blur | M3 | none yet | pending -> Task 15 |
| `toggle_background_opacity` | M3 | none yet | pending -> Task 15 |
| Read-only surface and badge | M3 | none yet | pending -> Task 11 |
| Renderer-health bar, device-loss recovery | M3 | e2e/device-lost (new surfaces only until Task 24) | pending -> Task 24 |
| File drag-and-drop (paths) | M2 | e2e/drop-files | done |
| Text drag-and-drop | M3 | none yet | pending -> Task 22 |
| IME (IMM32 composition, candidate position) | M1 | unit: ime.zig | manual |
| Dead keys, AltGr | M1 | e2e/typing-de-altgr, e2e/typing-de-deadkey | done |
| Keyboard: US, RU, Unicode, Ctrl+Shift+C | M1 | e2e/typing-us, e2e/typing-ru, e2e/typing-unicode, e2e/typing-ru-ctrl-shift-c | done |
| Clipboard: copy, paste, unsafe-paste confirmation | M1 | e2e/paste-confirm | done |
| Clipboard polish (selection clipboard, pwd) | M3 | none yet | pending -> Task 23 |
| Mouse: select, scroll, TUI wheel | M1 | e2e/vim-less, e2e/tui-latency | done |
| Shell: Git Bash default, pwsh, cmd fallback | M1 | e2e/startup | done |
| Shell: exit closes the window, tree killed on close | M1 | e2e/shell-exit, e2e/close-tree | done |
| Shell: Ctrl+C | M1 | e2e/ctrl-c | done |
| Shell: vim and less usable | M1 | e2e/vim-less | done |
| Shell integration (OSC 133 / OSC 7) | M5 | none yet | pending -> M5 |
| Live resize and close while streaming | M1 | e2e/resize, e2e/resize-while-streaming | done |
| Input and output latency gates | M2 | e2e/input-latency, e2e/output-latency, e2e/tui-latency | done |
| RAM budget (one surface, per tab / split / window) | M2 | `docs/windows/ram-baseline.csv`, measure-ram.ps1 | done |
| Window chrome: custom frame, Mica, snap layouts | M2 | e2e/frame-hittest, e2e/chrome-paint | done |
| Owned popups follow the window (overlay host) | M3 | e2e/overlay-follow | pending -> Task 9 |
| Export terminal IO (`export_terminal_io`) | M3 | none yet | pending -> Task 20 |
| tmux shim + Claude Code agent teams | M4 | none yet | pending -> M4 |

## Notes

- **Kitty graphics (gap, provisional, owner-approved).** The inbox ConPTY drops APC sequences, so the Kitty graphics
  APC never reaches the terminal (L1 ruling, M3 Task 28 probe). The `kitty-image` case exists and SKIPs until a
  reference PNG can be produced; the reference step is dropped for now. The gap closes if L1 enables
  `PSEUDOCONSOLE_PASSTHROUGH_MODE` (Task 28.1) or a bundled OpenConsole.
- **SGR 58 (gap under L1).** The first vt-smoke run showed that underline colours (`CSI 58`) are lost or mangle the
  style on the inbox ConPTY: `4:1;58;2;r;g;b` produced no underline at all, `4:3;58;5;196` a white one. The case
  `underline-colors` waits for L1 like `kitty-image`.
- **OSC 8 arrives** through ConPTY (the `osc8-link` case shows the text intact and no stray bytes); hover underline
  and opening belong to Task 10.
