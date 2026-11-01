# M8 — Ghostty 1.4 for Windows (upstream 1.4 merge, OSC 5522 clipboard, split drag, hidden-surface visibility and GPU release, mode 2033, security cross-check, Claude Code symbols, long-tab input lag, release `1.4.1-dev-win.<N>`): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the third Windows-port release, built on upstream Ghostty 1.4 (`build.zig.zon` `.version = "1.4.1-dev"`), version string `1.4.1-dev-win.<N>` (owner asked for `1.4.1-dev-win.1`; see **R-M8-2**, the lead confirms N with the owner before Task 25). It ships owner scope option 3 (`.superpowers/sdd/M8-win14/owner-decisions.md`):
- the upstream 1.4 merge (done: `windows` @ `6d24a43a3`, unit groups green 647/374/3702);
- **the long-tab input lag**: the D3D11 frame pacer no longer drifts; shader `iTime` keeps precision on old surfaces; pacing counters prove or kill the cause in the batch (Task 1, in flight);
- **Kitty clipboard protocol (OSC 5522)** read/write/paste events with MIME-typed Windows clipboard formats, a confirmation prompt with an image preview and "remember for the session", rich/HTML copy, an in-process selection clipboard;
- **split drag-and-drop** with full upstream parity plus the tab strip: within a tab, onto another tab, into another window, out to a new window; the process moves with the pane;
- **visibility**: hidden windows, the hidden quick terminal, lock screen / display off / remote disconnect and other virtual desktops report "not visible" (mode 2033, `CSI ? 998 n`, render pause, Kitty animation pause, generic GPU release); hidden tabs shrink their DXGI swap chain with a flash-free reshow; `CSI 8 t` guards like macOS/GTK;
- **quick fixes**: `TERMINUS_SUBLIME=1` for Windows children (Claude Code `◯ ✔` symbols), the 1.4 security cross-check gaps (Git for Windows prompt `$PWD` injection, invisible characters in links, C1 in dropped paths), Windows notes in the 1.4 config docs; keybindings checked (nothing changes);
- RAM / latency / GPU baselines re-measured (scrollback default is now 50 MB), every new GUI scenario run in **one batched pass** (Task 24), then the release (Task 25).

Exit: Task 24's batch is green (or every failure has an n.1 fix or an owner-accepted limit), the owner runs the manual checks in Task 24 § Owner checks, Task 25 publishes.

**Architecture:** no new subsystem in the core. Everything is apprt (`src/apprt/win32/`) work plus three renderer files:
- **Renderer:** `src/renderer/d3d11/SwapChain.zig` (pacer, `shrink`), `src/renderer/D3D11.zig` (`waitFrameSlot`, `surfaceHidden`, `presents`, first-present notify), `src/renderer/generic.zig` (`iTime` precision, one `surfaceHidden` hook line).
- **Clipboard:** pure codecs `clipboard_html.zig`, `clipboard_image.zig`, `clipboard_mime.zig`; Win32 glue `clipboard_formats.zig`; request flow in `clipboard.zig`; prompt in `dialogs.zig` + `dialog/*`; `selection_store.zig` on `App`.
- **Split drag:** pure `grab_handle.zig` + `split_drag.zig`; `grab_overlay.zig` (handle on screen); `split_drag_input.zig` (session); the surface move primitive in `Tab.zig`/`Surface.zig`/`hooks.zig`.
- **Visibility:** `Window.syncOcclusion` (window-level state), `screen_state.zig` (lock/display/cloak decoders) on `App`; `Window.RaiseGate` for the flash-free reshow.
- **termio:** `Exec.zig` `windowsUnicodeHint`.
- **Shell integration:** `src/shell-integration/bash/ghostty.bash` (Git prompt title fix).

**Tech Stack:** Zig 0.17.0, Windows PowerShell 5.1, Git for Windows (Git Bash, bash 5.3), the bundled ConPTY 1.25.260930003 (unchanged), wuffs PNG/JPEG decoders (already linked), Direct2D (dialog image), WTS / power-setting / WinEvent APIs.

