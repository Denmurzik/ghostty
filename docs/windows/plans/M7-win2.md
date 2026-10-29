# M7 — win.2 (tmux shim off, system symbols, themed tab rename, text weight, Windows links and file paste, pwsh/cmd ssh and cursor, WSL cwd, Kitty images, Win11 top-level "Open Ghostty here", release `-win.2`): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the second Windows-port release, `<zon>-win.2` (tag `win-<zon>-2`), fixes what the owner found after v1.0 and ships the agreed scope of `docs/windows/issues-after-v1.md` § 7:
- `windows-tmux-shim = false` by default: no `TMUX`/`TMUX_PANE` and no PATH prepend in panes, so Claude Code keeps truecolor and its image path; `tmux.exe` still ships, and the tmux scenarios turn the key on;
- the installer's Explorer task is ticked by default;
- text symbols and emoji come from Segoe UI Symbol / Segoe UI Emoji (system discovery) as on macOS and in Windows Terminal; the embedded Noto pair is used only when DirectWrite is unusable;
- the tab rename editor is a themed, borderless owned popup styled after `macos/Sources/Helpers/TabTitleEditor.swift`, with a pixel check;
- a measured comparison of `alpha-blending = native` / `linear-corrected` and `font-thicken` (made to work on Windows), and a new Windows default only if the owner finds one better;
- links to `C:\path\file:12` and `.\src\x`, pasting files copied in Explorer (`CF_HDROP`), `click-repeat-interval = 0` = the system double-click time;
- pwsh and cmd shell integration: `cursor`, `ssh-env`, `ssh-terminfo`; WSL tabs and splits inherit the directory from OSC 7;
- Kitty graphics: a GUI pixel check in pwsh on the bundled ConPTY, the `a=q` reply path through ConPTY input (probe, then a fix or a documented limit), a ruling on DCS tmux passthrough;
- Kitty in Git Bash: an investigation of the first-key loss after a resize on the bundled ConPTY under MSYS, compared with Windows Terminal; MSYS moves to the bundled console only if the loss is gone, else a documented limit with upstream bug-report text (not filed);
- the Windows 11 top-level "Open Ghostty here": an `IExplorerCommand` COM DLL (Zig), an unsigned sparse package, installer register/unregister, the classic verb kept, the locked-DLL case on upgrade handled by the Retry loop;
- docs and the release, `release.ps1 -N 2`, run by the lead with the owner.

Exit: the owner signs § M7 exit checklist, then publishes the pre-release from `publish.txt`.

