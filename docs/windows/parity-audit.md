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

## Update after win.2 (2026-10-29, `1.3.2-dev-win.2`)

| Gap | Now | Evidence |
| --- | --- | --- |
| Kitty graphics in pwsh/cmd | done: images draw, the `a=q` reply reaches the program (the earlier "done via bundled ConPTY" meant only that the bytes cross the console) | `e2e/kitty-render` (5/5 cases), `vt-smoke/kitty-image`, `conpty-probe/RESULT.md` |
| Kitty graphics in Git Bash | gap by default: `windows-conpty = auto` keeps MSYS on the inbox console, which drops the query; opt-in with `windows-conpty = bundled`, which loses input lines under MSYS (7-16 of 36 per run) | `docs/windows/m7/msys-key-loss.md` |
| Kitty `t=s`, MSYS paths for `t=f`/`t=t`, DCS `tmux;` passthrough | gap (upstream parity; the shim is off by default, so no wrapping) | R-M7-11 |
| Emoji: Noto instead of Segoe UI Emoji | done: Segoe UI Symbol/Emoji (colour, COLR v0), Noto only without DirectWrite | `e2e/font-symbols`, `vt-smoke/symbols` |
| `font-thicken` | done: works on Windows (outline glyphs); no default change (owner pick) | `e2e/text-weight` |
| Tab rename look | done: themed borderless popup, no white box | `e2e/tab-rename` |
| Windows paths in links, `C:\x:12` | done | `e2e/link-windows-path`; unit: url.zig |
| Paste of files copied in Explorer (`CF_HDROP`) | done | `e2e/paste-files`; unit: drop.zig |
| `click-repeat-interval` | done: follows the system double-click time | unit: os/mouse.zig |
| pwsh `cursor`/`ssh-env`/`ssh-terminfo`, cmd `cursor`/`ssh-env`/`ssh-terminfo` | done; cmd cursor stays while a command runs (no pre-exec hook) | `shell-marks`, headless cases |
| WSL tab/split start directory | done; custom `wsl.conf` hostname is a limit | `e2e/wsl-cwd` |
| Windows 11 top-level "Open Ghostty here" | done for folders and folder backgrounds (drives: classic verb); unsigned package, one-machine test | `installer-test`, `package-portable`, G4 owner check |
| Tmux shim default | off; `windows-tmux-shim = true` for Claude Code agent teams | `e2e/tmux-env` |
| IME, ligatures, Kitty keyboard protocol, UI Automation, `window-save-state`, IPC scripting | unchanged (manual / post-v1) | this audit above |