**Spec** (authority, amended by this plan's rulings; Task 22 records them as SPEC §18 R-M8-*):
- `.superpowers/sdd/M8-win14/owner-decisions.md` — **binding**, not re-asked.
- `.superpowers/sdd/M8-win14/design-context.md` (shared rules), `diag-lag.md` (lag, Task 1 brief = §4–§5), `design-5522.md` (clipboard), `design-drag.md` (split drag), `design-vis.md` (visibility), `design-sec.md` (security, env, keybindings, config keys).
- `docs/windows/SPEC.md`, `docs/windows/DECISIONS.md`; `docs/windows/next-version.md` (backlog: items 10, 11, 25, 28 and the "Upstream Ghostty 1.4.0" section); `docs/windows/issues-after-v1.md` (2.4, 2.5, 3.2, 9.3).
- Release path unchanged from M6/M7: `docs/windows/RELEASING.md`, `dist/windows/release.ps1`.

**Starts** at `windows` @ `6d24a43a3`. Task numbers are identities; the **Waves** table is the execution order. Task 1 is already in flight (`impl-lag`, worktree `.claude/worktrees/sdd-task-lag`).

## Global Constraints

Every task implicitly includes these.

**Toolchain and scope**
- Zig 0.17.0 at `C:/tools/zig-x86_64-windows-0.17.0/zig.exe` (full path). Shell for agents: Git Bash. Target `x86_64-windows-msvc`.
- **Core edits** only at the touch points listed below. A cause found elsewhere: stop with evidence; the lead schedules an `n.1` task.
- **Style follows macOS** (owner memory `style-follows-macos`): sizes, colours, spacing, opacities and animation timings are copied from `macos/Sources/` (the design files name the exact Swift lines). Where macOS has nothing, GTK (`src/apprt/gtk/`), then a Windows convention. Pixel values are DIP, scaled with the window DPI.

**Commits, PRs, issues**
- One commit per task with the message given in the task. **No `Co-Authored-By` or any other trailer** (owner global rule 1).
- **Never create a GitHub issue or PR** (AGENTS.md). Never send anything upstream (`is-unicode-supported`, `git-for-windows`): suggested upstream text goes into docs only (R-M8-4).
- Never `python -` (nor `python3 -` with a heredoc).

**Owner safety** (design-context.md; the owner is working inside Ghostty and this session runs in it)
- **NEVER kill, stop, suspend, attach a debugger to, or send input/messages to any running `ghostty.exe`, `OpenConsole.exe`, `conhost.exe` or shell you did not start yourself.** Read-only inspection (`Get-Process`, handle counts, memory) is allowed. Processes you start are killed **by PID only** (never by name).
- **No GUI window is launched by implementers.** Allowed for implementers: unit tests, builds, script parse checks, `-SelfTest`/`-DryRun` modes, headless probes (`test/windows/conpty-probe/headless.ps1`, `test/windows/shell-marks/run.ps1`) and a scenario's SKIP path. Every GUI run happens in Task 24, through `test/windows/e2e.ps1` (desktop lock, sandbox env, `Register-OwnGhostty`, stop in `finally`, captures only through `Get-ScreenShot`/`Save-WindowShot`/frame dumps).
- **Never write** `HKCU`/`HKLM`, `%USERPROFILE%\.config`, shell rc files, system settings. Scripts write only under `zig-out\`, the e2e sandbox and `%TEMP%`. Never copy files out of the owner's config (R-M8-37).
- **Clipboard:** a scenario or unit test that touches the real clipboard saves every format first and restores it (`lib/Clipboard.psm1`; Zig tests use `SavedClipboard` and skip when the clipboard holds non-text, so an owner's image is never destroyed).
- **Privacy:** no Windows user name in any committed file, log excerpt, ledger, screenshot name or report. Paths are written `%USERPROFILE%`, `%LOCALAPPDATA%`, `%TEMP%`.
- **Network:** none, except reading upstream code already in git (`git show upstream/main:<path>`, `git show v1.4.0:<path>`).
- Outward-facing actions (push, tag, `gh release …`) are the owner's.

**Builds and tests**
- `LOCK` = `bash "C:/Users/murue/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --` (every build and test compile goes through it; Bash timeout 600000). `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`. `PS` = `powershell -NoProfile -ExecutionPolicy Bypass -File`. `E2E` = `PS test/windows/e2e.ps1` (Task 24 only). `VTS` = `PS test/windows/vt-smoke.ps1` (Task 24 only). `RFS` = the M6 local x64 release build (`ZIG_GLOBAL_CACHE_DIR="$PWD/zig-out/zig-global" LOCK ZIG build -j4 -Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtarget=x86_64-windows-msvc --prefix zig-out/rfs`).
- **RAM rule (owner global rule 3):** check free memory before a heavy step; never the full test suite locally; always focused filters: `LOCK ZIG build test -j6 -Dtest-filter="<prefix>"`. When unsure, run smaller filters one at a time. The test-lock keeps ≥ 5 GB free per slot.
- **Test names must fall into a `release.ps1` unit group** (`dist/windows/release.ps1:226-228`): group 1 `win32 ` (everything in `src/apprt/win32/`), group 2 `windows `, `tmux shim `, `Exec: w`, `d3d11 ` (renderer, termio), group 3 `terminal`, `config`, `input`, `font`. So: renderer tests start `d3d11 ` (pacer tests: `d3d11 pacer: …`), apprt tests `win32 `, the Exec helper `windows unicode hint: …`. A test name outside these prefixes is a review finding.
- **New test files** are referenced from a `test { _ = @import("…"); }` block of the module that owns them (listed per task). `src/apprt/win32.zig` is edited only by Task 2.
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`; a cold first build runs with `run_in_background` under `timeout 1500` through the test-lock.
- Per task, the implementer runs: the task's unit filters, `LOCK ZIG build -j6`, `zig fmt` on touched Zig files, a parse check of every new/changed `.ps1`:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```
- **GUI e2e scenarios are written per task but NOT run** (owner decision). Each new scenario has the header `# e2e: milestone=M8 timeout=<s> order=<n>` (orders below), follows the PowerShell 5.1 rules (`Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, inbox modules only, Git Bash by full path, `Invoke-Native`, **no non-ASCII literal in a `.ps1`** — build code points with `[char]0x…`), and is listed in Task 24.
- **Review tier:** `light` = one batched sonnet review per wave; `full` = per-task opus review (parsers of untrusted data, security prompts, ownership/lifetime of surfaces, renderer pacing).

**Process (owner, memory `speed-over-ceremony`):** opus effort medium, sonnet effort high; ≤ 3 tasks per wave here (file sets strictly disjoint, shared registries included); `-j6` builds.

### M8 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/renderer/d3d11/SwapChain.zig` | pacer: count every present, drain backlog, consume the initial signal, idle resync, counters; `shrink()` | 1, 15 |
| `src/renderer/D3D11.zig` | `waitFrameSlot` returns the timeout; pacing log fields; `surfaceHidden`, `shrinkOnHide`, `presents`; `PresentTarget.presented` notify | 1, 15, 17 |
| `src/renderer/generic.zig` | custom-shader times in f64/ns with rebase (H2); one `surfaceHidden` hook line in `setVisible` | 1, 15 |
| `src/renderer/shadertoy.zig` | `rebaseTime` helper + tests (H2) | 1 |
| `src/termio/Exec.zig` | `windowsUnicodeHint` after the Windows TERM block | 18 |
| `src/shell-integration/bash/ghostty.bash` | Git for Windows prompt title: `$PWD` → `${PWD//[[:cntrl:]]/}` (MSYS only) | 6 |
| `src/config/Config.zig` | **doc comments only**: `copy-on-select`, `middle-click-action`, `drag-handle`, `windows-conpty` (if Task 9 shows inbox drops 5522/2033) | 22 |

Not touch points: `src/Surface.zig`, `src/terminal/**`, `src/termio/stream_handler.zig`, `src/datastruct/split_tree.zig`, `src/input/**`, `build.zig.zon`, upstream workflows.

### Fixed interfaces (so tasks in one wave run in parallel)

- **Private messages and timers** (`src/apprt/win32/messages.zig`, all added by Task 2; nobody else edits the file):
  | Name | Value | Posted to / owner | Used by |
  |---|---|---|---|
  | `WM_GHOSTTY_SYNC_OCCLUSION` | `WM_APP + 17` | top-level window, no params | Task 12 |
  | `WM_GHOSTTY_PRESENTED` | `WM_APP + 18` | top-level window, `wparam` = surface id | Task 17 |
  | `timers.msg_window.cloak_debounce` | `8` | App message window, 250 ms (App keeps the pending hwnds) | Task 16 |
  | `timers.window.raise_gate` | `3` | top-level window, 16 ms tick, 100 ms cap | Task 17 |
  | `timers.window.split_drag_spring` | `4` | top-level window (drag capture), 500 ms | Task 11 |
  | `timers.surface.grab_fade` | `4` | surface HWND, 16 ms frames, 150 ms fade | Task 8 |
- **Test IPC surface fields** (`src/apprt/win32/ipc/ops.zig` `writeSurface`): `"core_visible": bool` (Task 12), `"presents": u64` and `"chain_px": [w, h]` (Task 15). Scenarios written before those tasks land use these names.
- **Test IPC app state** (`hooks.testState`, Task 14): `"m8": { "split_drag": { "active", "ghost": "image"|"chip"|null, "zone": [x,y,w,h]|null, "marker": {window,index}|null }, "grab": [{ "surface", "shown": "hidden"|"dim"|"bright", "opacity" }] }`.
- **`split_drag_input.zig`** (stub created by Task 8, filled by Tasks 11 and 14): `pub fn press(s: *Surface, x: i32, y: i32) void`, `pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT` (registered in the `Window.zig` hook list by Task 8, before `strip_input_mod.handle`).
- **`dialogs.zig`** (Task 6 adds, Task 7 uses): `pub const DeceptiveSet = enum { paste, link }`, `pub fn isDeceptive(cp: u21, set: DeceptiveSet) bool`, `pub fn escapeDeceptive(alloc, text, set, max_chars) ![]u8`.
- **`dialogs.zig`** (Task 7 adds, Task 10 uses): `ClipboardKind`, `ClipboardPart`, `ClipboardAnswer`, `confirmClipboard(owner, kind, parts, can_remember) ClipboardAnswer` (signatures in Task 7).
- **`Window.zig`** (Task 12 adds, Tasks 16–17 use): `ScreenState`, `screenState()` (reads `IsWindowVisible`, `IsIconic`, `parked`, the **live** `DwmGetWindowAttribute(DWMWA_CLOAKED)` and the `screen_off` field), pure `windowOnScreen()`, `syncOcclusion()`, field `screen_off: bool = false`. Task 16 only sets `window.screen_off` on every window and calls `syncOcclusion` (no `Window.zig` edit in Task 16; `App.zig` stays out of Task 12).
- **FakeExe** (`test/windows/lib/FakeExe.psm1`, Task 9): `vtreader` gains `FAKE_QUERY_FILE` (query bytes from a file) and `FAKE_UNTIL` (stop after this byte string).
- **e2e orders**: Task 12 `visibility-hidden` 1200; Task 19 `csi8-resize` 1210; Task 20 `hidden-render` 1220; Task 21 `long-tab-lag` 1230; Task 4 `copy-html` 1240; Task 10 `kitty-clipboard-write` 1250, `kitty-clipboard-read` 1251, `kitty-paste-event` 1252; Task 13 `selection-paste` 1260, `middle-click` 1261; Task 6 `title-inject` 1270; Task 14 `split-drag` 1280.

### RAM, latency and GPU budget (measured in Task 24)

| Item | Budget | Measured by |
|---|---|---|
| `ghostty.exe` ReleaseFast, default config, 1 window 1 surface, 30 s after start (`one-surface`) | ≤ latest win.2-era `one-surface` row in `docs/windows/ram-baseline.csv` + 2 MB | Task 24 B8 |
| `scrollback` (filled to the new 50 MB default) | reported, not budgeted (expected ≈ +40 MB vs the 10 MB-era row) | Task 24 B8 |
| Hidden tab GPU memory after Task 15 | ≤ 2 MB per hidden tab (gate for keeping the shrink: R-M8-21) | Task 24 B2 |
| Key echo, Ghostty-owned p95 (`input-latency`) | ≤ latest row + 0.5 ms with the default config; with a custom shader ≥ 1 refresh period better than before Task 1 | Task 24 B8 |
| Long tab vs fresh tab key echo after 10 min of Claude-like output with a cursor shader | same distribution (≤ 2 ms p50 difference) | Task 24 B4 |
| Tab switch, visible → first present p95 (`show_ms`) | ≤ 50 ms | Task 24 B2 |

Over budget: the batch reports DONE_WITH_CONCERNS with numbers; the lead opens an n.1 task or the owner accepts.

## Review Focus

1. **Renderer pacing** (Tasks 1, 15, 17). The pacer must never block longer than today, never deadlock the draw mutex, and a swap-chain shrink must keep a composition chain attached to its visual. Tests: `d3d11 pacer:` and `d3d11 swapchain:` units, WARP tests, Task 24 B2/B4.
2. **Untrusted data parsers** (Task 3). CF_HTML headers, DIB headers and PNG/JPEG data come from other programs: every offset and size is overflow-checked against the block; hostile corpora and `std.testing.fuzz`.
3. **Clipboard security prompt** (Tasks 7, 10). The prompt shows exactly the bytes that are served, never the program's `name`, Deny is the default, remember only with a password; every request path ends in exactly one complete or deny (no double consumption of the arena-owned state).
4. **Surface lifetime across a move** (Tasks 5, 11, 14). A moved pane keeps its HWND, ConPTY and threads: reparent before remove, empty the tree before `removeTab`, close the old window last; every per-surface subsystem follows the new window.
5. **Security fixes** (Task 6). Git prompt rewrite touches only the literal from `git-prompt.sh`; the invisible-character set equals macOS `isUnsafeCharacter`; no regression of existing `shell_open` rows.

## Rulings (plan-m8, 2026-11-01; owner answers where given, else the design's recommendation; lead/owner may overturn; Task 22 records them as SPEC §18)

Owner (owner-decisions.md):
- **R-M8-1:** Scope = option 3: merge upstream 1.4 + quick fixes (Claude Code symbols, 1.4 security cross-check, RAM/latency baselines) + OSC 5522, split drag, GPU release for hidden tabs, mode 2033 + the long-tab lag fix — owner.
- **R-M8-2:** **Owner answer (2026-11-01): `1.4.1-dev-win.3`, tag `win-1.4.1-dev-3`; Task 23 is skipped.** Version `1.4.1-dev-win.<N>`. The owner asked for N = 1, but `src/apprt/win32/update/release.zig:1-5` compares releases **by N only** and `dist/windows/release-version.ps1:62-72` refuses an N not above the highest tag (`win-1.3.2-dev-2`): N = 1 would be refused, and installed win.1/win.2 builds would never announce it. **Recommended: N = 3 → `1.4.1-dev-win.3`, tag `win-1.4.1-dev-3`, no code change.** If the owner insists on `win.1`, Task 23 (conditional) changes the compare to (zon, N) and the CHANGELOG states that win.1/win.2 installs get no update toast. **The lead asks the owner before Task 22** — owner + plan.
- **R-M8-3:** Windows children get `TERMINUS_SUBLIME=1` when the final `TERM` is `xterm-ghostty` and the variable is unset (inherited or `env`); a user value is never overridden; no config knob; the opt-out is `env = TERM=xterm-256color` or `unset TERMINUS_SUBLIME` in the shell rc (documented) — owner + design-sec Q1.
- **R-M8-4:** No PR/issue to `is-unicode-supported` or `git-for-windows`; Task 22 writes the suggested upstream text into `next-version.md` only — owner (AGENTS.md).
- **R-M8-5:** Split drag: full parity (within a tab, onto another tab, into another window, out to a new window; the process moves with the pane) — owner.
- **R-M8-6:** Keybindings: the GTK 1.4 defaults (`ctrl+shift+page_up/down` = `move_tab`, `ctrl+shift+arrow_up/down` = `jump_to_prompt`) are already in our tree since win.1; the merge changes no binding; nothing is lost; `jump_to_prompt` stays non-performable (upstream core) — owner + design-sec §3.
- **R-M8-7:** The lag symptom is render-path latency (typed text and selection both late) → H1. Task 1 ships the pacer fix (diag-lag §4 steps 1–5), the `iTime` precision fix (H2) and the counters (§5 step 5) before proof; Task 24 B4 proves or kills H1 — owner + diag-lag Q3.
- **R-M8-8:** `copy_to_clipboard = mixed` (HTML on every copy) stays the upstream default; plain copy via `copy_to_clipboard:plain` is documented — owner.
- **R-M8-9:** `middle-click-action` default stays `primary-paste`. With Task 13's selection store it pastes the Ghostty-only selection buffer, which is empty unless the user sets `copy-on-select = primary|both` (Windows default `none`, `Config.zig:2559-2562`); so the default stays a no-op, as documented — owner + lead (reconciles design-vis V8 with design-5522 Task 6).
- **R-M8-10:** The drag handle exists on a lone pane (macOS `auto`: hidden only for a single pane in fullscreen) — owner.

Clipboard (design-5522):
- **R-M8-11:** OSC 5522 `loc=primary` and OSC 52 `p` → ENOSYS (macOS); `.selection` is supported, `.primary` is not — design-5522 Q1.
- **R-M8-12:** Image writes put `"PNG"` (or `"JFIF"`) **and** `CF_DIBV5`; decode failure or > 128 MiB decoded → the original format only — Q2.
- **R-M8-13:** When the clipboard holds only `CF_HDROP`: a 5522 `text/plain` read gets nothing, `text/uri-list` is served; Ctrl+V still pastes quoted paths (M7) — Q4.
- **R-M8-14:** A program's `text/uri-list` write is a plain registered format, never synthesised to `CF_HDROP` — Q5.
- **R-M8-15:** No read size cap, unless Task 9 measures an 8 MiB reply taking > 5 s or growing OpenConsole by > 500 MB; then Task 10 skips any representation larger than `clipboard-write-limit-bytes` (served as "not available", one log line) — Q6.
- **R-M8-16:** If the inbox console drops OSC 5522 / `?5522` / `?2033`: documented limit (Git Bash under `windows-conpty = auto`), MSYS is **not** moved to the bundled console for it; scenarios use a native program (bundled under `auto`) — Q7 + design-vis V6.
- **R-M8-17:** Prompt default button = Deny/Cancel (Enter denies; `paste-confirm.ps1` depends on it); labels Deny/Allow (paste: Cancel/Paste); the program's `name` is never shown; "Remember this choice for the session" only when the request has a password — Q8 + macOS.
- **R-M8-18:** The selection clipboard is an in-process store on `App` shared by all windows (macOS private pasteboard model); nothing leaves the process, no toast, no secure markers — design-5522 Task 6.
- **R-M8-19:** CF_HTML fragment served as `StartFragment..EndFragment`, fallbacks in design-5522 § 3 order; every write sets the three secure-input markers as today; MIME names must pass `isMimeName` (no `/` → refused), so programs cannot plant shell/clipboard-history control formats — design-5522 § 3.

Visibility (design-vis):
- **R-M8-20:** Lock screen, display off, remote/console disconnect and another virtual desktop = "not visible" (2033 `;2n`, render stops); cloak → occluded debounced 250 ms, uncloak immediate — Q1.
- **R-M8-21:** Hidden-tab DXGI swap chains shrink to 1×1 (Task 15) with the flash-free reshow (Task 17). Because GUI runs are deferred, both are implemented now and the gate is measured in Task 24 B2: keep the shrink if a hidden tab holds ≥ 8 MB at the default size or ≥ 30 MB maximized at 1080p before the shrink; otherwise the lead sets `shrink_hidden_chains = false` (one `const` in `D3D11.zig`) in an n.1 commit. If the B2 capture shows a flash Task 17 cannot fix, the fallback is the 10 s grace (shrink only tabs hidden > 10 s) as an n.1 task — Q3 + lead.
- **R-M8-22:** Windows fully covered by other apps are not tracked — Q2.
- **R-M8-23:** Zoomed-out split panes stay "not visible" (GTK, current behaviour) — Q6.
- **R-M8-24:** No EcoQoS / process power throttling in M8 — Q7.
- **R-M8-25:** `CSI 8 ; rows ; cols t` resizes only a lone surface in a single-tab, non-quick, non-maximized, non-fullscreen, non-snapped window with the inspector closed, by the surface delta, clamped to the work area keeping the top-left; `vt-window-resize-allowed` stays `false` by default — Q5.
- **R-M8-26:** Minimized windows keep their swap chain (DWM live preview, Alt+Tab) but are reported not visible — design-vis § 1.3.

Split drag (design-drag):
- **R-M8-27:** The tab strip is a drop target: release = new tab at the insertion slot (the tab-drag marker); hovering a chip 500 ms switches to that tab (spring-loading) — Q2.
- **R-M8-28:** Dragging out of a single-pane tab in a multi-tab window opens a new window; a lone pane of a lone tab dropped outside does nothing (macOS) — Q3.
- **R-M8-29:** Cursor `IDC_SIZEALL` over the handle and during the drag — Q4.
- **R-M8-30:** No undo for a split move; a move drops the undo entries of the tabs involved; "undo of split move" goes into `next-version.md` — Q5.
- **R-M8-31:** Ghost = 20 % snapshot of the pane centred on the pointer; title-chip fallback under secure input, on capture failure, below 48×32 px or an all-black sample row — Q6.
- **R-M8-32:** Config docs get one Windows line each for `drag-handle` ("On Windows, the same as macOS"), `copy-on-select`, `middle-click-action`, and `windows-conpty` if Task 9 shows an inbox drop — design-drag Q7 + design-sec DOC-1.
- **R-M8-33:** The quick terminal has no handle and is never a drop target (`QuickTerminal.acceptsTabDrop`) — Q8.
- **R-M8-34:** tmux-shim panes can be moved; a moved pane becomes a pane of the other tmux window (labels refresh) — Q9.
- **R-M8-35:** Same-tree move = "split the target first, then remove the source" (GTK order), ratio 0.5; cross-tree move inserts into the target tree first and aborts on OOM with nothing changed — design-drag § 2.

Security / docs (design-sec):
- **R-M8-36:** `clipboard-write` default stays `allow`; Task 6's Git prompt fix closes the known Windows vector — Q4.
- **R-M8-37:** The lag repro uses our own minimal cursor-trail shader in `test/windows/configs/` (200 ms trail on `iTime - iTimeCursorChange`), never a copy of the owner's shader or config — lead (owner-state rule).
- **R-M8-38:** The invisible set is macOS `isUnsafeCharacter` (C0, C1, U+061C, U+200B–U+200F, U+202A–U+202E, U+2066–U+2069, U+2028/2029, U+2060, U+FEFF); `.paste` excludes U+200D (ZWJ in emoji); dropped paths also refuse C1 — design-sec SEC-2/SEC-3.
- **R-M8-39:** Scrollback default 50 MB (upstream) is kept on Windows; SPEC says `scrollback-limit-bytes`; Task 24 re-measures the RAM row — design-sec § 4 + lead.
- **R-M8-40:** Kitty animation on D3D11 was never verified: if Task 24 shows frames do not advance while visible, that is a separate n.1 renderer task, not a Task 20 failure — design-vis V5.

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint, shared registries included. Task 1 is in flight.

| Wave | Tasks | Depends on | Files that make the split |
|---|---|---|---|
| W1 | **1** D3D11 pacer + `iTime` (in flight) · **2** drag pure logic + M8 registries · **3** clipboard codecs | — | 1 owns `d3d11/SwapChain.zig`, `D3D11.zig`, `generic.zig`, `shadertoy.zig`; 2 owns `win32.zig`, `messages.zig`, `e2e.ps1`; 3 creates `clipboard_html/image/mime.zig` and registers them from `clipboard.zig`'s test block (no other W1 task touches `clipboard.zig`) |
| W2 | **4** clipboard formats + rich copy · **5** surface move primitive · **6** security fixes | 3 (4); 2 (5) | 4 owns `clipboard.zig`; 5 owns `Tab.zig`, `Surface.zig`, `hooks.zig`, `overlay.zig`, `composition.zig`, `tmux/labels.zig`; 6 owns `dialogs.zig`, `link*.zig`, `shell_open.zig`, `drop.zig`, `ghostty.bash` |
| W3 | **7** clipboard prompt · **8** grab handle on screen · **9** ConPTY probes 5522 + 2033 | 3, 6 (7); 2, 5 (8) | 7 owns `dialogs.zig`, `dialog/*`, `d2d1.zig`; 8 owns `Surface.zig`, `hooks.zig`, `mouse.zig`, `Window.zig` (hook-list line); 9 owns `conpty-probe/*`, `FakeExe.psm1` |
| W4 | **10** Kitty clipboard flow · **11** drag session · **12** window-level visibility | 4, 7, 9 (10); 8 (11); — (12) | 10 owns `clipboard.zig`; 11 owns `split_drag_input.zig`, `App.zig`, `drag_ghost.zig`, `strip_input.zig`; 12 owns `Window.zig`, `Tab.zig`, `ipc/ops.zig`, `pkg/win32/dwmapi.zig` |
| W5 | **13** selection clipboard + middle click · **14** drag out, test state, scenario · **15** swap-chain shrink | 10 (13); 11 (14); 1, 12 (15) | 13 owns `clipboard.zig`, `App.zig`; 14 owns `Window.zig`, `split_drag_input.zig`, `grab_overlay.zig`, `hooks.zig`; 15 owns `D3D11.zig`, `SwapChain.zig`, `generic.zig`, `ipc/ops.zig` |
| W6 | **16** lock / display / cloak · **17** flash-free reshow · **18** `TERMINUS_SUBLIME` | 12 (16); 15 (17); — (18) | 16 owns `App.zig`, `pkg/win32/*`, `SharedDeps.zig`; 17 owns `D3D11.zig`, `Surface.zig`, `Window.zig`, `Tab.zig`; 18 owns `Exec.zig`, `term-terminfo.ps1` |
| W7 | **19** `CSI 8 t` guards · **20** hidden-render scenario + GPU/RAM measurement · **21** long-tab lag scenario | — (19); names fixed (20); 1 (21) | 19 owns `window_actions.zig`, `placement.zig`, `pkg/win32/user32.zig`; 20 owns `measure-ram.ps1`, `hidden-render.ps1`, `vt-smoke/cases/kitty-anim.sh`, `gpu-baseline.csv`; 21 owns `long-tab-lag.ps1`, `lag-gen.js`, `configs/cursor-trail.*` |
| W8 | **22** docs, CHANGELOG, version · (**23** version compare by zon + N, only if R-M8-2 = `win.1`) | all of 1–21; R-M8-2 answer | 22 owns `docs/windows/**`, `Config.zig` (docs), `test/windows/README.md`; 23 owns `update/release.zig`, `update/Updater.zig`, `release-version.ps1` |
| W9 | **24** batched GUI e2e + baselines (lead, owner away) | 22 | — |
| W10 | **25** release (lead + owner) | 24 | — |

Hot-file chains (every file touched by more than one task, in order):
- `src/apprt/win32/clipboard.zig`: 3 (test-import lines only) → 4 → 10 → 13.
- `src/apprt/win32/dialogs.zig`: 6 → 7.
- `src/apprt/win32/Window.zig`: 8 (hook-list line) → 12 → 14 → 17.
- `src/apprt/win32/Tab.zig`: 5 → 12 → 17.
- `src/apprt/win32/Surface.zig`: 5 → 8 → 17.
- `src/apprt/win32/hooks.zig`: 5 → 8 → 14.
- `src/apprt/win32/App.zig`: 11 → 13 → 16.
- `src/apprt/win32/split_drag_input.zig`: 8 (create stub) → 11 → 14.
- `src/apprt/win32/grab_overlay.zig`: 8 → 14.
- `src/apprt/win32/ipc/ops.zig`: 12 → 15.
- `src/renderer/D3D11.zig`: 1 → 15 → 17. `src/renderer/d3d11/SwapChain.zig`, `src/renderer/generic.zig`: 1 → 15.
- `pkg/win32/user32.zig`: 16 → 19. `pkg/win32/dwmapi.zig`: 12 only.
- `src/apprt/win32/messages.zig`, `src/apprt/win32.zig`, `test/windows/e2e.ps1`: 2 only.
- `test/windows/lib/FakeExe.psm1`: 9 only (10, 13 use it).
- `src/config/Config.zig`, `docs/windows/**`, `test/windows/README.md`: 22 only (21's and 20's CSV/script files excepted: `docs/windows/gpu-baseline.csv` is created by 20; Task 24 appends rows to the CSVs).

---

### Task 1: D3D11 frame pacer, shader `iTime` precision, pacing counters (IN FLIGHT)

**Review:** full (renderer pacing). **Owner:** `impl-lag`. **Brief:** `.superpowers/sdd/M8-win14/diag-lag.md` §4–§5.

**Depends:** —

**Files:**
- Modify `src/renderer/d3d11/SwapChain.zig`: `Pacer` (`presented` without the `buffer_count` cap, saturating at `maxInt(u32)`; `wait` drains a backlog with 0 ms polls, then one blocking wait; idle resync drains the semaphore and sets `pending = 0`; counters `capped_presents`, `wait_timeouts`), `init` (consume the initial signal with `WaitForSingleObjectEx(h, 0, 0)`), `waitForSlot`; unit tests.
- Modify `src/renderer/D3D11.zig`: `waitFrameSlot` returns `.timeout` to the frame; pacing log (`GHOSTTY_D3D11_PACING_LOG`) counts drawn-anyway frames; info line on resync `d3d11 pacer resync surface=<id> drained=<n> capped=<c> timeouts=<t>`; WARP test.
- Modify `src/renderer/generic.zig`: `updateCustomShaderUniformsForFrame` keeps times in f64 or integer ns and rebases `first_frame_time` when `time - cursor_change_time > 1 s` and `time - time_focus > 1 s` (H2).
- Modify `src/renderer/shadertoy.zig`: `rebaseTime` + 2 tests (as built by `impl-lag`).
- As built: commits `24adbfa28` (D3D11.zig + SwapChain.zig) and `9eb1997fd` (generic.zig + shadertoy.zig) on `sdd/task-lag`; report `.superpowers/sdd/M8-win14/task-lag-report.md`. No e2e, `gen.js`, config or docs files: the repro scenario is Task 21 (it follows the report's `lag-pacer` sketch). Review check: every new test name starts `d3d11 ` (or another release-group prefix); rename on review if not.

Steps (from the brief): 1) failing pacer tests; 2) the five fix steps of §4; 3) counters + resync log (§5 step 5); 4) H2 fix + test; 5) verify; 6) commit.

