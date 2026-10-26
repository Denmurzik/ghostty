# M3 pre-flight review

Plan: `docs/windows/plans/M3-feature-parity.md` (27 tasks, 8 waves + G1/G2). Read-only review against DECISIONS, SPEC
§6/§7.5/§13/§14/§15/§17/§18, the M2 plan and ledger, and the code at `33954db42` (no builds, no GUI runs). M2 is not
finished at this commit (Tasks 21, 23, 25, 28, 32, 38, 39 pending), so the M2 names the plan relies on are checked only
where they already exist.

Totals: **2 BLOCKER, 13 IMPORTANT, 17 MINOR.**

## BLOCKER

**1. Untrusted `open_url` already runs through `rundll32 url.dll,FileProtocolHandler`, and the plan keeps that path open (Tasks 2, 10).**
`src/Surface.zig:4582` `openUrl` falls back to `internal_os.open` whenever the apprt returns `false`. On Windows,
`src/os/open.zig:36` spawns `rundll32 url.dll,FileProtocolHandler <url>` for every kind. Only macOS refuses `.unknown`/`.osc8`
(`open.zig:27`). Today `open_url` is `deferred` in `actions.zig:33`, so `performAction` returns false. An OSC 8 link to
`file:///C:/Users/x/Downloads/a.exe`, `\\host\share\a.exe` or `ms-msdt:` is then handed to the shell handler unvalidated on
Ctrl+click. Task 2's stub keeps this: "stubs log … and return `false`". So does any Task 10 path that returns false
(refuse, cancelled confirm, full queue, OOM).
Fix:
- Global Constraints, add: "`open_url` never returns `false` to core: every arm returns `true` after it has opened,
  revealed, confirmed, refused or failed. Core's generic opener is unreachable on Windows."
- Task 2, `open_url` arm: "→ `link.open(app, target, value)`; the stub logs `M3 stub: refused open_url kind=…` and returns
  `true` (never false)". Add test `"win32 actions: open_url arm never returns false"`.
- M3 core touch points, append: "`src/os/open.zig`: the macOS untrusted-kind refusal also applies to `.windows` —
  Task 2". Test: `open(.osc8, "file:///C:/x/a.exe")` → `error.UntrustedLink` on Windows.
- Task 10 `link.open`: "returns `true` for every verdict and every error". Test `"win32 link: open returns true for refuse
  and on worker-queue overflow"`.
- Lead: this hole is live on `windows` now. Land the `open.zig` change as an M2 hotfix instead of waiting for W1.

**2. Nobody has checked that the sequences M3 features depend on survive inbox ConPTY with `flags = 0` (Tasks 3, 10, 18).**
The default ConPTY flags are 0 (`src/os/windows.zig` `ConPty.flags = 0`, overridable only by env). The ledger ruled
M2 Task 40 (passthrough/OpenConsole) N/A on latency grounds alone. Without `PSEUDOCONSOLE_PASSTHROUGH_MODE`, conhost
re-renders output, and unknown sequences are not guaranteed to reach Ghostty. The ones at risk: Kitty graphics APC
(`\e_G…`), OSC 9 and OSC 777 (notifications), OSC 133 C/D (`command_finished`), OSC 22. Kitty graphics is a DECISIONS
"Features" line. Task 3 would then generate a blank `kitty-image` reference. Tasks 18 and 10 would design and test against
input that never arrives, and the W6 run would find this last.
Fix: in Task 3, add Step 0 "ConPTY passthrough probe". Add `test/windows/vt-smoke/cases/probe-*.sh` for APC G, OSC 9,
OSC 777, OSC 133 A–D, OSC 8 and OSC 22, each run with `GHOSTTY_WIN32_CONPTY_FLAGS=0` and `=8`. The oracle is the
debug log (`osc`/`apc` handler lines) or `state` (test IPC). Record a table in the report. If anything needed is dropped
with flags 0, the lead rules before W2: either the default flags become `PASSTHROUGH_MODE` where accepted (the fallback to 0
in `pty.zig:512` exists), plus a latency re-measure at G1, or the affected features are recorded as owner-approved gaps.
Also add `src/os/windows.zig` (default ConPTY flags) to "M3 core touch points" under "lead ruling after the Task 3 probe".

