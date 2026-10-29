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
- 2026-10-29 (owner, win.2): symbols and emoji follow macOS and Windows Terminal: Segoe UI Symbol / Segoe UI Emoji on Windows, the embedded Noto emoji only without DirectWrite. Text weight: the owner compared the four `text-weight` variants and kept today's rendering (`linear-corrected`, no `font-thicken`); `font-thicken = true` now works on Windows for those who want heavier text.
- 2026-10-29 (owner, win.2): Explorer "Open Ghostty here" is also in the Windows 11 top-level menu (folders and folder backgrounds; drives keep the classic verb) through an unsigned sparse package registered by the installer (`Add-AppxPackage -ExternalLocation`); the installer task `explorermenu` is ticked by default. Residual risk accepted: tested only on the owner's machine; the classic verb stays for Windows 10 and as the fallback.
- Config: exactly ONE path on Windows: `%USERPROFILE%\.config\ghostty\config.ghostty` (if `XDG_CONFIG_HOME` is set it replaces the `%USERPROFILE%\.config` base, like Linux). No legacy `config` filename fallback on Windows, no AppData, no `~/.ghostty`.
- Default shell order: Git Bash → pwsh (PowerShell 7) → cmd.
- Updates: check GitHub Releases, notify via toast (`auto-update = check|off`). No auto-install.

## Built-in tmux
- Ship `tmux.exe` (Zig) next to `ghostty.exe`. It implements the tmux CLI by talking to the running Ghostty over a named pipe and mapping tmux commands onto native Ghostty splits/tabs/windows. No tmux server, no detach/attach persistence.
- Inside Ghostty sessions: `TMUX` and `TMUX_PANE` are set, the shim directory is PREPENDED to PATH (only inside Ghostty sessions).
- Primary acceptance: Claude Code agent teams with `teammateMode: "tmux"` work fully and correctly. Exact contract: `docs/windows/recon/tmux.md`.
- 2026-10-29 (owner, win.2): the shim is **off by default** (`windows-tmux-shim = false`): panes get no `TMUX`/`TMUX_PANE` and `PATH` is unchanged, so tools that detect tmux (Kitty graphics, Claude Code) behave as in a plain terminal. `tmux.exe` stays in the package; Claude Code agent teams need `windows-tmux-shim = true`. (Amends "Inside Ghostty sessions: `TMUX` and `TMUX_PANE` are set…", which applies with the key on.)