**Unit tests** (names must start `d3d11 ` so they land in release group 2):
- `d3d11 pacer: presents beyond the back buffer count are all matched` — 5 presents + 5 signals → `pending == 0`, no further wait.
- `d3d11 pacer: backlog drains in one wait` — pending 4, signals 4 → one `wait` consumes all 4 without blocking.
- `d3d11 pacer: idle resync drops stale signals` — 3 surplus signals, idle → `pending == 0`, the next wait blocks (fake reports timeout); `drained == 3` in the counters.
- `d3d11 pacer: timeout keeps the present owed` — existing behaviour.
- `d3d11 swapchain: undrained presents are drained by waitForSlot` (WARP) — present 10× without waits, `waitForSlot` → the next 0 ms poll times out.
- `d3d11 shader time: three days resolve one millisecond` (generic, pure helper) — after a simulated 3 days, `time - cursor_change_time` resolves 1 ms; rebase keeps `iTime - iTimeCursorChange` continuous.
- Existing `d3d11 ` swap-chain tests (`D3D11.zig` ~1425) stay green.

**Verify:** `LOCK ZIG build test -j6 -Dtest-filter="d3d11 "`; `LOCK ZIG build -j6`.

**E2e:** none of its own (Task 21's `long-tab-lag` + Task 24 B4).

**Done:** tests green; the pacing log line carries the timeout; commit `fix(d3d11): pacer counts every present and resyncs when idle; shader time keeps precision`.

### Task 2: Split drag pure logic (`grab_handle.zig`, `split_drag.zig`) and the M8 registries

**Review:** light. **Size:** 5 h.

**Depends:** —

**Files:**
- Create `src/apprt/win32/grab_handle.zig` (design-drag T1 interface: `Mode`, `handle_dip = 80×12`, `hover_factor = 0.2`, `handleRect`, `hoverBand`, `active(mode, fullscreen, tree_split, quick)`, `Ellipsis = { hidden, dim, bright }`, `ellipsis(...)`, `fade(from, to, t_ms)` 150 ms ease-in-out).
- Create `src/apprt/win32/split_drag.zig` (design-drag T2 interface: `Zone`, `zoneAt`, `zoneRect`, `direction`, `Hit`, `Event`, `Source`, `Outcome`, `Feedback`, `Machine.begin/feed`, `paneValid`, `outsideOutcome`, `moveWithin`, `insertInto`; plus T6's pure `newWindowOrigin(pointer, grab, offset, src_dpi, dst_dpi) Point`).
- Modify `src/apprt/win32.zig`: `_ = @import("win32/grab_handle.zig");`, `_ = @import("win32/split_drag.zig");` in the test block (next to `tab_drag.zig`).
- Modify `src/apprt/win32/messages.zig`: every id in **Fixed interfaces → Private messages and timers**, each with a doc comment; extend the id-uniqueness tests.
- Modify `test/windows/e2e.ps1`: `ValidateSet` += `'M8'`; help text lists M8.

Steps:
- [ ] **1. Failing tests** (below).
- [ ] **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 grab handle" -Dtest-filter="win32 split drag" -Dtest-filter="win32 skeleton"` → FAIL.
- [ ] **3. Implement.** `zoneAt` with f64 relative distances exactly like `macos/Sources/Features/Splits/TerminalSplitTreeView.swift:205-221` (ties left, right, top, bottom). Machine: `pressed` until `TabStrip.Metrics.drag_threshold` (4 DIP), then `dragging`; spring arms on a chip change, cancels on leaving, `spring_fired` over the same chip → `select`; `release` maps the last hit (`pane` valid → `to_pane`, `strip` → `new_tab`, `outside` → `outsideOutcome`, else `none`); `cancel` → `cancelled`; events after `done` are ignored. `moveWithin` = split target first, then remove source by its old handle (R-M8-35); error with no change if `src == dst` or either missing. `quick = true` → `active` false (R-M8-33); `always` shows `dim` with a hidden pointer.
- [ ] **4. Verify:** the filters pass; `LOCK ZIG build -j6`; `e2e.ps1` parses (the runner has no listing mode; it is **not** started — it would take the desktop lock and open windows).
- [ ] **5. Commit** `feat(win32): split drag geometry and state machine; M8 message ids and e2e milestone`

**Unit tests:**
- `win32 grab handle: rect is 80x12 DIP top centre` (96 and 144 dpi); `… rect clamps to a narrow pane`; `… hover band is 20 % with a 12 DIP floor and pane-height cap`; `… auto: active unless fullscreen with one pane`; `… never: inactive`; `… quick terminal: inactive`; `… ellipsis: auto hides with hidden pointer, bright on handle, dim in band, bright while dragging`; `… always: dim even with hidden pointer`; `… fade: 0 at start, target at 150 ms, monotonic`.
- `win32 split drag: zone triangles` (centre tie → left; points near each edge); `… zone rect is the half on the zone side` (odd sizes); `… below threshold release is none`; `… self pane gives no zone and release is none`; `… pane of a single-pane source tab is invalid only for itself`; `… release over a pane moves there with its zone`; `… release on the strip makes a new tab at the slot`; `… outside: new window for a split tab, for a multi-tab window, none for a lone pane`; `… spring arms on a tab, cancels on leaving, selects when it fires over the same tab`; `… Esc cancels; events after finish do nothing`; `… moveWithin: 2 panes swapped by dropping A on B's right`; `… moveWithin: 3 panes into a nested split, refs balanced` (TestView ref counts back to 1 after deinit); `… moveWithin of a zoomed source unzooms`; `… insertInto: target grows by 2 nodes, source untouched`; `… new-window origin keeps the grab point under the pointer`; `… new-window origin with a DPI change`.
- `win32 skeleton: M8 message and timer ids are unique` (extends the existing tests: `WM_APP + 17`, `+ 18`; window timers 3, 4; msg_window timer 8; surface timer 4; each unique within its class).

**E2e:** none (pure).

**Done:** all filters green; no other file touched.

### Task 3: Clipboard codecs — CF_HTML, DIB/PNG, MIME names (pure Zig)

**Review:** full (parsers of untrusted data). **Size:** 6 h.

**Depends:** —

**Files:**
- Create `src/apprt/win32/clipboard_html.zig`: `pub fn wrap(alloc, html: []const u8) ![]u8` (CF_HTML: `Version:0.9` + 10-digit `StartHTML/EndHTML/StartFragment/EndFragment` byte offsets; plain data → `<html><body>\r\n<!--StartFragment-->…<!--EndFragment-->\r\n</body>\r\n</html>`; data with `<!--StartFragment-->` indexed as is; data with `<body…>` gets the markers inside the body); `pub fn fragment(block: []const u8) ?[]const u8` (borrowed slice; header values decimal ≤ block length, `-1` = absent; fallbacks: markers, `StartHTML..EndHTML`, body after header; never out of bounds).
- Create `src/apprt/win32/clipboard_image.zig`: `Rgba`, `fromDib` (BITMAPINFOHEADER/V4/V5 = 40/108/124; 24/32 bpp; `BI_RGB`/`BI_BITFIELDS` with masks; mask-less 32 bpp all-zero alpha → opaque; signed height; `biSizeImage` 0 allowed; stride rounded to 4; overflow-checked against `block.len`; > 16384 px a side or > 256 MiB pixels → `error.TooLarge`; other depths → `error.Unsupported`), `toDibV5` (BITMAPV5HEADER, BI_BITFIELDS, `LCS_sRGB`, bottom-up BGRA), `encodePng` (IHDR 8-bit RGBA colour type 6, one IDAT from `std.compress.flate` zlib container, filter 0, fast level, IEND, CRC from `std.hash.Crc32`), `decode(alloc, mime, data)` (`image/png` → `wuffs.png.decode`, `image/jpeg` → `wuffs.jpeg.decode`, else `error.Unsupported`; decoded > 128 MiB → `error.TooLarge`), `preview(alloc, img, max_w, max_h) !Bgra` (box-filter downscale to fit, premultiplied BGRA).
- Create `src/apprt/win32/clipboard_mime.zig`: `pub fn isMimeName(name) bool` (`token "/" token [";" params]`, ASCII, no spaces, ≤ 255 bytes, token chars `A-Za-z0-9!#$&^_.+-`); `pub fn uriList(alloc, paths: []const []const u16) ![]u8` (`file:///C:/…` RFC 3986 percent-encoded UTF-8, `\r\n` after each; UNC `\\srv\share\x` → `file://srv/share/x`).
- Modify `src/apprt/win32/clipboard.zig`: **only** add `_ = @import("clipboard_html.zig"); _ = @import("clipboard_image.zig"); _ = @import("clipboard_mime.zig");` to a `test {}` block at the end of the file (no other change).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 clipboard html" -Dtest-filter="win32 clipboard image" -Dtest-filter="win32 clipboard mime"` → FAIL → **3. Implement** → **4. Verify** (filters, `LOCK ZIG build -j6`; check wuffs is reachable from the win32 test root — `src/build/SharedDeps.zig:533-538` already links it into the exe; if the test step lacks it, add nothing to the build and route `decode` through the module the exe uses, reporting the seam in the commit message) → **5. Commit** `feat(win32): CF_HTML, DIB and PNG codecs and MIME names for the clipboard`.

**Unit tests:**
- `win32 clipboard html: wrap computes offsets` — `wrap("<b>x</b>")`: offsets point exactly at `<html>`, `<b>`, the byte after `</b>`, the end; `fragment(wrap(x)) == x`; `<body class=a>` gets markers inside the body; already-marked data is not double-marked.
- `win32 clipboard html: fragment of real-world blocks` — Chrome-style and Word-style headers (`StartSelection`, `SourceURL`), `-1` StartHTML, offsets past the end → marker fallback, no header → null, CRLF and LF.
- `win32 clipboard html: hostile headers` — offsets `99999999999`, negative, End < Start, non-digits: no panic, null or fallback; also under `std.testing.fuzz` with that corpus.
- `win32 clipboard image: dib 24 and 32 bpp` — 2×2 bottom-up 24 bpp (padded stride), top-down 32 bpp BI_BITFIELDS with alpha, BI_RGB 32 bpp zero alpha → opaque; exact RGBA bytes.
- `win32 clipboard image: dib rejects lies` — size larger than the block, 1/4/8/16 bpp, zero width, height `minInt(i32)`: errors, no OOB.
- `win32 clipboard image: dibv5 roundtrip` — `fromDib(toDibV5(img)) == img`.
- `win32 clipboard image: png encode decodes with wuffs` — 1×1, 3×2, 257×3 equal after `wuffs.png.decode`.
- `win32 clipboard image: preview fits and premultiplies` — 800×6000 → inside the box, aspect kept; 50 % alpha red → premultiplied BGRA.
- `win32 clipboard mime: names` — `image/png`, `text/plain;charset=utf-8`, `application/x.foo+json` true; `PNG`, `HTML Format`, `FileGroupDescriptorW`, `a/ b`, `/x`, 300-byte name, non-ASCII false.
- `win32 clipboard mime: uri list` — `C:\My Files\ж.txt` (built from code points) → `file:///C:/My%20Files/%D0%B6.txt\r\n`; UNC case.

**E2e:** none (pure).

**Done:** filters green under the testing allocator (no leaks); fuzz test runs its corpus.

### Task 4: Clipboard formats layer — read one MIME, list, multi-format write; rich/HTML copy

**Review:** full. **Size:** 5 h.

**Depends:** 3.

**Files:**
- Create `src/apprt/win32/clipboard_formats.zig`: `Format = { id: u32, name: ?[]const u8 }`; **pure** `mimesFor(formats, buf) []const []const u8` (order `text/plain`, `text/html`, `image/png`, `image/jpeg`, `image/gif`, `text/rtf`, `text/uri-list`, then registered names passing `isMimeName` in enumeration order; de-dup; cap 16); `list(hwnd, buf: *[16][]const u8, names: *NameBuf)` (`EnumClipboardFormats` + `GetClipboardFormatNameW` only, never `GetClipboardData`); `readMime(alloc, hwnd, mime) !?[]u8` (design-5522 § 3 read table; `text/plain` never from `CF_HDROP`, R-M8-13); **pure** `plan(alloc, contents: []const apprt.ClipboardContent) !Plan` (formats + bytes a write sets, incl. CF_HTML wrap and image decode → DIBV5, R-M8-12); `writePlan(hwnd, plan, secure: bool)` (one `OpenClipboard`/`EmptyClipboard`/N×`SetClipboardData` transaction, `GlobalAlloc` per entry, secure markers last). `test {}` block references nothing new (its own tests only).
- Modify `src/apprt/win32/clipboard.zig`: `setClipboard` uses `plan` + `writePlan` (drop `error.NoTextContent`; image-only and HTML-only writes work; `cleared` = no non-empty representation, GTK rule); `write(hwnd, text, secure)` kept as a text-only helper re-implemented as a one-entry plan (callers `tab_actions.zig`, `proxy_icon.zig`, `tmux/Registry.zig` unchanged); `pub const listMimes = clipboard_formats.list; pub const readMime = clipboard_formats.readMime;`; `_ = @import("clipboard_formats.zig");` in the test block.
- Create `test/windows/e2e/copy-html.ps1` (`# e2e: milestone=M8 timeout=120 order=1240`).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 clipboard"` → FAIL → **3. Implement** → **4. Verify** (filter green — real-clipboard tests skip when the clipboard holds non-text; `LOCK ZIG build -j6`; scenario parses) → **5. Commit** `feat(win32): multi-format clipboard writes and MIME reads; rich HTML copy`.

**Unit tests:**
- `win32 clipboard formats: listing order and mapping` — `mimesFor({CF_UNICODETEXT, CF_LOCALE, "HTML Format", CF_DIB, "PNG", CF_HDROP, "image/svg+xml", "Chromium Web Custom MIME Data Format", "Rich Text Format"})` → `text/plain, text/html, image/png, text/rtf, text/uri-list, image/svg+xml`; 30 MIME-named formats → 16.
- `win32 clipboard formats: write plan` — `{text/plain "a\nb", text/html "<b>a</b>"}` → CF_UNICODETEXT + "HTML Format" (fragment == input); `{image/png 2×2}` → "PNG" + CF_DIBV5 2×2; corrupt PNG → "PNG" only; a `FileGroupDescriptorW`-named mime skipped; two text reps → one CF_UNICODETEXT (first); empty `text/plain` → one empty CF_UNICODETEXT.
- `win32 clipboard: multi-format roundtrip` (real clipboard, `SavedClipboard`-guarded) — write text+html+png; `readMime` returns each input (html as fragment, png identical); `list` gives the three in order; `IsClipboardFormatAvailable(CF_DIB)` true.
- `win32 clipboard: png served from a dib` (real clipboard) — only CF_DIB 2×2 24 bpp → `readMime("image/png")` decodes to the same pixels.
- Existing `win32 clipboard:` tests stay green.

**E2e `copy-html.ps1`** (written, not run): Git Bash prints `\e[31mred\e[0m plain`; drag-select with `MouseInput.psm1`; `Ctrl+Shift+C`. Assert: the "HTML Format" fragment contains `red` inside a `color: #` style and CF_UNICODETEXT is `red plain`. Then a config with `keybind = ctrl+shift+c=copy_to_clipboard:plain` (reload) → no "HTML Format". Clipboard saved/restored with `Clipboard.psm1`.

**Done:** filters green; Ctrl+Shift+C still copies text exactly as before (the text representation is byte-identical to win.2).

### Task 5: Surface move primitive (reparent one pane, no process restart)

**Review:** full (surface lifetime). **Size:** 4 h.

**Depends:** 2.

**Files:**
- Modify `src/apprt/win32/Surface.zig`: `pub fn reparent(self: *Surface, to: *Tab) void` (UI thread; `taskbar.surfaceClosed(old_window, s.id)` → `SetParent(s.hwnd, to.hwnd)` → `s.tab = to; s.window = to.window` → `applyDpi()` if the DPI differs → `bumpPresentTarget()` → `taskbar.surfaceRestored(new_window, s.id)` → `hooks.surfaceMoved`).
- Modify `src/apprt/win32/Tab.zig`: `MoveError`, `moveWithin(self, s, dst, dir)`, `adoptNextTo(self, s, dst, dir)`, `createAdopting(window, s) !*Tab`, private `releaseMoved(self, s) bool`, and a pure seam `fn moveOrder(kind: enum { same_tab, other_tab, emptied_tab, emptied_window }) []const Step` used by the code and the test.
- Modify `src/apprt/win32/hooks.zig`: `pub fn surfaceMoved(s: *Surface, from: *Tab, to: *Tab) void` (overlay re-own when windows differ, composition sync, tmux labels refresh of both tab ids, decor, `secure_input.tabLayoutChanged`).
- Modify `src/apprt/win32/overlay.zig`: `pub fn surfaceReparented(s: *Surface, from: *Window, to: *Window) void` (re-own popups whose `.surface == s`).
- Modify `src/apprt/win32/composition.zig`: `pub fn surfaceMoved(s: *Surface, from: *Window, to: *Window) void` (`decide(to)` + `syncSurface(s)`).
- Modify `src/apprt/win32/tmux/labels.zig`: refresh helper for two tab ids (only if the existing API has none).
- Read-audit only (no edit; record the grep result in the commit message): `inspector/Inspector.zig`, `SearchBar.zig`, `CommandPalette.zig`, `title_edit.zig`, `taskbar.zig`, `badges.zig`, `key_state.zig`, `scrollbar.zig` — grep `\.window\b` / `\.tab\b` on `Surface`. A subsystem that caches `s.window`/`s.tab` and is not covered by `hooks.surfaceMoved` is fixed **through** `hooks.surfaceMoved` only; if that needs an edit in an audited file, stop and report (the lead re-plans).

Steps (the move, exact order — design-drag T3):
- [ ] **1. Failing tests.**
- [ ] **2.** `adoptNextTo`: (1) `split_drag.insertInto(target.tree, s, dst, dir)` → `new_target` (OOM → nothing changed); (2) `undo_actions.forgetSurface(app, s)` + `forgetTab` for source and target (R-M8-30); `title_edit.cancelForSurface(old_window, s)`; close a palette/search bar anchored to `s` only if the window changes; (3) `s.reparent(target)`; (4) source `releaseMoved(s)`: focus via `focusAfterRemove`, `remove`; if empty, set `tree = .empty` **before** `window.removeTab(source)` (so `Tab.destroy` neither stops the moved surface's threads nor destroys its HWND); else `replaceTree`, `applyOcclusion`, `hooks.tabLayoutChanged(source)`; (5) `target.replaceTree(new_target)`, `target.focused = s`, `applyOcclusion`, `hooks.tabLayoutChanged(target)`; (6) source window without tabs → `requestClose(true)` (like `strip_input.transfer`); `target.window.activate()`, `target.focus()`.
- [ ] **3.** `moveWithin`: `split_drag.moveWithin` + `forgetTab(self)` + `replaceTree` + focus; no reparent. `createAdopting`: like `Tab.create` but the tree is `Tree.init(alloc, s)` of the existing surface.
- [ ] **4. Verify:** `LOCK ZIG build test -j6 -Dtest-filter="win32 tab" -Dtest-filter="win32 hooks" -Dtest-filter="win32 overlay"`; `LOCK ZIG build -j6`.
- [ ] **5. Commit** `feat(win32): move a pane between tabs and windows without restarting it`

**Unit tests:**
- `win32 tab: move order reparents before remove and empties before removeTab` — `moveOrder` for the four kinds: reparent before remove, `tree = .empty` before `removeTab`, window close last; same-tab has no reparent.
- `win32 hooks: surfaceMoved reaches every per-surface subsystem` — comptime list check (the hook's call list names overlay, composition, tmux labels, decor, secure_input).

**E2e:** covered by Task 14's `split-drag` (pids and hwnds stay, echo oracle in the moved pane).

**Done:** filters green; audit result in the commit message.

### Task 6: Security fixes — Git prompt `$PWD`, invisible characters in links, C1 in dropped paths

**Review:** full (security). **Size:** 4 h.

**Depends:** —

**Files:**
- Modify `src/shell-integration/bash/ghostty.bash`: in `__ghostty_precmd`, inside `if test "$_ghostty_executing" != "0"`, before the `133;P` wrapping, under `[[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]`: `[[ "$PS1" == *'$TITLEPREFIX:$PWD'* ]] && PS1=${PS1//'$TITLEPREFIX:$PWD'/'$TITLEPREFIX:${PWD//[[:cntrl:]]/}'}` with the comment of design-sec SEC-1 (pattern match only, no fork).
- Modify `test/windows/shell-marks/run.ps1`: cases `bash-git-title-inject`, `bash-git-title-plain`.
- Modify `src/apprt/win32/dialogs.zig`: `DeceptiveSet`, `isDeceptive`, `escapeDeceptive` (R-M8-38) next to `previewText`.
- Modify `src/apprt/win32/link_policy.zig`: `hasBidiControl` → `pub fn hasInvisible(s) bool` (UTF-8 decode + `isDeceptive(.link)`; invalid UTF-8 is not deceptive).
- Modify `src/apprt/win32/shell_open.zig`: `hasForbidden` uses `hasInvisible` (keeps C0/DEL/`"`); check-table rows.
- Modify `src/apprt/win32/link.zig`: extract `labelText(alloc, url)` from `hover`; `hover` and `postedDialog` (`shown`, `shown_scheme`) use `escapeDeceptive(.link, …)`.
- Modify `src/apprt/win32/drop.zig`: `pathIsSafe` also refuses `0xC2` followed by `0x80..0x9F`; doc comment.
- Create `test/windows/e2e/title-inject.ps1` (`# e2e: milestone=M8 timeout=90 order=1270`).
- Modify `test/windows/e2e/link-hover-open.ps1` (U+202E case), `test/windows/e2e/drop-files.ps1` (U+009B path case).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 dialogs" -Dtest-filter="win32 link" -Dtest-filter="win32 shell open" -Dtest-filter="win32 drop"` and `PS test/windows/shell-marks/run.ps1 -Only bash-git-title-inject,bash-git-title-plain` (headless, allowed) → FAIL → **3. Implement** → **4. Verify** (same commands green; existing `shell_open` rows pass; `LOCK ZIG build -j6`; scripts parse) → **5. Commit** `fix(win32): Git prompt title cannot inject escapes; invisible characters in links and C1 in dropped paths are refused`.

**Unit / headless tests:**
- `bash-git-title-inject` (shell-marks): sandbox `~/.bashrc` sets Git's exact default PS1 literal and `TITLEPREFIX=MINGW64`, `mkdir`+`cd` into `$'inj\a\e]52;c;SGVsbG8=\a'` → raw ConPTY output has no `ESC]52;`; the `ESC]0;MINGW64:` title runs to its own BEL; OSC 7 has no control bytes.
- `bash-git-title-plain`: a normal directory → title `MINGW64:/…/plain` unchanged.
- `win32 dialogs: deceptive codepoints` — every listed codepoint true; `Ж`, `😀`, `é` false; U+200D true for `.link`, false for `.paste`.
- `win32 dialogs: escapeDeceptive shows hidden characters` — `"a\u{202E}b\u{200B}c\u{85}\n"` → `"a<U+202E>b<U+200B>c<U+0085>\u{240A}"`.
- `win32 link policy: invisible characters` — `hasInvisible` true for `"x\u{200B}"`, `"\u{FEFF}x"`, `"\u{2060}"`, `"a\u{200D}b"`; false for `"Привет/😀.txt"`; invalid UTF-8 no crash.
- `win32 shell open:` check table + `check(.osc8, "C:\\a\\x.exe\u{200B}", .refuse, null)`, `check(.unknown, "file:///C:/a%E2%80%8Bb.txt", .refuse, null)`, `check(.osc8, "foo:x\u{FEFF}", .refuse, null)`.
- `win32 link: label escapes bidi` — `labelText("https://a.b/\u{202E}gpj.exe")` → `"https://a.b/<U+202E>gpj.exe"`.
- `win32 drop: unsafe paths are refused` (extended) — `"C:\\a\u{9B}b"`, `"C:\\a\u{85}"` refused; `"C:\\Ж\\é"`, `"C:\\a\u{A0}b"` accepted.

**E2e (written, not run):**
- `title-inject.ps1`: Git Bash surface, `cd` into a crafted directory under `%TEMP%\ghostty-e2e` (created by the scenario with `mkdir $'…'` in bash); `GetClipboardSequenceNumber` unchanged; the window title has no control pictures; clipboard saved/restored.
- `link-hover-open.ps1` (+case): an OSC 8 link whose URI holds U+202E; hover → the label (test-ops state) shows `<U+202E>`; Ctrl+click → `shell_open` records `refuse`.
- `drop-files.ps1` (+case): a synthetic HDROP with a U+009B path → nothing pasted, the refusal log line.

**Done:** all green; no visible change of a normal Git Bash title.

### Task 7: Clipboard confirmation prompt — image preview, parts summary, remember switch, macOS labels

**Review:** full (security UI) + pixel evidence in Task 24. **Size:** 6 h.

**Depends:** 3 (`clipboard_image.decode/preview`), 6 (`dialogs.escapeDeceptive`).

**Files:**
- Modify `pkg/win32/d2d1.zig`: type `ID2D1RenderTarget` slots `CreateBitmap` and `DrawBitmap`; `ID2D1Bitmap` (Release); `D2D1_BITMAP_PROPERTIES`.
- Modify `src/apprt/win32/dialog/Dialog.zig`: `Spec.image: ?Image = null` (`{ width, height, bgra }`, premultiplied, already downscaled) drawn between body and list (`CreateBitmap(B8G8R8A8_UNORM, PREMULTIPLIED)` once per render target, `DrawBitmap(dest, 1, LINEAR)`, centred, 1 px card stroke, re-created on DPI change); `Spec.check: ?Check = null` (`{ label: []const u16, state: *bool }`, a real `BUTTON` `BS_AUTOCHECKBOX | WS_TABSTOP` painted on `NM_CUSTOMDRAW`: 20 DIP rounded box, accent fill + Segoe Fluent Icons `E73E` when checked, body-font label, focus rect, `CDRF_SKIPDEFAULT`; Space toggles; read into `*state` when the dialog closes). If `Dialog.zig` passes ~1400 lines, put image/check painting in a new `src/apprt/win32/dialog/extras.zig` (create; referenced from `Dialog.zig`'s test block).
- Modify `src/apprt/win32/dialog/layout.zig`: `Input.image_h`, `Input.check_h`; `Plan.image`, `Plan.check`; image box = content width × `min(px(200), natural)` aspect-fit (GTK 200 px clamp); check row above the footer.
- Modify `src/apprt/win32/dialog/keys.zig`: Tab order list → check → buttons.
- Modify `src/apprt/win32/dialogs.zig`: `ClipboardKind = enum { paste, read, write }`, `ClipboardPart = struct { mime: []const u8, data: []const u8 }`, `ClipboardAnswer = struct { allow: bool, remember: bool }`, `pub fn confirmClipboard(owner: ?HWND, kind: ClipboardKind, parts: []const ClipboardPart, can_remember: bool) ClipboardAnswer` — titles "Clipboard Read"/"Clipboard Write"/"Confirm Paste"; body = macOS text (`macos/Sources/Ghostty/Ghostty.ClipboardConfirmationRequest.swift:30-44`); image = first `image/*` part that decodes, via `preview` (max 548×200 DIP at the owner DPI); list = one line per part "`<mime>` — `<size>`" (mime via `previewText`, ≤ 64 chars), blank line, then the first text part (`text/plain`, else valid UTF-8) through `escapeDeceptive(.paste, 512)`; buttons Deny/Allow (paste: Cancel/Paste), Deny/Cancel default (R-M8-17); the checkbox only when `can_remember`; **never the program's name**; fallback (dialog cannot be built) = the existing message box with `remember = false`. `confirm` keeps its signature (`link.zig`).
- Step 1 checks that the manifest enables comctl32 v6 for `NM_CUSTOMDRAW`; if not, fallback = owner-draw toggle button (Narrator says "button"; note in the commit).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 dialog"` → FAIL → **3. Implement** → **4. Verify** (filter green; `LOCK ZIG build -j6`; the existing `win32 dialogs:` tests pass) → **5. Commit** `feat(win32): clipboard prompt with image preview, parts summary and remember switch`.

**Unit tests:**
- `win32 dialog layout: image is clamped and fitted` — 800×6000 at 96/144 dpi → height `px(200)`, width ≤ content, aspect kept; 10×10 → natural size, centred.
- `win32 dialog layout: check row sits above the footer` — with/without check: no overlap, height grows by the row.
- `win32 dialogs: clipboard prompt text` — parts `{text/plain "rm -rf\n", image/png <bytes>}` → `text/plain — 7 bytes`, `image/png — 1.2 KB`, then `rm -rf␊`; Deny/Allow for read/write, Cancel/Paste for paste; a 300-byte MIME is cut; no `name` in any string (the API has no name parameter).
- `win32 dialogs: unpreviewable image` — corrupt PNG → no image, `image/png — 3 bytes (no preview)`.
- `win32 dialogs: hidden characters in the preview` — `"a\u{202E}b"` text part → `a<U+202E>b`.

**E2e:** dialog evidence in Task 10's `kitty-clipboard-read` (image box not uniform card colour); `paste-confirm.ps1` regression (Enter = cancel) in Task 24.

**Done:** filters green; `confirm` callers unchanged.

### Task 8: Grab handle on screen — overlay, hover, cursor, press routing

**Review:** light. **Size:** 3.5 h.

**Depends:** 2, 5 (`Surface.zig`, `hooks.zig` after Task 5).

**Files:**
- Create `src/apprt/win32/grab_overlay.zig`: `State = { popup: ?*overlay.Popup = null, shown: grab_handle.Ellipsis = .hidden, opacity: f32 = 0, on_handle: bool = false, in_band: bool = false }`; `pointerMoved(s, x, y)`, `pointerLeft(s)`, `hitHandle(s, x, y) bool`, `refresh(s)`; painter: three 2 DIP dots 3 DIP apart, centred, 3 DIP above the handle's centre line, colour = window palette `text` at alpha 0.3 (`dim`) / 0.8 (`bright`), fade 150 ms on `timers.surface.grab_fade`; no background (macOS); one overlay `label` popup per pane (`click_through = true`, `place` = surface top centre), created on first reveal, hidden after the fade, destroyed in `surfaceDestroying`; z-order above badges. `test {}` references its own tests.
- Create `src/apprt/win32/split_drag_input.zig` (stub): `pub fn press(s: *Surface, x: i32, y: i32) void {}` and `pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT { return null; }` with doc comments (filled by Task 11).
- Modify `src/apprt/win32/mouse.zig`: `WM_MOUSEMOVE` → `grab_overlay.pointerMoved` before `sendPos` (core still gets the move); `WM_LBUTTONDOWN` after the divider check → `if (grab_overlay.hitHandle(...)) { split_drag_input.press(surface, x, y); return 0; }` (left button only); `WM_SETCURSOR` over the handle → `IDC_SIZEALL` (R-M8-29); `WM_MOUSELEAVE` → `pointerLeft`; `mouse_state.hidden` → `pointer_visible = false`.
- Modify `src/apprt/win32/Surface.zig`: `grab: grab_overlay.State = .{}` field; the fade `WM_TIMER` case.
- Modify `src/apprt/win32/hooks.zig`: `grab_overlay.refresh` on config change, layout change, tab shown, focus, fullscreen and cursor-hidden changes; `surfaceDestroying` destroys the popup.
- Modify `src/apprt/win32/Window.zig`: **one line**: `split_drag_input.handle` in the hook list before `strip_input_mod.handle` (`Window.zig:63-70`).

Steps:
- [ ] **1. Failing test** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 grab overlay"` → FAIL → **3. Implement** (hit area only while `grab_handle.active(mode, window.placement.fullscreen, tree_split = >1 visible leaf, quick = window.kind == .quick)`) → **4. Verify** (filter + `-Dtest-filter="win32 grab handle"`; `LOCK ZIG build -j6`) → **5. Commit** `feat(win32): split grab handle (macOS look) with hover reveal`.

**Unit tests:** `win32 grab overlay: dots geometry at 96/144/192 dpi` (pure painter rect math); `win32 grab overlay: opacity follows the fade` (pure step function over `grab_handle.fade`).

**E2e:** part of Task 14's `split-drag` (hover → handle label in IPC state; `drag-handle = never` → none; a press in the rect does not reach the shell).

**Done:** filters green; a click outside the 80×12 DIP rect reaches the terminal as before (the press path is unchanged elsewhere).

### Task 9: ConPTY probes — OSC 5522 and mode 2033 through inbox and bundled consoles

**Review:** light. **Size:** 4 h.

**Depends:** —

**Files:**
- Create `test/windows/conpty-probe/cases/headless-5522.sh`: between markers emit `\e[?5522h`, `\e[?5522$p`, a write transaction (`type=write`, two `wdata` chunks `text/plain` and `text/html`, the empty commit `wdata`), a read `type=read;<b64 "text/plain .">`, then `read -rs -t 3 -d '\'` of the reply and hex it.
- Create `test/windows/conpty-probe/cases/probe-2033.sh`: `printf '\e[?2033h'`, `printf '\e[?998n'`, `printf '\e[?2033$p'`, `read -rs -t 3 -d n r; printf 'GOT:%s\n' "$(printf %s "$r" | od -An -tx1)"`.
- Modify `test/windows/conpty-probe/headless.ps1`: `-Kitty5522` (answers a 5522 read with a fixed OK/listing/DATA/DONE reply, DECRQM `?5522` with `\e[?5522;1$y`; records what arrived; `-ReplyBytes N` default 4096, runs at 1 MiB and 8 MiB timing the input path and sampling OpenConsole/conhost private bytes) and `-Visibility` (answers `?2033h`/`?998n` with `\e[?999;1n`, DECRQM `?2033` with `\e[?2033;2$y`; records whether each request arrived).
- Modify `test/windows/conpty-probe/RESULT.md`: sections "OSC 5522 through ConPTY (M8)" and "Mode 2033 through ConPTY (M8)": tables inbox 0/8 and bundled 0/8 × (DECSET arrives, OSC/DSR arrives byte-identical, reply read by Git Bash, reply read by a native VT reader), times and private bytes for 1/8 MiB replies, Windows build number.
- Modify `test/windows/lib/FakeExe.psm1`: `vtreader` gains `FAKE_QUERY_FILE` and `FAKE_UNTIL` (fixed interface).

Steps:
- [ ] **1.** Write the cases; extend the host and FakeExe.
- [ ] **2. Run (headless, allowed):** `PS test/windows/conpty-probe/headless.ps1 -Kitty5522 -Repeat 2` and `-Visibility -Repeat 2`, each against the inbox console and `-DllDir vendor/conpty/x64`, flags 0 and 8; native reader via `New-FakeExe -Kind vtreader`. Only processes the probe starts; killed by PID.
- [ ] **3. Record** the tables and the verdicts: (a) inbox drops 5522 / 2033 → R-M8-16 applies (Task 22 doc line; scenarios use a native program); (b) an 8 MiB reply > 5 s or OpenConsole + > 500 MB → R-M8-15 cap in Task 10; (c) the console answers `?998n` itself → note it.
- [ ] **4. Verify** both scripts parse; `FakeExe.psm1` imports. **5. Commit** `test(windows): OSC 5522 and mode 2033 through ConPTY, measured`.

**Unit tests:** none (probe). **E2e:** none of its own.

**Done:** RESULT.md has both tables filled and the three verdicts written as one line each; the ledger gets the verdicts for Tasks 10, 12 and 22.

### Task 10: Kitty clipboard read / write / paste-event flow

**Review:** full (security prompt, ownership). **Size:** 6 h.

**Depends:** 4, 7, 9 (FakeExe + the R-M8-15 verdict).

**Files:**
- Modify `src/apprt/win32/clipboard.zig`:
  - `Pending` gains `gathered: ?Gathered` (owned `[]terminal.clipboard.Content` + arena for a kitty read's data and listing; freed by `process` and `cancelAll`).
  - `request`: `.kitty_write`, `.kitty_read`, `.list`: `!supports(t)` → `.unsupported` before any prompt (embedded `:732` rule); else queue, `.started`.
  - `process`: `.list` → `completeClipboardRequest(req, .{ .available = list(...) })` (never prompts); `.kitty_read` → `readMime` per `kitty.mimes` (text aliases → `text/plain`), listing when `kitty.list`, R-M8-15 cap if Task 9 said so; `complete(confirmed=false)`; `UnauthorizedPaste` → `dialogs.confirmClipboard(.read, gathered, pw.len > 0)`; Allow → `complete(gathered, confirmed=true, remember)` with **the same bytes** (no re-read); Deny/close → `denyClipboardRequest`; a failed MIME is "not available". `.kitty_write` → `complete(.{})`; `UnauthorizedPaste` → prompt with `kitty.contents`; Allow → `complete(.{ .confirmed = true, .remember = r })`; Deny → deny.
  - `KittyFlow` struct (complete/confirm/deny), like `RequestFlow`, so tests drive it with fakes.
  - The OSC 52 / paste prompts switch to `dialogs.confirmClipboard` (kind `.paste`/`.read`/`.write`, one text part); the private `previewOf`/`isDeceptive` are removed in favour of `dialogs.escapeDeceptive(.paste)` (design-sec SEC-2 step 5).
  - Doc comment on `Surface.zig:538-557` is **not** edited (Surface.zig is outside this task).
- Create `test/windows/e2e/kitty-clipboard-write.ps1` (order 1250), `kitty-clipboard-read.ps1` (1251), `kitty-paste-event.ps1` (1252), all `# e2e: milestone=M8`.

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 clipboard"` → FAIL → **3. Implement** (every branch ends in exactly one of complete-consumed / deny; `active` cleared before completing) → **4. Verify** (filter green with the leak-checking allocator; `LOCK ZIG build -j6`; scenarios parse) → **5. Commit** `feat(win32): Kitty clipboard protocol (OSC 5522) reads, writes and paste events`.

**Unit tests** (fakes, no clipboard, no dialog):
- `win32 clipboard kitty: read allowed by policy completes once` — no prompt, 1 completion, gathered freed.
- `win32 clipboard kitty: read asks and serves what was shown` — `UnauthorizedPaste` → 1 prompt with the gathered parts → Allow+remember → second completion `confirmed=true, remember=true`, byte-identical contents; reader call count stays N.
- `win32 clipboard kitty: denied read answers EPERM` — Deny → `deny` once, no completion.
- `win32 clipboard kitty: write asks with committed contents` — prompt parts == `kitty.contents`; Allow → `confirmed=true`; remember offered iff pw non-empty.
- `win32 clipboard kitty: unsupported location before any prompt` — `request(.primary, kitty_write)` → `.unsupported`, nothing queued.
- `win32 clipboard kitty: list never prompts` — `.list` completes with `available` only.
- `win32 clipboard: pending request is denied when the surface closes` (extended) — queued `kitty_read` with gathered data, active `kitty_write`, queued `list` → deny order kept, gathered freed, no leak.
- `win32 clipboard kitty: surface gone behind the prompt` — `Answer.gone` → no completion, no double free.
- `win32 clipboard kitty: oversized representation is not available` — only if R-M8-15's cap is on.

**E2e (written, not run):**
- `kitty-clipboard-write.ps1`: `clipboard-write = allow`; native `vtreader` (bundled console under `auto`) writes `text/plain "gh-5522"`, `text/html "<b>gh</b>"`, `image/png` (2×2 literal) → reply `type=write:status=DONE`; snapshot: CF_UNICODETEXT `gh-5522`, "HTML Format" fragment `<b>gh</b>`, "PNG" identical, CF_DIBV5 2×2 (System.Drawing reads the same pixels). Case 2 `clipboard-write = ask`: a `GhosttyDialog` appears, Enter → `status=EPERM`, clipboard sequence number unchanged. Case 3: a 70 MiB write → `EFBIG`, no dialog.
- `kitty-clipboard-read.ps1`: `Set-ClipboardSnapshot` CF_UNICODETEXT `hello`, "HTML Format" `<i>hi</i>`, CF_DIB 16×16 red (no "PNG"); `clipboard-read = ask`; query `type=read;<b64 ". image/png text/html text/plain">`; dialog evidence saved, its image box is not uniform; Allow → listing `text/plain text/html image/png`, DATA `text/html` = `<i>hi</i>`, DATA `image/png` decodes to 16×16 red, DONE. Case 2 Deny → EPERM. Case 3 `clipboard-read = deny` → EPERM, no dialog. Case 4 `.`-only read → listing, no dialog. Case 5: 3840×2160 DIB → log `kitty read served … ms`, budget 300 ms ReleaseFast.
- `kitty-paste-event.ps1`: `vtreader` sends `\e[?5522h` and waits; clipboard = text + DIB; `Ctrl+Shift+V` → one `type=read:status=OK:…:pw=` packet listing `text/plain` and `image/png`, no bracketed-paste bytes, no dialog.

**Done:** filters green, leak-free; OSC 52 and Ctrl+V behave as in win.2 when mode 5522 is off.

### Task 11: Split drag session — capture, hit test across windows, ghost, zones, tab strip

**Review:** full (cross-window lifetime). **Size:** 5 h.

**Depends:** 8 (stub + hook line), 5 (move primitive).

**Files:**
- Modify `src/apprt/win32/split_drag_input.zig`: `Session = { machine, source: *Surface (re-validated by id on every event), capture: *Window, ghost: bool, zone_popup: ?*overlay.Popup, marker_window: ?u32, spring: ?{window, index} }`; `press`, `handle`, `hitAt(app, pt, src) split_drag.Hit`; pure seam `fn classify(in: struct { ours: bool, accepts: bool, in_strip: bool, leaf: ?usize }) HitKind`.
- Modify `src/apprt/win32/App.zig`: `split_drag: ?split_drag_input.Session = null`.
- Modify `src/apprt/win32/drag_ghost.zig`: image mode (`showImage(bgra, size)`, `moveTo`), chip fallback kept.
- Modify `src/apprt/win32/strip_input.zig`: export `pub fn showDropMarker(app, window_id, ?index)` (wraps `setMarker`) and `pub fn insertionIndexAt(window, x) usize` if `insertionIndex` is private.

Steps:
- [ ] **1. Failing tests.**
- [ ] **2. `press`:** build `Source` (tab split = > 1 visible leaf; window tab count), `Machine.begin(threshold = TabStrip.Metrics.forDpi(dpi).drag_threshold)`, `SetCapture(window.hwnd)` (the top-level window, never a pane or a tab container); keyboard focus to `window.hwnd` once past the threshold (Esc reaches the hook).
- [ ] **3. `handle`:** `WM_MOUSEMOVE` (needs `MK_LBUTTON`, else cancel) → `hitAt` → `feed(.move)`; `WM_LBUTTONUP` → `.release`; `VK_ESCAPE` → `.cancel`; `WM_CAPTURECHANGED` → `.cancel`; `WM_TIMER timers.window.split_drag_spring` → `.spring_fired`. Before every feed the source surface must be alive and in a tab, else cancel + clean up.
- [ ] **4. `hitAt`:** `WindowFromPoint` (our layered transparent popups are skipped), root = `GetAncestor(GA_ROOTOWNER)`; not ours → `outside`; tearing down, parked, minimized or `!QuickTerminal.acceptsTabDrop(kind)` → `blocked`; inside the strip (and `show_tabs`) → `strip{ slot, over }`; else the active tab's visible leaf under the point → `pane{ zone = zoneAt, rect }`; none → `blocked`.
- [ ] **5. Feedback:** ghost → `drag_ghost.showImage/moveTo`; zone → one label popup owned by the target window at `zoneRect` (screen px), `GetSysColor(COLOR_HIGHLIGHT)` at alpha 0.3 premultiplied, no border, re-owned when the target window changes, `NOACTIVATE | TRANSPARENT`; marker → `strip_input.showDropMarker`; spring → `SetTimer(capture.hwnd, split_drag_spring, 500)`; `select` → `windowById(...).selectTab(index)`.
- [ ] **6. Ghost image:** at the threshold, hide the handle dots, `BitBlt` the pane's screen rect into a 32 bpp DIB, `StretchBlt(HALFTONE)` to 20 %, alpha 255, `ghost_alpha` 0xD8; chip fallback per R-M8-31.
- [ ] **7. `done`:** clean up first (release capture, hide ghost, destroy zone popup, clear marker, kill spring timer); then `to_pane` same tab → `Tab.moveWithin`; other tab → `target_tab.adoptNextTo`; `new_tab` → `Tab.createAdopting(target_window, s)` + `ensureUnusedCapacity` + `insertTab(slot)` + Task 5 steps 2–6; `new_window` → `none` for now (Task 14); `none`/`cancelled` → refocus the source pane.
- [ ] **8. Verify:** `LOCK ZIG build test -j6 -Dtest-filter="win32 split drag" -Dtest-filter="win32 drag ghost"`; `LOCK ZIG build -j6`. **9. Commit** `feat(win32): drag a split onto panes, tabs and other windows`.

**Unit tests:** `win32 split drag input: hit resolution order` (`classify`: not ours → outside; not accepting → blocked; strip before panes; no leaf → blocked); `win32 drag ghost: snapshot size is 20 % with the 48x32 floor`; `win32 drag ghost: secure input forces the chip`.

**E2e:** Task 14's `split-drag`.

**Done:** filters green; `tab-drag` code paths untouched except the exported helpers.

### Task 12: Window-level visibility — hidden windows and the hidden quick terminal report "not visible"

**Review:** light. **Size:** 3.5 h.

**Depends:** — (Task 9's 2033 verdict only changes the scenario's pane config).

**Files:**
- Modify `src/apprt/win32/Window.zig`: `ScreenState = { visible, iconic, parked, cloaked = false, screen_off = false }`; `pub fn screenState(self) ScreenState` (`cloaked` from a live `DwmGetWindowAttribute(DWMWA_CLOAKED)`; a failed call = not cloaked); pure `pub fn windowOnScreen(s) bool`; `pub fn syncOcclusion(self)` (active tab gets `windowOnScreen()`, others false; idempotent; when any surface turned hidden → `app.scheduleMemoryRelease()` — the existing debounced Trim + HeapCompact, so generic's GPU release returns memory to the driver); field `screen_off: bool = false` (set by Task 16); `WM_SHOWWINDOW` → post `WM_GHOSTTY_SYNC_OCCLUSION` (the post sees the final `IsWindowVisible`), its handler runs `syncOcclusion`; `handleSize` minimized/restored → `syncOcclusion` (replaces `setMinimized`'s occlusion part); pure `showWindowNeedsSync(msg, wparam, lparam) bool`.
- Modify `src/apprt/win32/Tab.zig`: `applyOcclusion(shown)` keeps setting `s.minimized` but computes `on_screen` from `shown and leaf_visible and !tab.parked`; callers pass `shown = window.activeTab() == tab and windowOnScreen(window.screenState())`; the layout path (`Tab.zig:478-488`) uses the same expression; `onScreen(shown, leaf_visible, parked)`.
- Modify `src/apprt/win32/ipc/ops.zig`: `writeSurface` adds `"core_visible": s.core_surface.visible`.
- Modify `pkg/win32/dwmapi.zig`: `pub const DWMWA_CLOAKED: u32 = 14;` (absent today).
- Create `test/windows/e2e/visibility-hidden.ps1` (`# e2e: milestone=M8 timeout=150 order=1200`).
- No edit to `visibility.zig` or `QuickTerminal.zig` (`SW_HIDE`/`SW_SHOWNA` already produce `WM_SHOWWINDOW`).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 window" -Dtest-filter="win32 tab"` → FAIL → **3. Implement** → **4. Verify** (filters; `LOCK ZIG build -j6`; scenario parses) → **5. Commit** `feat(win32): hidden windows and the hidden quick terminal report not visible`.

**Unit tests:**
- `win32 window: hidden, minimized, parked, cloaked or screen-off windows show nothing` — `windowOnScreen` table (all clear → true; each bit → false).
- `win32 tab: only the active tab of an on-screen window renders` — rewrite of `win32 tab: a parked window or tab renders nothing` for the new `onScreen`.
- `win32 window: occlusion is synced after WM_SHOWWINDOW settles` — `showWindowNeedsSync` true for `WM_SHOWWINDOW` with any wparam, false otherwise.

**E2e `visibility-hidden.ps1`** (written, not run): Git Bash pane with mode 2033 logging (`printf '\e[?2033h'; while read -rsn9 -t 30 r; do printf '%q\n' "$r" >> $TMP/vis.log; done`; on the bundled console if Task 9 found an inbox drop):
1. start: `\E[?999;1n` logged; IPC `core_visible = true`;
2. `toggle_visibility` → within 1 s `core_visible = false`, `;2n`;
3. again → `;1n`, `core_visible = true`;
4. quick terminal shown then hidden, wait `animating = false` → its surface `core_visible = false`, its reader sees `;2n`;
5. `new_tab` → inactive tab's reader `;2n`; `goto_tab:1` → `;1n`;
6. minimize (IPC helper `ShowWindow(SW_MINIMIZE)`) → `;2n`, restore → `;1n`.
Pass/fail on the IPC field; `vis.log` checks reported as SKIP if the console drops 2033.

**Done:** filters green; inactive-tab and minimize behaviour unchanged (core dedups).

### Task 13: Selection clipboard (in-process) and middle click on Windows

**Review:** light. **Size:** 3.5 h.

**Depends:** 10.

**Files:**
- Create `src/apprt/win32/selection_store.zig`: `Store { arena, contents: []Content }`, `set(alloc, contents)` (deep copy, replaces), `get(mime) ?[]const u8` (text aliases → first text rep), `mimes(buf) []const []const u8`, `clear()`, `deinit()`.
- Modify `src/apprt/win32/App.zig`: `selection: selection_store.Store = .{}`; `deinit` frees it; `_ = @import("selection_store.zig");` in its test block.
- Modify `src/apprt/win32/clipboard.zig`: `supports` = `.standard` and `.selection` (`.primary` unsupported, R-M8-11); `setClipboard(.selection, …)` → `app.selection.set` (no Win32 clipboard, no toast, no secure markers); OSC 52 `s` write with `confirm` → same prompt, then the store; `process`: `paste`/`osc_52_read`/`kitty_read`/`list` with `t == .selection` read the store; `request(.paste = .selection)` with an empty store → `.unavailable` (binding falls through, R-M8-9).
- Create `test/windows/e2e/selection-paste.ps1` (order 1260), `test/windows/e2e/middle-click.ps1` (order 1261).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 selection store" -Dtest-filter="win32 clipboard"` → FAIL → **3. Implement** → **4. Verify** → **5. Commit** `feat(win32): Ghostty-only selection clipboard for copy-on-select primary and middle click`.

**Unit tests:**
- `win32 selection store: set replaces and owns` — caller buffers freed after `set`, `get` valid; second `set` replaces; leak-free.
- `win32 selection store: text aliases and listing` — `get("UTF8_STRING")` → text rep; `mimes` == stored order.
- `win32 clipboard: selection is supported, primary is not` — `supports(.standard)`, `supports(.selection)`, `!supports(.primary)` (replaces design-vis V8's "standard only" test).
- `win32 clipboard: empty selection paste is unavailable` — `request(.paste = .selection)` on an empty store → `.unavailable`.

**E2e (written, not run):**
- `selection-paste.ps1`: `copy-on-select = primary`; double-click a word printed by `echo`; system clipboard sequence number unchanged; type `echo `, middle-click, Enter with output redirected to a sandbox file → file holds the word. Case 2 `copy-on-select = none` → middle click pastes nothing.
- `middle-click.ps1`: clipboard = `mc-paste`; `middle-click-action = clipboard-paste` → `mc-paste` echoed by `cat`; `primary-paste` with default `copy-on-select` → nothing; `ignore` → nothing; with `printf '\e[?1000h'` the app receives the middle button and nothing is pasted; middle click on a tab chip still closes it.

**Done:** filters green; default config: middle click does nothing (as win.2).

### Task 14: Drag out to a new window, drag test state, `split-drag` scenario

**Review:** light. **Size:** 4 h.

**Depends:** 11.

**Files:**
- Modify `src/apprt/win32/Window.zig`: `createForTearOff(app, origin, source, content: ?geom.Size)` (null = `source.contentRect()` as today; callers updated in the same file).
- Modify `src/apprt/win32/split_drag_input.zig`: outcome `new_window` (only if `outsideOutcome` allowed it): content size = the pane's client size; `origin = split_drag.newWindowOrigin(pointer, grab, pane_offset, src_dpi, dst_dpi)`; `createForTearOff(…, pane_size)` → `Tab.createAdopting(new, s)` → `tabs.appendAssumeCapacity` → Task 5 steps 2–6 → `selectTabFocus(0, false)`, `showPlain()`, `activate()`; `pub fn testState(app, jw)`.
- Modify `src/apprt/win32/grab_overlay.zig`: `pub fn testState(app, jw)` (shown panes, opacity).
- Modify `src/apprt/win32/hooks.zig`: `testState` adds the `"m8"` object (fixed interface).
- Create `test/windows/e2e/split-drag.ps1` (`# e2e: milestone=M8 timeout=240 order=1280`, interactive, `MouseInput.psm1` like `tab-drag.ps1`).

Steps:
- [ ] **1. Failing test** (pure part already in Task 2; here a seam `win32 split drag input: new window only when allowed`) → **2. Implement** → **3. Verify** `LOCK ZIG build test -j6 -Dtest-filter="win32 split drag" -Dtest-filter="win32 window"`; `LOCK ZIG build -j6`; scenario parses → **4. Commit** `feat(win32): drag a split out to a new window; split-drag scenario`.

**E2e `split-drag.ps1`** (written, not run; cmd.exe config, `confirm-close-surface = false`, `window-show-tab-bar = always`):
1. Window A, tab T0 `new_split:right` → P0 | P1; record cmd.exe pids and pane hwnds.
2. Hover P1's top band → IPC `m8.grab` shows P1 `bright` on the rect. `drag-handle = never` (reload) → no entry; a press there reaches the terminal (echo oracle).
3. Drag P1's handle onto P0's top quarter: a `GhosttyDragGhost` visible, `m8.split_drag.zone` = P0's top half; after release vertical tree with P1 on top; hwnds and pids unchanged; echo oracle in P1.
4. Drag P1 250 px below A → new window B with one tab holding P1's hwnd; A keeps P0; pids unchanged; B's content size = P1's old size (± 2 px, same DPI).
5. Drag B's only pane onto A's P0 right zone → B closes, A is P0 | P1.
6. New tab T1 in A; drag P1 onto the strip right of T1 → tab T2 with P1; T0 keeps P0.
7. Spring-load: drag P0 (T0 single-pane, A has 3 tabs), hover T2's chip 700 ms → T2 active; drop on P1's left zone → T0 gone, T2 = P0 | P1.
8. Esc during a drag over a pane → nothing changes, no ghost, no zone popup.
9. Self drop → nothing changes.
10. Quick terminal: no handle; dropping a pane over it → `blocked`, nothing changes.
Evidence: `Save-WindowShot` of the zone highlight and the ghost.

**Done:** filters green; scenario parses; `tab-drag.ps1` unchanged.

### Task 15: D3D11 — shrink the DXGI swap chain of a hidden surface

**Review:** full (renderer). **Size:** 4 h.

**Depends:** 1 (pacer state in `SwapChain.zig`), 12 (`core_visible`, `syncOcclusion` trim).

**Files:**
- Modify `src/renderer/d3d11/SwapChain.zig`: `pub fn shrink(self) Error!void` (caller holds the context lock; `clearState` + `flush`; `ResizeBuffers(0, 1, 1, .UNKNOWN, flags)`; update `width/height`; reset the pacer as after a resize, keeping Task 1's resync semantics).
- Modify `src/renderer/D3D11.zig`: `pub const shrink_hidden_chains = true;` (R-M8-21 switch); `pub fn surfaceHidden(self)` (render thread, from generic `setVisible(false)`; lock context; `if shrink_hidden_chains and shrinkOnHide(has_chain, IsWindowVisible(hwnd) != 0, mode)` → `sc.shrink() catch log once`; release `retired_chain`); pure `pub fn shrinkOnHide(has_chain, window_visible, mode) bool`; `presents: std.atomic.Value(u64)` incremented in `presentSucceeded`; `pub fn chainPx(self) [2]u32` for tests; the `PresentTarget` doc block about minimized windows updated.
- Modify `src/renderer/generic.zig`: in `setVisible`, inside `if (!visible)` after `releaseGpuResources()`: `if (comptime @hasDecl(GraphicsAPI, "surfaceHidden")) self.api.surfaceHidden();` (the only core line).
- Modify `src/apprt/win32/ipc/ops.zig`: `writeSurface` adds `"presents"` and `"chain_px"`.

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="d3d11 "` → FAIL → **3. Implement** (ResizeBuffers, not drop, so a composition chain stays attached to its DComp visual) → **4. Verify** (filter green; `LOCK ZIG build -j6`) → **5. Commit** `feat(d3d11): hidden tabs shrink their swap chain to 1x1`.

**Unit tests:**
- `d3d11 swapchain: shrink keeps creation flags and the next copy regrows it` — WARP + hidden `TestWindow`: 64×32 → shrink → desc 1×1, same Flags/BufferCount/Format; `copyToBackbuffer` 64×32 → desc 64×32, readback red, `present` ok.
- `d3d11 swapchain: shrink of a composition chain` — same with `.composition`.
- `d3d11: shrink on hide only for a hidden window with a chain` — `shrinkOnHide` table (no chain → false; window visible (minimized/occluded) → false; hidden → true, both modes).
- `d3d11: surfaceHidden then draw regrows the chain` — headless draw harness + `TestWindow`: draw, `surfaceHidden`, 1×1, draw, back to target size, `presents` +2.
- `d3d11 pacer:` tests from Task 1 stay green after the shrink reset.

**E2e:** Task 20's `hidden-render` (`chain_px = [1,1]` for an inactive tab; minimized keeps its size); gate measured in Task 24 B2.

**Done:** filters green; a hidden tab's chain is 1×1 in the IPC state (verified in the batch).

### Task 16: Lock screen, display off, remote disconnect, virtual desktops

**Review:** light. **Size:** 4 h.

**Depends:** 12.

**Files:**
- Create `src/apprt/win32/screen_state.zig`: `Screen = { locked, display_off, disconnected }`, `off(s)`, `onSession(s, wparam)`, `onDisplayState(s, data)` (0 off, 1 on, 2 dimmed = on), `isCloakEvent(event, id_object, id_child) ?bool`.
- Modify `src/apprt/win32/App.zig`: after `createMessageWindow`: `WTSRegisterSessionNotification(msg_hwnd, NOTIFY_FOR_THIS_SESSION)`, `RegisterPowerSettingNotification(msg_hwnd, &GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_WINDOW_HANDLE)`, `SetWinEventHook(EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED, null, cb, GetCurrentProcessId(), 0, WINEVENT_OUTOFCONTEXT)`; unregister in `deinit`; message-window cases `WM_WTSSESSION_CHANGE`, `WM_POWERBROADCAST/PBT_POWERSETTINGCHANGE`; `screen: screen_state.Screen`; `syncAllOcclusion()` sets `window.screen_off = off(screen)` on every window and calls `syncOcclusion`; cloak callback (`isCloakEvent`) finds the window by hwnd: uncloak → `syncOcclusion` at once; cloak → add the hwnd to `cloak_pending` and `SetTimer(msg_hwnd, timers.msg_window.cloak_debounce, 250)`; the timer syncs every pending window that still exists (`screenState` reads the live cloak bit, so a transient Alt+Tab/Task View cloak that ended is a no-op). **No `Window.zig` or `dwmapi.zig` edit.** Fallback if the message-only window gets no session/power notifications: register on the first normal window and re-register when it closes; log `screen notifications registered on=<msg|window>`. One info line per transition `screen state locked=… display_off=… disconnected=…`. `_ = @import("screen_state.zig");` in App's test block.
- Modify `pkg/win32/user32.zig`: `RegisterPowerSettingNotification`, `UnregisterPowerSettingNotification`, `SetWinEventHook`, `UnhookWinEvent`, `WM_POWERBROADCAST = 0x0218`, `PBT_POWERSETTINGCHANGE = 0x8013`, `POWERBROADCAST_SETTING`, `EVENT_OBJECT_CLOAKED = 0x8017`, `EVENT_OBJECT_UNCLOAKED = 0x8018`, `WINEVENT_OUTOFCONTEXT`, `OBJID_WINDOW`, `CHILDID_SELF`, `WM_WTSSESSION_CHANGE = 0x02B1`.
- Create `pkg/win32/wtsapi32.zig` (`WTSRegisterSessionNotification`, `WTSUnRegisterSessionNotification`, `NOTIFY_FOR_THIS_SESSION`, `WTS_CONSOLE_CONNECT/DISCONNECT`, `WTS_REMOTE_CONNECT/DISCONNECT`, `WTS_SESSION_LOCK/UNLOCK`).
- Modify `pkg/win32/main.zig` (export `wtsapi32`), `pkg/win32/build.zig` (link `wtsapi32`), `src/build/SharedDeps.zig` (link `wtsapi32` next to the other system libs).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 screen"` → FAIL → **3.** bindings + link → **4.** App wiring → **5. Verify** (filter; `LOCK ZIG build -j6`; the exe imports `WTSAPI32.dll` — `dumpbin /imports` or `llvm-objdump` if present, else skip) → **6. Commit** `feat(win32): lock screen, display off and other virtual desktops pause rendering`.

**Unit tests** (`screen_state.zig`): `win32 screen: lock and unlock`; `win32 screen: remote disconnect then connect`; `win32 screen: console disconnect keeps locked` (lock + console disconnect + connect → locked until unlock); `win32 screen: display off, dimmed counts as on`; `win32 screen: cloak events of windows only` (`OBJID_WINDOW`/`CHILDID_SELF` → bool; others → null).

**E2e:** not automatable (lock/display/virtual desktop); owner manual checks in Task 24 § Owner checks.

**Done:** filters green; no behaviour change while the session is unlocked and the display on.

### Task 17: Flash-free reshow — the old tab stays on top until the new one presented

**Review:** full (renderer ↔ apprt handshake). **Size:** 5 h.

**Depends:** 15.

**Files:**
- Modify `src/renderer/D3D11.zig`: `PresentTarget.presented: ?Notify` (post-only, like `hand_off`), called after the first successful present following a shrink or a chain (re)creation; `pub fn chainShrunk(self) bool` (read under the context lock).
- Modify `src/apprt/win32/Surface.zig`: provide the callback: post `WM_GHOSTTY_PRESENTED` (wparam = surface id) to the top-level window.
- Modify `src/apprt/win32/Window.zig`: `RaiseGate = { old: ?*Tab, waiting: std.bit_set.IntegerBitSet(32), deadline_ms }` with pure `presented(i) bool`, `expired(now_ms) bool`; `raise_cap_ms = 100`; `selectTab`: when the new tab has a shrunk leaf, put it **under** the old (the `waitUnderOld` trick), show it, tell core visible, keep the old visible, arm the gate + `timers.window.raise_gate` (16 ms); input focus moves at once; `WM_GHOSTTY_PRESENTED` → `gate.presented(i)`; all arrived or expired → `raiseAbove` new, hide old (`setVisible(false)` occludes it), clear the gate; a second `selectTab` while gated finishes the pending one first; the first-show-over-glass wait is folded into the gate.
- Modify `src/apprt/win32/Tab.zig`: helper returning the on-screen leaf indices that need a first present.

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 window" -Dtest-filter="d3d11 "` → FAIL → **3. Implement** → **4. Verify** → **5. Commit** `feat(win32): tab switch keeps the old tab on top until the new one presented`.

**Unit tests:** `win32 window: raise gate opens after every leaf presented`; `win32 window: raise gate opens at the cap`; `win32 window: a second switch flushes the first`; `d3d11: presented notify fires once after a shrink` (headless harness).

**E2e:** in Task 20's `hidden-render` (20 switches with a capture each: no frame that is neither tab's content); `new-tab-flash.ps1` and `new-tab-white-flash.ps1` regressions in Task 24.

**Done:** filters green; a switch to a never-shrunk tab takes the old path (no gate).

### Task 18: `TERMINUS_SUBLIME=1` for Windows children (Claude Code symbols)

**Review:** light. **Size:** 1.5 h.

**Depends:** —

**Files:**
- Modify `src/termio/Exec.zig`: `fn windowsUnicodeHint(env: *std.process.Environ.Map) !void` (TERM == `xterm-ghostty` and `TERMINUS_SUBLIME` absent → put `"1"`), called inside `if (comptime is_windows)` right after the TERM block (~l.972, outside the `env_override TERM == null` branch); doc comment with the consumer list (is-unicode-supported: Claude Code, figures, log-symbols, ora, listr2, @inquirer/figures, @clack/prompts) and the opt-out (R-M8-3).
- Modify `test/windows/e2e/term-terminfo.ps1`: Git Bash / pwsh / cmd print `TERMINUS_SUBLIME` → `1`; with `env = TERM=xterm-256color` → absent; with `env = TERMINUS_SUBLIME=yes` → `yes`.

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="windows unicode hint" -Dtest-filter="Exec: w"` → FAIL → **3. Implement** → **4. Verify** → **5. Commit** `fix(termio): Windows children get TERMINUS_SUBLIME=1 so Node CLIs draw Unicode symbols`.

**Unit tests** (pure, not `is_windows`-gated): `windows unicode hint: set for xterm-ghostty` (no key → `"1"`); `windows unicode hint: user value wins` (`yes` kept); `windows unicode hint: not for xterm-256color or a user TERM` (TERM `xterm-256color` / `foo` / missing → absent).

**E2e:** `term-terminfo.ps1` (+cases). Owner check: `claude` shows `◯`/`✔`, terminal detection still says Ghostty.

**Done:** filters green.

### Task 19: `resize_window` (`CSI 8 t`) guards like macOS/GTK

**Review:** light. **Size:** 3 h.

**Depends:** — (after 16 for `user32.zig`; wave order ensures it).

**Files:**
- Modify `src/apprt/win32/placement.zig`: `ResizeContext = { quick, tabs, leaves, inspector, maximized, fullscreen, minimized, arranged }`; pure `resizeAllowed(c) bool`; pure `resizeByDelta(window: geom.Rect, surface: frame.Size, requested: frame.Size, work: geom.Rect) geom.Rect` (window + (requested − surface) per non-zero dimension, clamped to the work area, top-left kept, then moved inside).
- Modify `src/apprt/win32/actions/window_actions.zig`: `resize_window` → `false` when not allowed; else resize by the delta of the **requesting surface**.
- Modify `pkg/win32/user32.zig`: `IsWindowArranged` via `GetProcAddress` (missing → not arranged).
- Create `test/windows/e2e/csi8-resize.ps1` (`# e2e: milestone=M8 timeout=150 order=1210`, bundled ConPTY).

Steps:
- [ ] **1. Failing tests** → **2. Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 placement"` → FAIL → **3. Implement** → **4. Verify** → **5. Commit** `fix(win32): CSI 8 t resizes only a lone surface in a plain window`.

**Unit tests:** `win32 placement: CSI 8 t only for a lone surface in a plain window` (each guard flips it false); `win32 placement: CSI 8 t resizes by the surface delta` (zero dimension kept); `win32 placement: CSI 8 t clamps to the work area and keeps the top-left`.

**E2e `csi8-resize.ps1`:** `vt-window-resize-allowed = true`; `printf '\e[8;30;100t'` → `stty size` = `30 100`; 2 tabs → unchanged; a split → unchanged; quick terminal → unchanged; maximized → unchanged; default config → unchanged and the log has `resize_window requested, but disabled via config`; after our resize, ConPTY's echo is swallowed (`stty size` stable).

**Done:** filters green.

### Task 20: `hidden-render` scenario, GPU columns and the 50 MB scrollback in `measure-ram.ps1`

**Review:** light. **Size:** 4.5 h.

**Depends:** none for writing (IPC names fixed); runs after 12, 15, 17 in Task 24.

**Files:**
- Create `test/windows/e2e/hidden-render.ps1` (`# e2e: milestone=M8 timeout=240 order=1220`, pwsh on the bundled ConPTY): 1) pane A (tab 1) plays a Kitty animation (`kitty-anim.sh` bytes: frame 1 magenta, frame 2 green, `a=f` + `a=a,s=3,v=1`, `z=100`, looping); 2) tab 1 `presents` grows ≥ 8/s; 3) `new_tab` → over 3 s tab 1 `presents` constant, `core_visible = false`, `chain_px = [1,1]`, ghostty.exe CPU over those 3 s < 5 % of one core (reference run with the animation visible logged); 4) `goto_tab:1` → within 200 ms `presents` grows, a frame dump shows magenta or green in the image cells; 5) minimize → `presents` constant, `chain_px` unchanged; 6) pane B in tab 2 floods (`for /L`) while hidden → tab 2 `presents` constant; after `goto_tab:2` the screen matches the output tail; 7) **reshow flash check (Task 17):** `background = #102030`, tab 1 full of `M`, 20 switches with `capture-window.ps1` each → no capture that is neither tab's content; 8) optional run with `GHOSTTY_D3D11_DEBUG=1` → no `D3D11 ERROR` in the log. If frames do not advance while visible → report R-M8-40, not a fail of this scenario's hidden checks.
- Create `test/windows/vt-smoke/cases/kitty-anim.sh` (the animation bytes, reused by the scenario and for a manual look).
- Modify `test/windows/measure-ram.ps1`: switch `-Gpu` (CIM `Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory`, instances `pid_<PID>_luid_*`, sum Dedicated and Shared → MB; `…GPUEngine` `pid_<PID>_*_engtype_3D` average of 10 × 1 s; CPU from `TotalProcessorTime` delta / wall / logical CPUs; only the ghostty.exe it started; empty columns + INFO when the classes are absent); new scenarios `hidden-tabs` (fixed ~1600×900 client, 11 tabs, `-Sample "all@wait:10,one-visible@goto_tab:1,after-trim@wait:5"`, and a maximized run), `hidden-flood`, `hidden-anim`, `minimized`, `show_ms` (20 `goto_tab`, IPC action → `presents` increment); the `scrollback` scenario fills the new 50 MB default (≈ 1.2 M lines of `%i` output, or until `scrollback-limit-bytes` worth of bytes printed; the fill size is logged); `ValidateSet` updated; help text.
- Create `docs/windows/gpu-baseline.csv` (header only: `date,commit,optimize,adapter,scenario,private_mb,ws_mb,gpu_dedicated_mb,gpu_shared_mb,cpu_pct,gpu_3d_pct,show_ms_p50,show_ms_p95`).