## IMPORTANT

**3. Linking imgui's Win32/DX11 backends brings back the DLL search-order risk M1 avoided (Tasks 1, 19; R-M3-4).**
M1 loads `d3dcompiler_47.dll` with `LoadLibraryExW(…, LOAD_LIBRARY_SEARCH_SYSTEM32)` (`pkg/win32/d3dcompiler.zig:83`). R-M3-4
instead lets `imgui_impl_dx11.cpp` link `d3dcompiler` (`#pragma comment(lib)`). That is a static import, resolved at
process start from the application directory first: a portable zip unpacked in Downloads loads a planted
`d3dcompiler_47.dll`. `imgui_impl_win32.cpp` also loads `xinput1_4.dll`/`xinput9_1_0.dll` with plain `LoadLibraryA`. Task 1
additionally links `dcomp comdlg32 runtimeobject` statically. That makes every user load `dcomp.dll` at startup, against the
"every feature is lazy" goal; it is unmeasured until G1.
Fix:
- R-M3-4, replace the d3dcompiler sentence with: "`imgui_impl_dx11.cpp` is compiled with
  `-DD3DCompile=ghostty_imgui_D3DCompile`. Ghostty exports that symbol, which forwards to the System32-loaded pointer of
  `pkg/win32/d3dcompiler.zig`. `imgui_impl_win32.cpp` is compiled with `-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD`. `ghostty.exe`
  imports neither `d3dcompiler_47.dll` nor `xinput*`."
- Task 19, Step 4 += "`llvm-readobj --coff-imports zig-out/bin/ghostty.exe` (or a PE import-table check in Zig) lists no
  `d3dcompiler_47.dll`, `xinput*` or `dcomp.dll`."
- Task 19, Files += `pkg/dcimgui/main.zig`. It needs `extern` declarations for `ImGui_ImplWin32_*` and `ImGui_ImplDX11_*`.
  `ImGui_ImplWin32_WndProcHandler` is `#if 0` in the header, so it is declared by hand.
- Task 1: drop `dcomp` and `runtimeobject` from the link list. Tasks 8/15 (`DCompositionCreateDevice2`) and 18 (`Ro*`,
  `Windows*String`) resolve them on first use through `LoadLibraryExW(SYSTEM32)` + `GetProcAddress`, like
  `comctl32.zig:97`. `comdlg32` is a KnownDLL and may stay static.

