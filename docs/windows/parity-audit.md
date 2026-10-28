# Feature parity audit: upstream Ghostty vs the Windows port

Date: 2026-10-28. Base: `windows` at `12ba3e7ca` (M5 Tasks 12 and 15b still on review branches).
Method: three read-only code audits (apprt actions, config options, macOS/GTK app features). Evidence
is file:line in `src/apprt/win32`, `src/renderer/d3d11` and core; docs were not trusted over code.

## Summary

- **Apprt actions:** 67 of 70 implemented. Not implemented: `selection_changed` (needs UI Automation,
  post-v1), `toggle_tab_overview` (no tab overview on Windows, deliberate), `show_gtk_inspector`
  (GTK only). The win32 apprt implements 12 actions GTK leaves as no-ops (undo/redo, secure input,
  update check, float, toggle visibility, background opacity toggle, close all windows, and more).
- **Renderer (D3D11):** custom shaders (GLSL to HLSL), background image, alpha blending, colour
  space, vsync, minimum contrast, padding colour, background opacity: all supported.
- **App features:** quick terminal, command palette, tabs (rename, drag, tear-off), splits (zoom,
  equalize, dim), search, inspector, notifications, bell, progress, links, drag-and-drop, context
  menu, config reload and errors, global hotkeys, key tables, OSC 52 confirm, paste protection,
  theme auto switch, single instance, tray: all done. Windows extras: jump list, profiles, Explorer
  "Open Ghostty here", on-screen keyboard, tmux shim for Claude Code agent teams.

## Gaps

| Gap | Kind | Disposition |
| --- | --- | --- |
| Screen reader (UI Automation provider, `selection_changed`) | missing | post-v1 (large) |
| Window/tab restore on relaunch (`window-save-state`) | missing, option ignored | post-v1 (v1.1 candidate) |
| About dialog | missing | M5 19.n |
| Settings UI | missing (config file + `+edit-config` only) | won't do for v1 (GTK has none either) |
| Kitty graphics, SGR 58 underline colour | dropped by the inbox ConPTY | decision for M6: ship OpenConsole `conpty.dll` or keep as gap |
| ssh terminfo install to remotes (`ssh-terminfo` shell-integration feature) | partial: `TERM=xterm-ghostty` only when the remote has it | M5 19.n: verify the bash integration path in Git Bash; else document |
| IPC scripting (only new-window, new-tab, quick terminal outside test mode) | partial | post-v1 |
| Secure input | analog: blocks screen capture and clipboard history, not keyloggers | documented, by design |
| IME (IMM32, no TSF), ligatures, Kitty keyboard protocol | manual evidence only | M5 Task 19 manual checks |
| Emoji: Noto Color Emoji instead of COLRv1 Segoe UI Emoji | partial | documented |
| `window-step-resize` | option ignored | M5 19.n |
| `initial-window = false` | option ignored | M5 19.n |
| `window-subtitle` | option ignored | M5 19.n |
| `bell-audio-volume` (ignored), `bell-audio-path` (WAV only) | partial | M5 19.n: volume; other formats documented |
| `auto-update-channel` | not read | M5 19.n |
| `drag-handle` | ignored (title bar always draggable) | N/A |
| `background-blur` radius | on/off (DWM acrylic) | documented |
| `font-thicken`, `mouse-hide-while-typing`, `clipboard-write-limit-bytes` | unverified on Windows | M5 19.n: verify, fix if broken |
| `macos-icon*` / custom app icon, `macos-window-shadow`, `macos-titlebar-style` | no Windows analogue | won't do for v1 |
| Alt as Meta | core sends Alt as ESC prefix on non-macOS; AltGr handled in `key.zig` | no gap |

## Docs vs code

The feature checklist and CHANGELOG lagged behind M5 (undo, update check, secure input, OSK, jump
list, profiles, Explorer, `+edit-config`); the M5 docs commit on this branch adds them.
