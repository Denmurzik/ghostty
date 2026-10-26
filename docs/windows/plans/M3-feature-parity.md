# M3 — Feature parity (shaders, transparency, overlays, quick terminal, inspector): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every cross-platform Ghostty feature the M2 action table deferred to M3 works on Windows 11: quick terminal with global hotkeys, `toggle_visibility`, command palette, search bar, desktop notifications (toasts) and `command_finished`, URL hover label and safe `open_url`, terminal inspector (imgui win32 + dx11), config-errors dialog, `export_terminal_io`, user custom shaders (GLSL → SPIR-V → HLSL), Kitty graphics and background image verified by reference screenshots, `background-opacity`/`background-blur` through DirectComposition swap chains plus `toggle_background_opacity`, DirectWrite font discovery and `MapCharacters` fallback, full GPU device-loss recovery with a renderer-health bar, key-sequence/key-table indicator, read-only badge, unfocused-split dimming and `bell-features = border`, the M2 leftovers (tab context menu, tab tooltips, text drops), and `vt-smoke.ps1` screenshot checks. Every feature is lazy: a default config costs the same RAM and key-echo latency as M2.

**Architecture:** M3 adds feature modules to `src/apprt/win32` that hang off one fan-out file, `hooks.zig`, wired once into `App`/`Window`/`Tab`/`Surface` by the skeleton task (Task 2), so feature tasks never edit each other's files. Text overlays (search, palette, labels, badges, bars, in-app toasts) are owned popups managed by `overlay.zig` (layered click-through labels, or opaque interactive panels with native `EDIT` controls), painted with M2's process-wide Direct2D DC render target. Per-surface pixel effects (split dimming, bell border) are a "decor pass" drawn by the D3D11 backend onto the frame target before present (no extra HWND, no DComp). DirectComposition is used only when transparency is configured: the surface's swap chain switches to `CreateSwapChainForComposition` (premultiplied alpha) and the UI thread owns the DComp target/visual. The inspector renders imgui with `imgui_impl_dx11` on the shared device under the context lock, in its own top-level window.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/dwmapi/shell32/comctl32/comdlg32/advapi32), DirectComposition, DXGI/D3D11, Direct2D/DirectWrite, WinRT toasts (combase/runtimeobject, hand-written ABI), glslang + SPIRV-Cross (HLSL backend), dcimgui (`imgui_impl_win32` + `imgui_impl_dx11`), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority) §6.3, §6.5, §6.6, §7.5, §9, §13 (toasts/AUMID), §15.7 (vt-smoke), §17 M3, §18.2, §18.17, §18.19. Inputs: `docs/windows/recon/{renderer,platform,apprt}.md`; M2 plan `docs/windows/plans/M2-tabs-splits-windows.md` (deferred items: Task 3 deferred list, Task 19 tab menu/tooltip, Task 26 bell border, Task 38 text drops, Task 39 device loss) and the M2 ledger `.superpowers/sdd/M2-tabs-splits-windows/progress.md` ("minor (deferred)" lines assigned in "Carry-over assignment" below).

**Starts after M2 acceptance** (M2 Tasks 21–39 and 35 landed, G1 RAM fix 34.1 landed, `open_url` hotfix 34.4 landed). Task numbers are identities, not order: the wave table is the execution order.

**Revision 2 (architect-m3b, 2026-10-27):** applies `docs/windows/plans/M3-preflight-review.md` (dispositions at the end). Adds Task 28 (ConPTY sequence probe, W1) with lead decision point L1 and the conditional fallback Task 28.1 (`PSEUDOCONSOLE_PASSTHROUGH_MODE` default); moves Task 5 from W1 to W5 to keep W1 at 5 tasks; builds Task 10 on M2 hotfix Task 34.4 (`open_url` allowlist, already on `windows`) instead of re-planning it.

## Global Constraints

Carried from M1/M2 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2.
- Pure Win32 + DWM apprt; chrome and overlays drawn with Direct2D/DirectWrite; text inputs are native `EDIT` controls (SPEC D7). No WinUI/XAML, no .NET.
- Bindings hand-written in `pkg/win32` (D6): append-only, W-variants, `callconv(.winapi)`, COM interfaces list ALL vtable slots with a slot-count test against Windows SDK 10.0.26100 headers (WinRT interfaces count the 3 `IInspectable` slots). Core never imports `win32` — **one M3 exception** (ruling R-M3-9): `src/font/directwrite.zig`, Windows-gated, the way CoreText discovery imports `pkg/macos`.
- Zig 0.17 std idioms of the touched file (`global.io()`, `std.Io.Timestamp`, `io.sleep`); no `std.time.Timer`/`std.Thread.sleep`.
- **UI thread owns** every HWND, every DComp object, the D2D/DWrite chrome objects, imgui contexts, and the tab/split model. Render threads own their swap chains (create, resize, present). Cross-thread hand-off only by `PostMessageW` with a heap or AddRef'd payload; never `SendMessage` from a non-UI thread.
- **`open_url` never returns `false` to core** (pre-flight 1; M2 Task 34.4 established it): every arm returns `true` after it has opened, revealed, confirmed, refused or failed (OOM, full queue, cancelled confirm included). Core's generic opener (`src/os/open.zig`, which 34.4 makes refuse `.osc8`/`.unknown` on Windows) is unreachable from the win32 apprt.
- **System DLLs beyond the M2 set load lazily from System32** (pre-flight 3): `dcomp.dll`, the WinRT `combase`/`Ro*`/`Windows*String` entry points and `d3dcompiler_47.dll` are resolved on first use through `LoadLibraryExW(…, LOAD_LIBRARY_SEARCH_SYSTEM32)` + `GetProcAddress` (pattern: `pkg/win32/comctl32.zig:97`, `pkg/win32/d3dcompiler.zig:83`); `ghostty.exe`'s import table gains no `dcomp.dll`, `d3dcompiler_47.dll` or `xinput*` (checked in Task 19). `comdlg32` (KnownDLL) may be linked statically.
- **Every modal dialog runs from a posted-message handler** (`WM_GHOSTTY_POSTED_DIALOG`), never inside `performAction`, a core callback, an OLE/WinRT callback, or an IPC op.
- Owner safety (M2 rules, extended): e2e scenarios run only through `test/windows/e2e.ps1` with the shared desktop lock and a per-scenario `class`; never write the owner's registry or `%USERPROFILE%\.config`; never open a browser, a toast or an external handler on the owner's desktop from a test — with `GHOSTTY_WIN32_TEST_IPC=1`, `notify.zig` and `shell_open.zig` **record** instead of acting (exposed through the `state` op); global hotkeys used by tests are `ctrl+alt+shift+f9`/`f10` only and die with the process; transparency oracles capture only the screen rectangle of the Ghostty window over a solid backdrop window the scenario itself creates.
- Commits: no `Co-Authored-By` or similar trailers.
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`; a worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

Speed rules (owner, 2026-10-26; ledger "Speed-up" rulings — apply to every task; they supersede the `-j4` line of DECISIONS "Process constraints", which the lead updates in DECISIONS — pre-flight 20):

- **Builds and tests `-j6`**, strictly one at a time through the test-lock (it also checks free RAM). Bash timeout 600000. Prefer focused `-Dtest-filter`; never the full suite locally.
- **Implementers run unit tests + `LOCK ZIG build -j6` only.** Each task that owns a GUI scenario writes it (header, owner-safety rules) and makes it parse (`powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"`), but does **not** run it: the lead runs the wave's scenarios as one batch after the wave lands and routes failures back as fix rounds. Exceptions (implementer runs GUI): Task 8 (spike), Task 3 (`vt-smoke` reference generation on WARP), Task 28 (ConPTY probe). A task that adds a vt-smoke case writes the `.sh` + header only; the lead generates `ref/<case>.png` in the wave batch (`vt-smoke.ps1 -Only <case> -Driver warp -Update`) and inspects it (pre-flight 11).
- **Up to 5 writers in flight.** Tasks start as soon as their stated dependencies landed and their files do not collide with in-flight tasks; the wave table is the default schedule, not a barrier.
- **Review tier** (stated per task): `light` = one batched sonnet review per batch of landed-ready simple tasks; `opus` = per-task review for concurrency, COM lifetimes, security or latency.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (lead only, after `LOCK ZIG build -j6`)
- Renderer tests pass `-Dapp-runtime=none`; apprt tests run with the default runtime. Test names start with `win32 `, `d3d11 `, `windows ` or the core module's existing prefix.

### M3 core touch points (complete list)

`pkg/spirv-cross/build.zig` (HLSL backend, Windows-gated) and `src/renderer/shadertoy.zig` (`Target.hlsl`, `hlslFromSpv`) — Task 4; `src/global.zig` (lazy `glslang.init`) — Task 4, only if its measurement shows > 0.5 MB private; `src/font/directwrite.zig` (new), `src/font/discovery.zig` (Windows arm), `src/font/DeferredFace.zig` (only if the `.win` payload must change) — Task 5; `src/renderer/message.zig`, `src/renderer/Thread.zig`, `src/renderer/generic.zig`, `src/Surface.zig` (platform-neutral `redraw` message + `Surface.queueRedraw`) — Task 6; `pkg/dcimgui/build.zig` (`backend-dx11`, `backend-win32` options) and `src/build/SharedDeps.zig` (Windows dcimgui options; link list) — Tasks 1, 19; `src/termio/Exec.zig` Windows-only read-loop minors — Task 23; `src/renderer/generic.zig` + `src/renderer/image.zig`: on a backend-reported device-generation change, image textures (Kitty images, background image) are dropped and marked for re-upload (platform-neutral, no-op elsewhere) — Task 24 (pre-flight 10); `src/os/windows.zig` (default ConPTY flags → `PSEUDOCONSOLE_PASSTHROUGH_MODE` where accepted; the fallback to 0 at `src/pty.zig:512` stays) — Task 28.1, only under the lead's L1 ruling after the Task 28 probe (pre-flight 2). `src/os/open.zig` (Windows refusal of `.osc8`/`.unknown`) is M2 Task 34.4, not an M3 touch point. A cause found outside these files (e.g. generic changes for custom-shader ping-pong) is not fixed in the task: the implementer stops with evidence and the lead schedules an `n.1` task.

### RAM budget (owner: low RAM)

Private Bytes, ReleaseFast, hardware adapter, measured with `test/windows/measure-ram.ps1` (Task 3 adds `-ExtraConfig`/`-Actions`/`-Tag`/`-Sample` so no feature task edits the script; `-Actions` implies `GHOSTTY_WIN32_TEST_IPC=1`; `-Sample <label>@<op>` writes one CSV row per point with scenario `<tag>:<label>`). Baseline = the M2 acceptance rows (after 34.1). A feature that is not configured or not used costs nothing: modules allocate on first use.

| Item | Budget | Measured by |
|---|---|---|
| default config, 1 window 1 surface | ≤ M2 row + 1 MB | G1, Task 27 |
| DirectWrite discovery (`font-family = Consolas`, CJK fallback printed) | ≤ `font-consolas-m1` row + 2 MB (that row is recorded by the lead at G1, on the build before Task 5 lands) | G1 (baseline), Task 27 |
| custom shader configured (1 surface, 1 shader) | ≤ +2 × target bytes (ping-pong textures) + 4 MB | G1 (`custom-shader` tag) |
| composition mode (`background-opacity = 0.9`) | first surface ≤ +3 MB, each extra ≤ +0.5 MB over the hwnd-mode surface cost | G2 (`opacity` tag) |
| overlays (search, palette, labels) after first use | ≤ +1 MB total | Task 27 |
| inspector open on 1 surface | ≤ +25 MB while open; back within +2 MB of the pre-open value 30 s after close | Task 27 (`inspector` tag, `-Sample before@… open@… after30s@…`) |
| quick terminal | 0 before the first toggle; then one surface's cost | Task 27 (`-Sample before@… after@…`) |
| first toast shown (WinRT DLLs) | ≤ +4 MB | Task 27 (manual, owner-approved run) |
| `glslang.init` at startup | measured in Task 4; > 0.5 MB → made lazy | Task 4 |

### Latency budget (owner gate, M2 §18.18)

Ghostty-owned key echo ≤ 6 ms p95 and whole path ≤ 16 ms p95 on ReleaseFast must not regress. Gate for M3: `input-latency` (a) Ghostty-owned p95 within +0.5 ms of the M2 acceptance baseline in each of: default config (G1); a 2-split tab with dimming active (G1); `background-opacity = 0.9` (composition mode, G2); a custom shader configured (recorded, not gated — the user opted into GPU work per frame). Method (pre-flight 12): each gated configuration runs ≥ 200 key-echo samples × 3 runs; the gate compares the median of the 3 p95 values with the M2 acceptance configuration re-measured the same day on the same machine (the stored `n = 3` baseline rows are below run-to-run noise). If L1 changes the default ConPTY flags, G1 also re-measures the whole path (≤ 16 ms p95) with the new default. The decor pass draws only when its word is non-zero; overlays never take focus except the search bar and the palette; no M3 code runs on the `WM_KEYDOWN` → pty write path.

## Review Focus

1. **COM and thread affinity:** DComp objects touched only on the UI thread, the swap chain handed over AddRef'd by a posted message; WinRT toast objects created on the UI thread (STA), the `Activated` delegate called on a pool thread only posts; the DirectWrite text-analysis source object and fallback calls from render threads; imgui dx11 using the shared immediate context only under `Device.lockContext`. → Tasks 8, 14, 15 (spike + `composition` tests), 18 (delegate refcount test), 5 (MapCharacters from two threads), 19 (lock assert in Debug).
2. **Untrusted input to the OS:** `open_url` from OSC 8 / detected links (scheme allowlist, `file:` executables revealed not run, no UNC, length/control-char limits, confirmation for other schemes); toast title/body from OSC 9/777 (XML-escaped, control chars stripped); `export_terminal_io` path from the save dialog only. → Task 10 (`shell_open` validation table), Task 18 (XML escape tests).
3. **Latency and RAM of the default path:** nothing allocated before first use; the decor pass is skipped at word 0; composition mode only when transparency is configured; global hotkeys registered on the message window (no hooks); inspector renders only while open. → G1, G2, Task 27 rows.
4. **Device loss with everything open:** N surfaces in hwnd and composition mode, a custom shader, the inspector, the overlays; repeated losses; WARP fallback after three failures. → Task 24 tests + `device-recover` scenario.
5. **Overlays follow the window:** move, resize, maximize, DPI change, minimize, tab switch, split relayout and zoom, tab tear-off into another window (re-owning), quick terminal slide; interactive panels keep the owner window looking active. → Task 9 tests + `overlay-follow` scenario, Tasks 12/13 scenarios.
6. **Quick terminal and global keys:** hotkey taken by another app, layout change, toggle while the slide runs, autohide with own dialogs/popups, closing its last surface, `quit-after-last-window-closed = true` (quick window does not count). → Tasks 16, 17.

## Rulings (architect-m3, 2026-10-27; lead/owner may overturn — recorded in SPEC §18 by Task 27)