**4. `shell_open.validate` (R-M3-8) is a deny-list over an un-normalised path (Task 10).**
Missing cases that run code or leak data:
- Trailing dots/spaces: `a.exe.`, `a.exe ` (Windows strips them and runs `a.exe`).
- Alternate data streams: `C:\x\a.txt:evil.exe`.
- Percent-encoding in `file:` URLs: `a.%65xe`, `%5C%5Csrv`.
- Device names (`CON`, `\\.\`, `\\?\GLOBALROOT`), `\\?\C:\` long paths, and 8.3 names.
- Types missing from the list: `.settingcontent-ms`, `.library-ms`, `.searchConnector-ms`, `.diagcab`, `.appref-ms`,
  `.website`, `.theme(pack)`, `.iso/.img/.vhd(x)` (auto-mount), `.xll`, `.inf`, `.scf`, `.sct`, `.wsc`, `.msp`, `.docm`.
- Mapped network drives (`Z:` = `DRIVE_REMOTE`).
- The `unknown` kind's relative and `~` paths, which core says can be `src/main.zig`, and Git Bash's `/c/…` paths. These
  resolve against Ghostty's own cwd instead of the surface's pwd.
- `exists` runs on the UI thread, so a disconnected network drive blocks it for seconds.

Fix, R-M3-8 replacement for "`file:` and bare paths …":
- `file:` URLs are percent-decoded once. Bare paths are resolved against the surface pwd (`/c/x` → `C:\x`, `~` →
  `%USERPROFILE%`), then `GetFullPathNameW`.
- Refuse: a `:` after the drive letter, any `\\?\` or `\\.\` prefix, DOS device names, and `GetDriveTypeW` ≠ `DRIVE_FIXED`/
  `DRIVE_REMOVABLE`.
- Reveal: the extension check runs after stripping trailing dots and spaces, and also reveals when
  `AssocIsDangerous(ext)` (shlwapi) is true.
- `exists` and the drive check run on the shell_open worker, never on the UI thread.

Add one table row per case above to Task 10 Step 1.

**5. Text drops cannot reach the unsafe-paste confirmation without editing `clipboard.zig` (Task 22, R-M3-12).**
`completeClipboardRequest(.paste, …, confirmed = false)` returns `error.UnsafePaste`. The dialog-and-retry flow is
`clipboard.zig:204 process` / `:278 confirmWith`, both private. Task 22 may edit only `drop.zig`.
Fix: Task 23 (W2, already owns `clipboard.zig`) adds `pub fn pasteText(surface: *Surface, text: [:0]const u8) void` with
the same confirm/deny flow, and test `"win32 clipboard: pasteText asks for unsafe text"`. Task 22 calls it. Waves table:
22 depends on "2, 23".

**6. Decor dimming uses keyboard focus, and the tab topology has no hook (Tasks 2, 6).**
`decor.surfaceFocus` is driven by `WM_SETFOCUS`/`WM_KILLFOCUS` of the surface child. Those fire when the window is
deactivated, when the search bar or palette takes focus, and when a dialog opens. If `focused_in_tab` follows them, the
whole tab dims (GTK dims by the split tree's focused surface, not by toplevel focus). Splits created or closed without a
focus change, and `toggle_split_zoom`, never call `refreshTab`.
Fix:
- Task 6 `compute` doc: "`focused_in_tab` = `surface == tab.activeSurface()`, independent of Win32 focus and window
  activation".
- Task 2 `hooks.zig` += `pub fn tabLayoutChanged(tab: *Tab) void; // decor — after every split insert/remove/zoom/equalize
  relayout in Tab.zig`.
- Task 6 tests += `"win32 decor: window deactivation does not dim the active split"`.

**7. The command palette keeps a raw `*Surface` and config-owned actions across messages (Tasks 2, 13).**
`CommandPalette.State.target: ?*Surface` is not in `hooks.surfaceDestroying`'s fan-out. If a split closes while the palette
is open (e.g. `exit`), a later Enter runs `performBindingAction` on freed memory. The `overlay.Command` posted in
`WM_GHOSTTY_OVERLAY_CMD` carries an `input.Binding.Action` whose slices point into the config, and a reload in between frees
them.
Fix:
- Task 2 `surfaceDestroying` list += `CommandPalette` (closes the palette if its target is the dying surface).
- Task 13: `State.target_id: ?u32` replaces the pointer and is resolved through `Window.findSurface` at execute time.
  `overlay.Command` holds a deep copy of the action (`Action.clone`), freed by the handler.
- Test `"win32 palette: target closed while open"`.

**8. A composition swap chain handed off by `PostMessageW` leaks when the surface dies first (Tasks 14, 15, 24).**
`hooks.surfaceDestroying` runs before `core_surface.deinit()` joins the render thread, so the render thread can still create
a chain and post `WM_GHOSTTY_SET_CONTENT` with an AddRef. `DestroyWindow` then discards the message, and the chain and its
device generation are never released. This defeats Task 24's "generation 1 freed" test in real use.
Fix: Task 14 `HandOff`: "the callee stores the chain in `composition.SurfaceState.pending: std.atomic.Value(?*IDXGISwapChain1)`
(swap; release the previous value) and posts a payload-free `WM_GHOSTTY_SET_CONTENT`. The handler swaps `pending` to null.
`Surface.destroy` releases a non-null `pending` after `core_surface.deinit()` and before `DestroyWindow`." Test
`"win32 composition: hand-off after surfaceDestroying is released"`.

**9. Switching between hwnd and composition mode on reload is not designed or spiked (Tasks 8, 15; R-M3-2).**
`composition.configChanged` says only "store mode, bump generation". Nothing creates the DComp target and visual for a
surface that started in hwnd mode, or destroys them on the way back. The spike never puts a flip `hwnd` chain and a DComp
target on the same child HWND one after the other. It also does not check whether `ALLOW_TEARING` (Task 14: "same …
tearing flags") is valid for composition chains.
Fix:
- Task 8 adds (j): "the same child HWND: hwnd-mode chain → released → `CreateTargetForHwnd` + composition chain → back
  to hwnd mode; no `DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED`, no black frame longer than 1 refresh", and (k):
  "`CreateSwapChainForComposition` with `ALLOW_TEARING` + `Present(0, ALLOW_TEARING)`: accepted or not."
- Task 15 `configChanged`: "hwnd→composition: create target+visual (UI thread) before the generation bump;
  composition→hwnd: `SetContent(null)`, Commit, release target+visual after the bump".
- Test `"win32 composition: mode switch creates and destroys targets"`.

**10. Device-loss recovery leaves Kitty images and the background image on the removed device (Task 24).**
`generic.releaseGpuResources` (`generic.zig:1244`) deliberately does not release images ("we don't want to reupload images").
After `displayUnrealized`/`displayRealized` onto a new device generation, the image textures still belong to the lost
device, and binding them on the new context fails or crashes. The `device-recover` scenario has no image, so it would pass.
`generic.zig` is not in the M3 core touch points, so the implementer would stop and an `n.1` task would follow.
Fix: M3 core touch points += "`src/renderer/generic.zig` + `src/renderer/image.zig`: on a backend-reported device
generation change, image textures are dropped and marked for re-upload (platform-neutral, no-op elsewhere) — Task 24".
Task 24 test `"d3d11 device: images re-uploaded after recovery"`. The scenario config += `background-image = <fixture>`
plus one Kitty image printed before the loss.

**11. Implementer tasks that need GUI runs, against the speed rules (Tasks 5, 7, 15, 18).**
Only Tasks 3 and 8 may run GUI. Yet:
- Task 7 ships `ref/custom-shader.png` and Task 15 ships `ref/opacity.png`; both are generated by a vt-smoke GUI run.
- Task 5 Step 4 measures private bytes with `font-family = Consolas` (a `measure-ram` GUI run). That needs Task 3's
  `-ExtraConfig`, which lands in the same wave.
- Task 18 measures a real toast.

Fix:
- Tasks 7 and 15 write the case `.sh` + header only. "The lead generates `ref/<case>.png` in the wave batch
  (`vt-smoke.ps1 -Only <case> -Driver warp -Update`) and inspects it."
- Task 5 records only timings from a unit-test harness. The `Consolas` RAM row moves to G1, together with an M1-index row
  measured on the pre-Task-5 build (see 12).
- Task 18's toast delta moves to Task 27.

**12. Several RAM and latency budgets cannot be checked as written (RAM budget, Latency budget, Tasks 3, 27).**
- "DirectWrite ≤ M1-index row + 2 MB": `docs/windows/ram-baseline.csv` has no `font-family` row.
- The "overlays after first use" and "first toast" rows are absent from Task 27 Step 1.
- `measure-ram.ps1 -Actions` needs `GHOSTTY_WIN32_TEST_IPC=1`, but the script enables it only for `tabs|splits|zero-windows`
  (`measure-ram.ps1:130`). It also has no multi-point sampling for "inspector … 30 s after close" or "quick terminal
  before/after the first toggle".
- Latency: the baseline's key-echo rows have `n = 3` (p95 = max). The gate "within +0.5 ms p95" is below run-to-run noise.

Fix:
- Task 3 `measure-ram.ps1`: `-Actions` implies test IPC. Add `-Sample <label>@<op>` points (one CSV row per point, scenario
  `<tag>:<label>`).
- G1 records `font-consolas-m1` on the commit before Task 5 lands.
- Task 27 Step 1 += `overlays` (search + palette + link label opened once), `toast` (manual, owner-approved).
- Latency budget: "each gated configuration runs ≥ 200 key-echo samples × 3 runs; the gate compares the median of the 3
  p95 values with the M2 acceptance row re-measured on the same day".

**13. Owner safety: the save dialog and the manual toast write HKCU (Tasks 2, 18, 20).**
- `export-io` drives a real `GetSaveFileNameW` on the owner's desktop. It writes the ComDlg32 MRU keys
  (`HKCU\…\ComDlg32\OpenSavePidlMRU`, `LastVisitedPidlMRU`), and typing into it is flaky.
- Task 18's approved manual toast writes `HKCU\Software\Classes\AppUserModelId\…-debug` and leaves it there.

Fix:
- Task 2: op `export-io {surface, text, path}`. In test mode, `export_io` writes to `path` without a dialog and records
  `{path, bytes}` in `state.m3`.
- Task 20 scenario: assert the file content. The real dialog goes in the owner's manual checklist.
- Task 18 / Task 27: "the manual toast run names the HKCU key in the approval request and deletes it afterwards with
  `RegDeleteTreeW` (Task 1 binding)".

**14. Task 21's tooltip needs title-trimming data that no listed file provides.**
`TabStrip.zig` (layout) has no trimming state. Titles are drawn in `Chrome.zig`, which does not report clipping.
Fix: Task 21 Files += `src/apprt/win32/TabStrip.zig` (`Layout.trimmed: []bool`, filled from a DWrite text-width
measure via a callback) or `Chrome.zig`. Neither is touched by another W5 task. Hot-file chain: `Chrome.zig 9→21`.

**15. Dependencies missing from the waves table.**
With "start as soon as stated dependencies landed", these can start too early:
- 7 ← 3 (vt-smoke harness for its case).
- 15 ← 3.
- 19 ← 2 (stub file and `Surface.inspector`).
- 22 ← 23 (item 5).
- 20 ← 10 ("Open configuration" button relies on `open_config` → `shell_open.openPath`).
- 24 ← 15: runtime composition re-hand-off. Task 24's test uses a fake. Add the `background-opacity = 0.9` variant of
  `device-recover` to the W6 run.

Replace the W2–W5 "Depends on" cells accordingly.

## MINOR

16. Task 2 hooks: `appStopping` calls `link.appStopping (worker)`, but the worker lives in `App.shell_open`. Change it to
    `shell_open.appStopping`. `shell_open.submit(app, verdict)` has no window to post `url_confirm` to; make it
    `submit(app, surface_id, verdict)`. `WM_GHOSTTY_RECOVER` (+12) is never posted, because Task 24 uses timer 2. Drop it
    and keep it reserved.
17. Task 2 vs Task 19: `inspector.Inspector.action` (arm) vs a file-level `pub fn action` plus a nested `pub const Inspector`
    in `Inspector.zig`. Pick one: file-level functions, with `Surface.inspector: ?*Inspector.Inspector`.
18. Task 16: global binds can be `leaf_chained`, but `State.ids` stores one `Action`. Store the leaf and call
    `performAllChainedAction` for chains. Actions reference config memory: re-register inside `configChanged` before the
    old config is freed.
19. Task 17:
    - `quick-terminal-size` pixels = logical px × monitor DPI / 96.
    - Add `quick-terminal-layer` to the "ignored on Windows" list.
    - Say whether tabs can be torn off from or dropped onto the quick window (suggest: no drop target, tear-off allowed).
    - IPC toggle from another process hits the foreground lock. The `ghostty +toggle-quick-terminal` client calls
      `AllowSetForegroundWindow(server_pid)` before sending.
20. Global Constraints say `-j6`; DECISIONS "Process constraints" still says `-j4`. Record the owner's 2026-10-26 speed
    rule in DECISIONS (lead), or the plan contradicts the binding file.
21. Task 18 scenario: `command_finished` depends on Git Bash shell integration emitting OSC 133. Emit
    `printf '\e]133;C\a'; sleep 1; printf '\e]133;D;0\a'` directly, so the scenario does not depend on M5 integration work.
22. Task 10 test mode: say that the `confirm` TaskDialog is shown in test mode (the scenario presses Esc) and that "Yes"
    records instead of opening. The current text says both "records" and "dialog cancelled".
23. R-M3-5: `DisplayName "Ghostty"` vs the DECISIONS product name "Ghostty — Unofficial Windows port". Pick one.
    `SetCurrentProcessExplicitAppUserModelID` at start ungroups taskbar pins made with M1/M2 builds; add that to the
    changelog.
24. Task 1 binds names no task uses: `RegDeleteTreeW` (unless used by item 13), `DWMWA_BORDER_COLOR` (bell border is the
    decor pass), `GetGUIThreadInfo`, `WS_EX_NOREDIRECTIONBITMAP`, and the empty `kernel32` line. Drop them or name the
    consumer.
25. Task 15: create the DComp device with `DCompositionCreateDevice2(null, …)` (no rendering device), so it survives a
    D3D device loss. State this so Task 24 does not recreate it.
26. Task 10 reveal: use `SHOpenFolderAndSelectItems` (`ILCreateFromPathW`) instead of building an
    `explorer.exe /select,<path>` command line. That avoids quoting issues with `,` and spaces.
27. Task 24: `Device.preferWarp()` is process-global. The test resets it (`defer Device.resetPreferWarp()` test hook).
    A device loss that happens with a custom shader active should disable custom shaders for the next attempt (log +
    health text) before counting toward WARP: a GPU-hanging shader otherwise causes three system-wide TDR freezes.
28. Scenario and fixture files are missing from `Files:`:
    - Task 5: `e2e/font-fallback.ps1`.
    - Task 6: `split-dim.ps1`, `bell-border.ps1`.
    - Task 7: `custom-shader.ps1`.
    - Task 9: `overlay-follow.ps1`.
    - Task 10: `link-hover-open.ps1`.
    - Task 11: `status-overlays.ps1`.
    - Task 12: `search.ps1`.
    - Task 13: `palette.ps1`.
    - Task 15: `opacity-blur.ps1`.
    - Task 16: `hotkey-global.ps1`, `toggle-visibility.ps1`.
    - Task 17: `quick-terminal.ps1`.
    - Task 18: `notifications.ps1`.
    - Task 20: `config-errors.ps1`, `export-io.ps1`.
    - Task 21: `tab-menu.ps1`.
    - Task 22: `drop-text` (in `drop-files.ps1`, listed).
    - Task 24: `device-recover.ps1`.

    Add `Create:` lines so the disjointness check and the reviewers see them.
29. Task 19 / SPEC: the inspector's UI-thread swap chain is an exception to SPEC §6.4 ("the UI thread never calls into
    DXGI"). Add it to Task 27's SPEC update list. `render_inspector` arrives per terminal frame, and rendering imgui for
    each one on the UI thread delays `WM_KEYDOWN` while the inspector is open. Coalesce to the 30 Hz tick (a dirty flag).
30. R-M3-2 / Task 15: `toggle_background_opacity` with `background-opacity = 1` (hwnd mode) is a no-op (state unchanged,
    logged), as on macOS. Test row in `"win32 composition: backdrop table"`.
31. Task 15 / R-M3-3: "container paints nothing in transparent mode" leaves stale redirection-surface pixels. Paint
    alpha 0 (black brush inside the extended frame), as spike check (b) does.
32. Task 2 Step 0 (new): M2 lands Tasks 21–39 after this plan was written (tray, Task 30 `PresentTarget.generation`, Task
    32's re-parent point, Task 38's `drop.handle`, Task 39's device generation). Re-check every hook site and name
    against the landed code and report diffs to the lead before Step 1.