Steps:
- [ ] **1.** Write; **2. Verify:** both scripts parse; `powershell -NoProfile -Command "& { . ./test/windows/measure-ram.ps1 -? }"`; any `-SelfTest`/dry mode of `measure-ram.ps1` runs without a window. **3. Commit** `test(windows): hidden-render scenario; GPU, CPU and show-time columns in measure-ram`.

**Unit tests:** none (scripts).

**Done:** scripts parse; no window opened.

### Task 21: Long-tab lag repro scenario (proves or kills H1)

**Review:** light. **Size:** 2.5 h.

**Depends:** 1 (resync log line and counters). Task 1 added no scenario files (confirmed by `impl-lag`); reuse the `lag-pacer` sketch in `.superpowers/sdd/M8-win14/task-lag-report.md` where it differs from the steps below only in detail.

**Files:**
- Create `test/windows/e2e/long-tab-lag.ps1` (`# e2e: milestone=M8 timeout=1500 order=1230`): diag-lag §5 steps 1–4 and the control run:
  1. start with `GHOSTTY_LATENCY_TRACE=<sandbox>\lat.csv`, `GHOSTTY_D3D11_PACING_LOG=1`, Git Bash → zsh (`/usr/bin/zsh -f` if present, else bash), config `custom-shader = <repo>/test/windows/configs/cursor-trail.glsl`;
  2. tab A runs `node lag-gen.js 600` (Claude-like output, focused, 10 min); during it: cover the window with a top-level window the scenario creates for 60 s, 20 resizes, 50 tab switches A↔B;
  3. at the prompt in tab A and in a fresh tab C: 100 keys each via `send-input.ps1`, 30 ms apart;
  4. per surface from `lat.csv`: `total_ns`, `render_to_present_ns`, `slot_wait_ns`, `presents_between`; from the log: slot wait per frame and the `d3d11 pacer resync … drained=` lines; verdict printed: **H1 confirmed** (A: slot wait ≈ 0 every frame and ≥ 1 refresh slower than C) / **H1 killed** (same distributions → print which stage differs: `input_to_write`, `write_to_output`, `output_to_parsed`) / **fixed** (A ≈ C, `drained` small);
  5. control: the same with `custom-shader-animation = false`.
  Node missing → E2E-SKIP with reason. Budget row: Task 24 B4.