**Architecture:** no new subsystem except the Explorer command. Everything else is a change inside an existing module:
- **Defaults** in `src/config/Config.zig` (tmux shim; later the text-weight default and the `windows-conpty` doc).
- **Fonts:** `src/font/SharedGridSet.zig` (the emoji block) and `src/font/discovery.zig` (`Windows.discoverFallback` ordering by presentation); `src/font/face/freetype.zig` (`font-thicken` as an outline embolden, Windows only).
- **apprt:** `title_edit.zig` (popup editor), `clipboard.zig` (`CF_HDROP` read, reusing `drop.zig`'s parser and quoting).
- **termio:** OSC 7 for WSL panes and `wsl.exe --cd`; a pure `win32_input.zig` encoder used for Kitty replies (conditional).
- **Shell integration:** `pwsh/ghostty.ps1`, a new `cmd/ssh.cmd`, `shell_integration.zig` `setupCmd`.
- **Explorer command:** a std-only Zig DLL `ghostty-explorer.dll` (`src/explorer_command/`, built like `tmux.exe` by `src/build/GhosttyExplorerCommand.zig`), a sparse package `ghostty-explorer.msix` made by `makeappx` at packaging time, registered by the installer with `Add-AppxPackage -ExternalLocation {app} -AllowUnsigned`. `ghostty.exe` gets **no** package identity (AUMID, toasts and jump list stay as in v1.0).

**Tech Stack:** Zig 0.17.0, Windows PowerShell 5.1, Inno Setup 6.4+, Windows SDK 10.0.26100 `makeappx.exe` (present on the owner's machine under `%ProgramFiles(x86)%\Windows Kits\10\bin\10.0.26100.0\<arch>\`), Git for Windows, the bundled ConPTY 1.25.260930003 (unchanged).

**Spec:** `docs/windows/SPEC.md` and `docs/windows/DECISIONS.md` are the authority, amended by this plan's rulings (Task 17 records them as §18 R-M7-*).
- SPEC §9 (fonts), §10 (child environment), §12 (tmux shim), §13 (packaging), §17 (milestones), §18 (rulings).
- DECISIONS "Built-in tmux" (the PATH/TMUX line is amended by the owner's 2026-10-29 decision), "Release", "Process constraints".
- `docs/windows/issues-after-v1.md` § 1–6a (analysis) and **§ 7 (owner decisions, binding, not re-asked)**, plus § 2 "Owner decision: turn the tmux shim off" and § 4 "Owner decision" on symbols.
- M6: `docs/windows/plans/M6-release.md` (release path R-M6-1…12, unchanged), `docs/windows/RELEASING.md`.

**Starts** at `windows` @ `b861c0d40`. Task numbers are identities, not order: the wave table is the execution order. Tasks 11, 12, 13 and 16 have a condition stated in their header; a task whose condition is false is closed with a one-line ledger note and no commit.

## Global Constraints

Carried from M1–M6 (every task implicitly includes these):

- **Zig and target.** Zig 0.17.0 at `C:/tools/zig-x86_64-windows-0.17.0/zig.exe` (full path). Shell for agents: Git Bash. x64 `x86_64-windows-msvc`; ARM64 release artifacts `aarch64-windows-gnu` (R-M6-11). Minimum OS: Windows 11 22H2 (Windows 10 best effort; the top-level Explorer entry is Windows 11 only).
- **Scope.** Core edits only in § M7 core touch points. A cause found outside them: the implementer stops with evidence, and the lead schedules an `n.1` task.
- **Commits:** one commit per task with the message given in the task; **no `Co-Authored-By` or any other trailer**. Never `python -` (nor `python3 -` with a heredoc).
- **Issues and PRs:** never create a GitHub issue or PR (AGENTS.md). Task 16 writes bug-report **text** into a doc; nobody files it.
- **Worktree bootstrap:** `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.
- **RAM.** Every build and test compile runs through the test-lock (≥ 2 GB free per slot). Never the full test suite locally: always a focused `-Dtest-filter`. Check free memory before a heavy step; when unsure, run smaller parts (owner's global rule).
- **Privacy.** No Windows user name in any committed file, report, ledger, log excerpt, screenshot file name or published artifact. Paths are written `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`, `%TEMP%`. The M6 `Test-Privacy` scan stays on for every packaged file, including the new DLL and `.msix`.
- **PowerShell 5.1 rules** (M6): `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, inbox modules only; no bare `bash` (Git Bash by full path); native commands through `Invoke-Native`; **no non-ASCII literal in a `.ps1`/`.psm1`** (`[char]0x23FA`); each new script must parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```

**Owner safety (M2–M6 rules, restated; none needs a per-run approval because none touches owner state):**

- **GUI only through the runner.** Every GUI run goes through `test/windows/e2e.ps1` (desktop lock, sandbox env from `New-E2eSandbox`, `--class=<scenario class>`, `Register-OwnGhostty`, stop in `finally`, captures only through `Get-ScreenShot`/`Save-WindowShot`/frame dumps). `vt-smoke.ps1` takes the same desktop lock. Implementers never start a GUI; they may run a scenario's SKIP path, headless probes (`conpty-probe/headless.ps1`, `shell-marks/run.ps1`) and `-SelfTest` modes, which open no window.
- **Registry and packages.** No test, scenario, implementer run or `release.ps1` run writes the real `HKCU`/`HKLM` or registers/removes an AppX package.
  - The Explorer CLI runs only with `--dry-run`, or with `GHOSTTY_WIN32_TEST_IPC=1` **and** `GHOSTTY_WIN32_TEST_HIVE=<file>`.
  - Only the `/DGhosttyTest` installer runs in scripts; it has no Explorer task and no package code (R-M7-13).
  - `Get-AppxPackage` (read-only) is allowed in scenarios; `Add-AppxPackage`/`Remove-AppxPackage` run only in the owner's manual checks (§ M7 exit checklist 9) or on the owner's explicit go in G4.
- **Files.** Scripts write only under `zig-out\`, the e2e sandbox and `%TEMP%`. Nothing writes the owner's `%USERPROFILE%\.config\ghostty`, `%LOCALAPPDATA%\Programs`, the Start menu or the desktop.
- **Network.** No test reaches the internet; loopback only. The `ssh` features are tested against a fake `ssh.exe` (Task 7); a real host is an owner manual check.
- **Clipboard.** A scenario that touches the clipboard saves every format first and restores it in `finally` (`lib/Clipboard.psm1`).
- **Outward-facing actions** (push, tag, `gh release …`, publishing) are the owner's. `release.ps1` prints them.
- **WSL.** No scenario starts a WSL distro: the WSL scenario uses a fake `wsl.exe` (argv0 basename is what Ghostty checks).

Speed rules (owner, memory "speed over ceremony"):

- Up to **5 writers** in flight, each in its own git worktree; file sets inside a wave are strictly disjoint.
- Builds and tests: `-j6` through the test-lock. Bash timeout 600000.
- Implementers run: the task's unit filter(s), `LOCK ZIG build -j6`, script parse checks, `-SelfTest`/`-DryRun`, headless probes. **The lead runs every GUI e2e, batched at the wave end (G1–G4).** A task adds or extends only the scenarios in its **Files:** list (one per feature it adds; Task 1 only adds a config line to the tmux scenarios).
- **Review tier** per task: `light` = one batched sonnet review per wave; `opus` = per-task review for code loaded into Explorer, what an installer writes or deletes, a program-output-to-argv path, or release integrity.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --` (agents, from Git Bash only).
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `PS` = `powershell -NoProfile -ExecutionPolicy Bypass -File`
- `E2E` = `PS test/windows/e2e.ps1` (lead only, after the build it tests).
- `VTS` = `PS test/windows/vt-smoke.ps1` (lead only).
- `RFS` = M6's local x64 release recipe (`ZIG_GLOBAL_CACHE_DIR="$PWD/zig-out/zig-global" LOCK ZIG build -j4 -Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtarget=x86_64-windows-msvc --prefix zig-out/rfs`).
- New test name prefixes (each falls into a `release.ps1` unit group): `windows font: `, `windows shell integration: `, `windows osc7: `, `windows win32-input: `, `windows mouse: ` (group 2, filter `windows `); `config url: ` (group 3, filter `config`); `win32 title edit: `, `win32 clipboard: `, `win32 tmux env: ` (group 1, filter `win32 `); `Exec: wsl` (group 2, `Exec: w`); `explorer command: ` (its own step, `test-explorer-command`, added to `release.ps1` by Task 14).

### M7 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/config/Config.zig` | `windows-tmux-shim` default `false` + doc; `font-thicken` doc; the Windows text-weight default (conditional); `windows-conpty` doc | 1, 11, 16 |
| `src/font/SharedGridSet.zig` | the emoji-fallback block skips the embedded Noto pair on Windows when DirectWrite works | 2 |
| `src/font/discovery.zig` | `Windows` fallback order by presentation (text → Segoe UI Symbol first; emoji → Segoe UI Emoji first) | 2 |
| `src/font/face/freetype.zig` | `font-thicken`/`font-thicken-strength` as an outline embolden, `builtin.os.tag == .windows` only (Linux unchanged) | 4 |
| `src/renderer/image.zig` | the image step binds its linear-clamp sampler explicitly (issues § 2a.4) | 5 |
| `src/config/url.zig` | a Windows-only path branch appended to `regex` | 6 |
| `src/os/mouse.zig` | `.windows => GetDoubleClickTime()` | 6 |
| `src/termio/shell_integration.zig` | `setupCmd`: cursor in `PROMPT`; the `cmd` dir first on `PATH` when an `ssh-*` feature is on | 7 |
| `src/shell-integration/pwsh/ghostty.ps1`, `src/shell-integration/cmd/ssh.cmd` (new) | `cursor`, `ssh-env`, `ssh-terminfo` | 7 |
| `src/termio/stream_handler.zig` | OSC 7 in a WSL pane keeps a POSIX path (8); Kitty replies tagged for win32-input wrapping (12) | 8, 12 |
| `src/termio/Exec.zig` | `wsl.exe --cd <posix>` for an inherited POSIX cwd (8); wrapping of tagged replies when the console asked `?9001h` (12) | 8, 12 |
| `src/termio/win32_input.zig` (new) | pure win32-input-mode encoder | 12 |
| `src/os/windows.zig` | `conptyWantsBundled`: MSYS → bundled (only if Task 16's condition holds) | 16 |
| `src/build/windows_version.zig`, `dist/windows/versioninfo.rc` | `Exe.explorer_command`; `GHOSTTY_FILETYPE` (`VFT_DLL`) | 10 |
| `src/build/GhosttyExplorerCommand.zig` (new), `src/build/main.zig`, `build.zig` | DLL build, install on win32, `test-explorer-command` step | 10 |

Not touch points: the Kitty core (`src/terminal/kitty/**`), `src/terminal/dcs.zig` (R-M7-11: no tmux-passthrough unwrap), `build.zig.zon`, upstream workflows.

### RAM and latency budget

| Item | Budget | Measured by |
|---|---|---|
| RC `ghostty.exe`, default config, 1 window 1 surface, 30 s after start | ≤ M6 acceptance row + 1 MB (the skipped Noto faces should make it lower) | Task 18 |
| RC with a Kitty image on screen (Task 5 scenario's image) | reported, not budgeted | Task 18 |
| Key echo, Ghostty-owned p95 | within +0.5 ms of M6 (Task 12 wraps only Kitty replies, never keys) | Task 18 |
| Startup to first frame | within +10 ms of M6 | Task 18 |
| `ghostty-explorer.dll` | ≤ 300 KB ReleaseFast, imports ⊆ kernel32, ole32, shell32 (no CRT) | Task 10, Task 14 check |
| `tmux.exe` | unchanged (no code change) | — |

Over budget: DONE_WITH_CONCERNS with numbers.

## Review Focus

1. **Code loaded into Explorer** (Task 10). A fault in `ghostty-explorer.dll` takes down `explorer.exe` (or its surrogate). Every COM method checks its pointers, never panics (`ReleaseFast` with `@panic` → `E_FAIL` paths), allocates returned strings with `CoTaskMemAlloc`, keeps a correct reference count (`DllCanUnloadNow` = no objects and no locks), and launches `ghostty.exe` from the DLL's own directory only. Tests: Task 10 in-process COM tests; owner checklist 9.
2. **What the installer writes and deletes** (Tasks 1, 15). The Explorer task now defaults to ticked. The sparse package is registered only on Windows 11 with the task ticked, removed on uninstall, and the locked DLL never makes Setup offer Ignore. The `/DGhosttyTest` variant never registers a package. Tests: Task 15 `installer-test` (read-only `Get-AppxPackage` snapshot), owner checklist 9.
3. **Program output becomes a process argument** (Task 8). An OSC 7 path from a WSL pane becomes `wsl.exe --cd <path>`. Only an absolute POSIX path without control characters is accepted; it is passed as one argv element through the existing builder; a non-WSL surface never gets it; UNC/WebDAV stay rejected (SPEC §18, NTLM). Tests: Task 8 unit tests and `wsl-cwd`.
4. **Behaviour change for tmux users** (Task 1). Claude Code agent teams no longer open as splits unless `windows-tmux-shim = true`. Docs and notes say so in the first lines; the M4 scenarios and `claude-team.ps1` still pass with the key on. Tests: G1 tmux batch, Task 18 `claude-team.ps1`.
5. **Glyph changes are deliberate** (Tasks 2, 4, 11). Symbols and emoji move to system faces; a text-weight default changes only with the owner's pick; every changed vt-smoke reference is inspected before it is committed. Tests: Task 2 unit tests and `font-symbols`, vt-smoke refs (G1, G3).
6. **Paste safety** (Task 6). Pasted file paths go through the same paste path as text (bracketed paste, `clipboard-paste-protection`), quoted exactly as a drop is for the pane's shell. Tests: `win32 clipboard:` unit tests, `paste-files`.
7. **Release integrity and privacy** (Tasks 14, 18). The DLL and `.msix` are in the stage, the zip, the installer and the privacy scan; the CLSID in the DLL equals the manifest's; the notes state the residual risk of the context menu (tested on one machine). Tests: Task 14 checks, G4, Task 18.

## Rulings (plan-m7, 2026-10-29; lead/owner may overturn; recorded in SPEC §18 by Task 17)

The owner's win.2 decisions (`issues-after-v1.md` § 7, binding, not re-asked) are the Goal. Lead rulings that fill in the details:

- **R-M7-1 tmux shim off.**
  - `windows-tmux-shim` defaults to `false`. With it off, `env.apply` leaves `TMUX`, `TMUX_PANE` and `PATH` as inherited (unchanged code path).
  - The tmux pipe server still starts (it is what a reload with the key on uses for new surfaces; cost ~0).
  - `tmux.exe` stays in the zip and the installer; `package-portable` checks it with the key on.
  - **With the key on**, panes also get `CLAUDE_CODE_TMUX_TRUECOLOR=1` unless the environment already has it (issues § 1: the shim's "outer terminal" is Ghostty, which is truecolor). One line + one test.
  - DECISIONS "Built-in tmux" gets an amendment line (Task 17) instead of an edit of the original line.
- **R-M7-2 Explorer task ticked.** The task is renamed `explorer` → `explorermenu` (same description, no `Flags: unchecked`). Inno remembers tasks by name, so an upgrade from v1.0, where almost nobody ticked the old box, shows it ticked once; later upgrades remember the user's choice. Unticking on an upgrade still removes nothing (R-M6-4); the uninstaller does.
- **R-M7-3 Symbols and emoji.**
  - In `SharedGridSet`'s emoji block, the embedded `emoji` and `emoji_text` faces are added on Windows **only when `Windows.dw == null`** (DirectWrite unusable). Darwin and Linux behaviour is unchanged.
  - `Windows.discoverFallback` orders its fixed list by the requested presentation: text → `Segoe UI Symbol` before `Segoe UI Emoji`; emoji → `Segoe UI Emoji` first. `MapCharacters` stays in front of the list as today.
  - JetBrains Mono, Symbols Nerd Font and the sprites are unchanged (macOS parity).
  - **Colour check.** Win11 `seguiemj.ttf` is COLRv1 with v0 records; the FreeType path renders COLR v0 layers (`freetype.zig` colour branch). Task 2 asserts a BGRA bitmap for U+1F600. **If that fails**, emoji presentation keeps the embedded Noto Color Emoji (text symbols still go to Segoe UI Symbol), and Task 2 reports DONE_WITH_CONCERNS for the owner. This is the only fallback from the owner's decision, and it exists only because otherwise colour emoji would turn grey.
  - New Unicode emoji that Segoe UI Emoji lacks show as missing glyphs (macOS-like); `font-codepoint-map` remains the override.
- **R-M7-4 Tab rename editor.**
  - An owned borderless popup (`WS_POPUP`, owner = the top-level window), opaque, over the tab (or the title area for `prompt_title` on the window). It reuses the overlay `.panel` activation bookkeeping (`overlay.zig` `panel_activation`, the SearchBar pattern) so the window keeps its active look while the popup has focus.
  - The `EDIT` is a child of the popup with `ES_CENTER | ES_AUTOHSCROLL`, no `WS_BORDER`, no client edge. `WM_CTLCOLOREDIT` returns the tab's own background (the active-tab fill of `theme.palette`) and sets the tab title colour, so the editor looks like the tab label made editable (macOS: `isBordered = false`, `drawsBackground = false`, `focusRingType = .none`, centred, the label's font).
  - Font: the tab title family (`Chrome.shared().title_family`: Segoe UI Variable Text, else Segoe UI) at the tab title size for the window's DPI, `CLEARTYPE_QUALITY`. Horizontal inset 6 px × scale, as macOS.
  - Behaviour unchanged: Enter commits, Esc cancels, focus loss commits (as today), an empty commit clears the user title. The popup follows the window on move (overlay follow) and closes on tab close, tab switch, DPI change and window hide.
- **R-M7-5 Text weight.**
  - `font-thicken` works on Windows (it is a no-op today): outline glyphs only, `FT_Outline_EmboldenXY` with `x = y = (16 + strength * 48 / 255)` in 26.6 units (¼ px at strength 0, 1 px at 255), after the synthetic-bold step and before rendering; advance and cell metrics unchanged; colour and bitmap glyphs untouched. Linux FreeType is not changed.
  - **Comparison (Task 4 scenario, G1):** four variants A `linear-corrected` (today), B `native`, C `linear-corrected` + `font-thicken`, D `native` + `font-thicken`, same sample text (Claude Code orange `#D77757`, the Git Bash prompt colours SGR 32/33/35, white, grey `#808080` on the default background, and dark text on a light row), at the machine's DPI. Output: one PNG per variant, a contact sheet, and per-row ink coverage numbers.
  - **Decision rule:** the owner looks at the contact sheet (optionally next to a Windows Terminal screenshot of the same sample file, which the owner takes; the harness never captures a foreign window) and names a variant. If the owner names B, C or D, Task 11 makes it the Windows default; if A or no answer before W3 starts, the default stays and Task 11 only fixes the `font-thicken` doc.
  - A default change regenerates every vt-smoke reference (G3), each inspected.
- **R-M7-6 Windows paths in links.** A branch appended to `url.regex` only when `builtin.target.os.tag == .windows`:
  - drive-absolute `X:\…` and `X:/…` (not preceded by a word character);
  - dot-relative `.\…` and `..\…`;
  - bare relative with a backslash and a dotted last segment (`src\config\url.zig`);
  - the existing rules apply: no trailing `.`/`,`/`:`, parentheses only when balanced, space segments as for POSIX paths, `:line[:col]` kept in the match (`shell_open.stripPosition` already handles it);
  - never UNC (`\\server\…`, `\\?\…`), so a link can never contact an SMB share.
- **R-M7-7 Pasting files.** When the clipboard has `CF_HDROP` and no `CF_UNICODETEXT`, a paste reads the file list with `drop.pathsFromDropFiles`, quotes it with `drop.quote` for the surface's shell kind (`drop.shellKindFor`), and continues down the normal text-paste path (bracketed paste, paste protection). Text wins when both formats exist (Explorer puts only `CF_HDROP` for a file copy). Images on the clipboard stay unsupported. An OSC 52 read never returns file lists.
- **R-M7-8 Click interval.** `src/os/mouse.zig` returns `GetDoubleClickTime()` on Windows; `click-repeat-interval = 0` (the default) then follows the system setting, as on macOS.
- **R-M7-9 pwsh and cmd shell features.**
  - **pwsh `cursor`:** the prompt ends with `ESC[5 q` (`ESC[6 q` for `cursor:steady`); the cursor is reset with `ESC[0 q` where the integration emits `133;C` (a command starts). Same semantics as `ghostty.bash`.
  - **pwsh `ssh-env`/`ssh-terminfo`:** `function global:ssh` runs `"$env:GHOSTTY_BIN_DIR\ghostty.exe" +ssh [--forward-env=false] [--terminfo=false] -- <args>` **synchronously**: `System.Diagnostics.Process` with `UseShellExecute = $false`, no redirection (the console is inherited), the argument string built with a CommandLineToArgvW-safe quoting helper (PS 5.1 has no `ArgumentList`), `WaitForExit()`, `$global:LASTEXITCODE` = its exit code. Calling the GUI-subsystem exe with `&` would not wait (issues § 6a.6.1).
  - **cmd `cursor`:** `ESC[5 q` (`$E[5 q`) appended to the wrapped `PROMPT`. cmd has no pre-exec hook, so the bar stays while a command runs (documented limit).
  - **cmd `ssh-*`:** `share\ghostty\shell-integration\cmd\ssh.cmd` runs `start "" /b /wait "%GHOSTTY_BIN_DIR%\ghostty.exe" +ssh <flags from GHOSTTY_SHELL_FEATURES> -- %*`; `setupCmd` puts that directory first on the cmd pane's `PATH` only when an `ssh-*` feature is on. It shadows `ssh` only for what cmd itself resolves (`CreateProcess("ssh")` from other programs still finds `ssh.exe`).
  - `path` and `sudo` are not done for pwsh/cmd (not in the owner's scope).
- **R-M7-10 WSL directory.**
  - A surface knows whether its command is WSL by the existing argv0 rule (`Exec.zig` `isWsl…`: basename `wsl`/`wsl.exe`, or System32 `bash.exe`).
  - In such a surface, an OSC 7 path that `pwd_path.translate` rejects but is an absolute POSIX path (`/…`, no control characters, ≤ 4096 bytes) is stored as the terminal pwd as is, instead of being dropped. A UNC or `file://` with a foreign host stays rejected as today.
  - A new surface whose command is WSL and whose inherited `working-directory` is a POSIX path gets `--cd <path>` as argv[1] (an existing `--cd <x>` or a lone `~` argument is replaced), and starts with the default process cwd. A non-WSL surface that inherits a POSIX path drops it with one log line and starts in its default directory.
  - The palette, proxy icon and `window-subtitle` ignore a non-drive pwd (they already filter on drive paths; Task 8 verifies and guards).
- **R-M7-11 Kitty.**
  - **DCS tmux passthrough unwrap: not implemented.** With the shim off by default no pane has `TMUX`, so tools do not wrap. With `windows-tmux-shim = true` the shim answers `allow-passthrough off` and Claude Code turns images off anyway; that combination is a documented limit.
  - **`a=q` reply:** Task 9's headless probe decides. If the plain APC reply is lost in OpenConsole's input parser and the same reply sent as win32-input-mode character records arrives intact, Task 12 wraps **only Kitty graphics replies**, **only** when the pseudo console has asked for `CSI ? 9001 h` (`resize_prime.win32_input`), as key-down records `CSI 0;0;<utf16 unit>;1;0;1 _` (Vk 0, Sc 0, Kd 1, Cs 0, Rc 1). DA1/CPR/XTVERSION/OSC replies are never wrapped (OpenConsole consumes DA1/CPR itself).
  - If the plain reply already arrives: no code, Task 12 only adds the end-to-end case. If neither arrives: documented limit, with `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1` as the workaround for Claude Code (issues § 2a).
  - `t=s` (shared memory) and MSYS path translation for `t=f`/`t=t` stay out (upstream parity).
- **R-M7-12 MSYS on the bundled console.**
  - Re-measure first (G1): `resize-input` with `GHOSTTY_E2E_VARIANT=bundled`, 3 runs × 36 checks, on today's Git for Windows.
  - **Switch `auto` to bundled for MSYS only if those 108 checks lose 0 lines** and the default-variant run also loses 0 (Task 16).
  - The owner's Windows Terminal comparison (G1, manual, instructions below) and Task 13's test-mode experiment are evidence for the bug report and for win.3. Full win32-input-mode key encoding (audit 2.1) is **not** in win.2, even if Task 13 shows it removes the loss.
  - Otherwise: the limit stays documented, the opt-in stays `windows-conpty = bundled`, and `docs/windows/m7/msys-key-loss.md` holds the measurements and the bug-report text for msys2-runtime / Cygwin (not filed).
- **R-M7-13 Win11 top-level "Open Ghostty here".**
  - **DLL** `ghostty-explorer.dll`, std-only Zig (like `tmux.exe`: no SharedDeps, no libc), exports `DllGetClassObject` and `DllCanUnloadNow` only (registration is the package's job). One `IExplorerCommand` class, CLSID fixed forever in `src/explorer_command/ids.zig`, `ThreadingModel = STA`.
    - `GetTitle` → `Open Ghostty here`; `GetIcon` → `"<dll dir>\ghostty.exe",0`; `GetFlags` → `ECF_DEFAULT`; `GetCanonicalName` → the fixed verb GUID; `EnumSubCommands` → `E_NOTIMPL`.
    - `GetState` → `ECS_ENABLED` for exactly one item with a file-system path (`SFGAO_FILESYSTEM`, `SIGDN_FILESYSPATH`), else `ECS_HIDDEN`.
    - `Invoke` → `CreateProcessW` of `"<dll dir>\ghostty.exe" "--working-directory=<path>\."` (the classic verb's exact command shape, R-M5-5), no handles inherited, `CREATE_UNICODE_ENVIRONMENT`, the process cwd = `<path>`.
  - **Sparse package** `ghostty-explorer.msix` (built by `makeappx pack /nv` in `package.ps1`, never signed):
    - `Identity Name="Ghostty.ExplorerMenu"`, `Publisher="CN=Ghostty Windows port (unofficial), OID.2.25.311729368913984317654407730594956997722=1"`, `Version` = the 4-part FILEVERSION, `ProcessorArchitecture` = the arch;
    - `uap10:AllowExternalContent = true`; `TargetDeviceFamily Windows.Desktop MinVersion="10.0.22000.0"`; capabilities `runFullTrust`, `unvirtualizedResources`;
    - one `Application Id="Ghostty" Executable="ghostty.exe" uap10:TrustLevel="mediumIL" uap10:RuntimeBehavior="win32App"` with `AppListEntry="none"` (the Start entry stays the Inno shortcut);
    - `desktop4:Extension Category="windows.fileExplorerContextMenus"` for `Directory`, `Directory\Background` and `Drive`, verb `GhosttyOpenHere`, the CLSID; `com:Extension Category="windows.comServer"` → `com:SurrogateServer` → `com:Class Path="ghostty-explorer.dll" ThreadingModel="STA"`;
    - logos generated once from `dist/windows/ghostty.ico`.
  - **No identity for `ghostty.exe`:** its manifest gets no `<msix>` element. AUMID, toasts, jump list and taskbar grouping stay as in v1.0 (owner check 9 confirms).
  - **Installer** (task `explorermenu` ticked and Windows build ≥ 22000): after the classic verbs, `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { Add-AppxPackage -Path '<app>\ghostty-explorer.msix' -ExternalLocation '<app>' -AllowUnsigned -ForceUpdateFromAnyVersion; exit 0 } catch { exit 1 }"` (single quotes in paths doubled), hidden, waited. A failure (for example, if the machine needs Developer Mode for unsigned packages) is logged and shown as a suppressible note; the install succeeds and the classic verb remains. **This is the ruling for that case; it is not an open question.**
  - **Upgrade (the locked DLL):** `PrepareToInstall`, after the existing tray loop, when `{app}\ghostty-explorer.dll` exists: remove the package (`Get-AppxPackage -Name Ghostty.ExplorerMenu | Remove-AppxPackage`, hidden, waited, result ignored), then try `DeleteFile`; if that fails, `RenameFile` to `ghostty-explorer.dll.old-<tick>` (a loaded image can be renamed on the same volume); if that fails too, loop on Retry/Cancel with `Explorer is still using the Ghostty menu. Close all File Explorer windows, then click Retry.` Silent → return that text (Setup stops cleanly). Never an Ignore. `ssPostInstall` deletes `{app}\ghostty-explorer.dll.old-*` best effort.
  - **Uninstall:** `[UninstallRun]` removes the package first (`RunOnceId: "ExplorerMenuRevert"`), before the existing `ExplorerRevert`. A DLL that Explorer still holds is renamed aside by `CurUninstallStepChanged(usUninstall)`; a leftover `*.old-*`/renamed file can keep `{app}` until the next install or a manual delete (documented limit).
  - **Portable zip:** ships the DLL and the `.msix`; README gives the two PowerShell lines to add and remove it by hand. `+install-explorer-integration` does not register packages (no WinRT in the CLI).
  - **`/DGhosttyTest`:** installs both files, contains no package code (`#ifndef GhosttyTest`, as the other `[Code]`).
  - **Residual risk** (owner decision): tested only on the owner's machine; the release notes say so.
- **R-M7-14 Release.** `release.ps1 -N 2` (tag `win-<zon>-2`), no upstream merge in win.2, the M6 recipe otherwise unchanged. The lead adds the win.2 highlights and the residual-risk line to the generated `release-notes.md` before the owner runs `publish.txt`, then re-runs `Test-Privacy` on it.

## Waves (parallelism)

≤ 5 tasks per wave; file sets inside a wave are strictly disjoint. G = lead batch (GUI e2e, vt-smoke, owner inputs).

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 defaults (tmux off, Explorer task) · 2 system symbols/emoji · 3 tab rename popup · 4 `font-thicken` + `text-weight` scenario · 5 Kitty render scenario, image sampler, `resize-input` bundled variant, `FakeExe.psm1` | — |
| G1 | **Lead batch** (below) | W1 |
| W2 | 6 links, file paste, click interval · 7 pwsh/cmd features · 8 WSL cwd · 9 `a=q` probe · 10 Explorer command DLL | W1 (7, 8, 9 use `FakeExe.psm1`) |
| G2 | **Lead batch** | W2 |
| W3 | 11 text-weight default + doc · 12 Kitty reply wrapping (cond.) · 13 MSYS win32-input experiment (cond.) · 14 sparse package + packaging | G1 owner pick (11); 8 + G2 probe verdict (12); G1 measurements (13); 10 (14) |
| G3 | **Lead batch** | W3 |
| W4 | 15 installer register/unregister + `installer-test` · 16 MSYS decision, `windows-conpty` | 1 + 14 (15); 11 + G3 (16) |
| G4 | **Lead batch** (ReleaseFast package, installer-test, owner's package probe) | W4 |
| W5 | 17 docs (alone) | G4 |
| W6 | 18 release `-win.2`, acceptance (lead + owner) | 17 |

**G1 (lead):**
1. `LOCK ZIG build -j6` on the merged W1.
2. `E2E -Only tmux-env,tmux-send-keys,tmux-labels,tmux-replay,tmux-external,font-symbols,font-fallback,tab-rename,text-weight,kitty-render`.
3. `VTS -Only symbols,kitty-image -Update`, inspect both PNGs (magenta 8×2-cell block; symbols from Segoe faces), commit them (`test(windows): vt-smoke references for symbols and kitty-image`).
4. `GHOSTTY_E2E_VARIANT=bundled E2E -Only resize-input` three times, and the default variant once; record `lost=<n>/<checks>` per run in the ledger.
5. Send the owner: the `text-weight` contact sheet (R-M7-5), and the Windows Terminal check (R-M7-12): "Open Git Bash in Windows Terminal ≥ 1.23, split the pane or resize the window, type `echo abc` immediately; repeat 20 times; count lines that lose their first character; note `git --version` and `uname -r`." Both answers go to the ledger before W3 starts.

**G2 (lead):** `E2E -Only link-windows-path,link-hover-open,paste-files,drop-files,wsl-cwd,prompt-marks,term-terminfo,close-idle-prompt`; read Task 9's RESULT section and record the verdict for Task 12 (plain arrives / wrapped arrives / neither).

**G3 (lead):** `E2E -Only kitty-render` (with Task 12's case); if Task 11 changed a default: `VTS -Update` for every case with a reference, inspect, commit, then `E2E -Milestone M1` and `-Only render,theme,chrome-macos,font-fallback,font-symbols,text-weight`; if Task 13 ran: `GHOSTTY_E2E_VARIANT=bundled-w32im E2E -Only resize-input` × 3; `package.ps1` on the Debug `zig-out` with `-AllowNoTic` (the stage has the DLL and the `.msix`).

**G4 (lead, then owner):**
1. `RFS -Dversion-string=<zon>-win.0 -Dconpty-dir=<conpty root>`; `PS dist/windows/package.ps1 -Prefix zig-out\rfs -Version <zon>-win.0 -Arch x64 -OutDir zig-out\g4 -Symbols -Installer`, and `-FromZip … -Installer -Test` for the test setup.
2. `GHOSTTY_E2E_PACKAGE=<zip>` `GHOSTTY_E2E_SETUP=<…-setup-test.exe>` `E2E -Only package-portable,installer-test`. A SKIP with the lead's input = FAIL.
3. **Owner, on the owner's go:** install the G4 **real** setup (`-win.0`) with the task ticked; check the top-level entry on a folder, a folder background and `C:\`; invoke it; reinstall the same setup with a File Explorer window open after using the menu (the locked-DLL path); uninstall; `Get-AppxPackage -Name Ghostty.ExplorerMenu` prints nothing. A failure here opens a 15.n task before W5.

Hot-file chains (every file touched by more than one task):
- `src/config/Config.zig`: 1 → 11 → 16.
- `dist/windows/installer/ghostty.iss`: 1 → 15.
- `src/termio/Exec.zig`, `src/termio/stream_handler.zig`: 8 → 12.
- `test/windows/e2e/kitty-render.ps1`: 5 → 12.
- `test/windows/e2e/resize-input.ps1`: 5 → 13.
- `dist/windows/package.ps1`, `dist/windows/release.ps1`: 14 → 18 (18.n fixes only).
- `test/windows/e2e/package-portable.ps1`: 1 only. `test/windows/e2e/installer-test.ps1`: 15 only.
- `test/windows/e2e.ps1` (`ValidateSet` += `M7`): 1 only.
- `test/windows/lib/FakeExe.psm1`: 5 only (7, 8, 9 import it, never edit it).
- `docs/windows/**`, `dist/windows/README-windows.txt`, `test/windows/README.md`: 17 (+ 16's new `m7/msys-key-loss.md`, + 18's `m7/acceptance.md`).

Interfaces fixed by this plan (so W2/W3 tasks run in parallel):
- **`test/windows/lib/FakeExe.psm1`** (Task 5). C# console programs compiled once per sandbox with `Add-Type -OutputType ConsoleApplication -OutputAssembly <path>` (no Zig at run time):
  ```
  New-FakeExe -Path <exe> -Kind argv        # prints "ARGV:" + each argv element on its own line, "CWD:<cwd>", "TERM:<TERM>", then the first stdin line as "STDIN:<line>"; exit code from env FAKE_EXIT (default 0)
  New-FakeExe -Path <exe> -Kind osc7        # writes ESC]7;file://fake/<FAKE_OSC7_PATH> BEL, then behaves as argv, then waits for a line on stdin
  New-FakeExe -Path <exe> -Kind vtreader    # sets ENABLE_VIRTUAL_TERMINAL_INPUT, raw; writes FAKE_QUERY (C-escaped) to stdout; reads stdin for FAKE_WAIT_MS; prints "GOT:" + hex of what arrived
  ```
- **`src/explorer_command/ids.zig`** (Task 10): `pub const clsid_text = "{…}"`, `pub const clsid: GUID`, `pub const verb_name = "GhosttyOpenHere"`, `pub const package_name = "Ghostty.ExplorerMenu"`, `pub const dll_name = "ghostty-explorer.dll"`. Task 14's `package.ps1` reads `clsid_text` and `package_name` with a regex and checks the manifest against them.
- **`dist/windows/sparse/build-sparse.ps1`** (Task 14):
  ```
  build-sparse.ps1 -Stage <stage dir> -Version <4-part> -Arch x64|arm64   # writes <stage>\ghostty-explorer.msix; exit 0, 1 (check failed), 2 (makeappx not found)
  build-sparse.ps1 -Probe        # prints the makeappx path; exit 0 or 2
  build-sparse.ps1 -SelfTest     # pure manifest checks, no makeappx
  ```
- **`src/termio/win32_input.zig`** (Task 12):
  ```zig
  pub fn charRecordsLen(utf8: []const u8) usize;                       // exact output size
  pub fn charRecords(out: []u8, utf8: []const u8) error{NoSpaceLeft, InvalidUtf8}![]const u8;  // CSI 0;0;<u16>;1;0;1 _ per UTF-16 unit
  ```
- **Test-only env** (Task 13): `GHOSTTY_WIN32_TEST_W32IM=1`, honoured only with `GHOSTTY_WIN32_TEST_IPC=1`.
- **e2e variants:** `GHOSTTY_E2E_VARIANT=bundled` (Task 5) and `bundled-w32im` (Task 13) for `resize-input`.

---

### Task 1: Defaults — tmux shim off, Explorer task ticked; tmux scenarios turn the shim on

**Review:** light.

**Files:**
- Modify:
  - `src/config/Config.zig`: `@"windows-tmux-shim": bool = false`; the doc says the default is off, what turning it on does (`TMUX`, `TMUX_PANE`, `PATH`, `CLAUDE_CODE_TMUX_TRUECOLOR`), that Claude Code agent teams need it (`teammateMode: "tmux"`), and that with it on Kitty images from tmux-aware tools do not show (R-M7-11). The test `"windows config: M5 keys default"` also asserts `!cfg.@"windows-tmux-shim"`.
  - `src/apprt/win32/tmux/env.zig`: in `apply`, when `TMUX` is exported, `CLAUDE_CODE_TMUX_TRUECOLOR=1` unless present; the default test renamed and inverted.
  - `dist/windows/installer/ghostty.iss`: task `explorermenu` without `Flags: unchecked` (R-M7-2); `WizardIsTaskSelected('explorermenu')` in `CurStepChanged`.
  - `test/windows/e2e.ps1`: `ValidateSet` += `M7`; help text.
  - `test/windows/e2e/tmux-env.ps1`, `tmux-send-keys.ps1`, `tmux-labels.ps1`, `tmux-replay.ps1`, `tmux-external.ps1`, `package-portable.ps1`: `windows-tmux-shim = true` in the config they start with (`Start-BashE2e -ExtraConfig`, or appended to `-ConfigText`). `tmux-env.ps1` also gets a first step with the **default** config: `TMUX` and `TMUX_PANE` are unset in Git Bash and `command -v tmux` does not name the Ghostty folder.
  - `test/windows/claude-team.ps1`, `test/windows/measure-tmux.ps1`: the same key in their configs.

- [ ] **Step 1: Failing tests:**
  - `"win32 config: windows-tmux-shim defaults to false"` (renamed from `…to true`);
  - `"win32 tmux env: truecolor hint with the shim"`: enabled + pipe → `CLAUDE_CODE_TMUX_TRUECOLOR=1`; an existing `CLAUDE_CODE_TMUX_TRUECOLOR=0` kept; disabled → absent; no pipe → absent.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 config" -Dtest-filter="win32 tmux env" -Dtest-filter="windows config"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify:** the filters pass; `LOCK ZIG build -j6`; every changed `.ps1` parses; `PS dist/windows/installer/build.ps1 -SelfTest`; `git grep -n "Flags: unchecked" dist/windows/installer/ghostty.iss` shows only `desktopicon`; `E2E -Only tmux-cli` (no window; the implementer may run it).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux shim off by default, Explorer task ticked; tmux scenarios enable the shim"`

### Task 2: Symbols and emoji from the system fonts

**Review:** light.

**Files:**
- Modify `src/font/SharedGridSet.zig` (emoji block, R-M7-3), `src/font/discovery.zig` (presentation-ordered fallback; tests).
- Create `test/windows/e2e/font-symbols.ps1` (`# e2e: milestone=M7 timeout=120 order=1100`), `test/windows/vt-smoke/cases/symbols.sh` (`# vts: requires=M7-2 extra-config=`).

- [ ] **Step 1: Failing tests** (`discovery.zig`, skipped unless `freetype_windows`; system font files checked with the existing `testSystemFontPresent`):
  - `"windows font: text symbols prefer Segoe UI Symbol"`: U+2714, U+26A0, U+273B with text presentation → `seguisym.ttf` first;
  - `"windows font: record symbol resolves to a system face"`: U+23FA → a file under `%SystemRoot%\Fonts` (Segoe UI Symbol or Emoji, whichever has it);
  - `"windows font: emoji presentation prefers Segoe UI Emoji"` (the existing U+1F600 test kept);
  - `"windows font: Segoe UI Emoji renders in colour"`: U+1F600 rendered at 16 px through the FreeType face → `FT_PIXEL_MODE_BGRA` with at least one pixel whose channels differ (R-M7-3 colour check);
  - `"windows font: no embedded Noto when DirectWrite works"` / `"… Noto kept when DirectWrite is unusable"`: the collection built by `SharedGridSet` has no face from `font.embedded.emoji`/`emoji_text` with a working `dw`, and has both with `dw = null` (seam: a test-only constructor or field write on the `Windows` discovery; the implementer picks the smallest one).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows font"` → FAIL.
- [ ] **Step 3: Implement** R-M7-3. If the colour test fails on this machine, apply the R-M7-3 fallback and report DONE_WITH_CONCERNS with the pixel mode seen.
- [ ] **Step 4: Scenario and case:**
  - `font-symbols`: Git Bash prints `⏺ ✔ ⚠ ✻ ❯ →` and `😀 👍` (built from code points; the file stays ASCII) and a row of `M`. Every symbol cell has ink in the frame dump; each emoji cell has at least 20 pixels whose R, G, B differ by > 40 (colour); the log has `directwrite fallback family=Segoe UI Symbol` and `family=Segoe UI Emoji`, and no line naming Noto.
  - `symbols.sh`: the same text, reference generated in G1.
- [ ] **Step 5: Verify:** `-Dtest-filter="windows font"` and `-Dtest-filter="font"` (the upstream font tests on Windows) pass; `LOCK ZIG build -j6`; the scenario parses.
- [ ] **Step 6: Commit** `git commit -m "feat(font): Windows symbols and emoji from Segoe UI Symbol/Emoji; embedded Noto only without DirectWrite"`

### Task 3: Tab rename editor in a themed owned popup

**Review:** light.

**Files:**
- Modify:
  - `src/apprt/win32/title_edit.zig`: the popup (R-M7-4), `WM_CTLCOLOREDIT`, font, inset, centring; pure helpers for the editor rect and colours;
  - `src/apprt/win32/strip_input.zig`: `Session` keeps the popup HWND as well as the EDIT;
  - `src/apprt/win32/overlay.zig`: only if the `.panel` kind needs a hook for a foreign window proc (the SearchBar pattern needs none; say which in the report);
  - `src/apprt/win32/ipc/ops.zig`: `writeWindow` adds `title_edit: {open, popup, edit, rect}` (screen pixels) to the test state;
  - `test/windows/e2e/tab-rename.ps1`: finds the editor through `state.windows[0].title_edit` instead of a child `Edit` of the top-level; pixel checks.

- [ ] **Step 1: Failing tests** `"win32 title edit: rect inset and centring"` (tab rect, DPI 96/144 → popup rect, 6 px × scale inset, vertical centring on the tab) and `"win32 title edit: colours follow the tab"` (dark and light palette → field = active-tab fill, text = tab title colour, never white on a dark theme).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 title edit"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Scenario** (existing four steps kept), plus:
  - after the double click and before typing, capture the editor rect (`Get-ScreenShot` over `title_edit.rect`): fewer than 10 % of its pixels have all channels ≥ 240 (no white box), and its median colour is within 24 per channel of the tab fill next to it;
  - after typing `renamed`: at least 30 pixels in the rect differ from the pre-typing capture by > 60 in luminance (the text is visible);
  - the same two checks once more with `background-opacity = 0.85` (the translucent case of issues § 3).
- [ ] **Step 5: Verify:** the filter passes; `LOCK ZIG build -j6`; the scenario parses.
- [ ] **Step 6: Commit** `git commit -m "fix(win32): tab rename edits in a themed borderless popup over the tab, like macOS"`

### Task 4: `font-thicken` on Windows and the `text-weight` comparison scenario

**Review:** light.

**Files:**
- Modify `src/font/face/freetype.zig` (R-M7-5 embolden; tests).
- Create `test/windows/e2e/text-weight.ps1` (`# e2e: milestone=M7 timeout=240 order=1120`).

- [ ] **Step 1: Failing tests:**
  - `"windows font: thicken adds ink"`: the embedded JetBrains Mono `l` and `m` at 12 pt, 96 dpi: the coverage sum with `thicken = true` is greater than without; strength 255 > strength 0 > off; advance width unchanged;
  - `"windows font: thicken leaves colour glyphs alone"`: a BGRA glyph (Segoe UI Emoji if present, else skip) is byte-identical with and without.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows font: thicken"` → FAIL.
- [ ] **Step 3: Implement** (Windows only; `comptime builtin.target.os.tag == .windows`).
- [ ] **Step 4: Scenario** `text-weight`: for each variant A–D (R-M7-5) start Ghostty with `command = direct:<Git Bash> --noprofile --norc <sandbox>\sample.sh` (printf only, the sample of R-M7-5, then `exec sleep 600`), wait for two equal frame dumps, save `text-weight-<A..D>.png` to the evidence dir, compute per sample row the ink coverage (mean of `|px - bg| / |fg - bg|` over the row's text cells), write `text-weight <variant> <row> coverage=<x>` to `info.txt`, and compose `text-weight-sheet.png` (four crops stacked with labels, System.Drawing). PASS when all four dumps exist and C ≥ A, D ≥ B in coverage on every row (thicken works). Without `-EvidenceDir` it writes into the sandbox and PASSes on the numbers only.
- [ ] **Step 5: Verify:** filter passes; `LOCK ZIG build -j6`; the scenario parses.
- [ ] **Step 6: Commit** `git commit -m "feat(font): font-thicken on Windows; text-weight comparison scenario"`

### Task 5: Kitty render scenario, image sampler, `resize-input` bundled variant, `FakeExe.psm1`

**Review:** light.

**Files:**
- Modify:
  - `src/renderer/image.zig`: the image step passes the linear-clamp sampler explicitly (issues § 2a.4);
  - `test/windows/e2e/resize-input.ps1`: `GHOSTTY_E2E_VARIANT=bundled` appends `windows-conpty = bundled` to the Git Bash configs; every run writes `resize-input variant=<v> lost=<n>/<checks>` to `info.txt`.
- Create:
  - `test/windows/e2e/kitty-render.ps1` (`# e2e: milestone=M7 timeout=180 order=1110`);
  - `test/windows/lib/FakeExe.psm1` (interface above; `-SelfTest` compiles the three kinds into `%TEMP%` and runs `argv` once).

- [ ] **Step 1: Failing test** `"d3d11 image: the image step binds its sampler"` (the step description built by `image.zig` has a sampler in slot 0) → FAIL. Run `LOCK ZIG build test -j6 -Dtest-filter="d3d11 image"`.
- [ ] **Step 2: Implement** the sampler line.
- [ ] **Step 3: Scenario** `kitty-render` (frame dumps; the image is 2 magenta pixels stretched to 8×2 cells, issues § 2a.4):
  1. **pwsh, bundled (`windows-conpty = auto`):** `command = direct:powershell.exe -NoProfile -NoLogo -File <sandbox>\k.ps1`, which clears, writes `ESC_Ga=T,f=24,s=2,v=1,c=8,r=2;/wD//wD/ESC\` and sleeps. ≥ 90 % of the pixels in the 8×2-cell rect at row 0, col 0 are within 24 of `#ff00ff`. The pane's console child is `OpenConsole.exe` (`Win32_Process`, as `package-portable` does).
  2. **Git Bash with `windows-conpty = bundled`:** the same through `printf`.
  3. **Git Bash with `auto` (inbox):** no magenta pixel in the rect (the documented limit; PASS when absent).
  4. **`a=q` in pwsh:** `ESC_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC\`; the sandbox log has `kitty graphics response` (Ghostty answered; whether the program receives it is Tasks 9 and 12).
- [ ] **Step 4: Verify:** filter passes; `LOCK ZIG build -j6`; the scripts parse; `Import-Module test/windows/lib/FakeExe.psm1; New-FakeExe -SelfTest` passes (no window).
- [ ] **Step 5: Commit** `git commit -m "test(windows): kitty-render pixel check on the bundled ConPTY, explicit image sampler, resize-input bundled variant, fake exes"`

### Task 6: Windows paths in links, pasting files, click interval

**Review:** light.

**Files:**
- Modify `src/config/url.zig` (R-M7-6), `src/apprt/win32/clipboard.zig` (R-M7-7), `src/os/mouse.zig` (R-M7-8).
- Create `test/windows/e2e/link-windows-path.ps1` (`milestone=M7 timeout=120 order=1130`), `test/windows/e2e/paste-files.ps1` (`milestone=M7 timeout=150 order=1140`).

- [ ] **Step 1: Failing tests:**
  - `"config url: windows paths"` (Windows only): `C:\proj\a.ts:12` whole; `C:/x/y.zig:3:5` whole; `.\src\x.zig`; `..\a\b.txt`; `src\config\url.zig`; `see C:\work\file.txt.` without the dot; `(C:\a\b.txt)` without the parentheses; `C:\Program Files\Git\bin\bash.exe` whole; `\\server\share\x.txt` no match at `\\`; `\\?\C:\x` no match; the upstream `url regex` cases unchanged (`-Dtest-filter="url regex"` still passes);
  - `"win32 clipboard: a file list pastes as quoted paths"`: a synthetic `DROPFILES` block (two paths, one with a space and one with `'`) → the Git Bash, pwsh and cmd quotings equal `drop.quote`'s;
  - `"win32 clipboard: text wins over a file list"`;
  - `"windows mouse: double-click time"`: `clickInterval()` equals `GetDoubleClickTime()`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="config url" -Dtest-filter="url regex" -Dtest-filter="win32 clipboard" -Dtest-filter="windows mouse"` → FAIL.
- [ ] **Step 3: Implement.** The paste path: `clipboard.request` treats `CF_HDROP` as available for `.paste` (not for OSC 52); the read thread builds the text with `drop.zig`; the rest is the text path.
- [ ] **Step 4: Scenarios:**
  - `link-windows-path`: cmd prints `C:\Windows\win.ini:3`, `.\x\y.txt` and `\\server\share\z.txt`; Ctrl+hover over each: the first two show the link label with the exact path text; the UNC shows none; Ctrl+click on the first records `m3.opened` with the path (test mode records, nothing launches).
  - `paste-files`: with the owner's clipboard saved, put `CF_HDROP` for two sandbox files (one name with a space) on the clipboard (`System.Windows.Forms.Clipboard.SetFileDropList`), paste in Git Bash (`echo ` + paste + Enter) → the `echo` output names both files as the shell sees them; the same in cmd; restore the clipboard in `finally`.
- [ ] **Step 5: Verify:** filters pass; `LOCK ZIG build -j6`; scenarios parse.
- [ ] **Step 6: Commit** `git commit -m "feat(win32): Windows paths in links, paste files copied in Explorer, system double-click time"`

### Task 7: pwsh and cmd shell integration: `cursor`, `ssh-env`, `ssh-terminfo`

**Review:** light.

**Files:**
- Modify `src/shell-integration/pwsh/ghostty.ps1`, `src/termio/shell_integration.zig` (`setupCmd`), `test/windows/shell-marks/run.ps1` (new cases).
- Create `src/shell-integration/cmd/ssh.cmd` (installed with the rest of `src/shell-integration` by `GhosttyResources`; ASCII, CRLF).

- [ ] **Step 1: Failing tests:**
  - `"windows shell integration: cmd cursor in the prompt"`: features with `cursor` → `PROMPT` contains `$E[5 q` (steady → `$E[6 q`); without → not;
  - `"windows shell integration: cmd ssh dir on PATH"`: `ssh-env` or `ssh-terminfo` → `<resources>\shell-integration\cmd` is the first `PATH` entry; neither → `PATH` unchanged.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows shell integration"` → FAIL.
- [ ] **Step 3: Implement** R-M7-9.
- [ ] **Step 4: Headless cases** in `shell-marks/run.ps1` (no window; the implementer runs them with `pwsh`). A fake `ssh.exe` (`New-FakeExe -Kind argv`) sits first on the case's `PATH`; `ghostty +ssh` finds it as `ssh`. The `+ssh` cache lives in the case's sandbox `LOCALAPPDATA`/`XDG_*`.
  - pwsh 7 and Windows PowerShell 5.1, `ssh-env`: `ssh -p 2222 'host one'` → the fake's argv has `-o SendEnv=COLORTERM` … and `-p`, `2222`, `host one` as separate elements; `TERM:xterm-256color`; `$LASTEXITCODE` equals `FAKE_EXIT`.
  - pwsh, `ssh-terminfo`: the first call's stdin starts with the terminfo source (`xterm-ghostty|`), exit 0 → the second call gets `TERM:xterm-ghostty` (cached).
  - pwsh, no ssh features: `ssh` is the fake directly (no wrapper).
  - pwsh `cursor`: the raw output has `ESC[5 q` before `133;B` and `ESC[0 q` after `133;C`.
  - cmd with `ssh-env`: `ssh host` → the fake's argv as above; cmd `cursor`: `ESC[5 q` in the prompt bytes.
  - The existing 24 cases still pass (their expected prompt bytes updated for the cursor sequence where needed).
- [ ] **Step 5: Verify:** the filter passes; `LOCK ZIG build -j6`; `pwsh -NoProfile -File test/windows/shell-marks/run.ps1` all green.
- [ ] **Step 6: Commit** `git commit -m "feat(shell-integration): cursor, ssh-env and ssh-terminfo for pwsh and cmd"`

### Task 8: WSL tabs and splits inherit the directory

**Review:** opus (program output becomes a process argument, R-M7-10).

**Files:**
- Modify `src/termio/stream_handler.zig` (OSC 7 for WSL panes), `src/termio/Exec.zig` (`--cd`; tests), `src/apprt/win32/Surface.zig` (only if `normalizeWorkingDirectory` or a pwd consumer needs a guard; the report lists every pwd consumer checked: `tab_actions.pwd`, `CommandPalette`, the proxy icon, `window-subtitle`).
- Create `test/windows/e2e/wsl-cwd.ps1` (`milestone=M7 timeout=150 order=1150`).

- [ ] **Step 1: Failing tests:**
  - `"windows osc7: wsl pane keeps a posix path"`: a WSL surface, `file://host/home/u/proj` → pwd `/home/u/proj`; with a control character → ignored; a non-WSL surface → ignored (today's behaviour); `/c/x` in Git Bash → still `C:\x` (MSYS translation first);
  - `"Exec: wsl --cd from an inherited posix cwd"`: `wsl.exe` + cwd `/home/u/a b` → argv `{wsl.exe, --cd, /home/u/a b}` and the process cwd is the default; `wsl -d Ubuntu --cd ~` → the `--cd` value replaced; `wsl ~` → `~` replaced; `cmd.exe` + `/home/u` → cwd dropped with one log line; `wsl.exe` + `C:\x` → no `--cd`, cwd `C:\x` (today).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows osc7" -Dtest-filter="Exec: w"` → FAIL.
- [ ] **Step 3: Implement** R-M7-10.
- [ ] **Step 4: Scenario** `wsl-cwd`: `New-FakeExe -Kind osc7 -Path <sandbox>\bin\wsl.exe`, `FAKE_OSC7_PATH=/home/e2e/my proj`, `command = direct:<sandbox>\bin\wsl.exe`. After the first pane shows `CWD:`, `new_split` and `new_tab` through IPC: both new panes print `ARGV:--cd` and `ARGV:/home/e2e/my proj`. No real WSL starts.
- [ ] **Step 5: Verify:** filters pass, plus `-Dtest-filter="Exec: "` and `-Dtest-filter="terminal"` (stream handler regressions); `LOCK ZIG build -j6`; the scenario parses.
- [ ] **Step 6: Commit** `git commit -m "feat(windows): WSL tabs and splits start in the directory the WSL shell reported"`

### Task 9: Probe — does a Kitty `a=q` reply reach the program through ConPTY input?

**Review:** light.

**Files:**
- Modify `test/windows/conpty-probe/headless.ps1` (a reply mode), `test/windows/conpty-probe/RESULT.md` (a new section).
- Create `test/windows/conpty-probe/cases/headless-kittyq.sh`.

- [ ] **Step 1:** Extend the headless host: when it sees `ESC _ G … a=q … ESC \` in the output, it writes the reply `ESC _ G i=31;OK ESC \` to the console's input, in one of two forms chosen by `-ReplyForm plain|w32im` (`w32im` = the R-M7-11 records). The host already answers DA1 and CPR; it must keep doing so in both forms.
- [ ] **Step 2:** Clients:
  - Git Bash: `headless-kittyq.sh` sends the query, then `read -rs -t 2 -d '\'`, and prints the hex of what it read;
  - native: `New-FakeExe -Kind vtreader` with `FAKE_QUERY` = the query, `FAKE_WAIT_MS=2000` (the shape of a Node/Claude Code reader).
- [ ] **Step 3: Run** (headless, no window) the matrix {inbox, bundled} × {plain, w32im} × {Git Bash, native}, `-Repeat 2`, with the bundled files from `vendor/conpty`.
- [ ] **Step 4:** Write the RESULT section: the table, the exact bytes that arrived, the verdict per bundled cell (**plain arrives / wrapped arrives / neither**), and the OpenConsole version.
- [ ] **Step 5: Commit** `git commit -m "test(windows): conpty-probe measures the Kitty a=q reply path through ConPTY input"`

### Task 10: Explorer command DLL (`IExplorerCommand`)

**Review:** opus (code loaded into Explorer).

**Files:**
- Create:
  - `src/explorer_command/ids.zig` (interface above; the CLSID and verb GUID generated once by the implementer and never changed);
  - `src/explorer_command/com.zig` (the minimal COM declarations: `GUID`, `IUnknown`, `IClassFactory`, `IExplorerCommand`, `IShellItemArray`, `IShellItem`, HRESULTs, `SIGDN_FILESYSPATH`, `SFGAO_FILESYSTEM`, `ECS_*`, `ECF_*`);
  - `src/explorer_command/command.zig` (the class, its factory, the launcher behind a function pointer so tests capture the command line);
  - `src/explorer_command/main.zig` (exports `DllGetClassObject`, `DllCanUnloadNow`; module and lock counts);
  - `src/build/GhosttyExplorerCommand.zig` (`b.addLibrary(.{ .linkage = .dynamic, .name = "ghostty-explorer" })`, std only, `link_libc = false`, links `ole32`; version resource; install; tests);
  - `dist/windows/explorer-command.rc` (`#pragma code_page(65001)`, `#include "versioninfo.rc"`, no icon, no manifest).
- Modify:
  - `src/build/main.zig`: export `GhosttyExplorerCommand`;
  - `build.zig`: `test-explorer-command` step (Windows), and install next to `tmux.exe` when the target is Windows and the runtime is win32;
  - `src/build/windows_version.zig`: `Exe.explorer_command` (FileDescription `Ghostty Explorer menu`, OriginalFilename `ghostty-explorer.dll`), `GHOSTTY_FILETYPE` in the header (`0x1L` VFT_APP for the exes, `0x2L` VFT_DLL);
  - `dist/windows/versioninfo.rc`: `FILETYPE GHOSTTY_FILETYPE`.

- [ ] **Step 1: Failing tests** (`command.zig`, run by `test-explorer-command`):
  - `"explorer command: factory and refcount"`: `DllGetClassObject(clsid, IID_IClassFactory)` → `S_OK`; a wrong CLSID → `CLASS_E_CLASSNOTAVAILABLE`; `CreateInstance(IID_IExplorerCommand)` → `S_OK`, `IID_IUnknown` too, another IID → `E_NOINTERFACE`; after the last `Release` and `LockServer(FALSE)`, `DllCanUnloadNow` → `S_OK`, before it `S_FALSE`;
  - `"explorer command: title, icon, flags"`: strings are `CoTaskMemAlloc`'d and equal R-M7-13's values (icon path from a test DLL dir);
  - `"explorer command: state"`: a fake `IShellItemArray` (vtable in the test) with one file-system folder → `ECS_ENABLED`; zero items, two items, a non-file-system item → `ECS_HIDDEN`; a null array → `ECS_HIDDEN`, no crash;
  - `"explorer command: invoke builds the classic command"`: folder `C:\a b\c` → the captured command line `"<dir>\ghostty.exe" "--working-directory=C:\a b\c\."` and cwd `C:\a b\c`; a drive `D:\` → `--working-directory=D:\.`; a launch failure → an error HRESULT, no crash;
  - `"explorer command: version header"` (in `windows_version.zig`, filter `windows version`): the DLL header has `0x2L` and the DLL names.
- [ ] **Step 2: Run** `LOCK ZIG build test-explorer-command -j6 -Dtest-filter="explorer command"` and `LOCK ZIG build test -j6 -Dtest-filter="windows version"` → FAIL.
- [ ] **Step 3: Implement** R-M7-13 (DLL part). No `@panic` reachable from an exported function: every error maps to an HRESULT.
- [ ] **Step 4: Verify:**
  - the filters pass; `LOCK ZIG build -j6` installs `zig-out\bin\ghostty-explorer.dll`;
  - `LOCK ZIG build -j6 -Doptimize=ReleaseFast --prefix zig-out/xcmd`: the DLL ≤ 300 KB; `dumpbin /exports` (if found through `vswhere`) lists exactly the two exports, `/imports` only kernel32, ole32 (and shell32 if used); `(Get-Item …).VersionInfo` shows the DLL names; delete `zig-out/xcmd`;
  - `LOCK ZIG build -j6 -Dtarget=aarch64-windows-gnu --prefix zig-out/xarm` builds the DLL (no run); delete it.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): ghostty-explorer.dll, an IExplorerCommand for the Windows 11 folder menu"`

### Task 11: Text-weight default and the `font-thicken` doc

**Review:** light. **Condition:** always runs for the doc; the default changes only if the owner picked B, C or D in G1 (R-M7-5).

**Files:** Modify `src/config/Config.zig`: the `font-thicken` doc ("on Windows it emboldens outlines by ¼–1 px with `font-thicken-strength`"); if picked, the Windows arm of `alpha-blending` and/or `font-thicken`'s default (`builtin.target.os.tag == .windows`), with their docs naming the Windows default.

- [ ] **Step 1: Failing test** (only with a pick) `"windows config: text weight default"`: the default config on Windows has the picked values; macOS/Linux arms unchanged (comptime checks of the field defaults).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows config"` → FAIL. **Step 3: Implement.** **Step 4: Verify:** filter passes; `LOCK ZIG build -j6`. The lead regenerates the vt-smoke references in G3.
- [ ] **Step 5: Commit** `git commit -m "feat(config): Windows text weight default after the owner's comparison"` (doc only: `docs(config): font-thicken works on Windows`).

### Task 12: Kitty replies through win32-input-mode (conditional)

**Review:** light. **Condition:** G2 verdict for bundled is "wrapped arrives, plain does not" → code + scenario; "plain arrives" → Step 4 only; "neither" → closed (Task 17 documents the limit, R-M7-11).

**Files:**
- Create `src/termio/win32_input.zig` (interface above; tests).
- Modify `src/termio/stream_handler.zig` (`apcEnd` sends Kitty replies as a tagged write), `src/termio/Exec.zig` (wrap a tagged write with `win32_input.charRecords` when `resize_prime.win32_input` is set; untagged writes and keys untouched), `src/termio/message.zig` only if the tag needs a message field, `test/windows/e2e/kitty-render.ps1` (case 5).

- [ ] **Step 1: Failing tests:** `"windows win32-input: char records"` (`ESC_Gi=31;OK ESC\` → the exact record string; a BMP letter and a surrogate pair → one record per UTF-16 unit; `charRecordsLen` exact; invalid UTF-8 → error); `"windows win32-input: only tagged writes are wrapped"` (Exec's write path with the mode on/off, a tagged and an untagged write).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows win32-input"` → FAIL. **Step 3: Implement** R-M7-11.
- [ ] **Step 4: Scenario case 5** in `kitty-render`: in pwsh (bundled), `New-FakeExe -Kind vtreader` sends the `a=q` query; its screen output shows `GOT:` with the hex of `ESC _ G i=31;OK ESC \`.
- [ ] **Step 5: Verify:** the filter, `-Dtest-filter="Exec: "` and `-Dtest-filter="terminal"` pass; `LOCK ZIG build -j6`.
- [ ] **Step 6: Commit** `git commit -m "fix(windows): Kitty graphics replies reach programs through the bundled ConPTY"`

### Task 13: MSYS first-key loss — test-mode win32-input-mode experiment (conditional)

**Review:** light. **Condition:** G1 shows lines lost with `GHOSTTY_E2E_VARIANT=bundled` **and** the owner's Windows Terminal run lost none. Otherwise closed (the evidence goes straight to Task 16).

**Files:**
- Create `src/apprt/win32/w32im_experiment.zig`: with `GHOSTTY_WIN32_TEST_W32IM=1` and test mode, key-down/key-up from `WM_KEYDOWN`/`WM_KEYUP`/`WM_SYSKEY*` (vk, scan code, `ToUnicode` char, control-key state, repeat) are written to the surface's pty as `CSI Vk;Sc;Uc;Kd;Cs;Rc _` instead of going through core's key encoder; nothing else changes. Never compiled into a path that runs without the env.
- Modify the apprt file that dispatches `WM_KEYDOWN` (`src/apprt/win32/keyboard.zig` or `key.zig`; one file, named in the report), `test/windows/e2e/resize-input.ps1` (variant `bundled-w32im` = `bundled` + the env).

- [ ] **Step 1: Failing test** `"win32 w32im experiment: record for a key"` (vk 0x41, scan 0x1E, `a`, down, no mods → `CSI 65;30;97;1;0;1 _`; Shift held → `Cs` 0x10; repeat 3 → `Rc` 3; off without the env).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 w32im"` → FAIL. **Step 3: Implement.** **Step 4: Verify:** filter; `LOCK ZIG build -j6`; the scenario parses.
- [ ] **Step 5: Commit** `git commit -m "test(win32): test-mode win32-input-mode key experiment for the MSYS key loss"`

### Task 14: Sparse package and packaging

**Review:** opus (release integrity, privacy of published files).

**Files:**
- Create `dist/windows/sparse/AppxManifest.xml` (template, `{{VERSION}}`, `{{ARCH}}`, `{{CLSID}}`), `dist/windows/sparse/Assets/StoreLogo.png`, `Square44x44Logo.png`, `Square150x150Logo.png` (made once from `ghostty.ico`; the generating command line goes in the commit body), `dist/windows/sparse/build-sparse.ps1` (interface above).
- Modify:
  - `dist/windows/package.ps1`: `ghostty-explorer.dll` staged and required; `build-sparse.ps1` writes `ghostty-explorer.msix` into the stage (exit 2 → `package: FAIL makeappx not found`); checks: the manifest CLSID and package name equal `ids.zig`'s, the DLL's VersionInfo ProductVersion = `-Version`, the DLL imports (with `dumpbin`); both files privacy-scanned;
  - `dist/windows/release.ps1`: preflight `build-sparse.ps1 -Probe`; the unit step runs `test-explorer-command` after `test-tmux-shim`, counted in `tests.txt`.

- [ ] **Step 1: Failing checks:** `build-sparse.ps1 -SelfTest` (the manifest template has the OID publisher, `AllowExternalContent`, `MinVersion 10.0.22000.0`, `AppListEntry="none"`, the three item types, `ThreadingModel="STA"`, a CLSID placeholder; a template missing any → its named failure) → FAIL before the script exists; `package.ps1` on a Debug prefix without the DLL → `package: FAIL ghostty-explorer.dll`.
- [ ] **Step 2: Implement.** `makeappx pack /o /nv /d <tmp layout> /p <stage>\ghostty-explorer.msix`; the layout holds only the manifest and `Assets`; `Invoke-Native` throughout; no signing ever (`-SignCommand` never touches the `.msix`).
- [ ] **Step 3: Verify:** parse checks; `-SelfTest`; `-Probe` finds `makeappx`; `package.ps1` on the Debug `zig-out` with `-AllowNoTic -NoConpty` → the zip has `ghostty-explorer.dll` and `ghostty-explorer.msix` at its top folder; `makeappx unpack` of that `.msix` into `zig-out\msix-check` gives the manifest with the real CLSID and version (then delete it); `release.ps1 -Rehearsal -N 0 -DryRun -ConptyPackage <vendor path>` prints the new preflight and test lines; `git grep -nP "[^\x00-\x7F]" dist/windows/sparse/*.ps1` → nothing. Nothing registers a package.
- [ ] **Step 4: Commit** `git commit -m "build(windows): sparse package for the Explorer command, staged in the zip and installer"`

### Task 15: Installer — register and remove the menu package, the locked DLL, `installer-test`

**Review:** opus (what the installer writes and deletes, R-M7-13).

**Files:** Modify `dist/windows/installer/ghostty.iss`, `dist/windows/installer/build.ps1` (`-SelfTest` cases for the new defines if any), `test/windows/e2e/installer-test.ps1`.

- [ ] **Step 1: Failing check:** `installer-test` asserts, for the test setup, that `ghostty-explorer.dll` and `ghostty-explorer.msix` are installed and then removed by the uninstaller, and that a read-only `Get-AppxPackage -Name Ghostty.ExplorerMenu` snapshot is identical before install, after install and after uninstall (the test variant never registers). Parse only (the lead runs it in G4).
- [ ] **Step 2: Implement** the R-M7-13 installer part, all under `#ifndef GhosttyTest`:
  - `CurStepChanged(ssPostInstall)`: classic verbs (unchanged), then, with `explorermenu` ticked and `GetWindowsVersionEx` build ≥ 22000, the `Add-AppxPackage` line; a non-zero exit → `Log` + suppressible note; then delete `{app}\ghostty-explorer.dll.old-*`;
  - `PrepareToInstall`: the tray loop (unchanged), then the remove/delete/rename/Retry sequence for the DLL;
  - `[UninstallRun]` `ExplorerMenuRevert` before `ExplorerRevert`; `CurUninstallStepChanged(usUninstall)` renames a locked DLL aside;
  - every `powershell.exe` call: full path `{sys}\WindowsPowerShell\v1.0\powershell.exe`, hidden, waited, paths quoted per R-M7-13.
- [ ] **Step 3: Verify:** `build.ps1 -SelfTest`; ISCC compiles the release and the test variant for x64 and arm64 from a Task 14 stage (install nothing; delete the outputs); `git grep -n "Add-AppxPackage\|Remove-AppxPackage" dist/windows/installer/ghostty.iss` shows them only inside `#ifndef GhosttyTest` blocks; the scenario parses.
- [ ] **Step 4: Commit** `git commit -m "feat(installer): register the Windows 11 folder-menu package, retry on a locked menu DLL, remove it on uninstall"`

### Task 16: MSYS on the bundled console — decision, switch or documented limit

**Review:** light. **Condition:** the code part runs only if R-M7-12's switch condition holds; the doc part always.

**Files:**
- Create `docs/windows/m7/msys-key-loss.md`: G1/G3 measurements (runs, `lost=n/checks`, Git for Windows and MSYS runtime versions, OpenConsole version), the owner's Windows Terminal result, Task 13's A/B if it ran, the hypotheses of issues § 2a.3 with what the numbers say, the decision, and **bug-report text** for msys2-runtime / Cygwin (title, environment, minimal repro: Git Bash on `conpty.dll`/`OpenConsole.exe` 1.25.260930003, resize then type; expected/actual; the `CSI 6 n` timing observation; the WT comparison). The text is not filed by anyone in this plan.
- Modify (switch only): `src/os/windows.zig` (`conptyWantsBundled` returns true for MSYS; the log line changes), `src/config/Config.zig` (`windows-conpty` doc: `auto` = bundled for everything).
- Modify (limit): `src/config/Config.zig` `windows-conpty` doc gains the workaround sentence for Kitty in Git Bash (`windows-conpty = bundled`, at the cost of a rare lost key).

- [ ] **Step 1 (switch only): Failing test** `"windows conpty: auto picks bundled for MSYS"` (update of the existing `conptyWantsBundled` tests) → FAIL with `-Dtest-filter="windows conpty"`; implement; pass.
- [ ] **Step 2:** Write the doc. **Step 3: Verify:** `LOCK ZIG build test -j6 -Dtest-filter="windows conpty" -Dtest-filter="windows config"`; `LOCK ZIG build -j6`.
- [ ] **Step 4: Commit** `git commit -m "feat(windows): Git Bash on the bundled ConPTY"` (switch) or `git commit -m "docs(windows): MSYS first-key loss on the bundled ConPTY, measurements and report text"` (limit).

### Task 17: Docs — CHANGELOG, SPEC, DECISIONS, checklist, parity audit, READMEs

**Review:** lead.

**Files:** Modify:
- `docs/windows/CHANGELOG.md`: an "M7 — win.2" section. **First lines:** tmux shim off by default and how to turn it on for Claude Code agent teams. Then what changed (each scope item), changes you may notice (symbols/emoji look like Windows Terminal; the tab editor; the Explorer entry ticked and on the Windows 11 top level; cursor bar at the pwsh/cmd prompt), known limitations (cmd cursor during commands; DCS tmux passthrough; MSYS per Task 16; Kitty `a=q` per Task 12; the context menu tested on one machine, Developer Mode case, leftover renamed DLL; `t=s` and MSYS paths for `t=f`). Corrects the M5/M6 "Kitty graphics work there" claim to what G1/G3 measured.
- `docs/windows/SPEC.md`: §9 (symbols/emoji, `font-thicken`), §10 (`CLAUDE_CODE_TMUX_TRUECOLOR`, WSL `--cd`), §12 (default off), §13 (DLL, `.msix`, installer steps, portable lines), §17 (M7 entry, plan link; "done" in Task 18), §18 (R-M7-1…14).
- `docs/windows/DECISIONS.md`: dated amendment lines under "Built-in tmux" (default off, owner 2026-10-29), "Features" (symbols like macOS/WT; Win11 top-level menu with an unsigned sparse package), and the text-weight outcome.
- `docs/windows/feature-checklist.md`, `docs/windows/parity-audit.md`: rows for every scope item, `done`, `manual` or a gap; the Kitty rows by what was measured.
- `docs/windows/issues-after-v1.md`: a short "Status after win.2" list mapping each § 7 row to its task and outcome.
- `dist/windows/README-windows.txt`: tmux paragraph (`windows-tmux-shim = true`), the Explorer section (classic verb + the two PowerShell lines for the package in a portable folder), ≤ 80 columns, ASCII.
- `docs/windows/RELEASING.md`: the Windows SDK `makeappx` requirement in step 1; `-N 2` example; the step where the lead adds the highlights to `release-notes.md` and re-runs `Test-Privacy`.
- `test/windows/README.md`: an "M7 scenarios" section (`font-symbols`, `kitty-render`, `text-weight`, `link-windows-path`, `paste-files`, `wsl-cwd`; `FakeExe.psm1`; the variants; the package-registration safety rule).

- [ ] **Step 1:** Write. **Step 2: Commit** `git commit -m "docs(windows): win.2 changelog, SPEC and decisions as built"`

### Task 18: Release `-win.2`, acceptance, owner sign-off

**Review:** lead + owner.

- [ ] **Step 1 (owner):** `git push origin windows`, then `git fetch --tags origin` (R-M6-7).
- [ ] **Step 2 (owner, or the lead with the owner's go):** `PS dist/windows/release.ps1 -N 2 -ConptyPackage <pkg> -Arm64TestExe`, started with `run_in_background`. Output: 6 artifacts, `SHA256SUMS.txt`, notes, `publish.txt`, `tests.txt` (now with `test-explorer-command`).
- [ ] **Step 3 (lead, the usual lock):**
  - extract the x64 zip to `zig-out\rc`, `GHOSTTY_E2E_EXE=…\ghostty.exe`, `E2E -Milestone all` (M1–M7; `package-portable` and `installer-test` on this RC);
  - `VTS` against the RC exe;
  - the § budget rows (`m7-rc` in the CSVs) against the M6 rows;
  - `test/windows/claude-team.ps1` against the RC with `windows-tmux-shim = true` (the owner's go for the token cost).
- [ ] **Step 4 (lead):** add the win.2 highlights and the residual-risk line (R-M7-14) to `release-notes.md`; `Test-Privacy` on it; regenerate nothing else.
- [ ] **Step 5 (owner):** § M7 exit checklist 9 on the local artifacts.
- [ ] **Step 6:** `docs/windows/m7/acceptance.md`; SPEC §17 "done"; CHANGELOG acceptance line. Commit `git commit -m "docs(windows): M7 acceptance — win.2"`.
- [ ] **Step 7 (owner):** push; run `publish.txt`; check the draft; publish; the update toast from the installed v1.0 (`-win.1`).

Each failure in Steps 2–5 gets an 18.n note (step, log excerpt without the user name, evidence) and a fix commit `fix(<area>): <summary>`.

## M7 exit checklist (owner signs, PASS/FAIL per line)

1. **Release run.** `release.ps1 -N 2` finished with the three unit groups, `test-tmux-shim` and `test-explorer-command` green (`tests.txt`); 6 artifacts + `SHA256SUMS.txt`; privacy scan passed for every artifact, the DLL and the `.msix` included.
2. **Version.** `+version` prints `<zon>-win.2`; FileVersion `<maj>.<min>.<patch>.2` on `ghostty.exe`, `tmux.exe` and `ghostty-explorer.dll`.
3. **e2e and vt-smoke.** `E2E -Milestone all` green on the RC (M1–M7, `package-portable`, `installer-test`); `VTS` green, every changed reference inspected.
4. **Budgets.** The RC rows within § RAM and latency budget.
5. **Claude Code.** `claude-team.ps1` passes with `windows-tmux-shim = true`. With the default (off), Claude Code in Git Bash draws `#D77757` (truecolor), not `#D78787`.
6. **Feature checklist and parity audit** updated: every scope item done, manual or a documented gap.
7. **ARM64** (recorded, never blocking): built and packaged; the test exe run on a device, or N/A.
8. **Docs.** CHANGELOG M7 (tmux line first), SPEC §9/§10/§12/§13/§17/§18, DECISIONS lines, README-windows, RELEASING, `m7/msys-key-loss.md`.
9. **Owner manual checks** (x64, the owner's account, local artifacts with Mark-of-the-Web as in M6):
   - **Upgrade from v1.0** (`-win.1` installed) while Ghostty runs and a File Explorer window is open after using the Ghostty menu: Setup asks to close Ghostty; the Explorer box shows ticked; no Ignore prompt; the upgrade finishes.
   - **Windows 11 menu:** right-click a folder, a folder background and `C:\` → "Open Ghostty here" on the top level (and under "Show more options"); it opens Ghostty there. The taskbar icon groups with the pinned Ghostty and toasts still show under "Ghostty" (no package identity on `ghostty.exe`).
   - **Uninstall:** the menu entries are gone; `Get-AppxPackage -Name Ghostty.ExplorerMenu` prints nothing; the config is kept.
   - **Look:** tab rename shows no white box, typed text visible, opaque and translucent; ⏺ ✔ ⚠ ✻ and emoji look like Windows Terminal; the text weight is as picked.
   - **Kitty:** in pwsh the issues § 2a.4 smoke shows the magenta block; Claude Code shows an image in pwsh (or, per Task 12's outcome, with `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1`).
   - **Links and paste:** Ctrl+click `C:\Windows\win.ini:3` printed in pwsh opens it; copying two files in Explorer and pasting in Git Bash gives their quoted paths.
   - **Shells:** with `shell-integration-features = ssh-env,ssh-terminfo`, `ssh <a real host>` from pwsh and from cmd gets a working `TERM`; the bar cursor shows at the pwsh prompt.
   - **WSL:** a new split from a WSL tab after `cd /tmp` starts in `/tmp`.
10. **Gaps accepted by the owner:** the known limitations of the CHANGELOG M7 section.

Owner sign-off: name, date, tag, PASS/FAIL per line, decision (publish / fix and release `N+1`).

## Self-review

- **Owner scope → tasks:**

  | Scope item (§ 7 / the request) | Tasks |
  |---|---|
  | 1 tmux shim off by default; tmux e2e enable it; docs | 1, 17 (R-M7-1) |
  | 2 Installer Explorer task checked | 1 (R-M7-2), 15 |
  | 3 Symbols/emoji like macOS; Noto only without DirectWrite; font tests, vt-smoke refs | 2, G1 (R-M7-3) |
  | 4 Tab rename popup, `WM_CTLCOLOREDIT`, macOS style, pixel check | 3 (R-M7-4) |
  | 5 Text weight comparison; default only if better | 4, G1 owner pick, 11, G3 (R-M7-5) |
  | 6 `C:\path:12` links; Explorer `CF_HDROP` paste; `click-repeat-interval` | 6 (R-M7-6/7/8) |
  | 7 pwsh/cmd `ssh-env`/`ssh-terminfo`/`cursor`; WSL cwd from OSC 7 | 7, 8 (R-M7-9/10) |
  | 8 Kitty GUI render in pwsh; `a=q` reply path; DCS tmux ruling | 5, 9, 12 (R-M7-11) |
  | 9 Kitty in Git Bash: first-key-loss investigation, WT comparison, switch only if fixed, report text not filed | 5 (variant), G1, 13, 16 (R-M7-12) |
  | 10 Win11 top-level menu: DLL, sparse package with the OID publisher, installer, classic verb kept, Retry on a locked DLL | 10, 14, 15, G4 (R-M7-13) |
  | 11 Docs and release `-N 2` | 17, 18 (R-M7-14) |
  | Safety: GUI only via `e2e.ps1`; no real HKCU; no user name; no `python -`; loopback only; no trailers; no issues/PRs | § Global Constraints, § Owner safety, Tasks 7/8 fakes, 15 test variant |

- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | `Config.zig`, `tmux/env.zig`, `ghostty.iss`, `e2e.ps1`, `tmux-{env,send-keys,labels,replay,external}.ps1`, `package-portable.ps1`, `claude-team.ps1`, `measure-tmux.ps1` |
  | W1 | 2 | `SharedGridSet.zig`, `discovery.zig`, `e2e/font-symbols.ps1`, `vt-smoke/cases/symbols.sh` |
  | W1 | 3 | `title_edit.zig`, `strip_input.zig`, `overlay.zig` (if needed), `ipc/ops.zig`, `e2e/tab-rename.ps1` |
  | W1 | 4 | `face/freetype.zig`, `e2e/text-weight.ps1` |
  | W1 | 5 | `renderer/image.zig`, `e2e/kitty-render.ps1`, `e2e/resize-input.ps1`, `lib/FakeExe.psm1` |
  | W2 | 6 | `config/url.zig`, `win32/clipboard.zig`, `os/mouse.zig`, `e2e/link-windows-path.ps1`, `e2e/paste-files.ps1` |
  | W2 | 7 | `pwsh/ghostty.ps1`, `cmd/ssh.cmd`, `shell_integration.zig`, `shell-marks/run.ps1` |
  | W2 | 8 | `stream_handler.zig`, `Exec.zig`, `win32/Surface.zig` (if needed), `e2e/wsl-cwd.ps1` |
  | W2 | 9 | `conpty-probe/headless.ps1`, `conpty-probe/RESULT.md`, `conpty-probe/cases/headless-kittyq.sh` |
  | W2 | 10 | `src/explorer_command/*`, `GhosttyExplorerCommand.zig`, `build/main.zig`, `build.zig`, `windows_version.zig`, `versioninfo.rc`, `explorer-command.rc` |
  | W3 | 11 | `Config.zig` |
  | W3 | 12 | `win32_input.zig`, `stream_handler.zig`, `Exec.zig`, `message.zig` (if needed), `e2e/kitty-render.ps1` |
  | W3 | 13 | `w32im_experiment.zig`, the key-dispatch file (`keyboard.zig` or `key.zig`), `e2e/resize-input.ps1` |
  | W3 | 14 | `dist/windows/sparse/**`, `package.ps1`, `release.ps1` |
  | W4 | 15 | `ghostty.iss`, `installer/build.ps1`, `e2e/installer-test.ps1` |
  | W4 | 16 | `os/windows.zig` (switch only), `Config.zig`, `docs/windows/m7/msys-key-loss.md` |
  | W5 | 17 | the docs listed in Task 17 |

  No file is shared inside a wave. Task 3's `ipc/ops.zig` and Task 13's key-dispatch file are touched by no other task. Task 8 and Task 12 share `Exec.zig`/`stream_handler.zig` across W2 → W3 only.
- **Names defined once:**

  | Task | Names |
  |---|---|
  | 1 | task `explorermenu`; `CLAUDE_CODE_TMUX_TRUECOLOR` rule; `ValidateSet` `M7` |
  | 2 | presentation-ordered fallback in `Windows.discoverFallback`; vt-smoke case `symbols` |
  | 3 | `title_edit` test-state object; `Session.popup` |
  | 4 | the embolden formula; `text-weight` variants A–D and `info.txt` lines |
  | 5 | `FakeExe.psm1` kinds `argv`/`osc7`/`vtreader`; `GHOSTTY_E2E_VARIANT=bundled` |
  | 9 | `-ReplyForm plain|w32im`; the verdict words |
  | 10 | `ids.zig` constants; `Exe.explorer_command`; `GHOSTTY_FILETYPE`; `test-explorer-command` |
  | 12 | `win32_input.charRecords`/`charRecordsLen`; the reply tag |
  | 13 | `GHOSTTY_WIN32_TEST_W32IM`; variant `bundled-w32im` |
  | 14 | `build-sparse.ps1` parameters and exit codes; `ghostty-explorer.msix` |
  | 15 | `RunOnceId: "ExplorerMenuRevert"`; the `.old-<tick>` rename |
- **Review Focus → tests:** 1 → Task 10 tests, checklist 9; 2 → Task 15, G4, checklist 9; 3 → Task 8 tests, `wsl-cwd`; 4 → G1 tmux batch, Task 18 `claude-team`; 5 → Task 2 tests, `font-symbols`, vt-smoke (G1/G3); 6 → Task 6 tests, `paste-files`; 7 → Task 14 checks, G4, Task 18.
- **Proportion:** code blocks are interfaces and command lines only.
- **Known risks:**
  - Segoe UI Emoji colour through FreeType COLR v0 is unverified until Task 2's test runs; R-M7-3 has the fallback.
  - Unsigned sparse packages may need Developer Mode on some machines; R-M7-13 degrades to the classic verb, and only the owner's machine is tested.
  - A DLL fault crashes Explorer; Review Focus 1 and opus review.
  - The `ssh` wrappers depend on `ghostty.exe` (GUI subsystem) running interactively when launched synchronously; the headless fake-ssh cases cover the argument and TERM handling, a real host is an owner check.
  - A text-weight default change regenerates every vt-smoke reference.
  - The MSYS outcome may well be "documented limit" again; win.2 does not ship full win32-input-mode.

### Owner inputs during the run (not open questions; each has a default)

1. **G1:** pick a text-weight variant from the contact sheet (optionally with a Windows Terminal screenshot of the same sample). Default if no answer before W3: no change (R-M7-5).
2. **G1:** the 5-minute Git Bash check in Windows Terminal (R-M7-12). Default if not done: Task 13 is skipped and the report text says the comparison is missing.
3. **G4:** the go to install the G4 real setup and register the menu package on the owner's machine (owner decision: tested only there). Without it, the context-menu lines of the exit checklist stay open and block the release.
4. **Task 18:** the go for the `claude-team.ps1` token cost, and the publishing commands.
