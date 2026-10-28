# Feature parity audit: upstream Ghostty vs the Windows port

Date: 2026-10-28, status updated after Task 19.n batch 2 and the bundled ConPTY (`windows` at `bf428b83d`). Original base: `windows` at `12ba3e7ca`.
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
| About dialog | closed (19.n batch 2: palette, tray, tab menu, icon; icon and centring GUI check pending) | done |
| Settings UI | missing (config file + `+edit-config` only) | won't do for v1 (GTK has none either) |
| Kitty graphics, SGR 58 underline colour | closed by the bundled ConPTY (`windows-conpty = bundled`, headless probe byte-exact); GUI references `kitty-image`, `underline-colors` pending | done, GUI verification pending |
| ssh terminfo install to remotes (`ssh-terminfo` shell-integration feature) | checked headless in Git Bash: `ghostty +ssh` runs and tries the install; a real remote install not tested | closed (19.n batch 2), remote test open |
| IPC scripting (only new-window, new-tab, quick terminal outside test mode) | partial | post-v1 |
| Secure input | analog: blocks screen capture and clipboard history, not keyloggers | documented, by design |
| IME (IMM32, no TSF), ligatures, Kitty keyboard protocol | manual evidence only | M5 Task 19 manual checks |
| Emoji: Noto Color Emoji instead of COLRv1 Segoe UI Emoji | partial | documented |
| `window-step-resize` | closed (19.n batch 2) | done |
| `initial-window = false` | closed (19.n batch 2; e2e/initial-window pending first run) | done |
| `window-subtitle` | closed (19.n batch 2: `working-directory` shows `title - pwd`) | done |
| `bell-audio-volume`, `bell-audio-path` (WAV only) | volume closed (19.n batch 2); other formats stay a documented gap | done / documented |
| `auto-update-channel` | closed (19.n batch 2: `stable` skips pre-releases) | done |
| `drag-handle` | ignored (title bar always draggable) | N/A |
| `background-blur` radius | on/off (DWM acrylic) | documented |
| `font-thicken`, `mouse-hide-while-typing`, `clipboard-write-limit-bytes` | checked by code reading (19.n batch 2): `font-thicken` is macOS only upstream (documented, no Windows effect); the other two are core logic, no runtime check | closed / documented |
| `macos-icon*` / custom app icon, `macos-window-shadow`, `macos-titlebar-style` | no Windows analogue | won't do for v1 |
| Alt as Meta | core sends Alt as ESC prefix on non-macOS; AltGr handled in `key.zig` | no gap |

## Docs vs code

The feature checklist and CHANGELOG lagged behind M5 (undo, update check, secure input, OSK, jump
list, profiles, Explorer, `+edit-config`); the M5 docs commits add them, including the 19.n batches and the bundled ConPTY.
Still open after this update: UI Automation screen reader, `window-save-state` restore, IPC scripting (all post-v1);
GUI proof for About, `initial-window`, Kitty graphics and SGR 58 on the bundled console.