- Create `test/windows/e2e/lag-gen.js` (from diag-lag's `gen.js`: raw stdin, `?2004h ?1004h ?25l`, 60 fps `?2026h/l` frames redrawing an 18-line region, SGR 256/RGB, OSC 8, a transcript line every 8 frames, `ESC[2J ESC[3J` + 120 lines every 3 s; ASCII-only source).
- Create `test/windows/configs/cursor-trail.glsl` (our own shader, R-M8-37: a 200 ms trail on `iTime - iTimeCursorChange`, ≤ 60 lines) and `test/windows/configs/cursor-trail.ghostty` (`custom-shader = …`, defaults otherwise).

Steps: write; parse-check; `node --check test/windows/e2e/lag-gen.js` if node exists; commit `test(windows): long-tab lag repro with a cursor-trail shader`.

**Unit tests:** none.

**Done:** files parse; the scenario's SKIP path runs without a window.

### Task 22: Docs, CHANGELOG, config doc notes, next-version, version `1.4.1-dev-win.<N>`

**Review:** lead. **Size:** 3 h.

**Depends:** 1–21 merged; Task 9's verdicts; R-M8-2 answer from the owner.

**Files:** Modify:
- `docs/windows/CHANGELOG.md`: section "M8 — `1.4.1-dev-win.<N>`". First lines: based on upstream Ghostty 1.4 (link to upstream notes summary in `next-version.md`), the input-lag fix (pacer), Claude Code symbols (`TERMINUS_SUBLIME`, opt-out). Then features (OSC 5522 read/write/paste events, rich copy — every copy now also carries HTML, how to get plain; selection clipboard; split drag incl. tabs/windows/new window; hidden windows/lock/display off/virtual desktops report not visible; hidden tabs free their swap chain; `CSI 8 t` guards), **Security** (Git prompt `$PWD` injection, invisible characters in links, C1 in dropped paths), changes you may notice (scrollback default 50 MB; drag handle at the top of every pane; middle click unchanged by default), known limits (5522/2033 on the inbox console per Task 9; covered windows not tracked; split move has no undo; lock/virtual-desktop checks manual). If R-M8-2 = win.1: the line that win.1/win.2 installs get no update toast.
- `docs/windows/SPEC.md`: §7.4 clipboard formats table (design-5522 § 3), `.selection` supported / `.primary` unsupported (`:322`); §10 child env (`TERMINUS_SUBLIME`); scrollback lines `:723,:735` → `scrollback-limit-bytes`, default 50 MB; visibility (window-level, screen state, shrink); §17 M8 entry + plan link; §18 R-M8-1…40.
- `docs/windows/DECISIONS.md`: dated lines: 1.4 base; selection clipboard model; split drag scope; visibility signals.
- `docs/windows/feature-checklist.md`, `docs/windows/parity-audit.md` (`drag-handle` row → done; OSC 5522, rich copy, selection clipboard, mode 2033, GPU release rows with unit/e2e evidence).
- `docs/windows/issues-after-v1.md`: 2.4, 2.5, 3.2, 9.3 → done (task refs).
- `docs/windows/next-version.md`: close items 10, 11 (split drag part), 25, 28 (pending Task 24 B4 verdict — written as "fix shipped, proof in m8 batch"), the keybinding check ("already GTK 1.4, nothing to change"); "План для следующей версии" → done / remaining (Kitty animation per Task 24); new items: undo of split move (R-M8-30), covered-window occlusion (R-M8-22), EcoQoS (R-M8-24); the suggested upstream texts for `is-unicode-supported` (`TERM_PROGRAM === 'ghostty'` on win32) and git-for-windows (`git-prompt.sh` → `${PWD//[[:cntrl:]]/}`) as text only (R-M8-4).
- `docs/windows/RELEASING.md`: `-N <n>` example for `1.4.1-dev-win.<N>`.
- `src/config/Config.zig` (**doc comments only**): `copy-on-select` ("`primary` on Windows is a Ghostty-only selection buffer that middle click pastes; `both` also writes the system clipboard; `true` is `clipboard` on macOS and Windows"); `middle-click-action` ("On Windows `primary-paste` pastes that buffer, which is empty unless `copy-on-select` is `primary` or `both`"); `drag-handle` ("On Windows, the same as macOS"); `windows-conpty` ("… and the Kitty clipboard protocol (OSC 5522) / mode 2033" — only if Task 9 found an inbox drop).
- `test/windows/README.md`: "M8 scenarios" (every scenario of Task 24 B1–B7, `FakeExe` additions, `measure-ram -Gpu`, the lag scenario's runtime).

Steps: write; `LOCK ZIG build test -j6 -Dtest-filter="config"` (doc-only guard); `git diff --stat` shows only docs and `Config.zig` comments; commit `docs(windows): M8 changelog, SPEC and config notes as built`.

**Done:** diff is docs + comments; every R-M8 ruling is in SPEC §18.

### Task 23 (conditional: only if the owner keeps `1.4.1-dev-win.1`): compare releases by (zon, N)

**Review:** full (update path). **Size:** 2.5 h. **Depends:** R-M8-2 answer. Skipped (ledger note) when N continues (recommended).

**Files:** modify `src/apprt/win32/update/release.zig` (compare by zon semver, then N; header comment), `src/apprt/win32/update/Updater.zig` (`currentNForRun` → current (zon, N); tests), `dist/windows/release-version.ps1` (refuse N not above the highest **for the same zon**; self-test table rows).

**Unit tests:** `win32 update release: newer zon wins over a higher N` (`win-1.4.1-dev-1` beats `win-1.3.2-dev-2`); `… same zon compares N`; `… an older zon never wins`; release-version self-test rows `new-zon-n1` valid, `same-zon-not-above` refused. **Done:** filters + `PS dist/windows/release-version.ps1 -SelfTest`; CHANGELOG line in Task 22. Commit `fix(win32): releases compare by version then N`.

### Task 24: Batched GUI e2e, baselines and the lag verdict (lead, owner away)

**Review:** lead. **Depends:** 22 (and 23 if it ran).

Preconditions: the owner is away and agreed; desktop lock free; keep-awake helper on (`SetThreadExecutionState`); the owner's terminal minimized if it covers the capture area; ≥ 8 GB free RAM; no foreign `ghostty.exe` is touched (scenarios use `Register-OwnGhostty`, kill by PID).

- [ ] **B0. Builds.** `LOCK ZIG build -j6` (Debug, the e2e build). `RFS` ReleaseFast to `zig-out/rfs` (`-Dversion-string=1.4.1-dev-win.0`) for B2/B4/B8. Unit groups as `release.ps1` runs them (group 1 `win32 `, group 2, group 3; `-Jobs 2` on this machine).
- [ ] **B1. Visibility (Debug):** `E2E -Only visibility-hidden,csi8-resize`.
- [ ] **B2. Hidden surfaces and the R-M8-21 gate (ReleaseFast exe via `GHOSTTY_E2E_EXE`):** `E2E -Only hidden-render,new-tab-flash,new-tab-white-flash`; `PS test/windows/measure-ram.ps1 -Exe <rfs> -Gpu -Scenario hidden-tabs` (default size and maximized), `-Scenario hidden-flood`, `-Scenario hidden-anim`, `-Scenario minimized`, and `show_ms`; rows `m8-*` into `docs/windows/gpu-baseline.csv`. **Gate:** per hidden tab before-shrink ≥ 8 MB default or ≥ 30 MB maximized → keep; else `shrink_hidden_chains = false` n.1 commit and rerun `hidden-render`. A flash in step 7 → R-M8-21 grace fallback n.1.
- [ ] **B3. Clipboard (Debug):** `E2E -Only copy-html,kitty-clipboard-write,kitty-clipboard-read,kitty-paste-event,selection-paste,middle-click,paste-confirm,paste-files,right-click` (clipboard saved/restored by each).
- [ ] **B4. Lag (ReleaseFast):** `E2E -Only long-tab-lag` (≈ 25 min incl. control run). Record the verdict (confirmed-then-fixed / killed / fixed) and the `drained` numbers in the ledger and `next-version.md` item 28 (n.1 doc commit). H1 killed → the lead opens an n.1 investigation task at the stage the scenario names.
- [ ] **B5. Security and env (Debug):** `E2E -Only title-inject,link-hover-open,drop-files,term-terminfo,pwd-osc7`; headless `PS test/windows/shell-marks/run.ps1` (all cases).
- [ ] **B6. Split drag (Debug):** `E2E -Only split-drag,tab-drag` (mouse; run last among GUI scenarios before baselines to keep flaky mouse runs from blocking others; rerun once on a mouse-timing failure).
- [ ] **B7. Regression sweep (Debug):** `E2E -Milestone M7`, then `E2E -Milestone M1`; `VTS` (all cases with references); `kitty-render`.
- [ ] **B8. Baselines (ReleaseFast):** `measure-ram.ps1 -Exe <rfs>` scenarios `one-surface`, `scrollback` (50 MB fill), `tabs`, `splits`, `windows`, `close-10`, `zero-windows` → rows `m8-<scenario>` in `docs/windows/ram-baseline.csv`; `E2E -Only input-latency,output-latency,tui-latency` with `GHOSTTY_E2E_EXE=<rfs>` (and `input-latency` once with `cursor-trail.ghostty`) → rows in `docs/windows/latency-baseline.csv`. Compare with the budget table; commit `test(windows): M8 RAM, latency and GPU baselines` (CSV rows only).
- [ ] **B9. Report:** ledger `.superpowers/sdd/M8-win14/progress.md`: per scenario PASS/FAIL/SKIP with reason, the gate decision, the lag verdict, budget rows; each FAIL → an n.1 task (step, log excerpt without the user name, evidence) or an owner-accepted limit.

Order rationale: renderer/visibility first (the gate in B2 can change the build), the long lag run in the middle (no mouse, can run unattended), mouse-heavy drag late, baselines last on the final build.

**Owner checks (manual, after B9; checklist in the ledger):**
1. Git Bash pane with a 2033 reader (`printf '\e[?2033h'; cat -v`), `Win+L`, unlock → `;2n` then `;1n`; the log has two `screen state` lines.
2. `Win+Ctrl+→` / `←` with the reader → `;2n` / `;1n`.
3. Display off (power button / `Win+P` off timeout) → `;2n`, on → `;1n`.
4. `claude` in Git Bash shows `◯`/`✔`; `/terminal-setup` (or the status line) still names Ghostty.
5. A day of normal use with the owner's own shader config: does the long-tab lag come back? (`GHOSTTY_D3D11_PACING_LOG=1` optional; a large `drained` on the slow tab is the proof).
6. Drag a split by eye: handle look and zone highlight vs macOS screenshots (accent at 0.3).

**Done:** B1–B8 green or every failure has an n.1 fix or an accepted limit; owner checks 1–4 PASS; the ledger is complete.

### Task 25: Release `1.4.1-dev-win.<N>` (lead + owner)

**Review:** lead + owner. **Depends:** 24.

- [ ] **1 (owner):** `git push origin windows`, `git fetch --tags origin`.
- [ ] **2 (owner, or the lead with the owner's go):** `PS dist/windows/release.ps1 -N <N>` (x64; `-NoArm64` if the owner skips ARM64 again), `run_in_background`; test groups with `-Jobs 2`; a new commit needs its test-counts lines.
- [ ] **3 (lead):** extract the x64 zip to `zig-out\rc`; `GHOSTTY_E2E_EXE=…\ghostty.exe` `E2E -Only package-portable,installer-test,startup,render` (the full `-Milestone all` only with the owner's go — it was B7's job); `Test-Privacy` on `release-notes.md` after adding the M8 highlights.
- [ ] **4:** `docs/windows/m8/acceptance.md` (budget rows, B-steps outcome, owner checks); SPEC §17 "done"; CHANGELOG acceptance line; commit `docs(windows): M8 acceptance — 1.4.1-dev-win.<N>`.
- [ ] **5 (owner):** push; run `publish.txt`; publish the pre-release; the update toast from an installed win.2 appears (only true with N > 2 or with Task 23).

Each failure in Steps 2–5 gets a 25.n note and a fix commit `fix(<area>): <summary>`.

## Self-review

- **Coverage of the designs:** diag-lag §4–§5 → Tasks 1, 21, 24 B4. design-5522 Tasks 1–7 → 9, 3, 4, 10, 7, 13, and its docs/e2e split into 4/10/13 (scenarios) and 22 (docs). design-drag T1–T7 → 2 (T1+T2), 5 (T3), 8 (T4), 11 (T5), 14 (T6+T7 minus docs), 22 (docs). design-vis V1–V9 → 12, 16, 15, 17, 20 (V5+V9), 9 (V6), 19 (V7), 13 (V8 merged into the selection task, R-M8-9), 20 (V9). design-sec SEC-1/2/3 → 6, ENV-1 → 18, DOC-1 → 22, keybindings → R-M8-6 (no task).
- **Merges:** design-5522 Task 1 and design-vis V6 share `headless.ps1`/`RESULT.md` → one probe task (9). design-vis V8's "only standard" unit test is replaced by Task 13's "selection supported, primary not" (R-M8-9). design-sec SEC-2 step 5 (clipboard preview) runs inside Task 10, which rewrites the prompts anyway. V1 absorbs V3's `scheduleMemoryRelease` step (useful without the shrink and keeps `Window.zig` out of Task 15).
- **Disjointness:** checked per wave in the Waves table; `messages.zig`, `win32.zig` and `e2e.ps1` have a single writer (Task 2); `clipboard.zig` is edited in W1 only by Task 3's test-import lines.
- **Open for the lead:** R-M8-2 (N; asked before Task 22). Task 1's file set is confirmed (D3D11.zig, SwapChain.zig, generic.zig, shadertoy.zig); `shadertoy.zig` has no other writer.