## Release
- Portable zip + Inno Setup installer (shortcuts, "Open Ghostty here", uninstall), built by GitHub Actions on tag. No code signing certificate (SmartScreen warning accepted).
- v1.0 gate: feature checklist closed with automated tests (upstream tests on Windows, win32 apprt tests, vttest-style checks, RAM measurements, Claude Code tmux-mode run) + a pre-release smoked manually by the owner.
- 2026-10-28 (owner): releases are built locally with `dist/windows/release.ps1`; GitHub Actions is optional and manual-only. (Amends "built by GitHub Actions on tag": the owner's Actions minutes are exhausted.)
- 2026-10-28 (lead ruling, owner sign-off pending in the M6 acceptance): ARM64 release artifacts use `aarch64-windows-gnu` (amends R3); `-Arm64Abi msvc` once the VS ARM64 component is installed.

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

## 2026-10-27 — Window chrome redesign after Ghostty for macOS (owner, grill session)
Reference: the owner's screenshot of Ghostty for macOS (Tahoe titlebar tabs) + `macos/Sources/Features/Terminal/**`. No "liquid glass" effect.
- Two rows: a title row, and a tab row below it. The title row and the terminal share one background (terminal background colour, no seam); later one `background-opacity` for the whole window (title + tabs + terminal).
- Window buttons (minimise / maximise / close) stay on the right, Windows style, thin, drawn in the terminal colours; Snap Layouts keep working.
- Title row: proxy folder icon + window title, CENTERED. Window title = focused surface title like macOS (`BaseTerminalController.computeTitle`: title override, bell marker when `bell-features` has `title`, ghost fallback). Icon = Windows shell folder icon of the focused surface's pwd, shown only when the pwd is known (`macos-titlebar-proxy-icon` honoured). Icon actions: click opens the folder in Explorer; right-click shows a path menu (parent folders → open in Explorer, "Copy path"); drag the icon out as a folder (OLE drag source).
- Tab row: shown only with ≥ 2 tabs (`window-show-tab-bar` auto/always/never like macOS). Equal-width tabs filling the row, title centered, the selected tab a lighter rounded pill, thin separators between others, macOS shapes/sizes; the real keybinding of `goto_tab:N` from the config at the right of each tab (nothing if unbound); `×` appears on hover at the RIGHT (replacing the shortcut label); middle click closes; "+" always at the far right as a round button.
- Animations like macOS (~0.2 s): a new tab pushes the others and grows, a closed tab shrinks, drag-reorder slides neighbours, the tab row slides in when the second tab appears — the terminal grid resizes ONCE (no animated pty resizes).
- Inactive windows dim title text like macOS.
- Transparency/blur (with M3 Tasks 14/15): blur must stay on when the window is inactive (not only while focused) — the system Acrylic/Mica backdrops go solid on deactivation, so use a backdrop that persists.
- Order: first the look with opaque background (supersedes M3 Task 29's scope), then unified transparency with Tasks 14/15.
- 2026-10-27 (owner): the translucent window is FROSTED like Acrylic (blur + tint), not plain see-through, and stays frosted while the window is inactive. Applies to the whole window (title row + tab row + terminal). `background-blur` defaults to on when `background-opacity < 1`.
- 2026-10-27 (M3 Task 15a, transparency): translucent windows use the system Acrylic (`DWMSBT_TRANSIENTWINDOW`) over a transparent client; `WM_NCACTIVATE(FALSE)` is swallowed so DWM keeps the blur while the window is inactive (measured: without it Acrylic goes solid). It is not swallowed with `window-decoration = server` (the native caption must show inactive). Accepted side effects: the owner of a MessageBox and a second Acrylic window are drawn active too. Whether a window can be translucent is decided at creation (a window shown opaque, or that showed an hwnd swap chain, keeps an opaque surface for good, measured): a window born opaque stays solid after a reload to a translucent config (restart, like macOS) and `toggle_background_opacity` on it is a no-op (returns false); a window born translucent goes solid at `background-opacity = 1` and back without a restart. `background-blur` defaults to `true` on Windows and only matters with `background-opacity < 1`; the radius is ignored. Split dividers stay opaque.

## 2026-10-28 — Dialogs in Windows 11 style (owner request; lead ruling)
Deliberate departure from "visual style follows Ghostty for macOS": the owner asked for the dialogs to look like Windows 11. TaskDialog/MessageBox (Vista/10 look, light only, square) are replaced by our own modal window drawn like a WinUI 3 `ContentDialog` (`src/apprt/win32/dialog/`, public API of `dialogs.zig` unchanged; MessageBox stays as the fallback when the window cannot be built).
- Window: owned `WS_POPUP` with a thick frame whose non-client area is removed (shadow and rounded corners from DWM, `DWMWCP_ROUND`), centred on the owner, owner disabled while it runs a local message loop. Dark or light follows the owner window's immersive-dark flag, which `theme.zig` sets from the config/system scheme. Mica (`DWMSBT_MAINWINDOW`, frame extended over the client area) where the system has it, a solid fill otherwise (before 22H2, high contrast).
- Look: 24 DIP padding, 12 DIP title-to-body gap, width 320..548 DIP, Segoe UI Variable Display Semibold 20 px title, Segoe UI Variable Text 14 px body, button bar 80 DIP high (`#202020` dark, `#F3F3F3` light), buttons 32 DIP high, 8 DIP apart, equal widths, radius 4. All text and buttons are Direct2D/DirectWrite, grayscale AA, per-monitor DPI.
- The default button (Cancel for every question that is hard to undo, Reload for config errors) gets the accent style, as WinUI does: Enter presses the focused button, so the accent button is the one Enter takes first. Others: subtle fill with a 1 px border. Hover, pressed and keyboard focus (2 px outer and 1 px inner stroke, shown only after a key) follow WinUI tokens.
- Accent colour: the colour the user picked in Settings (`HKCU\...\DWM\AccentColor`), shaded as WinUI does (lighter on dark, darker on light), black or white text by contrast; `#0067C0` light / `#4CC2FF` dark when none. `DwmGetColorizationColor` was tried first and rejected: it is the accent mixed with the glass tint and comes out grey.
- Keys: Enter, Esc (cancel), Alt+F4, Tab/Shift+Tab, arrows, Alt+letter for `&` accelerators. Buttons are real owner-drawn `BUTTON` children, so Narrator reads them; the window text is the title and a one-pixel hollow `STATIC` (in the corner DWM rounds away) carries the body text. The title area drags the dialog (`HTCAPTION`).
- Safety: everything shown goes through `dialog/text.zig`: control characters become their Unicode control pictures, bidi and invisible formatting characters are written out as `<U+202E>`, never drawn or obeyed. Text is never cut to fit: a body too tall for 80% of the work area moves into the scrollable list, and long unbroken words (URLs) wrap by character.
- List (config errors): a read-only multi-line `EDIT` in a code font (Cascadia Mono, else Consolas), selectable, scrollable, themed (`DarkMode_Explorer` in dark). Such a dialog has no Mica: GDI controls draw with alpha 0 on glass (measured: their light text came out as the backdrop colour), so it uses the solid fill. All other dialogs are Mica.
- e2e scenarios that drove the old task dialogs now look for the window class `GhosttyDialog` instead of `#32770`; the automation message `WM_USER + 102` (press button id wparam, the old `TDM_CLICK_BUTTON`) is kept.