- **R-M3-1 Overlays = owned popups, pixel effects = decor pass** (amends SPEC §17 "DComp overlay visuals" and §6.6). Text overlays are owned `WS_POPUP`s (proven by M2's resize overlay and drop highlight; child windows above a flip-model child swap chain hit the airspace problem). Unfocused-split dimming and the bell border are drawn by the D3D11 backend on the frame target before present, driven by a per-surface atomic word. Cost if wrong: a later switch to DComp visuals for these two effects, local to `Decor.zig`/`decor.zig`.
- **R-M3-2 Composition mode only for transparency.** A surface's swap chain is `hwnd` mode unless `background-opacity < 1` or `background-blur` is not `false`; config reload switches modes through the M2 present-target generation (swap chain recreated on the render thread). `toggle_background_opacity` does not switch modes: it makes the window's backdrop layer opaque (the tab container paints `background`), as macOS makes the window opaque; with `background-opacity = 1` (hwnd mode) it is a no-op (state unchanged, logged), as on macOS. Cost if wrong: transparency costs RAM/latency for everyone (if always-on) or one mode switch per toggle.
- **R-M3-3 Backdrop with transparency:** `background-blur` true/radius/`macos-glass-*` → Acrylic (`DWMSBT_TRANSIENTWINDOW`) for the whole window, strip painted over it like over Mica; opacity without blur → no system backdrop, client transparent (extended frame `-1` or the empty-region blur-behind trick, whichever Task 8 proves), strip painted opaque. High contrast → transparency off. Radius values are ignored (DWM has no radius). Cost if wrong: one backdrop constant.
- **R-M3-4 Inspector uses the shared device** under `Device.lockContext`, rendered on the UI thread from a 30 Hz timer while its window is open (drawing when foreground or dirty); `render_inspector` only sets a dirty flag that the next tick consumes (no imgui frame per terminal frame, so `WM_KEYDOWN` is not delayed — pre-flight 29); `ClearState` after its draw. This UI-thread swap chain is the one exception to SPEC §6.4 ("the UI thread never calls into DXGI"), recorded by Task 27. It is a separate top-level `GhosttyInspector` window per surface (GTK `inspector_window` model), created on first `inspector` action, destroyed with the surface. `imgui_impl_dx11.cpp` is compiled with `-DD3DCompile=ghostty_imgui_D3DCompile`; Ghostty exports that symbol, which forwards to the System32-loaded pointer of `pkg/win32/d3dcompiler.zig`. `imgui_impl_win32.cpp` is compiled with `-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD`. `ghostty.exe` imports neither `d3dcompiler_47.dll` nor `xinput*` (pre-flight 3). Cost if wrong: an own device for the inspector (one flag; +RAM while open).
- **R-M3-5 Toasts via WinRT, no COM activator.** AUMID `com.mitchellh.ghostty.windows-unofficial` (Debug builds `…-debug`), self-registered under `HKCU\Software\Classes\AppUserModelId\<AUMID>` (`DisplayName` = "Ghostty — Unofficial Windows port" (DECISIONS product name), `IconUri` = `%LOCALAPPDATA%\ghostty\toast-icon.png` written from `images/icons/icon_128.png`) on the first notification, `SetCurrentProcessExplicitAppUserModelID` at start (this ungroups taskbar pins made with M1/M2 builds — noted in the M3 changelog). Click → `Activated` delegate → present that surface while Ghostty runs (it always runs: tray). A toast clicked in the Action Center after Ghostty exited does nothing (no `ToastActivator` CLSID; recorded). If WinRT fails: `FlashWindowEx` on the surface's window + one warning. Cost if wrong: a COM activator server (M5).
- **R-M3-6 Quick terminal** = a `Window` of kind `.quick`: `WS_POPUP`, `WS_EX_TOOLWINDOW` (no taskbar/Alt+Tab), topmost while shown, decorations `none`, strip `tabs_only` only with ≥ 2 tabs, size/position/screen from `quick-terminal-*`, slide by `SetWindowPos` frames on a timer (ease-out, `quick-terminal-animation-duration`, 0 = instant), not user-resizable in v1, hidden (not destroyed) on toggle, destroyed when its last surface closes. It is excluded from `goto_window`, the tray's "last active window" and the `quit-after-last-window-closed` count (macOS behaviour). `quick-terminal-keyboard-interactivity` and `quick-terminal-space-behavior` are ignored on Windows (Wayland/macOS only). Cost if wrong: Window-kind special cases.
- **R-M3-7 Global keybinds** (`global:` prefix) = `RegisterHotKey` on the message-only window, `MOD_NOREPEAT`; activation runs the bound action through `core_app.performAllAction` like GTK's portal path; registration failure (chord owned by another app) logs one warning per chord; re-registered on config change, not on keyboard-layout change (documented). No low-level keyboard hook. Cost if wrong: layout-dependent unicode triggers need re-registration on `WM_INPUTLANGCHANGE`.
- **R-M3-8 `open_url` policy** (extends M2 hotfix Task 34.4, which already ships the allowlist: http/https/mailto open, `file:`/local paths only revealed, UNC/device paths/other schemes refused, core `open.zig` refusing `.osc8`/`.unknown` on Windows; Task 10 moves that logic into `shell_open.zig` and widens it as below): `text`/`html` kinds (from Ghostty itself) open directly; `unknown`/`osc8` (terminal output) are validated: `http`, `https`, `mailto`, `ftp` open (mixed-case schemes normalised). `file:` URLs are percent-decoded once; bare paths are resolved against the surface's pwd (Git Bash `/c/x` → `C:\x`, `~` → `%USERPROFILE%`, relative → pwd-relative), then `GetFullPathNameW`. Refused: any `:` after the drive letter (ADS), any `\\?\` or `\\.\` prefix, UNC (incl. `\\?\UNC`, `file://host/`), DOS device names (`CON`, `NUL`, `COM1`… in any component), and `GetDriveTypeW` ≠ `DRIVE_FIXED`/`DRIVE_REMOVABLE` (mapped network drives). Existing local files open, except that after stripping trailing dots and spaces an executable/script/container type is revealed in Explorer (`SHOpenFolderAndSelectItems`) instead of run: PATHEXT ∪ `.lnk .url .scr .hta .msi .msp .msix .appx .appref-ms .application .ps1 .vbs .vbe .js .jse .wsf .wsh .wsc .sct .reg .inf .scf .cpl .jar .msc .chm .pif .gadget .settingcontent-ms .library-ms .searchConnector-ms .diagcab .website .theme .themepack .iso .img .vhd .vhdx .xll .docm`, or any extension for which `AssocIsDangerous` (shlwapi) is true; a missing path is refused. Any other scheme (`ms-*`, `search-ms`, `vscode:` …) asks first (TaskDialog "Open with an external program?", posted); > 2048 bytes or any C0/C1 control → refused with a log line. Validation and execution run on one lazy worker thread (STA, `ShellExecuteExW` with `SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI`), queue ≤ 8 — so `exists`/drive checks never block the UI thread on a dead network drive. `link.open` returns `true` for every verdict and error (Global Constraints). Cost if wrong: a confirmation or reveal where the user expected a direct open.
- **R-M3-9 DirectWrite for discovery only**, rasterisation stays FreeType + HarfBuzz; `src/font/directwrite.zig` may import `win32` (Windows-gated; mirrors `pkg/macos` in CoreText discovery). Emoji-presentation fallback is not routed to DirectWrite (Segoe UI Emoji is COLRv1, which FreeType cannot colour): the embedded Noto Color Emoji stays the emoji face. The M1 index stays as the fallback when the DWrite factory cannot be created. Cost if wrong: COLRv1 rendering work later.
- **R-M3-10 Device-loss recovery:** a renderer that sees `DEVICE_REMOVED/RESET` marks its generation lost and reports `unhealthy`; the apprt shows the health bar and, 250 ms after the first report (debounce), calls `displayUnrealized()` + `displayRealized()` for every surface on a lost generation; the backend re-acquires the healthy device on the next frame. Three failed recoveries within 60 s switch device acquisition to WARP (logged once). M2 Task 39's "resident process quits when the device is lost" fallback is removed. Cost if wrong: blank surfaces until reopened (M2 behaviour).
- **R-M3-11 Feature checklist** `docs/windows/feature-checklist.md` (one line per cross-platform feature: milestone, evidence = unit test, scenario or screenshot path, status) is the M3 exit artefact and feeds the v1.0 gate.
- **R-M3-12 Text drops** (M2 §18.17 deferred) go through core's paste path (`completeClipboardRequest` with a `.paste` request), so bracketed paste and the unsafe-paste confirmation apply exactly as for Ctrl+V.

## Waves (parallelism)

≤ 5 tasks per wave; file sets inside a wave are strictly disjoint (checked against every task's `Files:` and the hot-file chains). Scheduling follows real dependencies (speed rules); the table is the default.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 bindings · 2 skeleton + hooks · 3 vt-smoke, checklist, harness · 4 shadertoy → HLSL (core) · 28 ConPTY sequence probe | — |
| L1 | **Lead decision point** (before W2): reads Task 28's `RESULT.md`. All needed sequences arrive with flags 0 → no change. Some are dropped with 0 but arrive with 8 → Task 28.1 (default flags = `PSEUDOCONSOLE_PASSTHROUGH_MODE` where accepted) lands alone before W2, and G1 re-measures latency with it. Dropped with both → the affected features become owner-approved gaps in `feature-checklist.md`, and their tasks (3 `kitty-image` ref, 10, 18) drop the dependent scenario steps | 28 |
| W2 | 6 decor pass (dim, bell border) + core redraw · 8 transparency spike · 9 overlay host · 16 global hotkeys + `toggle_visibility` · 23 input/clipboard/termio/pwd polish | L1 (all); 2 (6, 9, 16, 23); 1 (8, 16) |
| W3 | 7 custom shaders on D3D11 · 10 links + `shell_open` · 11 status overlays · 12 search bar · 13 command palette | 3+4+6 (7); 9+1+23 (10); 9 (11, 12, 13) |
| G1 | **Lead checkpoint:** RAM `one-surface` default + `custom-shader` + `font-consolas-m1` (before Task 5 lands); latency (a) default and 2-split dimmed (+ whole path if L1 changed the flags); vt-smoke green incl. the lead-generated `custom-shader` ref. Over budget → the lead adds `n.1` tasks before W5 | 6, 7 |
| W4 | 14 composition swap chain (renderer) · 17 quick terminal · 18 notifications · 19 inspector · 20 config-errors + export | 7+8 (14); 16+23 (17); 1+2+L1 (18); 1+2 (19); 1+2+10 (20) |
| W5 | 5 DirectWrite discovery · 15 transparency + blur (apprt) + `toggle_background_opacity` · 21 tab context menu + tooltip · 22 text drops · 24 device-loss recovery | G1 (5); 3+14+17+8 (15); 2+9 (21); 2+23 (22); 14+15+19+11+17 (24, after 15 lands) |
| G2 | **Lead checkpoint:** RAM `opacity` rows; latency (a) with `background-opacity = 0.9`; lead generates and inspects the `opacity` vt-smoke ref | 15 |
| W6 | 25 M3 e2e full run (alone; includes the `background-opacity = 0.9` variant of `device-recover`) | all above |
| W7 | 26.n integration fixes (≤ 5 at a time, disjoint) | 25 |
| W8 | 27 RAM rows, latency, screenshots, checklist, SPEC update, acceptance (alone) | 26.* |

Hot-file chains (every file touched by more than one task; any file not listed has a single owner):
- apprt: `App.zig` 2→17→24; `Window.zig` 2→23→17→15; `Surface.zig` 2→23→15; `Tab.zig` 2→15; `frame.zig` 17→15; `Chrome.zig` 9→21; `actions/app_actions.zig` 2→10; `clipboard.zig` 2→23; `ipc/client.zig` 17 only; `TabStrip.zig` 21 only; every stub file of Task 2 → its one owner (listed in Task 2); `hooks.zig`, `messages.zig`, `actions.zig`, `ipc/ops.zig`, `src/apprt/win32.zig` 2 only; `inspector/Inspector.zig` 2→19→24.
- renderer: `src/renderer/D3D11.zig` 2→6→7→14→24; `d3d11/Frame.zig` 6→7; `d3d11/hlsl.zig` 6→7; `d3d11/SwapChain.zig` 14→24; `d3d11/Device.zig` 24 only.
- core: `src/renderer/shadertoy.zig` 4 only; `src/renderer/generic.zig` 6→24; `src/renderer/image.zig` 24 only; `src/os/windows.zig` 28.1 only (conditional); `src/build/SharedDeps.zig` 1→19.
- bindings: `pkg/win32/{user32,advapi32,dwmapi,gdi32,shell32,shlwapi,ole32,comctl32,main}.zig` 1 only; `pkg/win32/build.zig` 1→8; `dcomp.zig` 1→8→15; `dxgi.zig` 8→14; `winrt.zig` 1→18; `comdlg32.zig` 1→20; `dwrite.zig` 5 only; `d3dcompiler.zig` 7 only (Task 19's `ghostty_imgui_D3DCompile` forwarder lives in its own `inspector/imgui_shim.zig` and only consumes `Compiler.load`); `pkg/dcimgui/{build,main}.zig` 19 only. A declaration found missing in a Task-1-only file is reported to the lead, who appends it in a one-line commit between landings.
- tests/docs: `test/windows/lib/Harness.psm1`, `test/windows/e2e.ps1`, `test/windows/measure-ram.ps1`, `test/windows/e2e/_latency.ps1`, `test/windows/README.md`, `docs/windows/feature-checklist.md` 3→27; `docs/windows/ram-baseline.csv`, `docs/windows/latency-baseline.csv` G1→G2→27 (lead); `test/windows/vt-smoke/cases/<case>.sh` one owner per case (Task 3 creates the base cases; Tasks 7, 15 add their own case files); `test/windows/vt-smoke/ref/<case>.png` Task 3 for `requires=none` cases, the lead (wave batch) for the others; `test/windows/conpty-probe/*` 28 only; `docs/windows/SPEC.md` 27 (+ lead rulings).

Private message ids (`messages.zig`, Task 2; `WM_APP+1…+10` unchanged from M2): `+11` `WM_GHOSTTY_NOTIFY_CLICK` (msg window; wparam = surface id), `+12` reserved (no message: recovery uses msg-window timer 2 — pre-flight 16), `+13` `WM_GHOSTTY_SET_CONTENT` (surface; payload-free, wparam = present-target generation; the chain itself waits in `composition.SurfaceState.pending` — pre-flight 8), `+14` `WM_GHOSTTY_POSTED_DIALOG` (top-level; wparam = `DialogKind` (`export_io`, `config_errors`, `url_confirm`), lparam = heap payload), `+15` `WM_GHOSTTY_OVERLAY_CMD` (top-level; lparam = heap `overlay.Command` holding a deep copy of the action (`Action.clone`), freed by the handler — pre-flight 7). The uniqueness test range becomes `WM_APP+1 … WM_APP+31` (`+16…+31` reserved M4+).
Timer ids (`messages.timers`, per window class): msg window `1` quit (M1), `2` recovery debounce (Task 24); `GhosttySurface` `1` resize coalescer (M2), `2` bell border expiry (Task 6); `GhosttyWindow` `1` strip auto-scroll (M2), `2` quick-terminal slide (Task 17); `GhosttyOverlay` `1` hide after duration (labels, in-app toasts), `2` search debounce (Task 12); `GhosttyInspector` `1` 30 Hz render tick, also consumes the `render_inspector` dirty flag (Task 19); `GhosttyResizeOverlay` `1` hide (M2).

---

### Task 1: `pkg/win32` bindings for M3 (shared single-owner files) + new module shells

**Review:** light.

**Files:**
- Modify: `pkg/win32/user32.zig`, `pkg/win32/advapi32.zig`, `pkg/win32/dwmapi.zig`, `pkg/win32/gdi32.zig`, `pkg/win32/shell32.zig`, `pkg/win32/ole32.zig`, `pkg/win32/comctl32.zig`, `pkg/win32/main.zig`, `pkg/win32/build.zig`, `pkg/win32/test_user32.zig`
- Create: `pkg/win32/shlwapi.zig` (`AssocIsDangerous`, resolved on first use through `LoadLibraryExW(SYSTEM32)` + `GetProcAddress` like `comctl32.zig:97`); doc-comment-only shells registered in `main.zig`, owners fill them: `pkg/win32/dcomp.zig` (→ Task 8; `DCompositionCreateDevice2` resolved lazily, never imported), `pkg/win32/winrt.zig` (→ Task 18; `Ro*`/`Windows*String` resolved lazily from `combase.dll`), `pkg/win32/comdlg32.zig` (→ Task 20)
- Modify: `src/build/SharedDeps.zig` Windows link list += `comdlg32` only (KnownDLL; only for artifacts that import `win32`, as M2 Task 1 set up). `dcomp` and `runtimeobject` are **not** linked (pre-flight 3).

**Interfaces:**
- Produces:
  - `user32`: `RegisterHotKey UnregisterHotKey`, `WM_HOTKEY`, `MOD_ALT MOD_CONTROL MOD_SHIFT MOD_WIN MOD_NOREPEAT`, `MapVirtualKeyExW`, `MAPVK_VSC_TO_VK_EX`, `VkKeyScanExW` (if missing), `GetKeyboardLayout`, `MonitorFromPoint` flags `MONITOR_DEFAULTTOPRIMARY`, `SetWindowLongPtrW` index `GWLP_HWNDPARENT`, `WM_NCACTIVATE` (if missing), `EM_SETSEL EM_SETCUEBANNER`(`ECM_FIRST+1`) `EN_CHANGE EN_KILLFOCUS`, `WM_CTLCOLOREDIT`, `ES_LEFT`, `AllowSetForegroundWindow` (Task 17 IPC client).
  - `advapi32`: `RegCreateKeyExW RegSetValueExW RegCloseKey RegDeleteTreeW` (`RegDeleteTreeW`: the manual-toast cleanup of Tasks 18/27), `KEY_WRITE KEY_READ REG_SZ REG_OPTION_NON_VOLATILE`; **fix** `HKEY_CURRENT_USER` to the SDK's sign-extended value `0xFFFFFFFF80000001` on 64-bit (M2 Task 1 minor, required now that Task 18 writes HKCU).
  - `dwmapi`: `DwmEnableBlurBehindWindow`, `DWM_BLURBEHIND`, `DWM_BB_ENABLE DWM_BB_BLURREGION`, `DWMWA_WINDOW_CORNER_PREFERENCE` (if missing).
  - `gdi32`: `CreateRectRgn DeleteObject(region)`, `GetStockObject BLACK_BRUSH NULL_BRUSH`.
  - `shell32`: `ShellExecuteExW`, `SHELLEXECUTEINFOW` (x64 size 112), `SEE_MASK_NOASYNC SEE_MASK_FLAG_NO_UI SEE_MASK_NOCLOSEPROCESS`, `SetCurrentProcessExplicitAppUserModelID`, `SHOpenFolderAndSelectItems ILCreateFromPathW ILFree` (Task 10 reveal), `SHGetKnownFolderPath`-free (paths come from env).
  - `shlwapi`: `AssocIsDangerous` (lazy).
  - `ole32`: `CoInitializeEx CoUninitialize COINIT_APARTMENTTHREADED`, `CoTaskMemFree` (if missing).
  - `comctl32`: tooltip control `TOOLTIPS_CLASSW TTM_ADDTOOLW TTM_TRACKACTIVATE TTM_TRACKPOSITION TTM_UPDATETIPTEXTW TTM_SETMAXTIPWIDTH TTF_TRACK TTF_ABSOLUTE TTF_IDISHWND TTS_NOPREFIX TTS_ALWAYSTIP TOOLINFOW`.
- [ ] **Step 1: Failing tests** in `pkg/win32/test_user32.zig`:
  ```zig
  test "win32 shell32: SHELLEXECUTEINFOW size" { // 112 on x86_64 (provenance comment from a throwaway zig cc program) }
  test "win32 comctl32: TOOLINFOW size" { // 72 on x86_64 }
  test "win32 dwmapi: DWM_BLURBEHIND size" { // 20 }
  test "win32 advapi32: HKEY_CURRENT_USER is sign-extended" { // @intFromPtr(HKEY_CURRENT_USER) == 0xFFFFFFFF80000001 }
  test "win32 user32: RegisterHotKey roundtrip on a message window" { // MOD_CONTROL|MOD_ALT|MOD_SHIFT|MOD_NOREPEAT + VK_F9 on a HWND_MESSAGE window succeeds (or ERROR_HOTKEY_ALREADY_REGISTERED → SkipZigTest), UnregisterHotKey succeeds }
  test "win32 shlwapi: AssocIsDangerous flags .exe and not .txt" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 --build-file pkg/win32/build.zig` → FAIL.
- [ ] **Step 3: Implement** declarations; module shells; link list.
- [ ] **Step 4: Verify** package tests PASS; `LOCK ZIG build -j6` PASS; `LOCK ZIG build -j6 -Demit-lib-vt` PASS (lib-vt links none of the new libs).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M3 bindings (hotkeys, ShellExecuteEx, AUMID, blur-behind, tooltips, registry writes) and module shells"`

### Task 2: M3 skeleton — hooks fan-out, feature stubs, message ids, action wiring

**Review:** light (mechanical; reviewer checks every hook call site against the list below).

**Files:**
- Create: `src/apprt/win32/hooks.zig` (real fan-out); stubs (exact signatures below) `src/apprt/win32/{overlay,decor,hotkeys,visibility,QuickTerminal,notify,link,shell_open,SearchBar,CommandPalette,palette_filter,key_state,badges,app_toast,composition,config_errors,export_io,tab_menu,recovery}.zig`, `src/apprt/win32/inspector/Inspector.zig`
- Modify: `src/apprt/win32/messages.zig` (ids `+11…+15`, timer table, range test `+31`), `src/apprt/win32/actions.zig` (the 18 remaining M3 keys → `.implemented` — `open_url` is already implemented by M2 Task 34.4 —, arms call the feature stubs; coverage test pins 62 implemented / 6 deferred / 2 unsupported), `src/apprt/win32/ipc/ops.zig` (`toggle-quick-terminal` → `QuickTerminal.ipcToggle(app)`; `state` op appends `"m3": {…}` via `hooks.testState`; new test-only op `export-io` `{surface, text, path}` → `export_io.save(app, .{ .surface = … }, .{ .contents = text })` with `path` as the test-mode destination (pre-flight 13: in test mode `export_io` writes to `path` without a dialog and records `{path, bytes}` in `state.m3`), because core emits `export_terminal_io` only from the inspector's termio widget; replace the double-OOM `@panic` with a static response — M2 Task 11 minor), `src/apprt/win32/App.zig`, `src/apprt/win32/Window.zig`, `src/apprt/win32/Tab.zig`, `src/apprt/win32/Surface.zig` (hook calls + state fields only), `src/apprt/win32/actions/app_actions.zig` (`config_change` → `hooks.configChanged`; `reload_config` sets `app.reload_pending`), `src/apprt/win32/clipboard.zig` (`hooks.clipboardWritten` after a successful standard-clipboard write), `src/renderer/D3D11.zig` (`PresentTarget.decor: ?*const std.atomic.Value(u64) = null`), `src/apprt/win32.zig` (test imports of every new file)

**Interfaces:**
- Produces (later tasks replace bodies, never names or field types):
  ```zig
  // hooks.zig — real; each function calls the listed feature functions in this order
  pub fn appStarted(app: *App) void;              // end of App.init: hotkeys.appStarted, notify.appStarted, config_errors.appStarted
  pub fn appStopping(app: *App) void;             // start of App.terminate: hotkeys.appStopping, shell_open.appStopping (worker), Inspector.appStopping
  pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void;
      // decor, overlay, hotkeys, QuickTerminal, composition, notify, config_errors; app_toast.configReloaded when reloaded
  pub fn appMessage(app: *App, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;
      // msg window, before the default arm: WM_HOTKEY → hotkeys; WM_GHOSTTY_NOTIFY_CLICK → notify; WM_TIMER id 2 → recovery
  pub fn windowMessage(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;
      // FIRST in the Window dispatch chain (before frame.handle): overlay (WM_ACTIVATE/WM_NCACTIVATE keep-active), QuickTerminal (WM_ACTIVATE autohide, WM_TIMER 2),
      // WM_GHOSTTY_POSTED_DIALOG → export_io/config_errors/link; WM_GHOSTTY_OVERLAY_CMD → CommandPalette/SearchBar
  pub const WindowChange = enum { moved, sized, dpi, minimized, restored, activated, deactivated, destroying };
  pub fn windowChanged(window: *Window, change: WindowChange) void;  // overlay, QuickTerminal
  pub fn tabShown(tab: *Tab, shown: bool) void;                      // overlay
  pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void;  // overlay, composition (called at M2 Task 32's re-parent point)
  pub fn surfaceCreated(surface: *Surface) void;                     // decor, composition
  pub fn surfaceDestroying(surface: *Surface) void;                  // overlay, SearchBar, CommandPalette (closes the palette if this is its target), link, badges, key_state, Inspector, composition (before core deinit)
  pub fn surfaceFocus(surface: *Surface, focused: bool) void;        // decor, overlay (WM_SETFOCUS/WM_KILLFOCUS of the surface child)
  pub fn tabLayoutChanged(tab: *Tab) void;                           // decor — after every split insert/remove/zoom/equalize relayout and active-surface change in Tab.zig (pre-flight 6)
  pub fn surfaceRectChanged(surface: *Surface) void;                 // overlay (WM_WINDOWPOSCHANGED of the surface child)
  pub fn surfaceMessage(surface: *Surface, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_GHOSTTY_SET_CONTENT → composition; WM_TIMER 2 → decor
  pub fn clipboardWritten(surface: *Surface, cleared: bool) void;    // app_toast
  pub fn rendererHealth(surface: *Surface, health: apprt.action.RendererHealth) void; // badges, recovery
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;       // only with GHOSTTY_WIN32_TEST_IPC=1: "m3":{overlay,decor,notify,quick,search,palette,composition,hotkeys,health,opened,inspector}
  ```
  Per-object state fields added now with empty stub types the owners extend in their own files: `Surface.decor_word: std.atomic.Value(u64) = .init(0)` (passed as `PresentTarget.decor`), `Surface.search: SearchBar.State = .{}`, `Surface.link: link.State = .{}`, `Surface.badges: badges.State = .{}`, `Surface.key_state: key_state.State = .{}`, `Surface.decor: decor.State = .{}`, `Surface.composition: composition.SurfaceState = .{}`, `Surface.inspector: ?*Inspector.Inspector = null` (`Inspector` = `@import("inspector/Inspector.zig")`; file-level functions plus the nested `pub const Inspector` struct — pre-flight 17); `Window.kind: Kind = .normal` (`enum { normal, quick }`), `Window.overlays: overlay.WindowState = .{}`, `Window.palette: CommandPalette.State = .{}`, `Window.composition: composition.WindowState = .{}`; `App.hotkeys: hotkeys.State = .{}`, `App.quick: QuickTerminal.State = .{}`, `App.notify: notify.State = .{}`, `App.recovery: recovery.State = .{}`, `App.visibility: visibility.State = .{}`, `App.shell_open: shell_open.State = .{}`, `App.composition: composition.AppState = .{}`, `App.reload_pending: bool = false`.
  Action arms (stubs log `debug "M3 stub action=…"` and return `false`, except `open_url`): `toggle_quick_terminal` → `QuickTerminal.toggle(app)`; `toggle_visibility` → `visibility.toggle(app)`; `toggle_command_palette` → `CommandPalette.toggle(app, target)`; `inspector` → `Inspector.action(app, target, mode)`; `render_inspector` → `Inspector.render(app, target)`; `export_terminal_io` → `export_io.save(app, target, value)`; `desktop_notification` → `notify.desktop(app, target, value)`; `command_finished` → `notify.commandFinished(app, target, value)`; `mouse_over_link` → `link.hover(app, target, value)`; `open_url` → `link.open(app, target, value)`, whose stub body is M2 Task 34.4's allowlist code moved verbatim into `link.zig` (it returns `true` on every path, never `false` — pre-flight 1); `start_search`/`end_search`/`search_total`/`search_selected` → `SearchBar.start/end/total/selected(app, target, value)`; `key_sequence`/`key_table` → `key_state.sequence/table(app, target, value)`; `renderer_health` → `hooks.rendererHealth` (returns true); `readonly` → `badges.readonly(app, target, value)`; `toggle_background_opacity` → `composition.toggleOpacity(app, target)`.
  Stub-only files (doc comment + the hook functions above): `shell_open.zig`, `palette_filter.zig`, `tab_menu.zig` (`pub fn show(window: *Window, tab_index: usize, screen_x: i32, screen_y: i32) void` stub no-op).
- [ ] **Step 0: Re-check against landed M2** (pre-flight 32): M2 Tasks 21–39 and 34.4 landed after this plan was written (tray, Task 30 `PresentTarget.generation`, Task 32's re-parent point, Task 38's `drop.handle`, Task 39's device generation, 34.4's `open_url` arm). Re-check every hook site and every name used in this plan against the landed code; report diffs to the lead before Step 1 (the lead amends the plan in a one-line commit if needed).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 skeleton: M3 message ids are unique and keep M1/M2 values" { // +1..+15 distinct, ≤ WM_APP+31, M2 asserts kept }
  test "win32 skeleton: timer ids are unique per class incl. M3" {}
  test "win32 actions: every Action.Key is classified" { // 70 keys }
  test "win32 actions: M3 scope list" { // 62 implemented, 6 deferred (5 × M5, 1 × post-v1), 2 unsupported }
  test "win32 hooks: testState writes an m3 object" { // fake App with test IPC flag: output parses as JSON with key "m3" }
  test "win32 actions: open_url arm never returns false" { // refused (ms-msdt:), allowed and malformed URLs through the arm → true; 34.4's tests keep passing from their new home }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 skeleton"` (and `"win32 actions"`, `"win32 hooks"`) → FAIL.
- [ ] **Step 3: Implement** exactly as listed; no behaviour change for any M2 path (all stubs return false/no-op, `open_url` keeps 34.4's behaviour).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6` PASS; `LOCK ZIG build test -j6 -Dtest-filter="win32 "` PASS (no M2 regression).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M3 skeleton — hooks fan-out, feature stubs, message ids, action wiring"`

### Task 3: vt-smoke harness, feature checklist, measurement switches, harness minors

**Review:** light. **Runs GUI** (reference generation, WARP) — implementer takes the desktop lock through the runner.

**Files:**
- Create: `test/windows/vt-smoke.ps1`, `test/windows/vt-smoke/README.md`, `test/windows/vt-smoke/cases/{sgr-16,sgr-256,sgr-truecolor,styles,underlines,dec-graphics,box-drawing,wide-cjk,combining,cursor-erase,scroll-region,alt-screen,osc8-link,kitty-image,bg-image}.sh` (+ `kitty-16.png`, `bg.png` fixtures), `test/windows/vt-smoke/ref/<case>.png` (generated), `test/windows/lib/ImageCompare.psm1`, `test/windows/e2e/vt-smoke.ps1` (runner wrapper), `docs/windows/feature-checklist.md`
- Modify: `test/windows/measure-ram.ps1` (`-ExtraConfig <text>`, `-Actions <op:arg,…>` driven through `Invoke-GhosttyAction` — implies `GHOSTTY_WIN32_TEST_IPC=1`, today set only for `tabs|splits|zero-windows` at `measure-ram.ps1:130` —, `-Tag <name>` written to the CSV `scenario` column, `-Sample <label>@<op>[,…]` multi-point sampling: one CSV row per point with scenario `<tag>:<label>`, `<op>` an action or `wait:<seconds>` — pre-flight 12), `test/windows/e2e/_latency.ps1` + `input-latency.ps1` (`-ExtraConfig`, `-Splits 2`), `test/windows/lib/Harness.psm1` (`Get-FreeRamGb` counts standby list as available — M2 Task 4 minor), `test/windows/e2e.ps1` (lock-wait expiry written to `results.txt`; doc says test-lock — M2 Task 4 minors), `test/windows/README.md`

**Interfaces:**
- Produces:
  - `vt-smoke.ps1 [-Only a,b] [-Update] [-Driver warp|hardware] [-EvidenceDir d]`: per case writes an isolated config (`class = ghostty-vts-<hex>`, `font-size = 12`, `window-width = 100`, `window-height = 30`, `cursor-style-blink = false`, embedded font, `command = direct:<git bash> --noprofile --norc <case.sh>`; the case prints its sequences (each < 8 KiB, `printf` only — msys `cat` loses bytes, see memory note) then `exec sleep 600`), waits for a stable dump (two equal dumps 300 ms apart), converts the dump BMP to PNG, compares with `ref/<case>.png`. Header line per case `# vts: requires=<task|none> extra-config=<k=v;…>`; `requires` names the task or decision that makes the case meaningful (`T7` custom shader, `T15` transparency, `L1` for `kitty-image` and `osc8-link`, whose sequences Task 28 probes in parallel) — such a case SKIPs until its ref PNG exists; the lead generates those refs in the wave batch after the prerequisite lands. Exit 0 = all compared PASS/SKIP, 1 = any FAIL. `-Update` rewrites refs (lead inspects every changed PNG before commit).
  - `ImageCompare.psm1`: `Compare-Image -Actual <png|bmp> -Reference <png> [-Tolerance 24] [-MinMatch 0.995]` → `{ Match: double, MaxDiff: int, MeanDiff: double, DiffPng: path }` (System.Drawing, Windows PowerShell 5.1 compatible; per-channel absolute difference; writes a red diff image on failure).
  - `feature-checklist.md`: table `| Feature | Milestone | Evidence | Status |` with one row per feature of DECISIONS "Features" + SPEC §17 M1–M3 (≈ 70 rows: VT basics, SGR, OSC 8, OSC 52, Kitty keyboard, Kitty graphics, bg image, custom shaders, fonts/fallback/emoji, ligatures, themes, conditional config, config reload, keybinds/key tables/sequences, global keybinds, tabs, splits, windows, quick terminal, palette, search, inspector, notifications, URL hover/open, resize overlay, scrollbar, bell, progress, transparency/blur, readonly, drag-drop files/text, IME, dead keys, clipboard, …); M1/M2 rows point at existing scenarios/tests; M3 rows say `pending → Task N`.
- [ ] **Step 1: Failing test** `Compare-Image` self-test script `test/windows/vt-smoke/selftest.ps1` (identical image → Match 1.0; one changed pixel at diff 200 → MaxDiff 200, Match < 1; size mismatch → error) → FAIL before the module exists.
- [ ] **Step 2: Run** `powershell -NoProfile -File test/windows/vt-smoke/selftest.ps1` → FAIL.
- [ ] **Step 3: Implement**; generate references with `-Driver warp -Update` for every `requires=none` case; inspect each PNG (attach paths in the report).
- [ ] **Step 4: Verify** selftest PASS; `vt-smoke.ps1 -Driver warp` twice in a row → all PASS (determinism); `measure-ram.ps1 -Scenario one-surface -ExtraConfig "font-size = 14" -Tag smoke-check` writes one row tagged `smoke-check`, and `-Tag smoke-check -Sample a@wait:1,b@toggle_readonly` writes rows `smoke-check:a` and `smoke-check:b` (rows removed before commit).
- [ ] **Step 5: Commit** `git commit -m "test(windows): vt-smoke screenshot checks, feature checklist, RAM/latency config switches"`

### Task 4: Shadertoy → HLSL through SPIRV-Cross (core)

**Review:** light.

**Files:** Modify `pkg/spirv-cross/build.zig` (Windows-gated: `spirv_hlsl.cpp` + `-DSPIRV_CROSS_C_API_HLSL=1`), `src/renderer/shadertoy.zig` (`Target.hlsl`, `hlslFromSpv`, tests); conditionally `src/global.zig` (see Step 3).

**Interfaces:**
- Produces:
  ```zig
  // shadertoy.zig
  pub const Target = enum { glsl, msl, hlsl };
  pub fn hlslFromSpv(alloc: Allocator, spv: []const u8) ![:0]u8;
      // SPVC_BACKEND_HLSL, SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL = 50; UBO Globals → register(b1), iChannel0 → Texture2D t0 + SamplerState s0
      // (SPIR-V binding decorations; spvc_compiler_hlsl_add_resource_binding only if the defaults differ); entry "main", input SV_Position, output SV_Target0
  ```
  `loadFromFile(…, .hlsl)` dispatches to it. Non-Windows targets: `.hlsl` returns `error.UnsupportedTarget` (backend not compiled in).
- [ ] **Step 1: Failing tests** in `shadertoy.zig` (Windows-only where marked):
  ```zig
  test "shadertoy hlsl: crt and focus test shaders convert" { // Windows: output contains "register(b1)", "register(t0)", "register(s0)", "SV_Position", "SV_Target"; no "#version" }
  test "shadertoy hlsl: uniform packoffsets match shadertoy.Uniforms" { // parse every ": packoffset(cN.x)" of the Globals cbuffer → byte offset == @offsetOf(Uniforms, field) for all fields (iPalette[256], iChannelResolution[4] included) }
  test "shadertoy hlsl: invalid shader fails cleanly" { // test_shadertoy_invalid.glsl → error, no leak }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="shadertoy"` → FAIL.
- [ ] **Step 3: Implement.** Then measure `glslang.init()` cost: log `Device.logPrivateUsage`-style private bytes before/after it in a ReleaseFast run (one `ghostty.exe +version` is not enough — use the M2 private-usage log of a 1-surface start). If > 0.5 MB: make it lazy (platform-neutral: `std.once`-style init on the first `spirvFromGlsl`, removed from `global.zig`), with test `"shadertoy: lazy glslang init happens once across threads"`.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; the Linux cross recipe `LOCK ZIG build -j6 -Dtarget=x86_64-linux-gnu -Dapp-runtime=none` PASS (HLSL backend not compiled there).
- [ ] **Step 5: Commit** `git commit -m "feat(shadertoy): HLSL target through SPIRV-Cross for the D3D11 backend"` (+ `perf(global): lazy glslang init` if applied, numbers in the body).

### Task 5: DirectWrite font discovery and `MapCharacters` fallback

**Review:** opus (COM object implemented in Zig, called from UI and render threads).

**Files:**
- Create: `src/font/directwrite.zig`, `test/windows/e2e/font-fallback.ps1`
- Modify: `src/font/discovery.zig` (Windows struct: DirectWrite first, M1 index fallback), `pkg/win32/dwrite.zig` (append), `src/font/DeferredFace.zig` (only if the `.win` payload needs a field; keep path + face index), M1 Task 12 minors in the index code (`discovery.zig` Windows index: shared strings instead of per-face duplicates — only if the index stays reachable)

**Interfaces:**
- Consumes: `discovery.Descriptor`, `DeferredFace.win`, `WindowsFontFile` (UTF-16 file mapping → FreeType memory face).
- Produces:
  ```zig
  // pkg/win32/dwrite.zig (append; full slots + slot tests): IDWriteFactory2 (GetSystemFontFallback), IDWriteFontCollection (complete),
  //   IDWriteFontFamily, IDWriteFontList, IDWriteFont, IDWriteFont1 (IsMonospacedFont), IDWriteFontFace (GetFiles, GetIndex),
  //   IDWriteFontFile, IDWriteFontFileLoader, IDWriteLocalFontFileLoader, IDWriteLocalizedStrings, IDWriteFontFallback (MapCharacters),
  //   IDWriteTextAnalysisSource (vtable type for a Zig-implemented object), IID_IDWriteLocalFontFileLoader, DWRITE_FONT_WEIGHT/STYLE/STRETCH,
  //   DWRITE_INFORMATIONAL_STRING_FULL_NAME; fix DWRITE delimiterCount to u32 per SDK (M2 Task 7 minor)
  // src/font/directwrite.zig
  pub const DirectWrite = struct {
      pub fn init() ?DirectWrite;                 // shared factory (DWriteCreateFactory SHARED) + system collection; null on failure → M1 index
      pub fn deinit(self: *DirectWrite) void;
      pub fn discover(self: *const DirectWrite, alloc: Allocator, desc: Descriptor) !Iterator;      // family (localized + full names), bold/italic/style name, monospace, codepoint; best match first
      pub fn fallback(self: *const DirectWrite, alloc: Allocator, base_family: ?[]const u8, desc: Descriptor) !Iterator; // MapCharacters(cp) unless desc.presentation == .emoji
      pub const Iterator = struct { pub fn next(self: *Iterator) !?DeferredFace; pub fn deinit(self: *Iterator) void };
  };
  // A font whose file loader is not IDWriteLocalFontFileLoader (cloud/remote) is skipped with log.debug.
  ```
- [ ] **Step 1: Failing tests** (Windows only; real system fonts):
  ```zig
  test "windows directwrite: Consolas styles map to their files" { // regular/bold/italic/bold-italic → consola.ttf, consolab.ttf, consolai.ttf, consolaz.ttf }
  test "windows directwrite: unknown family yields nothing" {}
  test "windows directwrite: full name lookup" { // "Consolas Bold" resolves to consolab.ttf }
  test "windows directwrite: CJK fallback picks a Japanese face" { // U+3042 → family in {"Yu Gothic","Yu Gothic UI","Meiryo","MS Gothic","Microsoft YaHei"} }
  test "windows directwrite: emoji presentation is not routed" { // U+1F600 with presentation emoji → empty iterator }
  test "windows directwrite: fallback from two threads" { // 2 threads × 200 MapCharacters of mixed codepoints → no crash, same results }
  test "windows directwrite: iterate all families for +list-fonts" { // count > 50 }
  test "win32 dwrite: M3 interface slot counts" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="windows directwrite"` → FAIL.
- [ ] **Step 3: Implement**; `discovery.Windows.discover/discoverFallback` use `DirectWrite` when `init` succeeded. The text-analysis source object is stack/heap owned by the call (refcount honoured, never freed while DWrite holds it).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; `zig-out\bin\ghostty.exe +list-fonts | head` through Git Bash shows system families; record in the report: first `discover` and per-codepoint fallback times from a unit-test harness (`-Doptimize=ReleaseFast -Dtest-filter="windows directwrite"` with timing output; budget first ≤ 50 ms, fallback ≤ 5 ms). No GUI RAM run: the `font-consolas-m1` row is recorded by the lead at G1 before this task lands and the DirectWrite row at Task 27 (pre-flight 11). Scenario `font-fallback` (order 510): Git Bash prints `あ漢字한글 ☃ ∑ ⌘`; dump shows non-background pixels in each of those cells; log shows `directwrite fallback family=`.
- [ ] **Step 5: Commit** `git commit -m "feat(font): DirectWrite discovery and MapCharacters fallback on Windows"`

### Task 6: Decor pass — unfocused-split dimming and `bell-features = border` (+ core redraw request)

**Review:** opus (render-thread/UI-thread hand-off, latency of the default path).

**Files:**
- Create: `src/renderer/d3d11/Decor.zig`, `src/renderer/shaders/hlsl/decor.hlsl`, `test/windows/e2e/split-dim.ps1`, `test/windows/e2e/bell-border.ps1`
- Modify: `src/renderer/D3D11.zig` (read `PresentTarget.decor` each frame), `src/renderer/d3d11/Frame.zig` (decor draw on the target before the backbuffer copy; gate the dump `before_write` test hook with `builtin.is_test` — M2 Task 4 minor), `src/renderer/d3d11/hlsl.zig` (decor entry in the warmup list), `src/apprt/win32/decor.zig` (replace stub), `src/apprt/win32/bell.zig` (`border` feature)
- Modify (core, platform-neutral): `src/renderer/message.zig` (`redraw`), `src/renderer/Thread.zig` (handle it), `src/renderer/generic.zig` (`force_redraw` counted in `needs_redraw`), `src/Surface.zig` (`pub fn queueRedraw(self: *Surface) void`)

**Interfaces:**
- Produces:
  ```zig
  // decor.zig (apprt)
  pub const Word = packed struct(u64) { dim_alpha: u8 = 0, dim_rgb: u24 = 0, border: bool = false, border_px: u7 = 0, border_rgb: u24 = 0 };
  pub fn compute(in: struct { tab_surfaces: usize, focused_in_tab: bool, zoomed_other: bool, bell_border: bool,
      opacity: f64, fill: ?Color, background: Color, bell_color: Color, dpi: u32 }) Word;   // pure
      // focused_in_tab = (surface == tab.activeSurface()), independent of Win32 keyboard focus and window activation (search bar, palette,
      //   dialogs or a deactivated window never dim the active split — GTK dims by the split tree's focused surface; pre-flight 6)
      // dim iff tab_surfaces ≥ 2 and !focused_in_tab; dim_alpha = round(255 × (1 − clamp(opacity, 0.15, 1))); fill defaults to background;
      // border_px = scale(2, dpi); bell_color = the theme's accent (palette.text at full alpha)
  pub fn refreshTab(tab: *Tab) void;      // recompute every surface of the tab, store, queueRedraw on change
  pub fn surfaceFocus(surface: *Surface, focused: bool) void;  // hook: refreshTab; focus-in also clears bell_border
  pub fn tabLayoutChanged(tab: *Tab) void;                     // hook: refreshTab (split insert/remove/zoom/equalize, active-surface change)
  pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void;  // refresh all
  pub fn surfaceMessage(...) ?LRESULT;    // WM_TIMER 2: bell border expiry
  pub const State = struct { bell_border: bool = false };
  // bell.zig: `border` in bell-features → surface.decor.bell_border = true + decor.refreshTab; when the surface is focused at ring time the border expires after 1 s (timer 2)
  // Decor.zig (renderer): pipeline full_screen VS + decor PS (cbuffer b2 {dim rgba, border rgba, border_px, size}); draw(target, word) does nothing when word == 0
  // core: Surface.queueRedraw() sends renderer message .redraw and wakes the renderer thread; generic draws one frame even if no cells changed
  ```
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 decor: dims only unfocused surfaces of multi-split tabs" {}
  test "win32 decor: opacity 1 means no dim; fill defaults to background" {}
  test "win32 decor: bell border word" {}
  test "win32 decor: window deactivation does not dim the active split" { // surfaceFocus(active, false) with tab unchanged → word of the active surface stays 0 }
  test "win32 decor: split insert without focus change refreshes the tab" { // tabLayoutChanged after a 1→2 split → the inactive one dims }
  test "d3d11 decor: dim blends the fill colour" { // WARP target cleared black; word dim_alpha 0x4D fill white → pixel ≈ 0x4D ±1 }
  test "d3d11 decor: border touches only edge pixels" { // 64×32 target, border_px 2 → (0,0) and (1,1) coloured, (2,2) unchanged }
  test "d3d11 decor: zero word draws nothing" { // draw call counter 0 }
  test "renderer: redraw message forces one draw" { // headless D3D11 (WARP) renderer: a second drawFrame without changes presents nothing; after .redraw it presents once }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="d3d11 decor"`, `-Dtest-filter="renderer: redraw"`, and `LOCK ZIG build test -j6 -Dtest-filter="win32 decor"` → FAIL.
- [ ] **Step 3: Implement.** Scenarios: `split-dim` (order 520, `surfaces=2`): two splits, focus left → the right split's dump pixel at an empty cell = blend(bg, fill, 0.3) ±3, left unchanged; focus right → swapped; `unfocused-split-opacity = 1` → no change. `bell-border` (order 525): `bell-features = border`, a bell in the unfocused split → edge pixels of its dump in the bell colour; focusing it clears them.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`; scenarios parse.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): decor pass for unfocused-split dimming and bell border; core redraw request"`

### Task 7: Custom shaders on D3D11

**Review:** light (opus if Step 3 needs a generic change — then it becomes a lead `7.1` task).

**Files:** Modify `src/renderer/D3D11.zig` (`custom_shader_target = .hlsl`; `textureOptions` render-target + shader-resource; `samplerOptions` linear clamp), `src/renderer/d3d11/shaders.zig` (post pipelines), `src/renderer/d3d11/hlsl.zig` (`compileSource` for runtime sources with a SHA-256-keyed bytecode cache; failed compiles cached; D3DCompile warnings logged at debug on success — M1 Tasks 2/11 minors), `src/renderer/d3d11/buffer.zig` (constant-role `initFill` for any size ≤ 64 KiB rounded to 16 — M1 Task 8 minor, now reachable: `shadertoy.Uniforms` ≈ 4.7 KB), `src/renderer/d3d11/Texture.zig` (RTV when render-target usage), `src/renderer/d3d11/RenderPass.zig` (texture attachments), `src/renderer/d3d11/Frame.zig` (post passes before decor), `pkg/win32/d3dcompiler.zig` (error/warning blob text); Create `test/windows/vt-smoke/cases/custom-shader.sh` + `test/windows/vt-smoke/shaders/invert.glsl`, `test/windows/e2e/custom-shader.ps1` (`ref/custom-shader.png` is generated by the lead in the wave batch — pre-flight 11)

**Interfaces:**
- Consumes: Task 4 `hlslFromSpv`; generic `CustomShaderState` (front/back textures, sampler, `has_custom_shaders`), `animationWake`.
- Produces: `hlsl.compileSource(source: [:0]const u8, entry: [:0]const u8, profile: [:0]const u8) ![]const u8` (process cache `{sha256 → bytecode | failure}`); post pipelines = `full_screen` VS + user PS, blending on; ping-pong per generic; the final post pass writes the frame `Target`; decor (Task 6) after it.
- [ ] **Step 1: Failing tests** (WARP)
  ```zig
  test "d3d11 custom shader: crt test shader compiles to ps_5_0" { // shadertoy.loadFromFile(crt, .hlsl) → compileSource OK }
  test "d3d11 custom shader: invert shader renders inverted background" { // headless renderer, bg #102030, invert.glsl → target pixel #EFDFCF ±2 }
  test "d3d11 custom shader: fragCoord y is down" { // gradient-by-y shader: row 0 darker than last row }
  test "d3d11 custom shader: same source compiles once" { // two pipelines from one source → compile counter 1 }
  test "d3d11 custom shader: failed compile is cached and logged once" {}
  test "d3d11 buffer: constant role initFill of 4.7 KB" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="d3d11 custom shader"` (and `"d3d11 buffer"`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `custom-shader` (order 530): `custom-shader = <invert.glsl>` → dump background pixel inverted; a second config with a broken shader → log error, normal rendering, no crash; `custom-shader-animation = true` with an iTime shader → dumps differ over 1 s; with `false` idle CPU of the process over 10 s within +0.5 % of the no-shader run (recorded). vt-smoke case `custom-shader` (`requires=T7`), `.sh` + header only.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; RAM: lead measures at G1 with `measure-ram.ps1 -ExtraConfig "custom-shader = …" -Tag custom-shader`.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): user custom shaders (shadertoy GLSL → HLSL) with post-pass ping-pong"`

### Task 8: Transparency spike — DComp child targets, transparent client, Acrylic, re-parenting (risk R10)

**Review:** opus (decides R-M3-2/3 details). **Runs GUI** (own spike window, never `ghostty.exe`).

**Files:** Modify `pkg/win32/dcomp.zig` (`DCompositionCreateDevice2` resolved lazily from System32 — never a static import, `IDCompositionDevice` (full slots), `IDCompositionTarget`, `IDCompositionVisual` (full slots), IIDs, slot tests), `pkg/win32/dxgi.zig` (type `IDXGIFactory2.CreateSwapChainForComposition`; `DXGI_ALPHA_MODE_PREMULTIPLIED`), `pkg/win32/build.zig` (add the spike test file); Create `pkg/win32/test_composition_spike.zig`, `test/windows/composition-spike/run.ps1`, `test/windows/composition-spike/RESULT.md` (evidence: numbers, screenshots of the spike window only)

**Interfaces:**
- Produces evidence for each check (PASS/FAIL + numbers): (a) child-HWND `CreateTargetForHwnd(child, TRUE)` + visual with a premultiplied composition swap chain created on a worker ("render") thread and `SetContent`+`Commit` on the UI thread; present + `ResizeBuffers` on the worker keep working; (b) transparent client: `DwmExtendFrameIntoClientArea(-1)` + `DWMSBT_NONE` + alpha-0 paint shows the backdrop window through alpha-0 swap-chain pixels — else the `DwmEnableBlurBehindWindow` empty-region variant; record which works on this build; (c) `DWMSBT_TRANSIENTWINDOW` (Acrylic) behind the transparent swap chain, with "Transparency effects" on (screenshot) — off is the owner's manual check; (d) a D2D DC-painted strip over the extended frame stays readable in (b) and (c); (e) `SetParent` of the child to another top-level: does the DComp target survive? (if not, Task 15 recreates it in `tabReparented`); (f) `PrintWindow` vs screen-rect capture of the composed result; (g) waitable-object pacing on a composition swap chain (wait times over 300 frames, same as hwnd mode ±1 ms); (h) private bytes: DComp device, per target+visual; (i) maximize, DPI 144 via `SetWindowPos` to a scaled rect, minimize/restore; (j) the same child HWND: hwnd-mode flip chain → released → `CreateTargetForHwnd` + composition chain → released → hwnd-mode chain again: no `DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED`, no black frame longer than one refresh (pre-flight 9); (k) `CreateSwapChainForComposition` with `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING` + `Present(0, DXGI_PRESENT_ALLOW_TEARING)`: accepted or not (Task 14 drops the flag in composition mode if not); (l) a DComp device from `DCompositionCreateDevice2(null, …)` (no rendering device) keeps working after the D3D device used for the chains is released and recreated (pre-flight 25).
- [ ] **Step 1: Failing tests** `"win32 dcomp: interface slot counts"`, `"win32 dxgi: CreateSwapChainForComposition typed"` (WARP: creating a 64×64 premultiplied composition swap chain succeeds).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 --build-file pkg/win32/build.zig -Dtest-filter="win32 dcomp"` → FAIL.
- [ ] **Step 3: Implement** bindings + spike; run `run.ps1` (under the GUI lock); write `RESULT.md`.
- [ ] **Step 4: Verify** slot tests PASS; `RESULT.md` answers (a)–(l); the lead records the verdict (backdrop variant, re-parent behaviour) as SPEC §18 rulings before Task 15 starts.
- [ ] **Step 5: Commit** `git commit -m "test(windows): DirectComposition transparency spike and bindings"`

### Task 9: Overlay host — owned popups that follow the window (+ chrome/overlay DeviceLost minors)

**Review:** opus (window activation, z-order, re-parenting).

**Files:** Modify (replace stub) `src/apprt/win32/overlay.zig`; Modify `src/apprt/win32/resize_overlay.zig` (moves onto the host; owned popup without `HWND_TOPMOST`; `paintLabel` DeviceLost retry + log once — M2 Task 24 minors), `src/apprt/win32/Chrome.zig` (recreate the shared DC render target on `D2DERR_RECREATE_TARGET`; GDI fallback writes opaque alpha over Mica; `BufferedPaintInit` undone on init error paths — M2 Task 18 minors); Create `test/windows/e2e/overlay-follow.ps1`

**Interfaces:**
- Produces:
  ```zig
  pub const Anchor = enum { surface_top_right, surface_top_full, surface_bottom_left, surface_bottom_right, surface_bottom_center,
      window_top_center, window_bottom_center };
  pub const Kind = enum { label, panel };   // label: WS_EX_LAYERED|TRANSPARENT|NOACTIVATE|TOOLWINDOW, UpdateLayeredWindow, never focus;
                                            // panel: opaque WS_POPUP|WS_EX_TOOLWINDOW, rounded corners (DWMWCP_ROUND), buffered paint + D2D, may host EDIT children
  pub const Popup = struct {
      kind: Kind, anchor: Anchor, window: *Window, surface: ?*Surface,
      size: geom.Size,                   // logical px at 96 dpi; scaled by window.dpi
      margin: i32 = 8,
      paint: *const fn (p: *Popup, ctx: PaintContext) void,   // D2D on the shared DC target; ctx has rect, dpi, palette
      on_message: ?*const fn (p: *Popup, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT = null,
      hwnd: ?HWND = null, visible: bool = false, avoid_cursor: bool = false,  // bottom_left label flips to bottom_right under the cursor
      pub fn show(p: *Popup) !void; pub fn hide(p: *Popup) void; pub fn invalidate(p: *Popup) void;
      pub fn setSize(p: *Popup, size: geom.Size) void; pub fn destroy(p: *Popup) void;
      pub fn hideAfter(p: *Popup, ms: u32) void;               // GhosttyOverlay timer 1
  };
  pub fn rectFor(anchor: Anchor, surface_screen: geom.Rect, window_client_screen: geom.Rect, size_px: geom.Size, margin_px: i32,
      cursor: ?geom.Point) geom.Rect;     // pure; clamps inside the anchor rect
  pub fn beginPanelActivation(window: *Window) void;           // panels call it before SetFocus(edit)
  // hooks: windowChanged (reposition all; hide on minimized, show back on restored), tabShown (hide/show popups of the tab's surfaces),
  //   tabReparented (SetWindowLongPtrW(GWLP_HWNDPARENT, to.hwnd) + reposition), surfaceDestroying (destroy its popups),
  //   surfaceRectChanged (reposition that surface's popups), windowMessage: WM_ACTIVATE(WA_INACTIVE, lparam = own panel) and the
  //   matching WM_NCACTIVATE(FALSE) are swallowed so the owner keeps its active look and Window.active stays true
  pub const WindowState = struct { popups: std.ArrayList(*Popup) = .empty, panel_activation: bool = false };
  ```
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 overlay: rectFor anchors" { // each anchor at dpi 96 and 144; clamped when the surface is smaller than the popup }
  test "win32 overlay: bottom-left label avoids the cursor" {}
  test "win32 overlay: popups follow a moved owner" { // hidden test owner + label popup: SetWindowPos(owner) → windowChanged(.moved) → popup rect moved by the same delta }
  test "win32 overlay: re-owning on tab re-parent" { // GetWindow(popup, GW_OWNER) == new owner }
  test "win32 overlay: panel activation keeps the owner active" { // show panel, SetFocus(edit) → owner Window.active still true }
  test "win32 chrome: shared target recreated after RECREATE_TARGET" { // fake HRESULT path via test hook → second paint succeeds }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 overlay"` (and `"win32 chrome"`) → FAIL.
- [ ] **Step 3: Implement**; `resize_overlay` uses the host (behaviour unchanged; its scenario keeps passing). Scenario `overlay-follow` (order 535; uses the read-only badge, so it SKIPs with "needs Task 11" until `badges.zig` is real): badge shown via `action toggle_readonly`; window moved by `SetWindowPos` → badge rect moved by the same delta; minimized → badge hidden, restored → shown; the tab dragged out into a new window (M2 `tab-drag` helpers) → badge owner is the new window and positioned on it.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): overlay host for owned popups; chrome target recreation and overlay minors"`

### Task 10: Links — hover label, `open_url`, `shell_open` (+ `open_config` via `ShellExecuteExW`)

**Review:** opus (security).

**Files:** Modify (replace stubs) `src/apprt/win32/link.zig` (holds M2 Task 34.4's allowlist after Task 2; this task moves the validation into `shell_open.zig` and widens it per R-M3-8, keeping 34.4's tests green), `src/apprt/win32/shell_open.zig`; Modify `src/apprt/win32/actions/app_actions.zig` (`open_config` → `shell_open.openPath`, notepad fallback kept — M2 Task 15 minor); Create `test/windows/e2e/link-hover-open.ps1`

**Interfaces:**
- Consumes: M2 Task 34.4 (allowlist, `open.zig` refusal), Task 23 (`Surface` pwd).
- Produces:
  ```zig
  // shell_open.zig
  pub const Verdict = union(enum) { open: []const u8, reveal: []const u8, confirm: []const u8, refuse: []const u8 /* reason */ };
  pub const Env = struct { // injected so validate stays pure and table-testable
      pwd: ?[]const u8, userprofile: []const u8,
      exists: *const fn ([]const u16) bool, drive_type: *const fn ([]const u16) u32 /* GetDriveTypeW */,
      full_path: *const fn (Allocator, []const u16) anyerror![]u16 /* GetFullPathNameW */, is_dangerous: *const fn ([]const u16) bool /* AssocIsDangerous */ };
  pub fn validate(alloc: Allocator, kind: apprt.action.OpenUrl.Kind, url: []const u8, env: Env) !Verdict; // pure, R-M3-8:
      // percent-decode file: once; resolve /c/x, ~, relative against env.pwd; refuse ADS ':' / \\?\ / \\.\ / UNC / DOS device names /
      // non-fixed-or-removable drives; reveal by extension after stripping trailing dots and spaces, or is_dangerous
  pub fn submit(app: *App, surface_id: u32, kind: apprt.action.OpenUrl.Kind, url: []const u8) void;
      // copies url; the lazy worker thread (STA, queue ≤ 8) runs validate with the real Env (exists/drive checks never on the UI thread)
      // and acts: open → ShellExecuteExW NOASYNC|FLAG_NO_UI; reveal → SHOpenFolderAndSelectItems(ILCreateFromPathW(path)) (no explorer.exe
      // command line); confirm → posts WM_GHOSTTY_POSTED_DIALOG(url_confirm) to the window of surface_id (dropped if the surface is gone);
      // full queue → refuse + log. Test mode: every verdict is recorded into state.opened; the confirm TaskDialog IS shown, and "Yes" records
      // {url, verdict: confirm, outcome: accepted} instead of opening, Esc/"No" records outcome: cancelled (pre-flight 22)
  pub fn appStopping(app: *App) void;                // hook: drain/stop the worker
  pub fn openPath(app: *App, path: []const u8) void; // open_config: ShellExecuteExW("open"); failure/no association → notepad.exe <path>
  pub const State = struct { … worker, queue, recorded: [8]?Recorded };
  // link.zig
  pub fn hover(app: *App, target: apprt.Target, value: apprt.action.MouseOverLink) !bool; // label popup (overlay .label, surface_bottom_left, avoid_cursor);
      // empty url hides; text middle-ellipsized to 80 chars; follows GTK's link-previews handling
  pub fn open(app: *App, target: apprt.Target, value: apprt.action.OpenUrl) !bool;        // C0/C1 + length check → submit; returns true for every
      // verdict and every error (OOM, full queue, no surface) — never false (Global Constraints)
  pub const State = struct { label: ?*overlay.Popup = null };
  ```
- [ ] **Step 1: Failing tests** (`"win32 shell_open: …"`, one table row each, fake `Env`): `https://a.b/c` open (osc8); `javascript:alert(1)` confirm; `ms-msdt:/id x` confirm; `search-ms:query=x` confirm; `file:///C:/x/a.txt` open when it exists, refuse when not; `file:///C:/x/run.exe` and `C:\x\a.ps1` reveal; `\\srv\share\a.txt` and `file://srv/share/a` and `\\?\UNC\srv\s\a` refuse; URL with `\n` or U+0085 refuse; 2049 bytes refuse; `text` kind with a bare path opens without the checks except UNC; mixed-case schemes (`HtTpS:`) open; `C:\x\file.TXT.exe` reveal. Pre-flight 4 rows: `C:\x\a.exe.` and `C:\x\a.exe ` reveal; `C:\x\a.txt:evil.exe` refuse; `file:///C:/x/a.%65xe` reveal; `file:///%5C%5Csrv/s/a` refuse; `C:\x\CON`, `C:\x\nul.txt`, `\\.\C:\x`, `\\?\GLOBALROOT\x`, `\\?\C:\x\a.txt` refuse; 8.3 `C:\PROGRA~1\x\a.exe` reveal (extension check on the full path); `.settingcontent-ms`, `.library-ms`, `.searchConnector-ms`, `.diagcab`, `.appref-ms`, `.website`, `.theme`, `.themepack`, `.iso`, `.img`, `.vhd`, `.vhdx`, `.xll`, `.inf`, `.scf`, `.sct`, `.wsc`, `.msp`, `.docm` reveal; an unlisted extension with `is_dangerous` true reveal; `Z:\a.txt` with `drive_type` = `DRIVE_REMOTE` refuse; `unknown` kind `src/main.zig` with pwd `/c/repo` → open `C:\repo\src\main.zig`; `~/a.txt` → `%USERPROFILE%\a.txt`; `/c/x/a.txt` → `C:\x\a.txt`; relative path with no pwd refuse. `"win32 link: label text ellipsis"`, `"win32 link: open returns true for refuse and on worker-queue overflow"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 shell_open"` (and `"win32 link"`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `link-hover-open` (order 550; test IPC on, so nothing is launched): Git Bash prints an OSC 8 link; mouse moved over it → a visible `GhosttyOverlay` label of the pid within 500 ms; moved away → hidden; Ctrl+click → `state.m3.opened` holds the URL with verdict `open`; an OSC 8 `ms-settings:` link → the confirm TaskDialog appears, the script presses `Esc` → recorded `{verdict: confirm, outcome: cancelled}`. If L1 recorded OSC 8 as dropped by ConPTY, the scenario uses a detected plain-text URL instead and the OSC 8 steps are an owner-approved gap.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): link hover label and validated open_url/open_config through ShellExecuteEx"`

### Task 11: Status overlays — key sequence/table indicator, read-only badge, renderer-health bar, in-app toasts

**Review:** light.

**Files:** Modify (replace stubs) `src/apprt/win32/key_state.zig`, `src/apprt/win32/badges.zig`, `src/apprt/win32/app_toast.zig`; Create `test/windows/e2e/status-overlays.ps1`

**Interfaces:**
- Produces:
  ```zig
  // key_state.zig — mirrors GTK key_state_overlay.zig: label at surface_bottom_center, "<table> · ctrl+a › b", hidden when empty
  pub fn sequence(app: *App, target: apprt.Target, value: apprt.action.KeySequence) !bool;
  pub fn table(app: *App, target: apprt.Target, value: apprt.action.KeyTable) !bool;
  pub fn format(alloc: Allocator, tables: []const []const u8, triggers: []const input.Binding.Trigger) ![]u8; // pure
  // badges.zig
  pub fn readonly(app: *App, target: apprt.Target, value: apprt.action.Readonly) !bool;   // label surface_top_right: lock glyph (Segoe Fluent U+E72E) + "Read-only"
  pub fn health(surface: *Surface, health: apprt.action.RendererHealth) void;            // panel-less label surface_top_full, warning palette:
      // "Rendering paused: the GPU was reset. Recovering…"; hidden on .healthy; text switched by recovery.zig to the final-failure message
  pub fn setHealthText(surface: *Surface, text: []const u8) void;
  // app_toast.zig — label window_bottom_center, hideAfter(2000): "Copied to clipboard" / "Cleared clipboard" / "Reloaded the configuration",
  //   gated by app-notifications (clipboard-copy, config-reload), standard clipboard only
  pub fn clipboardWritten(surface: *Surface, cleared: bool) void;
  pub fn configReloaded(app: *App) void;
  ```
- [ ] **Step 1: Failing tests** `"win32 key_state: format"` (table + 3 triggers; empty → ""), `"win32 badges: health text by state"`, `"win32 app_toast: gated by app-notifications"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 key_state"` (and `badges`, `app_toast`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `status-overlays` (order 560): `keybind = ctrl+shift+a>x=new_split:right` → after `ctrl+shift+a` a visible key-state label, after `x` hidden and a new split exists; `action toggle_readonly` → badge visible, again → hidden; copy a selection (`copy_to_clipboard` via action op after `select_all`) → in-app toast visible ≤ 500 ms, gone after 2.5 s (clipboard backed up/restored by the runner).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): key sequence indicator, read-only badge, renderer health bar, in-app toasts"`

### Task 12: Search bar

**Review:** light.

**Files:** Modify (replace stub) `src/apprt/win32/SearchBar.zig`; Create `test/windows/e2e/search.ps1`

**Interfaces:**
- Produces:
  ```zig
  pub const State = struct { popup: ?*overlay.Popup = null, edit: ?HWND = null, total: ?usize = null, selected: ?usize = null, needle: std.ArrayList(u8) = .empty };
  pub fn start(app: *App, target: apprt.Target, value: apprt.action.StartSearch) !bool; // panel at surface_top_right (size 360×40 @96):
      // EDIT (dark: SetWindowTheme DarkMode_Explorer + WM_CTLCOLOREDIT palette brushes), counter "n/m", ▲ ▼ ✕ (Segoe Fluent) hit-tested;
      // prefill value.needle, select all, focus the EDIT (overlay.beginPanelActivation)
  pub fn end(app: *App, target: apprt.Target) !bool;           // hide, refocus the surface
  pub fn total(app: *App, target: apprt.Target, value: apprt.action.SearchTotal) !bool;
  pub fn selected(app: *App, target: apprt.Target, value: apprt.action.SearchSelected) !bool;
  pub fn counterText(buf: []u8, total: ?usize, selected: ?usize) []const u8;  // pure: "3/17", "0/0", "" when unknown
  // EN_CHANGE → debounce 50 ms (GhosttyOverlay timer 2) → performBindingAction(.{ .search = text }); Enter / F3 → .navigate_search next,
  // Shift+Enter / Shift+F3 → previous; Esc → performBindingAction(.end_search) (core answers with end_search → hide)
  ```
- [ ] **Step 1: Failing tests** `"win32 search: counter text"`, `"win32 search: key routing"` (pure mapping of VK + shift → binding action or none).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 search"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `search` (order 570): Git Bash prints `alpha beta alpha gamma alpha`; `action start_search` → panel visible and focused; type `alpha` → `state.m3.search.total == 3` within 1 s; Enter twice → `selected` advances; Esc → panel hidden, the surface focused (typing reaches the shell: echo oracle).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): search bar overlay driven by core search"`

### Task 13: Command palette

**Review:** light.

**Files:** Modify (replace stubs) `src/apprt/win32/CommandPalette.zig`, `src/apprt/win32/palette_filter.zig`; Create `test/windows/e2e/palette.ps1`

**Interfaces:**
- Produces:
  ```zig
  // palette_filter.zig (pure)
  pub const Entry = struct { title: []const u8, description: []const u8, index: usize };
  pub fn score(query: []const u8, text: []const u8) ?u32;   // case-insensitive subsequence; bonuses: prefix, word start, contiguous run; null = no match
  pub fn filter(alloc: Allocator, query: []const u8, entries: []const Entry) ![]usize; // indices by descending score (title ×2 + description), stable; empty query → all in order
  // CommandPalette.zig
  pub const State = struct { popup: ?*overlay.Popup = null, edit: ?HWND = null, target_id: ?u32 = null, rows: []usize = &.{}, sel: usize = 0, scroll: usize = 0 };
      // target_id, not a pointer: resolved through the window's surface-id lookup at execute time; a gone target → no-op (pre-flight 7)
  pub fn surfaceDestroying(surface: *Surface) void;         // hook: closes the palette when surface is its target
  pub fn toggle(app: *App, target: apprt.Target) !bool;     // panel window_top_center, width min(600 @96, 80% client), ≤ 12 visible rows
      // entries: the window's config `command-palette-entry` exactly as GTK command_palette.zig builds them; right-aligned keybinding text
      // from config.keybind.set (trigger of the entry's action), dim palette colour
      // Up/Down/PageUp/PageDown move the selection; Enter or click executes; Esc or focus loss closes; wheel scrolls
      // execute: close + refocus the target surface, then WM_GHOSTTY_OVERLAY_CMD carrying target_id and a deep copy of the action
      //   (Action.clone; a config reload in between cannot free it; the handler frees it) → resolve target_id → performBindingAction(action)
  ```
- [ ] **Step 1: Failing tests** `"win32 palette: target closed while open"` (target surface destroyed with the palette open → palette closed; a queued `OVERLAY_CMD` for the gone id is a no-op that frees the clone), `"win32 palette: overlay command owns a cloned action"` (testing allocator: no leak, no use of config memory after a simulated reload), `"win32 palette filter: subsequence and ranking"` (`"nsp"` ranks "New Split Right" above "Toggle Inspector"; `"zz"` matches nothing; empty query keeps order; ties stable), `"win32 palette filter: unicode case folding for ASCII only"` (Cyrillic compared byte-wise, documented).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 palette"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `palette` (order 580): `action toggle_command_palette` → panel visible; type `split right` → first row executes `new_split:right` on Enter → tab has 2 surfaces, palette closed, the original surface keeps keyboard focus semantics of core (`new_split` focuses the new one).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): command palette with fuzzy filter"`

### Task 14: Composition swap chain mode (renderer)

**Review:** opus (threads, COM hand-off, pacing).

**Files:** Modify `src/renderer/d3d11/SwapChain.zig` (`Mode.composition`: `CreateSwapChainForComposition`, `DXGI_ALPHA_MODE_PREMULTIPLIED`, `DXGI_SCALING_STRETCH`, same flip/waitable flags, tearing per Task 8 check (k); `ResizeBuffers` unchanged), `src/renderer/D3D11.zig` (`PresentTarget.mode` + `PresentTarget.hand_off`; swap chain created in the mode read at creation; mode change = generation bump path of M2 Task 30), `pkg/win32/dxgi.zig` (anything else the mode needs)

**Interfaces:**
- Produces:
  ```zig
  // D3D11.PresentTarget (appended fields; apprt fills them in Task 15)
  mode: ?*const std.atomic.Value(u8) = null,          // 0 = hwnd, 1 = composition; read when a swap chain is (re)created
  hand_off: ?HandOff = null,
  pub const HandOff = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, swap_chain: *dxgi.IDXGISwapChain1, generation: u32) void };
      // called on the render thread right after a composition swap chain is created/recreated, with one AddRef held for the callee.
      // The callee (Task 15) stores the chain in composition.SurfaceState.pending: std.atomic.Value(?*IDXGISwapChain1) by swap,
      // releases the previous value, and posts a payload-free WM_GHOSTTY_SET_CONTENT; the handler swaps pending to null, then
      // SetContent + Commit + Release. Surface.destroy releases a non-null pending after core_surface.deinit() (render thread joined)
      // and before DestroyWindow, so a hand-off racing surfaceDestroying never leaks (pre-flight 8). hwnd mode never calls it.
  ```
  The backbuffer copy is unchanged (target is premultiplied already). Headless tests use a fake hand-off.
- [ ] **Step 1: Failing tests** (WARP)
  ```zig
  test "d3d11 swapchain: composition mode creates a premultiplied chain and hands it off once" {}
  test "d3d11 swapchain: mode change recreates the chain on the next frame" { // mode 0 → 1 + generation bump → hand_off called; old chain released }
  test "d3d11 swapchain: composition resize keeps the hand-off count" { // ResizeBuffers does not call hand_off }
  test "d3d11 swapchain: waitable pacing in composition mode" { // waitForSlot after present behaves as in hwnd mode (fake waiter) }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="d3d11 swapchain"` → FAIL.
- [ ] **Step 3: Implement** per Task 8's `RESULT.md`.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; no change for `mode == null` (all M1/M2 renderer tests PASS).
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): composition swap chain mode with UI-thread hand-off"`

### Task 15: Transparency and blur (apprt) + `toggle_background_opacity`

**Review:** opus (DComp lifetime on the UI thread, re-parenting, latency gate G2).

**Files:** Modify (replace stub) `src/apprt/win32/composition.zig`; Modify `pkg/win32/dcomp.zig` (append if needed), `src/apprt/win32/Surface.zig` (fill `PresentTarget.mode`/`hand_off`; `destroy` releases `composition.pending` after `core_surface.deinit()`), `src/apprt/win32/Window.zig` (extended frame + backdrop by mode), `src/apprt/win32/Tab.zig` (container paints alpha 0 in transparent mode — black brush inside the extended frame, as spike check (b) does, so no stale redirection-surface pixels (pre-flight 31) — and `background` when toggled opaque), `src/apprt/win32/frame.zig` (backdrop choice R-M3-3), `src/apprt/win32/theme.zig` (`painter_over_mica` becomes per-window state: opaque strip without blur, over-backdrop strip with blur; high contrast → transparency off); Create `test/windows/vt-smoke/cases/opacity.sh` (`.sh` + header only; the lead generates `ref/opacity.png` at G2 — pre-flight 11), `test/windows/e2e/transparency.ps1`, `test/windows/e2e/opacity-blur.ps1`

**Interfaces:**
- Produces:
  ```zig
  pub fn wantComposition(config: *const Config, high_contrast: bool) bool;  // pure: opacity < 1 or blur enabled, and !high_contrast
  pub fn backdropFor(config: *const Config, toggled_opaque: bool, high_contrast: bool) Backdrop; // pure: .mica (M2 default), .acrylic, .transparent, .opaque
  pub const AppState = struct { device: ?*dcomp.IDCompositionDevice = null };   // created on the first composition surface (UI thread) with
      // DCompositionCreateDevice2(null, …) — no rendering device — so it survives a D3D device loss; Task 24 never recreates it (pre-flight 25)
  pub const SurfaceState = struct { mode: std.atomic.Value(u8) = .init(0), target: ?*dcomp.IDCompositionTarget = null, visual: ?*dcomp.IDCompositionVisual = null, generation: u32 = 0,
      pending: std.atomic.Value(?*dxgi.IDXGISwapChain1) = .init(null) };  // Task 14 HandOff contract
  pub const WindowState = struct { toggled_opaque: bool = false, backdrop: Backdrop = .mica };
  pub fn surfaceCreated(surface: *Surface) void;       // composition: CreateTargetForHwnd(surface.hwnd, TRUE) + CreateVisual + SetRoot
  pub fn surfaceMessage(surface: *Surface, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_GHOSTTY_SET_CONTENT: swap pending → null;
      // stale generation (wparam) → Release only; else SetContent + Commit + Release
  pub fn surfaceDestroying(surface: *Surface) void;    // SetContent(null) + Commit + release target/visual before core deinit (pending is released by Surface.destroy)
  pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void; // backdrop re-applied; on a mode switch (pre-flight 9):
      // hwnd→composition: create target + visual (UI thread) BEFORE storing the mode and bumping the present-target generation;
      // composition→hwnd: store the mode, bump the generation, then SetContent(null) + Commit + release target + visual
  pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void; // recreate targets if Task 8 (e) says they do not survive
  pub fn toggleOpacity(app: *App, target: apprt.Target) !bool;      // window-level toggled_opaque flip; no swap chain change (R-M3-2); hwnd mode → no-op, logged
  ```
- [ ] **Step 1: Failing tests** `"win32 composition: wantComposition"`, `"win32 composition: backdrop table"` (blur → acrylic; opacity only → transparent; toggled → opaque; high contrast → mica/opaque; `background-opacity = 1` + toggle → state unchanged), `"win32 composition: stale hand-off is released"` (generation mismatch → no SetContent, refcount back to 0 via a fake swap chain object), `"win32 composition: hand-off after surfaceDestroying is released"` (fake chain handed off after the hook; destroy path → refcount 0), `"win32 composition: mode switch creates and destroys targets"` (fake DComp device: hwnd→composition creates target+visual before the generation bump; back → released after it).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 composition"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `transparency` (order 630): the script shows its own magenta backdrop window, places Ghostty over it with `background = #000000`, `background-opacity = 0.5`; the screen-rect capture of an empty cell ≈ (128, 0, 128) ±12 and the dump alpha ≈ 128; `toggle_background_opacity` → the same pixel ≈ (0,0,0); reload with `background-opacity = 1` → `state.m3.composition.mode == hwnd` and opaque. `opacity-blur` (order 635): `background-blur = true` → `DwmGetWindowAttribute(SYSTEMBACKDROP_TYPE) == 3`. vt-smoke `opacity` case (`requires=T15`, `.sh` + header only).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`. G2 (lead): `measure-ram.ps1 -ExtraConfig "background-opacity = 0.9" -Tag opacity` (1 and 5 surfaces) and `input-latency.ps1 -ExtraConfig "background-opacity = 0.9"`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): background opacity and blur through DirectComposition; toggle_background_opacity"`

### Task 16: Global hotkeys and `toggle_visibility`

**Review:** light.

**Files:** Modify (replace stubs) `src/apprt/win32/hotkeys.zig`, `src/apprt/win32/visibility.zig`; Create `test/windows/e2e/hotkey-global.ps1`, `test/windows/e2e/toggle-visibility.ps1`

**Interfaces:**
- Produces:
  ```zig
  // hotkeys.zig
  pub const Chord = struct { mods: u32, vk: u16 };
  pub fn chordFor(trigger: input.Binding.Trigger, hkl: ?*anyopaque) ?Chord; // physical → keycodes native scancode → MapVirtualKeyExW(VSC_TO_VK_EX);
      // unicode → VkKeyScanExW (shift state adds MOD_SHIFT; ctrl/alt states → null); catch_all → null; mods ctrl/alt/shift/super → MOD_*
  pub const State = struct { ids: std.AutoHashMapUnmanaged(i32, Leaf) = .empty, next_id: i32 = 1, failed: u32 = 0 };
      // Leaf = the binding's leaf exactly as stored in config.keybind.set (`.leaf` or `.leaf_chained`); it points into config memory (pre-flight 18)
  pub fn appStarted(app: *App) void;            // register every global leaf of config.keybind.set (MOD_NOREPEAT) on app.msg_hwnd
  pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void;  // unregister all, register again from the NEW config —
      // runs inside the config_change hook, before the old config is freed, so no id ever maps to freed memory
  pub fn appStopping(app: *App) void;           // unregister all
  pub fn appMessage(app: *App, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_HOTKEY → core_app.performAllAction(rt_app, action)
      // for `.leaf`; core's chained-action path (performAllChainedAction or its equivalent at the landed upstream base) for `.leaf_chained`
  // visibility.zig — macOS semantics: if a Ghostty window (not quick) is foreground → hide all visible normal windows (remember them and
  // the foreground one); else show the remembered ones (or present the last active) and bring the remembered foreground window to front.
  pub fn toggle(app: *App) !bool;
  pub const State = struct { hidden: std.ArrayList(u32) = .empty /* window ids */, foreground: ?u32 = null };
  ```
- [ ] **Step 1: Failing tests** `"win32 hotkeys: chord from physical key"` (`ctrl+alt+shift+f9` → MOD_CONTROL|MOD_ALT|MOD_SHIFT + VK_F9), `"win32 hotkeys: chord from unicode under US and DE layouts"` (`ctrl+grave_accent`/`` ` `` under US → VK_OEM_3; layouts loaded with the M1 test helper and restored), `"win32 hotkeys: register and unregister on a message window"`, `"win32 hotkeys: chained global bind runs every action"` (fake perform callback records 2 actions), `"win32 visibility: hide then show restores the same set"` (pure state machine over fake window ids).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 hotkeys"` (and `"win32 visibility"`) → FAIL.
- [ ] **Step 3: Implement.** Scenarios: `hotkey-global` (order 540): `keybind = global:ctrl+alt+shift+f9=new_window`; with a foreign window (the script's own WinForms window) in the foreground, `SendInput` of the chord → a second `GhosttyWindow` of the pid appears ≤ 1 s. `toggle-visibility` (order 545): `keybind = global:ctrl+alt+shift+f10=toggle_visibility`; chord → all Ghostty windows hidden; chord again → visible, foreground restored.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): global keybinds through RegisterHotKey; toggle_visibility"`

### Task 17: Quick terminal

**Review:** opus (window lifecycle, focus, autohide).

**Files:** Modify (replace stub) `src/apprt/win32/QuickTerminal.zig`; Modify `src/apprt/win32/Window.zig` (`kind = .quick` creation path: styles, no taskbar, topmost while shown; excluded from `goto_window`/last-active), `src/apprt/win32/frame.zig` (quick: decorations none, strip `tabs_only` with ≥ 2 tabs else hidden), `src/apprt/win32/App.zig` (window counting for `quit-after-last-window-closed` and the tray skips quick windows; the `+toggle-quick-terminal` client path in `performIpc`), `src/apprt/win32/ipc/client.zig` (optional `allow_foreground`: `AllowSetForegroundWindow(server_pid)` with the pid the client already verifies, before sending — the server cannot take the foreground otherwise; pre-flight 19); Create `test/windows/e2e/quick-terminal.ps1`

**Interfaces:**
- Produces:
  ```zig
  pub const State = struct { window: ?*Window = null, shown: bool = false, anim: ?Anim = null, prev_foreground: ?HWND = null };
  pub const Anim = struct { from: geom.Rect, to: geom.Rect, start_ns: u64, duration_ns: u64, hiding: bool };
  pub fn targetRect(position: Config.QuickTerminalPosition, size: Config.QuickTerminalSize, work_area: geom.Rect) geom.Rect; // pure
      // uses QuickTerminalSize's own calculation helpers when Config provides them (as the GTK Wayland path does); defaults per core
  pub fn hiddenRect(position: Config.QuickTerminalPosition, shown: geom.Rect, work_area: geom.Rect) geom.Rect; // off the anchored edge; center → same rect (fade-free instant)
  pub fn frameAt(anim: Anim, now_ns: u64) struct { rect: geom.Rect, done: bool };   // pure, ease-out cubic
  pub fn monitorFor(screen: Config.QuickTerminalScreen) HMONITOR;  // main → primary; mouse → monitor at cursor; macos-menu-bar → primary
  pub fn toggle(app: *App) !bool;          // lazy create (kind .quick, one tab); show: SW_SHOWNA, slide in (GhosttyWindow timer 2, 8 ms steps),
                                           // SetForegroundWindow + focus the active surface; hide: slide out, SW_HIDE, restore prev_foreground if still a window
  pub fn ipcToggle(app: *App) !void;       // IPC op toggle-quick-terminal
  pub fn windowMessage(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_ACTIVATE(WA_INACTIVE) + quick-terminal-autohide
      // → hide unless lparam is a window of this process (own dialogs, overlays, inspector); WM_TIMER 2 → animation step
  pub fn configChanged(app: *App, config: *const Config, reloaded: bool) void;  // re-place when shown
  ```
  A toggle during an animation reverses it from the current rect. Closing the quick window's last surface destroys it (`State.window = null`).
  Pre-flight 19: `quick-terminal-size` pixel values are logical px × monitor DPI / 96; `quick-terminal-layer` joins `quick-terminal-keyboard-interactivity`/`-space-behavior` as ignored on Windows; tabs can be torn off from the quick window (they open a normal window) but the quick window's strip is not a drop target for tabs from other windows.
- [ ] **Step 1: Failing tests** `"win32 quick: targetRect per position and size"` (top 100%×50% of a 1920×1040 work area → {0,0,1920,520}; right 40% width; center 50%×50%; pixel sizes), `"win32 quick: hiddenRect off edge"`, `"win32 quick: frameAt eases and ends exactly at to"`, `"win32 quick: reverse mid-animation"`, `"win32 quick: window counting ignores quick windows"` (pure helper used by App), `"win32 quick: pixel size scales with monitor DPI"` (800 px at 144 dpi → 1200), `"win32 quick: strip refuses tab drops"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 quick"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `quick-terminal` (order 590): `ipc toggle-quick-terminal` → a visible `GhosttyWindow` of kind quick (`state.m3.quick.shown`) at the top of the primary work area, no taskbar button (`WS_EX_TOOLWINDOW`), surface focused (echo oracle through it); toggle again → hidden, shell still alive (toggle → same pid tree, prompt still there); `quick-terminal-autohide = true` + activating the script's own window → hidden; `quick-terminal-position = bottom` → rect at the bottom; `quit-after-last-window-closed = true` with only the quick window shown and the normal window closed → process still running (quick does not count) — the scenario then quits via the `quit` action.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): quick terminal (slide-in topmost window, global toggle, autohide)"`

### Task 18: Desktop notifications (toasts) and `command_finished`

**Review:** opus (WinRT ABI, delegate refcounting, registry write, untrusted text).

**Files:** Modify (replace stub) `src/apprt/win32/notify.zig`; Modify `pkg/win32/winrt.zig` (fill; `RoGetActivationFactory`/`RoActivateInstance`/`Windows*String` resolved on first use from System32 `combase.dll` via `LoadLibraryExW` + `GetProcAddress` — no `runtimeobject` import, pre-flight 3); Create `test/windows/e2e/notifications.ps1`

**Interfaces:**
- Produces:
  ```zig
  // winrt.zig: WindowsCreateString/WindowsDeleteString/WindowsGetStringRawBuffer, RoGetActivationFactory, RoActivateInstance, HSTRING,
  //   IInspectable (6), IToastNotificationManagerStatics (9), IToastNotifier (12), IToastNotificationFactory (7), IToastNotification (15),
  //   IXmlDocumentIO (9), IXmlDocument (as IInspectable), TypedEventHandler<ToastNotification, IInspectable> delegate vtable (IUnknown + Invoke = 4)
  //   + its parametric IID copied from windows.ui.notifications.h (__FITypedEventHandler_2_Windows__CUI__CNotifications__CToastNotification_IInspectable);
  //   all IIDs/runtime-class names from SDK 10.0.26100; slot tests
  // notify.zig
  pub const aumid = if (builtin.mode == .Debug) "com.mitchellh.ghostty.windows-unofficial-debug" else "com.mitchellh.ghostty.windows-unofficial";
  pub fn toastXml(alloc: Allocator, title: []const u8, body: []const u8, surface_id: u32) ![:0]u16; // pure: ToastGeneric, XML-escaped,
      // C0/C1 and bidi overrides stripped, title ≤ 256 / body ≤ 1024 code points (core truncates first; this is the backstop), launch="surface=<id>"
  pub const RegistryWriter = struct { ctx: *anyopaque, setString: *const fn (ctx: *anyopaque, subkey: []const u16, name: []const u16, value: []const u16) bool };
  pub fn registerAumid(w: RegistryWriter, icon_path: []const u8) bool; // HKCU\Software\Classes\AppUserModelId\<aumid>: DisplayName "Ghostty — Unofficial Windows port", IconUri
  pub fn appStarted(app: *App) void;      // SetCurrentProcessExplicitAppUserModelID(aumid) (not in test mode)
  pub fn desktop(app: *App, target: apprt.Target, value: apprt.action.DesktopNotification) !bool;  // desktop-notifications gate → show
  pub fn commandFinished(app: *App, target: apprt.Target, value: apprt.action.CommandFinished) !bool;
      // mirrors GTK application.zig command_finished: notify-on-command-finish (never/unfocused/always), -after, -action
      // (bell → the M2 bell entry point that `ring_bell` uses, no bell.zig edit; notify → toast)
  pub fn appMessage(app: *App, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_GHOSTTY_NOTIFY_CLICK → present_terminal for that surface if alive
  pub const State = struct { notifier: ?*winrt.IToastNotifier = null, registered: bool = false, recorded: RingBuffer(Recorded, 16) = .{} };
  // show(): first use → write the icon PNG + registerAumid (real writer), create notifier via CreateToastNotifierWithId(aumid); per toast:
  //   XmlDocument LoadXml → factory.CreateToastNotification → add_Activated(delegate{surface id}) → notifier.Show; failure → FlashWindowEx + warn once.
  //   Test mode (GHOSTTY_WIN32_TEST_IPC=1): only `recorded` (title, body, surface) — no WinRT, no registry.
  ```
- [ ] **Step 1: Failing tests** `"win32 notify: toast xml escapes and strips"` (`<b>&"'` escaped; U+202E and `\x1b` stripped; long body truncated), `"win32 notify: aumid registration through the writer"` (fake writer receives the two values under the right subkey; nothing touches the real registry), `"win32 notify: command_finished policy"` (table: never/unfocused/always × focused × duration vs `-after`), `"win32 notify: delegate refcount"` (AddRef/Release balance; Invoke posts exactly one message with the surface id), `"win32 winrt: slot counts"`, `"win32 winrt: toast factory activates"` (RoGetActivationFactory for `Windows.UI.Notifications.ToastNotificationManager` succeeds; nothing shown; SKIP if WinRT unavailable).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 notify"` (and `"win32 winrt"`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `notifications` (order 600, test mode): `printf '\e]9;hello & <you>\e\\'` → `state.m3.notify.recorded[0]` = title "Ghostty"/body as given; `notify-on-command-finish = always`, `-after = 0s`; the case emits OSC 133 itself (`printf '\e]133;C\a'; sleep 1; printf '\e]133;D;0\a'`, no dependency on Git Bash shell integration — pre-flight 21) → one entry recorded; `desktop-notifications = false` → nothing recorded. The real toast is the owner's manual check (exit checklist).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`. No real toast here: the first-toast RAM delta and the real toast are Task 27's manual, owner-approved run (pre-flight 11/13). If L1 recorded OSC 9/777/133 as dropped, the matching scenario steps are removed and recorded as owner-approved gaps.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): desktop notifications as WinRT toasts with self-registered AUMID; command_finished"`

### Task 19: Inspector (imgui win32 + dx11)

**Review:** opus (shared context lock on the UI thread, imgui context lifetime).

**Files:** Modify `pkg/dcimgui/build.zig` (options `backend-dx11`, `backend-win32` compiling `imgui_impl_dx11.cpp` with `-DD3DCompile=ghostty_imgui_D3DCompile` and `imgui_impl_win32.cpp` with `-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD` — R-M3-4), `pkg/dcimgui/main.zig` (`extern` declarations for `ImGui_ImplWin32_*` and `ImGui_ImplDX11_*`; `ImGui_ImplWin32_WndProcHandler` is `#if 0` in the header, so it is declared by hand), `src/build/SharedDeps.zig` (Windows: `backend-dx11 = true`, `backend-win32 = true`, `backend-opengl3 = false`; no `d3dcompiler` in the link list); Modify (replace stub) `src/apprt/win32/inspector/Inspector.zig`; Create `src/apprt/win32/inspector/Window.zig`, `src/apprt/win32/inspector/imgui_shim.zig` (`export fn ghostty_imgui_D3DCompile(…)` forwarding to `pkg/win32/d3dcompiler.zig`'s System32-loaded pointer; `E_FAIL` when unavailable), `test/windows/e2e/inspector.ps1`

**Interfaces:**
- Consumes: core `Surface.activateInspector/deactivateInspector`, core inspector `setup()`/`render(...)` as used by `src/apprt/embedded.zig` (≈1262–1510; mirror its frame sequence), `Device.lockContext/unlockContext`.
- Produces:
  ```zig
  // inspector/Inspector.zig
  pub fn action(app: *App, target: apprt.Target, mode: apprt.action.Inspector) !bool;  // toggle/show/hide for the target surface
  pub fn render(app: *App, target: apprt.Target) !bool;                                // render_inspector → sets a dirty flag only; the 30 Hz
      // GhosttyInspector timer 1 renders when dirty or foreground (never one imgui frame per terminal frame — pre-flight 29)
  pub fn surfaceDestroying(surface: *Surface) void;                                    // close + free before core deinit
  pub fn deviceChanged(app: *App) void;                                                // Task 24: ImGui_ImplDX11_InvalidateDeviceObjects + Init on the new device
  pub fn appStopping(app: *App) void;                                                  // hook: close every inspector window
  pub const Inspector = struct { window: *inspector.Window, ig_ctx: *cimgui.ImGuiContext, surface: *Surface, swap_chain: ..., … };
  // inspector/Window.zig: top-level class GhosttyInspector (own taskbar entry), title "Inspector — <surface title>", 800×600 @dpi, dark caption;
  //   flip-model hwnd swap chain on the shared device, created/resized/presented on the UI thread under lockContext (Present(0) — never waits under the lock);
  //   ImGui_ImplWin32_WndProcHandler first in its WndProc; GhosttyInspector timer 1 at 33 ms while open (renders when foreground or dirty); ClearState after each draw
  ```
- [ ] **Step 1: Failing tests** `"win32 inspector: open and close frees the imgui context"` (hidden window, WARP device via test options: one frame rendered, context count back to 0), `"win32 inspector: draw holds the context lock"` (Debug assert path: `assertContextLocked` inside the render callback), `"win32 inspector: closing the surface closes its inspector"`, `"win32 inspector: render_inspector coalesces to the tick"` (100 `render` calls between two ticks → 1 imgui frame).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 inspector"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `inspector` (order 610): `action inspector:toggle` → a visible `GhosttyInspector` window of the pid; key typed in the terminal appears in the inspector's key list (its dump or `state.m3.inspector.frames` advancing); toggle again → window gone; RAM before/open/after recorded by the lead in Task 27 (`measure-ram.ps1 -Actions inspector:toggle -Tag inspector`).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`; `LOCK ZIG build -j6 -Demit-lib-vt` and the Linux recipe still build (dcimgui options unchanged off Windows); the import table of `zig-out/bin/ghostty.exe` (`llvm-readobj --coff-imports`, or a small PE import-table check in Zig if `llvm-readobj` is unavailable) lists no `d3dcompiler_47.dll`, no `xinput*` and no `dcomp.dll` (pre-flight 3).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): terminal inspector with imgui win32 + dx11 backends"`

### Task 20: Config-errors dialog and `export_terminal_io`

**Review:** light.

**Files:** Modify (replace stubs) `src/apprt/win32/config_errors.zig`, `src/apprt/win32/export_io.zig`; Modify `src/apprt/win32/dialogs.zig` (generic `taskDialogList` helper; M2 Task 27 minors: a failing `TaskDialogIndirect` HRESULT does not prompt twice, default button failure surfaced), `pkg/win32/comdlg32.zig` (fill: `GetSaveFileNameW`, `OPENFILENAMEW` (x64 size 152), `OFN_OVERWRITEPROMPT OFN_PATHMUSTEXIST OFN_NOCHANGEDIR OFN_EXPLORER`, `CommDlgExtendedError`); Create `test/windows/e2e/config-errors.ps1`, `test/windows/e2e/export-io.ps1`

**Interfaces:**
- Produces:
  ```zig
  // config_errors.zig — mirrors GTK config_errors_dialog: on appStarted and on configChanged(reloaded) with diagnostics, post
  //   WM_GHOSTTY_POSTED_DIALOG(config_errors) to the active window; TaskDialog "Configuration errors" listing up to 20 diagnostics (+ "and N more"),
  //   buttons "Reload configuration" (→ reload_config), "Open configuration" (→ open_config), "Ignore"; at most one dialog at a time
  pub fn formatDiagnostics(alloc: Allocator, diags: []const configpkg.Diagnostic, max: usize) ![]u8;  // pure
  // export_io.zig — save(app, target, value): copy contents, post WM_GHOSTTY_POSTED_DIALOG(export_io); handler: GetSaveFileNameW
  //   (default name "ghostty-<yyyymmdd-hhmmss>.txt", filter "Text (*.txt)"), write bytes as given (no BOM, no CRLF conversion); cancel → free.
  //   Test mode (GHOSTTY_WIN32_TEST_IPC=1, the export-io op's path): no dialog — writes to the given path and records {path, bytes} in
  //   state.m3, so no ComDlg32 MRU key on the owner's HKCU is ever written by a test (pre-flight 13)
  pub fn defaultName(buf: []u8, now: Timestamp) []const u8;  // pure
  ```
- [ ] **Step 1: Failing tests** `"win32 config errors: format caps the list"`, `"win32 export: default file name"`, `"win32 comdlg32: OPENFILENAMEW size"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 config errors"` (and `export`, `comdlg32`) → FAIL.
- [ ] **Step 3: Implement.** Scenarios: `config-errors` (order 620): config with `font-sise = 3` → a TaskDialog window of the pid lists it; "Ignore" closes; fixing the file + "Reload configuration" → no dialog. `export-io` (order 625): the test op `export-io` with text `hello-export` and a sandbox path (core emits `export_terminal_io` only from the inspector's termio widget, which a script cannot click) → no dialog; the file holds exactly `hello-export` and `state.m3` records `{path, bytes: 12}`. The real save dialog and the inspector's own export button are in the owner's manual checklist.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): config errors dialog and export_terminal_io save dialog"`

### Task 21: Tab context menu and full-title tooltip (M2 deferred)

**Review:** light.

**Files:** Modify (replace stub) `src/apprt/win32/tab_menu.zig`; Modify `src/apprt/win32/strip_input.zig` (right-click on a tab → `tab_menu.show`; hover over a trimmed tab → tooltip), `src/apprt/win32/TabStrip.zig` (`Layout.trimmed: []bool`, filled through a text-width measure callback), `src/apprt/win32/Chrome.zig` (supplies that callback from its DWrite title text format — pre-flight 14); Create `test/windows/e2e/tab-menu.ps1`

**Interfaces:**
- Produces: `tab_menu.show(window, tab_index, screen_x, screen_y)`: `TrackPopupMenuEx(TPM_RETURNCMD)` with "Rename tab…" (→ `prompt_title` tab), "Move to new window" (→ `move_tab_to_new_window`), separator, "Close tab", "Close other tabs", "Close tabs to the right" (→ `close_tab` this/other/right), each executed through the existing actions on the tab's active surface; items disabled when meaningless (single tab → close others/right disabled). Tooltip: one tracking `TOOLTIPS_CLASSW` per window (created lazily), shown after 500 ms hover on a tab whose title is trimmed (`TabStrip` layout reports trimming), hidden on leave/press/drag; text = full title.
- [ ] **Step 1: Failing tests** `"win32 tab menu: item states"` (pure: count 1 → close-others/right disabled; last tab → close-right disabled), `"win32 tab menu: command → action mapping"`, `"win32 tabstrip: trimmed flags from the measure callback"` (fake measure: wide title in a narrow tab → trimmed, short → not).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tab menu"` (and `"win32 tabstrip"`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `tab-menu` (order 640): 3 tabs; right-click tab 2 → a `#32768` menu window of the pid; choose "Close other tabs" (keyboard: arrows + Enter) → 1 tab left; a 30-tab strip, hover a trimmed tab 700 ms → a visible tooltip window with the full title.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab context menu and full-title tooltip"`

### Task 22: Text drops (M2 §18.17 deferred)

**Review:** light.

**Files:** Modify `src/apprt/win32/drop.zig`, `test/windows/e2e/drop-files.ps1` (text half added; helper `_drop.ps1` gains `Start-OleTextDrag`)

**Interfaces:**
- Produces: `IDropTarget` accepts `CF_UNICODETEXT` (after `CF_HDROP`, which keeps priority); `Drop` copies the text (UTF-16 → UTF-8, NUL-terminated at the first NUL, unpaired surrogates → U+FFFD) and posts `WM_GHOSTTY_DROP` with `kind = .text`; the handler focuses the surface and delivers through `clipboard.pasteText(surface, text)` (Task 23; the same confirm/deny flow as Ctrl+V around `completeClipboardRequest(.paste, …)` — calling `completeClipboardRequest(…, confirmed = false)` directly only returns `error.UnsafePaste`, pre-flight 5), so bracketed paste and the unsafe-paste confirmation (multi-line text) behave exactly as Ctrl+V (R-M3-12). Text over 10 MiB is refused with a log line.
- [ ] **Step 1: Failing tests** `"win32 drop: text payload conversion"` (NUL cut, surrogate repair, CRLF kept as given), `"win32 drop: files keep priority over text"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 drop"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `drop-text` (order 650): drop one line `echo dropped` → appears at the prompt, not executed; drop two lines → the paste-confirm TaskDialog appears; Cancel → nothing typed.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): text drops through the paste path"`

### Task 23: Input, clipboard, termio and pwd polish (M1/M2 carry-overs)

**Review:** light.

**Files:** Modify `src/apprt/win32/keyboard.zig`, `src/apprt/win32/key.zig`, `src/apprt/win32/clipboard.zig`, `src/termio/Exec.zig` (Windows-only paths), `src/apprt/win32/Window.zig` + `src/apprt/win32/Surface.zig` + `src/apprt/win32/actions/tab_actions.zig` (pwd per surface)

**Interfaces:**
- Fixes (each with a failing test first):
  - keyboard (M1 Task 23 minors): Alt+numpad digits no longer leak as `alt+numpad_N` key events before the composed `WM_CHAR` (held while Alt is down and digits are numpad VKs); dead-key `utf8` is not sent through unicode binding lookup (GTK passes empty); Shift is not consumed for `shift+space`; the 64-byte UTF-8 buffer never cuts a code point; fake shifts are dropped, not sent as `.unidentified`.
  - clipboard paste entry for drops (pre-flight 5): `pub fn pasteText(surface: *Surface, text: [:0]const u8) void` — the same confirm/deny flow as Ctrl+V (`process`/`confirmWith` reused, unsafe text → the paste-confirm dialog, posted), consumed by Task 22.
  - clipboard (M1 Task 26 minors): invalid UTF-8 OSC 52 payload → U+FFFD replacement before the write; embedded NUL truncates with a log; a failed confirmed `completeClipboardRequest` still answers the OSC 52 read; `previewText` escapes C1 and bidi overrides.
  - termio (M1 Task 9 minors, Windows-only): synchronous overlapped `ReadFile` completion read via `GetOverlappedResult` (not `lpNumberOfBytesRead`); no extra `closeConsoleAsync` thread from `threadExit` when the close already ran.
  - pwd per surface (M2 Task 13 minor): `pwd` stored on the `Surface`, the window subtitle/title source and new-tab/split inheritance read the focused surface's pwd.
- [ ] **Step 1: Failing tests** `"win32 key: alt+numpad sequence yields one text event"`, `"win32 key: shift+space keeps shift"`, `"win32 key: utf8 buffer never splits a code point"`, `"win32 clipboard: osc52 invalid utf8 replaced"`, `"win32 clipboard: preview escapes bidi overrides"`, `"win32 clipboard: pasteText asks for unsafe text"` (multi-line text → confirm path taken, nothing written before the answer; single line → written), `"win32 tab: new tab inherits the focused surface pwd"`, `"windows exec: sync-completed read uses GetOverlappedResult"` (fake pipe).
- [ ] **Step 2: Run** the filters (`"win32 key"`, `"win32 clipboard"`, `"win32 tab"`, and `-Dapp-runtime=none -Dtest-filter="windows exec"`) → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; the lead's W2 batch includes `typing-*`, `paste-confirm`, `stream-integrity`, `close-while-streaming`.
- [ ] **Step 5: Commit** one commit per area, `git commit -m "fix(win32): <area> carry-overs from M1/M2"`

### Task 24: Device-loss recovery and the renderer-health bar (beyond M2 Task 39)

**Review:** opus (cross-thread teardown/rebuild, generations, UAF risk).

**Files:** Modify (replace stub) `src/apprt/win32/recovery.zig`; Modify `src/renderer/d3d11/Device.zig` (generation recovery, WARP after 3 failures in 60 s; DXGI debug factory only after the debug layer is confirmed — M1 Task 8 minor), `src/renderer/D3D11.zig` (re-acquire on the first frame after `displayRealized`; `deviceLost()` query), `src/renderer/d3d11/SwapChain.zig` (recreation after re-acquire, composition hand-off again), `src/apprt/win32/inspector/Inspector.zig` (`deviceChanged`), `src/apprt/win32/App.zig` (remove M2 Task 39's "quit when the device is lost and no window is left"); Modify (core, platform-neutral) `src/renderer/generic.zig` + `src/renderer/image.zig` (on a backend-reported device-generation change, Kitty-image and background-image textures are dropped and marked for re-upload — `releaseGpuResources` deliberately keeps them today; no-op on other backends — pre-flight 10); Create `test/windows/e2e/device-recover.ps1`

**Interfaces:**
- Produces:
  ```zig
  // recovery.zig
  pub const State = struct { armed: bool = false, failures: [3]u64 = .{0,0,0}, warp: bool = false };
  pub fn rendererHealth(surface: *Surface, health: apprt.action.RendererHealth) void; // unhealthy → arm msg-window timer 2 (250 ms) once
  pub fn appMessage(app: *App, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // timer 2: for every surface whose renderer reports deviceLost():
      // core.renderer.displayUnrealized(); core.renderer.displayRealized() (UI thread, as GTK does); inspector.deviceChanged; record a failure
      // if the same surface is unhealthy again within 5 s; 3 failures in 60 s → Device.preferWarp() + badges.setHealthText(final message).
      // A loss while a custom shader is active first disables custom shaders for the next attempt (log + health text) before it counts
      // toward WARP, so a GPU-hanging shader cannot cause three system-wide TDR freezes (pre-flight 27)
  pub fn decideShader(custom_shader_active: bool, shaders_disabled: bool) enum { disable_shaders, count_failure };  // pure
  pub fn decide(failures: []const u64, now_ms: u64) enum { retry, warp };  // pure
  // Device.zig
  pub fn preferWarp() void;              // future acquire() uses WARP (process-global)
  pub fn resetPreferWarp() void;         // test hook only (builtin.is_test); tests `defer Device.resetPreferWarp()`
  // D3D11.zig
  pub fn deviceLost(self: *const D3D11) bool;   // atomic read, any thread
  ```
- [ ] **Step 1: Failing tests** (WARP)
  ```zig
  test "d3d11 device: renderers re-acquire a fresh generation after realize" { // two headless renderers, markLost → displayUnrealized/Realized → both on generation 2; generation 1 freed }
  test "d3d11 device: composition chain handed off again after recovery" { // fake hand-off counter +1 }
  test "d3d11 device: preferWarp switches the adapter" { // defer Device.resetPreferWarp() }
  test "d3d11 device: images re-uploaded after recovery" { // headless renderer with a background image + one Kitty image: after the generation change both textures belong to generation 2 }
  test "win32 recovery: decide" { // 1–2 failures retry; 3 within 60 s warp; 3 spread over 2 min retry }
  test "win32 recovery: custom shader is disabled before counting toward WARP" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="d3d11 device"` and `-Dtest-filter="win32 recovery"` → FAIL.
- [ ] **Step 3: Implement.** `GHOSTTY_D3D11_SIMULATE_DEVICE_LOST=<ms>` (Debug, M2 Task 39) now fails every renderer's next `Present` with `DXGI_ERROR_DEVICE_REMOVED`. Scenario `device-recover` (order 660, Debug only, `surfaces=4`): 2 tabs, one with 2 splits, inspector closed, `custom-shader` configured, `background-image = <vt-smoke bg.png fixture>`, one Kitty image printed before the loss; a `-Variant opacity` run adds `background-opacity = 0.9` (composition re-hand-off, run in W6); after the simulated loss the health bar is visible (`state.m3.health`) within 1 s; within 3 s every surface's dump shows its background (image) and the Kitty image again and the bar is hidden; the log has exactly one `device lost`, one `custom shaders disabled after device loss` and four `renderer recovered`. The owner's manual check: a real TDR (`dxcap -forcetdr`, Graphics Tools) — exit checklist.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): full device-loss recovery with health bar and WARP fallback"`

### Task 25: M3 end-to-end run

**Files:** none planned; bug notes only (the lead files 26.n).

- [ ] **Step 1:** `LOCK ZIG build -j6`; `E2E -Milestone all -EvidenceDir %TEMP%\m3-evidence` (Debug), plus `device-recover -Variant opacity` (pre-flight 15). `LOCK ZIG build -j6 -Doptimize=ReleaseFast --prefix zig-out-rf`; `$env:GHOSTTY_E2E_EXE` = RF exe; `E2E -Milestone all`. `powershell -File test/windows/vt-smoke.ps1 -Driver warp`.
- [ ] **Step 2:** For every FAIL write a bug note (scenario, build, symptom, log excerpt, evidence path). `LOCK ZIG build test -j6 -Dtest-filter="win32 "`, `-Dapp-runtime=none -Dtest-filter="d3d11 "`, `"windows directwrite"`, `"shadertoy"`, and `--build-file pkg/win32/build.zig` → record counts.
- [ ] **Step 3: Commit** only if scenario scripts needed fixes of their own: `git commit -m "test(windows): M3 e2e stabilisation"`.

### Task 26.n: Integration fix (template, one bug per task)

**Files:** exactly the files the bug note names (lead assigns; ≤ 5 parallel only with disjoint files).

- [ ] **Step 1:** Reproduce with the failing scenario; pure-logic bugs get a failing unit test first.
- [ ] **Step 2:** Fix; unit filter → PASS; the lead re-runs the scenario in the next batch.
- [ ] **Step 3: Commit** `git commit -m "fix(win32): <bug summary>"`

### Task 27: RAM rows, latency, screenshots, feature checklist, SPEC update, M3 acceptance

**Files:** Modify `docs/windows/ram-baseline.csv`, `docs/windows/latency-baseline.csv`, `docs/windows/feature-checklist.md` (every row has evidence and a status), `test/windows/README.md` (M3 scenarios, vt-smoke, owner-safety additions), `test/windows/lib/Harness.psm1` (only if documented helpers need fixes), `docs/windows/SPEC.md` (§6.6/§7.5/§17 per R-M3-1; §6.4 exception: the inspector's UI-thread swap chain (R-M3-4); §17 M3 marked done with the commit; §18 M3 rulings R-M3-1…12 + Task 8 verdict + L1 ConPTY ruling), `docs/windows/CHANGELOG.md` (M3 section; notes that the explicit AUMID ungroups taskbar pins made with M1/M2 builds)

- [ ] **Step 1:** ReleaseFast build; RAM rows (§ RAM budget): `one-surface` default, `custom-shader`, `opacity` (1 and 5 surfaces), `inspector` (`-Sample` before/open/after 30 s), `quick-terminal` (`-Sample` before/after first toggle), font `Consolas` + CJK (vs G1's `font-consolas-m1`), `overlays` (search + palette + link label each opened once), `toast` (manual and owner-approved: the approval request names the HKCU key `Software\Classes\AppUserModelId\<aumid>`; afterwards the key is deleted with `RegDeleteTreeW` — pre-flight 13); gate each against its budget; over → DONE_WITH_CONCERNS with numbers, owner decides.
- [ ] **Step 2:** Latency: `input-latency` (a) default, 2-split dimmed, `background-opacity = 0.9`, custom shader (recorded) — gate per § Latency budget; rows appended.
- [ ] **Step 3:** Screenshots → evidence dir: search bar, palette, quick terminal (top and bottom), inspector, link label, key-state label, read-only badge, health bar (simulated), transparency over the magenta backdrop (blur and no blur), dimmed split, bell border, custom shader, vt-smoke diff summary; list paths.
- [ ] **Step 4:** ARM64 cross-build `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j6` → record.
- [ ] **Step 5:** Exit checklist (below) recorded; commit `git commit -m "docs(windows): M3 acceptance — RAM, latency, screenshots, feature checklist"`.

### Task 28: ConPTY sequence probe (W1, before lead decision L1; pre-flight 2)

**Review:** light (evidence only, no product code). **Runs GUI** (throwaway `class` instances under the desktop lock through the runner, test IPC on).

**Why:** the default ConPTY flags are 0 (`src/os/windows.zig` `ConPty.flags`, overridable by `GHOSTTY_WIN32_CONPTY_FLAGS`). Without `PSEUDOCONSOLE_PASSTHROUGH_MODE` (8; M2 Task 36 found the inbox conhost accepts it) conhost re-renders output, and sequences it does not understand may never reach Ghostty. M3 features depending on them: Kitty graphics APC (DECISIONS "Features"), OSC 9/777 notifications, OSC 133 `command_finished`, OSC 8 links, OSC 22 pointer shape.

**Files:** Create `test/windows/conpty-probe/run.ps1`, `test/windows/conpty-probe/cases/probe-{kitty-apc,osc9,osc777,osc133,osc8,osc22}.sh` (`printf` only, each < 8 KiB, then `exec sleep 600`), `test/windows/conpty-probe/RESULT.md`. No product code; if a sequence has no observable oracle in the current build, the row says so and the lead decides at L1.

**Interfaces:**
- Produces: `run.ps1 [-Flags 0,8] [-Only …]` launches one Debug `ghostty.exe` per case and flags value (`GHOSTTY_WIN32_CONPTY_FLAGS=<n>`, isolated config, `class = ghostty-cprobe-<hex>`), and judges arrival by one oracle per case: the debug log (stream-handler `osc`/`apc` lines, or the apprt's log line for the resulting action — `desktop_notification`, `command_finished`, `mouse_shape`), the `state` op, or for Kitty APC a dump with the image's pixels present. `RESULT.md`: table `sequence × flags {0, 8} → arrived / dropped / mangled`, with log excerpts, plus key-echo p95 (`input-latency`, 1 run) and `stream-integrity` PASS/FAIL under flags 8.
- [ ] **Step 1: Failing check:** `run.ps1 -Only osc9 -Flags 0` before the case file exists → exits 1 with "no case".
- [ ] **Step 2: Implement** the runner and the six cases.
- [ ] **Step 3: Run** all cases with flags 0 and 8, twice each (determinism); write `RESULT.md`.
- [ ] **Step 4: Verify** every row has a verdict and evidence; scripts parse.
- [ ] **Step 5: Commit** `git commit -m "test(windows): ConPTY passthrough probe for M3 sequences"`

**L1 (lead, before W2):** all needed sequences arrive with 0 → nothing changes. Some arrive only with 8 → Task 28.1. Dropped with both → owner-approved gaps in `feature-checklist.md`; Tasks 3 (`kitty-image`, `osc8-link` refs), 10, 18 drop the dependent steps. The ruling goes into SPEC §18 at Task 27.

### Task 28.1 (conditional, only under L1): default ConPTY flags = `PSEUDOCONSOLE_PASSTHROUGH_MODE`

**Review:** opus (latency gate, core touch point). Lands alone between L1 and W2.

**Files:** Modify `src/os/windows.zig` (default flags `PSEUDOCONSOLE_PASSTHROUGH_MODE` when the running conhost accepts it; the `CreatePseudoConsole` fallback to 0 in `src/pty.zig:512` stays and logs once; `GHOSTTY_WIN32_CONPTY_FLAGS` still overrides).

- [ ] **Step 1: Failing test** `"windows conpty: default flags request passthrough"` (pure helper returning the default flags = 8; env override still wins).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dapp-runtime=none -Dtest-filter="windows conpty"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j6`; the lead re-runs `conpty-probe/run.ps1` without the env var (all needed rows arrive), `stream-integrity`, `vim-less`, `input-latency`; G1 re-measures the whole path (≤ 16 ms p95).
- [ ] **Step 5: Commit** `git commit -m "feat(pty): ConPTY passthrough mode by default on Windows"`

---

## M3 exit checklist

1. `LOCK ZIG build -j6` and ReleaseFast build succeed; `pkg/win32` tests pass; `-Dtest-filter="win32 "` passes 3× in a row; `"d3d11 "`, `"shadertoy"`, `"windows directwrite"`, `"renderer: redraw"` (`-Dapp-runtime=none`) pass; `-Demit-lib-vt` and the Linux recipe build.
2. `win32 actions: every Action.Key is classified` green with 62 implemented, 6 deferred (M5 ×5, post-v1 ×1), 2 unsupported.
3. `E2E -Milestone all` green on Debug and ReleaseFast (M1 + M2 + M3 scenarios); SKIPs only for a non-interactive desktop and re-run by the owner; `vt-smoke.ps1 -Driver warp` all PASS.
4. RAM rows within § RAM budget; default-config rows within +1 MB of M2.
5. Latency: § Latency budget met (Ghostty-owned key echo p95 within +0.5 ms of M2 in the gated configurations).
6. `docs/windows/feature-checklist.md`: every cross-platform feature row has evidence and status ✅ (or an owner-approved gap).
7. Screenshot set inspected by the lead.
8. Owner manual checklist (PASS/FAIL per line): a real toast appears, clicking it focuses the surface (the HKCU AUMID key is removed afterwards unless the owner keeps it); the real `export_terminal_io` save dialog (from the inspector) writes the file; the quick terminal hotkey from another app (e.g. Explorer) slides it in/out smoothly at 100/150 % scale; `background-opacity = 0.85` with and without `background-blur` looks right with "Transparency effects" on and off; a custom shader from the Ghostty shaders collection runs; search, palette, inspector usable with keyboard only; CJK/emoji fallback looks native; a real TDR (`dxcap -forcetdr`) recovers every window; links in Claude Code output open in the browser, `file:` links to an `.exe` only reveal; typing feels unchanged versus M2.
9. Upstream merge into `windows` (lead), M3 changelog with known gaps (toast clicks after exit do nothing; COLRv1 emoji stay Noto; hotkeys not re-registered on layout change; quick terminal not user-resizable; any sequence L1 recorded as dropped by ConPTY; taskbar pins from M1/M2 builds ungrouped by the AUMID).
10. L1 ConPTY ruling recorded in SPEC §18 with Task 28's `RESULT.md` as evidence.

## Carry-over assignment (M1/M2 deferred items that belong to M3)

| Item | Assigned |
|---|---|
| M2 Task 3 deferred list (19 actions → M3) | Task 2 wiring; owners 10–13, 15–20, 24 |
| M2 Task 19 / pre-flight 29: tab context menu, full-title tooltip | Task 21 |
| M2 Task 26: `bell-features = border` | Task 6 |
| M2 Task 38 / SPEC §18.17: text drops | Task 22 |
| M2 Task 39 / SPEC §18.19: full device-loss recovery, health bar | Tasks 24, 11 |
| SPEC §17 from M2: unfocused-split dimming, readonly badge, `toggle_visibility`, `toggle_background_opacity` | Tasks 6, 11, 16, 15 |
| M2 Task 15 minor: `open_config` via `ShellExecuteExW` + notepad fallback | Task 10 |
| M2 Task 18 minors: GDI fallback alpha on Mica, `BufferedPaintInit` cleanup, DeviceLost paint | Task 9 |
| M2 Task 24 minors: `HWND_TOPMOST` on owned popup, `paintLabel` DeviceLost retry/logOnce | Task 9 |
| M2 Task 13 minor: pwd per surface | Task 23 |
| M2 Task 4 minors: dump `before_write` hook in production, `Get-FreeRamGb` standby, lock-wait expiry not recorded | Tasks 6, 3 |
| M2 Task 7 minor: DWRITE `delimiterCount` type | Task 5 |
| M2 Task 11 minor: `ops.zig` double-OOM `@panic` | Task 2 |
| M2 Task 1 minor: `HKEY_CURRENT_USER` sign extension (now reached by the AUMID write) | Task 1 |
| M2 Task 27 minors: TaskDialog failure → second prompt, default-button failure hidden | Task 20 |
| M1 T2/T11 D3DCompile warnings dropped, failed compile not cached; T8 constant-role `initFill` 256 B (reachable with custom shaders) | Task 7 |
| M1 T8 DXGI debug factory before the debug-layer fallback | Task 24 |
| M1 T12 font: index string duplication, first-discover latency, mapped files | Task 5 (index fix only if the index stays reachable; latency measured; mapped files recorded) |
| M1 T23 keyboard, T26 clipboard, T9 Exec read-loop minors | Task 23 |
| M1 T20 `hlsl_uniform_offsets` hand-mirrored | Not fixed — recorded: the builtin `Uniforms` layout is already pinned by the M1 comptime `@offsetOf` tests; a reflection-based check would add `D3DReflect` bindings for no new coverage |
| M1 T16 logging minors | M5 (unchanged from the M2 plan) |
| Other M2 "minor (deferred)" lines (Tasks 5, 8, 9, 10, 14, 17, 19, 20, 22, 31, 36, 37) | Not M3: they belong to M2 code paths and go to the M2 final review / 34.n or stay recorded |

## Self-review

- **Spec coverage (SPEC §17 M3 + every M3 mention):** quick terminal + `RegisterHotKey` + slide (16, 17); palette (13); search (12); notifications/AUMID (18); URL hover/open with validation (10); inspector imgui win32+dx11 (19); config-errors dialog (20); custom shaders via SPIRV-Cross (4, 7); Kitty graphics + background image verified (3 vt-smoke cases); transparency + blur with DComp (8, 14, 15); DirectWrite discovery/fallback (5); device-loss recovery + health bar (24, 11); key-sequence/table indicator (11); export-terminal-io (20); vt-smoke (3); from M2: dimming + bell border (6), readonly badge (11), `toggle_visibility` + global hotkeys (16), `toggle_background_opacity` (15); M2 leftovers: tab menu/tooltip (21), text drops (22); feature checklist (3, 27); M1/M2 minors (table above). SPEC §2's planned file names `notify.zig`, `QuickTerminal.zig`, `CommandPalette.zig`, `SearchBar.zig`, `inspector/` are kept.
- **Waves re-checked against `Files:`** (≤ 5 per wave, no file in two tasks of one wave): W1 — 1 `pkg/win32` shared files (+ new `shlwapi.zig`) + `SharedDeps.zig`; 2 apprt hook sites + stubs + `actions.zig`/`messages.zig`/`ops.zig`/`D3D11.zig`; 3 test scripts + checklist; 4 `spirv-cross/build.zig` + `shadertoy.zig` (+ `global.zig`); 28 `test/windows/conpty-probe/*` only. Between L1 and W2 — 28.1 `src/os/windows.zig` (alone, conditional). W2 — 6 `Decor.zig`/`decor.hlsl`/`D3D11.zig`/`Frame.zig`/`hlsl.zig`/`decor.zig`/`bell.zig` + core renderer/Surface + 2 scenario scripts; 8 `dcomp.zig`/`dxgi.zig`/`pkg/win32/build.zig`/spike; 9 `overlay.zig`/`resize_overlay.zig`/`Chrome.zig`; 16 `hotkeys.zig`/`visibility.zig`; 23 `keyboard.zig`/`key.zig`/`clipboard.zig`/`Exec.zig`/`Window.zig`/`Surface.zig`/`tab_actions.zig`. W3 — 7 renderer `shaders/hlsl/buffer/Texture/RenderPass/Frame/D3D11.zig` + `d3dcompiler.zig` + vt-smoke custom-shader files; 10 `link.zig`/`shell_open.zig`/`app_actions.zig`; 11 `key_state.zig`/`badges.zig`/`app_toast.zig`; 12 `SearchBar.zig`; 13 `CommandPalette.zig`/`palette_filter.zig`. W4 — 14 `SwapChain.zig`/`D3D11.zig`/`dxgi.zig`; 17 `QuickTerminal.zig`/`Window.zig`/`frame.zig`/`App.zig`/`ipc/client.zig`; 18 `notify.zig`/`winrt.zig`; 19 `dcimgui/{build,main}.zig`/`SharedDeps.zig`/`inspector/*`; 20 `config_errors.zig`/`export_io.zig`/`dialogs.zig`/`comdlg32.zig`. W5 — 5 `font/*` + `dwrite.zig` + `font-fallback.ps1`; 15 `composition.zig`/`dcomp.zig`/`Surface.zig`/`Window.zig`/`Tab.zig`/`frame.zig`/`theme.zig` + vt-smoke opacity case + `transparency.ps1`/`opacity-blur.ps1`; 21 `tab_menu.zig`/`strip_input.zig`/`TabStrip.zig`/`Chrome.zig`; 22 `drop.zig` + drop scripts; 24 `recovery.zig`/`Device.zig`/`D3D11.zig`/`SwapChain.zig`/`inspector/Inspector.zig`/`App.zig`/`generic.zig`/`image.zig` (starts after 15 lands). Each scenario script named in a task's `Files:` has that task as its only owner. Each multi-owner file follows its chain.
- **Type names defined once and only consumed elsewhere:** `hooks.WindowChange`, `overlay.{Anchor,Kind,Popup,WindowState}`, `decor.{Word,State}`, `shell_open.Verdict`, `palette_filter.Entry`, `QuickTerminal.{State,Anim}`, `hotkeys.{Chord,State}`, `notify.RegistryWriter`, `composition.{AppState,SurfaceState,WindowState,Backdrop}`, `D3D11.PresentTarget.{decor,mode,hand_off}`, `recovery.State`, `directwrite.DirectWrite` (Tasks 2, 5, 6, 9, 10, 13, 14, 15, 16, 17, 18, 24).
- **Default-path guarantee:** no task allocates at startup except the hook fan-out and `SetCurrentProcessExplicitAppUserModelID`; hotkeys register only if global keybinds exist; G1/G2 measure it.

### Open questions → lead-default rulings (no owner questions)

1. *DComp visuals vs owned popups/decor pass for overlays?* → owned popups + decor pass (R-M3-1); SPEC amended in Task 27.
2. *Composition always on (one code path) vs only for transparency?* → only for transparency (R-M3-2): protects the M2 latency/RAM baseline.
3. *Inspector device: shared or own?* → shared under the context lock (R-M3-4), RAM first; flip if Task 19's review sees lock contention > 1 ms.
4. *Toast click when Ghostty is not running?* → not supported in v1 (R-M3-5); revisit with a COM activator in M5 if the owner wants it.
5. *Quick terminal autohide default?* → core's Windows default (`false`, like Linux); not changed.
6. *Global hotkeys: `RegisterHotKey` vs low-level hook?* → `RegisterHotKey` (R-M3-7): no input-path cost, no AV heuristics.
7. *Custom URL schemes from terminal output?* → confirm dialog (R-M3-8), not silent open, not silent refuse.
8. *Emoji via DirectWrite fallback (Segoe UI Emoji)?* → no; embedded Noto stays (R-M3-9) until COLRv1 rasterisation exists.
9. *Text drops: plain insert or paste semantics?* → paste semantics with protection (R-M3-12).
10. *Should `toggle_background_opacity` recreate swap chains?* → no; backdrop-only switch (R-M3-2).

### Pre-flight pass (self, on this revision)

- Contradictions fixed while writing: the first draft let Task 6 edit `Tab.zig` and `app_actions.zig` (collided with Tasks 9/10 and Task 2's hook sites) → all such call sites moved into Task 2's hooks; Task 17 would have edited `ipc/ops.zig` after Task 2 → Task 2 now routes the op to `QuickTerminal.ipcToggle`; Tasks 17 and 19 would both have added RAM scenarios to `measure-ram.ps1` in W4 → Task 3 adds generic `-ExtraConfig/-Actions/-Tag` switches and no feature task edits the script; the pwd-per-surface fix (needs `Window.zig`/`Surface.zig`) was first placed with Task 21 in W5 next to Task 15 → moved to Task 23 (W2, where those files are free).
- File overlaps inside waves: none (see the per-wave list above); `D3D11.zig` appears once per wave (W1:2, W2:6, W3:7, W4:14, W5:24); `Window.zig` (W1:2, W2:23, W4:17, W5:15); `Surface.zig` (W1:2, W2:23, W5:15); `App.zig` (W1:2, W4:17, W5:24); `SharedDeps.zig` (W1:1, W4:19); `dcomp.zig` (W1:1, W2:8, W5:15); `SwapChain.zig` (W4:14, W5:24).
- Missing tests checked: every task has failing unit tests before code; GUI behaviour has a scenario written by the owning task (run by the lead); security-sensitive logic (`shell_open.validate`, `notify.toastXml`) is pure and table-tested; the registry write is tested through an injected writer only (owner safety); toasts and external opens are recorded in test mode, so no scenario acts on the owner's desktop.
- Owner-safety re-check: hotkey chords fixed to `ctrl+alt+shift+f9/f10`; transparency oracle uses the scenario's own backdrop window; the composition spike never starts `ghostty.exe`; toasts and URL opens never fire in tests; no system setting changed (Transparency effects off is the owner's manual check).
- Residual risks: Task 8 may show the transparent-client variant does not work on this build (fallback: blur-behind empty region; worst case opacity only with blur); imgui_impl_dx11's `D3DCompile` rename (R-M3-4) — if the `#pragma comment(lib, "d3dcompiler")` still pulls an import, Task 19's import-table check fails loudly and Task 19 compiles a patched copy of the backend without the pragma (never links `d3dcompiler`); the WinRT delegate parametric IID must be copied from the SDK header, not derived (Task 18 slot test fails loudly otherwise).

## Pre-flight dispositions

Review: `docs/windows/plans/M3-preflight-review.md` (2 BLOCKER, 13 IMPORTANT, 17 MINOR). Result: 2/2 BLOCKER applied (1 through M2 hotfix Task 34.4, 2 as a new task instead of a Task 3 step); 13/13 IMPORTANT applied; 17/17 MINOR applied (20 as a plan note, DECISIONS edit left to the lead). Rejected: none.

| # | Sev. | Disposition |
|---|---|---|
| 1 | BLOCKER | Applied via M2: lead ruling — fixed now as M2 hotfix Task 34.4 (apprt `open_url` allowlist; core `open.zig` refuses `.osc8`/`.unknown` on Windows). Here: Global Constraint "`open_url` never returns `false`"; Task 2 moves 34.4's arm into `link.zig` (no `false` stub) with test `open_url arm never returns false`; Task 10 builds on 34.4 and `link.open` returns `true` for every verdict/error (test for refuse and queue overflow); `open.zig` is not an M3 touch point. |
| 2 | BLOCKER | Applied with deviation: a dedicated W1 Task 28 (ConPTY probe, flags 0 vs 8, APC G / OSC 9 / 777 / 133 / 8 / 22, `RESULT.md`) instead of a Task 3 Step 0, so Task 3's refs are not blocked; lead decision point L1 before W2; fallback Task 28.1 (`PSEUDOCONSOLE_PASSTHROUGH_MODE` default in `src/os/windows.zig`, core touch point under L1) + latency re-measure at G1; dropped-with-both → owner-approved gaps. Task 5 moved W1 → W5 to keep W1 at 5 tasks. |
| 3 | IMPORTANT | Applied: R-M3-4 `-DD3DCompile=ghostty_imgui_D3DCompile` (forwarder in `inspector/imgui_shim.zig`) and `-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD`; Task 19 import-table check and `pkg/dcimgui/main.zig` externs; Task 1 links only `comdlg32`; `dcomp`/WinRT entry points resolved lazily from System32 (new Global Constraint, Tasks 8/18). |
| 4 | IMPORTANT | Applied: R-M3-8 rewritten (percent-decode, pwd/`~`/`/c/` resolution, `GetFullPathNameW`, ADS/`\?\`/`\.\`/device-name/drive-type refusals, trailing dot/space strip, extended extension list + `AssocIsDangerous`); validation and `exists` on the worker via an injected `Env`; one Task 10 table row per case; Task 10 depends on 23 (pwd). |
| 5 | IMPORTANT | Applied: Task 23 adds `clipboard.pasteText` + test; Task 22 calls it; 22 depends on 2+23. |
| 6 | IMPORTANT | Applied: `focused_in_tab = surface == tab.activeSurface()`; hook `tabLayoutChanged` (Task 2) consumed by `decor`; deactivation and split-insert tests. |
| 7 | IMPORTANT | Applied: `CommandPalette` in the `surfaceDestroying` fan-out; `State.target_id`; `overlay.Command` holds an `Action.clone` freed by the handler; tests. |
| 8 | IMPORTANT | Applied: `SurfaceState.pending` atomic swap, payload-free `WM_GHOSTTY_SET_CONTENT`, release in `Surface.destroy` after `core_surface.deinit()`; test `hand-off after surfaceDestroying is released`. |
| 9 | IMPORTANT | Applied: spike checks (j) mode round-trip on one child HWND and (k) tearing on composition chains; Task 15 `configChanged` ordering; test `mode switch creates and destroys targets`. |
| 10 | IMPORTANT | Applied: core touch point `generic.zig` + `image.zig` (Task 24), chain `generic.zig` 6→24; test `images re-uploaded after recovery`; scenario adds `background-image` and a Kitty image. |
| 11 | IMPORTANT | Applied: Tasks 7/15 ship `.sh` + header only, the lead generates refs in the wave batch (G1/G2); Task 5 records timings from a unit-test harness, RAM row at G1/27; Task 18 toast delta moved to Task 27. |
| 12 | IMPORTANT | Applied: `measure-ram.ps1` `-Actions` implies test IPC, `-Sample`; G1 records `font-consolas-m1` before Task 5; Task 27 adds `overlays` and `toast`; latency method ≥ 200 samples × 3 runs vs same-day re-measured M2 configuration. |
| 13 | IMPORTANT | Applied: `export-io` op `{surface, text, path}`, test mode writes without a dialog and records; real dialog in the owner checklist; manual toast names the HKCU key and deletes it with `RegDeleteTreeW` (Task 27). |
| 14 | IMPORTANT | Applied: Task 21 Files += `TabStrip.zig` (`Layout.trimmed`) and `Chrome.zig` (measure callback); chain `Chrome.zig` 9→21; test. |
| 15 | IMPORTANT | Applied: 7←3, 15←3, 19←2, 22←23, 20←10, 24←15 (24 starts after 15 lands in W5), plus 10←23 and 21←9; `device-recover -Variant opacity` in W6. |
| 16 | MINOR | Applied: `shell_open.appStopping`; `submit(app, surface_id, kind, url)`; `+12` reserved, `WM_GHOSTTY_RECOVER` dropped. |
| 17 | MINOR | Applied: file-level functions in `inspector/Inspector.zig`, `Surface.inspector: ?*Inspector.Inspector`. |
| 18 | MINOR | Applied: `hotkeys.State` stores the leaf; chained leaves run through core's chained path; re-registration inside `configChanged` before the old config is freed; test. |
| 19 | MINOR | Applied: DPI-scaled pixel sizes, `quick-terminal-layer` ignored, tear-off allowed / no drop target, `AllowSetForegroundWindow(server_pid)` in the IPC client (`ipc/client.zig` + `App.zig`, Task 17); tests. |
| 20 | MINOR | Applied as a plan note (speed rules supersede DECISIONS `-j4`); the DECISIONS edit is the lead's (this commit touches only the plan). |
| 21 | MINOR | Applied: the `notifications` scenario emits OSC 133 C/D itself. |
| 22 | MINOR | Applied: test mode shows the confirm TaskDialog; "Yes" records `accepted`, Esc records `cancelled`. |
| 23 | MINOR | Applied: `DisplayName` = DECISIONS name "Ghostty — Unofficial Windows port"; pin ungrouping in the M3 changelog and known gaps. |
| 24 | MINOR | Applied: dropped `DWMWA_BORDER_COLOR`, `GetGUIThreadInfo`, `WS_EX_NOREDIRECTIONBITMAP`, the empty `kernel32` line (and `kernel32.zig` from Task 1); `RegDeleteTreeW` kept with its consumer named (13). |
| 25 | MINOR | Applied: `DCompositionCreateDevice2(null, …)` stated in Task 15, verified by spike check (l); Task 24 never recreates it. |
| 26 | MINOR | Applied: reveal via `SHOpenFolderAndSelectItems(ILCreateFromPathW)`; bindings in Task 1. |
| 27 | MINOR | Applied: `Device.resetPreferWarp` test hook; custom shaders disabled after a loss before counting toward WARP (`decideShader`, test, scenario log line). |
| 28 | MINOR | Applied: every listed scenario script added as `Create:` to its task (`drop-text` stays in `drop-files.ps1`). |
| 29 | MINOR | Applied: SPEC §6.4 exception added to Task 27; `render_inspector` coalesced to the 30 Hz tick via a dirty flag; test. |
| 30 | MINOR | Applied: R-M3-2 and Task 15 — hwnd-mode toggle is a logged no-op; backdrop-table row. |
| 31 | MINOR | Applied: Task 15 `Tab.zig` paints alpha 0 (black brush in the extended frame). |
| 32 | MINOR | Applied: Task 2 Step 0 re-checks hook sites and names against landed M2 (incl. 34.4) and reports diffs before Step 1. |
