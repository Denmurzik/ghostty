# Ghostty for Windows — binding decisions

Owner decisions (user, 2026-10-25). These are the spec authority; changing any of them needs the owner's sign-off.

## Product
- Full native port of Ghostty to Windows 11, low RAM, published as an unofficial fork: repo `Denmurzik/ghostty`, branch `windows` (fork default branch), upstream remote = ghostty-org/ghostty, base = upstream main `cec8b92f1` (1.3.2-dev, Zig 0.17.0).
- Name: "Ghostty — Unofficial Windows port". Binary `ghostty.exe`. Original Ghostty icon.
- Archs: x86_64 + aarch64 (ARM64 only cross-built; cannot be tested locally). Minimum OS: Windows 11 22H2 (runs on Win10 best-effort, no guarantees).

## Architecture
- App runtime: NEW native Zig apprt `src/apprt/win32` — pure Win32 + DWM (Mica backdrop, dark titlebar, snap layouts). No WinUI, no GTK, no .NET.
- Renderer: NEW Direct3D 11 GraphicsAPI backend `src/renderer/D3D11.zig` + `src/renderer/d3d11/`. User custom shaders (GLSL shadertoy) are converted to HLSL via glslang → SPIR-V → SPIRV-Cross HLSL backend.
- Code is laid out so it could be upstreamed: Windows code isolated in its own dirs/arms; core changes minimal and platform-gated.

## Features
- All cross-platform Ghostty features 1:1 (VT, config, fonts, tabs, splits, multiple windows, quick terminal, command palette, search, inspector, shell integration, themes, custom shaders, Kitty graphics, background image, keybinds/key tables, notifications, URL hover/open, config reload, resize overlay…).
- macOS-only features get Windows analogs (e.g. AppleScript → CLI/IPC, Secure Keyboard Entry → analog, Quick Look → none), plus Windows extras: jump lists, shell profiles (WSL distros / pwsh / cmd / Git Bash) in a new-tab menu, Explorer "Open Ghostty here".
- Config: exactly ONE path on Windows: `%USERPROFILE%\.config\ghostty\config.ghostty` (if `XDG_CONFIG_HOME` is set it replaces the `%USERPROFILE%\.config` base, like Linux). No legacy `config` filename fallback on Windows, no AppData, no `~/.ghostty`.
- Default shell order: Git Bash → pwsh (PowerShell 7) → cmd.
- Updates: check GitHub Releases, notify via toast (`auto-update = check|off`). No auto-install.

## Built-in tmux
- Ship `tmux.exe` (Zig) next to `ghostty.exe`. It implements the tmux CLI by talking to the running Ghostty over a named pipe and mapping tmux commands onto native Ghostty splits/tabs/windows. No tmux server, no detach/attach persistence.
- Inside Ghostty sessions: `TMUX` and `TMUX_PANE` are set, the shim directory is PREPENDED to PATH (only inside Ghostty sessions).
- Primary acceptance: Claude Code agent teams with `teammateMode: "tmux"` work fully and correctly. Exact contract: `docs/windows/recon/tmux.md`.

## Release
- Portable zip + Inno Setup installer (shortcuts, "Open Ghostty here", uninstall), built by GitHub Actions on tag. No code signing certificate (SmartScreen warning accepted).
- v1.0 gate: feature checklist closed with automated tests (upstream tests on Windows, win32 apprt tests, vttest-style checks, RAM measurements, Claude Code tmux-mode run) + a pre-release smoked manually by the owner.

## Process constraints
- Machine: 15.5 GB RAM, ~4–5 GB free. Builds/test suites strictly one at a time via the teamlead `test-lock` script; zig builds with `-j6` (owner speed rules 2026-10-26; `-j4` if a build OOMs).
- Commits: no `Co-Authored-By` or similar trailers.
- Visual verification: screenshots of the Ghostty window are allowed and expected after UI/renderer changes.

## Lead rulings (made while the owner was unavailable; owner may overturn)
- R1: Panes created via `tmux.exe` get Ghostty's environment overlaid with the calling client's environment (unlike real tmux) so API keys / PATH from the leader shell reach teammates. Cost if wrong: env leakage between panes; switch to tmux semantics + `update-environment`.
- R2: The pane command string from `respawn-pane`/`split-window … -- <cmd>` is POSIX sh syntax; run it via Git Bash `bash -c` when present, else via a built-in minimal parser for Claude Code's grammar (`cd '…' && env K=V … 'exe' args`). Cost if wrong: teammates fail to start without Git Bash.
- R3: Target ABI = MSVC (upstream default; VS 18 Build Tools present locally and on GitHub runners). Cost if wrong: switch to `-gnu`.
- R4: Builtin renderer shaders are hand-written HLSL ported from `shaders.metal` (D3D11 is Y-down like Metal); only user custom shaders go through SPIRV-Cross. Runtime `D3DCompile` via `d3dcompiler_47.dll` first; build-time precompile is a later optimization.
- R5: Native Zig apprt (not the embedded C API host).

## Owner decisions (2026-10-26, morning review)
- Single instance: `detect` — a launch without arguments opens a new window in the running process; a launch with arguments (`--font-size=…`, `-e …`) starts a separate process.
- Last window closed: Ghostty stays running in the notification area (tray icon); `quit-after-last-window-closed = false` is the Windows default; the tray menu offers New Window / Quit.
- Closing a tab: Windows Terminal semantics — terminate the shell and the console processes attached to that tab's pseudo-console; separate console windows (`start cmd`, `start python x.py`), detached processes and GUI apps survive. (Supersedes lead ruling on Task 19's job-object kill-all-console policy.)
- Tab tear-off / re-dock: dragging a tab outside the window opens it in a new window (process keeps running); dragging a tab onto another window's tab strip moves it there; in-strip drag reorders.
- File drag-and-drop: dropping files/folders from Explorer onto a terminal surface inserts their paths (shell-quoted for the running shell, space-separated) as if typed/pasted — M2.
- Input latency: the owner reports heavy input lag ("вообще не отзывчивый") while testing the M1 Debug build. M2 must measure keypress-to-frame latency on ReleaseFast AND Debug, find the causes (frame pacing wait, WM_CHAR handling, renderer wakeups, Debug-only costs) and make typing feel immediate; acceptance threshold set in the M2 plan.
- Input latency (update 2026-10-26): lag reproduces on ReleaseFast too; HIGH lag in TUI apps on mouse-wheel scroll and interaction. Highest priority in M2 (first task).
- Drops into Git Bash insert POSIX msys paths ('/c/Users/…'); unknown shells use cmd-style double quotes.
- Latency gate: whole path ≤16 ms p95 ReleaseFast; if ConPTY+shell alone exceed it, try ConPTY passthrough / bundled OpenConsole like Windows Terminal; Ghostty-owned stages ≤6 ms; plus the owner's hands-on comparison against Windows Terminal. Debug may stay slower; daily use is ReleaseFast.

## Owner decision (2026-10-27): visual style follows Ghostty for macOS
- For every visual element (split dividers, tab strip and tabs, titlebar, overlays such as resize/search/command palette, quick terminal, scrollbar, inspector, dialogs) the reference is how Ghostty does it on macOS (`macos/Sources/…`): sizes in points → DIPs, colours derived the same way from the terminal palette/config, animations and spacing. Deviate only where Windows conventions require it (caption buttons, snap layouts, Mica), and say so in the task report.
